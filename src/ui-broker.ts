import { createHash } from "node:crypto";
import { lstat, mkdtemp, readFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, isAbsolute, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { z } from "zod";
import type { ProjectContext } from "./profile.js";
import { makeSafeEnvironment, resolvePowerShellExecutable, runProcess } from "./process.js";

const MODULE_DIRECTORY = dirname(fileURLToPath(import.meta.url));
const WINDOW_OBSERVER = resolve(MODULE_DIRECTORY, "..", "scripts", "window-observer.ps1");
const GRANTS_ENVIRONMENT_KEY = "CHATGPT_HYBRID_UI_GRANTS_PATH";
const CAPTURE_HELPER_ENVIRONMENT_KEY = "CHATGPT_HYBRID_WINDOW_CAPTURE_HELPER";
const MAX_GRANTS_BYTES = 1024 * 1024;
const MAX_CAPTURE_BYTES = 32 * 1024 * 1024;
const WINDOW_REF_PATTERN = /^window:[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/u;

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
const storeSchema = z.object({ version: z.literal(1), grants: z.array(grantSchema).max(128) }).strict();
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
type Observed = z.infer<typeof observedSchema>;

function grantsPath(context: ProjectContext): string {
  const configured = process.env[GRANTS_ENVIRONMENT_KEY];
  if (configured && !isAbsolute(configured)) throw new Error(`${GRANTS_ENVIRONMENT_KEY} must be absolute.`);
  return resolve(configured ?? resolve(context.engineRoot, "runtime", "ui_grants.json"));
}

async function loadStore(context: ProjectContext): Promise<{ configured: boolean; value: z.infer<typeof storeSchema> }> {
  const path = grantsPath(context);
  const info = await lstat(path).catch((error: NodeJS.ErrnoException) => {
    if (error.code === "ENOENT") return undefined;
    throw error;
  });
  if (!info) return { configured: false, value: { version: 1, grants: [] } };
  if (!info.isFile() || info.isSymbolicLink() || info.nlink > 1 || info.size > MAX_GRANTS_BYTES) throw new Error("Window grant store is unsafe.");
  return { configured: true, value: storeSchema.parse(JSON.parse(new TextDecoder("utf-8", { fatal: true }).decode(await readFile(path))) as unknown) };
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

function sameIdentity(grant: Grant, observed: Observed): boolean {
  return grant.identity.windowHandle === observed.windowHandle
    && grant.identity.processId === observed.processId
    && grant.identity.processStartedAt === observed.processStartedAt
    && grant.identity.executablePath.toLocaleLowerCase("en-US") === observed.executablePath.toLocaleLowerCase("en-US");
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

export function resolveGrantedWindowList(storeValue: unknown, observedValue: unknown, profileId: string) {
  const store = storeSchema.parse(storeValue);
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
  const grants = store.value.grants.filter((grant) => grant.profileId === context.profile.id);
  if (grants.length === 0) return { configured: store.configured, windows: [], unavailableCount: 0 };
  return { configured: store.configured, ...resolveGrantedWindowList(store.value, await observeWindows(), context.profile.id) };
}

async function requireGrant(context: ProjectContext, windowRef: string): Promise<Grant> {
  if (!WINDOW_REF_PATTERN.test(windowRef)) throw new Error("windowRef is invalid.");
  const store = await loadStore(context);
  const matches = store.value.grants.filter((grant) => grant.profileId === context.profile.id && grant.ref === windowRef);
  if (matches.length !== 1) throw new Error("The requested window is not granted to this profile.");
  return matches[0]!;
}

function identityArguments(grant: Grant): string[] {
  return [
    "--window-handle", grant.identity.windowHandle,
    "--expected-pid", String(grant.identity.processId),
    "--expected-start", grant.identity.processStartedAt,
    "--expected-exe", grant.identity.executablePath,
  ];
}

async function verifiedNativeHelper(context: ProjectContext): Promise<string | undefined> {
  const configured = process.env[CAPTURE_HELPER_ENVIRONMENT_KEY];
  if (configured && !isAbsolute(configured)) throw new Error(`${CAPTURE_HELPER_ENVIRONMENT_KEY} must be absolute.`);
  const path = resolve(configured ?? resolve(context.engineRoot, "runtime-distribution", "window-capture", "win-x64", "HybridWindowCapture.exe"));
  const hashPath = `${path}.sha256`;
  const [info, hashInfo] = await Promise.all([lstat(path).catch(() => undefined), lstat(hashPath).catch(() => undefined)]);
  if (!info && !hashInfo) return undefined;
  if (!info || !hashInfo || !info.isFile() || info.isSymbolicLink() || info.nlink > 1 || info.size < 100_000 || info.size > 32 * 1024 * 1024
      || !hashInfo.isFile() || hashInfo.isSymbolicLink() || hashInfo.nlink > 1 || hashInfo.size > 4096) {
    throw new Error("Native window capture distribution is incomplete or unsafe.");
  }
  const expectedText = new TextDecoder("utf-8", { fatal: true }).decode(await readFile(hashPath)).trim();
  const match = /^([a-f0-9]{64})\s+HybridWindowCapture\.exe$/iu.exec(expectedText);
  if (!match) throw new Error("Native window capture checksum file is malformed.");
  const observed = createHash("sha256").update(await readFile(path)).digest("hex");
  if (observed !== match[1]!.toLocaleLowerCase("en-US")) throw new Error("Native window capture checksum mismatch.");
  return path;
}

async function captureWithNative(context: ProjectContext, helper: string, grant: Grant, outputPath: string): Promise<void> {
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
    const helper = await verifiedNativeHelper(context);
    if (helper) {
      try {
        await captureWithNative(context, helper, grant, outputPath);
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
    if (!info.isFile() || info.isSymbolicLink() || info.nlink > 1 || info.size < 8 || info.size > MAX_CAPTURE_BYTES) throw new Error("Window capture output is missing or unsafe.");
    const bytes = await readFile(outputPath);
    if (!bytes.subarray(0, 8).equals(Buffer.from([0x89,0x50,0x4e,0x47,0x0d,0x0a,0x1a,0x0a]))) throw new Error("Window capture did not produce PNG.");
    return {
      result: {
        ...publicWindow(grant, after), capturedAt: new Date().toISOString(), mimeType: "image/png" as const,
        byteLength: bytes.byteLength, sha256: createHash("sha256").update(bytes).digest("hex"), backend, fallbackUsed,
      },
      bytes,
    };
  } finally { await rm(temporaryRoot, { recursive: true, force: true }); }
}
