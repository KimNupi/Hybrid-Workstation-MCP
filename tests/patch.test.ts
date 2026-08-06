import { spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import { mkdir, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { describe, expect, it } from "vitest";
import { applyPatch } from "../src/patch.js";
import type { ProjectContext } from "../src/profile.js";

function runGit(cwd: string, args: string[]): string {
  const result = spawnSync("git.exe", args, { cwd, encoding: "utf8", windowsHide: true });
  if (result.status !== 0) throw new Error(result.stderr || result.stdout || `git ${args.join(" ")} failed`);
  return result.stdout.trim();
}

function hash(text: string): string {
  return createHash("sha256").update(Buffer.from(text, "utf8")).digest("hex");
}

function contextFor(repo: string, engineRoot: string): ProjectContext {
  return {
    profile: {
      id: "patch-fixture",
      displayName: "Patch Fixture",
      appName: "Patch Fixture",
      serverName: "patch-fixture",
      permissionPreset: "workstation",
      defaultWorkingDirectoryRelative: ".",
      httpPort: 23101,
      bootstrapFiles: [],
      identityMarkers: [],
      primaryRoot: repo,
    },
    primaryRoot: repo,
    defaultWorkingDirectory: repo,
    engineRoot,
    managedProjectRoots: [{ profileId: "patch-fixture", primaryRoot: repo }],
  };
}

const patch = [
  "diff --git a/one.txt b/one.txt",
  "--- a/one.txt",
  "+++ b/one.txt",
  "@@ -1 +1,2 @@",
  " alpha",
  "+beta",
  "diff --git a/new.txt b/new.txt",
  "new file mode 100644",
  "index 0000000..3e75765",
  "--- /dev/null",
  "+++ b/new.txt",
  "@@ -0,0 +1 @@",
  "+new",
  "diff --git a/delete.txt b/delete.txt",
  "deleted file mode 100644",
  "index 2f9a147..0000000",
  "--- a/delete.txt",
  "+++ /dev/null",
  "@@ -1 +0,0 @@",
  "-remove",
  "",
].join("\n");

describe("hash-guarded apply_patch", () => {
  it("applies multi-file text patches atomically and reports review data", async () => {
    const root = await mkdtemp(join(tmpdir(), "wbs-patch-"));
    const repo = join(root, "repo");
    const runtimeRoot = join(root, "runtime");
    await mkdir(repo, { recursive: true });
    await mkdir(runtimeRoot, { recursive: true });
    try {
      runGit(repo, ["init", "-b", "main"]);
      runGit(repo, ["config", "core.autocrlf", "false"]);
      runGit(repo, ["config", "user.name", "WBS Test"]);
      runGit(repo, ["config", "user.email", "wbs@example.invalid"]);
      await writeFile(join(repo, "one.txt"), "alpha\n", "utf8");
      await writeFile(join(repo, "delete.txt"), "remove\n", "utf8");
      runGit(repo, ["add", "."]);
      runGit(repo, ["commit", "-m", "base"]);

      const result = await applyPatch({
        context: contextFor(repo, runtimeRoot),
        root: repo,
        patch,
        expectedFiles: [
          { path: "one.txt", expectedSha256: hash("alpha\n") },
          { path: "new.txt", expectedSha256: "absent" },
          { path: "delete.txt", expectedSha256: hash("remove\n") },
        ],
      });

      expect(await readFile(join(repo, "one.txt"), "utf8")).toBe("alpha\nbeta\n");
      expect(await readFile(join(repo, "new.txt"), "utf8")).toBe("new\n");
      await expect(readFile(join(repo, "delete.txt"), "utf8")).rejects.toThrow();
      expect(result.files.map((file) => [file.path, file.action])).toEqual([
        ["one.txt", "update"],
        ["new.txt", "add"],
        ["delete.txt", "delete"],
      ]);
      expect(result.additions).toBe(2);
      expect(result.deletions).toBe(1);
    } finally {
      await rm(root, { recursive: true, force: true });
    }
  }, 30_000);

  it("rejects stale baselines before changing any patch target", async () => {
    const root = await mkdtemp(join(tmpdir(), "wbs-patch-stale-"));
    const repo = join(root, "repo");
    const runtimeRoot = join(root, "runtime");
    await mkdir(repo, { recursive: true });
    await mkdir(runtimeRoot, { recursive: true });
    try {
      runGit(repo, ["init", "-b", "main"]);
      runGit(repo, ["config", "core.autocrlf", "false"]);
      await writeFile(join(repo, "one.txt"), "changed elsewhere\n", "utf8");
      await writeFile(join(repo, "delete.txt"), "remove\n", "utf8");
      await expect(applyPatch({
        context: contextFor(repo, runtimeRoot),
        root: repo,
        patch,
        expectedFiles: [
          { path: "one.txt", expectedSha256: hash("alpha\n") },
          { path: "new.txt", expectedSha256: "absent" },
          { path: "delete.txt", expectedSha256: hash("remove\n") },
        ],
      })).rejects.toThrow(/baseline changed/u);
      expect(await readFile(join(repo, "one.txt"), "utf8")).toBe("changed elsewhere\n");
      expect(await readFile(join(repo, "delete.txt"), "utf8")).toBe("remove\n");
      await expect(readFile(join(repo, "new.txt"), "utf8")).rejects.toThrow();
    } finally {
      await rm(root, { recursive: true, force: true });
    }
  });

  it("rejects symlink and non-regular Git file modes before touching the workspace", async () => {
    const unsafePatch = [
      "diff --git a/link.txt b/link.txt",
      "new file mode 120000",
      "index 0000000..d95f3ad",
      "--- /dev/null",
      "+++ b/link.txt",
      "@@ -0,0 +1 @@",
      "+../outside.txt",
      "",
    ].join("\n");
    await expect(applyPatch({
      context: contextFor("C:\\unused", "C:\\unused-runtime"),
      root: "C:\\unused",
      patch: unsafePatch,
      expectedFiles: [{ path: "link.txt", expectedSha256: "absent" }],
    })).rejects.toThrow(/regular text-file Git modes/u);
  });
});
