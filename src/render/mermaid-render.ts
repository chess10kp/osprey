// Mermaid ASCII renderer — renders simple Mermaid diagrams as ASCII art in the terminal.
// Delegated to lib/jac/render/_mermaid_render_toolchain.py via bridge.

import { bridgeRenderMermaid, bridgeDetectDiagramType } from "../jac/jac-bridge.js";

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

export function detectDiagramType(source: string): MermaidDiagramType {
  return bridgeDetectDiagramType(source) as MermaidDiagramType;
}

export function renderMermaidAscii(source: string): string {
  return bridgeRenderMermaid(source);
}
