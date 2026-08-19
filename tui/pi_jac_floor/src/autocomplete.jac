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
    return ((index == 0) or PATH_DELIMITERS.has((text[(index - 1)] if text[(index - 1)] is not None else "")));
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

# ===== JS2JAC UNCONVERTED (1 decl(s), needs LLM) =====
# JS2JAC-HOLE[E7200] Declaration produced no output:
# | function findLastDelimiter(text: string): number {
# | 	for (let i = text.length - 1; i >= 0; i -= 1) {
# | 		if (PATH_DELIMITERS.has(text[i] ?? "")) {
# | 			return i;
# | 		}
# | 	}
# | 	return -1;
# | }
