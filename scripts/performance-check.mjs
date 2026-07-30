import { performance } from "node:perf_hooks";
import { mkdir, mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { createServer } from "../dist/server.js";
import { listDirectory, readTextFile } from "../dist/filesystem.js";
import { getWorkstationContext } from "../dist/workstation.js";

const root = await mkdtemp(join(tmpdir(), "hybrid-performance-"));
const projectRoot = join(root, "project");
const engineRoot = join(root, "engine");
const listingRoot = join(projectRoot, "listing");
const bootstrapPath = join(projectRoot, "AGENTS.md");
const largeTextPath = join(projectRoot, "large-mixed-lines.txt");

try {
  await Promise.all([
    mkdir(listingRoot, { recursive: true }),
    mkdir(engineRoot, { recursive: true }),
  ]);
  await writeFile(bootstrapPath, "Performance fixture.\n", "utf8");
  const fileCount = 800;
  for (let offset = 0; offset < fileCount; offset += 100) {
    await Promise.all(Array.from({ length: Math.min(100, fileCount - offset) }, (_, index) => (
      writeFile(join(listingRoot, `entry-${String(offset + index).padStart(4, "0")}.txt`), "fixture\n", "utf8")
    )));
  }
  const lineCount = 180_000;
  const chunks = [];
  for (let index = 1; index <= lineCount; index += 1) {
    const newline = index % 3 === 0 ? "\r\n" : index % 3 === 1 ? "\n" : "\r";
    chunks.push(`line-${index}${newline}`);
  }
  await writeFile(largeTextPath, chunks.join(""), "utf8");

  const profile = Object.freeze({
    id: "performance-fixture",
    displayName: "Performance Fixture",
    appName: "Performance Fixture",
    serverName: "performance-fixture",
    permissionPreset: "workstation",
    defaultWorkingDirectoryRelative: ".",
    httpPort: 23990,
    bootstrapFiles: Object.freeze(["AGENTS.md"]),
    identityMarkers: Object.freeze([]),
    primaryRoot: projectRoot,
  });
  const context = Object.freeze({
    profile,
    primaryRoot: projectRoot,
    defaultWorkingDirectory: projectRoot,
    engineRoot,
    managedProjectRoots: Object.freeze([{ profileId: profile.id, primaryRoot: projectRoot }]),
  });

  const serverCount = 40;
  const serverStartedAt = performance.now();
  const servers = Array.from({ length: serverCount }, () => createServer(context));
  const serverTotalMs = performance.now() - serverStartedAt;
  await Promise.all(servers.map((server) => server.close()));
  const serverAverageMs = serverTotalMs / serverCount;
  if (serverAverageMs > 30) {
    throw new Error(`MCP server construction regressed: ${serverAverageMs.toFixed(2)}ms average exceeds 30ms.`);
  }

  const contextCount = 30;
  const contextStartedAt = performance.now();
  for (let index = 0; index < contextCount; index += 1) await getWorkstationContext(context);
  const contextTotalMs = performance.now() - contextStartedAt;
  if (contextTotalMs > 1_500) {
    throw new Error(`workstation_context regressed: ${contextTotalMs.toFixed(2)}ms exceeds 1500ms.`);
  }

  const listingStartedAt = performance.now();
  const listing = await listDirectory({ context, path: listingRoot, depth: 1, maxEntries: 1_000 });
  const listingMs = performance.now() - listingStartedAt;
  if (listing.entries.length !== fileCount || listing.truncated) throw new Error("Directory performance fixture was incomplete.");
  if (listingMs > 3_000) {
    throw new Error(`Large directory listing regressed: ${listingMs.toFixed(2)}ms exceeds 3000ms.`);
  }

  const textStartedAt = performance.now();
  const text = await readTextFile({ context, path: largeTextPath, startLine: 150_000, maxLines: 400 });
  const textMs = performance.now() - textStartedAt;
  if (text.totalLines !== lineCount + 1 || text.endLine !== 150_399) throw new Error("Text pagination fixture was incomplete.");
  if (textMs > 2_000) {
    throw new Error(`Large text pagination regressed: ${textMs.toFixed(2)}ms exceeds 2000ms.`);
  }

  console.log(JSON.stringify({
    serverConstruction: { count: serverCount, totalMs: serverTotalMs, averageMs: serverAverageMs },
    workstationContext: { count: contextCount, totalMs: contextTotalMs },
    directoryListing: { entries: listing.entries.length, totalMs: listingMs },
    textPagination: { totalLines: text.totalLines, totalMs: textMs },
  }, null, 2));
} finally {
  await rm(root, { recursive: true, force: true });
}
