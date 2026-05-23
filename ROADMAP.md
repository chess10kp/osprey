**A Jac-native, terminal-first Jac coding agent** that gives Jac developers the agentic workflow Jac Coder has, but outside VS Code, with better keyboard ergonomics, multimodal context, CLI/toolchain awareness, and Jac-specific project intelligence.

## 3. Jac-specific reasoning

* walkers
* nodes
* edges
* object-spatial modeling
* abilities
* graph traversal semantics
* AI-native declarations
* Jac/Python interop
* Jac frontend/backend/full-stack project structure
* Jac compiler/runtime failure modes

---

# MVP product shape

## MVP 1: Jac Toolchain Agent

The first version should do five things extremely well.

### 1. Project detection

When opened in a repo, detect:

* `*.jac` files
* `jac.toml` / project config if present
* Python environment
* installed `jac` / `jaclang` / `jaseci`
* entrypoint: `main.jac`, `app.jac`, etc.
* whether project is backend/fullstack/client
* tests
* generated JS/Python/native artifacts

### 3. Jac explanation mode

Commands:

```txt
/jac explain walker
/jac explain file
/jac explain error
/jac explain graph
```

It should translate Jac-specific semantics into precise mental models.

### 4. Jac project generation

Commands:

```txt
/jac new api
/jac new fullstack
/jac new graph-app
/jac new ai-service
/jac new walker-demo
```

Internally calls `jac create` where appropriate.

### 5. Refactor Python → Jac

This is likely your strongest demo.

Command:

```txt
/jac convert-python
```

Use case:

> “Take this Python domain model and rewrite it using Jac nodes, edges, walkers, and abilities.”

That shows why Jac exists.

---

# Architecture

## Layer 1 — Agent runtime

Use the agent-next runtime and jac-ink integration.

Responsibilities:

* slash commands
* keyboard bindings
* context collectors
* Jac CLI wrappers
* diagnostics parsing
* patch application
* model routing
* skill loading

## Layer 2 — Jac toolchain adapter

A thin adapter around:

```bash
jac check
jac run
jac test
jac format
jac lint
jac start
jac create
```

Expose normalized output:

```ts
type JacDiagnostic = {
  file: string;
  line: number;
  column?: number;
  severity: "error" | "warning" | "info";
  code?: string;
  message: string;
  raw: string;
};
```

## Layer 3 — Jac knowledge pack

A curated, versioned corpus:

* syntax reference
* language idioms
* object-spatial modeling guide
* walker patterns
* AI-native syntax examples
* common errors
* project templates

This should be packaged as agent skills/docs, not just shoved into the system prompt.

## Layer 4 — Multimodal context ingestion

Sources:

* clipboard image
* file image
* screenshot command
* selected terminal text
* selected file region
* repo tree
* `jac check` diagnostics
* AST/LSP output if accessible
* README/spec files
* Mermaid/Graphviz diagrams

## Layer 5 — Model routing

Use cheap/fast models for:

* syntax explanation
* diagnostics triage
* command suggestions

Use stronger multimodal/frontier models for:

* image-to-architecture
* large refactors
* ambiguous design tasks

The agent runtime supports custom providers and provider configuration, so model routing can be layered in without owning model infra.

---

# Feature map

## Tier 0 — Required MVP

| Feature               | Description                                           |
| --------------------- | ----------------------------------------------------- |
| Jac project detection | Detect Jac project, CLI, env, entrypoint              |
| `/jac check`          | Run `jac check`, summarize diagnostics                |
| `/jac fix`            | Repair compile/type errors with feedback loop         |
| `/jac test`           | Run tests and repair failures                         |
| `/jac explain`        | Explain selected Jac code/error                       |
| `/jac format`         | Run Jac formatter                                     |
| Jac prompt pack       | Reusable prompts for common Jac workflows             |
| Jac skill pack        | Skills for project generation, debugging, refactoring |

## Tier 1 — Differentiators

| Feature                      | Description                                              |
| ---------------------------- | -------------------------------------------------------- |
| Python → Jac refactor        | Convert Python OO/domain code into Jac graph-native code |
| Graph modeling assistant     | Turn domain descriptions into nodes/edges/walkers        |
| Jac idiom reviewer           | Detect “Python written in Jac” anti-patterns             |
| Walker debugger              | Explain traversal paths and possible state mutations     |
| Full-stack generator         | Generate backend/frontend/API Jac app skeletons          |
| Multimodal diagram ingestion | Convert images/diagrams into Jac models                  |

## Tier 2 — Advanced

| Feature                         | Description                                    |
| ------------------------------- | ---------------------------------------------- |
| Jac AST integration             | Use compiler AST/pass output for smarter edits |
| LSP diagnostics                 | Consume Jac LSP data outside VS Code           |
| Graph execution visualizer      | Render walker traversal as Mermaid/Graphviz    |
| Agentic test generation         | Generate tests from graph invariants           |
| Jac package authoring assistant | Help build reusable Jac modules                |
| Native compile advisor          | Recommend `jac nacompile` paths for hot spots  |
| Local docs RAG                  | Versioned retrieval over Jac docs/source       |

## Tier 3 — Research-grade

| Feature                  | Description                                           |
| ------------------------ | ----------------------------------------------------- |
| Semantic Jac synthesis   | Generate AI-native Jac declarations from specs        |
| Graph invariant verifier | Static-ish checks over node/edge/walker contracts     |
| Multi-agent Jac planner  | Separate architect/implementer/reviewer/tester agents |
| Runtime trace debugger   | Use execution traces to diagnose walker behavior      |
| Jac migration agent      | Convert Python/FastAPI projects into Jac apps         |

---

# PRD Draft

## Product Requirements Document: Jackal

### 1. Product name

**Jackal**

### 2. One-line description

A terminal-native agent runtime that provides a specialized coding agent for Jac/Jaseci development.

### 3. Problem

Jac is a new AI-native, graph-native programming language with unfamiliar abstractions such as walkers, nodes, edges, abilities, object-spatial programming, AI declarations, and full-stack runtime conventions. Existing tooling is concentrated around VS Code/Jac Coder, leaving terminal-first, Neovim, Zed, Emacs, SSH, and remote-development users without a specialized Jac coding agent.

Generic coding agents can edit `.jac` files, but they lack:

* Jac-specific toolchain loops
* object-spatial modeling knowledge
* Jac compiler/runtime diagnostic handling
* graph traversal reasoning
* multimodal architecture-to-code workflows
* editor-independent keyboard workflows

### 6. Non-goals

Jackal will not initially:

* replace the Jac compiler
* replace Jac LSP
* build a full IDE
* avoid forking runtime internals unless unavoidable
* host models
* provide cloud deployment infrastructure
* guarantee formal verification of Jac programs

### 7. Core user stories

#### US-1: Fix compiler errors

As a Jac developer, I can run:

```txt
/jac fix
```

and Jackal will:

1. run `jac check`
2. parse errors
3. inspect files
4. patch the code
5. rerun `jac check`
6. explain what changed

#### US-2: Learn Jac from code

As a new Jac user, I can select code and run:

```txt
/jac explain
```

Jackal explains nodes, edges, walkers, abilities, and traversal behavior.

#### US-3: Convert Python to Jac

As a Python developer, I can provide Python domain logic and run:

```txt
/jac convert-python
```

Jackal rewrites it into idiomatic Jac using graph-native modeling.

#### US-4: Generate graph model from description

As a developer, I can describe a system:

```txt
Users join projects, projects contain tasks, tasks have assignees and blockers.
```

Jackal generates:

* nodes
* edges
* walkers
* tests
* sample data

#### US-5: Generate Jac from diagram

As a developer, I can paste a diagram/screenshot and ask Jackal to generate a Jac implementation.

#### US-6: Work from any editor

As a terminal-first user, I can use Jackal in tmux/SSH/Neovim/Zed/Emacs without opening VS Code.

---

# Functional requirements

## FR-1: Jac environment detection

Jackal must detect:

* Jac installation
* `jac` CLI availability
* Jac version
* Python environment
* project root
* entrypoint
* test files
* config files
* package/dependency files

Output should be surfaced through:

```txt
/jac doctor
```

## FR-2: Jac command runner

Jackal must wrap:

```bash
jac check
jac test
jac run
jac format
jac lint
jac start
jac create
jac add
jac install
jac nacompile
```

At minimum MVP requires:

```bash
jac check
jac test
jac run
jac format
```

## FR-3: Diagnostic parser

Jackal must parse `jac check`, `jac test`, and runtime output into structured diagnostics.

## FR-4: Agentic repair loop

Jackal must support bounded repair loops:

* max iterations configurable
* no infinite edits
* show diff before apply, unless auto-apply enabled
* rerun verification commands after patch

## FR-5: Jac knowledge skills

Ship skills for:

* Jac basics
* object-spatial programming
* walkers
* graph modeling
* AI-native constructs
* full-stack Jac apps
* debugging
* Python interop
* native compilation

## FR-6: Prompt templates

Provide prompts:

```txt
/jac:new-api
/jac:new-fullstack
/jac:explain-walker
/jac:convert-python
/jac:review-idioms
/jac:generate-tests
/jac:diagram-to-model
```

## FR-7: Multimodal context

Support at least:

* image file input
* clipboard text
* selected terminal output
* selected code region
* pasted screenshots if the runtime supports it
* diagram-to-Jac generation using multimodal-capable model

## FR-8: Keyboard workflow

Provide configurable keybindings for:

| Action                   | Suggested binding |
| ------------------------ | ----------------- |
| Explain selection        | `Ctrl-j e`        |
| Fix diagnostics          | `Ctrl-j f`        |
| Run check                | `Ctrl-j c`        |
| Run tests                | `Ctrl-j t`        |
| Paste multimodal context | `Ctrl-j v`        |
| Generate graph model     | `Ctrl-j g`        |
| Open Jac command palette | `Ctrl-j Ctrl-j`   |

## FR-9: Jac idiom reviewer

Detect patterns like:

* overusing Python-style classes where nodes/edges fit better
* walkers with unclear traversal boundaries
* graph relationships represented as plain arrays
* AI calls hidden in generic functions instead of Jac-native constructs
* missing tests around walker behavior
* unstructured entrypoints

## FR-10: Test generation

Generate tests for:

* walker traversal
* node/edge creation
* API behavior
* graph invariants
* AI output structure when applicable

---

# Non-functional requirements

## NFR-1: Lightweight

Installation should be simple: clone the repo and run `npm install`, or use the provided Docker image.

## NFR-2: No VS Code dependency

Must work from terminal.

## NFR-3: Version-aware

Jackal should detect Jac version and load matching reference docs.

## NFR-4: Transparent

Every tool invocation should be visible:

```bash
jac check main.jac
```

No hidden magic.

## NFR-5: Safe patching

Default behavior:

* show diff
* ask before applying large changes
* preserve backups or use git diff

## NFR-6: Extensible

Users should be able to add their own:

* Jac templates
* project conventions
* skill packs
* model preferences
* custom commands

---

# MVP implementation plan

## Phase 1 — agent-next runtime skeleton

Deliver:

* installable agent runtime package
* one extension
* one Jac skill
* basic `/jac doctor`
* basic `/jac check`
* basic `/jac explain`

## Phase 2 — Jac CLI repair loop

Deliver:

* structured diagnostic parsing
* `/jac fix`
* diff generation
* verification loop with `jac check`
* optional `jac test`

## Phase 3 — Jac project generation

Deliver:

* `/jac new api`
* `/jac new fullstack`
* `/jac new graph-app`
* prompt templates
* starter examples

## Phase 4 — Python/Jac conversion

Deliver:

* `/jac convert-python`
* domain model extraction
* graph model proposal
* generated Jac files
* generated tests

## Phase 5 — Multimodal

Deliver:

* image/diagram ingestion
* screenshot/clipboard workflow
* diagram → node/edge/walker code
* Mermaid → Jac support

## Phase 6 — Advanced Jac intelligence

Deliver:

* AST/LSP integration
* walker traversal visualization
* idiom reviewer
* graph invariant test generation

---

# Recommended first prototype

Do **not** start with multimodal.

Start with this tight loop:

```txt
/jac doctor
/jac check
/jac fix
/jac explain
```

That gives you immediate utility.

Then add the killer demo:

```txt
/jac convert-python
```

Then add:

```txt
/jac diagram-to-model
```

That sequence avoids building flashy features before the core agent is reliable.

---

# Best first technical milestone

Build an agent runtime package that can:

1. detect a Jac repo
2. run `jac check`
3. parse the output
4. ask the model for a patch
5. apply the patch
6. rerun `jac check`

That is the minimum credible Jac coding agent.

Everything else compounds from there.

[1]: https://docs.jaseci.org/reference/cli/?utm_source=chatgpt.com "CLI Commands - Jac - AI-Native Full-Stack Development"
[2]: https://github.com/jaseci-labs/jac-vscode?utm_source=chatgpt.com "jaseci-labs/jac-vscode: vs code extension which ..."
[3]: https://github.com/jaseci-labs/jaseci?utm_source=chatgpt.com "The Official Jaseci Code Repository"
[4]: https://docs.jaseci.org/tutorials/ai/multimodal/?utm_source=chatgpt.com "Multimodal - AI-Native Full-Stack Development"

