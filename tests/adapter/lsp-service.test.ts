import { describe, expect, it } from "vitest";
import { mkdtempSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { resolveLspConfig } from "../../src/jac/lsp-service.js";

describe("resolveLspConfig", () => {
  it("enables jac LSP auto-start by default", () => {
    const cwd = mkdtempSync(join(tmpdir(), "jackal-lsp-"));
    const config = resolveLspConfig(cwd);

    expect(config.enabled).toBe(true);
    expect(config.autoStart).toEqual(["jac"]);
    expect(config.servers.jac?.args).toEqual(["lsp"]);
  });

  it("respects .jackal lsp=false", () => {
    const cwd = mkdtempSync(join(tmpdir(), "jackal-lsp-"));
    const config = resolveLspConfig(cwd, { lsp: false });

    expect(config.enabled).toBe(false);
  });

  it("loads autoStart and servers from .pi-lsp.json", () => {
    const cwd = mkdtempSync(join(tmpdir(), "jackal-lsp-"));
    writeFileSync(
      join(cwd, ".pi-lsp.json"),
      JSON.stringify({
        autoStart: ["jac"],
        servers: { jac: { command: "jac", args: ["lsp"] } },
      }),
    );

    const config = resolveLspConfig(cwd);
    expect(config.autoStart).toEqual(["jac"]);
    expect(config.servers.jac?.command).toBeTruthy();
    expect(config.servers.jac?.args).toEqual(["lsp"]);
  });

  it("honors explicit autoStart disable in .pi-lsp.json", () => {
    const cwd = mkdtempSync(join(tmpdir(), "jackal-lsp-"));
    writeFileSync(join(cwd, ".pi-lsp.json"), JSON.stringify({ autoStart: [] }));

    const config = resolveLspConfig(cwd);
    expect(config.autoStart).toEqual([]);
  });
});
