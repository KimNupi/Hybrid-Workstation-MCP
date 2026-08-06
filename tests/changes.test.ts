import { spawnSync } from "node:child_process";
import { mkdir, mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { describe, expect, it } from "vitest";
import { showChanges } from "../src/changes.js";
import type { ProjectContext } from "../src/profile.js";

function runGit(cwd: string, args: string[]): string {
  const result = spawnSync("git.exe", args, { cwd, encoding: "utf8", windowsHide: true });
  if (result.status !== 0) throw new Error(result.stderr || result.stdout || `git ${args.join(" ")} failed`);
  return result.stdout.trim();
}

function contextFor(repo: string): ProjectContext {
  return {
    profile: {
      id: "changes-fixture",
      displayName: "Changes Fixture",
      appName: "Changes Fixture",
      serverName: "changes-fixture",
      permissionPreset: "workstation",
      defaultWorkingDirectoryRelative: ".",
      httpPort: 23103,
      bootstrapFiles: [],
      identityMarkers: [],
      primaryRoot: repo,
    },
    primaryRoot: repo,
    defaultWorkingDirectory: repo,
    engineRoot: join(repo, ".."),
    managedProjectRoots: [{ profileId: "changes-fixture", primaryRoot: repo }],
  };
}

describe("show_changes", () => {
  it("summarizes staged, unstaged, combined, and untracked files with a bounded patch", async () => {
    const root = await mkdtemp(join(tmpdir(), "wbs-changes-"));
    const repo = join(root, "repo");
    await mkdir(repo, { recursive: true });
    try {
      runGit(repo, ["init", "-b", "main"]);
      runGit(repo, ["config", "user.name", "WBS Test"]);
      runGit(repo, ["config", "user.email", "wbs@example.invalid"]);
      await writeFile(join(repo, "both.txt"), "base\n", "utf8");
      await writeFile(join(repo, "staged.txt"), "base\n", "utf8");
      await writeFile(join(repo, "unstaged.txt"), "base\n", "utf8");
      runGit(repo, ["add", "."]);
      runGit(repo, ["commit", "-m", "base"]);

      await writeFile(join(repo, "both.txt"), "base\nstaged\n", "utf8");
      await writeFile(join(repo, "staged.txt"), "base\nstaged\n", "utf8");
      runGit(repo, ["add", "both.txt", "staged.txt"]);
      await writeFile(join(repo, "both.txt"), "base\nstaged\nunstaged\n", "utf8");
      await writeFile(join(repo, "unstaged.txt"), "base\nunstaged\n", "utf8");
      await writeFile(join(repo, "untracked.txt"), "new\n", "utf8");

      const result = await showChanges({
        context: contextFor(repo),
        path: repo,
        maxPatchCharacters: 50_000,
      });
      expect(result.head).toMatch(/^[a-f0-9]{40}$/u);
      expect(result.branch).toBe("main");
      expect(result.summary).toMatchObject({
        files: 4,
        stagedFiles: 2,
        unstagedFiles: 2,
        untrackedFiles: 1,
      });
      expect(result.files.find((file) => file.path === "both.txt")?.scope).toBe("both");
      expect(result.files.find((file) => file.path === "staged.txt")?.scope).toBe("staged");
      expect(result.files.find((file) => file.path === "unstaged.txt")?.scope).toBe("unstaged");
      expect(result.files.find((file) => file.path === "untracked.txt")?.scope).toBe("untracked");
      expect(result.patch).toContain("# Staged changes");
      expect(result.patch).toContain("# Unstaged changes");
      expect(result.inventoryTruncated).toBe(false);
      expect(result.patchTruncated).toBe(false);

      const bounded = await showChanges({
        context: contextFor(repo),
        path: repo,
        maxPatchCharacters: 40,
      });
      expect(bounded.patchTruncated).toBe(true);
      expect(bounded.patch).toContain("[diff truncated]");
    } finally {
      await rm(root, { recursive: true, force: true });
    }
  });

  it("summarizes an unborn Git repository without requiring HEAD", async () => {
    const root = await mkdtemp(join(tmpdir(), "wbs-changes-unborn-"));
    const repo = join(root, "repo");
    await mkdir(repo, { recursive: true });
    try {
      runGit(repo, ["init", "-b", "main"]);
      await writeFile(join(repo, "untracked.txt"), "new\n", "utf8");
      const result = await showChanges({
        context: contextFor(repo),
        path: repo,
        maxPatchCharacters: 10_000,
      });
      expect(result.head).toBeNull();
      expect(result.branch).toBe("main");
      expect(result.summary).toMatchObject({ files: 1, untrackedFiles: 1 });
      expect(result.files[0]).toMatchObject({ path: "untracked.txt", scope: "untracked" });
      expect(result.inventoryTruncated).toBe(false);
    } finally {
      await rm(root, { recursive: true, force: true });
    }
  });
});
