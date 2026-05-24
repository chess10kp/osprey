import { existsSync, mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { afterEach, describe, expect, it } from "vitest";
import { parseFrontmatter } from "../../src/orchestration/frontmatter.js";
import {
  appendSkillsToPrompt,
  expandSkillCommand,
  formatSkillsForPrompt,
  loadJackalSkills,
  loadSkillByDir,
} from "../../src/project/skills.js";

const tempDirs: string[] = [];

function makeTempProject(): string {
  const dir = join(tmpdir(), `jackal-skill-test-${Date.now()}-${Math.random().toString(36).slice(2)}`);
  mkdirSync(dir, { recursive: true });
  tempDirs.push(dir);
  return dir;
}

afterEach(() => {
  for (const dir of tempDirs.splice(0)) {
    rmSync(dir, { recursive: true, force: true });
  }
});

describe("loadJackalSkills", () => {
  it("indexes built-in Jackal skills", () => {
    const { skills } = loadJackalSkills({ cwd: process.cwd() });
    expect(skills.length).toBeGreaterThan(10);
    expect(skills.some((s) => s.name === "fix-skill" && s.source === "builtin")).toBe(true);
  });

  it("includes project skills from .jackal/skills/", () => {
    const project = makeTempProject();
    const skillDir = join(project, ".jackal", "skills", "demo-skill");
    mkdirSync(skillDir, { recursive: true });
    writeFileSync(
      join(skillDir, "SKILL.md"),
      `---
name: demo-skill
description: Demo project skill for tests
---

# Demo Skill
Follow these demo instructions.
`,
    );

    const { skills } = loadJackalSkills({ cwd: project });
    const demo = skills.find((s) => s.name === "demo-skill");
    expect(demo).toBeDefined();
    expect(demo?.source).toBe("project");
    expect(demo?.filePath).toBe(join(skillDir, "SKILL.md"));
  });

  it("lets project skills override built-in names", () => {
    const project = makeTempProject();
    const skillDir = join(project, ".jackal", "skills", "fix-skill");
    mkdirSync(skillDir, { recursive: true });
    writeFileSync(
      join(skillDir, "SKILL.md"),
      `---
name: fix-skill
description: Project override
---

Project-specific fix workflow.
`,
    );

    const { skills } = loadJackalSkills({ cwd: project });
    const fix = skills.find((s) => s.name === "fix-skill");
    expect(fix?.source).toBe("project");
    expect(readSkillBody(fix!.filePath)).toContain("Project-specific fix workflow");
  });
});

function readSkillBody(filePath: string): string {
  const { body } = parseFrontmatter(readFileSync(filePath, "utf-8"));
  return body.trim();
}

describe("formatSkillsForPrompt", () => {
  it("formats skills as XML with absolute locations", () => {
    const { skills } = loadJackalSkills({ cwd: process.cwd() });
    const fix = skills.find((s) => s.name === "fix-skill");
    expect(fix).toBeDefined();

    const result = formatSkillsForPrompt([fix!]);
    expect(result).toContain("<available_skills>");
    expect(result).toContain("<name>fix-skill</name>");
    expect(result).toContain(`<location>${fix!.filePath}</location>`);
    expect(result).toContain("Use the read tool to load a skill's file");
  });

  it("excludes disable-model-invocation skills", () => {
    const result = formatSkillsForPrompt([
      {
        name: "hidden",
        description: "Hidden skill",
        filePath: "/tmp/hidden/SKILL.md",
        baseDir: "/tmp/hidden",
        source: "path",
        disableModelInvocation: true,
      },
    ]);
    expect(result).toBe("");
  });
});

describe("appendSkillsToPrompt", () => {
  it("appends XML catalog when skills exist", () => {
    const { skills } = loadJackalSkills({ cwd: process.cwd() });
    const prompt = appendSkillsToPrompt("Base prompt", skills);
    expect(prompt).toContain("Base prompt");
    expect(prompt).toContain("<available_skills>");
    expect(prompt).toContain("Use the read tool");
  });
});

describe("expandSkillCommand", () => {
  it("expands /skill:name into XML skill block", () => {
    const { skills } = loadJackalSkills({ cwd: process.cwd() });
    const expanded = expandSkillCommand("/skill:fix-skill", skills);
    expect(expanded).toContain('<skill name="fix-skill" location="');
    expect(expanded).toMatch(/validate_jac|Fix Workflow/i);
  });

  it("passes through unknown skills unchanged", () => {
    const expanded = expandSkillCommand("/skill:not-a-real-skill", []);
    expect(expanded).toBe("/skill:not-a-real-skill");
  });

  it("appends args after skill block", () => {
    const { skills } = loadJackalSkills({ cwd: process.cwd() });
    const expanded = expandSkillCommand("/skill:fix-skill check main.jac", skills);
    expect(expanded).toContain('<skill name="fix-skill"');
    expect(expanded).toContain("check main.jac");
  });
});

describe("loadSkillByDir", () => {
  it("strips YAML frontmatter from built-in skills", () => {
    const body = loadSkillByDir("osp-skill");
    expect(body.length).toBeGreaterThan(0);
    expect(body).not.toContain("---");
    expect(body).not.toMatch(/^name:/m);
  });
});
