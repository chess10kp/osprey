  1. Agent modes & runtime model

  ┌──────────────────────────────┬───────────────────────────────────────────────────┐
  │ Cursor CLI                   │ Jackal                                            │
  ├──────────────────────────────┼───────────────────────────────────────────────────┤
  │ Debug ties into runtime      │ Debugging is “read code + bash + jac check”       │
  │ logging / instrumentation    │                                                   │
  └──────────────────────────────┴───────────────────────────────────────────────────┘

  2. Built-in tools Cursor has natively

  ┌─────────────────────────────────┬───────┬────────────────────────────────────────┐
  │ Capability                      │ Curso │ Jackal                                 │
  │                                 │ r     │                                        │
  │                                 │ CLI   │                                        │
  ├─────────────────────────────────┼───────┼────────────────────────────────────────┤
  │ Semantic codebase search        │ ✓    │ ❌ — glob + bash grep + ast_search /   │
  │ (semSearch over an index)       │       │ LSP only                               │
  │ Browser automation (first-class │ ✓    │ ❌ in default pi/mcp.json (only jac;   │
  │ tool + browser subagent)        │       │ browser would need MCP wiring)         │
  │ Mid-turn user questions (agent  │ ✓    │ ❌ — blocking TUI input only           │
  │ asks, keeps going)              │       │                                        │
  │ Dynamic rule fetch (Fetch Rules │ ✓    │ ❌ — static SYSTEM.md + skill index    │
  │ tool)                           │       │                                        │
  │ Edit preview                    │ ✓    │ ❌                                     │
  │ (string_replace_preview)        │       │                                        │
  │ Dedicated git tools (11 named   │ ✓    │ 🟡 — all via bash                      │
  │ git ops)                        │       │                                        │
  └─────────────────────────────────┴───────┴────────────────────────────────────────┘

  3. Sandbox, permissions, and safety

  ┌───────────────────────────────┬───────────────┬──────────────────────────────────┐
  │ Capability                    │ Cursor CLI    │ Jackal                           │
  ├───────────────────────────────┼───────────────┼──────────────────────────────────┤
  │ OS sandbox (Landlock /        │ ✓            │ ❌ — full bash on host           │
  │ Seatbelt / WSL2)              │ sandbox.json  │                                  │
  │                               │ + --sandbox   │                                  │
  │ Permission patterns           │ ✓            │ 🟡 — session approval queue, not │
  │ (Shell(**), Mcp(server,tool), │ ~/.cursor/cli │ pattern-based allowlists         │
  │ etc.)                         │ -config.json  │                                  │
  │ Protection toggles (dotfiles, │ ✓            │ ❌                               │
  │ external files, delete,       │               │                                  │
  │ browser)                      │               │                                  │
  │ Command injection scanning    │ ✓ (hooks +   │ ❌                               │
  │                               │ guards)       │                                  │
  │ Directory trust / first-run   │ ✓            │ ❌                               │
  │ safety                        │               │                                  │
  │ .cursorignore (block paths    │ ✓            │ 🟡 — gitignore-aware search      │
  │ from agent)                   │               │ exists; no full ignore layer for │
  │                               │               │ reads                            │
  └───────────────────────────────┴───────────────┴──────────────────────────────────┘

  4. Hooks & extensibility

  ┌────────────────────────────────────────────┬──────────┬──────────────────────────┐
  │ Capability                                 │ Cursor   │ Jackal                   │
  │                                            │ CLI      │                          │
  ├────────────────────────────────────────────┼──────────┼──────────────────────────┤
  │ hooks.json (preToolUse,                    │ ✓       │ ❌                       │
  │ beforeShellExecution, afterFileEdit,       │          │                          │
  │ subagentStart, …)                          │          │                          │
  │ Custom callable tools (.cursor/tools /     │ ✓ /     │ ❌ — .jackal/commands    │
  │ nanocoder-style)                           │ partial  │ are prompt templates     │
  │                                            │          │ only                     │
  │ Config env substitution (${env:VAR})       │ ✓ in    │ ❌                       │
  │                                            │ MCP/conf │                          │
  │                                            │ ig       │                          │
  │ XML tool-calling fallback for weak tool    │ ✓       │ ❌ — native tool APIs    │
  │ models                                     │          │ only                     │
  └────────────────────────────────────────────┴──────────┴──────────────────────────┘

  5. MCP platform (beyond “has MCP”)

  Both can use MCP, but Cursor’s platform is richer:

  • OAuth / agent mcp login and CLI management (enable, disable, list-tools)
  • MCP Apps (interactive UI in chat)
  • Permission tokens per server/tool in config
  • HTTP/SSE MCP with cloud-safe proxying
  • Multiple servers with interpolation (${workspaceFolder}, etc.)

  Jackal today: jac only in pi/mcp.json, lazy connect, no browser/context7 unless you
  add servers yourself.

  6. Subagents & orchestration

  ┌────────────────────────────┬────────────┬────────────────────────────────────────┐
  │ Capability                 │ Cursor CLI │ Jackal                                 │
  ├────────────────────────────┼────────────┼────────────────────────────────────────┤
  │ Built-in explore / bash /  │ ✓         │ ❌ — custom                            │
  │ browser subagents          │ auto-deleg │ scout/architect/implementer only       │
  │                            │ ated       │                                        │
  │ Parallel Task tool +       │ ✓         │ 🟡 — agent tool + chains; no           │
  │ resume subagent by ID      │            │ nested/resume IDs like Cursor          │
  │ readonly subagents         │ ✓         │ ❌                                     │
  │ Cloud handoff (& → VM      │ ✓         │ ❌ — local Ink only                    │
  │ agent)                     │            │                                        │
  └────────────────────────────┴────────────┴────────────────────────────────────────┘

  Jackal is strong on Jac-specific chains (pi/chains/*.chain.md) — that’s a
  differentiator, not a gap.

  7. Skills, rules, and memory

  ┌───────────────────────────────────────┬────────────┬─────────────────────────────┐
  │ Capability                            │ Cursor CLI │ Jackal                      │
  ├───────────────────────────────────────┼────────────┼─────────────────────────────┤
  │ Layered rules (Always / Intelligent / │ ✓         │ 🟡 — AGENTS.md + SYSTEM.md, │
  │ Globs / Manual @)                     │ .cursor/ru │ no rule types               │
  │                                       │ les        │                             │
  │ Team / user rules from dashboard      │ ✓         │ ❌                          │
  │ Skills auto-discovery + /skill-name   │ ✓         │ ✅ pi/skills/ (similar      │
  │                                       │            │ idea)                       │
  │ /compress with thread summary         │ ✓         │ ✅ /compact (similar)       │
  └───────────────────────────────────────┴────────────┴─────────────────────────────┘

  8. Background work & CLI ergonomics

  ┌────────────────────────────────┬─────────┬───────────────────────────────────────┐
  │ Capability                     │ Cursor  │ Jackal                                │
  │                                │ CLI     │                                       │
  ├────────────────────────────────┼─────────┼───────────────────────────────────────┤
  │ Background shells + wake on    │ ✓      │ ❌ — bash runs to completion          │
  │ regex output                   │         │                                       │
  │ /loop / monitored terminal     │ ✓      │ ❌                                    │
  │ files                          │         │                                       │
  │ Git worktrees (--worktree)     │ ✓      │ ❌                                    │
  │ Headless stream-json / partial │ ✓      │ 🟡 — jackal run --plain, not full     │
  │ stream                         │         │ event stream                          │
  │ Session resume by ID (agent    │ ✓      │ ✅ /resume (similar)                  │
  │ resume)                        │         │                                       │
  │ Vim input / custom status line │ ✓      │ ❌                                    │
  │ ACP server (agent acp)         │ ✓      │ ❌                                    │
  │ @cursor/sdk programmatic API   │ ✓      │ ❌ — adapter is internal, no public   │
  │                                │         │ SDK                                   │
  └────────────────────────────────┴─────────┴───────────────────────────────────────┘

  9. Cloud & product surface (intentionally out of scope for Jackal)

  • Cloud agents (VM, desktop use, continue on web, CI autofix)
  • Bugbot, Slack/Linear/Jira integrations
  • Enterprise IAM, SCIM, pooled usage, sandbox policy from dashboard
  • Cursor Blame / AI commit messages in IDE

  Jackal’s FEATURES.md explicitly defers hosting/models/cloud — so these are gaps vs
  Cursor, but often by design.

  10. Nanocoder-style gaps still relevant (not Cursor-specific)

  From your own parity doc, Jackal also lacks vs a “full” terminal agent baseline:

  • Streaming bash output while command runs
  • Reasoning/thinking blocks in the TUI (showThinkingBlocks)
  • /tune, scheduler/cron, model database browse
  • Web research (unless you add MCP)
  • Structured logging (pino-style correlation IDs)
  • Custom tools (.jackal/tools/*.md with schemas)

  ────────────────────────────────────────

  What Jackal has that Cursor CLI does not

  Worth stating so the comparison isn’t one-sided:

  • Jac MCP as the primary toolchain (validate_jac, run_jac, search_docs, graph viz,
    etc.)
  • Jac workflows: /jac-check, /jac-doctor, autocheck-on-edit, /osp, Jac explain
    templates
  • Ink TUI tuned for Jac dev (tool timeline, Jac-specific subagents)
  • Checkpoint/task workflows aligned with .jackal project config

  ────────────────────────────────────────

  Practical “missing for parity” short list

  If the goal is “Jackal harness ≈ Cursor CLI for daily coding,” the highest-impact
  gaps are:

  1. Ask + Debug modes (not just plan-as-filter)
  2. Semantic search + web search/fetch
  3. OS sandbox + permission allowlists
  4. Hooks (hooks.json lifecycle)
  5. Background shells + streaming tool output
  6. Browser + vision + image tools (or documented MCP wiring for them)
  7. Broader MCP config (multi-server, OAuth, per-tool permissions)
  8. Headless/SDK surface (stream-json, public agent API)

  If you want, we can turn this into a tracked parity section in
  docs/NANOCODER-PARITY.md (Cursor column next to Nanocoder) or a focused roadmap
  slice for the harness.



