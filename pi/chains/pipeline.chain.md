---
name: pipeline
description: Full Jac pipeline — scout the codebase, architect the OSP graph, implement the code
---

## scout
output: context.md

Investigate the Jac/Jaseci project for: {task}

Find all .jac files, check project structure (jac.toml, main.jac), grep for node/edge/walker/can/import declarations.
Run `jac check` if available and capture diagnostics.
Return project type, file inventory, OSP structure (nodes, edges, walkers), and where to start.

## planner
reads: context.md
model: claude-sonnet-4-5

Based on the scout findings, design the OSP graph structure for: {task}

Design nodes, edges, walkers, and abilities. Follow Jac OSP conventions:
- One walker per workflow/query
- Put node/edge declarations together
- `root entry` ability on walkers that start from root
- Use typed edges only when the relationship carries data
- Use `report` to return data, `disengage` to stop traversal

Output a numbered implementation plan with files to create/modify and risks.

## worker

Execute the implementation plan:

{previous}

Create/modify .jac files as specified. After each file, run `jac check` to validate.
Fix errors immediately (max 3 retries per file). If a `jac check` error looks like
a type-checker false positive, note it and move on.
