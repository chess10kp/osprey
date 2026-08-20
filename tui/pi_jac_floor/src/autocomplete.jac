"""Command/path/fuzzy-file autocomplete, ported from pi-tui's autocomplete.ts.

Async/subprocess note: the original `walkDirectoryWithFd` shelled out via
Node's `child_process.spawn`, wired to an `AbortSignal` through a `Promise`,
and callers awaited it. A headless `jac run` has no ambient event loop to
drive that dance, so this port makes the whole fd-walk path SYNCHRONOUS:
`walkDirectoryWithFd` and `getFuzzyFileSuggestions`/`getSuggestions` are plain
`def`s that call `autocomplete_support.run_fd`, a `subprocess.run(...,
timeout=...)` wrapper. Any failure -- missing `fd` binary, non-zero exit,
timeout, or an already-aborted `signal` -- yields `[]`, preserving the
observable contract without needing Promises or async/await. `signal.aborted`
is still honored (checked before and after the run) and `AbortController`/
`AbortSignal` (from `.input_support`) remain the public cancellation surface;
the listener-based `child.kill()` path is unnecessary since `run_fd`'s own
timeout already bounds the subprocess.
"""

import from .fuzzy { fuzzyFilter }
import from re { sub }
import from .input_support { AbortSignal }
import from .autocomplete_support { readdirSync, statSync, homedir, basename, dirname, join, run_fd }

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
        return normalized;
    }
    hasTrailingSeparator: bool = normalized.endswith("/");
    trimmed = sub(r"^\/+|\/+$", "", normalized);
    if not trimmed {
        return normalized;
    }
    separatorPattern: str = "[\\\\/]";
    segments = [escapeRegex(segment) for segment in trimmed.split("/") if segment];
    if len(segments) == 0 {
        return normalized;
    }
    pattern: str = separatorPattern.join(segments);
    if hasTrailingSeparator {
        pattern += separatorPattern;
    }
    return pattern;
}

def findLastDelimiter(text: str) -> int {
    i: int = len(text) - 1;
    while i >= 0 {
        if text[i] in PATH_DELIMITERS {
            return i;
        }
        i -= 1;
    }
    return -1;
}

def findUnclosedQuoteStart(text: str) -> int | None {
    inQuotes: bool = False;
    quoteStart: int = -1;
    i: int = 0;
    while i < len(text) {
        if text[i] == "\"" {
            inQuotes = not inQuotes;
            if inQuotes {
                quoteStart = i;
            }
        }
        i += 1;
    }
    return (quoteStart if inQuotes else None);
}

def isTokenStart(text: str, index: int) -> bool {
    return (index == 0) or (text[index - 1] in PATH_DELIMITERS);
}

def extractQuotedPrefix(text: str) -> str | None {
    quoteStart = findUnclosedQuoteStart(text);
    if quoteStart is None {
        return None;
    }
    if (quoteStart > 0) and (text[quoteStart - 1] == "@") {
        if not isTokenStart(text, quoteStart - 1) {
            return None;
        }
        return text[quoteStart - 1:];
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
    needsQuotes = (options["isQuotedPrefix"] or (" " in path));
    prefix = ("@" if options["isAtPrefix"] else "");
    if not needsQuotes {
        return f"{prefix}{path}";
    }
    openQuote: str = f"{prefix}\"";
    closeQuote: str = "\"";
    return f"{openQuote}{path}{closeQuote}";
}

def walkDirectoryWithFd(baseDir: str, fdPath: str, query: str, maxResults: int, signal: AbortSignal | None) -> list[dict[str, str | bool]] {
    if (signal is not None) and signal.aborted {
        return [];
    }
    args: list[str] = ["--base-directory", baseDir, "--max-results", str(maxResults), "--type", "f", "--type", "d", "--follow", "--hidden", "--exclude", ".git", "--exclude", ".git/*", "--exclude", ".git/**"];
    if "/" in toDisplayPath(query) {
        args.append("--full-path");
    }
    if query {
        args.append(buildFdPathQuery(query));
    }
    run = run_fd(fdPath, args, 2.0);
    if (signal is not None) and signal.aborted {
        return [];
    }
    if not (run["ok"] as bool) {
        return [];
    }
    stdout = (run["stdout"] as str);
    if not stdout {
        return [];
    }
    lines = [line for line in stdout.strip().split("\n") if line];
    results: list[dict[str, str | bool]] = [];
    for line in lines {
        displayLine = toDisplayPath(line);
        hasTrailingSeparator: bool = displayLine.endswith("/");
        normalizedPath = (displayLine[0:-1] if hasTrailingSeparator else displayLine);
        if (normalizedPath == ".git") or normalizedPath.startswith(".git/") or ("/.git/" in normalizedPath) {
            continue;
        }
        results.append({"path": displayLine, "isDirectory": hasTrailingSeparator});
    }
    return results;
}

obj:pub CombinedAutocompleteProvider {
    has basePath: str;
    has commands: list[any] = [];
    has fdPath: str | None = None;

    def __init__(basePath: str, commands: list[any] = [], fdPath: str | None = None) -> None {
        self.basePath = basePath;
        self.commands = commands;
        self.fdPath = fdPath;
    }

    def getSuggestions(lines: list[str], cursorLine: int, cursorCol: int, options: dict[str, any]) -> dict[str, any] | None {
        currentLine = (lines[cursorLine] or "");
        textBeforeCursor = currentLine[0:cursorCol];
        atPrefix = self.extractAtPrefix(textBeforeCursor);
        if atPrefix {
            parsed = parsePathPrefix(atPrefix);
            rawPrefix = (parsed["rawPrefix"] as str);
            isQuotedPrefix = (parsed["isQuotedPrefix"] as bool);
            suggestions = self.getFuzzyFileSuggestions(rawPrefix, {"isQuotedPrefix": isQuotedPrefix, "signal": options.get("signal")});
            if len(suggestions) == 0 {
                return None;
            }
            return {"items": suggestions, "prefix": atPrefix};
        }
        if (not options.get("force")) and textBeforeCursor.startswith("/") {
            spaceIndex = (-1 if " " not in textBeforeCursor else textBeforeCursor.index(" "));
            if spaceIndex == -1 {
                prefix = textBeforeCursor[1:];
                commandItems = [];
                for cmd_j in self.commands {
                    cmd: dict[str, any] = cmd_j;
                    name = (cmd["name"] if ("name" in cmd) else cmd["value"]);
                    hint = (cmd.get("argumentHint") if (("argumentHint" in cmd) and cmd.get("argumentHint")) else None);
                    desc = (cmd.get("description") if cmd.get("description") is not None else "");
                    fullDesc = ((f"{hint} — {desc}" if desc else hint) if hint else desc);
                    commandItems.append({"name": name, "label": name, "description": (fullDesc or None)});
                }
                filtered = [];
                getCommandName = lambda (ci: any) -> str { return (ci["name"] as str); };
                for matched in fuzzyFilter(commandItems, prefix, getCommandName) {
                    filteredItem: dict[str, any] = {"value": matched["name"], "label": matched["label"]};
                    if matched.get("description") {
                        filteredItem["description"] = matched["description"];
                    }
                    filtered.append(filteredItem);
                }
                if len(filtered) == 0 {
                    return None;
                }
                return {"items": filtered, "prefix": textBeforeCursor};
            }
            commandName = textBeforeCursor[1:spaceIndex];
            argumentText = textBeforeCursor[spaceIndex + 1:];
            command: dict[str, any] | None = None;
            for cmd_j in self.commands {
                cmd: dict[str, any] = cmd_j;
                cmdName = (cmd["name"] if ("name" in cmd) else cmd["value"]);
                if cmdName == commandName {
                    command = cmd;
                    break;
                }
            }
            if (command is None) or (not ("getArgumentCompletions" in command)) or (not command.get("getArgumentCompletions")) {
                return None;
            }
            argumentSuggestions = command["getArgumentCompletions"](argumentText);
            if (not isinstance(argumentSuggestions, list)) or (len(argumentSuggestions) == 0) {
                return None;
            }
            return {"items": argumentSuggestions, "prefix": argumentText};
        }
        pathMatch = self.extractPathPrefix(textBeforeCursor, bool(options.get("force")));
        if pathMatch is None {
            return None;
        }
        suggestions = self.getFileSuggestions(pathMatch);
        if len(suggestions) == 0 {
            return None;
        }
        return {"items": suggestions, "prefix": pathMatch};
    }

    def applyCompletion(lines: list[str], cursorLine: int, cursorCol: int, item: dict[str, any], prefix: str) -> dict[str, any] {
        currentLine = (lines[cursorLine] or "");
        beforePrefix = currentLine[0:cursorCol - len(prefix)];
        afterCursor = currentLine[cursorCol:];
        isQuotedPrefix = (prefix.startswith("\"") or prefix.startswith("@\""));
        hasLeadingQuoteAfterCursor: bool = afterCursor.startswith("\"");
        itemValue = (item["value"] as str);
        hasTrailingQuoteInItem: bool = itemValue.endswith("\"");
        adjustedAfterCursor = (afterCursor[1:] if (isQuotedPrefix and hasTrailingQuoteInItem and hasLeadingQuoteAfterCursor) else afterCursor);
        isSlashCommand = (prefix.startswith("/") and (beforePrefix.strip() == "") and not ("/" in prefix[1:]));
        itemLabel = (item["label"] as str);
        if isSlashCommand {
            newLine: str = f"{beforePrefix}/{itemValue} {adjustedAfterCursor}";
            newLines = [*lines];
            newLines[cursorLine] = newLine;
            return {"lines": newLines, "cursorLine": cursorLine, "cursorCol": len(beforePrefix) + len(itemValue) + 2};
        }
        if prefix.startswith("@") {
            isDirectory: bool = itemLabel.endswith("/");
            suffix = ("" if isDirectory else " ");
            newLine: str = f"{beforePrefix + itemValue}{suffix}{adjustedAfterCursor}";
            newLines = [*lines];
            newLines[cursorLine] = newLine;
            hasTrailingQuote: bool = itemValue.endswith("\"");
            cursorOffset = (len(itemValue) - 1 if (isDirectory and hasTrailingQuote) else len(itemValue));
            return {"lines": newLines, "cursorLine": cursorLine, "cursorCol": len(beforePrefix) + cursorOffset + len(suffix)};
        }
        textBeforeCursor = currentLine[0:cursorCol];
        newLine = beforePrefix + itemValue + adjustedAfterCursor;
        newLines = [*lines];
        newLines[cursorLine] = newLine;
        isDirectory: bool = itemLabel.endswith("/");
        hasTrailingQuote: bool = itemValue.endswith("\"");
        cursorOffset = (len(itemValue) - 1 if (isDirectory and hasTrailingQuote) else len(itemValue));
        return {"lines": newLines, "cursorLine": cursorLine, "cursorCol": len(beforePrefix) + cursorOffset};
    }

    def extractAtPrefix(text: str) -> str | None {
        quotedPrefix = extractQuotedPrefix(text);
        if (quotedPrefix is not None) and quotedPrefix.startswith("@\"") {
            return quotedPrefix;
        }
        lastDelimiterIndex: int = findLastDelimiter(text);
        tokenStart: int = (0 if (lastDelimiterIndex == -1) else lastDelimiterIndex + 1);
        if (tokenStart < len(text)) and (text[tokenStart] == "@") {
            return text[tokenStart:];
        }
        return None;
    }

    def extractPathPrefix(text: str, forceExtract: bool = False) -> str | None {
        quotedPrefix = extractQuotedPrefix(text);
        if quotedPrefix {
            return quotedPrefix;
        }
        lastDelimiterIndex: int = findLastDelimiter(text);
        pathPrefix = (text if (lastDelimiterIndex == -1) else text[lastDelimiterIndex + 1:]);
        if forceExtract {
            return pathPrefix;
        }
        if ("/" in pathPrefix) or pathPrefix.startswith(".") or pathPrefix.startswith("~/") {
            return pathPrefix;
        }
        if (pathPrefix == "") and text.endswith(" ") {
            return pathPrefix;
        }
        return None;
    }

    def expandHomePath(path: str) -> str {
        if path.startswith("~/") {
            expandedPath = join(homedir(), path[2:]);
            return (f"{expandedPath}/" if (path.endswith("/") and not expandedPath.endswith("/")) else expandedPath);
        } elif path == "~" {
            return homedir();
        }
        return path;
    }

    def resolveScopedFuzzyQuery(rawQuery: str) -> dict[str, str] | None {
        normalizedQuery = toDisplayPath(rawQuery);
        slashIndex = normalizedQuery.rfind("/");
        if slashIndex == -1 {
            return None;
        }
        displayBase = normalizedQuery[0:slashIndex + 1];
        query = normalizedQuery[slashIndex + 1:];
        baseDir: str;
        if displayBase.startswith("~/") {
            baseDir = self.expandHomePath(displayBase);
        } elif displayBase.startswith("/") {
            baseDir = displayBase;
        } else {
            baseDir = join(self.basePath, displayBase);
        }
        try {
            if not statSync(baseDir).isDirectory() {
                return None;
            }
        } except Exception {
            return None;
        }
        return {"baseDir": baseDir, "query": query, "displayBase": displayBase};
    }

    def scopedPathForDisplay(displayBase: str, relativePath: str) -> str {
        normalizedRelativePath = toDisplayPath(relativePath);
        if displayBase == "/" {
            return f"/{normalizedRelativePath}";
        }
        return f"{toDisplayPath(displayBase)}{normalizedRelativePath}";
    }

    def getFileSuggestions(prefix: str) -> list[dict[str, str]] {
        try {
            searchDir: str;
            searchPrefix: str;
            parsed = parsePathPrefix(prefix);
            rawPrefix = (parsed["rawPrefix"] as str);
            isAtPrefix = (parsed["isAtPrefix"] as bool);
            isQuotedPrefix = (parsed["isQuotedPrefix"] as bool);
            expandedPrefix = rawPrefix;
            if expandedPrefix.startswith("~") {
                expandedPrefix = self.expandHomePath(expandedPrefix);
            }
            isRootPrefix = (rawPrefix == "") or (rawPrefix == "./") or (rawPrefix == "../") or (rawPrefix == "~") or (rawPrefix == "~/") or (rawPrefix == "/") or (isAtPrefix and (rawPrefix == ""));
            if isRootPrefix {
                if rawPrefix.startswith("~") or expandedPrefix.startswith("/") {
                    searchDir = expandedPrefix;
                } else {
                    searchDir = join(self.basePath, expandedPrefix);
                }
                searchPrefix = "";
            } elif rawPrefix.endswith("/") {
                if rawPrefix.startswith("~") or expandedPrefix.startswith("/") {
                    searchDir = expandedPrefix;
                } else {
                    searchDir = join(self.basePath, expandedPrefix);
                }
                searchPrefix = "";
            } else {
                dir = dirname(expandedPrefix);
                file = basename(expandedPrefix);
                if rawPrefix.startswith("~") or expandedPrefix.startswith("/") {
                    searchDir = dir;
                } else {
                    searchDir = join(self.basePath, dir);
                }
                searchPrefix = file;
            }
            entries = readdirSync(searchDir, {"withFileTypes": True});
            suggestions: list[dict[str, str]] = [];
            for entry_j in entries {
                if not entry_j.name.lower().startswith(searchPrefix.lower()) {
                    continue;
                }
                isDirectory = entry_j.isDirectory();
                if (not isDirectory) and entry_j.isSymbolicLink() {
                    try {
                        fullPath = join(searchDir, entry_j.name);
                        isDirectory = statSync(fullPath).isDirectory();
                    } except Exception {
                    }
                }
                relativePath: str;
                name = entry_j.name;
                displayPrefix = rawPrefix;
                if displayPrefix.endswith("/") {
                    relativePath = displayPrefix + name;
                } elif ("/" in displayPrefix) or ("\\" in displayPrefix) {
                    if displayPrefix.startswith("~/") {
                        homeRelativeDir = displayPrefix[2:];
                        dir = dirname(homeRelativeDir);
                        relativePath = f"~/{(name if (dir == '.') else join(dir, name))}";
                    } elif displayPrefix.startswith("/") {
                        dir = dirname(displayPrefix);
                        if dir == "/" {
                            relativePath = f"/{name}";
                        } else {
                            relativePath = f"{dir}/{name}";
                        }
                    } else {
                        relativePath = join(dirname(displayPrefix), name);
                        if displayPrefix.startswith("./") and not relativePath.startswith("./") {
                            relativePath = f"./{relativePath}";
                        }
                    }
                } else {
                    if displayPrefix.startswith("~") {
                        relativePath = f"~/{name}";
                    } else {
                        relativePath = name;
                    }
                }
                relativePath = toDisplayPath(relativePath);
                pathValue = (f"{relativePath}/" if isDirectory else relativePath);
                value = buildCompletionValue(pathValue, {"isDirectory": isDirectory, "isAtPrefix": isAtPrefix, "isQuotedPrefix": isQuotedPrefix});
                suggestions.append({"value": value, "label": name + ("/" if isDirectory else "")});
            }

            def sortKey(sugg: dict[str, str]) -> tuple {
                isDir = sugg["value"].endswith("/");
                return (0 if isDir else 1, sugg["label"].lower());
            }
            suggestions.sort(key=sortKey);
            return suggestions;
        } except Exception {
            return [];
        }
    }

    def scoreEntry(filePath: str, query: str, isDirectory: bool) -> int {
        fileName = basename(filePath);
        lowerFileName: str = fileName.lower();
        lowerQuery: str = query.lower();
        score = 0;
        if lowerFileName == lowerQuery {
            score = 100;
        } elif lowerFileName.startswith(lowerQuery) {
            score = 80;
        } elif lowerQuery in lowerFileName {
            score = 50;
        } elif lowerQuery in filePath.lower() {
            score = 30;
        }
        if isDirectory and (score > 0) {
            score += 10;
        }
        return score;
    }

    def getFuzzyFileSuggestions(query: str, options: dict[str, any]) -> list[dict[str, str]] {
        signal = options.get("signal");
        if (not self.fdPath) or ((signal is not None) and signal.aborted) {
            return [];
        }
        try {
            scopedQuery = self.resolveScopedFuzzyQuery(query);
            fdBaseDir = (scopedQuery["baseDir"] if scopedQuery is not None else self.basePath);
            fdQuery = (scopedQuery["query"] if scopedQuery is not None else query);
            entries = walkDirectoryWithFd(fdBaseDir, self.fdPath, fdQuery, 100, signal);
            if (signal is not None) and signal.aborted {
                return [];
            }
            scoredEntries = [];
            for entry in entries {
                score = (self.scoreEntry((entry["path"] as str), fdQuery, (entry["isDirectory"] as bool)) if fdQuery else 1);
                if score > 0 {
                    scoredEntries.append({**entry, "score": score});
                }
            }
            scoredEntries.sort(key=lambda (e: any) -> int { return -(e["score"] as int); });
            topEntries = scoredEntries[0:20];
            isQuotedPrefix = bool(options.get("isQuotedPrefix"));
            suggestions: list[dict[str, str]] = [];
            for entry_j in topEntries {
                entryPath = (entry_j["path"] as str);
                isDirectory = (entry_j["isDirectory"] as bool);
                pathWithoutSlash = (entryPath[0:-1] if isDirectory else entryPath);
                displayPath = (self.scopedPathForDisplay((scopedQuery["displayBase"] as str), pathWithoutSlash) if scopedQuery is not None else pathWithoutSlash);
                entryName = basename(pathWithoutSlash);
                completionPath = (f"{displayPath}/" if isDirectory else displayPath);
                value = buildCompletionValue(completionPath, {"isDirectory": isDirectory, "isAtPrefix": True, "isQuotedPrefix": isQuotedPrefix});
                suggestions.append({"value": value, "label": entryName + ("/" if isDirectory else ""), "description": displayPath});
            }
            return suggestions;
        } except Exception {
            return [];
        }
    }

    def shouldTriggerFileCompletion(lines: list[str], cursorLine: int, cursorCol: int) -> bool {
        currentLine = (lines[cursorLine] or "");
        textBeforeCursor = currentLine[0:cursorCol];
        if textBeforeCursor.strip().startswith("/") and not (" " in textBeforeCursor.strip()) {
            return False;
        }
        return True;
    }
}
