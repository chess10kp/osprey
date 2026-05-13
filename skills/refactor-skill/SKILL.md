---
name: refactor-skill
description: Guided refactoring workflow adapted for Jac projects. Use when the user asks to refactor code, rename symbols, restructure walkers/nodes/edges, or change APIs while preserving behavior.
---

# Jac Refactor Skill

This skill adapts general-purpose refactoring guidance to Jac-specific projects (nodes, edges, walkers, abilities).
It assumes the Jac MCP tools are available (validate_jac, lint_jac, get_ast, run_jac, explain_error) and that all edits must be small, verifiable, and reversible.

Principles
- Safety first: preserve external behavior. Prefer small, focused edits and verify with `validate_jac` and `run_jac` (or tests) after each change.
- Plan before edit: produce a short numbered plan under a "Plan:" header describing the change steps. Use the extension's plan mode flow when appropriate.
- Use AST and examples: use `get_ast` to inspect structure before renames, and `list_examples`/`get_example` to find idiomatic patterns.
- Keep changes atomic: one logical change per edit so it's easy to revert or iterate.
- Always re-run linters and validation after edits.

Workflow
1. Clarify scope
- If the user hasn't specified files or symbols, ask one clarifying question: which file(s) or symbol(s) should be refactored? Prefer the session `workingFile` if relevant.

2. Create a plan (numbered)
- Produce a short Plan: with 2–6 numbered steps. Example:

Plan:
1. Rename ability `foo` to `bar` on node `Person` (edit Person.jac).
2. Update walker `DoStuff` to call `bar` instead of `foo`.
3. Run `validate_jac` and `lint_jac` on changed files; fix errors.
4. Run `MyApp` (if available) or relevant walker to smoke-test behavior.

3. Identify safe edits
- Use `get_ast` or read the files to confirm symbol occurrences and where the change is needed. When renaming, ensure you update all references: node abilities, walker calls, and any typed edges that name abilities.

4. Apply edits (one-at-a-time)
- For each Plan step that requires code changes:
  a. Make a minimal edit (exact replace or small insertion). Use `edit`/`write` tools via the MCP if available or the extension's edit flows.
  b. Run `validate_jac` (or `lint_jac`) on the edited file(s).
  c. If errors appear, call `explain_error` for unfamiliar codes and fix only targeted lines.
  d. Repeat until `validate_jac` passes for those files.

5. Test / smoke-check
- If the project exposes `run_jac` or test walkers, run quick smoke tests to ensure behavior is preserved. Compare outputs if possible.

6. Summarize
- After finishing the plan, produce a concise summary of edits and any outstanding issues.

What to avoid
- Large, undifferentiated refactors in one step. Break them down.
- Deleting code to silence errors without understanding root cause.
- Changing public walker/node contracts (field names, reported shapes) without documenting and updating all callers.

Jac-specific tips
- Renaming an ability: abilities are declared with `can <name> with <Trigger> entry { ... }`. Update walker calls and any `report`/`visit` usage that depends on that ability.
- Walker/Node API changes: prefer adding a deprecated shim ability that forwards to the new API, then plan a follow-up to remove the shim later.
- Edge typing: if you change an edge's payload (fields), update places that construct that edge and any filters that match typed edges.

Tools to use (Jac MCP)
- validate_jac — full compile + type-check
- lint_jac — style/lint checks (if available)
- check_syntax — fast parse-only
- get_ast — inspect file AST for precise symbol locations
- explain_error — understand compiler error codes
- run_jac — smoke-run walkers / programs

When to call the user
- If the refactor touches ambiguous files or public APIs, ask the user to confirm the scope or to provide additional tests/entrypoints.


