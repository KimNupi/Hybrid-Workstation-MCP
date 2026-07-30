import { readFile, readdir } from "node:fs/promises";
import { resolve } from "node:path";
import { describe, expect, it } from "vitest";

describe("public stdio transport contract", () => {
  it("keeps the tunnel sample and MCP entrypoint pinned to stdio", async () => {
    const configure = await readFile(resolve("scripts", "Configure-Tunnel.ps1"), "utf8");
    const stdio = await readFile(resolve("src", "stdio.ts"), "utf8");
    expect(configure).toContain("sample_mcp_stdio_local");
    expect(configure).toContain("--mcp-command");
    expect(configure).toContain("dist/stdio.js");
    expect(stdio).toContain("StdioServerTransport");
  });

  it("does not expose a public HTTP server entrypoint or direct Express dependency", async () => {
    const sourceFiles = await readdir(resolve("src"));
    const packageJson = JSON.parse(await readFile(resolve("package.json"), "utf8")) as {
      dependencies?: Record<string, string>;
    };
    expect(sourceFiles).not.toContain("http-server.ts");
    expect(packageJson.dependencies).not.toHaveProperty("express");
    for (const name of sourceFiles.filter((candidate) => candidate.endsWith(".ts"))) {
      const source = await readFile(resolve("src", name), "utf8");
      expect(source).not.toContain("StreamableHTTPServerTransport");
    }
  });
});
