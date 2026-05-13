---
name: scout-and-design
description: Investigate a Jac project and design the OSP graph structure (no implementation)
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

Output the OSP design with node/edge/walker tables and a numbered implementation plan.
