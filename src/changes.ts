import { stat, realpath } from "node:fs/promises";
import { dirname, resolve } from "node:path";
import type { ProjectContext } from "./profile.js";
import { makeWorkstationEnvironment, runProcess } from "./process.js";
import { resolveAuthorizedWorkstationPath } from "./workstation.js";

const MAX_GIT_OUTPUT_BYTES = 8 * 1024 * 1024;
const HEAD_PATTERN = /^[a-f0-9]{40,64}$/u;

type ChangeScope = "staged" | "unstaged" | "both" | "untracked";

interface MutableChange {
  path: string;
  staged: boolean;
  unstaged: boolean;
  untracked: boolean;
  additions: number;
  deletions: number;
  binary: boolean;
}

function normalizePath(path: string): string {
  return process.platform === "win32" ? path.toLocaleLowerCase("en-US") : path;
}

async function git(cwd: string, args: readonly string[], maxOutputBytes = MAX_GIT_OUTPUT_BYTES) {
  const result = await runProcess("git.exe", ["-C", cwd, ...args], {
    cwd,
    timeoutMs: 120_000,
    maxStdoutBytes: maxOutputBytes,
    maxStderrBytes: 1024 * 1024,
    env: makeWorkstationEnvironment({ GIT_TERMINAL_PROMPT: "0" }),
  });
  if (result.timedOut) throw new Error(`Git command timed out: git ${args.join(" ")}`);
  if (result.exitCode !== 0) {
    throw new Error((result.stderr || result.stdout).trim() || `Git command failed with exit code ${result.exitCode}.`);
  }
  return result;
}

async function readHead(repositoryRoot: string): Promise<string | null> {
  const result = await runProcess("git.exe", ["-C", repositoryRoot, "rev-parse", "--verify", "--quiet", "HEAD"], {
    cwd: repositoryRoot,
    timeoutMs: 30_000,
    maxStdoutBytes: 64 * 1024,
    maxStderrBytes: 64 * 1024,
    env: makeWorkstationEnvironment({ GIT_TERMINAL_PROMPT: "0" }),
  });
  if (result.timedOut) throw new Error("Git HEAD inspection timed out.");
  if (result.exitCode === 1) return null;
  if (result.exitCode !== 0) {
    throw new Error((result.stderr || result.stdout).trim() || `Git HEAD inspection failed with exit code ${result.exitCode}.`);
  }
  const head = result.stdout.trim().toLocaleLowerCase("en-US");
  if (!HEAD_PATTERN.test(head)) throw new Error("Git returned an invalid HEAD revision.");
  return head;
}

function parseNumstat(text: string, staged: boolean, changes: Map<string, MutableChange>): void {
  for (const line of text.split(/\r?\n/u)) {
    if (!line) continue;
    const firstTab = line.indexOf("\t");
    const secondTab = firstTab < 0 ? -1 : line.indexOf("\t", firstTab + 1);
    if (firstTab < 0 || secondTab < 0) continue;
    const additionsText = line.slice(0, firstTab);
    const deletionsText = line.slice(firstTab + 1, secondTab);
    const path = line.slice(secondTab + 1).replaceAll("\\", "/");
    if (!path) continue;
    const key = normalizePath(path);
    const existing = changes.get(key) ?? {
      path,
      staged: false,
      unstaged: false,
      untracked: false,
      additions: 0,
      deletions: 0,
      binary: false,
    };
    if (staged) existing.staged = true;
    else existing.unstaged = true;
    if (additionsText === "-" || deletionsText === "-") {
      existing.binary = true;
    } else {
      existing.additions += Number.parseInt(additionsText, 10) || 0;
      existing.deletions += Number.parseInt(deletionsText, 10) || 0;
    }
    changes.set(key, existing);
  }
}

function parseUntracked(status: string, changes: Map<string, MutableChange>): void {
  const entries = status.split("\0").filter(Boolean);
  for (let index = 0; index < entries.length; index += 1) {
    const entry = entries[index]!;
    if (entry.length < 4) continue;
    const code = entry.slice(0, 2);
    const path = entry.slice(3).replaceAll("\\", "/");
    if (code === "??" && path) {
      const key = normalizePath(path);
      changes.set(key, {
        path,
        staged: false,
        unstaged: false,
        untracked: true,
        additions: 0,
        deletions: 0,
        binary: false,
      });
    }
    if (code.includes("R") || code.includes("C")) index += 1;
  }
}

function scopeFor(change: MutableChange): ChangeScope {
  if (change.untracked) return "untracked";
  if (change.staged && change.unstaged) return "both";
  return change.staged ? "staged" : "unstaged";
}

function boundedPatch(staged: string, unstaged: string, maxCharacters: number) {
  const sections: string[] = [];
  if (staged.trim()) sections.push(`# Staged changes\n${staged.trimEnd()}`);
  if (unstaged.trim()) sections.push(`# Unstaged changes\n${unstaged.trimEnd()}`);
  const full = sections.join("\n\n");
  if (full.length <= maxCharacters) return { patch: full, patchTruncated: false };
  return {
    patch: `${full.slice(0, maxCharacters)}\n\n[diff truncated]`,
    patchTruncated: true,
  };
}

export async function showChanges(input: {
  context: ProjectContext;
  path: string;
  maxPatchCharacters: number;
}) {
  if (!Number.isInteger(input.maxPatchCharacters) || input.maxPatchCharacters < 1 || input.maxPatchCharacters > 200_000) {
    throw new Error("maxPatchCharacters must be an integer between 1 and 200000.");
  }
  const authorized = await resolveAuthorizedWorkstationPath(input.context, input.path, "tree");
  const info = await stat(authorized);
  const cwd = info.isDirectory() ? authorized : dirname(authorized);
  const topLevel = await git(cwd, ["rev-parse", "--show-toplevel"], 64 * 1024);
  const repositoryRoot = await realpath(resolve(topLevel.stdout.trim()));
  const head = await readHead(repositoryRoot);
  const branch = (await git(repositoryRoot, ["branch", "--show-current"], 64 * 1024)).stdout.trim() || null;

  const [stagedStat, unstagedStat, status, stagedDiff, unstagedDiff] = await Promise.all([
    git(repositoryRoot, ["diff", "--cached", "--numstat", "--no-renames"]),
    git(repositoryRoot, ["diff", "--numstat", "--no-renames"]),
    git(repositoryRoot, ["status", "--porcelain=v1", "-z", "--untracked-files=all"]),
    git(repositoryRoot, ["diff", "--cached", "--no-color", "--no-ext-diff", "--no-renames", "--unified=3"]),
    git(repositoryRoot, ["diff", "--no-color", "--no-ext-diff", "--no-renames", "--unified=3"]),
  ]);

  const changes = new Map<string, MutableChange>();
  parseNumstat(stagedStat.stdout, true, changes);
  parseNumstat(unstagedStat.stdout, false, changes);
  parseUntracked(status.stdout, changes);
  const files = [...changes.values()]
    .sort((left, right) => left.path.localeCompare(right.path, "en"))
    .map((change) => ({
      path: change.path,
      scope: scopeFor(change),
      additions: change.binary || change.untracked ? null : change.additions,
      deletions: change.binary || change.untracked ? null : change.deletions,
      binary: change.binary,
    }));
  const patch = boundedPatch(stagedDiff.stdout, unstagedDiff.stdout, input.maxPatchCharacters);

  return {
    repositoryRoot,
    head,
    branch,
    generatedAt: new Date().toISOString(),
    summary: {
      files: files.length,
      additions: files.reduce((sum, file) => sum + (file.additions ?? 0), 0),
      deletions: files.reduce((sum, file) => sum + (file.deletions ?? 0), 0),
      stagedFiles: files.filter((file) => file.scope === "staged" || file.scope === "both").length,
      unstagedFiles: files.filter((file) => file.scope === "unstaged" || file.scope === "both").length,
      untrackedFiles: files.filter((file) => file.scope === "untracked").length,
    },
    files,
    inventoryTruncated: stagedStat.truncated || unstagedStat.truncated || status.truncated,
    patch: patch.patch,
    patchTruncated: patch.patchTruncated || stagedDiff.truncated || unstagedDiff.truncated,
  } as const;
}
