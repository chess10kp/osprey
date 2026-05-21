// ────────────────────────────────────────────────────────────────────────────
// Jackal TUI Shell — emitted into .jac/tui/ as the Ink rendering host.
//
// Self-contained Ink shell that boots a Pi AgentSession, renders messages,
// streaming text, tool calls, and runs a full prompt loop.
//
// Dependencies (resolved from emitted package.json):
//   ink, react, @earendil-works/pi-coding-agent
// ────────────────────────────────────────────────────────────────────────────

import React, { useState, useEffect, useCallback, useRef } from "react";
import { render, Box, Text, useInput, useApp } from "ink";
import { createAgentSession, SessionManager } from "@earendil-works/pi-coding-agent";

// ──── Store (inlined) ──────────────────────────────────────────────────────

const INIT = {
  phase: "booting", model: "", provider: "", sessionId: "",
  messages: [], streamingText: null, toolExecutions: {}, error: null,
};

function createStore() {
  let snap = { ...INIT };
  const ls = new Set();
  const emit = () => { for (const l of ls) try { l(); } catch {} };
  return {
    get: () => snap,
    subscribe: (fn) => { ls.add(fn); return () => ls.delete(fn); },
    set: (p) => { snap = { ...snap, ...p }; emit(); },
    pushMsg: (m) => { snap = { ...snap, messages: [...snap.messages, m] }; emit(); },
    upsertTool: (t) => { snap = { ...snap, toolExecutions: { ...snap.toolExecutions, [t.id]: t } }; emit(); },
    reset: () => { snap = { ...INIT }; emit(); },
  };
}

// ──── Event Bridge (inlined) ───────────────────────────────────────────────

function bridgeEvents(session, store) {
  return session.subscribe((e) => {
    if (!e?.type) return;
    switch (e.type) {
      case "agent_start": store.set({ phase: "streaming" }); break;
      case "agent_end":
        { const s = store.get();
          if (s.streamingText !== null && s.streamingText !== "") {
            store.pushMsg({ role: "assistant", text: s.streamingText });
          }
          store.set({ phase: "ready", streamingText: null }); }
        break;
      case "message_start": store.set({ phase: "streaming", streamingText: "" }); break;
      case "message_update":
        if (e.text) store.set({ streamingText: (store.get().streamingText ?? "") + String(e.text) });
        break;
      case "message_end":
        { const t = store.get().streamingText ?? "";
          if (t) store.pushMsg({ role: "assistant", text: t });
          store.set({ streamingText: null }); }
        break;
      case "tool_execution_start":
        store.upsertTool({ id: String(e.toolCallId ?? ""), name: String(e.toolName ?? "?"), status: "running", input: e.input });
        break;
      case "tool_execution_end":
        store.upsertTool({ id: String(e.toolCallId ?? ""), name: String(e.toolName ?? "?"), status: "done", result: e.result ? String(e.result) : "" });
        break;
      case "model_select":
        store.set({ provider: String(e.provider ?? ""), model: String(e.model ?? "") });
        break;
      case "compaction_start": store.set({ phase: "compacting" }); break;
      case "compaction_end": store.set({ phase: "ready" }); break;
      case "auto_retry_start": store.set({ phase: "retrying" }); break;
      case "auto_retry_end": store.set({ phase: "ready" }); break;
      case "session_start":
        store.set({ sessionId: String(e.sessionId ?? "") });
        break;
    }
  });
}

// ──── useStore hook ─────────────────────────────────────────────────────────

function useStore(store) {
  const [, setN] = useState(0);
  useEffect(() => store.subscribe(() => setN((n) => n + 1)), [store]);
  return store.get();
}

// ──── Helpers ───────────────────────────────────────────────────────────────

function truncate(s, max = 120) {
  if (!s) return "";
  const flat = s.replace(/\n/g, "↵");
  return flat.length > max ? flat.slice(0, max) + "…" : flat;
}

function formatDuration(ms) {
  if (ms < 1000) return `${ms}ms`;
  return `${(ms / 1000).toFixed(1)}s`;
}

// ──── Components ────────────────────────────────────────────────────────────

function Header({ snap }) {
  const phase = snap.phase;
  const color = phase === "streaming" ? "green" : phase === "error" ? "red" : phase === "compacting" ? "yellow" : phase === "retrying" ? "magenta" : "cyan";
  const model = snap.model ? `${snap.provider}/${snap.model}` : "no model";
  return React.createElement(
    Box, { flexDirection: "row", justifyContent: "space-between", paddingX: 1 },
    React.createElement(Text, { bold: true, color: "magenta" }, "🐺 Jackal"),
    React.createElement(Text, { color }, phase),
    React.createElement(Text, { dimColor: true }, model),
  );
}

function ToolCall({ tool }) {
  const icon = tool.status === "running" ? "⏳" : "✓";
  const color = tool.status === "running" ? "yellow" : "green";
  const input = tool.input ? truncate(JSON.stringify(tool.input), 80) : "";
  const result = tool.result ? truncate(tool.result, 100) : "";
  return React.createElement(
    Box, { flexDirection: "column", marginLeft: 2, marginY: 0 },
    React.createElement(Text, {},
      React.createElement(Text, { color }, `${icon} `),
      React.createElement(Text, { bold: true }, tool.name),
      input ? React.createElement(Text, { dimColor: true }, ` ${input}`) : null,
    ),
    result ? React.createElement(
      Box, { marginLeft: 2 },
      React.createElement(Text, { dimColor: true, color: "gray" }, `→ ${result}`),
    ) : null,
  );
}

function ToolPanel({ toolExecutions }) {
  const tools = Object.values(toolExecutions);
  if (tools.length === 0) return null;
  return React.createElement(
    Box, { flexDirection: "column", marginTop: 0, marginBottom: 0 },
    ...tools.slice(-8).map((t) =>
      React.createElement(ToolCall, { key: t.id, tool: t })
    ),
  );
}

function MessageList({ messages, streamingText, toolExecutions }) {
  const items = [];
  const msgSlice = messages.slice(-200);

  for (const msg of msgSlice) {
    const prefix = msg.role === "user" ? "> " : "";
    const color = msg.role === "user" ? "cyan" : "white";
    for (const line of (msg.text || "").split("\n")) {
      items.push(React.createElement(Text, { key: `m-${items.length}`, color }, `${prefix}${line}`));
    }
    items.push(React.createElement(Text, { key: `sp-${items.length}` }, ""));
  }

  // Tool calls (from store, interleaved conceptually)
  const tools = Object.values(toolExecutions);
  if (tools.length > 0) {
    items.push(React.createElement(Text, { key: "tools-label", dimColor: true }, `── tools (${tools.length}) ──`));
    for (const t of tools.slice(-6)) {
      const icon = t.status === "running" ? "⏳" : "✓";
      const c = t.status === "running" ? "yellow" : "green";
      items.push(React.createElement(Text, { key: `t-${t.id}`, color: c }, `  ${icon} ${t.name}`));
    }
    items.push(React.createElement(Text, { key: "tools-end", dimColor: true }, "──────────────"));
  }

  if (streamingText) {
    for (const line of streamingText.split("\n")) {
      items.push(React.createElement(Text, { key: `st-${items.length}`, color: "green" }, line));
    }
  }

  if (items.length === 0) {
    items.push(React.createElement(Text, { dimColor: true }, "No messages yet. Type a prompt and press Enter."));
  }

  return React.createElement(Box, { flexDirection: "column" }, ...items.slice(-120));
}

function StatusBar({ snap }) {
  const parts = [];
  if (snap.phase === "streaming") parts.push("⏳ streaming");
  if (snap.phase === "compacting") parts.push("🗑 compacting");
  if (snap.phase === "retrying") parts.push("🔄 retrying");
  if (snap.error) parts.push(`❌ ${snap.error}`);
  const toolCount = Object.keys(snap.toolExecutions).length;
  const running = Object.values(snap.toolExecutions).filter((t) => t.status === "running").length;
  if (toolCount > 0) parts.push(`🔧 ${toolCount} tools${running > 0 ? ` (${running} running)` : ""}`);
  if (parts.length === 0) parts.push("ready");
  parts.push("Esc=abort");
  return React.createElement(
    Box, { borderStyle: "single", borderColor: "gray", paddingX: 1, justifyContent: "space-between" },
    React.createElement(Text, { dimColor: true }, parts.slice(0, -1).join(" │ ")),
    React.createElement(Text, { dimColor: true, color: "gray" }, parts[parts.length - 1]),
  );
}

function HelpOverlay() {
  return React.createElement(
    Box, { flexDirection: "column", borderStyle: "round", borderColor: "yellow", paddingX: 1 },
    React.createElement(Text, { bold: true, color: "yellow" }, "Commands:"),
    React.createElement(Text, {}, "  /help        Show this help"),
    React.createElement(Text, {}, "  /model       Show current model"),
    React.createElement(Text, {}, "  /clear       Clear messages"),
    React.createElement(Text, {}, "  /tools       Show tool execution log"),
    React.createElement(Text, {}, "  /exit, /quit Exit Jackal"),
    React.createElement(Text, {}, "  Esc          Abort streaming"),
  );
}

function ToolsOverlay({ toolExecutions }) {
  const tools = Object.values(toolExecutions);
  if (tools.length === 0) {
    return React.createElement(
      Box, { flexDirection: "column", borderStyle: "round", borderColor: "cyan", paddingX: 1 },
      React.createElement(Text, { dimColor: true }, "No tool executions recorded."),
    );
  }
  const items = tools.map((t) => {
    const icon = t.status === "running" ? "⏳" : "✓";
    const c = t.status === "running" ? "yellow" : "green";
    const result = t.result ? truncate(t.result, 200) : "(no result)";
    return React.createElement(
      Box, { key: t.id, flexDirection: "column" },
      React.createElement(Text, { color: c }, `${icon} ${t.name}`),
      React.createElement(Text, { dimColor: true }, `   ${result}`),
    );
  });
  return React.createElement(
    Box, { flexDirection: "column", borderStyle: "round", borderColor: "cyan", paddingX: 1 },
    React.createElement(Text, { bold: true }, `Tool Executions (${tools.length})`),
    ...items,
  );
}

// ──── Main App ──────────────────────────────────────────────────────────────

function App({ session, store }) {
  const { exit } = useApp();
  const snap = useStore(store);
  const [input, setInput] = useState("");
  const [overlay, setOverlay] = useState(null); // null | "help" | "tools"

  const clearOverlay = useCallback(() => setOverlay(null), []);

  const handleSubmit = useCallback((text) => {
    const cmd = text.trim();
    if (!cmd) return;

    // Built-in commands
    if (cmd === "/exit" || cmd === "/quit") { exit(); return; }
    if (cmd === "/help") { setOverlay("help"); return; }
    if (cmd === "/clear") { store.set({ messages: [], toolExecutions: {} }); return; }
    if (cmd === "/model") {
      const s = store.get();
      store.pushMsg({ role: "system", text: `Model: ${s.provider}/${s.model}` });
      return;
    }
    if (cmd === "/tools") { setOverlay("tools"); return; }

    // Send to Pi
    store.pushMsg({ role: "user", text: cmd });
    session.sendUserMessage(cmd).catch((err) => {
      store.set({ error: err?.message || String(err) });
    });
  }, [session, store, exit]);

  useInput((char, key) => {
    if (overlay) {
      // Any key dismisses overlay
      clearOverlay();
      return;
    }

    if (key.return) {
      handleSubmit(input);
      setInput("");
    } else if (key.backspace || key.delete) {
      setInput((p) => p.slice(0, -1));
    } else if (key.escape) {
      try { session.abort(); } catch {}
    } else if (char && !key.ctrl && !key.meta) {
      setInput((p) => p + char);
    }
  });

  return React.createElement(
    Box, { flexDirection: "column", padding: 0 },
    React.createElement(Header, { snap }),
    React.createElement(Box, { marginY: 0 },
      React.createElement(Text, { color: "gray" }, "─".repeat(60)),
    ),
    overlay === "help"
      ? React.createElement(HelpOverlay)
      : overlay === "tools"
        ? React.createElement(ToolsOverlay, { toolExecutions: snap.toolExecutions })
        : React.createElement(MessageList, {
            messages: snap.messages,
            streamingText: snap.streamingText,
            toolExecutions: snap.toolExecutions,
          }),
    React.createElement(StatusBar, { snap }),
    React.createElement(
      Box, { marginTop: 0 },
      React.createElement(Text, { color: "green", bold: true }, "❯ "),
      React.createElement(Text, {}, input),
      React.createElement(Text, { dimColor: true }, "█"),
    ),
  );
}

// ──── Boot ──────────────────────────────────────────────────────────────────

async function main() {
  const cwd = process.cwd();
  const store = createStore();

  process.stdout.write("\x1b]0;Jackal - Coding Agent\x07");

  const { session } = await createAgentSession({
    cwd,
    sessionManager: SessionManager.inMemory(cwd),
  });

  const unsub = bridgeEvents(session, store);
  store.set({ phase: "ready" });

  const cleanup = () => {
    unsub();
    try { session.dispose(); } catch {}
    process.exit(0);
  };

  process.on("SIGINT", cleanup);
  process.on("SIGTERM", cleanup);
  session.subscribe((e) => { if (e?.type === "session_shutdown") cleanup(); });

  render(React.createElement(App, { session, store }));
}

main().catch((err) => {
  console.error("Jackal failed to start:", err);
  process.exit(1);
});
