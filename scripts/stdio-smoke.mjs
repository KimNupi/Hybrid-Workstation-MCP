import { strict as assert } from "node:assert";
import { spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import { mkdir, mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StdioClientTransport } from "@modelcontextprotocol/sdk/client/stdio.js";

const expectedTools = [
  "apply_patch",
  "git_worktree_create",
  "git_worktree_list",
  "git_worktree_remove",
  "list_directory",
  "project_resume",
  "read_image",
  "read_text_file",
  "replace_text",
  "search_files",
  "show_changes",
  "shell_cancel",
  "shell_output",
  "shell_start",
  "shell_status",
  "ui_window_capture",
  "ui_window_list",
  "workstation_context",
  "write_text_file",
].sort();

function runGit(cwd, args) {
  const result = spawnSync("git.exe", args, { cwd, encoding: "utf8", windowsHide: true });
  if (result.status !== 0) throw new Error(result.stderr || result.stdout || `git ${args.join(" ")} failed`);
  return result.stdout.trim();
}

function payload(result) {
  assert.notEqual(result.isError, true, JSON.stringify(result.content));
  const text = result.content.find((part) => part.type === "text")?.text;
  assert.equal(typeof text, "string");
  return JSON.parse(text);
}

function errorText(result) {
  assert.equal(result.isError, true, JSON.stringify(result.content));
  return result.content
    .filter((part) => part.type === "text")
    .map((part) => part.text)
    .join("\n");
}

async function waitForShell(client, id) {
  const deadline = Date.now() + 20_000;
  while (Date.now() < deadline) {
    const status = payload(await client.callTool({ name: "shell_status", arguments: { id } }));
    if (status.status !== "running" && status.trackingState === "archived_terminal") return status;
    await new Promise((resolveWait) => setTimeout(resolveWait, 50));
  }
  throw new Error(`Shell job did not finish: ${id}`);
}

const toolDirectory = fileURLToPath(new URL("..", import.meta.url));
const entrypoint = fileURLToPath(new URL("../dist/stdio.js", import.meta.url));
const fixtureRoot = await mkdtemp(join(tmpdir(), "hybrid-workstation-stdio-"));
const engineRoot = join(fixtureRoot, "engine");
const runtimeRoot = join(engineRoot, "runtime");
const projectRoot = join(fixtureRoot, "project");
const profileDirectory = join(projectRoot, "tools", "chatgpt-hybrid-mcp");
const profilePath = join(profileDirectory, "profile.json");
const registryPath = join(runtimeRoot, "profile_registry.json");
const markerPath = join(projectRoot, "workstation.marker");
const bootstrapPath = join(projectRoot, "AGENTS.md");
const readablePath = join(fixtureRoot, "readable.txt");
const protectedPath = join(runtimeRoot, ".env.local");
const profileId = "stdio-fixture";

await Promise.all([
  mkdir(profileDirectory, { recursive: true }),
  mkdir(runtimeRoot, { recursive: true }),
]);
await Promise.all([
  writeFile(markerPath, `identity=${profileId}\n`, "utf8"),
  writeFile(bootstrapPath, "Fixture policy: verify every result.\n", "utf8"),
  writeFile(readablePath, "fixture=true\n", "utf8"),
  writeFile(protectedPath, "CONTROL_PLANE_API_KEY=must-not-be-readable\n", "utf8"),
]);
const profileText = `${JSON.stringify({
  id: profileId,
  displayName: "Stdio Fixture",
  appName: "Stdio Fixture Workstation",
  serverName: "stdio-fixture-workstation",
  permissionPreset: "workstation",
  defaultWorkingDirectoryRelative: ".",
  httpPort: 23998,
  bootstrapFiles: ["AGENTS.md"],
  identityMarkers: [{ relativePath: "workstation.marker", expectedLiteral: `identity=${profileId}` }],
}, null, 2)}\n`;
await writeFile(profilePath, profileText, "utf8");
await writeFile(registryPath, `${JSON.stringify({
  version: 1,
  profiles: [{
    id: profileId,
    profilePath,
    profileSha256: createHash("sha256").update(profileText).digest("hex"),
  }],
}, null, 2)}\n`, "utf8");
runGit(projectRoot, ["init", "-b", "main"]);
runGit(projectRoot, ["config", "core.autocrlf", "false"]);
runGit(projectRoot, ["config", "user.name", "Hybrid Workstation Stdio Smoke"]);
runGit(projectRoot, ["config", "user.email", "stdio-smoke@example.invalid"]);
runGit(projectRoot, ["add", "."]);
runGit(projectRoot, ["commit", "-m", "fixture"]);

const client = new Client({ name: "hermetic-stdio-smoke", version: "1.6.0" });
const transport = new StdioClientTransport({
  command: process.execPath,
  args: [entrypoint, "--profile", profileId],
  cwd: toolDirectory,
  env: {
    ...process.env,
    CHATGPT_HYBRID_ENGINE_ROOT: engineRoot,
    CHATGPT_HYBRID_PROFILE_REGISTRY: registryPath,
    CONTROL_PLANE_API_KEY: "stdio-smoke-sentinel",
  },
  stderr: "inherit",
});

try {
  await client.connect(transport);
  const listed = await client.listTools();
  assert.deepEqual(listed.tools.map((tool) => tool.name).sort(), expectedTools);

  const workstation = payload(await client.callTool({ name: "workstation_context", arguments: {} }));
  assert.equal(workstation.profileId, profileId);
  assert.equal(workstation.permissionPreset, "workstation");
  assert.equal(workstation.transport, "stdio");
  assert.equal(workstation.engineRoot, resolve(engineRoot));
  assert.match(workstation.contextRevision, /^[a-f0-9]{64}$/u);
  assert.match(workstation.buildRevision, /^[a-f0-9]{64}$/u);
  assert.match(workstation.toolSchemaRevision, /^[a-f0-9]{64}$/u);
  assert.notEqual(workstation.buildRevision, "0".repeat(64));
  assert.notEqual(workstation.toolSchemaRevision, "0".repeat(64));

  const readable = payload(await client.callTool({
    name: "read_text_file",
    arguments: { path: readablePath },
  }));
  assert.equal(readable.text, "fixture=true\n");

  const denied = await client.callTool({
    name: "read_text_file",
    arguments: { path: protectedPath },
  });
  assert.match(errorText(denied), /Protected credential/u);

  const managed = payload(await client.callTool({
    name: "git_worktree_create",
    arguments: {
      contextRevision: workstation.contextRevision,
      branch: "smoke/managed-worktree",
    },
  }));
  assert.match(managed.worktreeId, /^wt_[a-f0-9]{32}$/u);
  assert.match(managed.head, /^[a-f0-9]{40,64}$/u);
  assert.equal(managed.dirty, false);
  const managedList = payload(await client.callTool({ name: "git_worktree_list", arguments: {} }));
  assert.equal(managedList.items.length, 1);
  assert.equal(managedList.items[0].worktreeId, managed.worktreeId);
  const managedRemoval = payload(await client.callTool({
    name: "git_worktree_remove",
    arguments: {
      contextRevision: workstation.contextRevision,
      worktreeId: managed.worktreeId,
    },
  }));
  assert.equal(managedRemoval.removed, true);
  assert.equal(managedRemoval.branchPreserved, true);
  assert.equal(runGit(projectRoot, ["show-ref", "--verify", "refs/heads/smoke/managed-worktree"]).length > 0, true);

  const shell = payload(await client.callTool({
    name: "shell_start",
    arguments: {
      contextRevision: workstation.contextRevision,
      cwd: fixtureRoot,
      command: "if ($null -eq $env:CONTROL_PLANE_API_KEY) { Write-Output 'KEY_SCRUBBED' } else { Write-Output 'KEY_LEAKED' }",
      timeoutMs: 10_000,
    },
  }));
  const status = await waitForShell(client, shell.id);
  assert.equal(status.status, "completed");
  assert.equal(status.containmentEnforced, true);
  const output = payload(await client.callTool({ name: "shell_output", arguments: { id: shell.id } }));
  assert.match(output.stdout.text, /KEY_SCRUBBED/u);
  assert.doesNotMatch(output.stdout.text, /stdio-smoke-sentinel|KEY_LEAKED/u);

  console.log("Hermetic Hybrid Workstation stdio smoke passed: 19 tools, managed worktree lifecycle, build identity, protected files, and credential-scrubbed shell.");
} finally {
  await client.close().catch(() => undefined);
  await rm(fixtureRoot, { recursive: true, force: true });
}
