# PLAN.md

## Overview

Plan the OSP-native terminal UI described in `OSPUI.md` as the forward Jackal product surface under `app/`. The work will evolve the current OSP graph and differential-rendering experiments into a detached per-session semantic UI graph, a typed event/effect runtime, and a retained terminal renderer. Existing code in `tui/pi_jac_floor/` is a parity and learning reference; it is not the product architecture or a second source of truth.

Delivery is gate-driven. First establish the detached graph, lifetime rules, event dispatch, terminal adapters, layout/damage renderer, and a representative Jackal shell. Then prove the claimed OSP advantages through inspection, benchmarks, an external widget, and authoring at realistic scale before broad feature migration.

## Goals

- Author product screens as durable, statically declared semantic nodes connected by typed OSP edges, not as a component tree rebuilt each frame.
- Keep each UI session in a detached `UiSessionRoot` graph that is never attached to Jac's persistent `root`.
- Keep domain state, UI-session state, renderer state, and host resources in their correct lifetime domains.
- Deliver normalized semantic input and domain changes as typed event walkers with target-and-bubble propagation.
- Execute external work through typed effects after propagation; keep the UI graph single-writer and responsive while model and tool work runs.
- Render through stable node identity with retained measurement, arrangement, clipping, damage, cell diffing, and cursor state held outside semantic nodes.
- Support the real Jackal shell: streaming transcript, multiline prompt, status, focus, scrolling, overlays, resize, Unicode, cancellation, and terminal restoration.
- Virtualize transcript rendering and preserve scroll anchors during streaming and resize.
- Make topology, bindings, event routes, invalidation, layout, damage, and lifetimes directly inspectable.
- Prove that walkers, explicit dependencies, retained invalidation, and OSP authoring provide measurable practical value over conventional callback and full-frame baselines.
- Keep framework interfaces deep: graph mutation, dispatch, rendering, and lifecycle complexity must stay behind small, testable interfaces.

## Current State

### Implemented in `app/`

- `app/ui/model.jac` provides an initial OSP UI slice with ordered `Child` edges, single-parent mounting, move/unmount operations, `Feeds` dependencies, owned signals, cached projection, equality-cutoff updates, input projection, and post-order cleanup.
- `app/ui/paint.jac` provides an early structural region painter that assigns rows and repaints changed or shifted leaf regions.
- `app/ui/model.test.jac` covers child ordering, cache reuse, signal invalidation, dynamic dependency replacement, projected input, cleanup, row composition, dirty-leaf painting, and sibling movement after height changes.
- `scripts/osp-tui-smoke.jac` proves that an OSP projection can drive the existing flat differential renderer.
- `scripts/osp-region-smoke.jac` proves selective structural repaint for a log/spacer/status layout.
- The all-Jac harness in `app/agent/` owns the ReAct loop and emits streaming and tool events to terminal or JSONL sinks.

### Implemented in the parity reference

- `tui/pi_jac_floor/` contains working reference behavior for terminal startup/restoration, escape-sequence buffering, bracketed paste, key normalization, editor behavior, focus, overlays, frame coalescing, Unicode helpers, markdown, and flat differential ANSI updates.
- Its smoke suite captures useful expected behavior and known rendering cases such as append, in-place mutation, shifted rows, resize, overlays, editor input, wrapping, and markdown.

### Gaps against `OSPUI.md`

- `UiNode` currently stores dirty flags, cached lines, geometry, and prior paint data. The specification requires all renderer and frame state to live in runtime side tables keyed by stable node ID.
- Generic `view(render_fn, input_fn, kind)` nodes and process-local closures are prototype interfaces. Product authoring requires statically declared semantic archetypes and node-side typed arrival dispatch.
- Signal dependencies are currently captured from reads. V1 requires explicit `Feeds` relations, and domain observation must use a separate process-local binding registry.
- There is no detached `UiSessionRoot`, `Screen`/`Overlay` type hierarchy, `Owns`, `FocusNext`, or `Layer` relation, graph revision, or complete invariant validation.
- Structural mutation currently uses dense integer order and lacks the complete sparse-rank mutation interface, cycle checks, duplicate-key checks, replace operations, and atomic validation.
- Input is routed directly to one projected handler. Typed semantic walkers, target-and-bubble propagation, default actions, effects, and modal target resolution are not implemented.
- The region painter has no layout contracts, rectangles, clipping, old/new damage union, retained cell buffer, viewport model, overlay restoration, or cursor cleanup.
- The agent loop is synchronous with the current host and JSONL events do not yet provide the durable IDs, sequence numbers, cancellation, queue bounds, snapshots, and backpressure required by the product seam.
- There is no semantic Jackal screen, transcript virtualization, one-time markup lowering, inspection surface, external-widget proof, or OSP-versus-baseline benchmark.

## Tasks

### Priority 0 — Must complete

- [ ] **Define the semantic graph and lifetime model in `app/ui/model.jac`.**
  - Declare `UiNode`, `UiContainer`, `UiRegion`, `UiSessionRoot`, `Screen`, and `Overlay` plus product archetypes such as `MainScreen`, `TranscriptView`, `Prompt`, `Status`, and `ApprovalOverlay`.
  - Add typed `Child(rank)`, `Owns`, `Feeds`, `FocusNext`, and `Layer(z_index, modal)` edges.
  - Keep only stable identity and semantic UI-session state on nodes; move dirty state, caches, geometry, cells, damage, and cursor data out of the graph.
  - Remove runtime string archetypes and automatic dependency capture from the product authoring interface.
  - Prove that the UI graph is detached and has no reachability path from persistent `root`.

- [ ] **Create one invariant-preserving topology mutation module.**
  - Implement `append_child`, `insert_before`, `insert_after`, `move_before`, `move_after`, `detach`, and `replace` in `app/ui/mutation.jac`.
  - Use sparse ranks and normalize internally; callers must never renumber siblings.
  - Enforce acyclic containment, one visual parent, deterministic order, unique sibling keys, valid ranks, and atomic failure without partial mutation.
  - Increment a graph revision and invalidate the smallest affected layout root after each successful structural change.

- [ ] **Add `UiSession` and the process-local lifetime registries.**
  - Implement `app/ui/runtime.jac` with ownership of the detached root, current screen, focus, event queue, graph revision, renderer, bindings, invalidation journal, host capabilities, and cleanup registries.
  - Implement `app/ui/bindings.jac` with explicit subscribe, unsubscribe, and delivery by domain source ID, target UI node ID, and event type.
  - Forbid persistent-domain-to-UI graph edges; `Feeds` remains UI-local only.
  - Dispose in the specified order and detect orphaned bindings, stale edges, invalid focus, unreleased capabilities, and registry-retained detached subgraphs.

- [ ] **Implement typed semantic events, propagation, and effects.**
  - Define `UiEvent` walkers and normalized events such as `InsertText`, `Submit`, `Cancel`, `MoveFocus`, `Resize`, and `TranscriptChanged` in `app/ui/events.jac`.
  - Resolve targets by explicit binding, topmost modal layer, focused node, then screen root as appropriate.
  - Compute the unique containment path and deliver the same event instance to the target and then each parent until propagation stops.
  - Keep `handled`, `propagation_stopped`, and `default_prevented` independent.
  - Define typed effects such as `SendPrompt`, `CopyToClipboard`, `SpawnProcess`, and `Quit`; execute them only after propagation.
  - Permit one product-owned handler per event archetype on a concrete node archetype; UI state mutation is node-owned.

- [ ] **Port required terminal behavior into product-owned adapters under `app/ui/`.**
  - Define a small terminal interface with process and virtual-terminal adapters.
  - Port only required behavior from `tui/pi_jac_floor/`: raw mode, alternate screen, resize, bracketed paste, complete escape buffering, key normalization, synchronized output, and reliable restoration.
  - Normalize raw bytes into semantic events and coalesce resize storms, mouse motion, paste blocks, and stream chunks before walker creation.
  - Cover fragmented escape sequences, Unicode, multiline paste, normal exit, exceptions, interrupts, and terminal restoration in virtual and PTY tests.
  - Do not make forward product changes in `tui/pi_jac_floor/`.

- [ ] **Replace the prototype painter with a retained layout and damage renderer.**
  - Introduce renderer-local side tables in `app/ui/layout.jac`, `app/ui/renderer.jac`, and `app/ui/width.jac`, keyed by stable node ID.
  - Implement fixed, intrinsic, bounded, grow, viewport, and overlay layout contracts; vertical composition; and only the horizontal layout required by Jackal.
  - Measure bottom-up and arrange top-down with width-dependent wrapping, clipping, scrolling, wide characters, combining characters, and ANSI-aware display width.
  - Compute damage from the union of old and new rectangles and repair moved, shrunk, obscured, removed, restyled, clipped, and cursor-owning regions.
  - Paint desired cells for damaged areas, diff against the retained cell buffer, and emit one synchronized ANSI update per frame.
  - Retire `app/ui/paint.jac` after the retained renderer replaces it; do not keep two painter sources of truth.

- [ ] **Implement OSP-native focus, layers, overlays, and ownership.**
  - Derive default focus order from ordered containment and use `FocusNext` only for explicit overrides.
  - Keep focus in `UiSession`, allow exactly one cursor requester, and reject deleted or unavailable focus targets.
  - Paint layers in ascending `z_index` and target input in descending `z_index`.
  - On modal open, create and attach the overlay subtree, save prior focus, trap input, and move focus to its initial target.
  - On close, remove bindings and owned state, dispose the subtree, restore valid prior focus, and damage the old rectangle so underlying content is repainted.

- [ ] **Build the representative Jackal shell as durable semantic topology.**
  - Initialize `MainScreen`, `TranscriptView`, `Status`, and `Prompt` once beneath `UiSessionRoot`; do not reconstruct them on each frame.
  - Store prompt draft/mode, transcript scroll/follow-tail state, focus, selection, and open overlays at UI-session lifetime.
  - Implement multiline editing, history, paste, cursor movement, submit/cancel, status fragments, a modal approval overlay, and the horizontal fragments needed by the shell.
  - Verify that semantic node IDs remain stable across typing, streaming, resize, focus changes, and overlay cycles.

- [ ] **Create a typed asynchronous seam between the Jac brain and UI.**
  - Add versioned command/event envelopes with session, request, turn, tool, sequence, and correlation IDs in `app/agent/protocol.jac`.
  - Run model and tool work outside the UI event loop; external workers enqueue immutable events and never mutate the UI graph.
  - Use bounded queues, preserve structural event order, and coalesce only compatible text deltas.
  - Add turn and subprocess-group cancellation that produces correlated completion/cancel events.
  - Keep terminal and JSONL modes as adapters, and add a typed in-process adapter for the product TUI.
  - Prove that typing, resize, overlays, Escape, and Ctrl-C remain responsive during model streaming and long-running tools.

- [ ] **Implement transcript projection, streaming, and virtualization.**
  - Keep conversations, messages, and tool results in domain state; bind source IDs and revisions into `TranscriptView` without duplicating the full domain model.
  - Materialize only visible wrapped lines plus overscan; never create OSP nodes for terminal lines or cells.
  - Cache measurement by message ID, width, content revision, and style revision.
  - Follow the newest content when `follow_tail` is true; otherwise preserve the visible anchor message and intra-message offset across inserts and streaming.
  - Ensure off-screen changes produce no terminal damage unless they affect the visible anchor or scroll range.

- [ ] **Provide the complete inspection and invariant surface.**
  - Implement `dump_graph`, `dump_bindings`, `dump_event_path`, `explain_invalidation`, `dump_layout`, `dump_damage`, and `dump_lifetimes` in `app/ui/inspect.jac`.
  - Include deterministic validation for containment cycles, duplicate keys, invalid ranks, stale edges, invalid focus, orphaned bindings, and leaked capabilities.
  - Connect each invalidation record to its originating event or `Feeds` relation, affected layout root, and resulting damage.

- [ ] **Support direct graph construction and one-time markup lowering through the same interface.**
  - Keep direct OSP construction for dynamic or algorithmic topology.
  - Add one-time lowering for statically declared semantic tags, stable keys, typed initial state, containment order, ownership/focus/feed/layer relations, and domain bindings.
  - Reject unknown tags and invalid properties during checking or lowering and provide a mode that prints generated Jac graph construction.
  - Do not introduce a virtual tree, per-frame view function, callback registry, runtime-generated archetypes, or second component lifecycle.
  - If Jac lacks a supported lowering extension, use direct construction and document a human-owned upstream request; do not edit `jaclang` or add compiler shims.

- [ ] **Pass all six OSPUI architecture validation gates before declaring v1 complete.**
  - Gate 1: detached graph lifecycle and complete session disposal.
  - Gate 2: interactive prompt comparison against a callback baseline, including code size, extension, logging, replay, tests, and runtime cost.
  - Gate 3: real Jackal layout and damage across wrapping, growth, shrink, movement, resize, Unicode, clipping, scrolling, overlays, and cursor cleanup.
  - Gate 4: compare full-frame repaint, retained region repaint, and explicit UI-local dependency invalidation using nodes queried, allocations, cells written, latency, and complexity.
  - Gate 5: implement `ProgressBar` in a separate package with events, measurement, painting, disposal, inspection, and markup registration without framework-source edits.
  - Gate 6: author a realistic Jackal screen with dozens of semantic regions, conditional tool rows, approvals, and overlays without manual rank management or per-frame reconstruction.
  - Stop and revise the architecture if walkers, retained invalidation, or OSP authoring do not show a concrete advantage.

### Priority 1 — Should complete

- [ ] **Port proven daily-driver visual modules onto the stable OSP interfaces.**
  - Port finalized markdown, tool timeline rows, loaders, notifications, autocomplete, command palette, selectors, help, model/session pickers, and structured diff review from the parity references.
  - Preserve semantic-region graph granularity; repeated noninteractive lines and markdown spans remain renderer projections.
  - Give each migrated module graph, event, layout, damage, and lifecycle tests.

- [ ] **Add safety and workflow overlays required for daily use.**
  - Implement correlated tool approvals, diff accept/reject, mode changes, cancellation status, MCP status, tasks, checkpoints, context usage, and session actions as semantic regions or overlays where they need independent identity.
  - Ensure modal overlays trap focus and non-modal overlays do not incorrectly intercept input.

- [ ] **Add replayable diagnostics and developer commands.**
  - Expose graph, binding, event-path, invalidation, layout, damage, and lifetime dumps through focused debug commands.
  - Allow captured semantic event traces to be replayed against the virtual terminal for deterministic defect reproduction.

- [ ] **Create the full virtual-terminal, PTY, and lifecycle test matrix.**
  - Require graph, event, layout, damage, streaming, disposal, and extension tests for every product widget or screen.
  - Assert both final terminal cells and patch scope so full clears cannot hide damage bugs.
  - Add negative tests for stale bindings, graph mutation during render, invalid focus restoration, leaked capabilities, and detached graph retention.

- [ ] **Document the stable framework interface and migration rules in `app/ui/README.md`.**
  - Document lifetimes, graph invariants, mutation ordering, event/error modes, layout contracts, renderer performance expectations, disposal, inspection, extension, and validation commands.
  - State that `app/` is the only forward product path and `tui/pi_jac_floor/`, `src/`, and `templates/` are references until cutover.

### Priority 2 — Nice to have

- [ ] **Add optional non-modal surfaces and richer terminal capabilities only after the v1 gates.**
  - Consider mouse selection, images, terminal color-scheme notifications, progress reporting, and advanced keyboard protocols when a Jackal workflow needs them.
  - Keep host capabilities outside the semantic graph and require lifecycle cleanup tests.

- [ ] **Profile narrow renderer kernels before native optimization.**
  - Benchmark Unicode width/wrapping, cell composition, frame diffing, markdown parsing, and transcript measurement end to end.
  - Move only measured bottlenecks into `app/core/`; keep crossings coarse and retain Jac ownership of UI/session semantics.

- [ ] **Evaluate a second renderer only after terminal v1 is stable.**
  - Use a real second renderer to discover shared abstractions rather than generalizing the terminal model in advance.
  - Do not add web synchronization, hydration, active-session migration, or renderer-neutral abstractions without a concrete product requirement.

- [ ] **Explore richer authoring and tooling after one-time lowering is proven.**
  - Consider generated topology diagrams, source-linked inspection output, static graph linting, and package discovery for external widgets.
  - Do not add runtime archetype generation, automatic dependency capture, or a visual graph editor.

## Notes/Assumptions

- `OSPUI.md` is the authoritative surface specification. `ROADMAP.md` remains authoritative for delivery order and places this work in N1, with daily-driver visual and workflow migration continuing into N2.
- Full OSPUI v1 requires every Priority 0 task and all six validation gates. Priority 1 applies the stable framework to broader daily-driver behavior and hardens its test and documentation surface.
- The current `app/ui` implementation is a prototype and evidence source. Its graph ordering, invalidation, cleanup, and region-paint tests should be retained where compatible, but interfaces that conflict with the specification should be replaced rather than layered over.
- `tui/pi_jac_floor/` supplies parity behavior and test cases. Product code must move to `app/`; do not create a permanent adapter that leaves focus, overlays, or lifecycle truth in the reference component tree.
- Persistent application state must never hold ordinary graph edges to ephemeral UI nodes. The binding registry is the v1 seam even if Jac later gains transient or weak edges.
- UI topology mutations and semantic state changes are single-writer. Model, tool, filesystem, network, and timer work may run elsewhere only by enqueueing immutable events.
- Markup is one-time initialization, not a virtual DOM. Direct OSP construction remains valid and is the fallback if supported static lowering is not available.
- General flexbox, web rendering, persisted UI topology, terminal-line/cell nodes, automatic dependency capture, and cross-process UI migration are explicit non-goals.
- Framework or compiler gaps belong to `jaclang`/Jac tooling and require human handoff. This repository must not modify `jaclang`, `jac-ink`, `jac-client`, or add compile-pipeline shims.
- The working tree already contains unrelated and in-progress TUI changes. Future implementation must preserve them and commit each coherent feature or bugfix separately as required by `AGENTS.md`.
