"""MCP client — talks to `jac mcp` (or any MCP server) as a stdio subprocess.

Transport: newline-delimited JSON-RPC 2.0 over stdin/stdout (verified against
`jac mcp`, which speaks one JSON object per line, no Content-Length framing).
Lifecycle: start -> initialize handshake -> notifications/initialized ->
tools/list / tools/call -> stop.

Style mirrors plugin_bridge.jac: obj state + module-level functions taking
the client as first arg, defensive dict access, background stdout reader
thread with per-id correlation events. The public seam NEVER raises — every
entry point returns {"ok": True, ...} or {"ok": False, "error": ...}.
"""

import json;
import os;
import shutil;
import subprocess;
import sys;
import tempfile;
import threading;
import time;

glob DEFAULT_TIMEOUT_S: float = 15.0,
     MAX_NOTIFICATIONS: int = 1000;

# Protocol version we offer during initialize; servers negotiate down.
glob MCP_PROTOCOL_VERSION: str = "2025-06-18";


obj McpClient {
    """State holder for one MCP server subprocess."""
    has proc: any = None,
        server_cmd: list[str] = [],
        next_id: int = 1,
        timeout_s: float = DEFAULT_TIMEOUT_S,
        initialized: bool = False,
        protocol_version: str = "",
        server_info: dict = {},
        pending: dict = {},
        notifications: list[dict] = [],
        write_lock: any = None,
        reader_stop: any = None,
        reader_thread: any = None;

    def start(server_cmd: list[str], timeout_s: float = -1.0) -> dict {
        return mcp_start(self, server_cmd, timeout_s);
    }

    def list_tools(timeout_s: float = -1.0) -> dict {
        return mcp_list_tools(self, timeout_s);
    }

    def call_tool(name: str, arguments: dict, timeout_s: float = -1.0) -> dict {
        return mcp_call_tool(self, name, arguments, timeout_s);
    }

    def stop() -> dict {
        return mcp_stop(self);
    }
}


def create_mcp_client(timeout_s: float = DEFAULT_TIMEOUT_S) -> McpClient {
    return McpClient(timeout_s=timeout_s);
}


def _alive(client: McpClient) -> bool {
    if client.proc is None {
        return False;
    }
    return client.proc.poll() is None;
}


def _ensure_io(client: McpClient) {
    if client.write_lock is None {
        client.write_lock = threading.Lock();
    }
    if client.reader_stop is None {
        client.reader_stop = threading.Event();
    }
}


"""Background stdout reader — routes responses by id, buffers notifications."""
def _reader_loop(client: McpClient) {
    stop = client.reader_stop;
    proc = client.proc;
    if proc is None or proc.stdout is None {
        return;
    }
    while stop is None or not stop.is_set() {
        try {
            line_raw: any = proc.stdout.readline();
        } except Exception {
            break;
        }
        if not line_raw {
            break;
        }
        line_s: str = str(line_raw).strip();
        if not line_s {
            continue;
        }
        try {
            parsed: any = json.loads(line_s);
        } except Exception {
            continue;  # skip non-JSON noise on the transport
        }
        if not isinstance(parsed, dict) {
            continue;
        }
        rid: any = parsed.get("id");
        is_response = (
            "id" in parsed
            and rid is not None
            and "method" not in parsed
        );
        if is_response {
            key = str(rid);
            waiter: any = client.pending.get(key);
            if waiter is not None {
                waiter["msg"] = parsed;
                ev: any = waiter.get("event");
                if ev is not None {
                    ev.set();
                }
            }
            continue;
        }
        # Notification or server->client request: buffer for inspection.
        if len(client.notifications) < MAX_NOTIFICATIONS {
            client.notifications.append(parsed);
        }
    }
}


def _start_reader(client: McpClient) {
    _ensure_io(client);
    if client.reader_thread is not None and client.reader_thread.is_alive() {
        return;
    }
    client.reader_stop.clear();
    t = threading.Thread(
        target=_reader_loop, args=(client,), daemon=True, name="mcp-reader"
    );
    client.reader_thread = t;
    t.start();
}


def _stop_reader(client: McpClient) {
    if client.reader_stop is not None {
        client.reader_stop.set();
    }
    client.reader_thread = None;
}


def _write_line(client: McpClient, msg: dict) {
    if not _alive(client) or client.proc.stdin is None {
        raise RuntimeError("mcp server not running");
    }
    line = json.dumps(msg) + "\n";
    lock: any = client.write_lock;
    if lock is not None {
        lock.acquire();
        try {
            client.proc.stdin.write(line);
            client.proc.stdin.flush();
        } finally {
            lock.release();
        }
    } else {
        client.proc.stdin.write(line);
        client.proc.stdin.flush();
    }
}


"""Send a JSON-RPC request and wait for the correlated response.

Internal: raises TimeoutError/RuntimeError. Public seam wraps this."""
def _request(
    client: McpClient, method: str, params: dict, timeout_s: float
) -> dict {
    _ensure_io(client);
    rid = client.next_id;
    client.next_id += 1;
    key = str(rid);
    client.pending[key] = {"event": threading.Event(), "msg": None};
    req: dict = {
        "jsonrpc": "2.0",
        "id": rid,
        "method": method,
        "params": params if params else {},
    };
    try {
        _write_line(client, req);
    } except Exception as e {
        client.pending.pop(key, None);
        raise RuntimeError(f"mcp write failed: {e}");
    }
    deadline = time.monotonic() + timeout_s;
    while True {
        remaining = max(0.01, deadline - time.monotonic());
        waiter: any = client.pending.get(key);
        if waiter is None {
            raise RuntimeError("mcp response waiter vanished");
        }
        if waiter.get("msg") is not None {
            client.pending.pop(key, None);
            got: any = waiter["msg"];
            return got as dict;
        }
        ok = waiter["event"].wait(timeout=remaining);
        if not ok and time.monotonic() >= deadline {
            client.pending.pop(key, None);
            raise TimeoutError(f"timed out waiting for {method}");
        }
    }
}


"""Extract {"ok": ...} payload from a JSON-RPC response dict."""
def _response_payload(resp: dict) -> dict {
    err: any = resp.get("error");
    if isinstance(err, dict) and err is not None {
        code = err.get("code", "");
        message = str(err.get("message", "unknown mcp error"));
        return {"ok": False, "error": f"{message} (code {code})"};
    }
    result: any = resp.get("result");
    if not isinstance(result, dict) {
        return {"ok": True, "result": {}};
    }
    return {"ok": True, "result": result};
}


def _effective_timeout(client: McpClient, timeout_s: float) -> float {
    if timeout_s > 0.0 {
        return timeout_s;
    }
    return client.timeout_s;
}


"""Spawn the MCP server subprocess and run the initialize handshake.

server_cmd example: ["jac", "mcp"]. Returns {"ok": True, "server_info": ...}
or {"ok": False, "error": ...}; never raises."""
def mcp_start(client: McpClient, server_cmd: list[str], timeout_s: float = -1.0) -> dict {
    if not server_cmd {
        return {"ok": False, "error": "server_cmd must not be empty"};
    }
    if _alive(client) {
        return {"ok": False, "error": "mcp client already started"};
    }
    timeout = _effective_timeout(client, timeout_s);
    _ensure_io(client);
    try {
        client.proc = subprocess.Popen(
            [str(c) for c in server_cmd],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
            bufsize=1,
        );
    } except Exception as e {
        client.proc = None;
        return {"ok": False, "error": f"failed to spawn mcp server: {e}"};
    }
    client.server_cmd = [str(c) for c in server_cmd];
    _start_reader(client);
    init_params: dict = {
        "protocolVersion": MCP_PROTOCOL_VERSION,
        "capabilities": {},
        "clientInfo": {"name": "jackal", "version": "0.1.0"},
    };
    try {
        resp = _request(client, "initialize", init_params, timeout);
    } except Exception as e {
        mcp_stop(client);
        return {"ok": False, "error": f"initialize failed: {e}"};
    }
    payload = _response_payload(resp);
    if not payload["ok"] {
        mcp_stop(client);
        return payload;
    }
    result: any = payload["result"];
    pv = str(result.get("protocolVersion", ""));
    if pv {
        client.protocol_version = pv;
    }
    raw_info: any = result.get("serverInfo");
    info: dict = {};
    if isinstance(raw_info, dict) {
        info = raw_info;
    }
    client.server_info = info;
    # Handshake completion notification (no response expected).
    try {
        _write_line(client, {"jsonrpc": "2.0", "method": "notifications/initialized"});
    } except Exception as e {
        mcp_stop(client);
        return {"ok": False, "error": f"initialized notification failed: {e}"};
    }
    client.initialized = True;
    out: dict = {"ok": True};
    if info.get("name") {
        out["server_name"] = str(info.get("name"));
    }
    if pv {
        out["protocol_version"] = pv;
    }
    return out;
}


"""List tools exposed by the server. Returns {"ok", "tools": [...]}."""
def mcp_list_tools(client: McpClient, timeout_s: float = -1.0) -> dict {
    if not client.initialized or not _alive(client) {
        return {"ok": False, "error": "mcp client not initialized"};
    }
    timeout = _effective_timeout(client, timeout_s);
    try {
        resp = _request(client, "tools/list", {}, timeout);
    } except Exception as e {
        return {"ok": False, "error": str(e)};
    }
    payload = _response_payload(resp);
    if not payload["ok"] {
        return payload;
    }
    result: any = payload["result"];
    raw_tools: any = result.get("tools", []);
    tools: list[dict] = [];
    if isinstance(raw_tools, list) {
        for t in raw_tools {
            if isinstance(t, dict) and t.get("name") {
                schema: any = t.get("inputSchema");
                tools.append({
                    "name": str(t.get("name")),
                    "description": str(t.get("description", "")),
                    "inputSchema": schema if isinstance(schema, dict) else {},
                });
            }
        }
    }
    return {"ok": True, "tools": tools};
}


"""Call a tool on the server. Returns {"ok", "result"/"error", "is_error"?}.

MCP-level tool failures (isError=true) come back ok=True with is_error=True
and the error text in "result" — the transport succeeded; semantics failed."""
def mcp_call_tool(
    client: McpClient, name: str, arguments: dict, timeout_s: float = -1.0
) -> dict {
    if not client.initialized or not _alive(client) {
        return {"ok": False, "error": "mcp client not initialized"};
    }
    if not name {
        return {"ok": False, "error": "tool name must not be empty"};
    }
    args: dict = {};
    if isinstance(arguments, dict) {
        args = arguments;
    }
    timeout = _effective_timeout(client, timeout_s);
    params: dict = {"name": str(name), "arguments": args};
    try {
        resp = _request(client, "tools/call", params, timeout);
    } except Exception as e {
        return {"ok": False, "error": str(e)};
    }
    payload = _response_payload(resp);
    if not payload["ok"] {
        return payload;
    }
    result: any = payload["result"];
    # Flatten content blocks to text (standard MCP text-content shape).
    parts: list[str] = [];
    raw_content: any = result.get("content", []);
    if isinstance(raw_content, list) {
        for block in raw_content {
            if isinstance(block, dict) and str(block.get("type", "")) == "text" {
                parts.append(str(block.get("text", "")));
            }
        }
    }
    text = "\n".join(parts);
    is_err = bool(result.get("isError", False));
    out: dict = {"ok": True, "result": text, "is_error": is_err};
    structured: any = result.get("structuredContent");
    if isinstance(structured, dict) {
        out["structured"] = structured;
    }
    return out;
}


"""Stop the server subprocess and tear down reader state. Never raises."""
def mcp_stop(client: McpClient) -> dict {
    proc = client.proc;
    if proc is not None {
        try {
            if proc.poll() is None {
                if proc.stdin is not None {
                    try {
                        proc.stdin.close();
                    } except Exception {
                    }
                }
                proc.terminate();
                try {
                    proc.wait(timeout=2.0);
                } except Exception {
                    try {
                        proc.kill();
                        proc.wait(timeout=2.0);
                    } except Exception {
                    }
                }
            }
        } except Exception {
        }
    }
    _stop_reader(client);
    client.proc = None;
    client.initialized = False;
    client.pending = {};
    return {"ok": True};
}


"""Map MCP tools/list results to ToolSpec-compatible dicts.

Each spec matches the native registration shape used across the repo:
{"name", "description", "parameters"} where parameters is the MCP
inputSchema JSON-Schema dict (empty object schema when absent).
prefix avoids collisions with native tools (e.g. "mcp_")."""
def mcp_tool_specs(client: McpClient, prefix: str = "", timeout_s: float = -1.0) -> list[dict] {
    res = mcp_list_tools(client, timeout_s);
    specs: list[dict] = [];
    if not res["ok"] {
        return specs;
    }
    tools: any = res.get("tools", []);
    for t in tools {
        if not isinstance(t, dict) {
            continue;
        }
        name = str(t.get("name", ""));
        if not name {
            continue;
        }
        raw_schema: any = t.get("inputSchema");
        params: dict = {};
        if isinstance(raw_schema, dict) and raw_schema {
            params = raw_schema;
        } else {
            params = {"type": "object", "properties": {}, "required": []};
        }
        full_name = prefix + name;
        specs.append({
            "name": full_name,
            "description": str(t.get("description", "")),
            "parameters": params,
        });
    }
    return specs;
}
