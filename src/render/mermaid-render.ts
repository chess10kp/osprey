// Mermaid ASCII renderer — pure TypeScript, no bridge subprocess.
// Ported from lib/jac/render/_mermaid_render_toolchain.py.

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

// ── Detection ────────────────────────────────────────────────────────────────

export function detectDiagramType(source: string): MermaidDiagramType {
  const first = (source.trim().split("\n")[0] ?? "").toLowerCase();
  if (first.startsWith("flowchart") || first.startsWith("graph")) return "flowchart";
  if (first.startsWith("sequence")) return "sequence";
  if (first.startsWith("class")) return "class";
  if (first.startsWith("er")) return "er";
  if (first.startsWith("state")) return "state";
  return "unknown";
}

// ── Flowchart parser ─────────────────────────────────────────────────────────

const ARROW_RE = /\s*(-->|<-->|-\.->|-\.->|->)\s*/;
const EDGE_LABEL_RE = /^\|([^|]*)\|\s*/;

function extractNodeLabel(token: string): { id: string; label: string | null; shape: "box" | "round" | "diamond" } {
  let m: RegExpMatchArray | null;
  m = token.match(/^(\w+)\[([^\]]*)\]$/);
  if (m) return { id: m[1]!, label: m[2] || null, shape: "box" };
  m = token.match(/^(\w+)\(([^)]*)\)$/);
  if (m) return { id: m[1]!, label: m[2] || null, shape: "round" };
  m = token.match(/^(\w+)\{([^}]*)\}$/);
  if (m) return { id: m[1]!, label: m[2] || null, shape: "diamond" };
  return { id: token, label: null, shape: "box" };
}

interface InternalNode { id: string; label: string; shape: string }
interface InternalEdge { from: string; to: string; label?: string; style: string; arrow: string }

function parseFlowchart(source: string): { direction: string; nodes: InternalNode[]; edges: InternalEdge[] } {
  const lines = source.split("\n");
  const first = lines[0]?.trim() ?? "";

  let direction: "TB" | "LR" | "BT" | "RL" = "TB";
  if (first.includes("LR")) direction = "LR";
  else if (first.includes("BT")) direction = "BT";
  else if (first.includes("RL")) direction = "RL";

  const nodeMap = new Map<string, InternalNode>();
  const edges: InternalEdge[] = [];

  function ensure(id: string, label?: string | null, shape = "box"): void {
    if (!nodeMap.has(id)) {
      nodeMap.set(id, { id, label: label ?? id, shape });
    } else {
      const n = nodeMap.get(id)!;
      if (label && n.label === id) n.label = label;
      if (shape !== "box" && n.shape === "box") n.shape = shape;
    }
  }

  for (const raw of lines.slice(1)) {
    const line = raw.trim().replace(/"/g, "");
    if (!line || line.startsWith("%")) continue;

    const parts = line.split(ARROW_RE);
    if (parts.length >= 3) {
      const fromToken = parts[0]!.trim();
      const arrowStr = parts[1]!.trim();
      let rest = parts[2]!.trim();

      const { id: fromId, label: fromLbl, shape: fromShape } = extractNodeLabel(fromToken);

      let edgeLabel: string | undefined;
      const elm = rest.match(EDGE_LABEL_RE);
      if (elm) {
        edgeLabel = elm[1];
        rest = rest.slice(elm[0].length);
      }

      const { id: toId, label: toLbl, shape: toShape } = extractNodeLabel(rest.trim());

      ensure(fromId, fromLbl, fromShape);
      ensure(toId, toLbl, toShape);

      const arrow = arrowStr.includes("<-->") ? "both" : "forward";
      const style = arrowStr.includes("-.->") ? "dashed" : "solid";
      edges.push({ from: fromId, to: toId, label: edgeLabel, style, arrow });
      continue;
    }

    // Standalone node
    const { id: nid, label: lbl, shape } = extractNodeLabel(line);
    if (nid) {
      if (/^\w+$/.test(line)) ensure(nid);
      else ensure(nid, lbl, shape);
    }
  }

  return { direction, nodes: [...nodeMap.values()], edges };
}

// ── ASCII rendering ──────────────────────────────────────────────────────────

function formatNode(label: string, shape: string): string {
  const padded = ` ${label} `;
  if (shape === "round") return `(${padded})`;
  if (shape === "diamond") return `<${padded}>`;
  if (shape === "circle") return `((${label}))`;
  return `[${padded}]`;
}

function renderFlowchartAscii(diagram: ReturnType<typeof parseFlowchart>): string {
  const { nodes, edges, direction } = diagram;
  if (!nodes.length) return "(empty diagram)";

  const nodeMap = new Map(nodes.map((n) => [n.id, n]));
  const isLr = direction === "LR" || direction === "RL";

  if (isLr) {
    const lines: string[] = [];
    for (const node of nodes) {
      const n = nodeMap.get(node.id) ?? node;
      const label = n.label || node.id;
      const outEdges = edges.filter((e) => e.from === node.id);
      lines.push(formatNode(label, n.shape));
      for (const edge of outEdges) {
        const arrow = edge.arrow === "both" ? " <--> " : " ---> ";
        const elbl = edge.label ? ` "${edge.label}"` : "";
        const target = nodeMap.get(edge.to);
        lines.push(`  ${arrow}${elbl} ${target?.label ?? edge.to}`);
      }
    }
    return lines.join("\n");
  }

  // Top-down BFS layering
  const inDeg = new Map<string, number>();
  const adj = new Map<string, string[]>();
  for (const n of nodes) { inDeg.set(n.id, 0); adj.set(n.id, []); }
  for (const e of edges) {
    adj.get(e.from)?.push(e.to);
    inDeg.set(e.to, (inDeg.get(e.to) ?? 0) + 1);
  }

  const layers = new Map<string, number>();
  const queue: string[] = [];
  for (const [nid, deg] of inDeg) {
    if (deg === 0) { layers.set(nid, 0); queue.push(nid); }
  }
  for (const n of nodes) {
    if (!layers.has(n.id)) { layers.set(n.id, 0); queue.push(n.id); }
  }

  let maxLayer = 0;
  const visited = new Set<string>();
  while (queue.length > 0) {
    const nid = queue.shift()!;
    if (visited.has(nid)) continue;
    visited.add(nid);
    const layer = layers.get(nid) ?? 0;
    maxLayer = Math.max(maxLayer, layer);
    for (const nxt of adj.get(nid) ?? []) {
      const nl = Math.max(layers.get(nxt) ?? 0, layer + 1);
      layers.set(nxt, nl);
      maxLayer = Math.max(maxLayer, nl);
      if (!visited.has(nxt)) queue.push(nxt);
    }
  }

  const layerGroups: string[][] = Array.from({ length: maxLayer + 1 }, () => []);
  for (const [nid, layer] of layers) layerGroups[layer]!.push(nid);

  const lines: string[] = [];
  for (let l = 0; l <= maxLayer; l++) {
    const group = layerGroups[l]!;
    if (!group.length) continue;
    lines.push(
      group
        .map((gid) => {
          const n = nodeMap.get(gid);
          return formatNode(n?.label ?? gid, n?.shape ?? "box");
        })
        .join("     "),
    );

    const nextGroup = l < maxLayer ? new Set(layerGroups[l + 1]) : new Set<string>();
    for (const gid of group) {
      const out = edges.filter((e) => e.from === gid && nextGroup.has(e.to));
      for (const edge of out) {
        const arrow = edge.arrow === "both" ? "↕" : "↓";
        const elbl = edge.label ? ` "${edge.label}"` : "";
        lines.push(`  ${arrow}${elbl} ${edge.to}`);
      }
    }
    if (l < maxLayer && nextGroup.size > 0) lines.push("  |");
  }
  return lines.join("\n");
}

function renderSequence(source: string): string {
  const lines = source.split("\n").slice(1);
  const participants = new Map<string, string>();
  const messages: { from: string; to: string; text: string; dotted: boolean }[] = [];

  for (const raw of lines) {
    const line = raw.trim();
    if (!line || line.startsWith("%")) continue;

    let m = line.match(/^participant\s+(\w+)(?:\s+as\s+(.+))?$/i);
    if (m) { participants.set(m[1]!, (m[2] ?? m[1]).trim()); continue; }

    m = line.match(/^(\w+)\s*->?>?(?:\s*([^:]+):?\s*)?(.+)?$/);
    if (m) {
      messages.push({
        from: m[1]!,
        to: (m[2] ?? "").trim(),
        text: (m[3] ?? "").trim(),
        dotted: line.includes("-->>"),
      });
    }
  }

  if (!participants.size && !messages.length) return "(empty sequence diagram)";

  const parts: string[] = ["Participants:"];
  for (const [pid, label] of participants) parts.push(`  ${pid}: ${label}`);
  parts.push("");
  for (const msg of messages) {
    const arrow = msg.dotted ? "-->>>" : "---->";
    parts.push(`${msg.from} ${arrow} ${msg.to}: ${msg.text}`);
  }
  return parts.join("\n");
}

function renderClass(source: string): string {
  const lines = source.split("\n").slice(1);
  const classes = new Map<string, { fields: string[]; methods: string[] }>();
  let current = "";

  for (const raw of lines) {
    const line = raw.trim();
    if (!line || line.startsWith("%")) continue;
    if (line === "}") { current = ""; continue; }
    const m = line.match(/^class\s+(\w+)/);
    if (m) { current = m[1]!; classes.set(current, { fields: [], methods: [] }); continue; }
    if (current && classes.has(current)) {
      if (line.includes("(")) classes.get(current)!.methods.push(line);
      else if (line.includes(":") || /^[+\-#]/.test(line)) classes.get(current)!.fields.push(line);
    }
  }

  if (!classes.size) return "(empty class diagram)";

  const parts: string[] = [];
  for (const [name, cls] of classes) {
    parts.push(`┌─ ${name} ─────────┐`);
    for (const f of cls.fields) parts.push(`│ ${f}`);
    if (cls.fields.length && cls.methods.length) parts.push("├───────────────────┤");
    for (const m of cls.methods) parts.push(`│ ${m}`);
    parts.push("└───────────────────┘");
    parts.push("");
  }
  return parts.join("\n");
}

function renderEr(source: string): string {
  const lines = source.split("\n").slice(1);
  const entities = new Map<string, string[]>();
  const relations: string[] = [];

  for (const raw of lines) {
    const line = raw.trim();
    if (!line || line.startsWith("%")) continue;
    const m1 = line.match(/^(\w+)\s*\{/);
    if (m1) { entities.set(m1[1]!, []); continue; }
    if (line === "}") continue;
    const m2 = line.match(/^(\w+)\s*\|\|--\|>\s*(\w+)\s*:\s*(.*)$/);
    if (m2) { relations.push(`${m2[1]} ||--|> ${m2[2]} : ${m2[3]}`); continue; }
    if (entities.size > 0) {
      const last = [...entities.keys()].pop()!;
      entities.get(last)!.push(line);
    }
  }

  const parts: string[] = [];
  for (const [name, fields] of entities) {
    parts.push(`┌─ ${name} ─────────┐`);
    for (const f of fields) parts.push(`│ ${f}`);
    parts.push("└───────────────────┘");
    parts.push("");
  }
  if (relations.length) {
    parts.push("Relationships:");
    for (const r of relations) parts.push(`  ${r}`);
  }
  return parts.join("\n");
}

function renderState(source: string): string {
  const lines = source.split("\n").slice(1);
  const states: string[] = [];
  const transitions: { from: string; to: string; event: string }[] = [];

  for (const raw of lines) {
    const line = raw.trim();
    if (!line || line.startsWith("%") || line.startsWith("[*]")) continue;
    let m = line.match(/^state\s+"?([^"]+)"?\s+as\s+(\w+)/i);
    if (m) { states.push(`${m[2]}: ${m[1]}`); continue; }
    m = line.match(/^(\w+)$/);
    if (m) { states.push(m[1]!); continue; }
    m = line.match(/^(\w+)\s*-->?\s*(\w+)\s*:\s*(.+)$/);
    if (m) transitions.push({ from: m[1]!, to: m[2]!, event: m[3]!.trim() });
  }

  const parts: string[] = [];
  if (states.length) {
    parts.push("States:");
    for (const s of states) parts.push(`  [${s}]`);
    parts.push("");
  }
  if (transitions.length) {
    parts.push("Transitions:");
    for (const t of transitions) parts.push(`  ${t.from} --(${t.event})--> ${t.to}`);
  }
  return parts.join("\n") || "(empty state diagram)";
}

// ── Public API ───────────────────────────────────────────────────────────────

export function renderMermaidAscii(source: string): string {
  const dtype = detectDiagramType(source);
  if (dtype === "flowchart") return renderFlowchartAscii(parseFlowchart(source));
  if (dtype === "sequence") return renderSequence(source);
  if (dtype === "class") return renderClass(source);
  if (dtype === "er") return renderEr(source);
  if (dtype === "state") return renderState(source);
  const first = source.split("\n")[0]?.trim() ?? "?";
  return `(unsupported diagram type — first line: ${first})`;
}
