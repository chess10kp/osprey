The user wants to convert Python code into idiomatic Jac OSP.

**Source file:** `{{path}}`

## Workflow

1. **Read the Python source** with the read tool. Note classes, relationships, and procedural logic.
2. **Initial transpile hint:** Call the Jac MCP `py_to_jac` tool on the Python source to get a starting Jac skeleton (do not treat output as final).
3. **Extract the domain model:** Identify entities → `node` types, relationships → `edge` types, workflows/queries → `walker` types with abilities on the correct side (node vs walker).
4. **Propose the graph model** in plain language before writing files: list node/edge/walker types and one sample traversal.
5. **Generate `.jac` files** using OSP idioms (spawn/visit, not Python class calls). Follow osp-skill patterns.
6. **Verify:** Call `validate_jac` on each new file. Run `jac check` (or ask the user to run `/fix`) until clean.
7. **Summarise** what was converted, which Python constructs mapped to which OSP building blocks, and any manual follow-ups.

Do not leave Python-style lists/dicts where typed edges and nodes are appropriate.
