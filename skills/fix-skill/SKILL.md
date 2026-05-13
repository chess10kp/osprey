---
name: fix-skill
description: Iteratively fix Jac compiler errors using the Jac MCP. Use when the user runs /fix, when validate_jac returns errors, or when the user asks you to repair a .jac file.
---

# Fix Workflow

When fixing Jac compiler errors, follow this loop. Stop after at most **3 attempts** on the same file — if still failing, summarize what you tried and ask the user.

All validation, error explanation, and CLI execution comes from the **Jac MCP server** (configured in `jackal/mcp.json`). Do not shell out to `jac` yourself.

## 0. Diagnose first when the user described the issue

If the user provided a description (e.g. `/fix the walker fails after the refactor`), follow the **diagnosis-skill** workflow before any edits:
- Gather evidence with `validate_jac`, file reads, `explain_error`, and `get_ast`.
- Synthesize a diagnosis (root cause, evidence, proposed fix strategy, risk).
- Only proceed to the steps below once the diagnosis is validated.

## 1. Run `validate_jac` to get the current error set

Call the `validate_jac` MCP tool on the target file. It performs full type checking and returns structured errors and warnings. Use `check_syntax` instead if you only need a fast parse-only pass.

## 2. Read the source at each error location

Always read the file before editing — never guess. Read a window around the reported `line` (e.g. `[line - 10, line + 10]`) so you have surrounding context.

## 3. (Optional) Get a deeper explanation

For unfamiliar error codes or messages, call the `explain_error` MCP tool. It returns the category, root cause, and a fix example.

## 4. Diagnose, then make a focused edit

- Fix only what the diagnostic points to. Do not refactor adjacent code.
- Prefer the smallest correct change: rename a typo, add a missing `;`, fix a type, import a missing symbol.
- If the same error repeats across many lines, look for a single root cause (a missing import, a wrong type alias) before mass-editing.

## 5. Re-run `validate_jac` to verify

Always re-validate after every edit. Two outcomes:
- **All errors gone**: summarize the change in one or two lines and stop.
- **New or remaining errors**: go back to step 2.

## 6. Cap attempts

Track how many times you've edited the same file in this session.
- After **3 failed attempts** on the same file, stop. Tell the user what you tried, what error remains, and ask whether to continue, change strategy, or get more context.

## Common Jac error patterns

| Error                                    | Likely cause                                                          |
| ---------------------------------------- | --------------------------------------------------------------------- |
| `Undefined symbol 'X'`                   | Missing `import:py X` / `import:jac X` or typo                        |
| `Type mismatch`                          | A function annotation or return type disagrees with usage             |
| `Walker has no entry for node 'X'`       | OSP walker missing `can <ability> with X entry { ... }` block         |
| `Cannot find ability 'X' on node 'Y'`   | Defined ability on the wrong node, or missed a `:node:Y:can:X` decl  |
| `Expected ';'` or `Expected '{'`         | Missing terminator or block delimiter — read the line above carefully |

## What NOT to do

- Do not delete code to silence an error.
- Do not stub out functions with `pass` to make compilation succeed if the user wanted real behaviour.
- Do not add `# type: ignore`-style escape hatches; Jac wants real fixes.
- Do not exceed 3 attempts silently — surface the failure to the user.
