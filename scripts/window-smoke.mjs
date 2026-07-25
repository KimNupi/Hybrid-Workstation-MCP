import { strict as assert } from "node:assert";
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StdioClientTransport } from "@modelcontextprotocol/sdk/client/stdio.js";
import { fileURLToPath } from "node:url";

function payload(result) {
  assert.notEqual(result.isError, true, JSON.stringify(result.content));
  const text = result.content.find((part) => part.type === "text")?.text;
  assert.equal(typeof text, "string");
  return JSON.parse(text);
}

const toolDirectory = fileURLToPath(new URL("..", import.meta.url));
const entrypoint = fileURLToPath(new URL("../dist/stdio.js", import.meta.url));
const profileId = process.argv[2] ?? "workstation";
const client = new Client({ name: `${profileId}-window-smoke`, version: "1.2.0" });
const transport = new StdioClientTransport({
  command: process.execPath,
  args: [entrypoint, "--profile", profileId],
  cwd: toolDirectory,
  env: { ...process.env, CONTROL_PLANE_API_KEY: "window-smoke-sentinel" },
  stderr: "inherit",
});

try {
  await client.connect(transport);
  const listed = payload(await client.callTool({ name: "ui_window_list", arguments: {} }));
  assert.ok(listed.windows.length > 0, "window smoke requires one local grant");
  const target = listed.windows[0];
  const result = await client.callTool({ name: "ui_window_capture", arguments: { windowRef: target.windowRef } });
  assert.notEqual(result.isError, true, JSON.stringify(result.content));
  const metadata = JSON.parse(result.content.find((part) => part.type === "text").text);
  const image = result.content.find((part) => part.type === "image");
  assert.equal(metadata.windowRef, target.windowRef);
  assert.equal(metadata.mimeType, "image/png");
  assert.match(metadata.sha256, /^[a-f0-9]{64}$/u);
  assert.ok(["windows_graphics_capture", "print_window_fallback"].includes(metadata.backend));
  assert.equal(image?.mimeType, "image/png");
  assert.ok(Buffer.from(image.data, "base64").byteLength > 8);
  console.log(`Window observation smoke passed: ${metadata.backend}, ${metadata.byteLength} bytes.`);
} finally {
  await client.close().catch(() => undefined);
}
