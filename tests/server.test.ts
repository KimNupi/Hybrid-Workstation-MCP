import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { InMemoryTransport } from "@modelcontextprotocol/sdk/inMemory.js";
import { describe, expect, it } from "vitest";
import type { PermissionPreset, ProjectContext } from "../src/profile.js";
import { createServer } from "../src/server.js";

const readTools = [
  "list_directory",
  "project_resume",
  "read_image",
  "read_text_file",
  "search_files",
  "show_changes",
  "ui_window_capture",
  "ui_window_list",
  "workstation_context",
];
const writeTools = ["apply_patch", "replace_text", "write_text_file"];
const shellTools = ["shell_cancel", "shell_output", "shell_start", "shell_status"];

function makeContext(permissionPreset: PermissionPreset): ProjectContext {
  const primaryRoot = "C:\\fixture";
  return {
    profile: {
      id: "fixture",
      displayName: "Fixture",
      appName: "Fixture",
      serverName: "fixture-workstation",
      permissionPreset,
      defaultWorkingDirectoryRelative: ".",
      httpPort: 23001,
      bootstrapFiles: [],
      identityMarkers: [{ relativePath: "fixture.marker", expectedLiteral: "identity=fixture" }],
      primaryRoot,
    },
    primaryRoot,
    defaultWorkingDirectory: primaryRoot,
    engineRoot: "C:\\engine",
    managedProjectRoots: [{ profileId: "fixture", primaryRoot }],
  };
}

async function listedTools(permissionPreset: PermissionPreset): Promise<string[]> {
  const server = createServer(makeContext(permissionPreset));
  const client = new Client({ name: "permission-preset-test", version: "1.0.0" });
  const [clientTransport, serverTransport] = InMemoryTransport.createLinkedPair();
  await Promise.all([server.connect(serverTransport), client.connect(clientTransport)]);
  try {
    return (await client.listTools()).tools.map((tool) => tool.name).sort();
  } finally {
    await client.close();
    await server.close();
  }
}

describe("permission presets", () => {
  it("exposes only read tools in readonly mode", async () => {
    await expect(listedTools("readonly")).resolves.toEqual([...readTools].sort());
  });

  it("preserves the full sixteen-tool workstation mode", async () => {
    await expect(listedTools("workstation")).resolves.toEqual([...readTools, ...writeTools, ...shellTools].sort());
  });
});
