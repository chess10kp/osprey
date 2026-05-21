// ────────────────────────────────────────────────────────────────────────────
// Jackal TUI Shell — emitted into .jac/tui/ as the Ink rendering host.
//
// This is a template that gets written as shell.mjs by the build pipeline.
// It imports Pi SDK + Ink + the compiled user module, wires everything
// together, and renders the interactive coding agent TUI.
//
// Dependencies (resolved from emitted package.json):
//   ink, react, @earendil-works/pi-coding-agent, @earendil-works/pi-ai
// ────────────────────────────────────────────────────────────────────────────

import React, { useState, useEffect, useCallback, useRef } from "react";
import { render, Box, Text, useInput, useApp, useStdout } from "ink";
import { createAgentSession, SessionManager, AuthStorage, ModelRegistry } from "@earendil-works/pi-coding-agent";

// ──── Store (inlined — no separate file needed) ────────────────────────────

const INITIAL_SNAPSHOT = {
  phase: "booting",
  model: "",
  provider: "",
  sessionId: "",
  sessionName: "",
  messages: [],
  streamingText: null,
  toolExecutions: {},
  error: null,
};

function createStore() {
  let snapshot = { ...INITIAL_SNAPSHOT };
  const listeners = new Set();
  return {
    get: () => snapshot,
    subscribe: (fn) => { listeners.add(fn); return () => listeners.delete(fn); },
    set: (partial) => { snapshot = { ...snapshot, ...partial }; for (const l of listeners) try { l(); } catch {} },
    pushMessage: (msg) => { snapshot = { ...snapshot, messages: [...snapshot.messages, msg] }; for (const l of listeners) try { l(); } catch {} },
    reset: () => { snapshot = { ...INITIAL_SNAPSHOT }; for (const l of listeners) try { l(); } catch {} },
  };
}

// ──── Event Bridge (inlined) ───────────────────────────────────────────────

function bridgeEvents(session, store) {
  return session.subscribe((event) => {
    if (!event?.type) return;
    switch (event.type) {
      case "agent_start": store.set({ phase: "streaming" }); break;
      case "agent_end":
        if (store.get().streamingText !== null) {
          const text = store.get().streamingText ?? "";
          store.pushMessage({ role: "assistant", text });
          store.set({ phase: "ready", streamingText: null });
        } else {
          store.set({ phase: "ready" });
        }
        break;
      case "message_start": store.set({ phase: "streaming", streamingText: "" }); break;
      case "message_update":
        if (event.text) {
          const cur = store.get().streamingText ?? "";
          store.set({ streamingText: cur + String(event.text) });
        }
        break;
      case "message_end":
        { const text = store.get().streamingText ?? "";
          store.pushMessage({ role: "assistant", text });
          store.set({ streamingText: null }); }
        break;
      case "model_select":
        store.set({ provider: event.provider ? String(event.provider) : "", model: event.model ? String(event.model) : "" });
        break;
      case "session_start":
        store.set({ sessionId: String(event.sessionId ?? ""), sessionName: String(event.sessionName ?? "") });
        break;
      case "compaction_start": store.set({ phase: "compacting" }); break;
      case "compaction_end": store.set({ phase: "ready" }); break;
      case "auto_retry_start": store.set({ phase: "retrying" }); break;
      case "auto_retry_end": store.set({ phase: "ready" }); break;
    }
  });
}

// ──── useStore hook ─────────────────────────────────────────────────────────

function useStore(store) {
  const [, forceUpdate] = useState(0);
  useEffect(() => {
    return store.subscribe(() => forceUpdate((n) => n + 1));
  }, [store]);
  return store.get();
}

// ──── Components ────────────────────────────────────────────────────────────

function Header({ snapshot }) {
  const phase = snapshot.phase;
  const color = phase === "streaming" ? "green" : phase === "error" ? "red" : phase === "compacting" ? "yellow" : "cyan";
  const model = snapshot.model ? `${snapshot.provider}/${snapshot.model}` : "no model";
  return React.createElement(
    Box,
    { flexDirection: "row", justifyContent: "space-between", paddingX: 1 },
    React.createElement(Text, { bold: true, color: "magenta" }, "Jackal"),
    React.createElement(Text, { color }, phase),
    React.createElement(Text, { dimColor: true }, model),
  );
}

function MessageList({ messages, streamingText }) {
  const items = [];
  for (const msg of messages) {
    const prefix = msg.role === "user" ? "> " : "";
    const color = msg.role === "user" ? "cyan" : "white";
    const lines = (msg.text || "").split("\n");
    for (const line of lines) {
      items.push(React.createElement(Text, { key: `m-${items.length}`, color }, `${prefix}${line}`));
    }
    items.push(React.createElement(Text, { key: `s-${items.length}` }, ""));
  }
  if (streamingText) {
    const lines = streamingText.split("\n");
    for (const line of lines) {
      items.push(React.createElement(Text, { key: `st-${items.length}`, color: "green" }, line));
    }
  }
  if (items.length === 0) {
    items.push(React.createElement(Text, { dimColor: true }, "No messages yet. Type a prompt and press Enter."));
  }
  return React.createElement(Box, { flexDirection: "column" }, ...items.slice(-100));
}

function StatusBar({ snapshot }) {
  const parts = [];
  if (snapshot.phase === "streaming") parts.push("⏳ streaming");
  if (snapshot.phase === "compacting") parts.push("🗑 compacting");
  if (snapshot.phase === "retrying") parts.push("🔄 retrying");
  if (snapshot.error) parts.push(`❌ ${snapshot.error}`);
  if (parts.length === 0) parts.push("ready");
  return React.createElement(
    Box,
    { borderStyle: "single", borderColor: "gray", paddingX: 1 },
    React.createElement(Text, { dimColor: true }, parts.join(" │ ")),
  );
}

// ──── Main App ──────────────────────────────────────────────────────────────

function App({ session, store }) {
  const { exit } = useApp();
  const snapshot = useStore(store);
  const [input, setInput] = useState("");
  const [history, setHistory] = useState([]);

  const handleSubmit = useCallback(() => {
    const text = input.trim();
    if (!text) return;
    if (text === "/exit" || text === "/quit") { exit(); return; }
    setInput("");
    store.pushMessage({ role: "user", text });
    setHistory((h) => [...h, text]);
    session.sendUserMessage(text).catch((err) => {
      store.set({ error: err?.message || String(err) });
    });
  }, [input, session, store, exit]);

  useInput((char, key) => {
    if (key.return) {
      handleSubmit();
    } else if (key.backspace) {
      setInput((prev) => prev.slice(0, -1));
    } else if (key.escape) {
      // Abort streaming
      try { session.abort(); } catch {}
    } else if (char && !key.ctrl && !key.meta) {
      setInput((prev) => prev + char);
    }
  });

  return React.createElement(
    Box,
    { flexDirection: "column", padding: 0 },
    React.createElement(Header, { snapshot }),
    React.createElement(Box, { marginY: 0, flexDirection: "column" },
      React.createElement(Text, { color: "gray" }, "─".repeat(60)),
    ),
    React.createElement(MessageList, {
      messages: snapshot.messages,
      streamingText: snapshot.streamingText,
    }),
    React.createElement(StatusBar, { snapshot }),
    React.createElement(
      Box,
      { marginTop: 0 },
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

  const unsubBridge = bridgeEvents(session, store);
  store.set({ phase: "ready" });

  const cleanup = () => {
    unsubBridge();
    try { session.dispose(); } catch {}
    process.exit(0);
  };

  process.on("SIGINT", cleanup);
  process.on("SIGTERM", cleanup);

  render(React.createElement(App, { session, store }));

  // Graceful shutdown on exit
  session.subscribe((event) => {
    if (event?.type === "session_shutdown") cleanup();
  });
}

main().catch((err) => {
  console.error("Jackal failed to start:", err);
  process.exit(1);
});
