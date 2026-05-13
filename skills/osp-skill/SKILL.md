---
name: osp-skill
description: Generate Object-Spatial Programming (OSP) code in Jac — nodes, edges, walkers, abilities, and graph traversal. Use when the user asks for graph-shaped data, walkers, traversal, agents-on-graphs, or anything involving nodes/edges/spawn/visit.
---

# Jac OSP (Object-Spatial Programming) Skill

OSP is the core paradigm of Jac. Data lives in **nodes** connected by **edges**, and computation is performed by **walkers** that *spawn* on a node and *visit* their neighbors. Every node and walker can declare **abilities** that fire on entry/exit.

Always retrieve concrete examples first via the **Jac MCP** before writing OSP code from scratch:

- Call `list_examples` to see the available example categories.
- Call `get_example` with a category that matches (e.g. one demonstrating walkers, nodes, or edges).
- For deeper grounding, call `search_docs` with keywords like `walker`, `spawn`, `visit`, `edge`, `by llm`, or `get_resource` for specific URIs like `jac://docs/osp` or `jac://guide/patterns`.

## The four building blocks

### 1. `node`

A typed graph vertex with `has` fields and optional abilities.

```jac
node Person {
    has name: str;
    has age: int = 0;
}
```

### 2. `edge`

A typed connection between two nodes; can carry `has` fields.

```jac
edge Knows {
    has since: int;
}
```

### 3. `walker`

A mobile computation unit. Spawned on a node, walks edges, can `report` data and `disengage` to stop.

```jac
walker Greet {
    can hi with `root entry { visit [-->]; }
    can say with Person entry {
        print("hi " + here.name);
        visit [-->];
    }
}
```

### 4. Abilities (`can ... with X entry`)

A reactive method that fires when a walker visits. The trigger type can be a walker (on a node) or a node (on a walker).

## Connecting nodes

```jac
a ++> b;                     # plain forward edge
a +>:Knows(since=2020):+> b; # typed edge with fields
a <++ b;                     # backward edge
[-->]                        # all forward neighbors of `here`
[<--]                        # all backward neighbors
[-->](`?Person)              # filter neighbors by type
```

## Spawning a walker

```jac
MyWalker() spawn some_node;     # run the walker starting at some_node
results = MyWalker() spawn root; # collect what the walker reported
```

`root` is the implicit per-graph anchor node — start most traversals from it.

## OSP design checklist

When the user asks you to model something with OSP, work through these in order:

1. **Identify the entities** → become `node` types.
2. **Identify the relationships** → become `edge` types (typed only if they carry data or need filtering).
3. **Identify the queries / actions** → become `walker` types. One walker per workflow.
4. **Decide who owns the logic**:
   - State-changing logic that depends on the *visiting walker* → ability on the **node** (`can <name> with <Walker> entry`).
   - Logic that depends on the *kind of node* being visited → ability on the **walker** (`can <name> with <Node> entry`).
5. **Always include a `` `root entry `` ability** on top-level walkers so they can launch from `root` and `visit [-->]` into the actual graph.
6. **Use `report`** to bubble data out of a traversal; the spawn expression returns the list of reports.
7. **Use `disengage`** to stop the walker early when a target is found.

## Common pitfalls (DO NOT do these)

- ❌ Calling a walker like a function: `MyWalker(node)`. Always use `MyWalker() spawn node`.
- ❌ Forgetting to `visit [-->]` inside an ability — the walker will stop after the first node.
- ❌ Using Python `class` semantics. Walkers and nodes are not regular classes; field defaults must be declared with `has`.
- ❌ Mutating `here` from outside an ability; use abilities or pass data through `report`.
- ❌ Defining a walker without any `` `root entry `` ability and then trying to `spawn root` — it will visit nothing.

## Verify

After generating any OSP code, **call the `validate_jac` MCP tool** on the file. If errors come back, follow `fix-skill` (use `explain_error` for any unfamiliar error code).
