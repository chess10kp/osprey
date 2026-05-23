The user wants Object-Spatial Programming (OSP) Jac code for: {{description}}

Follow the osp-skill workflow below and leverage the Jac MCP throughout.

## osp-skill reference

{{osp_skill}}

## Workflow

1. Call `list_examples` to see categories, then `get_example` for any walker/node/edge category that matches.
   For deeper grounding, call `search_docs` with keywords like `walker`, `spawn`, `visit`, `edge`, `by llm`, or `get_resource` for `jac://docs/osp` / `jac://guide/patterns`.
2. Identify nodes, edges, walkers, and where each ability lives (on the node vs on the walker).
3. Write the file with all four building blocks and a `` `root entry `` ability that spawns from `root`.
4. Call `validate_jac` to verify it compiles. If it errors, follow fix-skill (max 3 attempts), using `explain_error` for unfamiliar codes.
5. Optionally call `graph_visualize` on the OSP code and include a Mermaid-friendly summary of the graph model.
6. Briefly summarise the design choices (which node owns which ability, why typed edges if used).
