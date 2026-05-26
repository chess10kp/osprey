"""Web search (Brave) and URL fetch utilities.

Ported from src/agent/web-tools.ts. Uses stdlib only (urllib, json).
The AgentTool wrapping stays in TS; this provides pure logic + HTTP ops.
"""

from __future__ import annotations

import json
import os
import re
import urllib.request
import urllib.error
import urllib.parse
import ssl
from typing import Any

BRAVE_SEARCH_URL = "https://api.search.brave.com/res/v1/web/search"
DEFAULT_SEARCH_COUNT = 5
MAX_SEARCH_COUNT = 10
DEFAULT_FETCH_TIMEOUT_S = 30
MAX_FETCH_BODY_BYTES = 512 * 1024
USER_AGENT = "Jackal/0.1 (+https://github.com/jaseci/jackal)"


# ---------------------------------------------------------------------------
# API key
# ---------------------------------------------------------------------------

def brave_api_key() -> str | None:
    key = (os.environ.get("BRAVE_API_KEY") or "").strip()
    if key:
        return key
    key = (os.environ.get("BRAVE_SEARCH_API_KEY") or "").strip()
    return key or None


# ---------------------------------------------------------------------------
# URL safety (SSRF protection)
# ---------------------------------------------------------------------------

def _is_private_or_link_local(host: str) -> bool:
    bare = host[1:-1] if host.startswith("[") and host.endswith("]") else host
    # IPv6
    if ":" in bare:
        h = bare.lower()
        if h == "::1":
            return True
        if h.startswith("fc") or h.startswith("fd"):
            return True
        if h.startswith("fe80:"):
            return True
        return False
    # IPv4
    parts = bare.split(".")
    try:
        nums = [int(p) for p in parts]
    except ValueError:
        return False
    if len(nums) != 4 or any(n < 0 or n > 255 for n in nums):
        return False
    a, b = nums[0], nums[1]
    if a == 10:
        return True
    if a == 127:
        return True
    if a == 169 and b == 254:
        return True
    if a == 172 and 16 <= b <= 31:
        return True
    if a == 192 and b == 168:
        return True
    return False


def assert_safe_fetch_url(raw: str) -> str:
    """Validate URL for safe fetching. Returns normalized URL string."""
    parsed = urllib.parse.urlparse(raw)
    if parsed.scheme not in ("http", "https"):
        raise ValueError("Only http(s) URLs are allowed")
    host = (parsed.hostname or "").lower()
    if host in ("localhost", "127.0.0.1", "0.0.0.0", "::1", "[::1]"):
        raise ValueError("Loopback URLs are not allowed")
    if host.endswith(".localhost"):
        raise ValueError("Loopback URLs are not allowed")
    if host == "metadata.google.internal" or host.endswith(".internal"):
        raise ValueError("Internal hostnames are not allowed")
    if _is_private_or_link_local(host):
        raise ValueError("Private network URLs are not allowed")
    return raw


# ---------------------------------------------------------------------------
# HTML → readable text
# ---------------------------------------------------------------------------

def _decode_basic_entities(text: str) -> str:
    text = re.sub(r"&nbsp;", " ", text, flags=re.IGNORECASE)
    text = text.replace("&amp;", "&").replace("&lt;", "<").replace("&gt;", ">")
    text = text.replace("&quot;", '"').replace("&#39;", "'")
    text = re.sub(r"&#x([0-9a-f]+);", lambda m: chr(int(m.group(1), 16)), text, flags=re.IGNORECASE)
    text = re.sub(r"&#(\d+);", lambda m: chr(int(m.group(1))), text)
    return text


def html_to_readable_text(html: str) -> str:
    text = re.sub(r"<script[\s\S]*?</script>", "", html, flags=re.IGNORECASE)
    text = re.sub(r"<style[\s\S]*?</style>", "", text, flags=re.IGNORECASE)
    text = re.sub(r"<noscript[\s\S]*?</noscript>", "", text, flags=re.IGNORECASE)
    text = re.sub(r"<!--[\s\S]*?-->", "", text)
    text = re.sub(r"<br\s*/?>", "\n", text, flags=re.IGNORECASE)
    text = re.sub(r"</(p|div|section|article|header|footer|li|tr|h[1-6])>", "\n", text, flags=re.IGNORECASE)
    text = re.sub(r'<li[^>]*>', "- ", text, flags=re.IGNORECASE)
    text = re.sub(r"<[^>]+>", " ", text)
    text = _decode_basic_entities(text)
    text = re.sub(r"[ \t]+\n", "\n", text)
    text = re.sub(r"\n{3,}", "\n\n", text)
    text = re.sub(r"[ \t]{2,}", " ", text)
    return text.strip()


# ---------------------------------------------------------------------------
# Search result types
# ---------------------------------------------------------------------------

def format_web_search_results(results: list[dict]) -> str:
    if not results:
        return "No results found."
    parts = []
    for i, r in enumerate(results, 1):
        lines = [f"{i}. {r['title']}", f"   URL: {r['url']}"]
        if r.get("description"):
            lines.append(f"   {r['description']}")
        parts.append("\n".join(lines))
    return "\n\n".join(parts)


def parse_brave_search_response(data: Any) -> list[dict]:
    if not isinstance(data, dict):
        return []
    web = data.get("web", {})
    rows = web.get("results", []) if isinstance(web, dict) else []
    if not isinstance(rows, list):
        return []
    out: list[dict] = []
    for row in rows:
        if not isinstance(row, dict):
            continue
        title = str(row.get("title", "")).strip()
        url = str(row.get("url", "")).strip()
        description = str(row.get("description", row.get("snippet", ""))).strip()
        if not url:
            continue
        out.append({"title": title or url, "url": url, "description": description})
    return out


# ---------------------------------------------------------------------------
# Search + Fetch operations
# ---------------------------------------------------------------------------

def search_web(query: str, count: int | None = None) -> dict:
    """Search via Brave API. Returns {results, raw}."""
    api_key = brave_api_key()
    if not api_key:
        raise ValueError(
            "Web search requires BRAVE_API_KEY (or BRAVE_SEARCH_API_KEY). "
            "Get a key at https://api.search.brave.com/"
        )

    n = min(max(count or DEFAULT_SEARCH_COUNT, 1), MAX_SEARCH_COUNT)
    params = urllib.parse.urlencode({"q": query, "count": str(n)})
    url = f"{BRAVE_SEARCH_URL}?{params}"

    req = urllib.request.Request(url, headers={
        "Accept": "application/json",
        "Accept-Encoding": "gzip",
        "X-Subscription-Token": api_key,
    })

    ctx = ssl.create_default_context()
    try:
        with urllib.request.urlopen(req, timeout=20, context=ctx) as resp:
            body = resp.read().decode("utf-8")
    except urllib.error.HTTPError as e:
        body = e.read().decode("utf-8", errors="replace")
        try:
            data = json.loads(body)
            msg = data.get("message", body[:200])
        except json.JSONDecodeError:
            msg = body[:200]
        raise ValueError(f"Brave search failed (HTTP {e.code}): {msg}")
    except urllib.error.URLError as e:
        raise ValueError(f"Brave search request failed: {e.reason}")

    try:
        data = json.loads(body)
    except json.JSONDecodeError:
        raise ValueError(f"Brave search returned non-JSON")

    return {"results": parse_brave_search_response(data), "raw": data}


def fetch_web_page(url: str, timeout_s: int | None = None) -> dict:
    """Fetch a public URL and return readable text."""
    assert_safe_fetch_url(url)
    timeout = timeout_s or DEFAULT_FETCH_TIMEOUT_S

    req = urllib.request.Request(url, headers={
        "Accept": "text/html,application/xhtml+xml,text/plain,application/json;q=0.9,*/*;q=0.8",
        "User-Agent": USER_AGENT,
    })

    ctx = ssl.create_default_context()
    with urllib.request.urlopen(req, timeout=timeout, context=ctx) as resp:
        content_type = resp.headers.get("Content-Type", "application/octet-stream")
        raw_bytes = resp.read()
        final_url = resp.url or url

    if len(raw_bytes) > MAX_FETCH_BODY_BYTES:
        raise ValueError(f"Response too large ({len(raw_bytes)} bytes, max {MAX_FETCH_BODY_BYTES})")

    body = raw_bytes.decode("utf-8", errors="replace")

    if "application/json" in content_type:
        try:
            text = json.dumps(json.loads(body), indent=2)
        except json.JSONDecodeError:
            text = body
    elif "text/html" in content_type or "application/xhtml" in content_type:
        title_match = re.search(r"<title[^>]*>([\s\S]*?)</title>", body, re.IGNORECASE)
        title = html_to_readable_text(title_match.group(1)) if title_match else ""
        main = html_to_readable_text(body)
        text = f"# {title}\n\n{main}" if title else main
    else:
        text = body

    # Truncate to reasonable size for tool output
    max_bytes = 50_000
    if len(text.encode("utf-8")) > max_bytes:
        text = text[:max_bytes] + "\n... (truncated)"

    return {"url": final_url, "contentType": content_type, "text": text}
