# Jac E2E user story: Task Tracker

**As a** Jac developer  
**I want to** scaffold, implement, validate, run, and use a small task-list app  
**So that** I can confirm the full Jac loop works on my machine (CLI + browser + optional Jackal).

Use a dedicated test directory (e.g. `/tmp/jac-e2e-test`) so you do not scaffold inside an existing project.

---

## Preconditions

| Requirement | How to verify |
|-------------|---------------|
| Jac CLI | `jac --version` |
| Node.js (fullstack client build) | `node --version` |
| Empty workspace | No `jac.toml` in the directory you will use |
| (Optional) Jackal | From this repo: `npm install && npm run build:agent && ./jackal.sh` |

---

## Act 1 — Scaffold the project

**Goal:** A runnable Jac project exists on disk.

```bash
mkdir -p /tmp/jac-e2e-test && cd /tmp/jac-e2e-test
jac create tasktracker --use fullstack
cd tasktracker
jac install
```

**Acceptance criteria**

- [ ] `tasktracker/jac.toml` exists
- [ ] `main.jac`, `components/`, and service modules exist
- [ ] `jac install` completes without errors

### Fix deprecated scaffold syntax

Templates may still emit `cl { }` / `sv { }` blocks (W0064). Before running anything:

1. Open `main.jac`
2. Replace braced `cl { ... }` with a `to cl:` section
3. Keep server imports at the top (server is the default context — no `to sv:` needed)
4. Use plain `import from services.X { ... }` in `main.jac` (not `sv import`)

Canonical `main.jac` shape: see skill `pi/skills/jac-fullstack-patterns/SKILL.md`.

---

## Act 2 — Implement the smallest useful feature

**Goal:** One graph node, four RPC endpoints, and a minimal UI.

### 2a — Server (`services/tasks.sv.jac` or inline in `main.jac`)

Implement a todo model and CRUD. Pattern: `pi/skills/jac-sv-endpoints/SKILL.md`.

| Endpoint | Behavior |
|----------|----------|
| `def:pub list_tasks()` | Return all `Task` nodes |
| `def:pub add_task(title: str)` | Create and return a new `Task` |
| `def:pub toggle_task(id: str)` | Flip `done` by stable `jid()` |
| `def:pub delete_task(id: str)` | Remove matching task |

**Acceptance criteria**

- [ ] Every `def:pub` has an explicit return type
- [ ] Lookups use `jid(task)`, not `id(task)`
- [ ] New service symbols are imported in `main.jac`: `import from services.tasks { ... }`

Example server sketch (adapt to your scaffold layout):

```jac
node Task {
    has title: str;
    has done: bool = False;
}

def:pub list_tasks() -> list[Task] {
    return [root -->][?:Task];
}

def:pub add_task(title: str) -> Task {
    return (root ++> Task(title=title))[0];
}

def:pub toggle_task(id: str) -> Task | None {
    for t in [root -->][?:Task] {
        if jid(t) == id {
            t.done = not t.done;
            return t;
        }
    }
    return None;
}

def:pub delete_task(id: str) -> bool {
    for t in [root -->][?:Task] {
        if jid(t) == id {
            del t;
            return True;
        }
    }
    return False;
}
```

### 2b — Client (`components/TaskList.cl.jac` + hook)

- [ ] Hook calls server with **positional** args: `add_task(title)` not `add_task(title=title)`
- [ ] Hook uses `sv import from ..services.tasks { ... }` in `.cl.jac` files
- [ ] `main.jac` under `to cl:` defines `def:pub app()` returning your shell component

---

## Act 3 — Static correctness (before running)

**Goal:** Type-check passes before runtime debugging.

```bash
cd /tmp/jac-e2e-test/tasktracker
jac check
# or narrower:
jac check main.jac services/tasks.sv.jac components/TaskList.cl.jac
```

**Acceptance criteria**

- [ ] `jac check` exits 0 (no errors)
- [ ] W0064 warnings (`cl {` / `sv {`) are resolved

### Optional: Jackal

From `tasktracker/`:

```bash
/path/to/jackal/jackal.sh
```

Inside the shell:

- `/jac-doctor` — verify toolchain
- `/jac-check` — same as `jac check` with TUI diagnostics
- Or ask: “Run jac check on this project and fix any errors.”

---

## Act 4 — Run the application

**Goal:** Dev server serves API + client with hot reload.

```bash
pkill -f "jac start" 2>/dev/null || true   # avoid stale port 8001
jac start --dev main.jac
```

**Acceptance criteria**

- [ ] Terminal shows dev server URL (typically `http://localhost:...`)
- [ ] Browser loads the UI without a blank page or Vite error
- [ ] Editing a `.cl.jac` file updates the UI without a full restart (HMR)

**Server changes need a full restart** — HMR only reloads client files:

```bash
pkill -f "jac start"
jac start --dev main.jac
```

Do **not** use `jac serve` (deprecated). Use `jac start --dev main.jac`.

---

## Act 5 — Manual acceptance test (browser)

Do this while the dev server from Act 4 is running.

| Step | Action | Expected result |
|------|--------|-----------------|
| 1 | Open the app URL | Task list UI renders |
| 2 | Add task “Buy milk” | New row appears |
| 3 | Add task “Write tests” | Second row appears |
| 4 | Toggle first task | Visual “done” state changes |
| 5 | Delete second task | Row disappears |
| 6 | Refresh page | State matches server graph (OSP persistence) |

**Acceptance criteria**

- [ ] No `404` or `422` in the browser network tab on RPC calls
- [ ] After editing `.sv.jac`, you restarted `jac start` before retesting

---

## Act 6 — Runtime verification (CLI, optional)

**Goal:** Confirm Jac can execute server logic headlessly.

For backend-only projects (`jac create taskapi` without `--use client`):

```bash
jac run main.jac
# or a specific entry:
jac enter main.jac <entry_name>
```

For this fullstack story, Act 5 is the primary runtime proof. `jac run` is most useful when you add a `with entry { ... }` block or a standalone script.

---

## Act 7 — (Optional) End-to-end with Jackal

From your **tasktracker** project directory:

```bash
/path/to/jackal/jackal.sh
```

Suggested prompt:

> Implement a Task node and list/add/toggle/delete endpoints in `services/tasks.sv.jac`, wire imports in `main.jac`, and a minimal TaskList UI. Run jac check after edits.

Workflow:

1. `/jac-doctor` — toolchain OK
2. Let the agent implement Act 2
3. `/jac-check` after edits
4. You run `jac start --dev main.jac` locally (long-running server stays on your terminal)
5. Complete Act 5 in the browser

**Acceptance criteria**

- [ ] Agent uses `jac check` or MCP `validate_jac` after writes
- [ ] You complete Act 5 without fixing import / `sv import` mistakes yourself

---

## Definition of done

You are done when **all** of these are true:

1. Project created with `jac create` + `jac install`
2. `jac check` clean
3. `jac start --dev main.jac` serves UI + API
4. Browser walkthrough (add → toggle → delete → refresh) succeeds
5. You know when to restart vs rely on HMR (`.sv.jac` vs `.cl.jac`)

---

## Troubleshooting

| Symptom | Likely cause | Fix |
|---------|--------------|-----|
| `404` on RPC | Endpoint not registered in `main.jac` | Add `import from services.X { fn, Types }` at top |
| `422 Field required` | Keyword args in client call | Use positional args |
| `Could not resolve services/X.js` | Plain `import` in `.cl.jac` | Use `sv import from ..services.X` |
| `401` on `def:priv` | Not logged in | Use `def:pub` for this story, or add auth (`jac-sv-auth` skill) |
| RPC worked once, then fails | Stale `jac start` on wrong port | `pkill -f "jac start"` then restart |
| W0064 warnings | Old `cl {` / `sv {` blocks | Migrate to `to cl:` sections |

---

## Shorter variant: backend-only (~30 min)

No browser — CLI + graph only:

```bash
mkdir -p /tmp/jac-e2e-backend && cd /tmp/jac-e2e-backend
jac create taskapi
# implement nodes + def:pub endpoints in main.jac
jac check
jac run main.jac
```

Same CRUD story; acceptance is printed output instead of Act 5.

---

## Related docs and skills

| Resource | Purpose |
|----------|---------|
| `pi/skills/jac-scaffold/SKILL.md` | `jac create` templates and post-scaffold checklist |
| `pi/skills/jac-fullstack-patterns/SKILL.md` | `main.jac` wiring, `sv import` rules |
| `pi/skills/jac-sv-endpoints/SKILL.md` | `def:pub` / `def:priv`, return types, `jid()` |
| `pi/skills/jac-cl-components/SKILL.md` | `.cl.jac` UI and hooks |
| `docs/QUICK_REFERENCE.md` | Jackal slash commands and flags |
| `README.md` | Running Jackal locally |
