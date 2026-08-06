import { createHash, randomUUID } from "node:crypto";
import { copyFile, lstat, mkdir, readFile, realpath, rename, rm, stat, writeFile } from "node:fs/promises";
import { basename, dirname, isAbsolute, relative, resolve } from "node:path";
import type { ProjectContext } from "./profile.js";
import { makeWorkstationEnvironment, runProcess } from "./process.js";
import { isProtectedWorkstationPath, resolveAuthorizedWorkstationPath } from "./workstation.js";

const MAX_PATCH_BYTES = 4 * 1024 * 1024;
const MAX_FILE_BYTES = 16 * 1024 * 1024;
const MAX_FILES = 100;
const SHA256_PATTERN = /^[a-f0-9]{64}$/u;

type PatchAction = "add" | "update" | "delete";

export interface PatchExpectation {
  readonly path: string;
  readonly expectedSha256: string;
}

interface ParsedPatchFile {
  readonly path: string;
  readonly action: PatchAction;
  additions: number;
  deletions: number;
}

interface BaselineFile {
  readonly relativePath: string;
  readonly requestedPath: string;
  readonly actualPath: string;
  readonly action: PatchAction;
  readonly expectedSha256: string;
  readonly existed: boolean;
  readonly beforeSha256: string | null;
  readonly additions: number;
  readonly deletions: number;
}

function sha256(bytes: Buffer): string {
  return createHash("sha256").update(bytes).digest("hex");
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

function normalizeForComparison(path: string): string {
  return process.platform === "win32" ? path.toLocaleLowerCase("en-US") : path;
}

function isWithinOrEqual(root: string, candidate: string): boolean {
  const relationship = relative(normalizeForComparison(root), normalizeForComparison(candidate));
  return relationship === "" || (!relationship.startsWith("..") && !isAbsolute(relationship));
}

function normalizeRelativePath(rawPath: string): string {
  const normalized = rawPath.replaceAll("\\", "/");
  if (
    rawPath.trim() !== rawPath ||
    normalized.length === 0 ||
    normalized.includes("\0") ||
    isAbsolute(rawPath) ||
    /^[A-Za-z]:/u.test(rawPath) ||
    normalized.startsWith("/")
  ) {
    throw new Error(`Patch path must be a normalized workspace-relative path: ${rawPath}`);
  }
  const segments = normalized.split("/");
  if (segments.some((segment) => !segment || segment === "." || segment === "..")) {
    throw new Error(`Patch path must be a normalized workspace-relative path: ${rawPath}`);
  }
  if (segments[0]?.toLocaleLowerCase("en-US") === ".git") {
    throw new Error(`Patch paths cannot target Git metadata: ${rawPath}`);
  }
  return segments.join("/");
}

function parseHeaderPath(value: string): string | null {
  const raw = value.split("\t", 1)[0]!.trim();
  if (raw === "/dev/null") return null;
  const withoutPrefix = raw.startsWith("a/") || raw.startsWith("b/") ? raw.slice(2) : raw;
  return normalizeRelativePath(withoutPrefix);
}

function parsePatch(patch: string): ParsedPatchFile[] {
  const bytes = Buffer.byteLength(patch, "utf8");
  if (bytes < 1 || bytes > MAX_PATCH_BYTES) {
    throw new Error(`patch must contain between 1 and ${MAX_PATCH_BYTES} UTF-8 bytes.`);
  }
  if (patch.includes("\0")) throw new Error("Binary patches are not supported.");
  if (/^(?:GIT binary patch|Binary files |rename from |rename to |copy from |copy to |old mode |new mode )/mu.test(patch)) {
    throw new Error("Binary, rename, copy, and standalone mode-change patches are not supported.");
  }

  const lines = patch.replaceAll("\r\n", "\n").replaceAll("\r", "\n").split("\n");
  for (const line of lines) {
    const mode = /^(?:new file mode|deleted file mode) ([0-9]{6})$/u.exec(line)?.[1];
    if (mode !== undefined && mode !== "100644" && mode !== "100755") {
      throw new Error(`Only regular text-file Git modes are supported: ${line}`);
    }
  }
  const files: ParsedPatchFile[] = [];
  let current: ParsedPatchFile | undefined;

  for (let index = 0; index < lines.length; index += 1) {
    const line = lines[index]!;
    if (line.startsWith("--- ")) {
      const next = lines[index + 1];
      if (!next?.startsWith("+++ ")) throw new Error("Every --- patch header must be followed by a +++ header.");
      const source = parseHeaderPath(line.slice(4));
      const destination = parseHeaderPath(next.slice(4));
      if (source === null && destination === null) throw new Error("Patch file headers cannot both be /dev/null.");
      if (source !== null && destination !== null && source !== destination) {
        throw new Error(`Patch renames are not supported: ${source} -> ${destination}`);
      }
      const path = destination ?? source!;
      const action: PatchAction = source === null ? "add" : destination === null ? "delete" : "update";
      if (files.some((item) => normalizeForComparison(item.path) === normalizeForComparison(path))) {
        throw new Error(`Patch contains duplicate file headers: ${path}`);
      }
      current = { path, action, additions: 0, deletions: 0 };
      files.push(current);
      index += 1;
      continue;
    }
    if (!current) continue;
    if (line.startsWith("+++ ") || line.startsWith("--- ") || line.startsWith("@@")) continue;
    if (line.startsWith("+") && !line.startsWith("+++")) current.additions += 1;
    if (line.startsWith("-") && !line.startsWith("---")) current.deletions += 1;
  }

  if (files.length < 1) throw new Error("Patch contains no supported text file headers.");
  if (files.length > MAX_FILES) throw new Error(`Patch touches more than ${MAX_FILES} files.`);
  return files;
}

async function assertNoLinkTraversal(root: string, target: string): Promise<void> {
  const relationship = relative(root, target);
  if (relationship.startsWith("..") || isAbsolute(relationship)) {
    throw new Error(`Patch target escapes the selected root: ${target}`);
  }
  let current = root;
  const segments = relationship.split(/[\\/]/u).filter(Boolean);
  for (let index = 0; index < segments.length; index += 1) {
    current = resolve(current, segments[index]!);
    const info = await lstat(current).catch((error) => {
      if (errorCode(error) === "ENOENT") return undefined;
      throw error;
    });
    if (!info) break;
    if (info.isSymbolicLink()) throw new Error(`Patch paths cannot traverse symlinks or junctions: ${current}`);
  }
}

async function readRegularTextFile(path: string): Promise<{ sha256: string }> {
  const info = await lstat(path);
  if (!info.isFile() || info.isSymbolicLink()) throw new Error(`Patch target is not a regular file: ${path}`);
  if (info.nlink > 1) throw new Error(`Hardlinked text mutation is not supported: ${path}`);
  if (info.size > MAX_FILE_BYTES) throw new Error(`Patch target exceeds the ${MAX_FILE_BYTES}-byte limit: ${path}`);
  const bytes = await readFile(path);
  new TextDecoder("utf-8", { fatal: true }).decode(bytes);
  return { sha256: sha256(bytes) };
}

interface FileLeaseOwner {
  readonly version: 1;
  readonly operationId: string;
  readonly processId: number;
  readonly targetPath: string;
  readonly createdAt: string;
}

async function withTargetWriteLease<T>(
  context: ProjectContext,
  targetPath: string,
  operation: () => Promise<T>,
): Promise<T> {
  const leaseRoot = resolve(context.engineRoot, "runtime", "file-leases");
  const normalizedTarget = normalizeForComparison(targetPath);
  const leasePath = resolve(leaseRoot, sha256(Buffer.from(normalizedTarget, "utf8")));
  const ownerPath = resolve(leasePath, "owner.json");
  await mkdir(leaseRoot, { recursive: true });

  let acquired = false;
  for (let attempt = 0; attempt < 3 && !acquired; attempt += 1) {
    try {
      await mkdir(leasePath);
      acquired = true;
    } catch (error) {
      if (errorCode(error) !== "EEXIST") throw error;
      const owner = await readFile(ownerPath, "utf8")
        .then((text): FileLeaseOwner | null => JSON.parse(text) as FileLeaseOwner)
        .catch(() => null);
      if (owner && Number.isInteger(owner.processId) && owner.processId > 0 && processIsAlive(owner.processId)) {
        throw new Error(
          `FILE_WRITE_LEASE_BUSY: target is being updated by operation ${owner.operationId} in process ${owner.processId}: ${targetPath}`,
        );
      }
      const leaseInfo = await stat(leasePath).catch(() => undefined);
      if (!owner && (!leaseInfo || Date.now() - leaseInfo.mtimeMs < 30_000)) {
        throw new Error(`FILE_WRITE_LEASE_UNCERTAIN: target lease owner is not yet verifiable: ${targetPath}`);
      }
      const stalePath = `${leasePath}.stale-${randomUUID()}`;
      try {
        await rename(leasePath, stalePath);
        await rm(stalePath, { recursive: true, force: true });
      } catch (renameError) {
        if (errorCode(renameError) !== "ENOENT") throw renameError;
      }
    }
  }
  if (!acquired) throw new Error(`FILE_WRITE_LEASE_BUSY: could not acquire target lease: ${targetPath}`);

  const owner: FileLeaseOwner = {
    version: 1,
    operationId: randomUUID(),
    processId: process.pid,
    targetPath,
    createdAt: new Date().toISOString(),
  };
  try {
    await writeFile(ownerPath, `${JSON.stringify(owner)}\n`, { encoding: "utf8", flag: "wx", mode: 0o600 });
    return await operation();
  } finally {
    await rm(leasePath, { recursive: true, force: true }).catch(() => undefined);
  }
}

async function withTargetWriteLeases<T>(
  context: ProjectContext,
  targets: readonly string[],
  operation: () => Promise<T>,
): Promise<T> {
  const ordered = [...new Set(targets.map((target) => resolve(target)))].sort((left, right) => (
    normalizeForComparison(left).localeCompare(normalizeForComparison(right), "en")
  ));
  const acquire = async (index: number): Promise<T> => {
    const target = ordered[index];
    if (target === undefined) return await operation();
    return await withTargetWriteLease(context, target, async () => await acquire(index + 1));
  };
  return await acquire(0);
}

async function gitApply(root: string, patchPath: string, checkOnly: boolean) {
  const args = ["-C", root, "apply", "--whitespace=error-all", "--recount"];
  if (checkOnly) args.push("--check");
  args.push("--", patchPath);
  const result = await runProcess("git.exe", args, {
    cwd: root,
    timeoutMs: 120_000,
    maxStdoutBytes: 1024 * 1024,
    maxStderrBytes: 1024 * 1024,
    env: makeWorkstationEnvironment({ GIT_TERMINAL_PROMPT: "0" }),
  });
  if (result.timedOut) throw new Error("git apply timed out.");
  if (result.exitCode !== 0) throw new Error((result.stderr || result.stdout).trim() || `git apply exited with ${result.exitCode}.`);
}

async function assertGitWorkspaceRoot(root: string): Promise<void> {
  const result = await runProcess("git.exe", ["-C", root, "rev-parse", "--show-toplevel"], {
    cwd: root,
    timeoutMs: 30_000,
    maxStdoutBytes: 64 * 1024,
    maxStderrBytes: 64 * 1024,
    env: makeWorkstationEnvironment({ GIT_TERMINAL_PROMPT: "0" }),
  });
  if (result.exitCode !== 0) throw new Error("apply_patch requires an existing Git workspace root.");
  const discovered = await realpath(result.stdout.trim());
  if (normalizeForComparison(discovered) !== normalizeForComparison(root)) {
    throw new Error(`apply_patch root must be the Git workspace root: ${discovered}`);
  }
}

async function loadBaseline(
  context: ProjectContext,
  root: string,
  parsed: ParsedPatchFile,
  expectation: PatchExpectation,
): Promise<BaselineFile> {
  const requestedPath = resolve(root, parsed.path);
  if (!isWithinOrEqual(root, requestedPath)) throw new Error(`Patch target escapes the selected root: ${parsed.path}`);
  if (isProtectedWorkstationPath(context, requestedPath)) {
    throw new Error(`Protected credential or browser-profile path denied: ${requestedPath}`);
  }
  await assertNoLinkTraversal(root, requestedPath);
  const existing = await lstat(requestedPath).catch((error) => {
    if (errorCode(error) === "ENOENT") return undefined;
    throw error;
  });

  if (expectation.expectedSha256 === "absent") {
    if (parsed.action !== "add") throw new Error(`Only add patches may use expectedSha256='absent': ${parsed.path}`);
    if (existing) throw new Error(`Patch target already exists: ${parsed.path}`);
    const parent = await realpath(dirname(requestedPath)).catch(() => undefined);
    if (!parent || !isWithinOrEqual(root, parent)) throw new Error(`Patch target parent must already exist inside the root: ${parsed.path}`);
    return {
      relativePath: parsed.path,
      requestedPath,
      actualPath: resolve(parent, basename(requestedPath)),
      action: parsed.action,
      expectedSha256: expectation.expectedSha256,
      existed: false,
      beforeSha256: null,
      additions: parsed.additions,
      deletions: parsed.deletions,
    };
  }

  if (!SHA256_PATTERN.test(expectation.expectedSha256)) {
    throw new Error(`expectedSha256 must be 'absent' or a lowercase SHA-256 hash: ${parsed.path}`);
  }
  if (parsed.action === "add") throw new Error(`Add patches must use expectedSha256='absent': ${parsed.path}`);
  if (!existing) throw new Error(`Patch target does not exist: ${parsed.path}`);
  const actualPath = await realpath(requestedPath);
  if (!isWithinOrEqual(root, actualPath)) throw new Error(`Patch target resolves outside the selected root: ${parsed.path}`);
  const current = await readRegularTextFile(actualPath);
  if (current.sha256 !== expectation.expectedSha256) {
    throw new Error(`Patch baseline changed for ${parsed.path}; no changes were applied.`);
  }
  return {
    relativePath: parsed.path,
    requestedPath,
    actualPath,
    action: parsed.action,
    expectedSha256: expectation.expectedSha256,
    existed: true,
    beforeSha256: current.sha256,
    additions: parsed.additions,
    deletions: parsed.deletions,
  };
}

async function revalidateBaseline(file: BaselineFile): Promise<void> {
  const info = await lstat(file.requestedPath).catch((error) => {
    if (errorCode(error) === "ENOENT") return undefined;
    throw error;
  });
  if (file.expectedSha256 === "absent") {
    if (info) throw new Error(`Patch target appeared after validation: ${file.relativePath}`);
    return;
  }
  if (!info) throw new Error(`Patch target disappeared after validation: ${file.relativePath}`);
  const current = await readRegularTextFile(file.actualPath);
  if (current.sha256 !== file.expectedSha256) {
    throw new Error(`Patch baseline changed for ${file.relativePath}; no changes were applied.`);
  }
}

async function restoreBaseline(files: readonly BaselineFile[], backupRoot: string): Promise<void> {
  for (const file of [...files].reverse()) {
    if (!file.existed) {
      await rm(file.requestedPath, { force: true });
      continue;
    }
    const backup = resolve(backupRoot, file.relativePath);
    await mkdir(dirname(file.requestedPath), { recursive: true });
    await copyFile(backup, file.requestedPath);
  }
}

function errorMessage(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}

async function restoreOrThrow(
  files: readonly BaselineFile[],
  backupRoot: string,
  originalError: unknown,
): Promise<void> {
  try {
    await restoreBaseline(files, backupRoot);
  } catch (rollbackError) {
    throw new Error(
      `PATCH_ROLLBACK_INCOMPLETE: original=${errorMessage(originalError)}; rollback=${errorMessage(rollbackError)}`,
    );
  }
}

export async function applyPatch(input: {
  context: ProjectContext;
  root: string;
  patch: string;
  expectedFiles: readonly PatchExpectation[];
}) {
  const parsedFiles = parsePatch(input.patch);
  if (input.expectedFiles.length !== parsedFiles.length) {
    throw new Error("expectedFiles must contain exactly one entry for every file header in the patch.");
  }
  const expectationMap = new Map<string, PatchExpectation>();
  for (const expectation of input.expectedFiles) {
    const path = normalizeRelativePath(expectation.path);
    const key = normalizeForComparison(path);
    if (expectationMap.has(key)) throw new Error(`expectedFiles contains a duplicate path: ${path}`);
    expectationMap.set(key, { path, expectedSha256: expectation.expectedSha256 });
  }
  for (const file of parsedFiles) {
    if (!expectationMap.has(normalizeForComparison(file.path))) {
      throw new Error(`expectedFiles is missing the patch path: ${file.path}`);
    }
  }

  const authorizedRoot = await resolveAuthorizedWorkstationPath(input.context, input.root, "tree");
  const rootInfo = await stat(authorizedRoot);
  if (!rootInfo.isDirectory()) throw new Error(`apply_patch root is not a directory: ${authorizedRoot}`);
  const root = await realpath(authorizedRoot);
  await assertGitWorkspaceRoot(root);

  const baselines: BaselineFile[] = [];
  for (const file of parsedFiles) {
    const expectation = expectationMap.get(normalizeForComparison(file.path))!;
    baselines.push(await loadBaseline(input.context, root, file, expectation));
  }

  const transactionId = randomUUID();
  const transactionRoot = resolve(input.context.engineRoot, "runtime", "patch-transactions", transactionId);
  const backupRoot = resolve(transactionRoot, "backup");
  const patchPath = resolve(transactionRoot, "change.patch");
  await mkdir(backupRoot, { recursive: true });
  await writeFile(patchPath, input.patch, { encoding: "utf8", flag: "wx", mode: 0o600 });

  try {
    return await withTargetWriteLeases(input.context, baselines.map((file) => file.actualPath), async () => {
      for (const file of baselines) await revalidateBaseline(file);
      for (const file of baselines) {
        if (!file.existed) continue;
        const backup = resolve(backupRoot, file.relativePath);
        await mkdir(dirname(backup), { recursive: true });
        await copyFile(file.actualPath, backup);
      }

      await gitApply(root, patchPath, true);
      for (const file of baselines) await revalidateBaseline(file);

      try {
        await gitApply(root, patchPath, false);
      } catch (error) {
        await restoreOrThrow(baselines, backupRoot, error);
        throw error;
      }

      const files = [];
      try {
        for (const file of baselines) {
          const info = await lstat(file.requestedPath).catch((error) => {
            if (errorCode(error) === "ENOENT") return undefined;
            throw error;
          });
          if (file.action === "delete") {
            if (info) throw new Error(`Patch did not delete the expected file: ${file.relativePath}`);
            files.push({
              path: file.relativePath,
              action: file.action,
              previousSha256: file.beforeSha256,
              sha256: null,
              additions: file.additions,
              deletions: file.deletions,
            });
            continue;
          }
          if (!info) throw new Error(`Patch did not produce the expected file: ${file.relativePath}`);
          const current = await readRegularTextFile(file.requestedPath);
          files.push({
            path: file.relativePath,
            action: file.action,
            previousSha256: file.beforeSha256,
            sha256: current.sha256,
            additions: file.additions,
            deletions: file.deletions,
          });
        }
      } catch (error) {
        await restoreOrThrow(baselines, backupRoot, error);
        throw error;
      }

      return {
        transactionId,
        root,
        files,
        additions: files.reduce((sum, file) => sum + file.additions, 0),
        deletions: files.reduce((sum, file) => sum + file.deletions, 0),
      } as const;
    });
  } finally {
    await rm(transactionRoot, { recursive: true, force: true }).catch(() => undefined);
  }
}
