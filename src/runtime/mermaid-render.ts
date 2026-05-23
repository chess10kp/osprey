// Mermaid ASCII renderer — renders simple Mermaid diagrams as ASCII art in the terminal.
//
// Supports flowchart, sequence, class, ER, and state diagrams at a basic level.
// The agent can use this to visualize graph models, walker traversals, etc.

export type MermaidDiagramType = "flowchart" | "sequence" | "class" | "er" | "state" | "unknown";

export interface MermaidNode {
  id: string;
  label: string;
  shape: "box" | "round" | "diamond" | "circle" | "cylinder";
}

export interface MermaidEdge {
  from: string;
  to: string;
  label?: string;
  style: "solid" | "dashed" | "dotted";
  arrow: "forward" | "backward" | "both" | "none";
}

export interface MermaidDiagram {
  type: MermaidDiagramType;
  direction: "TB" | "LR" | "BT" | "RL";
  nodes: MermaidNode[];
  edges: MermaidEdge[];
}

/**
 * Detect the diagram type from a mermaid block.
 */
export function detectDiagramType(source: string): MermaidDiagramType {
  const first = source.trim().split("\n")[0]?.toLowerCase() ?? "";
  if (first.startsWith("flowchart") || first.startsWith("graph")) return "flowchart";
  if (first.startsWith("sequence")) return "sequence";
  if (first.startsWith("class")) return "class";
  if (first.startsWith("er")) return "er";
  if (first.startsWith("state")) return "state";
  return "unknown";
}

/**
 * Parse a simple flowchart from mermaid source.
 * Handles basic node declarations and connections.
 */
export function parseFlowchart(source: string): MermaidDiagram {
  const lines = source.split("\n");
  const first = lines[0]?.trim() ?? "";

  let direction: MermaidDiagram["direction"] = "TB";
  if (first.includes("LR")) direction = "LR";
  else if (first.includes("BT")) direction = "BT";
  else if (first.includes("RL")) direction = "RL";

  const nodes = new Map<string, MermaidNode>();
  const edges: MermaidEdge[] = [];
  const nodePattern = /^(\w+)\[([^\]]*)\]$/;
  const nodeRoundPattern = /^(\w+)\(([^)]*)\)$/;
  const nodeDiamondPattern = /^(\w+)\{([^}]*)\}$/;
  const nodeCirclePattern = /^(\w+)\(([^)]*)\)$/;
  const edgePattern = /^(\w+)\s*-->?(?:\|([^|]*)\|\s*)?(\w+)(?:\[(?:[^\]]*)\])?$/;
  const edgeBothPattern = /^(\w+)\s*<-->?(?:\|([^|]*)\|\s*)?(\w+)(?:\[(?:[^\]]*)\])?$/;
  const edgeDashedPattern = /^(\w+)\s*-\.->(?:\|([^|]*)\|\s*)?(\w+)(?:\[(?:[^\]]*)\])?$/;

  function ensureNode(id: string, label?: string): void {
    if (!nodes.has(id)) {
      nodes.set(id, {
        id,
        label: label ?? id,
        shape: "box",
      });
    } else if (label) {
      const existing = nodes.get(id)!;
      if (existing.label === id) existing.label = label;
    }
  }

  for (const rawLine of lines.slice(1)) {
    const line = rawLine.trim().replace(/"/g, "");
    if (!line || line.startsWith("%") || line.startsWith("%%")) continue;

    // Try edge patterns first (more specific)
    const bothMatch = edgeBothPattern.exec(line);
    if (bothMatch) {
      ensureNode(bothMatch[1]!, bothMatch[1]);
      ensureNode(bothMatch[3]!, bothMatch[3]);
      edges.push({
        from: bothMatch[1]!,
        to: bothMatch[3]!,
        label: bothMatch[2] ?? undefined,
        style: "solid",
        arrow: "both",
      });
      continue;
    }

    const dashedMatch = edgeDashedPattern.exec(line);
    if (dashedMatch) {
      ensureNode(dashedMatch[1]!, dashedMatch[1]);
      ensureNode(dashedMatch[3]!, dashedMatch[3]);
      edges.push({
        from: dashedMatch[1]!,
        to: dashedMatch[3]!,
        label: dashedMatch[2] ?? undefined,
        style: "dashed",
        arrow: "forward",
      });
      continue;
    }

    const edgeMatch = edgePattern.exec(line);
    if (edgeMatch) {
      ensureNode(edgeMatch[1]!, edgeMatch[1]);
      ensureNode(edgeMatch[3]!, edgeMatch[3]);
      edges.push({
        from: edgeMatch[1]!,
        to: edgeMatch[3]!,
        label: edgeMatch[2] ?? undefined,
        style: "solid",
        arrow: "forward",
      });
      continue;
    }

    // Try node patterns
    const diamondMatch = nodeDiamondPattern.exec(line);
    if (diamondMatch) {
      ensureNode(diamondMatch[1]!, diamondMatch[2]);
      nodes.get(diamondMatch[1]!)!.shape = "diamond";
      continue;
    }

    const roundMatch = nodeRoundPattern.exec(line);
    if (roundMatch) {
      ensureNode(roundMatch[1]!, roundMatch[2]);
      nodes.get(roundMatch[1]!)!.shape = "round";
      continue;
    }

    const boxMatch = nodePattern.exec(line);
    if (boxMatch) {
      ensureNode(boxMatch[1]!, boxMatch[2]);
      continue;
    }

    // Bare node reference
    const bareMatch = line.match(/^(\w+)$/);
    if (bareMatch) {
      ensureNode(bareMatch[1]!);
    }
  }

  return {
    type: "flowchart",
    direction,
    nodes: [...nodes.values()],
    edges,
  };
}

/**
 * Render a parsed flowchart diagram as ASCII art.
 * Uses a simple top-down or left-right layout.
 */
export function renderFlowchartAscii(diagram: MermaidDiagram): string {
  const { nodes, edges, direction } = diagram;
  if (nodes.length === 0) return "(empty diagram)";

  const isLR = direction === "LR" || direction === "RL";

  // Assign layers using topological ordering
  const inDegree = new Map<string, number>();
  const adjacency = new Map<string, string[]>();

  for (const node of nodes) {
    inDegree.set(node.id, 0);
    adjacency.set(node.id, []);
  }

  for (const edge of edges) {
    adjacency.get(edge.from)?.push(edge.to);
    inDegree.set(edge.to, (inDegree.get(edge.to) ?? 0) + 1);
  }

  // Assign layers (BFS)
  const layers = new Map<string, number>();
  const queue: string[] = [];

  for (const [id, deg] of inDegree) {
    if (deg === 0) {
      queue.push(id);
      layers.set(id, 0);
    }
  }

  // Handle cycles — assign unvisited nodes to layer 0
  for (const node of nodes) {
    if (!layers.has(node.id)) {
      layers.set(node.id, 0);
      queue.push(node.id);
    }
  }

  let maxLayer = 0;
  const visited = new Set<string>();
  while (queue.length > 0) {
    const id = queue.shift()!;
    if (visited.has(id)) continue;
    visited.add(id);

    const layer = layers.get(id) ?? 0;
    maxLayer = Math.max(maxLayer, layer);

    for (const next of adjacency.get(id) ?? []) {
      const nextLayer = Math.max(layers.get(next) ?? 0, layer + 1);
      layers.set(next, nextLayer);
      maxLayer = Math.max(maxLayer, nextLayer);
      if (!visited.has(next)) queue.push(next);
    }
  }

  // Group nodes by layer
  const layerGroups: string[][] = [];
  for (let i = 0; i <= maxLayer; i++) layerGroups.push([]);
  for (const [id, layer] of layers) {
    layerGroups[layer]?.push(id);
  }

  // Render
  const lines: string[] = [];

  if (isLR) {
    // Left-right layout
    for (const node of nodes) {
      const n = diagram.nodes.find((nd) => nd.id === node.id)!;
      const label = n.label || node.id;
      const outEdges = edges.filter((e) => e.from === node.id);
      const shape = formatNodeShape(label, n.shape);
      lines.push(shape);
      if (outEdges.length > 0) {
        for (const edge of outEdges) {
          const arrow = edge.arrow === "both" ? " <--> " : " ---> ";
          const edgeLabel = edge.label ? ` "${edge.label}"` : "";
          const target = nodes.find((nd) => nd.id === edge.to);
          lines.push(`  ${arrow}${edgeLabel} ${target?.label ?? edge.to}`);
        }
      }
    }
  } else {
    // Top-down layout
    for (let l = 0; l <= maxLayer; l++) {
      const group = layerGroups[l] ?? [];
      if (group.length === 0) continue;

      const nodeLabels = group.map((id) => {
        const n = diagram.nodes.find((nd) => nd.id === id);
        return formatNodeShape(n?.label ?? id, n?.shape ?? "box");
      });
      lines.push(nodeLabels.join("     "));

      // Draw edges to next layer
      const nextGroup = layerGroups[l + 1] ?? [];
      for (const id of group) {
        const outEdges = edges.filter(
          (e) => e.from === id && nextGroup.includes(e.to),
        );
        for (const edge of outEdges) {
          const arrow = edge.arrow === "both" ? "↕" : "↓";
          const edgeLabel = edge.label ? ` "${edge.label}"` : "";
          lines.push(`  ${arrow}${edgeLabel} ${edge.to}`);
        }
      }
      if (l < maxLayer && nextGroup.length > 0) {
        lines.push("  |");
      }
    }
  }

  return lines.join("\n");
}

function formatNodeShape(label: string, shape: MermaidNode["shape"]): string {
  const padded = ` ${label} `;
  switch (shape) {
    case "round":
      return `(${padded})`;
    case "diamond":
      return `<${padded}>`;
    case "circle":
      return `((${label}))`;
    case "cylinder":
      return `[${padded}]`;
    case "box":
    default:
      return `[${padded}]`;
  }
}

/**
 * High-level render: detect diagram type, parse, and render.
 */
export function renderMermaidAscii(source: string): string {
  const type = detectDiagramType(source);

  switch (type) {
    case "flowchart": {
      const diagram = parseFlowchart(source);
      return renderFlowchartAscii(diagram);
    }
    case "sequence":
      return renderSequenceAscii(source);
    case "class":
      return renderClassAscii(source);
    case "er":
      return renderErAscii(source);
    case "state":
      return renderStateAscii(source);
    default:
      return `(unsupported diagram type — first line: ${source.split("\n")[0]?.trim() ?? "?"})`;
  }
}

/** Extract participants and messages from a sequence diagram. */
function renderSequenceAscii(source: string): string {
  const lines = source.split("\n").slice(1);
  const participants = new Map<string, string>();
  const messages: Array<{ from: string; to: string; text: string; dotted: boolean }> = [];

  for (const raw of lines) {
    const line = raw.trim();
    if (!line || line.startsWith("%") || line.startsWith("%%")) continue;

    const participantMatch = line.match(/^participant\s+(\w+)(?:\s+as\s+(.+))?$/i);
    if (participantMatch) {
      participants.set(participantMatch[1]!, participantMatch[2]?.trim() ?? participantMatch[1]!);
      continue;
    }

    const msgMatch = line.match(/^(\w+)\s*->>?>(?:\s*([^:]+):?\s*)?(.+)?$/);
    if (msgMatch) {
      messages.push({
        from: msgMatch[1]!,
        to: msgMatch[2]?.trim() ?? "",
        text: msgMatch[3]?.trim() ?? "",
        dotted: line.includes("-->>"),
      });
    }
  }

  if (participants.size === 0 && messages.length === 0) {
    return "(empty sequence diagram)";
  }

  const parts: string[] = ["Participants:", ...[...participants.entries()].map(([id, label]) => `  ${id}: ${label}`), ""];

  for (const msg of messages) {
    const arrow = msg.dotted ? "-->>>" : "----->";
    parts.push(`${msg.from} ${arrow} ${msg.to}: ${msg.text}`);
  }

  return parts.join("\n");
}

/** Render class diagram as ASCII. */
function renderClassAscii(source: string): string {
  const lines = source.split("\n").slice(1);
  const classes: Map<string, { fields: string[]; methods: string[] }> = new Map();
  let currentClass = "";

  for (const raw of lines) {
    const line = raw.trim();
    if (!line || line.startsWith("%")) continue;

    if (line.startsWith("}")) {
      currentClass = "";
      continue;
    }

    const classMatch = line.match(/^class\s+(\w+)/);
    if (classMatch) {
      currentClass = classMatch[1]!;
      classes.set(currentClass, { fields: [], methods: [] });
      continue;
    }

    if (currentClass && classes.has(currentClass)) {
      const cls = classes.get(currentClass)!;
      if (line.includes("(")) {
        cls.methods.push(line);
      } else if (line.includes(":") || line.match(/^\s*[+\-#]/)) {
        cls.fields.push(line);
      }
    }
  }

  if (classes.size === 0) return "(empty class diagram)";

  const parts: string[] = [];
  for (const [name, cls] of classes) {
    parts.push(`┌─ ${name} ─────────┐`);
    for (const f of cls.fields) parts.push(`│ ${f}`);
    if (cls.fields.length > 0 && cls.methods.length > 0) parts.push("├───────────────────┤");
    for (const m of cls.methods) parts.push(`│ ${m}`);
    parts.push(`└───────────────────┘`);
    parts.push("");
  }

  return parts.join("\n");
}

/** Render ER diagram as ASCII. */
function renderErAscii(source: string): string {
  const lines = source.split("\n").slice(1);
  const entities: Map<string, string[]> = new Map();
  const relations: string[] = [];

  for (const raw of lines) {
    const line = raw.trim();
    if (!line || line.startsWith("%")) continue;

    const entityMatch = line.match(/^(\w+)\s*\{/);
    if (entityMatch) {
      entities.set(entityMatch[1]!, []);
      continue;
    }

    if (line === "}") continue;

    const relMatch = line.match(/^(\w+)\s*\|\|--\|>\s*(\w+)\s*:\s*(.*)$/);
    if (relMatch) {
      relations.push(`${relMatch[1]} ||--|> ${relMatch[2]} : ${relMatch[3]}`);
      continue;
    }

    // Field inside entity
    if (entities.size > 0) {
      const last = [...entities.keys()].pop();
      if (last) entities.get(last)?.push(line);
    }
  }

  const parts: string[] = [];
  for (const [name, fields] of entities) {
    parts.push(`┌─ ${name} ─────────┐`);
    for (const f of fields) parts.push(`│ ${f}`);
    parts.push(`└───────────────────┘`);
    parts.push("");
  }

  if (relations.length > 0) {
    parts.push("Relationships:");
    for (const r of relations) parts.push(`  ${r}`);
  }

  return parts.join("\n");
}

/** Render state diagram as ASCII. */
function renderStateAscii(source: string): string {
  const lines = source.split("\n").slice(1);
  const states: string[] = [];
  const transitions: Array<{ from: string; to: string; event: string }> = [];

  for (const raw of lines) {
    const line = raw.trim();
    if (!line || line.startsWith("%") || line.startsWith("%%") || line.startsWith("[*]")) continue;

    const stateMatch = line.match(/^state\s+"?([^"]+)"?\s+as\s+(\w+)/i);
    if (stateMatch) {
      states.push(`${stateMatch[2]}: ${stateMatch[1]}`);
      continue;
    }

    const bareState = line.match(/^(\w+)$/);
    if (bareState) {
      states.push(bareState[1]!);
      continue;
    }

    const transMatch = line.match(/^(\w+)\s*-->?\s*(\w+)\s*:\s*(.+)$/);
    if (transMatch) {
      transitions.push({
        from: transMatch[1]!,
        to: transMatch[2]!,
        event: transMatch[3]!.trim(),
      });
    }
  }

  const parts: string[] = [];
  if (states.length > 0) {
    parts.push("States:");
    for (const s of states) parts.push(`  [${s}]`);
    parts.push("");
  }

  if (transitions.length > 0) {
    parts.push("Transitions:");
    for (const t of transitions) {
      parts.push(`  ${t.from} --(${t.event})--> ${t.to}`);
    }
  }

  return parts.join("\n") || "(empty state diagram)";
}
