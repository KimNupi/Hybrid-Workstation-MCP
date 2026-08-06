import { spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import { mkdir, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { describe, expect, it } from "vitest";
import type { ProjectContext } from "../src/profile.js";
import { createManagedWorktree, listManagedWorktrees, removeManagedWorktree } from "../src/worktree.js";

function runGit(cwd: string, args: string[]): string {
  const result = spawnSync("git.exe", args, { cwd, encoding: "utf8", windowsHide: true });
  if (result.status !== 0) throw new Error(result.stderr || result.stdout || `git ${args.join(" ")} failed`);
  return result.stdout.trim();
}

function contextFor(repo: string, engineRoot: string): ProjectContext {
  return {
    profile: {
      id: "worktree-fixture",
      displayName: "Worktree Fixture",
      appName: "Worktree Fixture",
      serverName: "worktree-fixture",
      permissionPreset: "workstation",
      defaultWorkingDirectoryRelative: ".",
      httpPort: 23102,
      bootstrapFiles: [],
      identityMarkers: [],
      primaryRoot: repo,
    },
    primaryRoot: repo,
    defaultWorkingDirectory: repo,
    engineRoot,
    managedProjectRoots: [{ profileId: "worktree-fixture", primaryRoot: repo }],
  };
}

async function initializeRepository(root: string) {
  const repo = join(root, "repo");
  const engineRoot = join(root, "engine");
  await mkdir(repo, { recursive: true });
  await mkdir(engineRoot, { recursive: true });
  runGit(repo, ["init", "-b", "main"]);
  runGit(repo, ["config", "core.autocrlf", "false"]);
  runGit(repo, ["config", "user.name", "Hybrid Workstation Test"]);
  runGit(repo, ["config", "user.email", "hybrid-workstation@example.invalid"]);
  await writeFile(join(repo, "tracked.txt"), "base\n", "utf8");
  runGit(repo, ["add", "tracked.txt"]);
  runGit(repo, ["commit", "-m", "base"]);
  return { repo, engineRoot, context: contextFor(repo, engineRoot) };
}

function expectedWorktreeId(repo: string, branch: string): string {
  const normalized = process.platform === "win32" ? repo.toLocaleLowerCase("en-US") : repo;
  const digest = createHash("sha256").update(normalized, "utf8").update("\0", "utf8").update(branch, "utf8").digest("hex");
  return `wt_${digest.slice(0, 32)}`;
}

describe("managed Git worktrees", () => {
  it("creates by branch idempotently, refuses dirty removal, preserves the branch, and reopens it", async () => {
    const root = await mkdtemp(join(tmpdir(), "hybrid-worktree-"));
    try {
      const { repo, context } = await initializeRepository(root);
      const branch = "agent/isolated-change";
      const created = await createManagedWorktree({ context, branch, baseRef: "HEAD" });
      expect(created).toMatchObject({
        recovered: false,
        branch,
        branchCreated: true,
        present: true,
        registered: true,
        dirty: false,
      });
      expect(created.worktreeId).toBe(expectedWorktreeId(repo, branch));
      expect(await readFile(join(created.path, "tracked.txt"), "utf8")).toBe("base\n");

      const recovered = await createManagedWorktree({ context, branch, baseRef: "main" });
      expect(recovered.recovered).toBe(true);
      expect(recovered.worktreeId).toBe(created.worktreeId);

      const listed = await listManagedWorktrees(context);
      expect(listed.items).toHaveLength(1);
      expect(listed.items[0]).toMatchObject({
        worktreeId: created.worktreeId,
        branch,
        present: true,
        registered: true,
        dirty: false,
      });

      await writeFile(join(created.path, "tracked.txt"), "dirty\n", "utf8");
      await expect(removeManagedWorktree({ context, worktreeId: created.worktreeId })).rejects.toThrow(/local changes/u);
      runGit(created.path, ["restore", "tracked.txt"]);

      const removed = await removeManagedWorktree({ context, worktreeId: created.worktreeId });
      expect(removed).toMatchObject({ removed: true, branchPreserved: true, branch });
      expect(runGit(repo, ["show-ref", "--verify", `refs/heads/${branch}`])).toBeTruthy();
      expect((await listManagedWorktrees(context)).items).toEqual([]);

      const reopened = await createManagedWorktree({ context, branch, baseRef: "HEAD" });
      expect(reopened.worktreeId).toBe(created.worktreeId);
      expect(reopened.branchCreated).toBe(false);
      expect(reopened.head).toBe(created.head);
      await removeManagedWorktree({ context, worktreeId: reopened.worktreeId });
    } finally {
      await rm(root, { recursive: true, force: true });
    }
  }, 30_000);

  it("never deletes a pre-existing unverified managed-worktree path", async () => {
    const root = await mkdtemp(join(tmpdir(), "hybrid-worktree-collision-"));
    try {
      const { repo, engineRoot, context } = await initializeRepository(root);
      const branch = "agent/collision";
      const worktreeId = expectedWorktreeId(repo, branch);
      const collisionPath = join(engineRoot, "runtime", "managed-worktrees", "worktree-fixture", worktreeId);
      await mkdir(collisionPath, { recursive: true });
      await writeFile(join(collisionPath, "sentinel.txt"), "preserve\n", "utf8");

      await expect(createManagedWorktree({ context, branch, baseRef: "HEAD" })).rejects.toThrow(/already exists/u);
      expect(await readFile(join(collisionPath, "sentinel.txt"), "utf8")).toBe("preserve\n");
      expect((await listManagedWorktrees(context)).items).toEqual([]);
    } finally {
      await rm(root, { recursive: true, force: true });
    }
  });

  it("refuses a branch that is already checked out elsewhere", async () => {
    const root = await mkdtemp(join(tmpdir(), "hybrid-worktree-branch-busy-"));
    try {
      const { repo, context } = await initializeRepository(root);
      const otherPath = join(root, "other");
      runGit(repo, ["worktree", "add", "-b", "agent/busy", otherPath, "HEAD"]);
      await expect(createManagedWorktree({
        context,
        branch: "agent/busy",
        baseRef: "HEAD",
      })).rejects.toThrow(/already checked out/u);
    } finally {
      await rm(root, { recursive: true, force: true });
    }
  });
});
