# Jackal + Cordis — dynamic composition design

**Date:** 2026-08-16 · **Source:** `~/repos/cordis/paper.pdf` — Shi, Zhang, Cui,
*A Programming Paradigm for Spatiotemporal Composability* (PKU / DeepSeek-AI).
**Goal:** the na-harness becomes a dynamically composable system — functionality
swapped in/out at runtime, effects reverted structurally, dependencies reactive.
This is also the principled replacement for the dropped jac plugin system: a
component model we own, written in Jac.

**Status: core spike landed** — `na/cordis/core.jac` + 6 passing tests.

---

## 1. The paper's model (what we adopt)

| Construct | Paper | Meaning |
|---|---|---|
| Revertible effect | `track(f, g)` on effect context `∂Γ = Γ × (Γ→Γ)` | every context mutation carries an explicit inverse; the runtime accumulates inverses; unload = apply accumulator → **complete state recovery** |
| Reactive coeffect | `inject d`, `provide p`, satisfaction `σ ⊨ d` | components declare deps and provisions as typed keys; store changes classify fibers activating/deactivating → **no ad-hoc dependency detection** |
| Fiber | `(d, p, e, π, σ, τ, θ)` | component instantiation with lifecycle Inactive⇄Active, per-fiber accumulator, parent, registry |
| Loader + HMR | entries `(id, url, isolate, intercept, config, disabled)` | declarative config reconciled into fiber ops; module replacement = dispose old fiber + use new — **no process restart, no HMR boundaries** |

§1.2.2 motivates exactly our case: *self-evolving agent harnesses* — a future
harness generates and deploys modifications to its own components while serving;
without temporal composability every self-modification is a restart that loses
state; without spatial composability dependents break silently.

## 2. What landed (C0 spike) — `na/cordis/core.jac`

A compact synchronous port, faithful in the load-bearing parts:

- `EffectContext` — coeffect store + per-fiber LIFO inverse accumulators.
  `set(k,v)` is `set` of Def. 23: extend store, track restriction as inverse.
  `effect(fn, args, inverse, inv_args)` is Alg. 1 in iterator-degenerate form.
- `Fiber` — `inject`/`provide`/`apply`; `satisfied` is Def. 24.
- `use/unload/swap` — registration (deps constrain *activation*, not loading —
  Thm 63), withdrawal with LIFO recovery, hot-swap sugar.
- `_refresh` — re-classification to fixpoint (quiescence); deactivation is
  eager-recovery (no inertia/async yet).

Simplifications (deliberate, spike scope): fiber ≡ component (no separate
instantiation count); no realms/isolation/interception; provisions unique among
active fibers (paper's disjointness, enforced); `notify` collapsed into
`_refresh` (synchronous); inverses are `(fn, args)` pairs, not closures.

**Tests (6/6 pass):** root-effect recovery · dependent waits for provider ·
unload deactivates dependents and reverts their effects · re-provision
reactivates · hot swap recovers old + installs new · `dispose_all` empties all.

## 3. Target architecture

```
main.jac ── boots EffectContext, loads entry config
   │
   ├─ provider components     provide: "model", "auth", "llm.transport"
   ├─ tool components         inject: ["model"]; provide: "tools.read", ...
   ├─ renderer components     inject: ["model"]; provide: "renderer", "slash./render"
   ├─ session component       inject: ["model", "tools.*"]; provide: "agent.turn"
   └─ loader component        watches .jackal/components/, reconciles entries
```

Everything the N0 harness hardcodes becomes a component with a declared
interface. Swapping functionality = `ctx.swap(old, new)` — old effects revert,
dependents react, new installs. The LLM tool list is *derived* from live
providers of `tools.*` keys, so tool swap changes the next turn's schema.

## 4. Phases

| Phase | Deliverable | Acceptance |
|---|---|---|
| **C0** core calculus | `cordis/core.jac` + tests | ✅ done |
| **C1** componentize N0 | tools/renderer/session as fibers over one ctx; tool list derived from `tools.*` providers | swap renderer mid-session; unload a tool → next turn lacks it |
| **C2** loader | `.jackal/components.toml` entries (id, url/path, config, disabled) → reconciliation; group entries | edit config file → live system quiesces to it without restart |
| **C3** HMR | file-watcher on component modules: rewrite `.jac` → dispose+use via loader | edit a component file → behavior changes in-place, state preserved |
| **C4** self-evolution | agent tools `deploy_component` / `swap_component` (write .jac + loader op); sandboxes via pinned server placement | agent installs its own tool mid-session and uses it next turn |
| **C5** paper parity** | realms/isolation (per-session key realms), interception, async inertia (abortable fibers) | two sessions isolate the same key; long apply aborts cleanly |

** Later/optional — adopt only when a concrete need exists; the paper's
metatheory (Thm 61/66/73) is the reference for each addition.

## 5. Design rules (from the paper, binding on us)

1. **All context mutation flows through `ctx.effect`/`ctx.set`.** Anything a
   component does outside the context is outside the recovery guarantee.
2. **The inverse obligation is on the component author** (the runtime does not
   verify `g∘f = id`) — component tests must assert recovery (`dispose_all`
   leaves the context empty).
3. **Deps constrain activation, not loading.** Register eagerly; fibers wait.
4. **Provisions are unique per active fiber** — conflict is an error, not an
   override.
5. **Deactivation recovers effects but keeps the fiber registered** (waiting),
   matching Inactive-not-removed.

## 6. Open questions

1. Component granularity: one fiber per tool, or one per tool *suite*?
   (Paper §6.5 favors coarse components; we'll start per-suite.)
2. Should `tools.*` keys carry JSON-schema metadata (byllm Tool objects)
   directly as the store value? (C1 decides.)
3. Session history: inside the context (revertible per session component) or
   outside (plain disk persistence)? Default: outside — chat history is data,
   not environment.
