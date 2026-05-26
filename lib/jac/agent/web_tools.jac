"""Web search (Brave) and URL fetch — SSRF guard, HTML→text, result formatting."""

::py::
import json
import os
import re
import ssl
import urllib.error
import urllib.parse
import urllib.request

BRAVE_SEARCH_URL = "https://api.search.brave.com/res/v1/web/search"
DEFAULT_SEARCH_COUNT = 5
MAX_SEARCH_COUNT = 10
DEFAULT_FETCH_TIMEOUT_S = 30
MAX_FETCH_BODY_BYTES = 512 * 1024
USER_AGENT = "Jackal/0.1 (+https://github.com/jaseci/jackal)"


def brave_api_key():
    key = (os.environ.get("BRAVE_API_KEY") or "").strip()
    if key:
        return key
    key = (os.environ.get("BRAVE_SEARCH_API_KEY") or "").strip()
    return key or None


def _is_private_or_link_local(host):
    bare = host[1:-1] if host.startswith("[") and host.endswith("]") else host
    if ":" in bare:
        h = bare.lower()
        if h == "::1":
            return True
        if h.startswith("fc") or h.startswith("fd"):
            return True
        if h.startswith("fe80:"):
            return True
        return False
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


def assert_safe_fetch_url(raw):
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


def _decode_basic_entities(text):
    text = re.sub(r"&nbsp;", " ", text, flags=re.IGNORECASE)
    text = text.replace("&amp;", "&").replace("&lt;", "<").replace("&gt;", ">")
    text = text.replace("&quot;", '"').replace("&#39;", "'")
    text = re.sub(
        r"&#x([0-9a-f]+);",
        lambda m: chr(int(m.group(1), 16)),
        text,
        flags=re.IGNORECASE,
    )
    text = re.sub(r"&#(\d+);", lambda m: chr(int(m.group(1))), text)
    return text


def html_to_readable_text(html):
    text = re.sub(r"<script[\s\S]*?</script>", "", html, flags=re.IGNORECASE)
    text = re.sub(r"<style[\s\S]*?</style>", "", text, flags=re.IGNORECASE)
    text = re.sub(r"<noscript[\s\S]*?</noscript>", "", text, flags=re.IGNORECASE)
    text = re.sub(r"<!--[\s\S]*?-->", "", text)
    text = re.sub(r"<br\s*/?>", "\n", text, flags=re.IGNORECASE)
    text = re.sub(
        r"</(p|div|section|article|header|footer|li|tr|h[1-6])>",
        "\n",
        text,
        flags=re.IGNORECASE,
    )
    text = re.sub(r'<li[^>]*>', "- ", text, flags=re.IGNORECASE)
    text = re.sub(r"<[^>]+>", " ", text)
    text = _decode_basic_entities(text)
    text = re.sub(r"[ \t]+\n", "\n", text)
    text = re.sub(r"\n{3,}", "\n\n", text)
    text = re.sub(r"[ \t]{2,}", " ", text)
    return text.strip()


def format_web_search_results(results):
    if not results:
        return "No results found."
    parts = []
    for i, r in enumerate(results, 1):
        lines = [f"{i}. {r['title']}", f"   URL: {r['url']}"]
        if r.get("description"):
            lines.append(f"   {r['description']}")
        parts.append("\n".join(lines))
    return "\n\n".join(parts)


def parse_brave_search_response(data):
    if not isinstance(data, dict):
        return []
    web = data.get("web", {})
    rows = web.get("results", []) if isinstance(web, dict) else []
    if not isinstance(rows, list):
        return []
    out = []
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


def search_web(query, count=None):
    api_key = brave_api_key()
    if not api_key:
        raise ValueError(
            "Web search requires BRAVE_API_KEY (or BRAVE_SEARCH_API_KEY). "
            "Get a key at https://api.search.brave.com/"
        )

    n = min(max(count or DEFAULT_SEARCH_COUNT, 1), MAX_SEARCH_COUNT)
    params = urllib.parse.urlencode({"q": query, "count": str(n)})
    url = f"{BRAVE_SEARCH_URL}?{params}"

    req = urllib.request.Request(
        url,
        headers={
            "Accept": "application/json",
            "Accept-Encoding": "gzip",
            "X-Subscription-Token": api_key,
        },
    )

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
        raise ValueError("Brave search returned non-JSON")

    return {"results": parse_brave_search_response(data), "raw": data}


def fetch_web_page(url, timeout_s=None):
    assert_safe_fetch_url(url)
    timeout = timeout_s or DEFAULT_FETCH_TIMEOUT_S

    req = urllib.request.Request(
        url,
        headers={
            "Accept": "text/html,application/xhtml+xml,text/plain,application/json;q=0.9,*/*;q=0.8",
            "User-Agent": USER_AGENT,
        },
    )

    ctx = ssl.create_default_context()
    with urllib.request.urlopen(req, timeout=timeout, context=ctx) as resp:
        content_type = resp.headers.get("Content-Type", "application/octet-stream")
        raw_bytes = resp.read()
        final_url = resp.url or url

    if len(raw_bytes) > MAX_FETCH_BODY_BYTES:
        raise ValueError(
            f"Response too large ({len(raw_bytes)} bytes, max {MAX_FETCH_BODY_BYTES})"
        )

    body = raw_bytes.decode("utf-8", errors="replace")

    if "application/json" in content_type:
        try:
            text = json.dumps(json.loads(body), indent=2)
        except json.JSONDecodeError:
            text = body
    elif "text/html" in content_type or "application/xhtml" in content_type:
        title_match = re.search(
            r"<title[^>]*>([\s\S]*?)</title>", body, re.IGNORECASE
        )
        title = html_to_readable_text(title_match.group(1)) if title_match else ""
        main = html_to_readable_text(body)
        text = f"# {title}\n\n{main}" if title else main
    else:
        text = body

    max_bytes = 50_000
    if len(text.encode("utf-8")) > max_bytes:
        text = text[:max_bytes] + "\n... (truncated)"

    return {"url": final_url, "contentType": content_type, "text": text}
::py::

# ---------- tests ----------

test "safe url valid" {
    assert assert_safe_fetch_url("https://example.com") == "https://example.com";
}

test "safe url ftp rejected" {
    try {
        assert_safe_fetch_url("ftp://example.com");
        assert False;
    } except ValueError as e {
        assert "http" in str(e);
    }
}

test "safe url localhost rejected" {
    try {
        assert_safe_fetch_url("http://localhost:3000");
        assert False;
    } except ValueError as e {
        assert "Loopback" in str(e);
    }
}

test "safe url private ip rejected" {
    try {
        assert_safe_fetch_url("http://192.168.1.1");
        assert False;
    } except ValueError as e {
        assert "Private" in str(e);
    }
}

test "safe url internal rejected" {
    try {
        assert_safe_fetch_url("http://metadata.google.internal");
        assert False;
    } except ValueError as e {
        assert "Internal" in str(e);
    }
}

test "html to readable" {
    html = "<html><head><title>Test</title></head><body><h1>Hello</h1><p>World</p></body></html>";
    text = html_to_readable_text(html);
    assert "Hello" in text;
    assert "World" in text;
}

test "html strips scripts" {
    html = "<script>alert('x')</script><p>Safe</p>";
    text = html_to_readable_text(html);
    assert "alert" not in text;
    assert "Safe" in text;
}

test "html decodes entities" {
    html = "<p>a &amp; b &lt; c &gt; d</p>";
    text = html_to_readable_text(html);
    assert "a & b" in text;
    assert "< c" in text;
}

test "format search results empty" {
    assert format_web_search_results([]) == "No results found.";
}

test "format search results" {
    results = [{"title": "Test", "url": "https://example.com", "description": "A result"}];
    text = format_web_search_results(results);
    assert "1. Test" in text;
    assert "https://example.com" in text;
    assert "A result" in text;
}

test "parse brave response" {
    data = {
        "web": {
            "results": [
                {"title": "A", "url": "https://a.com", "description": "desc a"},
                {"title": "B", "url": "https://b.com"},
            ]
        }
    };
    results = parse_brave_search_response(data);
    assert len(list(results)) == 2;
    assert results[0]["title"] == "A";
    assert results[1]["description"] == "";
}

test "parse brave response empty" {
    assert parse_brave_search_response(None) == [];
    assert parse_brave_search_response({}) == [];
    assert parse_brave_search_response({"web": {}}) == [];
}

test "private ip detection" {
    assert _is_private_or_link_local("10.0.0.1");
    assert _is_private_or_link_local("127.0.0.1");
    assert _is_private_or_link_local("169.254.1.1");
    assert _is_private_or_link_local("172.16.0.1");
    assert _is_private_or_link_local("192.168.1.1");
    assert not _is_private_or_link_local("8.8.8.8");
}

test "private ipv6 detection" {
    assert _is_private_or_link_local("::1");
    assert _is_private_or_link_local("fc00::1");
    assert _is_private_or_link_local("fe80::1");
    assert not _is_private_or_link_local("2001:db8::1");
}
