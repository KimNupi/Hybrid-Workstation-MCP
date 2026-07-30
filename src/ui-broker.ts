import { createHash, randomUUID } from "node:crypto";
import { lstat, mkdtemp, readFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, isAbsolute, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { z } from "zod";
import { verifiedWorkstationNativeHelper } from "./native-helper.js";
import type { ProjectContext } from "./profile.js";
import { makeSafeEnvironment, resolvePowerShellExecutable, runProcess } from "./process.js";

const MODULE_DIRECTORY = dirname(fileURLToPath(import.meta.url));
const WINDOW_OBSERVER = resolve(MODULE_DIRECTORY, "..", "scripts", "window-observer.ps1");
const GRANTS_ENVIRONMENT_KEY = "CHATGPT_HYBRID_UI_GRANTS_PATH";
const MAX_GRANTS_BYTES = 1024 * 1024;
const MAX_CAPTURE_BYTES = 32 * 1024 * 1024;
const WINDOW_REF_PATTERN = /^window:[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/u;
const TRUSTED_APP_REF_PATTERN = /^trusted-app:[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/u;

const identitySchema = z.object({
  windowHandle: z.string().regex(/^[1-9][0-9]{0,19}$/u),
  processId: z.number().int().positive(),
  processStartedAt: z.iso.datetime({ offset: true }),
  executablePath: z.string().min(1).max(32_768),
}).strict();
const grantSchema = z.object({
  profileId: z.string().regex(/^[a-z0-9][a-z0-9-]{0,31}$/u),
  ref: z.string().regex(WINDOW_REF_PATTERN),
  label: z.string().trim().min(1).max(1200),
  createdAt: z.iso.datetime({ offset: true }),
  identity: identitySchema,
}).strict();
const trustedAppSchema = z.object({
  profileId: z.string().regex(/^[a-z0-9][a-z0-9-]{0,31}$/u),
  ref: z.string().regex(TRUSTED_APP_REF_PATTERN),
  label: z.string().trim().min(1).max(1200),
  createdAt: z.iso.datetime({ offset: true }),
  executablePath: z.string().trim().min(1).max(32_768),
  titleContains: z.string().trim().min(2).max(200),
}).strict();
const storeV1Schema = z.object({ version: z.literal(1), grants: z.array(grantSchema).max(128) }).strict();
const storeV2Schema = z.object({
  version: z.literal(2),
  grants: z.array(grantSchema).max(128),
  trustedApps: z.array(trustedAppSchema).max(128),
}).strict();
const storeSchema = z.union([storeV1Schema, storeV2Schema]);
const observedSchema = identitySchema.extend({
  processName: z.string().max(1024),
  title: z.string().max(4096),
  left: z.number().int(),
  top: z.number().int(),
  width: z.number().int().min(1).max(16384),
  height: z.number().int().min(1).max(16384),
  minimized: z.boolean(),
}).strict();
const nativeResultSchema = z.object({
  ok: z.literal(true),
  backend: z.literal("windows_graphics_capture"),
  width: z.number().int().positive(),
  height: z.number().int().positive(),
}).strict();

type Grant = z.infer<typeof grantSchema>;
type TrustedApp = z.infer<typeof trustedAppSchema>;
type Observed = z.infer<typeof observedSchema>;
interface Store {
  version: 2;
  grants: Grant[];
  trustedApps: TrustedApp[];
}
interface AutoBinding {
  identityKey: string;
  grant: Grant;
}
interface TrustedMatch {
  profileId: string;
  rule: TrustedApp;
  window: Observed;
}

const autoBindings = new Map<string, AutoBinding>();

function grantsPath(context: ProjectContext): string {
  const configured = process.env[GRANTS_ENVIRONMENT_KEY];
  if (configured && !isAbsolute(configured)) throw new Error(`${GRANTS_ENVIRONMENT_KEY} must be absolute.`);
  return resolve(configured ?? resolve(context.engineRoot, "runtime", "ui_grants.json"));
}

function normalizeStore(value: unknown): Store {
  const parsed = storeSchema.parse(value);
  return parsed.version === 1
    ? { version: 2, grants: [...parsed.grants], trustedApps: [] }
    : { version: 2, grants: [...parsed.grants], trustedApps: [...parsed.trustedApps] };
}

async function loadStore(context: ProjectContext): Promise<{ configured: boolean; value: Store }> {
  const path = grantsPath(context);
  const info = await lstat(path).catch((error: NodeJS.ErrnoException) => {
    if (error.code === "ENOENT") return undefined;
    throw error;
  });
  if (!info) return { configured: false, value: { version: 2, grants: [], trustedApps: [] } };
  if (!info.isFile() || info.isSymbolicLink() || info.nlink > 1 || info.size > MAX_GRANTS_BYTES) {
    throw new Error("Window grant store is unsafe.");
  }
  const decoded = new TextDecoder("utf-8", { fatal: true }).decode(await readFile(path));
  return { configured: true, value: normalizeStore(JSON.parse(decoded) as unknown) };
}

async function runObserver(args: readonly string[], timeoutMs = 8_000): Promise<unknown> {
  if (process.platform !== "win32") throw new Error("Window observation is available only on Windows.");
  const result = await runProcess(resolvePowerShellExecutable(), [
    "-NoLogo", "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File", WINDOW_OBSERVER, ...args,
  ], {
    cwd: resolve(MODULE_DIRECTORY, ".."), timeoutMs, maxStdoutBytes: 2 * 1024 * 1024,
    maxStderrBytes: 256 * 1024, env: makeSafeEnvironment(),
  });
  if (result.timedOut) throw new Error("Window observer timed out.");
  if (result.exitCode !== 0) throw new Error(result.stderr.trim() || `Window observer exited with ${result.exitCode}.`);
  return JSON.parse(result.stdout) as unknown;
}

async function observeWindows(): Promise<readonly Observed[]> {
  return z.object({ windows: z.array(observedSchema).max(512) }).strict().parse(await runObserver(["-Action", "list"])).windows;
}

function normalizeComparison(value: string): string {
  return value.toLocaleLowerCase("en-US");
}

function sameIdentity(grant: Grant, observed: Observed): boolean {
  return grant.identity.windowHandle === observed.windowHandle
    && grant.identity.processId === observed.processId
    && grant.identity.processStartedAt === observed.processStartedAt
    && normalizeComparison(grant.identity.executablePath) === normalizeComparison(observed.executablePath);
}

function observedIdentityKey(observed: Observed): string {
  return [
    observed.windowHandle,
    String(observed.processId),
    observed.processStartedAt,
    normalizeComparison(observed.executablePath),
  ].join("\u0000");
}

function publicWindow(grant: Grant, observed: Observed) {
  return {
    windowRef: grant.ref,
    label: grant.label,
    title: observed.title,
    processName: observed.processName,
    bounds: { left: observed.left, top: observed.top, width: observed.width, height: observed.height },
    minimized: observed.minimized,
  } as const;
}

function resolveTrustedCandidates(store: Store, observed: readonly Observed[], profileId: string) {
  const exactCandidates: TrustedMatch[] = [];
  const candidateCounts = new Map<string, number>();
  const ownersByIdentity = new Map<string, TrustedMatch[]>();

  for (const rule of store.trustedApps) {
    const matching = observed.filter((window) => (
      normalizeComparison(window.executablePath) === normalizeComparison(rule.executablePath)
      && normalizeComparison(window.title).includes(normalizeComparison(rule.titleContains))
    ));
    candidateCounts.set(`${rule.profileId}\u0000${rule.ref}`, matching.length);
    for (const window of matching) {
      const key = observedIdentityKey(window);
      const owners = ownersByIdentity.get(key) ?? [];
      owners.push({ profileId: rule.profileId, rule, window });
      ownersByIdentity.set(key, owners);
    }
    if (matching.length === 1) exactCandidates.push({ profileId: rule.profileId, rule, window: matching[0]! });
  }

  const currentRules = store.trustedApps.filter((rule) => rule.profileId === profileId);
  const matches = exactCandidates.filter((match) => (
    match.profileId === profileId
    && ownersByIdentity.get(observedIdentityKey(match.window))?.length === 1
  ));
  let unmatchedCount = 0;
  let ambiguousCount = 0;
  let collisionCount = 0;
  for (const rule of currentRules) {
    const count = candidateCounts.get(`${profileId}\u0000${rule.ref}`) ?? 0;
    if (count === 0) unmatchedCount += 1;
    else if (count > 1) ambiguousCount += 1;
    else {
      const exact = exactCandidates.find((match) => match.profileId === profileId && match.rule.ref === rule.ref);
      if (exact && (ownersByIdentity.get(observedIdentityKey(exact.window))?.length ?? 0) > 1) collisionCount += 1;
    }
  }
  return {
    trustedRuleCount: currentRules.length,
    autoBoundCount: matches.length,
    autoUnmatchedCount: unmatchedCount,
    autoAmbiguousCount: ambiguousCount,
    autoCollisionCount: collisionCount,
    matches,
  };
}

export function resolveTrustedWindowRuleCandidates(storeValue: unknown, observedValue: unknown, profileId: string) {
  return resolveTrustedCandidates(
    normalizeStore(storeValue),
    z.array(observedSchema).max(512).parse(observedValue),
    profileId,
  );
}

function autoBindingKey(profileId: string, ruleRef: string): string {
  return `${profileId}\u0000${ruleRef}`;
}

function clearAutoBindings(profileId: string): void {
  const prefix = `${profileId}\u0000`;
  for (const key of autoBindings.keys()) {
    if (key.startsWith(prefix)) autoBindings.delete(key);
  }
}

function resolveAutoGrants(store: Store, observed: readonly Observed[], profileId: string) {
  const automatic = resolveTrustedCandidates(store, observed, profileId);
  const grants: Grant[] = [];
  const activeKeys = new Set<string>();
  for (const match of automatic.matches) {
    const key = autoBindingKey(profileId, match.rule.ref);
    activeKeys.add(key);
    const identityKey = observedIdentityKey(match.window);
    const existing = autoBindings.get(key);
    if (existing?.identityKey === identityKey) {
      grants.push(existing.grant);
      continue;
    }
    const grant: Grant = {
      profileId,
      ref: `window:${randomUUID()}`,
      label: match.rule.label,
      createdAt: new Date().toISOString(),
      identity: {
        windowHandle: match.window.windowHandle,
        processId: match.window.processId,
        processStartedAt: match.window.processStartedAt,
        executablePath: match.window.executablePath,
      },
    };
    autoBindings.set(key, { identityKey, grant });
    grants.push(grant);
  }
  const prefix = `${profileId}\u0000`;
  for (const key of autoBindings.keys()) {
    if (key.startsWith(prefix) && !activeKeys.has(key)) autoBindings.delete(key);
  }
  return { ...automatic, grants };
}

export function resolveGrantedWindowList(storeValue: unknown, observedValue: unknown, profileId: string) {
  const store = normalizeStore(storeValue);
  const observed = z.array(observedSchema).max(512).parse(observedValue);
  const grants = store.grants.filter((grant) => grant.profileId === profileId);
  const windows = [] as ReturnType<typeof publicWindow>[];
  let unavailableCount = 0;
  for (const grant of grants) {
    const match = observed.find((candidate) => sameIdentity(grant, candidate));
    if (match) windows.push(publicWindow(grant, match));
    else unavailableCount += 1;
  }
  return { windows, unavailableCount };
}

export async function listGrantedWindows(context: ProjectContext) {
  const store = await loadStore(context);
  const manualGrants = store.value.grants.filter((grant) => grant.profileId === context.profile.id);
  const trustedRules = store.value.trustedApps.filter((rule) => rule.profileId === context.profile.id);
  if (manualGrants.length === 0 && trustedRules.length === 0) {
    clearAutoBindings(context.profile.id);
    return {
      configured: store.configured,
      windows: [],
      unavailableCount: 0,
      trustedRuleCount: 0,
      autoBoundCount: 0,
      autoUnmatchedCount: 0,
      autoAmbiguousCount: 0,
      autoCollisionCount: 0,
    };
  }

  const observed = await observeWindows();
  const automatic = resolveAutoGrants(store.value, observed, context.profile.id);
  const grants = [...manualGrants, ...automatic.grants];
  const manualRefs = new Set(manualGrants.map((grant) => grant.ref));
  const identities = new Set<string>();
  const windows = [] as ReturnType<typeof publicWindow>[];
  let unavailableCount = 0;
  for (const grant of grants) {
    const match = observed.find((candidate) => sameIdentity(grant, candidate));
    if (!match) {
      if (manualRefs.has(grant.ref)) unavailableCount += 1;
      continue;
    }
    const identityKey = observedIdentityKey(match);
    if (identities.has(identityKey)) continue;
    identities.add(identityKey);
    windows.push(publicWindow(grant, match));
  }
  return {
    configured: store.configured,
    windows,
    unavailableCount,
    trustedRuleCount: automatic.trustedRuleCount,
    autoBoundCount: automatic.autoBoundCount,
    autoUnmatchedCount: automatic.autoUnmatchedCount,
    autoAmbiguousCount: automatic.autoAmbiguousCount,
    autoCollisionCount: automatic.autoCollisionCount,
  };
}

async function requireGrant(context: ProjectContext, windowRef: string): Promise<Grant> {
  if (!WINDOW_REF_PATTERN.test(windowRef)) throw new Error("windowRef is invalid.");
  const store = await loadStore(context);
  const manual = store.value.grants.filter((grant) => grant.profileId === context.profile.id && grant.ref === windowRef);
  if (manual.length === 1) return manual[0]!;
  const rules = store.value.trustedApps.filter((rule) => rule.profileId === context.profile.id);
  if (rules.length > 0) {
    const automatic = resolveAutoGrants(store.value, await observeWindows(), context.profile.id);
    const matches = automatic.grants.filter((grant) => grant.ref === windowRef);
    if (matches.length === 1) return matches[0]!;
  } else {
    clearAutoBindings(context.profile.id);
  }
  throw new Error("The requested window is not granted or uniquely auto-bound to this profile.");
}

function identityArguments(grant: Grant): string[] {
  return [
    "--window-handle", grant.identity.windowHandle,
    "--expected-pid", String(grant.identity.processId),
    "--expected-start", grant.identity.processStartedAt,
    "--expected-exe", grant.identity.executablePath,
  ];
}

async function captureWithNative(helper: string, grant: Grant, outputPath: string): Promise<void> {
  const result = await runProcess(helper, ["capture", ...identityArguments(grant), "--output", outputPath], {
    cwd: resolve(MODULE_DIRECTORY, ".."), timeoutMs: 12_000, maxStdoutBytes: 64 * 1024,
    maxStderrBytes: 64 * 1024, env: makeSafeEnvironment(),
  });
  if (result.timedOut || result.exitCode !== 0) throw new Error(result.stderr.trim() || "Windows Graphics Capture failed.");
  nativeResultSchema.parse(JSON.parse(result.stdout) as unknown);
}

export async function captureGrantedWindow(context: ProjectContext, windowRef: string) {
  const grant = await requireGrant(context, windowRef);
  const before = (await observeWindows()).find((candidate) => sameIdentity(grant, candidate));
  if (!before) throw new Error("The granted window is unavailable or its process identity changed.");
  if (before.minimized) throw new Error("Restore the granted window before capturing it.");
  const temporaryRoot = await mkdtemp(join(tmpdir(), "hybrid-window-capture-"));
  const outputPath = resolve(temporaryRoot, "capture.png");
  let backend: "windows_graphics_capture" | "print_window_fallback" = "windows_graphics_capture";
  let fallbackUsed = false;
  try {
    const helper = await verifiedWorkstationNativeHelper(context);
    if (helper) {
      try {
        await captureWithNative(helper, grant, outputPath);
      } catch {
        fallbackUsed = true;
      }
    } else {
      fallbackUsed = true;
    }
    if (fallbackUsed) {
      backend = "print_window_fallback";
      z.object({ window: observedSchema, outputPath: z.string(), backend: z.literal("print_window_fallback") }).strict().parse(
        await runObserver([
          "-Action", "capture", "-WindowHandle", grant.identity.windowHandle, "-OutputPath", outputPath,
          "-ExpectedProcessId", String(grant.identity.processId), "-ExpectedProcessStartedAt", grant.identity.processStartedAt,
          "-ExpectedExecutablePath", grant.identity.executablePath,
        ], 12_000),
      );
    }
    const after = (await observeWindows()).find((candidate) => sameIdentity(grant, candidate));
    if (!after) throw new Error("The window identity changed during capture.");
    const info = await lstat(outputPath);
    if (!info.isFile() || info.isSymbolicLink() || info.nlink > 1 || info.size < 8 || info.size > MAX_CAPTURE_BYTES) {
      throw new Error("Window capture output is missing or unsafe.");
    }
    const bytes = await readFile(outputPath);
    if (!bytes.subarray(0, 8).equals(Buffer.from([0x89,0x50,0x4e,0x47,0x0d,0x0a,0x1a,0x0a]))) {
      throw new Error("Window capture did not produce PNG.");
    }
    return {
      result: {
        ...publicWindow(grant, after), capturedAt: new Date().toISOString(), mimeType: "image/png" as const,
        byteLength: bytes.byteLength, sha256: createHash("sha256").update(bytes).digest("hex"), backend, fallbackUsed,
      },
      bytes,
    };
  } finally {
    await rm(temporaryRoot, { recursive: true, force: true });
  }
}
