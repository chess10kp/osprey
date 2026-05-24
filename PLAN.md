# PLAN.md

## Overview

Plan to add markdown rendering to the Jackal TUI so that assistant responses are rendered with syntax-highlighted code blocks, formatted headings, bold/italic text, lists, tables, blockquotes, and inline code — instead of the current plain-text dump. The design is modeled on how nanocoder implements terminal markdown.

## Goals

1. **Rich response display** — LLM responses render with proper terminal formatting: bold headings, syntax-highlighted fenced code blocks, bullet/numbered lists, blockquotes, links, inline code, and tables.
2. **Streaming-safe** — During streaming, show plain tail-truncated text (cheap re-render); apply full markdown parsing only on the finalized `AssistantMessage`.
3. **Copy-friendly code blocks** — Fenced code blocks render without the left border so users can select and copy them from the terminal cleanly.
4. **Theme-aware** — All colors pull from the existing `theme.cl.jac` tokens (PRIMARY, SECONDARY, INFO, TEXT, TOOL, etc.).

## Current State

### What Jackal does now

Both `StreamingMessage` (`streammsg.cl.jac`) and `AssistantMessage` (`asstmsg.cl.jac`) render the raw text inside a plain `<Text>{display}</Text>`. There is **no markdown parsing, no syntax highlighting, no structural formatting**. The entire assistant response is dumped as-is inside a bordered box.

Key files:
- `templates/components/asstmsg.cl.jac` — finalized messages: model header + bordered box + token count
- `templates/components/streammsg.cl.jac` — live streaming: spinner + model header + truncated text in a bordered box
- `templates/components/transcript.cl.jac` — routes messages to the above components
- `templates/components/theme.cl.jac` — shared color tokens (PRIMARY, SECONDARY, INFO, TEXT, ACCENT, TOOL, etc.)

### How nanocoder does it

Nanocoder has a dedicated `markdown-parser/` module (~350 lines total) that converts markdown to ANSI-formatted strings using **chalk** + **cli-highlight** + **cli-table3** + **wrap-ansi**:

1. **`parseMarkdownParts(text, colors, width)`** — core function in `source/markdown-parser/index.ts`:
   - Extracts and **protects** fenced code blocks (`\`\`\`lang ... \`\`\``) and inline code with placeholders
   - Applies regex-based formatting for: headings (`#`), bold (`**`), italic (`*`), bullet lists (`-`/`*`), numbered lists, blockquotes (`>`), links (`[text](url)`)
   - Restores inline code as chalk-colored text, fenced blocks as syntax-highlighted via `cli-highlight`
   - Returns `MarkdownPart[]` — `{ type: 'text', content } | { type: 'code', content }`

2. **Code block handling** — fenced blocks get syntax-highlighted via `cli-highlight` (which uses highlight.js themes). Code blocks render **without** the left border for clean terminal copy/paste.

3. **Table rendering** — `table-parser.ts` uses `cli-table3` to render markdown tables as proper ASCII tables with borders, column alignment, and terminal-width-aware sizing.

4. **HTML entity decoding** — `html-entities.ts` converts common entities (`&amp;`, `&lt;`, etc.) and numeric entities.

5. **Text wrapping** — `utils/text-wrapping.ts` uses `wrap-ansi` with a trim-fix for continuation lines to keep text within terminal width without breaking ANSI escape codes.

6. **Streaming strategy** — `StreamingMessage` shows a **tail-truncated** plain text preview (last 12 lines, no markdown parsing) to keep re-renders cheap. Full markdown parsing only runs in the finalized `AssistantMessage`.

7. **Dependencies**: `chalk@^5.2.0`, `cli-highlight@^2.1.11`, `cli-table3@^0.6.5`, `wrap-ansi@^10.0.0` — all already present in Jackal's `node_modules/`.

### Dependencies available

| Package | In Jackal `node_modules/` | In `.jac/tui/node_modules/` | Purpose |
|---------|--------------------------|----------------------------|---------|
| `chalk` | ✅ | ✅ | ANSI color styling |
| `cli-highlight` | ✅ | ✅ (auto-installed) | Syntax highlighting for code blocks |
| `cli-table3` | ❌ | ❌ | ASCII table rendering |
| `wrap-ansi` | ✅ | ✅ | Terminal-width text wrapping |
| `highlight.js` | ✅ (dep of cli-highlight) | ✅ (dep of cli-highlight) | Language grammars |

## Tasks

### Priority 0 — Must complete

- [x] **Create markdown parser module** — `templates/markdown.mjs` implements nanocoder-style `parseMarkdownParts()`:
  - HTML entity decoding
  - Extract + protect fenced code blocks (`\`\`\`lang ... \`\`\``) with placeholders
  - Extract + protect inline code with placeholders
  - Format headings (bold, PRIMARY color)
  - Format bold (`**text**`), italic (`*text*`)
  - Format bullet lists (`- ` → `• `) and numbered lists
  - Format blockquotes (`> ` → dim italic)
  - Format links (`[text](url)` → underlined text + dim URL)
  - Syntax-highlight code blocks via `cli-highlight` with chalk fallback
  - Return `{ type: 'text' | 'code', content: string }[]`

- [x] **Integrate into `AssistantMessage`** (`asstmsg.cl.jac`):
  - Import `parseMarkdownParts` from the markdown module
  - Replace the single `<Text>{display}</Text>` with a loop over markdown parts
  - Text parts: render inside the existing bordered box (left-border style)
  - Code parts: render **without** border for clean copy/paste
  - Fallback to plain text if parsing returns empty

- [x] **Add `cli-highlight` to Jac runtime** — Auto-installed in `jackal.sh` postprocess step alongside `@inkjs/ui`

### Priority 1 — Should complete

- [x] **Add `cli-table3` dependency** — Used in `templates/markdown.mjs`

- [x] **Table rendering** — `parseMarkdownTable()` detects `| header | --- |` patterns and renders via cli-table3

- [x] **Streaming text wrapping** — `StreamingMessage` uses `wrapPlainText()` from `templates/text-wrapping.mjs`

- [x] **Text wrapping utility** — `wrapWithTrimmedContinuations()` in `templates/text-wrapping.mjs`; applied in `parseMarkdownParts`

### Priority 2 — Nice to have

- [ ] **Token-aware width calculation** — Use terminal width in `AssistantMessage` for text wrapping (nanocoder uses `useTerminalWidth()` hook; Jackal can use `process.stdout.columns` or pass width from the Ink `useApp()` context)

- [ ] **Non-interactive mode rendering** — When running `jackal run --plain`, flatten markdown parts into a single string without borders/headers (nanocoder has this with `useNonInteractiveRender`)

- [ ] **Mermaid block detection** — Detect ` ```mermaid ` code blocks and route them to the existing `pi-mermaid` ASCII renderer instead of plain syntax highlighting

- [ ] **Configurable theme mapping** — Allow `.jackal` config to override markdown color mappings (e.g., `markdown.heading: "yellow"` instead of default PRIMARY)

- [ ] **Staggered rendering** — For very long responses, render markdown incrementally (text parts first, then code blocks) to reduce perceived latency

## Timeline

### Phase 1 — Core markdown rendering (1-2 sessions)
- Create the markdown parser module
- Wire `cli-highlight` availability
- Integrate into `AssistantMessage`
- **Result:** Headings, bold, italic, lists, blockquotes, links, inline code, and syntax-highlighted code blocks render in finalized messages.

### Phase 2 — Tables and wrapping (1 session)
- Add `cli-table3`, port table parser
- Add text wrapping utility
- Apply wrapping to streaming + finalized messages
- **Result:** Tables render properly; text respects terminal width.

### Phase 3 — Polish (1 session)
- Non-interactive mode flat output
- Mermaid block routing
- Width calculation refinements
- **Result:** Full parity with nanocoder's markdown rendering quality.

## Notes/Assumptions

1. **jac-ink dependency bundling** — Whether `cli-highlight` and `cli-table3` are available at runtime depends on how jac-ink resolves imports. If jac-ink doesn't bundle them, we need to either install them in `.jac/tui/node_modules/` or pre-compute highlighting in the adapter and pass ANSI strings to the Ink components. This may require a **human handoff** to jac-ink if import resolution needs a plugin change.

2. **Jac language support in cli-highlight** — `cli-highlight` uses highlight.js which supports Python but not `.jac` files natively. Jac code blocks will fall back to `plaintext` or `python` as the closest match. A custom highlight.js grammar for Jac could be added later.

3. **Performance** — `cli-highlight` can be slow on very large code blocks. Nanocoder mitigates this by only parsing markdown on the finalized message (not during streaming). We follow the same pattern.

4. **chalk in Jac components** — The `.jac/tui/node_modules/` already has `chalk`. Importing `chalk` from within `.cl.jac` components should work if jac-ink supports `import from "chalk"`. If not, chalk calls can live in the adapter/facade and pass pre-colored strings.

5. **No external markdown libraries** — Both nanocoder and this plan use a hand-rolled regex parser (not `marked` or `remark`). This keeps the bundle small, avoids async parsing, and handles the limited subset of markdown that LLMs actually emit. The `marked` package in `node_modules/` is a transitive dep, not used directly.
