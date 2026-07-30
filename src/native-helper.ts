import { createHash } from "node:crypto";
import { lstat, readFile } from "node:fs/promises";
import { isAbsolute, resolve } from "node:path";
import type { ProjectContext } from "./profile.js";

const NATIVE_HELPER_ENVIRONMENT_KEY = "CHATGPT_HYBRID_WINDOW_CAPTURE_HELPER";
const VERIFICATION_CACHE_MS = 30_000;

interface HelperFingerprint {
  readonly path: string;
  readonly executable: string;
  readonly checksum: string;
}

interface VerifiedHelperCache {
  readonly fingerprint: HelperFingerprint;
  readonly verifiedAtMs: number;
}

let verifiedHelperCache: VerifiedHelperCache | undefined;

function defaultHelperPath(context: ProjectContext): string {
  return resolve(
    context.engineRoot,
    "runtime-distribution",
    "window-capture",
    "win-x64",
    "HybridWindowCapture.exe",
  );
}

function statFingerprint(info: Awaited<ReturnType<typeof lstat>>): string {
  return [info.dev, info.ino, info.size, info.mtimeMs, info.ctimeMs].join(":");
}

function sameFingerprint(left: HelperFingerprint, right: HelperFingerprint): boolean {
  return left.path === right.path
    && left.executable === right.executable
    && left.checksum === right.checksum;
}

export async function verifiedWorkstationNativeHelper(
  context: ProjectContext,
): Promise<string | undefined> {
  const configured = process.env[NATIVE_HELPER_ENVIRONMENT_KEY];
  if (configured && !isAbsolute(configured)) {
    throw new Error(`${NATIVE_HELPER_ENVIRONMENT_KEY} must be an absolute path.`);
  }
  const path = resolve(configured ?? defaultHelperPath(context));
  const checksumPath = `${path}.sha256`;
  const [info, checksumInfo] = await Promise.all([
    lstat(path).catch(() => undefined),
    lstat(checksumPath).catch(() => undefined),
  ]);
  if (!info && !checksumInfo) return undefined;
  if (
    !info
    || !checksumInfo
    || !info.isFile()
    || info.isSymbolicLink()
    || info.nlink > 1
    || info.size < 100_000
    || info.size > 32 * 1024 * 1024
    || !checksumInfo.isFile()
    || checksumInfo.isSymbolicLink()
    || checksumInfo.nlink > 1
    || checksumInfo.size > 4096
  ) {
    throw new Error("Native workstation helper distribution is incomplete or unsafe.");
  }

  const fingerprint: HelperFingerprint = {
    path,
    executable: statFingerprint(info),
    checksum: statFingerprint(checksumInfo),
  };
  const now = Date.now();
  if (
    verifiedHelperCache
    && now - verifiedHelperCache.verifiedAtMs <= VERIFICATION_CACHE_MS
    && sameFingerprint(verifiedHelperCache.fingerprint, fingerprint)
  ) {
    return path;
  }

  const expectedText = new TextDecoder("utf-8", { fatal: true })
    .decode(await readFile(checksumPath))
    .trim();
  const match = /^([a-f0-9]{64})\s+HybridWindowCapture\.exe$/iu.exec(expectedText);
  if (!match) throw new Error("Native workstation helper checksum file is malformed.");
  const observed = createHash("sha256").update(await readFile(path)).digest("hex");
  if (observed !== match[1]?.toLocaleLowerCase("en-US")) {
    throw new Error("Native workstation helper checksum mismatch.");
  }
  verifiedHelperCache = { fingerprint, verifiedAtMs: now };
  return path;
}

export function resetNativeHelperVerificationCacheForTests(): void {
  verifiedHelperCache = undefined;
}
