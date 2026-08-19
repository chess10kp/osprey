# Jackal TUI — thin Ink client

```
brain:  app/main.jac (Jac, owned ReAct loop)     ← all state lives here
wire:   JSONL over stdio (--json mode)           ← the only coupling
UI:     tui/ TSX on ink (node + tsx)             ← disposable renderer
```

## Run

```bash
~/repos/jackal/tui/jackal-tui [target-dir]     # default: $PWD
```

Requirements: `node` 20+, `jac` on PATH (or `~/.local/bin`), one provider key
in the environment (`OPENROUTER_API_KEY` / `DEEPSEEK_API_KEY` / `OPENAI_API_KEY`)
— or `~/.pi/agent/auth.json` with an `openrouter.key`, which the launcher reads.

Keys: type to compose, Enter submit, Up/Down history, Ctrl+U clear line,
Ctrl+C quit. Commands: `/model NAME`, `/clear`, `/help`, `/exit`.

## JSONL protocol (`jac run app/main.jac -- --json`)

**In** (one JSON object per line):
```json
{"type": "user",    "text": "..."}
{"type": "command", "text": "/model openrouter/..."}
```

**Out:**
```json
{"type": "session_ready", "model": "...", "cwd": "..."}
{"type": "chunk",       "content": "..."}        // live model token
{"type": "tool_call",   "tool": "...", "args": {...}}
{"type": "tool_result", "tool": "...", "result": "..."}
{"type": "turn_end",    "secs": 1.2, "tools": 2}
{"type": "info",        "text": "..."}           // command replies
{"type": "error",       "message": "..."}
{"type": "session_end"}
```

The brain keeps running if the UI dies — restart the TUI and history is in
the brain process (until we add brain-side session persistence; then the UI
becomes fully stateless).

## Notes

- `node --import tsx` runs the TSX; no bundler. `bun` also works for
  non-interactive bits but garbles ink frames — use node.
- ink 7's `parseKeypress` handles one keypress per stdin chunk; pasted
  newlines are split manually in `Input` (see comment in `app.tsx`).
- `@inkjs/ui` v2 renders broken frames in this environment; the input is
  hand-rolled on `useInput` (~40 lines) — no extra deps beyond ink+react.
