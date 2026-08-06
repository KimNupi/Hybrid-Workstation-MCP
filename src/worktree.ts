import { createHash, randomBytes } from "node:crypto";
import { lstat, mkdir, open, readFile, readdir, realpath, rename, rm, stat, writeFile } from "node:fs/promises";
import { dirname, isAbsolute, relative, resolve } from "node:path";
import type { ProjectContext } from "./profile.js";
import { makeWorkstationEnvironment, runProcess } from "./process.js";

const MAX_OUTPUT_BYTES = 1024 * 1024;
const PROFILE_ID_PATTERN = /^[a-z0-9](?:[a-z0-9-]{0,30}[a-z0-9])?$/u;
const WORKTREE_ID_PATTERN = /^wt_[a-f0-9]{32}$/u;
const HEAD_PATTERN = /^[a-f0-9]{40,64}$/u;
const REF_PATTERN = /^[A-Za-z0-9][A-Za-z0-9._/-]{0,254}$/u;

type WorktreeRecordStatus = "creating" | "active";

interface WorktreeRecord {
  readonly version: 1;
  readonly status: WorktreeRecordStatus;
  readonly worktreeId: string;
  readonly profileId: string;
  readonly repositoryRoot: string;
  readonly path: string;
  readonly branch: string;
  readonly baseRef: string;
  readonly baseSha: string;
  readonly branchCreated: boolean;
  readonly createdAt: string;
}

interface PorcelainWorktree {
  readonly path: string;
  readonly head: string | null;
  readonly branch: string | null;
  readonly bare: boolean;
  readonly detached: boolean;
  readonly locked: boolean;
  readonly prunable: boolean;
}

function normalizeForComparison(path: string): string {
  return process.platform === "win32" ? path.toLocaleLowerCase("en-US") : path;
}

function isWithinOrEqual(root: string, candidate: string): boolean {
  const relationship = relative(normalizeForComparison(root), normalizeForComparison(candidate));
  return relationship === "" || (!relationship.startsWith("..") && !isAbsolute(relationship));
}

function errorCode(error: unknown): string | undefined {
  return error && typeof error === "object" && "code" in error
    ? String((error as { code?: unknown }).code)
    : undefined;
}

function processIsAlive(pid: number): boolean {
  try {
    process.kill(pid, 0);
    return true;
  } catch (error) {
    return errorCode(error) === "EPERM";
  }
}

function errorMessage(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}

function assertBranch(value: string): string {
  const branch = value.trim();
  if (
    branch !== value ||
    !REF_PATTERN.test(branch) ||
    branch.includes("..") ||
    branch.includes("@{") ||
    branch.endsWith(".") ||
    branch.endsWith("/")
  ) {
    throw new Error(`Invalid branch: ${value}`);
  }
  return branch;
}

function assertBaseRef(value: string): string {
  const baseRef = value.trim();
  if (
    baseRef !== value ||
    baseRef.length < 1 ||
    baseRef.length > 255 ||
    /[\0\r\n]/u.test(baseRef) ||
    baseRef.startsWith("-")
  ) {
    throw new Error(`Invalid baseRef: ${value}`);
  }
  return baseRef;
}

function assertWorktreeId(value: string): string {
  if (!WORKTREE_ID_PATTERN.test(value)) throw new Error(`Invalid worktreeId: ${value}`);
  return value;
}

function worktreeIdFor(repositoryRoot: string, branch: string): string {
  const digest = createHash("sha256")
    .update(normalizeForComparison(repositoryRoot), "utf8")
    .update("\0", "utf8")
    .update(branch, "utf8")
    .digest("hex");
  return `wt_${digest.slice(0, 32)}`;
}

function runtimeRoot(context: ProjectContext): string {
  return resolve(context.engineRoot, "runtime");
}

function stateRoot(context: ProjectContext): string {
  return resolve(runtimeRoot(context), "managed-worktree-state", context.profile.id);
}

function storageRoot(context: ProjectContext): string {
  return resolve(runtimeRoot(context), "managed-worktrees", context.profile.id);
}

function recordPath(context: ProjectContext, worktreeId: string): string {
  return resolve(stateRoot(context), `${worktreeId}.json`);
}

async function writeJsonAtomic(path: string, value: unknown, exclusive = false): Promise<void> {
  await mkdir(dirname(path), { recursive: true });
  if (exclusive) {
    await writeFile(path, `${JSON.stringify(value)}\n`, { encoding: "utf8", flag: "wx", mode: 0o600 });
    return;
  }
  const temporary = `${path}.${process.pid}.${randomBytes(8).toString("hex")}.tmp`;
  await writeFile(temporary, `${JSON.stringify(value)}\n`, { encoding: "utf8", flag: "wx", mode: 0o600 });
  try {
    await rename(temporary, path);
  } catch (error) {
    await rm(temporary, { force: true }).catch(() => undefined);
    throw error;
  }
}

function validateRecord(value: unknown): WorktreeRecord {
  if (!value || typeof value !== "object") throw new Error("Managed worktree record is invalid.");
  const item = value as Record<string, unknown>;
  if (
    item.version !== 1 ||
    (item.status !== "creating" && item.status !== "active") ||
    typeof item.worktreeId !== "string" ||
    typeof item.profileId !== "string" ||
    typeof item.repositoryRoot !== "string" ||
    typeof item.path !== "string" ||
    typeof item.branch !== "string" ||
    typeof item.baseRef !== "string" ||
    typeof item.baseSha !== "string" ||
    typeof item.branchCreated !== "boolean" ||
    typeof item.createdAt !== "string" ||
    !WORKTREE_ID_PATTERN.test(item.worktreeId) ||
    !PROFILE_ID_PATTERN.test(item.profileId) ||
    !HEAD_PATTERN.test(item.baseSha) ||
    !isAbsolute(item.repositoryRoot) ||
    !isAbsolute(item.path)
  ) {
    throw new Error("Managed worktree record is invalid.");
  }
  assertBranch(item.branch);
  assertBaseRef(item.baseRef);
  return item as unknown as WorktreeRecord;
}

async function readRecord(path: string): Promise<WorktreeRecord | undefined> {
  const info = await lstat(path).catch((error) => {
    if (errorCode(error) === "ENOENT") return undefined;
    throw error;
  });
  if (!info) return undefined;
  if (!info.isFile() || info.isSymbolicLink() || info.nlink > 1 || info.size > 64 * 1024) {
    throw new Error(`Managed worktree record is unsafe: ${path}`);
  }
  const text = await readFile(path, "utf8");
  return validateRecord(JSON.parse(text) as unknown);
}

async function git(repositoryRoot: string, args: readonly string[], timeoutMs = 30_000) {
  const result = await runProcess("git.exe", ["-C", repositoryRoot, ...args], {
    cwd: repositoryRoot,
    timeoutMs,
    maxStdoutBytes: MAX_OUTPUT_BYTES,
    maxStderrBytes: MAX_OUTPUT_BYTES,
    env: makeWorkstationEnvironment({ GIT_TERMINAL_PROMPT: "0" }),
  });
  if (result.timedOut) throw new Error(`Git command timed out: git ${args.join(" ")}`);
  if (result.exitCode !== 0) {
    throw new Error((result.stderr || result.stdout).trim() || `Git command failed with exit code ${result.exitCode}.`);
  }
  return result;
}

async function assertExactGitRoot(context: ProjectContext): Promise<string> {
  const canonical = await realpath(context.primaryRoot);
  const discovered = await git(canonical, ["rev-parse", "--show-toplevel"]);
  const exact = await realpath(discovered.stdout.trim());
  if (normalizeForComparison(exact) !== normalizeForComparison(canonical)) {
    throw new Error(`Registered project root is not the Git repository root: ${context.primaryRoot}`);
  }
  return canonical;
}

async function resolveCommit(repositoryRoot: string, ref: string): Promise<string> {
  const result = await git(repositoryRoot, ["rev-parse", "--verify", `${ref}^{commit}`]);
  const head = result.stdout.trim().toLocaleLowerCase("en-US");
  if (!HEAD_PATTERN.test(head)) throw new Error("Git returned an invalid revision.");
  return head;
}

async function currentHead(worktreePath: string): Promise<string> {
  return await resolveCommit(worktreePath, "HEAD");
}

async function currentBranch(worktreePath: string): Promise<string | null> {
  return (await git(worktreePath, ["branch", "--show-current"])).stdout.trim() || null;
}

async function branchExists(repositoryRoot: string, branch: string): Promise<boolean> {
  const result = await runProcess(
    "git.exe",
    ["-C", repositoryRoot, "show-ref", "--verify", "--quiet", `refs/heads/${branch}`],
    {
      cwd: repositoryRoot,
      timeoutMs: 30_000,
      maxStdoutBytes: 64 * 1024,
      maxStderrBytes: 64 * 1024,
      env: makeWorkstationEnvironment({ GIT_TERMINAL_PROMPT: "0" }),
    },
  );
  if (result.exitCode === 0) return true;
  if (result.exitCode === 1) return false;
  throw new Error((result.stderr || result.stdout).trim() || "Could not inspect branch state.");
}

async function acquireGitLease(leasePath: string): Promise<void> {
  for (let attempt = 0; attempt < 3; attempt += 1) {
    try {
      const handle = await open(leasePath, "wx");
      try {
        await handle.writeFile(
          `${JSON.stringify({ version: 1, processId: process.pid, createdAt: new Date().toISOString() })}\n`,
          "utf8",
        );
      } finally {
        await handle.close();
      }
      return;
    } catch (error) {
      if (errorCode(error) !== "EEXIST") throw error;
      const existing = await readFile(leasePath, "utf8").catch(() => "");
      let ownerPid = 0;
      try {
        const parsed = JSON.parse(existing) as { processId?: unknown };
        ownerPid = typeof parsed.processId === "number" && Number.isInteger(parsed.processId) ? parsed.processId : 0;
      } catch {
        ownerPid = 0;
      }
      const leaseInfo = await stat(leasePath).catch(() => undefined);
      const staleUnknownOwner = ownerPid <= 0 && leaseInfo !== undefined && Date.now() - leaseInfo.mtimeMs >= 30_000;
      if ((ownerPid > 0 && !processIsAlive(ownerPid)) || staleUnknownOwner) {
        await rm(leasePath, { force: true });
        continue;
      }
      throw new Error("GIT_TOOL_LEASE_BUSY: another structured Git operation is active for this repository.");
    }
  }
  throw new Error("GIT_TOOL_LEASE_BUSY: another structured Git operation is active for this repository.");
}

async function withGitLease<T>(
  context: ProjectContext,
  repositoryRoot: string,
  operation: () => Promise<T>,
): Promise<T> {
  const hash = createHash("sha256").update(normalizeForComparison(repositoryRoot), "utf8").digest("hex");
  const leasePath = resolve(runtimeRoot(context), "git-tool-leases", hash);
  await mkdir(dirname(leasePath), { recursive: true });
  await acquireGitLease(leasePath);
  try {
    return await operation();
  } finally {
    await rm(leasePath, { force: true }).catch(() => undefined);
  }
}

function parseWorktreePorcelain(text: string): PorcelainWorktree[] {
  const records: PorcelainWorktree[] = [];
  let current: {
    path?: string;
    head?: string;
    branch?: string;
    bare?: boolean;
    detached?: boolean;
    locked?: boolean;
    prunable?: boolean;
  } = {};
  const finish = () => {
    if (!current.path) return;
    records.push({
      path: resolve(current.path),
      head: current.head && HEAD_PATTERN.test(current.head.toLocaleLowerCase("en-US"))
        ? current.head.toLocaleLowerCase("en-US")
        : null,
      branch: current.branch?.startsWith("refs/heads/") ? current.branch.slice("refs/heads/".length) : null,
      bare: current.bare === true,
      detached: current.detached === true,
      locked: current.locked === true,
      prunable: current.prunable === true,
    });
    current = {};
  };
  for (const line of text.split(/\r?\n/u)) {
    if (!line) {
      finish();
      continue;
    }
    const space = line.indexOf(" ");
    const key = space < 0 ? line : line.slice(0, space);
    const value = space < 0 ? "" : line.slice(space + 1);
    if (key === "worktree") current.path = value;
    else if (key === "HEAD") current.head = value;
    else if (key === "branch") current.branch = value;
    else if (key === "bare") current.bare = true;
    else if (key === "detached") current.detached = true;
    else if (key === "locked") current.locked = true;
    else if (key === "prunable") current.prunable = true;
  }
  finish();
  return records;
}

async function listedWorktrees(repositoryRoot: string): Promise<PorcelainWorktree[]> {
  return parseWorktreePorcelain((await git(repositoryRoot, ["worktree", "list", "--porcelain"])).stdout);
}

async function statusForRecord(repositoryRoot: string, record: WorktreeRecord) {
  const registered = (await listedWorktrees(repositoryRoot)).find(
    (item) => normalizeForComparison(item.path) === normalizeForComparison(record.path),
  );
  if (registered && registered.branch !== record.branch) {
    throw new Error(
      `Managed worktree Git registration changed: expected branch ${record.branch}, actual ${registered.branch ?? "detached"}.`,
    );
  }
  const pathInfo = await lstat(record.path).catch((error) => {
    if (errorCode(error) === "ENOENT") return undefined;
    throw error;
  });
  if (pathInfo && (!pathInfo.isDirectory() || pathInfo.isSymbolicLink())) {
    throw new Error(`Managed worktree path is not a regular directory: ${record.path}`);
  }
  const present = Boolean(pathInfo);
  if (present) {
    const canonicalPath = await realpath(record.path);
    if (normalizeForComparison(canonicalPath) !== normalizeForComparison(record.path)) {
      throw new Error(`Managed worktree path resolves to a different location: ${record.path}`);
    }
  }
  let head: string | null = registered?.head ?? null;
  let branch: string | null = registered?.branch ?? null;
  let statusText = "";
  if (present && registered) {
    head = await currentHead(record.path);
    branch = await currentBranch(record.path);
    if (branch !== record.branch) {
      throw new Error(`Managed worktree branch identity changed: expected ${record.branch}, actual ${branch ?? "detached"}.`);
    }
    statusText = (await git(record.path, ["status", "--short", "--untracked-files=all"])).stdout.trim();
  }
  const changes = statusText ? statusText.split(/\r?\n/u).filter(Boolean) : [];
  return {
    worktreeId: record.worktreeId,
    profileId: record.profileId,
    repositoryRoot,
    path: record.path,
    branch: branch ?? record.branch,
    baseRef: record.baseRef,
    baseSha: record.baseSha,
    head,
    present,
    registered: Boolean(registered),
    dirty: changes.length > 0,
    changes,
    locked: registered?.locked ?? false,
    prunable: registered?.prunable ?? false,
    branchCreated: record.branchCreated,
    createdAt: record.createdAt,
  } as const;
}

function assertRecordIdentity(
  context: ProjectContext,
  record: WorktreeRecord,
  repositoryRoot: string,
  worktreeId: string,
): void {
  const managedRoot = storageRoot(context);
  const expectedPath = resolve(managedRoot, worktreeId);
  if (
    record.profileId !== context.profile.id ||
    record.worktreeId !== worktreeId ||
    normalizeForComparison(record.repositoryRoot) !== normalizeForComparison(repositoryRoot) ||
    normalizeForComparison(record.path) !== normalizeForComparison(expectedPath) ||
    !isWithinOrEqual(managedRoot, record.path)
  ) {
    throw new Error(`Managed worktree record identity mismatch: ${worktreeId}`);
  }
}

export async function listManagedWorktrees(context: ProjectContext) {
  const repositoryRoot = await assertExactGitRoot(context);
  const entries = await readdir(stateRoot(context), { withFileTypes: true }).catch((error) => {
    if (errorCode(error) === "ENOENT") return [];
    throw error;
  });
  const items = [];
  for (const entry of entries.sort((left, right) => left.name.localeCompare(right.name, "en"))) {
    if (!entry.isFile() || !entry.name.endsWith(".json")) continue;
    const worktreeId = entry.name.slice(0, -5);
    if (!WORKTREE_ID_PATTERN.test(worktreeId)) continue;
    const record = await readRecord(resolve(stateRoot(context), entry.name));
    if (!record) continue;
    assertRecordIdentity(context, record, repositoryRoot, worktreeId);
    items.push(await statusForRecord(repositoryRoot, record));
  }
  return {
    profileId: context.profile.id,
    repositoryRoot,
    items,
  } as const;
}

export async function createManagedWorktree(input: {
  context: ProjectContext;
  branch: string;
  baseRef: string;
}) {
  const repositoryRoot = await assertExactGitRoot(input.context);
  const branch = assertBranch(input.branch);
  const baseRef = assertBaseRef(input.baseRef);
  const worktreeId = worktreeIdFor(repositoryRoot, branch);
  const managedRoot = storageRoot(input.context);
  const path = resolve(managedRoot, worktreeId);
  const statePath = recordPath(input.context, worktreeId);
  await mkdir(managedRoot, { recursive: true });

  const existing = await readRecord(statePath);
  if (existing) {
    assertRecordIdentity(input.context, existing, repositoryRoot, worktreeId);
    if (existing.branch !== branch) throw new Error(`Managed worktree identity collision: ${worktreeId}`);
    const status = await statusForRecord(repositoryRoot, existing);
    if (status.present && status.registered) {
      if (existing.status === "creating") {
        if (status.head !== existing.baseSha) {
          throw new Error(`Managed worktree creation recovery found an unexpected HEAD: ${worktreeId}`);
        }
        await writeJsonAtomic(statePath, { ...existing, status: "active" });
      }
      return { ...status, recovered: true } as const;
    }
    throw new Error(`Managed worktree creation is incomplete and requires manual inspection: ${worktreeId}`);
  }

  return await withGitLease(input.context, repositoryRoot, async () => {
    await git(repositoryRoot, ["check-ref-format", "--branch", branch]);
    const registrations = await listedWorktrees(repositoryRoot);
    const branchRegistration = registrations.find((item) => item.branch === branch);
    if (branchRegistration) {
      throw new Error(`Branch is already checked out in another worktree: ${branch} (${branchRegistration.path})`);
    }
    if (await lstat(path).catch(() => undefined)) {
      throw new Error(`Managed worktree path already exists and was not changed: ${path}`);
    }

    const existingBranch = await branchExists(repositoryRoot, branch);
    const baseSha = existingBranch
      ? await resolveCommit(repositoryRoot, `refs/heads/${branch}`)
      : await resolveCommit(repositoryRoot, baseRef);
    const record: WorktreeRecord = {
      version: 1,
      status: "creating",
      worktreeId,
      profileId: input.context.profile.id,
      repositoryRoot,
      path,
      branch,
      baseRef,
      baseSha,
      branchCreated: !existingBranch,
      createdAt: new Date().toISOString(),
    };
    await writeJsonAtomic(statePath, record, true);
    try {
      const args = existingBranch
        ? ["worktree", "add", path, branch]
        : ["worktree", "add", "--no-track", "-b", branch, path, baseSha];
      await git(repositoryRoot, args, 120_000);
      const active: WorktreeRecord = { ...record, status: "active" };
      await writeJsonAtomic(statePath, active);
      return { ...(await statusForRecord(repositoryRoot, active)), recovered: false } as const;
    } catch (error) {
      const registered = (await listedWorktrees(repositoryRoot).catch(() => [] as PorcelainWorktree[])).find(
        (item) => normalizeForComparison(item.path) === normalizeForComparison(path),
      );
      if (registered?.branch === branch && registered.head === baseSha) {
        const cleanupStatus = await git(path, ["status", "--short", "--untracked-files=all"]).catch(() => undefined);
        if (cleanupStatus?.stdout.trim() === "") {
          await git(repositoryRoot, ["worktree", "remove", "--force", path], 120_000).catch(() => undefined);
        }
      }
      const [remainingPath, remainingRegistration] = await Promise.all([
        lstat(path).catch(() => undefined),
        listedWorktrees(repositoryRoot)
          .then((items) => items.find((item) => normalizeForComparison(item.path) === normalizeForComparison(path)))
          .catch(() => undefined),
      ]);
      if (remainingPath || remainingRegistration) {
        throw new Error(
          `WORKTREE_CREATE_CLEANUP_UNCERTAIN: ${worktreeId} requires manual inspection at ${path}; original=${errorMessage(error)}`,
        );
      }
      await rm(statePath, { force: true }).catch(() => undefined);
      throw error;
    }
  });
}

export async function removeManagedWorktree(input: {
  context: ProjectContext;
  worktreeId: string;
}) {
  const repositoryRoot = await assertExactGitRoot(input.context);
  const worktreeId = assertWorktreeId(input.worktreeId);
  const statePath = recordPath(input.context, worktreeId);
  const record = await readRecord(statePath);
  if (!record) throw new Error(`Unknown managed worktree: ${worktreeId}`);
  assertRecordIdentity(input.context, record, repositoryRoot, worktreeId);

  return await withGitLease(input.context, repositoryRoot, async () => {
    const status = await statusForRecord(repositoryRoot, record);
    if (!status.present || !status.registered || !status.head) {
      throw new Error(`Managed worktree is not in a removable active state: ${worktreeId}`);
    }
    if (status.dirty) throw new Error(`Managed worktree has local changes and was not removed: ${worktreeId}`);
    const verifiedHead = await currentHead(record.path);
    const verifiedBranch = await currentBranch(record.path);
    if (verifiedHead !== status.head || verifiedBranch !== record.branch) {
      throw new Error(`Managed worktree identity changed during removal: ${worktreeId}`);
    }
    await git(repositoryRoot, ["worktree", "remove", record.path], 120_000);
    await rm(statePath, { force: true });
    return {
      worktreeId,
      profileId: input.context.profile.id,
      repositoryRoot,
      path: record.path,
      branch: record.branch,
      head: verifiedHead,
      removed: true,
      branchPreserved: true,
    } as const;
  });
}
