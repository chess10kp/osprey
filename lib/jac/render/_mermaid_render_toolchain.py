"""Mermaid ASCII renderer — renders simple Mermaid diagrams as ASCII art in the terminal."""

from __future__ import annotations

import re


def detect_diagram_type(source: str) -> str:
    first = (source.strip().split("\n")[0] or "").lower()
    if first.startswith("flowchart") or first.startswith("graph"):
        return "flowchart"
    if first.startswith("sequence"):
        return "sequence"
    if first.startswith("class"):
        return "class"
    if first.startswith("er"):
        return "er"
    if first.startswith("state"):
        return "state"
    return "unknown"


def _extract_node_label(token: str) -> tuple[str, str | None, str]:
    """Extract (id, label?, shape) from A, A[Label], A(Label), A{Label}."""
    m = re.match(r"^(\w+)\[([^\]]*)\]$", token)
    if m:
        return m.group(1), m.group(2) or None, "box"
    m = re.match(r"^(\w+)\(([^)]*)\)$", token)
    if m:
        return m.group(1), m.group(2) or None, "round"
    m = re.match(r"^(\w+)\{([^}]*)\}$", token)
    if m:
        return m.group(1), m.group(2) or None, "diamond"
    return token, None, "box"


_ARROW_RE = re.compile(r"\s*(-->|<-->|-\.->|-\.->|->)\s*")
_EDGE_LABEL_RE = re.compile(r"^\|([^|]*)\|\s*")


def parse_flowchart(source: str) -> dict:
    lines = source.split("\n")
    first = lines[0].strip() if lines else ""

    direction = "TB"
    if "LR" in first:
        direction = "LR"
    elif "BT" in first:
        direction = "BT"
    elif "RL" in first:
        direction = "RL"

    nodes: dict[str, dict] = {}
    edges: list[dict] = []

    def ensure(nid: str, label: str | None = None, shape: str = "box") -> None:
        if nid not in nodes:
            nodes[nid] = {"id": nid, "label": label or nid, "shape": shape}
        elif label and nodes[nid]["label"] == nid:
            nodes[nid]["label"] = label
        if shape != "box" and nodes[nid]["shape"] == "box":
            nodes[nid]["shape"] = shape

    for raw in lines[1:]:
        line = raw.strip().replace('"', "")
        if not line or line.startswith("%"):
            continue

        # Try splitting by arrow
        parts = _ARROW_RE.split(line, maxsplit=1)
        if len(parts) >= 3:
            from_token = parts[0].strip()
            arrow_str = parts[1].strip()
            rest = parts[2].strip()

            from_id, from_lbl, from_shape = _extract_node_label(from_token)

            # Edge label |text|
            edge_label = None
            m = _EDGE_LABEL_RE.match(rest)
            if m:
                edge_label = m.group(1)
                rest = rest[m.end():]

            to_token = rest.strip()
            to_id, to_lbl, to_shape = _extract_node_label(to_token)

            ensure(from_id, from_lbl, from_shape)
            ensure(to_id, to_lbl, to_shape)

            arrow = "both" if "<-->" in arrow_str else "forward"
            style = "dashed" if "-.->" in arrow_str else "solid"
            edges.append({"from": from_id, "to": to_id, "label": edge_label, "style": style, "arrow": arrow})
            continue

        # Standalone node
        nid, lbl, shape = _extract_node_label(line)
        if nid:
            m = re.match(r"^(\w+)$", line)
            if m:
                ensure(nid)
            else:
                ensure(nid, lbl, shape)

    return {"type": "flowchart", "direction": direction, "nodes": list(nodes.values()), "edges": edges}


def _format_node(label: str, shape: str) -> str:
    padded = f" {label} "
    if shape == "round":
        return f"({padded})"
    if shape == "diamond":
        return f"<{padded}>"
    if shape == "circle":
        return f"(({label}))"
    return f"[{padded}]"


def render_flowchart_ascii(diagram: dict) -> str:
    nodes = diagram.get("nodes", [])
    edges = diagram.get("edges", [])
    direction = diagram.get("direction", "TB")

    if not nodes:
        return "(empty diagram)"

    is_lr = direction in ("LR", "RL")
    node_map = {n["id"]: n for n in nodes}

    if is_lr:
        lines: list[str] = []
        for node in nodes:
            n = node_map.get(node["id"], node)
            label = n.get("label") or node["id"]
            out_edges = [e for e in edges if e["from"] == node["id"]]
            lines.append(_format_node(label, n.get("shape", "box")))
            for edge in out_edges:
                arrow = " <--> " if edge.get("arrow") == "both" else " ---> "
                elbl = f' "{edge["label"]}"' if edge.get("label") else ""
                target = node_map.get(edge["to"])
                lines.append(f"  {arrow}{elbl} {target.get('label', edge['to']) if target else edge['to']}")
        return "\n".join(lines)

    # Top-down: BFS layering
    in_deg: dict[str, int] = {n["id"]: 0 for n in nodes}
    adj: dict[str, list[str]] = {n["id"]: [] for n in nodes}
    for edge in edges:
        adj[edge["from"]].append(edge["to"])
        in_deg[edge["to"]] = in_deg.get(edge["to"], 0) + 1

    layers: dict[str, int] = {}
    queue: list[str] = []
    for nid, deg in in_deg.items():
        if deg == 0:
            layers[nid] = 0
            queue.append(nid)
    for n in nodes:
        if n["id"] not in layers:
            layers[n["id"]] = 0
            queue.append(n["id"])

    max_layer = 0
    visited: set[str] = set()
    while queue:
        nid = queue.pop(0)
        if nid in visited:
            continue
        visited.add(nid)
        layer = layers.get(nid, 0)
        max_layer = max(max_layer, layer)
        for nxt in adj.get(nid, []):
            nl = max(layers.get(nxt, 0), layer + 1)
            layers[nxt] = nl
            max_layer = max(max_layer, nl)
            if nxt not in visited:
                queue.append(nxt)

    layer_groups: list[list[str]] = [[] for _ in range(max_layer + 1)]
    for nid, layer in layers.items():
        layer_groups[layer].append(nid)

    lines = []
    for l in range(max_layer + 1):
        group = layer_groups[l]
        if not group:
            continue
        labels = []
        for gid in group:
            n = node_map.get(gid)
            labels.append(_format_node(n.get("label", gid) if n else gid, n.get("shape", "box") if n else "box"))
        lines.append("     ".join(labels))

        next_group = layer_groups[l + 1] if l < max_layer else []
        for gid in group:
            out = [e for e in edges if e["from"] == gid and e["to"] in next_group]
            for edge in out:
                arrow = "↕" if edge.get("arrow") == "both" else "↓"
                elbl = f' "{edge["label"]}"' if edge.get("label") else ""
                lines.append(f"  {arrow}{elbl} {edge['to']}")
        if l < max_layer and next_group:
            lines.append("  |")

    return "\n".join(lines)


def _render_sequence(source: str) -> str:
    lines = source.split("\n")[1:]
    participants: dict[str, str] = {}
    messages: list[dict] = []

    for raw in lines:
        line = raw.strip()
        if not line or line.startswith("%"):
            continue
        m = re.match(r"^participant\s+(\w+)(?:\s+as\s+(.+))?$", line, re.I)
        if m:
            participants[m.group(1)] = (m.group(2) or m.group(1)).strip()
            continue
        m = re.match(r"^(\w+)\s*->?>?(?:\s*([^:]+):?\s*)?(.+)?$", line)
        if m:
            messages.append({"from": m.group(1), "to": (m.group(2) or "").strip(), "text": (m.group(3) or "").strip(), "dotted": "-->>" in line})

    if not participants and not messages:
        return "(empty sequence diagram)"

    parts = ["Participants:"]
    for pid, label in participants.items():
        parts.append(f"  {pid}: {label}")
    parts.append("")
    for msg in messages:
        arrow = "-->>>" if msg["dotted"] else "----->"
        parts.append(f'{msg["from"]} {arrow} {msg["to"]}: {msg["text"]}')
    return "\n".join(parts)


def _render_class(source: str) -> str:
    lines = source.split("\n")[1:]
    classes: dict[str, dict] = {}
    current = ""

    for raw in lines:
        line = raw.strip()
        if not line or line.startswith("%"):
            continue
        if line.startswith("}"):
            current = ""
            continue
        m = re.match(r"^class\s+(\w+)", line)
        if m:
            current = m.group(1)
            classes[current] = {"fields": [], "methods": []}
            continue
        if current and current in classes:
            if "(" in line:
                classes[current]["methods"].append(line)
            elif ":" in line or re.match(r"^\s*[+\-#]", line):
                classes[current]["fields"].append(line)

    if not classes:
        return "(empty class diagram)"

    parts: list[str] = []
    for name, cls in classes.items():
        parts.append(f"┌─ {name} ─────────┐")
        for f in cls["fields"]:
            parts.append(f"│ {f}")
        if cls["fields"] and cls["methods"]:
            parts.append("├───────────────────┤")
        for m in cls["methods"]:
            parts.append(f"│ {m}")
        parts.append("└───────────────────┘")
        parts.append("")
    return "\n".join(parts)


def _render_er(source: str) -> str:
    lines = source.split("\n")[1:]
    entities: dict[str, list[str]] = {}
    relations: list[str] = []

    for raw in lines:
        line = raw.strip()
        if not line or line.startswith("%"):
            continue
        m = re.match(r"^(\w+)\s*\{", line)
        if m:
            entities[m.group(1)] = []
            continue
        if line == "}":
            continue
        m = re.match(r"^(\w+)\s*\|\|--\|>\s*(\w+)\s*:\s*(.*)$", line)
        if m:
            relations.append(f"{m.group(1)} ||--|> {m.group(2)} : {m.group(3)}")
            continue
        if entities:
            last = list(entities.keys())[-1]
            entities[last].append(line)

    parts: list[str] = []
    for name, fields in entities.items():
        parts.append(f"┌─ {name} ─────────┐")
        for f in fields:
            parts.append(f"│ {f}")
        parts.append("└───────────────────┘")
        parts.append("")
    if relations:
        parts.append("Relationships:")
        for r in relations:
            parts.append(f"  {r}")
    return "\n".join(parts)


def _render_state(source: str) -> str:
    lines = source.split("\n")[1:]
    states: list[str] = []
    transitions: list[dict] = []

    for raw in lines:
        line = raw.strip()
        if not line or line.startswith("%") or line.startswith("[*]"):
            continue
        m = re.match(r'^state\s+"?([^"]+)"?\s+as\s+(\w+)', line, re.I)
        if m:
            states.append(f"{m.group(2)}: {m.group(1)}")
            continue
        m = re.match(r"^(\w+)$", line)
        if m:
            states.append(m.group(1))
            continue
        m = re.match(r"^(\w+)\s*-->?\s*(\w+)\s*:\s*(.+)$", line)
        if m:
            transitions.append({"from": m.group(1), "to": m.group(2), "event": m.group(3).strip()})

    parts: list[str] = []
    if states:
        parts.append("States:")
        for s in states:
            parts.append(f"  [{s}]")
        parts.append("")
    if transitions:
        parts.append("Transitions:")
        for t in transitions:
            parts.append(f"  {t['from']} --({t['event']})--> {t['to']}")
    return "\n".join(parts) or "(empty state diagram)"


def render_mermaid_ascii(source: str) -> str:
    dtype = detect_diagram_type(source)
    if dtype == "flowchart":
        return render_flowchart_ascii(parse_flowchart(source))
    if dtype == "sequence":
        return _render_sequence(source)
    if dtype == "class":
        return _render_class(source)
    if dtype == "er":
        return _render_er(source)
    if dtype == "state":
        return _render_state(source)
    first = source.split("\n")[0].strip() if source.strip() else "?"
    return f"(unsupported diagram type — first line: {first})"
