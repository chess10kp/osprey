import { describe, expect, it } from "vitest";
import {
  buildConvertPythonPrompt,
  buildExplainPrompt,
  buildOspPrompt,
  renderPromptTemplate,
} from "../../src/jac/jac-workflows.js";

describe("jac-workflows (lib/jac bridge)", () => {
  it("renderPromptTemplate substitutes placeholders", () => {
    const text = renderPromptTemplate("convert-python", { path: "foo.py" });
    expect(text).toContain("foo.py");
  });

  it("buildOspPrompt includes description", () => {
    const text = buildOspPrompt("my graph model");
    expect(text).toContain("my graph model");
  });

  it("buildExplainPrompt file mode includes code", () => {
    const text = buildExplainPrompt("file", "walker foo;");
    expect(text).toContain("walker foo;");
  });
});
