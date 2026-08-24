"""Web search + fetch tools - parity with src/agent/web-tools.ts.

Pure stdlib (urllib.request / urllib.parse + re + json), no new pip deps,
so this lowers in the server codespace like agent/tools.jac. Search backend:
the DuckDuckGo HTML endpoint (no API key, browser-y User-Agent). Both tools
fail loud {"ok": false}-style JSON strings instead of raising across the seam.

The Jac importer resolves web_tools.test.jac as the same-stem annex of this
module (plugin_hooks_events.jac pattern), so the offline test harness imports
(socket, threading) live here alongside the runtime imports.
"""

import re;
import json;
import html;
import os;
import socket;
import threading;
import urllib.parse;
import urllib.request;
import from .tool_spec { MAX_TOOL_RESULT }

glob WEB_TIMEOUT_SECS: int = 15,
     FETCH_BODY_CAP: int = MAX_TOOL_RESULT,
     DEFAULT_SEARCH_RESULTS: int = 5,
     MAX_FETCH_RESULTS: int = 20,
     SEARCH_USER_AGENT: str = (
         "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 "
         "(KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36"
     );


"""Validate an http(s) URL; reject everything else (no file://, no data:).
Returns ("", error_message) on failure."""
def validate_web_url(raw: str) -> tuple {
    url = (raw or "").strip();
    if not url {
        return ("", "url is required");
    }
    parsed = urllib.parse.urlparse(url);
    if parsed.scheme not in ("http", "https") {
        scheme = parsed.scheme if parsed.scheme else "none";
        return ("", f"Only http(s) URLs are allowed (got scheme '{scheme}'): {url}");
    }
    if not parsed.netloc {
        return ("", f"Invalid URL (missing host): {url}");
    }
    return (url, "");
}
sem validate_web_url = "Reject non-http(s) URLs before any network I/O.";

"""Decode a DuckDuckGo outbound link into the real target URL."""
def _decode_ddg_href(href_attr: str) -> str {
    href: str = html.unescape(str(href_attr).strip());
    if href.startswith("//") {
        href = "https:" + href;
    }
    m = re.search(r"[?&]uddg=([^&]+)", href);
    if m is not None {
        href = urllib.parse.unquote(m.group(1));
    }
    return href;
}

"""Strip script/style blocks, comments, and tags down to readable text."""
def strip_html(page: str) -> str {
    t: str = str(page);
    t = re.sub(r"(?is)<(script|style)[^>]*>.*?</\1>", " ", t);
    t = re.sub(r"(?s)<!--.*?-->", " ", t);
    t = re.sub(r"(?s)<[^>]*>", " ", t);
    t = html.unescape(t);
    t = re.sub(r"[ \t\r\f\v]+", " ", t);
    t = re.sub(r"\s*\n\s*", "\n", t);
    t = re.sub(r"\n{3,}", "\n\n", t);
    return t.strip();
}
sem strip_html = "Regex-based HTML-to-text extraction (scripts/styles removed first).";

"""Cap tool output at the shared MAX_TOOL_RESULT convention."""
def truncate_result(text: str, cap: int = FETCH_BODY_CAP) -> str {
    body = str(text);
    if len(body) <= cap {
        return body;
    }
    return body[:cap] + "\n\n... [truncated]";
}

"""Extract the <title> of an HTML document, empty string when absent."""
def _extract_title(page: str) -> str {
    m = re.search(r"(?is)<title[^>]*>(.*?)</title>", str(page));
    if m is None {
        return "";
    }
    return strip_html(m.group(1));
}


"""web_search tool: top DDG hits as 'N. Title / URL: ... / snippet' lines.
Never raises; failures come back as {"ok": false, "error": ...} JSON."""
def web_search(query: str, num_results: int = DEFAULT_SEARCH_RESULTS) -> str {
    q = (query or "").strip();
    if not q {
        return json.dumps({"ok": False, "error": "query is required"});
    }
    n = max(1, min(int(num_results), MAX_FETCH_RESULTS));
    try {
        endpoint = "https://html.duckduckgo.com/html/?" + urllib.parse.urlencode({"q": q});
        req = urllib.request.Request(endpoint, headers={"User-Agent": SEARCH_USER_AGENT});
        resp = urllib.request.urlopen(req, timeout=WEB_TIMEOUT_SECS);
        page = resp.read(FETCH_BODY_CAP * 4).decode("utf-8", errors="replace");
        resp.close();

        # Result anchors: <a class="result__a" href="...">Title</a>
        anchors = re.findall(
            r'(?is)<a\s([^>]*class="result__a"[^>]*)>(.*?)</a>', page
        );
        snippets = re.findall(
            r'(?is)<(?:a|td|div)[^>]*class="[^"]*result__snippet[^"]*"[^>]*>(.*?)</(?:a|td|div)>',
            page,
        );
        results: list[tuple] = [];
        seen_urls: set = set();
        for entry in enumerate(anchors) {
            idx = int(entry[0]);
            pair = entry[1];
            attrs = str(pair[0]);
            title = strip_html(pair[1]);
            href_m = re.search(r'href="([^"]+)"', attrs);
            if href_m is None or not title {
                continue;
            }
            url = _decode_ddg_href(href_m.group(1));
            if not url.startswith("http") or url in seen_urls {
                continue;
            }
            seen_urls.add(url);
            snippet = strip_html(snippets[idx]) if idx < len(snippets) else "";
            results.append((title, url, snippet));
            if len(results) >= n {
                break;
            }
        }
        if not results {
            return "No results found.";
        }
        blocks: list[str] = [];
        for hit_entry in enumerate(results) {
            i = int(hit_entry[0]);
            hit = hit_entry[1];
            lines = [f"{i + 1}. {hit[0]}", f"   URL: {hit[1]}"];
            if hit[2] {
                lines.append(f"   {hit[2]}");
            }
            blocks.append("\n".join(lines));
        }
        return truncate_result("\n\n".join(blocks));
    } except Exception as e {
        return json.dumps({"ok": False, "error": f"Search failed for '{q}': {e}"});
    }
}
sem web_search = "Search the web (DuckDuckGo HTML backend) and return the top results with titles, URLs, and snippets. Use for docs, releases, and facts not in the repo.";
sem web_search.query = "Search query.";
sem web_search.num_results = "Max results to return (default 5, capped at 20).";


"""web_fetch tool: fetch an http(s) page and return readable stripped text.
Body is capped after decode; never raises across the seam."""
def web_fetch(url: str) -> str {
    vr = validate_web_url(url);
    target = str(vr[0]);
    err = str(vr[1]);
    if err {
        return json.dumps({"ok": False, "error": err});
    }
    try {
        req = urllib.request.Request(target, headers={"User-Agent": SEARCH_USER_AGENT});
        resp = urllib.request.urlopen(req, timeout=WEB_TIMEOUT_SECS);
        raw = resp.read(FETCH_BODY_CAP * 4);
        ctype = str(resp.headers.get("Content-Type", ""));
        resp.close();
        text = raw.decode("utf-8", errors="replace");
        looks_html = "html" in ctype.lower() or bool(
            re.search(r"(?i)<html|<body|<div|<!doctype", text[:2000])
        );
        header = "";
        if looks_html {
            title = _extract_title(text);
            if title {
                header = f"# {title}\n\n";
            }
            text = strip_html(text);
        }
        if not text.strip() {
            return json.dumps({"ok": False, "error": f"Fetched {target} but it has no readable text."});
        }
        return truncate_result(header + text.strip());
    } except Exception as e {
        return json.dumps({"ok": False, "error": f"Fetch failed for {target}: {e}"});
    }
}
sem web_fetch = "Fetch an http(s) URL and return readable text (HTML stripped, ~50KB cap). Use after web_search when you need page content.";
sem web_fetch.url = "http(s) URL to fetch.";


"""ToolSpec-shaped dicts for agent.tools.tool_specs() registration.
Mirrors the ToolSpec(name/description/parameters/handler) shape without
importing ToolSpec, so tools.jac needs one append line to adopt these."""
def tool_specs_web() -> list[dict] {
    return [
        {
            "name": "web_search",
            "description": "Search the web (DuckDuckGo HTML backend) and return the top results with titles, URLs, and snippets. Use for docs, releases, and facts not in the repo.",
            "parameters": {
                "type": "object",
                "properties": {
                    "query": {"type": "string", "description": "Search query."},
                    "num_results": {"type": "integer", "description": "Max results (default 5, capped at 20)."},
                },
                "required": ["query"],
            },
            "handler": web_search,
        },
        {
            "name": "web_fetch",
            "description": "Fetch an http(s) URL and return readable text (HTML stripped, ~50KB cap). Use after web_search when you need page content.",
            "parameters": {
                "type": "object",
                "properties": {
                    "url": {"type": "string", "description": "http(s) URL to fetch."},
                },
                "required": ["url"],
            },
            "handler": web_fetch,
        },
    ];
}
