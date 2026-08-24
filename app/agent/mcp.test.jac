"""Tests for agent/mcp.jac (same-stem annex, merged with the base module
at test time - no import of the own stem). All transport tests run against
a fake newline-delimited JSON-RPC MCP server generated into a temp dir at
test time; the real `jac mcp` is never spawned here.
"""

glob FAKE_SERVER_SRC: str = """
import sys, json

def send(obj):
    sys.stdout.write(json.dumps(obj) + \"\\n\")
    sys.stdout.flush()

mode = sys.argv[1] if len(sys.argv) > 1 else "normal"
for raw in sys.stdin:
    raw = raw.strip()
    if not raw:
        continue
    try:
        req = json.loads(raw)
    except Exception:
        continue
    method = req.get("method", "")
    rid = req.get("id")
    if mode != "normal" and method == "tools/list":
        continue  # silent: never respond (timeout path)
    if method == "initialize":
        send({"jsonrpc": "2.0", "id": rid, "result": {
            "protocolVersion": "2025-06-18",
            "capabilities": {"tools": {}},
            "serverInfo": {"name": "fake-mcp", "version": "0.0.1"},
        }})
    elif method == "notifications/initialized":
        pass
    elif method == "tools/list":
        send({"jsonrpc": "2.0", "id": rid, "result": {"tools": [
            {"name": "echo", "description": "Echo the given text back.",
             "inputSchema": {"type": "object",
                             "properties": {"text": {"type": "string"}},
                             "required": ["text"]}},
            {"name": "boom", "description": "Always fails.",
             "inputSchema": {"type": "object",
                             "properties": {}, "required": []}},
        ]}})
    elif method == "tools/call":
        name = str(req.get("params", {}).get("name", ""))
        args = req.get("params", {}).get("arguments", {}) or {}
        if name == "echo":
            text = str(args.get("text", ""))
            send({"jsonrpc": "2.0", "id": rid, "result": {
                "content": [{"type": "text", "text": "echo:" + text}],
                "isError": False}})
        else:
            send({"jsonrpc": "2.0", "id": rid, "error": {
                "code": -32601, "message": "unknown tool: " + name}})
    elif rid is not None:
        send({"jsonrpc": "2.0", "id": rid, "error": {
            "code": -32601, "message": "method not found"}})
""";


def _write_fake_server(tmp: str) -> list[str] {
    path = os.path.join(tmp, "fake_mcp_server.py");
    with open(path, "w") as f { f.write(FAKE_SERVER_SRC); }
    return [sys.executable, path, "normal"];
}


def _write_silent_server(tmp: str) -> list[str] {
    path = os.path.join(tmp, "silent_mcp_server.py");
    with open(path, "w") as f { f.write(FAKE_SERVER_SRC); }
    return [sys.executable, path, "silent"];
}


test "start handshake and stop against fake mcp server" {
    tmp = tempfile.mkdtemp();
    client = create_mcp_client();
    try {
        cmd = _write_fake_server(tmp);
        res = mcp_start(client, cmd, timeout_s=10.0);
        assert res["ok"] is True;
        assert res.get("server_name") == "fake-mcp";
        assert client.initialized is True;
        assert client.protocol_version == "2025-06-18";
    } finally {
        mcp_stop(client);
        shutil.rmtree(tmp, ignore_errors=True);
    }
}


test "tools/list maps to ToolSpec-shaped specs" {
    tmp = tempfile.mkdtemp();
    client = create_mcp_client();
    try {
        cmd = _write_fake_server(tmp);
        assert mcp_start(client, cmd, timeout_s=10.0)["ok"] is True;
        specs = mcp_tool_specs(client);
        assert len(specs) == 2;
        echo: any = None;
        for s in specs {
            if s["name"] == "echo" { echo = s; }
        }
        assert echo is not None;
        assert echo["description"] == "Echo the given text back.";
        props: any = echo["parameters"].get("properties");
        assert isinstance(props, dict) and "text" in props;
        # prefixed mapping avoids native-tool collisions
        prefixed = mcp_tool_specs(client, prefix="mcp_");
        names = [s["name"] for s in prefixed];
        assert "mcp_echo" in names;
    } finally {
        mcp_stop(client);
        shutil.rmtree(tmp, ignore_errors=True);
    }
}


test "call_tool round trip through fake server" {
    tmp = tempfile.mkdtemp();
    client = create_mcp_client();
    try {
        cmd = _write_fake_server(tmp);
        assert mcp_start(client, cmd, timeout_s=10.0)["ok"] is True;
        res = mcp_call_tool(client, "echo", {"text": "hello"}, timeout_s=10.0);
        assert res["ok"] is True;
        assert res.get("is_error") is False;
        assert res.get("result") == "echo:hello";
        # JSON-RPC-level error for unknown tool fails loud at the seam
        bad = mcp_call_tool(client, "nope", {}, timeout_s=10.0);
        assert bad["ok"] is False;
        assert "unknown tool" in str(bad.get("error", ""));
    } finally {
        mcp_stop(client);
        shutil.rmtree(tmp, ignore_errors=True);
    }
}


test "timeout on silent tools/list returns ok False" {
    tmp = tempfile.mkdtemp();
    client = create_mcp_client();
    try {
        cmd = _write_silent_server(tmp);
        assert mcp_start(client, cmd, timeout_s=10.0)["ok"] is True;
        t0 = time.time();
        res = mcp_list_tools(client, timeout_s=0.5);
        elapsed = time.time() - t0;
        assert res["ok"] is False;
        assert "timed out" in str(res.get("error", ""));
        assert elapsed < 5.0;
    } finally {
        mcp_stop(client);
        shutil.rmtree(tmp, ignore_errors=True);
    }
}


test "spawn failure and empty-cmd fail loud without raising" {
    client = create_mcp_client();
    res = mcp_start(client, ["/nonexistent/jackal/fake_binary_xyz"], timeout_s=5.0);
    assert res["ok"] is False;
    assert "failed to spawn" in str(res.get("error", ""));
    empty = mcp_start(client, []);
    assert empty["ok"] is False;
    # calls before start also fail loud
    fresh = create_mcp_client();
    lt = mcp_list_tools(fresh);
    assert lt["ok"] is False;
    ct = mcp_call_tool(fresh, "x", {});
    assert ct["ok"] is False;
}
