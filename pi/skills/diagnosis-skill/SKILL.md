---
name: diagnosis-skill
description: Diagnose and fix issues with the Jac application
---

# Diagnosis Workflow

Before editing any code, build a confident understanding of the root cause. This prevents speculative fixes that introduce new errors.

## When to use

- The user ran `/fix <description>` and described what they think is wrong.

## 1. Gather evidence

### a. Read the source at every error location
Read a window around each reported line (`[line - 10, line + 10]` minimum). Look for:
- Missing imports (`import:py`, `import:jac`)
- Typos in symbol names
- Mismatched braces or block delimiters
- Wrong node/edge/walker declarations in OSP code

### b. Check for logical errors
Look for mismatches between intent and implementation: off-by-one traversals, missing `disengage`, wrong ability signatures, incorrect `has` edge cardinality, or walker ordering assumptions.

### c. (Optional) Inspect the AST
Call `get_ast` on the file to see the exact structure the compiler sees. This is especially useful when:
- The error line looks correct to a human
- You suspect a precedence or parsing issue
- The code uses nested abilities or `by llm()` blocks

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
- If the root cause is uncertain: ask the user clarifying questions. Do not guess.
- If the fix strategy feels risky (e.g. changes a public API signature or walker topology): present the diagnosis to the user and ask for approval.

## What NOT to do during diagnosis

- Do not edit files during the diagnosis phase.
- Do not suppress errors with workarounds just to make `validate_jac` pass.
- Do not assume the first error in the list is the root cause — read the context first.
- Do not skip reading the file because the error message "looks obvious".

## Next step

Once the diagnosis is validated, proceed to **fix-skill** to apply the fix.
