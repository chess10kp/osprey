import { existsSync, readFileSync } from "node:fs";
import { join } from "node:path";
import { appendSkillCatalogToPrompt } from "../project/skill-index.js";

const FALLBACK_SYSTEM = `You are Jackal, a Jac/Jaseci coding assistant.
Be concise, evidence-based, and correct. When unsure about Jac syntax, say so.`;

export function loadJackalSystemPrompt(cwd: string, explicit?: string): string {
  if (explicit && explicit.trim()) return explicit;

  const candidates = [
    join(cwd, "jackal", "SYSTEM.md"),
    join(cwd, "pi", "SYSTEM.md"),
  ];

  for (const path of candidates) {
    if (!existsSync(path)) continue;
    try {
      const txt = readFileSync(path, "utf-8").trim();
      if (txt) return appendSkillCatalogToPrompt(txt);
    } catch {
      // ignore and continue
    }
  }

  return FALLBACK_SYSTEM;
}
