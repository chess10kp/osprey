# interop import: child_process { spawn }
# interop import: fs { readdirSync, statSync }
# interop import: os { homedir }
# interop import: path { basename, dirname, join }
import from "./fuzzy.jac" { fuzzyFilter }
import from re { sub }

glob PATH_DELIMITERS = set([" ", "\t", "\"", "'", "="]);

def toDisplayPath(value: str) -> str {
    return value.replace("\\", "/");
}

def escapeRegex(value: str) -> str {
    return sub(r"[.*+?^${}()|[\]\\]", "\\$&", value);
}

def buildFdPathQuery(query: str) -> str {
    normalized = toDisplayPath(query);
    if not ("/" in normalized) {
        return (normalized as str);
    }
    hasTrailingSeparator: str = normalized.endswith("/");
    trimmed = sub(r"^\/+|\/+$", "", normalized);
    if not trimmed {
        return (normalized as str);
    }
    separatorPattern: str = "[\\\\/]";
    segments = [escapeRegex(segment) for segment in trimmed.split("/").filter(Boolean)];
    if (len(segments) == 0) {
        return (normalized as str);
    }
    pattern = separatorPattern.join(segments);
    if hasTrailingSeparator {
        pattern += separatorPattern;
    }
    return (pattern as str);
}

def findLastDelimiter(text: str) -> float {
    i: int = (len(text) - 1);
    while (i >= 0) {
        if PATH_DELIMITERS.has(((lambda (_jx_null0: any) -> any { return (_jx_null0 if _jx_null0 is not None else ""); })(text[i]))) {
            return (i as float);
        }
        i -= 1;
    }
    return -1;
}

def findUnclosedQuoteStart(text: str) -> float | None {
    inQuotes: bool = False;
    quoteStart = -1;
    i: int = 0;
    while (i < len(text)) {
        if (text[i] == "\"") {
            inQuotes = not inQuotes;
            if inQuotes {
                quoteStart = i;
            }
        }
        i += 1;
    }
    return (quoteStart if inQuotes else None);
}

def isTokenStart(text: str, index: float) -> bool {
    return ((index == 0) or PATH_DELIMITERS.has(((lambda (_jx_null1: any) -> any { return (_jx_null1 if _jx_null1 is not None else ""); })(text[(index - 1)]))));
}

def extractQuotedPrefix(text: str) -> str | None {
    quoteStart = findUnclosedQuoteStart(text);
    if (quoteStart == None) {
        return None;
    }
    if ((quoteStart > 0) and (text[(quoteStart - 1)] == "@")) {
        if not isTokenStart(text, (quoteStart - 1)) {
            return None;
        }
        return text[(quoteStart - 1):];
    }
    if not isTokenStart(text, quoteStart) {
        return None;
    }
    return text[quoteStart:];
}

def parsePathPrefix(prefix: str) -> dict[str, str | bool] {
    if prefix.startswith("@\"") {
        return {"rawPrefix": prefix[2:], "isAtPrefix": True, "isQuotedPrefix": True};
    }
    if prefix.startswith("\"") {
        return {"rawPrefix": prefix[1:], "isAtPrefix": False, "isQuotedPrefix": True};
    }
    if prefix.startswith("@") {
        return {"rawPrefix": prefix[1:], "isAtPrefix": True, "isQuotedPrefix": False};
    }
    return {"rawPrefix": prefix, "isAtPrefix": False, "isQuotedPrefix": False};
}

def buildCompletionValue(path: str, options: dict[str, bool]) -> str {
    needsQuotes = (options.isQuotedPrefix or (" " in path));
    prefix = ("@" if options.isAtPrefix else "");
    if not needsQuotes {
        return f"{prefix}{path}";
    }
    openQuote: str = f"{prefix}\"";
    closeQuote: str = "\"";
    return f"{openQuote}{path}{closeQuote}";
}

async def walkDirectoryWithFd(baseDir: str, fdPath: str, query: str, maxResults: float, signal: any) -> any {
    args = ["--base-directory", baseDir, "--max-results", str(maxResults), "--type", "f", "--type", "d", "--follow", "--hidden", "--exclude", ".git", "--exclude", ".git/*", "--exclude", ".git/**"];
    if ("/" in toDisplayPath(query)) {
        args.append("--full-path");
    }
    if query {
        args.append(buildFdPathQuery(query));
    }
    return await Promise(lambda (resolve: any) -> any { if signal.aborted {     resolve([]);     return; } child = spawn(fdPath, args, {"stdio": ["ignore", "pipe", "pipe"]}); stdout: str = ""; resolved: bool = False; finish = lambda (results: list[dict[str, str | bool]]) -> any { if resolved {     return; } resolved = True; signal.removeEventListener("abort", onAbort); resolve(results); }; onAbort = lambda () -> any { if (child.exitCode == None) {     child.kill("SIGKILL"); } }; signal.addEventListener("abort", onAbort, {"once": True}); child.stdout.setEncoding("utf-8"); child.stdout.on("data", lambda (chunk: str) -> any { stdout += chunk; }); child.on("error", lambda () -> any { finish([]); }); child.on("close", lambda (code: any) -> any { if ((signal.aborted or (code != 0)) or not stdout) {     finish([]);     return; } lines = stdout.strip().split("\n").filter(Boolean); results: list[dict[str, str | bool]] = []; for line in lines {     displayLine = toDisplayPath(line);     hasTrailingSeparator: str = displayLine.endswith("/");     normalizedPath = (displayLine[0:-1] if hasTrailingSeparator else displayLine);     if (((normalizedPath == ".git") or normalizedPath.startswith(".git/")) or ("/.git/" in normalizedPath)) {         continue;     }     results.append({"path": displayLine, "isDirectory": hasTrailingSeparator}); } finish(results); }); });
}

obj:pub CombinedAutocompleteProvider {
    has commands: list[any];
    has basePath: str;
    has fdPath: str | None;
    def __init__(commands: list[any] = [], basePath: str, fdPath: str | None = None) -> None {
        self.commands = commands;
        self.basePath = basePath;
        self.fdPath = fdPath;
    }
    async def getSuggestions(lines: list[str], cursorLine: float, cursorCol: float, options: dict[str, any | bool | None]) -> any {
        currentLine = (lines[cursorLine] or "");
        textBeforeCursor = currentLine[0:cursorCol];
        atPrefix = self.extractAtPrefix(textBeforeCursor);
        if atPrefix {
            _jx_d0: any = parsePathPrefix(atPrefix);
            rawPrefix = _jx_d0.rawPrefix;
            isQuotedPrefix = _jx_d0.isQuotedPrefix;
            suggestions = await self.getFuzzyFileSuggestions(rawPrefix, {"isQuotedPrefix": isQuotedPrefix, "signal": options.signal});
            if (len(suggestions) == 0) {
                return None;
            }
            return {"items": suggestions, "prefix": atPrefix};
        }
        if (not options.force and textBeforeCursor.startswith("/")) {
            spaceIndex = (-1 if " " not in textBeforeCursor else textBeforeCursor.index(" "));
            if (spaceIndex == -1) {
                prefix = textBeforeCursor[1:];
                commandItems = self.commands.map(lambda (cmd: any) -> any { name = (cmd.name if ("name" in cmd) else cmd.value); hint = (cmd.argumentHint if (("argumentHint" in cmd) and cmd.argumentHint) else None); desc = ((lambda (_jx_null2: any) -> any { return (_jx_null2 if _jx_null2 is not None else ""); })(cmd.description)); fullDesc = ((f"{hint} — {desc}" if desc else hint) if hint else desc); return {"name": name, "label": name, "description": (fullDesc or None)}; });
                filtered = [{"value": item.name, "label": item.label, **(item.description and {"description": item.description})} for item in fuzzyFilter(commandItems, prefix, lambda (item: any) -> any { return item.name; })];
                if (len(filtered) == 0) {
                    return None;
                }
                return {"items": filtered, "prefix": textBeforeCursor};
            }
            commandName = textBeforeCursor[1:spaceIndex];
            argumentText = textBeforeCursor[(spaceIndex + 1):];
            command = self.commands.find(lambda (cmd: any) -> any { name = (cmd.name if ("name" in cmd) else cmd.value); return (name == commandName); });
            if ((not command or not ("getArgumentCompletions" in command)) or not command.getArgumentCompletions) {
                return None;
            }
            argumentSuggestions = await command.getArgumentCompletions(argumentText);
            if (not Array.isArray(argumentSuggestions) or (len(argumentSuggestions) == 0)) {
                return None;
            }
            return {"items": argumentSuggestions, "prefix": argumentText};
        }
        pathMatch = self.extractPathPrefix(textBeforeCursor, ((lambda (_jx_null3: any) -> any { return (_jx_null3 if _jx_null3 is not None else False); })(options.force)));
        if (pathMatch == None) {
            return None;
        }
        suggestions = self.getFileSuggestions(pathMatch);
        if (len(suggestions) == 0) {
            return None;
        }
        return {"items": suggestions, "prefix": pathMatch};
    }
    def applyCompletion(lines: list[str], cursorLine: float, cursorCol: float, item: any, prefix: str) -> dict[str, list[str] | float] {
        currentLine = (lines[cursorLine] or "");
        beforePrefix = currentLine[0:(cursorCol - len(prefix))];
        afterCursor = currentLine[cursorCol:];
        isQuotedPrefix = (prefix.startswith("\"") or prefix.startswith("@\""));
        hasLeadingQuoteAfterCursor: str = afterCursor.startswith("\"");
        hasTrailingQuoteInItem: str = item.value.endswith("\"");
        adjustedAfterCursor = (afterCursor[1:] if ((isQuotedPrefix and hasTrailingQuoteInItem) and hasLeadingQuoteAfterCursor) else afterCursor);
        isSlashCommand = ((prefix.startswith("/") and (beforePrefix.strip() == "")) and not ("/" in prefix[1:]));
        if isSlashCommand {
            newLine: str = f"{beforePrefix}/{item.value} {adjustedAfterCursor}";
            newLines = [*lines];
            newLines[cursorLine] = newLine;
            return {"lines": newLines, "cursorLine": cursorLine, "cursorCol": ((len(beforePrefix) + len(item.value)) + 2)};
        }
        if prefix.startswith("@") {
            isDirectory: str = item.label.endswith("/");
            suffix = ("" if isDirectory else " ");
            newLine: str = f"{(beforePrefix + item.value)}{suffix}{adjustedAfterCursor}";
            newLines = [*lines];
            newLines[cursorLine] = newLine;
            hasTrailingQuote: str = item.value.endswith("\"");
            cursorOffset = ((len(item.value) - 1) if (isDirectory and hasTrailingQuote) else len(item.value));
            return {"lines": newLines, "cursorLine": cursorLine, "cursorCol": ((len(beforePrefix) + cursorOffset) + len(suffix))};
        }
        textBeforeCursor = currentLine[0:cursorCol];
        if (("/" in textBeforeCursor) and (" " in textBeforeCursor)) {
            newLine = ((beforePrefix + item.value) + adjustedAfterCursor);
            newLines = [*lines];
            newLines[cursorLine] = newLine;
            isDirectory: str = item.label.endswith("/");
            hasTrailingQuote: str = item.value.endswith("\"");
            cursorOffset = ((len(item.value) - 1) if (isDirectory and hasTrailingQuote) else len(item.value));
            return {"lines": newLines, "cursorLine": cursorLine, "cursorCol": (len(beforePrefix) + cursorOffset)};
        }
        newLine = ((beforePrefix + item.value) + adjustedAfterCursor);
        newLines = [*lines];
        newLines[cursorLine] = newLine;
        isDirectory: str = item.label.endswith("/");
        hasTrailingQuote: str = item.value.endswith("\"");
        cursorOffset = ((len(item.value) - 1) if (isDirectory and hasTrailingQuote) else len(item.value));
        return {"lines": newLines, "cursorLine": cursorLine, "cursorCol": (len(beforePrefix) + cursorOffset)};
    }
    def extractAtPrefix(text: str) -> str | None {
        quotedPrefix = extractQuotedPrefix(text);
        if ((lambda (_jx_opt4: any) -> any { return (_jx_opt4.startsWith("@\"") if _jx_opt4 is not None else None); })(quotedPrefix)) {
            return quotedPrefix;
        }
        lastDelimiterIndex: float = float(findLastDelimiter(text));
        tokenStart = (0 if (lastDelimiterIndex == -1) else (lastDelimiterIndex + 1));
        if (text[tokenStart] == "@") {
            return text[tokenStart:];
        }
        return None;
    }
    def extractPathPrefix(text: str, forceExtract: bool = False) -> str | None {
        quotedPrefix = extractQuotedPrefix(text);
        if quotedPrefix {
            return quotedPrefix;
        }
        lastDelimiterIndex: float = float(findLastDelimiter(text));
        pathPrefix = (text if (lastDelimiterIndex == -1) else text[(lastDelimiterIndex + 1):]);
        if forceExtract {
            return pathPrefix;
        }
        if ((("/" in pathPrefix) or pathPrefix.startswith(".")) or pathPrefix.startswith("~/")) {
            return pathPrefix;
        }
        if ((pathPrefix == "") and text.endswith(" ")) {
            return pathPrefix;
        }
        return None;
    }
    def expandHomePath(path: str) -> str {
        if path.startswith("~/") {
            expandedPath = join(homedir(), path[2:]);
            return (f"{expandedPath}/" if (path.endswith("/") and not expandedPath.endswith("/")) else expandedPath);
        }
        elif (path == "~") {
            return homedir();
        }
        return path;
    }
    def resolveScopedFuzzyQuery(rawQuery: str) -> dict[str, str] | None {
        normalizedQuery = toDisplayPath(rawQuery);
        slashIndex = normalizedQuery.lastIndexOf("/");
        if (slashIndex == -1) {
            return None;
        }
        displayBase = normalizedQuery[0:(slashIndex + 1)];
        query = normalizedQuery[(slashIndex + 1):];
        baseDir: str;
        if displayBase.startswith("~/") {
            baseDir = self.expandHomePath(displayBase);
        }
        elif displayBase.startswith("/") {
            baseDir = displayBase;
        }
        else {
            baseDir = join(self.basePath, displayBase);
        }
        try {
            if not statSync(baseDir).isDirectory() {
                return None;
            }
        }
        except Exception {
            return None;
        }
        return {"baseDir": baseDir, "query": query, "displayBase": displayBase};
    }
    def scopedPathForDisplay(displayBase: str, relativePath: str) -> str {
        normalizedRelativePath = toDisplayPath(relativePath);
        if (displayBase == "/") {
            return f"/{normalizedRelativePath}";
        }
        return f"{toDisplayPath(displayBase)}{normalizedRelativePath}";
    }
    def getFileSuggestions(prefix: str) -> list[any] {
        try {
            searchDir: str;
            searchPrefix: str;
            _jx_d0: any = parsePathPrefix(prefix);
            rawPrefix = _jx_d0.rawPrefix;
            isAtPrefix = _jx_d0.isAtPrefix;
            isQuotedPrefix = _jx_d0.isQuotedPrefix;
            expandedPrefix = rawPrefix;
            if expandedPrefix.startswith("~") {
                expandedPrefix = self.expandHomePath(expandedPrefix);
            }
            isRootPrefix = (((((((rawPrefix == "") or (rawPrefix == "./")) or (rawPrefix == "../")) or (rawPrefix == "~")) or (rawPrefix == "~/")) or (rawPrefix == "/")) or (isAtPrefix and (rawPrefix == "")));
            if isRootPrefix {
                if (rawPrefix.startswith("~") or expandedPrefix.startswith("/")) {
                    searchDir = expandedPrefix;
                }
                else {
                    searchDir = join(self.basePath, expandedPrefix);
                }
                searchPrefix = "";
            }
            elif rawPrefix.endswith("/") {
                if (rawPrefix.startswith("~") or expandedPrefix.startswith("/")) {
                    searchDir = expandedPrefix;
                }
                else {
                    searchDir = join(self.basePath, expandedPrefix);
                }
                searchPrefix = "";
            }
            else {
                dir = dirname(expandedPrefix);
                file = basename(expandedPrefix);
                if (rawPrefix.startswith("~") or expandedPrefix.startswith("/")) {
                    searchDir = dir;
                }
                else {
                    searchDir = join(self.basePath, dir);
                }
                searchPrefix = file;
            }
            entries = readdirSync(searchDir, {"withFileTypes": True});
            suggestions: list[any] = [];
            for entry_j in entries {
                if not entry_j.name.lower().startswith(searchPrefix.lower()) {
                    continue;
                }
                isDirectory = entry_j.isDirectory();
                if (not isDirectory and entry_j.isSymbolicLink()) {
                    try {
                        fullPath = join(searchDir, entry_j.name);
                        isDirectory = statSync(fullPath).isDirectory();
                    }
                    except Exception {
                    }
                }
                relativePath: str;
                name = entry_j.name;
                displayPrefix = rawPrefix;
                if displayPrefix.endswith("/") {
                    relativePath = (displayPrefix + name);
                }
                elif (("/" in displayPrefix) or ("\\" in displayPrefix)) {
                    if displayPrefix.startswith("~/") {
                        homeRelativeDir = displayPrefix[2:];
                        dir = dirname(homeRelativeDir);
                        relativePath = f"~/{(name if (dir == ".") else join(dir, name))}";
                    }
                    elif displayPrefix.startswith("/") {
                        dir = dirname(displayPrefix);
                        if (dir == "/") {
                            relativePath = f"/{name}";
                        }
                        else {
                            relativePath = f"{dir}/{name}";
                        }
                    }
                    else {
                        relativePath = join(dirname(displayPrefix), name);
                        if (displayPrefix.startswith("./") and not relativePath.startswith("./")) {
                            relativePath = f"./{relativePath}";
                        }
                    }
                }
                else {
                    if displayPrefix.startswith("~") {
                        relativePath = f"~/{name}";
                    }
                    else {
                        relativePath = name;
                    }
                }
                relativePath = toDisplayPath(relativePath);
                pathValue = (f"{relativePath}/" if isDirectory else relativePath);
                value = buildCompletionValue(pathValue, {"isDirectory": isDirectory, "isAtPrefix": isAtPrefix, "isQuotedPrefix": isQuotedPrefix});
                suggestions.append({"value": value, "label": (name + ("/" if isDirectory else ""))});
            }
            suggestions.sort(lambda (a: any, b: any) -> any { aIsDir: str = a.value.endswith("/"); bIsDir: str = b.value.endswith("/"); if (aIsDir and not bIsDir) {     return -1; } if (not aIsDir and bIsDir) {     return 1; } return a.label.localeCompare(b.label); });
            return suggestions;
        }
        except Exception as _e {
            return [];
        }
    }
    def scoreEntry(filePath: str, query: str, isDirectory: bool) -> float {
        fileName = basename(filePath);
        lowerFileName: str = fileName.lower();
        lowerQuery: str = query.lower();
        score = 0;
        if (lowerFileName == lowerQuery) {
            score = 100;
        }
        elif lowerFileName.startswith(lowerQuery) {
            score = 80;
        }
        elif (lowerQuery in lowerFileName) {
            score = 50;
        }
        elif (lowerQuery in filePath.lower()) {
            score = 30;
        }
        if (isDirectory and (score > 0)) {
            score += 10;
        }
        return score;
    }
    async def getFuzzyFileSuggestions(query: str, options: dict[str, bool | any]) -> any {
        if (not self.fdPath or options.signal.aborted) {
            return [];
        }
        try {
            scopedQuery = self.resolveScopedFuzzyQuery(query);
            fdBaseDir = ((lambda (_jx_null6: any) -> any { return (_jx_null6 if _jx_null6 is not None else self.basePath); })(((lambda (_jx_opt5: any) -> any { return (_jx_opt5.baseDir if _jx_opt5 is not None else None); })(scopedQuery))));
            fdQuery = ((lambda (_jx_null8: any) -> any { return (_jx_null8 if _jx_null8 is not None else query); })(((lambda (_jx_opt7: any) -> any { return (_jx_opt7.query if _jx_opt7 is not None else None); })(scopedQuery))));
            entries = await walkDirectoryWithFd(fdBaseDir, self.fdPath, fdQuery, 100, options.signal);
            if options.signal.aborted {
                return [];
            }
            scoredEntries = [entry_j for entry_j in [{**entry_j, "score": (self.scoreEntry(entry_j.path, fdQuery, entry_j.isDirectory) if fdQuery else 1)} for entry in entries] if (entry_j.score > 0)];
            scoredEntries.sort(key=lambda (_jx_sort: any) -> any { return _jx_sort["score"]; }, reverse=True);
            topEntries = scoredEntries[0:20];
            suggestions: list[any] = [];
            for _jx_item0 in topEntries {
                entryPath = _jx_item0.path;
                isDirectory = _jx_item0.isDirectory;
                pathWithoutSlash = (entryPath[0:-1] if isDirectory else entryPath);
                displayPath = (self.scopedPathForDisplay(scopedQuery.displayBase, pathWithoutSlash) if scopedQuery else pathWithoutSlash);
                entryName = basename(pathWithoutSlash);
                completionPath = (f"{displayPath}/" if isDirectory else displayPath);
                value = buildCompletionValue(completionPath, {"isDirectory": isDirectory, "isAtPrefix": True, "isQuotedPrefix": options.isQuotedPrefix});
                suggestions.append({"value": value, "label": (entryName + ("/" if isDirectory else "")), "description": displayPath});
            }
            return suggestions;
        }
        except Exception {
            return [];
        }
    }
    def shouldTriggerFileCompletion(lines: list[str], cursorLine: float, cursorCol: float) -> bool {
        currentLine = (lines[cursorLine] or "");
        textBeforeCursor = currentLine[0:cursorCol];
        if (textBeforeCursor.strip().startswith("/") and not (" " in textBeforeCursor.strip())) {
            return False;
        }
        return True;
    }
}
