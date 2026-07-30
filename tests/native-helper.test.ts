import { createHash } from "node:crypto";
import { mkdir, mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, expect, it } from "vitest";
import {
  resetNativeHelperVerificationCacheForTests,
  verifiedWorkstationNativeHelper,
} from "../src/native-helper.js";
import type { ProjectContext, ProjectProfile } from "../src/profile.js";

const temporaryRoots: string[] = [];
const environmentKey = "CHATGPT_HYBRID_WINDOW_CAPTURE_HELPER";
const originalConfiguredPath = process.env[environmentKey];

async function fixture() {
  const root = await mkdtemp(join(tmpdir(), "hybrid-native-helper-"));
  temporaryRoots.push(root);
  const primaryRoot = join(root, "project");
  const engineRoot = join(root, "engine");
  await Promise.all([mkdir(primaryRoot, { recursive: true }), mkdir(engineRoot, { recursive: true })]);
  const profile = Object.freeze({
    id: "native-helper-test",
    displayName: "Native Helper Test",
    appName: "Native Helper Test",
    serverName: "native-helper-test",
    permissionPreset: "readonly",
    defaultWorkingDirectoryRelative: ".",
    httpPort: 23081,
    bootstrapFiles: Object.freeze([]),
    identityMarkers: Object.freeze([]),
    primaryRoot,
  }) as unknown as ProjectProfile;
  const context = Object.freeze({
    profile,
    primaryRoot,
    defaultWorkingDirectory: primaryRoot,
    engineRoot,
    managedProjectRoots: Object.freeze([{ profileId: profile.id, primaryRoot }]),
  }) as ProjectContext;
  return { context, root, engineRoot };
}

async function writeDistribution(path: string, bytes: Buffer) {
  await writeFile(path, bytes);
  const digest = createHash("sha256").update(bytes).digest("hex");
  await writeFile(`${path}.sha256`, `${digest}  HybridWindowCapture.exe\n`, "utf8");
}

afterEach(async () => {
  resetNativeHelperVerificationCacheForTests();
  if (originalConfiguredPath === undefined) delete process.env[environmentKey];
  else process.env[environmentKey] = originalConfiguredPath;
  await Promise.all(temporaryRoots.splice(0).map((root) => rm(root, { recursive: true, force: true })));
});

describe("native workstation helper verification", () => {
  it("accepts one checksum-pinned regular executable distribution", async () => {
    const { context, root } = await fixture();
    const path = join(root, "HybridWindowCapture.exe");
    await writeDistribution(path, Buffer.alloc(100_001, 7));
    process.env[environmentKey] = path;
    await expect(verifiedWorkstationNativeHelper(context)).resolves.toBe(path);
    await expect(verifiedWorkstationNativeHelper(context)).resolves.toBe(path);
  });

  it("invalidates cached verification when the executable changes", async () => {
    const { context, root } = await fixture();
    const path = join(root, "HybridWindowCapture.exe");
    await writeDistribution(path, Buffer.alloc(100_001, 3));
    process.env[environmentKey] = path;
    await expect(verifiedWorkstationNativeHelper(context)).resolves.toBe(path);
    await writeFile(path, Buffer.alloc(100_001, 4));
    await expect(verifiedWorkstationNativeHelper(context)).rejects.toThrow("checksum mismatch");
  });

  it("uses the public distribution path and rejects relative configuration", async () => {
    const { context, engineRoot } = await fixture();
    process.env[environmentKey] = "relative-helper.exe";
    await expect(verifiedWorkstationNativeHelper(context)).rejects.toThrow("must be an absolute path");
    delete process.env[environmentKey];
    await expect(verifiedWorkstationNativeHelper(context)).resolves.toBeUndefined();

    const path = join(
      engineRoot,
      "runtime-distribution",
      "window-capture",
      "win-x64",
      "HybridWindowCapture.exe",
    );
    await mkdir(join(path, ".."), { recursive: true });
    await writeDistribution(path, Buffer.alloc(100_001, 9));
    await expect(verifiedWorkstationNativeHelper(context)).resolves.toBe(path);
  });
});
