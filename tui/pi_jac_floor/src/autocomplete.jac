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
    # JS2JAC-HOLE[E7205] Class method produced no output:
    # | async getSuggestions(
    # | 		lines: string[],
    # | 		cursorLine: number,
    # | 		cursorCol: number,
    # | 		options: { signal: AbortSignal; force?: boolean },
    # | 	): Promise<AutocompleteSuggestions | null> {
    # | 		const currentLine = lines[cursorLine] || "";
    # | 		const textBeforeCursor = currentLine.slice(0, cursorCol);
    # | 
    # | 		const atPrefix = this.extractAtPrefix(textBeforeCursor);
    # | 		if (atPrefix) {
    # | 			const { rawPrefix, isQuotedPrefix } = parsePathPrefix(atPrefix);
    # | 			const suggestions = await this.getFuzzyFileSuggestions(rawPrefix, {
    # | 				isQuotedPrefix,
    # | 				signal: options.signal,
    # | 			});
    # | 			if (suggestions.length === 0) return null;
    # | 
    # | 			return {
    # | 				items: suggestions,
    # | 				prefix: atPrefix,
    # | 			};
    # | 		}
    # | 
    # | 		if (!options.force && textBeforeCursor.startsWith("/")) {
    # | 			const spaceIndex = textBeforeCursor.indexOf(" ");
    # | 
    # | 			if (spaceIndex === -1) {
    # | 				const prefix = textBeforeCursor.slice(1);
    # | 				const commandItems = this.commands.map((cmd) => {
    # | 					const name = "name" in cmd ? cmd.name : cmd.value;
    # | 					const hint = "argumentHint" in cmd && cmd.argumentHint ? cmd.argumentHint : undefined;
    # | 					const desc = cmd.description ?? "";
    # | 					const fullDesc = hint ? (desc ? `${hint} — ${desc}` : hint) : desc;
    # | 					return {
    # | 						name,
    # | 						label: name,
    # | 						description: fullDesc || undefined,
    # | 					};
    # | 				});
    # | 
    # | 				const filtered = fuzzyFilter(commandItems, prefix, (item) => item.name).map((item) => ({
    # | 					value: item.name,
    # | 					label: item.label,
    # | 					...(item.description && { description: item.description }),
    # | 				}));
    # | 
    # | 				if (filtered.length === 0) return null;
    # | 
    # | 				return {
    # | 					items: filtered,
    # | 					prefix: textBeforeCursor,
    # | 				};
    # | 			}
    # | 
    # | 			const commandName = textBeforeCursor.slice(1, spaceIndex);
    # | 			const argumentText = textBeforeCursor.slice(spaceIndex + 1);
    # | 
    # | 			const command = this.commands.find((cmd) => {
    # | 				const name = "name" in cmd ? cmd.name : cmd.value;
    # | 				return name === commandName;
    # | 			});
    # | 			if (!command || !("getArgumentCompletions" in command) || !command.getArgumentCompletions) {
    # | 				return null;
    # | 			}
    # | 
    # | 			const argumentSuggestions = await command.getArgumentCompletions(argumentText);
    # | 			if (!Array.isArray(argumentSuggestions) || argumentSuggestions.length === 0) {
    # | 				return null;
    # | 			}
    # | 
    # | 			return {
    # | 				items: argumentSuggestions,
    # | 				prefix: argumentText,
    # | 			};
    # | 		}
    # | 
    # | 		const pathMatch = this.extractPathPrefix(textBeforeCursor, options.force ?? false);
    # | 		if (pathMatch === null) {
    # | 			return null;
    # | 		}
    # | 
    # | 		const suggestions = this.getFileSuggestions(pathMatch);
    # | 		if (suggestions.length === 0) return null;
    # | 
    # | 		return {
    # | 			items: suggestions,
    # | 			prefix: pathMatch,
    # | 		};
    # | 	}
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
        if ((lambda (_jx_opt2: any) -> any { return (_jx_opt2.startsWith("@\"") if _jx_opt2 is not None else None); })(quotedPrefix)) {
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
            fdBaseDir = ((lambda (_jx_null4: any) -> any { return (_jx_null4 if _jx_null4 is not None else self.basePath); })(((lambda (_jx_opt3: any) -> any { return (_jx_opt3.baseDir if _jx_opt3 is not None else None); })(scopedQuery))));
            fdQuery = ((lambda (_jx_null6: any) -> any { return (_jx_null6 if _jx_null6 is not None else query); })(((lambda (_jx_opt5: any) -> any { return (_jx_opt5.query if _jx_opt5 is not None else None); })(scopedQuery))));
            # JS2JAC-HOLE[E7215] `this` is not supported (component helpers must not rely on receiver binding):
            # | const entries = await walkDirectoryWithFd(fdBaseDir, this.fdPath, fdQuery, 100, options.signal);
            if options.signal.aborted {
                return [];
            }
            # JS2JAC-HOLE[transitive-stmt] references dropped binding 'entries':
            # | const scoredEntries = entries
            # | 				.map((entry) => ({
            # | 					...entry,
            # | 					score: fdQuery ? this.scoreEntry(entry.path, fdQuery, entry.isDirectory) : 1,
            # | 				}))
            # | 				.filter((entry) => entry.score > 0);
            # JS2JAC-HOLE[transitive-stmt] references dropped binding 'scoredEntries':
            # | scoredEntries.sort((a, b) => b.score - a.score);
            # JS2JAC-HOLE[transitive-stmt] references dropped binding 'scoredEntries':
            # | const topEntries = scoredEntries.slice(0, 20);
            suggestions: list[any] = [];
            # JS2JAC-HOLE[transitive-stmt] references dropped binding 'topEntries':
            # | for (const { path: entryPath, isDirectory } of topEntries) {
            # | 				const pathWithoutSlash = isDirectory ? entryPath.slice(0, -1) : entryPath;
            # | 				const displayPath = scopedQuery
            # | 					? this.scopedPathForDisplay(scopedQuery.displayBase, pathWithoutSlash)
            # | 					: pathWithoutSlash;
            # | 				const entryName = basename(pathWithoutSlash);
            # | 				const completionPath = isDirectory ? `${displayPath}/` : displayPath;
            # | 				const value = buildCompletionValue(completionPath, {
            # | 					isDirectory,
            # | 					isAtPrefix: true,
            # | 					isQuotedPrefix: options.isQuotedPrefix,
            # | 				});
            # | 
            # | 				suggestions.push({
            # | 					value,
            # | 					label: entryName + (isDirectory ? "/" : ""),
            # | 					description: displayPath,
            # | 				});
            # | 			}
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
