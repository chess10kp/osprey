# OSPUI Priority 0 — Implementation Plan

**Input:** `PLAN.md` (Priority 0 tasks), `OSPUI.md` (authoritative spec), `ROADMAP.md` (N1 delivery order).
**Scope:** implement all 13 Priority-0 tasks. Gates 1–6 harnesses are included (task 13); passing them is the completion gate.
**Status of this doc:** findings verified against the actual toolchain and codebase on 2026-08-18, before implementation.

---

## 1. Verified toolchain findings (probed, not assumed)

| # | Finding | Consequence |
|---|---------|-------------|
| F1 | `jac 0.36.1` on Linux. `cd app && JAC_TEST_JOBS=0 jac test ui/model.jac` → 8 passed. | Serial test jobs required. Parallel workers race on the pg-embed cache; a crashed run can also leave a stale `~/.cache/jac/pg/main` that breaks `initdb` (fix: `rm -rf ~/.cache/jac/pg/main`). |
| F2 | First `jac run` in `app/` performs one-time venv setup (~25 s) plus pg-embed download noise; subsequent runs are quiet and fast. | CI/dev commands must warm the cache; don't treat pg WARNING/INFO as failure. |
| F3 | `jid(node)` returns a 32-char string, not the node. | Perfect for stable side-table keys (`dict[jid, ...]`); never compare `jid(a) == a`. |
| F4 | Typed edges fully work: `edge Child: A --> A { has rank: int; }`, `p +>:Child(rank=0):+> c`, `[p ->:Child:->]`, edge handles `[edge p ->:Child:-> c]` support attribute write and `del`. | Sparse-rank mutation module is implementable exactly as specified. Edge handles must be captured into a variable before `del`. |
| F5 | Walkers with inline node abilities work: `can ring with Ping entry { visitor.hits += 1; }` + `node spawn walker` is synchronous; walker state readable afterwards. | Event dispatch = runtime computes bubble path, spawns the **same** walker instance at each node until `propagation_stopped`. Arrival dispatch is node-owned, as spec §13.4 requires. |
| F6 | `impl Widget { can ring with Ping entry }` annex in the same file **compiled but did not dispatch** (hits=0; inline version hits=1). | Treat cross-module/annex ability attachment as unavailable in 0.36.1. Product abilities are declared on the node declaration inside the product module (spec-preferred). Framework default actions live in the runtime dispatch loop, not annex abilities. If Gate 5 (external widget package) needs cross-package abilities, that is a jaclang human handoff — document, don't shim. |
| F7 | `root` is a reserved built-in name even inside test files. | Use `base`/`top`/`ui_root` in code and tests. |
| F8 | Several constructs (`FuncCall`, `EdgeRefTrailer`) fail native lowering and fall back to the server codespace with a note. | Pin all new `ui.*` modules to `server` in `app/jac.toml` (`[placement.pins]`) so we don't rely on noisy fallback. |
| F9 | `tui/pi_jac_floor/src/terminal.jac`, `keys.jac` (776 LOC), `stdin_buffer.jac` are js2jac translations bound to Node globals (`process.stdout`, `fs`) via `terminal_support` shims. | Product adapters under `app/ui/` are **rewrites in Python idiom** (termios/tty/select/signal) porting behavior only — raw mode, bracketed paste, escape buffering, key normalization, resize, restoration. No Node shims in `app/`. |

## 2. Codebase findings

- `app/ui/model.jac` (582 LOC) is the prototype: `view(render_fn, …)` closures, dirty/cached/painted state **on nodes**, dense integer order, automatic `Feeds` capture from reads. Spec/PLAN say **replace, don't layer**.
- Consumers of the old interface (all must be updated or retired in the same commit that breaks them): `app/ui/model.test.jac` (8 tests — keep compatible cases, rewrite the rest), `app/ui/paint.jac` (retired by the retained renderer), `scripts/osp-tui-smoke.jac` (legacy flat-diff path — retire), `scripts/osp-region-smoke.jac` (region paint — superseded; keep as history or port), `app/ui/README.md` (rewritten at the end).
- `app/agent/` (session/llm/tools/system) is a synchronous ReAct loop with an `on_event(kind, data)` boundary — the seam to grow `protocol.jac` on. No UI coupling today.
- The working tree is already dirty with unrelated in-progress work (status-bar disk space, README edits, parity smoke files). Plan preserves them untouched; every unit below is its own commit (AGENTS.md rule 1).
- `app/jac.toml` `[placement.pins]` currently pins `"ui.model" = "server"` only.

## 3. Target module map

```
app/ui/
  model.jac        UiNode/UiContainer/UiRegion/UiSessionRoot/Screen/Overlay + product
                   archetypes (MainScreen, TranscriptView, Prompt, Status,
                   ApprovalOverlay, Header) + Child(rank)/Owns/Feeds/FocusNext/
                   Layer(z_index, modal) edges. Nodes carry ONLY key + semantic
                   state. jid is the stable ID.
  mutation.jac     append_child / insert_before / insert_after / move_before /
                   move_after / detach / replace. Sparse ranks (gap 1024,
                   normalize on exhaustion), cycle + single-parent + duplicate-key
                   + rank validation, atomic failure, graph-revision bump,
                   smallest-affected-layout-root invalidation.
  runtime.jac      UiSession: owns detached root, current screen, focus, event
                   queue, graph revision, invalidation journal, renderer, bindings,
                   capability registry, disposed tracking. Orderly dispose +
                   leak detection (orphaned bindings, stale edges, invalid focus,
                   unreleased capabilities, registry-retained subgraphs).
  bindings.jac     BindingRegistry: subscribe/unsubscribe/deliver by
                   (domain source_id, target jid, event archetype). Refuses
                   persistent-root → UI edges by construction (no API exists).
  events.jac       UiEvent walker base (handled / propagation_stopped /
                   default_prevented / effects) + InsertText, Submit, Cancel,
                   MoveFocus, Resize, StreamChunk, TranscriptChanged walkers;
                   Effect objs (SendPrompt, CopyToClipboard, SpawnProcess, Quit);
                   dispatch(target resolution order: topmost modal → focused →
                   screen root → explicit binding target), bubble over the unique
                   Child containment path, default actions, post-propagation
                   effect execution hook.
  width.jac        ANSI-aware display width: wide + combining Unicode,
                   wrapping, truncation (Python `unicodedata`; no East-Asian
                   tables vendored).
  terminal.jac     Terminal interface + ProcessTerminal (termios raw mode,
                   alternate screen, SIGWINCH resize, bracketed paste,
                   complete escape buffering, synchronized output, restoration
                   on normal exit / exception / SIGINT).
  virtual_terminal.jac  In-memory Terminal + input-event injection; cell capture
                   for tests. No I/O.
  input.jac        Byte → semantic-event normalization + coalescing (resize
                   storms, mouse motion, paste blocks, stream chunks) so raw
                   bytes never become walkers (spec §13.1).
  layout.jac       Renderer side tables keyed by jid: contract, measured size,
                   current/previous rect. Contracts: fixed, intrinsic, bounded,
                   grow, viewport, overlay. Vertical composition + the horizontal
                   fragments Jackal needs. Measure bottom-up, arrange top-down,
                   width-dependent wrapping, clipping, scrolling.
  renderer.jac     Retained cell buffer, damage = union(old,new) rects, repair
                   moved/shrunk/obscured/removed/restyled/clipped/cursor regions,
                   desired-cells paint for damaged areas, cell diff, ONE
                   synchronized ANSI update per frame, cursor state (exactly one
                   requester; relocation/cleanup on close). Retires paint.jac.
  inspect.jac      dump_graph / dump_bindings / dump_event_path /
                   explain_invalidation / dump_layout / dump_damage /
                   dump_lifetimes + deterministic invariant validation
                   (cycles, duplicate keys, invalid ranks, stale edges, invalid
                   focus, orphaned bindings, leaked capabilities).
  markup.jac       One-time lowering: statically registered tag → archetype map,
                   keys, initial state, containment order, owns/focus/feed/layer
                   relations, domain bindings. Unknown tag/property = error.
                   `--print-generated` mode emits equivalent direct-construction
                   Jac. No virtual tree, no per-frame view, no runtime archetype
                   generation. (No compiler extension exists for lowering in
                   0.36.1 → direct construction stays primary; upstream request
                   documented for the human.)
  screen.jac       The Jackal shell: MainScreen(TranscriptView, Status, Prompt)
                   built once under UiSessionRoot; multiline editing (draft,
                   cursor, history, paste, submit/cancel), status fragments,
                   modal ApprovalOverlay lifecycle (open: save focus, trap input,
                   focus initial target, damage bounds; close: unbind, dispose,
                   restore focus, damage old rect). Node-ID stability checks.
  transcript.jac   Transcript projection: messages stay in domain state;
                   TranscriptView binds source_id + observed_revision +
                   scroll_offset + follow_tail. Renderer materializes visible
                   wrapped lines + overscan only; measurement cache keyed by
                   (message_id, width, content_rev, style_rev); follow-tail vs
                   anchor preservation; off-screen changes ⇒ no damage.
app/agent/
  protocol.jac     Versioned command/event envelopes (session, request, turn,
                   tool, sequence, correlation IDs); bounded queues; structural
                   order preservation; text-delta coalescing; turn + subprocess-
                   group cancellation with correlated completion events; typed
                   in-process adapter for the TUI; term + JSONL adapters stay.
app/ui/widgets/progress/   Gate-5 external package: ProgressBar node + SetProgress
                   event + measure/paint behavior + disposal + inspection +
                   markup registration — no framework-source edits.
app/ui/gates/      Gate harnesses: gate1_detached_lifecycle, gate2_prompt_vs_callback,
                   gate3_layout_damage, gate4_invalidation_bench, gate6_authoring_scale.
```

## 4. Key design decisions (locked by spec + probes)

1. **Identity** — `jid(node)` string keys everywhere outside the graph; side tables (`layout.jac`, `renderer.jac`, `runtime.jac` journals) live in `UiSession`-owned objects, never on nodes.
2. **Dispatch** — runtime-driven target-and-bubble: compute path target→screen via `[n <-:Child:<-]`, spawn the same walker instance at each stop (F5), honoring `propagation_stopped` independently of `handled`/`default_prevented`. Effects execute only after propagation completes.
3. **One handler per archetype per node** — enforced by Jac itself: abilities are declared once on the node declaration (F6); no runtime registry of closures keyed by ID (explicit non-goal).
4. **Ranks** — sparse with 1024 gap; normalization only when the gap is exhausted; callers never renumber. Every mutation validates first (cycle, single parent, duplicate sibling key, rank bounds) and fails atomically before touching edges.
5. **Revision** — `UiSession.graph_revision += 1` on every successful structural change; renderer snapshots the revision per frame; mid-frame change ⇒ frame abandoned and recomputed (exceptional under single-writer).
6. **Terminal** — Python stdlib only (`termios`, `tty`, `select`, `signal`, `fcntl`/`termios.TIOCGWINSZ`); behavior ported from `tui/pi_jac_floor`, code not. Input normalizer coalesces before walker creation.
7. **Transcript virtualization** — never OSP nodes for lines/cells; domain list + `(message_id, width, content_rev, style_rev)` measurement cache; visible + overscan window only.
8. **Detachment proof (Gate 1)** — no API attaches UI nodes to persistent `root` (mutations only accept `UiContainer` parents reachable from `UiSessionRoot`); test walks persistent root's edges and asserts no UI jid is reachable, spawns walkers, runs persistence ops, disposes, and asserts registries/renderer state/binding maps are empty.
9. **Baseline comparisons (Gates 2/4)** — callback-prompt and full-frame/region/Feeds-invalidation baselines live beside the OSP versions in `app/ui/gates/` as plain Jac programs measuring code size, nodes queried, allocations, cells written, wall time.

## 5. Commit sequence (each = one PR-sized unit, tests green at every step)

| # | Unit | Contents | Acceptance check |
|---|------|----------|------------------|
| 1 | Semantic graph model | Rewrite `model.jac` (nodes, archetypes, 5 typed edges, jid identity, no renderer state on nodes); rewrite `model.test.jac` (keep compatible cases: ordering, cleanup, movement) | `JAC_TEST_JOBS=0 jac test ui/model.jac`; `jac check .` |
| 2 | Topology mutation | `mutation.jac` + tests: sparse ranks, insert/move/detach/replace, atomic failure, cycle/dup/rank rejection, revision bump, layout-root invalidation | new test file green |
| 3 | Session + bindings + dispose | `runtime.jac`, `bindings.jac` + tests: detached ownership, focus registry, orderly disposal, leak detection | tests incl. orphan-binding + stale-edge negatives |
| 4 | Events + effects | `events.jac` + tests: resolution order, target-and-bubble, three independent flags, default actions, effects-after-propagation, one-handler rule | tests green |
| 5 | Width + terminal adapters + input | `width.jac`, `terminal.jac`, `virtual_terminal.jac`, `input.jac` + tests: fragmented escapes, Unicode, multiline paste, resize coalescing, restoration on normal/exception/SIGINT exits (virtual; PTY smoke script optional here, required by N1 later) | virtual-terminal tests green |
| 6 | Layout + renderer | `layout.jac`, `renderer.jac`; retire `paint.jac` and update the two `scripts/osp-*-smoke.jac` consumers; tests: growth/shrink/move/resize/Unicode/clipping/overlay restoration/cursor cleanup; patch-scope assertions so full clears can't hide damage bugs | renderer tests green; `jac check .` |
| 7 | Focus/layers/overlays | runtime focus order from containment (+`FocusNext` overrides), single cursor requester, z-order paint up / input down, modal trap, close-restore-damage | overlay lifecycle tests green |
| 8 | Jackal shell topology | `screen.jac` + tests: stable IDs across typing/streaming/resize/focus/overlay cycles; multiline editor behaviors; approval overlay round-trip | screen tests green |
| 9 | Typed agent seam | `app/agent/protocol.jac`: envelopes, bounded queues, delta coalescing, cancellation; in-process adapter driving `screen.jac`; term/JSONL unchanged | protocol + adapter tests green |
| 10 | Transcript virtualization | `transcript.jac` + tests: visible+overscan materialization, measurement cache reuse, follow-tail, anchor preservation, off-screen ⇒ no damage | streaming tests green |
| 11 | Inspection surface | `inspect.jac` + tests: all dumps deterministic, invalidation records link event/feed → layout root → damage | inspect tests green |
| 12 | Markup lowering | `markup.jac` + tests: tag/property errors, generated-print mode, equivalence with direct construction for the shell screen | markup tests green |
| 13 | Gates 1–6 + docs | gate harnesses; `widgets/progress` package; benchmark numbers recorded in `app/ui/README.md` (rewritten: stable interface, lifetimes, invariants, migration rules, validation commands) | all gates pass; README final |

Commits 5–6 and 9 are the riskiest (fresh terminal code, async seam); they land behind the virtual-terminal harness so failures are reproducible without a TTY.

## 6. Validation commands

```bash
cd app
JAC_TEST_JOBS=0 jac test ui/<module>.test.jac   # per module
JAC_TEST_JOBS=0 jac test .                      # full suite (warm cache first)
jac check .                                     # whole app compiles
cd ..
JACPATH=app jac run app/ui/gates/gate<N>_*.jac  # gate harnesses
```

## 7. Risks & human handoffs

- **Annex/impl dispatch (F6)** — if Gate 5 cannot register a cross-package widget without framework edits, file a jaclang issue (annex ability dispatch or a supported lowering extension) and keep the ProgressBar package in-repo under `app/ui/widgets/` until then. No compiler shims.
- **pg-embed flakiness (F1/F2)** — serial test jobs; consider `JAC_TEST_JOBS=0` in CI wrapper scripts.
- **PTY tests** — spec asks for virtual *and* PTY coverage; PTY runs need a real TTY. Virtual tests are mandatory per commit; PTY smoke is bundled into the gate scripts and may require a `-e` flag or script-driven `script(1)` session.
- **Native pins (F8)** — add `"ui.*" = "server"` pins; revisit only if profiling (Gate 4) shows a need.
- **Scale** — units 5, 6, 8, 10 are each 400–700 LOC with tests; if a unit balloons, split the commit but keep every commit green.

## 8. Non-goals restated (guard rails)

No web/second renderer, no persisted UI topology, no runtime archetype generation, no automatic dependency capture, no virtual DOM/per-frame view tree, no general flexbox, no line/cell OSP nodes, no closures keyed by runtime ID, no edits to `tui/pi_jac_floor/`, `jaclang`, `jac-ink`, or `jac-client`.
