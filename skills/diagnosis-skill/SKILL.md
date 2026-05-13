---
name: diagnosis-skill
description: Systematically diagnose Jac compiler errors and user-reported issues before attempting a fix. Use when the user provides a description of a problem, when errors are ambiguous, or before a complex fix.
---

# Diagnosis Workflow

Before editing any code, build a confident understanding of the root cause. This prevents speculative fixes that introduce new errors.

## When to use

- The user ran `/fix <description>` and described what they think is wrong.
- `validate_jac` returns errors that seem related (e.g. cascade of "undefined symbol" after one import change).
- An error message is cryptic or points to the wrong line.
- You are about to start the third fix attempt on the same file — stop and diagnose instead.

## 1. Gather evidence

### a. Run `validate_jac` (or `check_syntax` for a fast pass)
Collect the full error set. Note:
- Which files are involved
- Whether errors cluster around a single import, type, or walker
- Whether the first error is the root cause and later errors are symptoms

### b. Read the source at every error location
Read a window around each reported line (`[line - 10, line + 10]` minimum). Look for:
- Missing imports (`import:py`, `import:jac`)
- Typos in symbol names
- Mismatched braces or block delimiters
- Wrong node/edge/walker declarations in OSP code

### c. (Optional) Inspect the AST
Call `get_ast` on the file to see the exact structure the compiler sees. This is especially useful when:
- The error line looks correct to a human
- You suspect a precedence or parsing issue
- The code uses nested abilities or `by llm()` blocks

### d. (Optional) Explain unfamiliar errors
Call `explain_error` for any error code or message you do not fully understand. Record:
- Category (syntax, type, OSP, import, etc.)
- Root cause in plain English
- Typical fix pattern

## 2. Synthesize a diagnosis

Write a short diagnosis in this exact format:

```
Diagnosis:
- Root cause: <one sentence>
- Affected files: <list>
- Evidence: <which validate_jac errors, AST observations, or explain_error results support this>
- Proposed fix strategy: <what you will change and why>
- Risk: <what could go wrong or what you still don't know>
```

## 3. Validate the diagnosis before editing

Before you apply any edit, do ONE of the following:
- If the root cause is a simple typo or missing import: proceed to fix-skill.
- If the root cause is uncertain: ask the user a single clarifying question. Do not guess.
- If the fix strategy feels risky (e.g. changes a public API signature or walker topology): present the diagnosis to the user and ask for approval.

## What NOT to do during diagnosis

- Do not edit files during the diagnosis phase.
- Do not suppress errors with workarounds just to make `validate_jac` pass.
- Do not assume the first error in the list is the root cause — read the context first.
- Do not skip reading the file because the error message "looks obvious".

## Next step

Once the diagnosis is validated, proceed to **fix-skill** to apply the fix.
