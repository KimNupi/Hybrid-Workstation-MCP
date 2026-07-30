import { access, link, mkdir, mkdtemp, readFile, rm, symlink, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, expect, it } from "vitest";
import { listDirectory, readImageFile, readTextFile, replaceText, searchFiles, writeTextFile } from "../src/filesystem.js";
import type { ProjectContext, ProjectProfile } from "../src/profile.js";

const temporaryRoots: string[] = [];

async function fixture(): Promise<{ context: ProjectContext; primary: string; foreign: string; outside: string }> {
  const root = await mkdtemp(join(tmpdir(), "workstation-files-"));
  temporaryRoots.push(root);
  const primary = join(root, "primary");
  const foreign = join(root, "foreign");
  const outside = join(root, "outside 한글");
  const engineRoot = join(root, "hybrid-workstation-mcp");
  await Promise.all([
    mkdir(primary, { recursive: true }),
    mkdir(foreign, { recursive: true }),
    mkdir(outside, { recursive: true }),
    mkdir(engineRoot, { recursive: true }),
  ]);
  const profile = Object.freeze({
    id: "test-profile",
    displayName: "Test Profile",
    appName: "Test Workstation",
    serverName: "test-workstation",
    defaultWorkingDirectoryRelative: ".",
    httpPort: 23002,
    bootstrapFiles: Object.freeze([]),
    identityMarkers: Object.freeze([]),
    primaryRoot: primary,
  }) as unknown as ProjectProfile;
  const context = Object.freeze({
    profile,
    primaryRoot: primary,
    defaultWorkingDirectory: primary,
    engineRoot,
    managedProjectRoots: Object.freeze([
      Object.freeze({ profileId: "test-profile", primaryRoot: primary }),
      Object.freeze({ profileId: "foreign-profile", primaryRoot: foreign }),
    ]),
  });
  return { context, primary, foreign, outside };
}

afterEach(async () => {
  await Promise.all(temporaryRoots.splice(0).map((root) => rm(root, { recursive: true, force: true })));
});

describe("workstation filesystem", () => {
  it("reads, creates, replaces, lists, and searches outside the profile root", async () => {
    const { context, outside } = await fixture();
    const path = join(outside, ".env.example");
    const created = await writeTextFile({
      context,
      path,
      content: "alpha=한글\nbeta=two\n",
      expectedSha256: "absent",
      createParents: false,
    });
    expect(created.created).toBe(true);

    const read = await readTextFile({ context, path, startLine: 1, maxLines: 10 });
    expect(read.text).toContain("alpha=한글");
    expect(read.sha256).toBe(created.sha256);

    const replaced = await replaceText({
      context,
      path,
      expectedSha256: read.sha256,
      oldText: "beta=two",
      newText: "beta=three",
    });
    expect((await readFile(path, "utf8"))).toContain("beta=three");
    expect(replaced.sha256).not.toBe(read.sha256);

    const listing = await listDirectory({ context, path: outside, depth: 2, maxEntries: 100 });
    expect(listing.entries.some((entry) => entry.path === path)).toBe(true);

    const contentSearch = await searchFiles({
      context,
      path: outside,
      query: "beta=three",
      mode: "content",
      regex: false,
      globs: [],
      includeHidden: true,
      respectIgnoreFiles: false,
      maxResults: 20,
    });
    expect(contentSearch.matches.some((match) => match.path === path)).toBe(true);

    const pathSearch = await searchFiles({
      context,
      path: outside,
      query: ".env.example",
      mode: "path",
      regex: false,
      globs: [],
      includeHidden: true,
      respectIgnoreFiles: false,
      maxResults: 20,
    });
    expect(pathSearch.matches.some((match) => match.path === path)).toBe(true);
  });

  it("uses the default cwd for relative paths and preserves stale-write conflicts", async () => {
    const { context, primary } = await fixture();
    const path = join(primary, "nested", "file.txt");
    const created = await writeTextFile({
      context,
      path: "nested/file.txt",
      content: "first\n",
      expectedSha256: "absent",
      createParents: true,
    });
    await writeFile(path, "changed elsewhere\n", "utf8");
    await expect(writeTextFile({
      context,
      path,
      content: "overwrite\n",
      expectedSha256: created.sha256,
      createParents: false,
    })).rejects.toThrow("changed after it was read");
    expect(await readFile(path, "utf8")).toBe("changed elsewhere\n");
  });

  it("allows hardlink reads but rejects ambiguous hardlink mutation", async () => {
    const { context, outside } = await fixture();
    const source = join(outside, "source.txt");
    const alias = join(outside, "alias.txt");
    await writeFile(source, "hardlink content\n", "utf8");
    await link(source, alias);
    const read = await readTextFile({ context, path: alias, startLine: 1, maxLines: 10 });
    expect(read.text).toContain("hardlink content");
    await expect(replaceText({
      context,
      path: alias,
      expectedSha256: read.sha256,
      oldText: "hardlink",
      newText: "changed",
    })).rejects.toThrow(/Hardlinked text mutation/u);
    expect(await readFile(source, "utf8")).toBe("hardlink content\n");
  });

  it("allows exactly one concurrent replacement for the same prior hash", async () => {
    const { context, outside } = await fixture();
    const path = join(outside, "concurrent.txt");
    const created = await writeTextFile({
      context,
      path,
      content: "version=one\n",
      expectedSha256: "absent",
      createParents: false,
    });
    const attempts = await Promise.allSettled([
      writeTextFile({ context, path, content: "version=left\n", expectedSha256: created.sha256, createParents: false }),
      writeTextFile({ context, path, content: "version=right\n", expectedSha256: created.sha256, createParents: false }),
    ]);
    expect(attempts.filter((attempt) => attempt.status === "fulfilled")).toHaveLength(1);
    expect(attempts.filter((attempt) => attempt.status === "rejected")).toHaveLength(1);
    expect(["version=left\n", "version=right\n"]).toContain(await readFile(path, "utf8"));
  });

  it("denies every direct filesystem tool at another managed project root before mutation", async () => {
    const { context, foreign } = await fixture();
    const textPath = join(foreign, "secret.txt");
    const imagePath = join(foreign, "secret.png");
    await writeFile(textPath, "foreign content\n", "utf8");
    await writeFile(imagePath, Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]));

    await expect(listDirectory({ context, path: foreign, depth: 1, maxEntries: 10 })).rejects.toThrow("foreign-profile");
    await expect(searchFiles({
      context,
      path: foreign,
      query: "foreign",
      mode: "content",
      regex: false,
      globs: [],
      includeHidden: true,
      respectIgnoreFiles: false,
      maxResults: 10,
    })).rejects.toThrow("foreign-profile");
    await expect(readTextFile({ context, path: textPath, startLine: 1, maxLines: 10 })).rejects.toThrow("foreign-profile");
    await expect(readImageFile(context, imagePath)).rejects.toThrow("foreign-profile");
    await expect(replaceText({
      context,
      path: textPath,
      expectedSha256: "0".repeat(64),
      oldText: "foreign",
      newText: "changed",
    })).rejects.toThrow("foreign-profile");

    const newParent = join(foreign, "must-not-exist");
    await expect(writeTextFile({
      context,
      path: join(newParent, "new.txt"),
      content: "blocked\n",
      expectedSha256: "absent",
      createParents: true,
    })).rejects.toThrow("foreign-profile");
    await expect(access(newParent)).rejects.toThrow();
  });

  it("blocks relative, broad-tree, case-variant, and junction routes into another managed project", async () => {
    const { context, primary, foreign, outside } = await fixture();
    const secretPath = join(foreign, "secret.txt");
    await writeFile(secretPath, "foreign content\n", "utf8");

    await expect(readTextFile({ context, path: "../foreign/secret.txt", startLine: 1, maxLines: 10 })).rejects.toThrow("foreign-profile");
    await expect(listDirectory({ context, path: join(primary, ".."), depth: 1, maxEntries: 10 })).rejects.toThrow("foreign-profile");

    if (process.platform === "win32") {
      await expect(readTextFile({ context, path: secretPath.toUpperCase(), startLine: 1, maxLines: 10 })).rejects.toThrow("foreign-profile");
    }

    const alias = join(outside, "foreign-junction");
    await symlink(foreign, alias, process.platform === "win32" ? "junction" : "dir");
    await expect(readTextFile({ context, path: join(alias, "secret.txt"), startLine: 1, maxLines: 10 })).rejects.toThrow("foreign-profile");
  });

  it("protects runtime credentials, configured grants, secret files, and canonical aliases", async () => {
    const { context, outside } = await fixture();
    const runtime = join(context.engineRoot, "runtime");
    const runtimeSecret = join(runtime, ".env.local");
    const configuredGrants = join(outside, "ui_grants.json");
    const envSecret = join(outside, ".env");
    const privateKey = join(outside, "private.pem");
    const safeTemplate = join(outside, ".env.template");
    await mkdir(runtime, { recursive: true });
    await Promise.all([
      writeFile(runtimeSecret, "TUNNEL_KEY=runtime-secret\n", "utf8"),
      writeFile(configuredGrants, "grants-secret\n", "utf8"),
      writeFile(envSecret, "API_TOKEN=file-secret\n", "utf8"),
      writeFile(privateKey, "private-key-secret\n", "utf8"),
      writeFile(safeTemplate, "API_TOKEN=replace-me\n", "utf8"),
    ]);

    const previousGrantsPath = process.env.CHATGPT_HYBRID_UI_GRANTS_PATH;
    process.env.CHATGPT_HYBRID_UI_GRANTS_PATH = configuredGrants;
    try {
      for (const path of [runtimeSecret, configuredGrants, envSecret, privateKey]) {
        await expect(readTextFile({ context, path, startLine: 1, maxLines: 10 }))
          .rejects.toThrow(/Protected credential/u);
      }
      await expect(readTextFile({ context, path: safeTemplate, startLine: 1, maxLines: 10 }))
        .resolves.toMatchObject({ text: "API_TOKEN=replace-me\n" });

      const newRuntimeFile = join(runtime, "must-not-exist.txt");
      await expect(writeTextFile({
        context,
        path: newRuntimeFile,
        content: "blocked\n",
        expectedSha256: "absent",
        createParents: false,
      })).rejects.toThrow(/Protected credential/u);
      await expect(access(newRuntimeFile)).rejects.toThrow();

      const listing = await listDirectory({ context, path: outside, depth: 2, maxEntries: 100 });
      expect(listing.entries.map((entry) => entry.path)).not.toEqual(expect.arrayContaining([
        configuredGrants,
        envSecret,
        privateKey,
      ]));
      expect(listing.entries.some((entry) => entry.path === safeTemplate)).toBe(true);

      const searched = await searchFiles({
        context,
        path: outside,
        query: "secret",
        mode: "content",
        regex: false,
        globs: [],
        includeHidden: true,
        respectIgnoreFiles: false,
        maxResults: 20,
      });
      expect(searched.matches).toEqual([]);

      const alias = join(outside, "runtime-alias");
      await symlink(runtime, alias, process.platform === "win32" ? "junction" : "dir");
      await expect(readTextFile({ context, path: join(alias, ".env.local"), startLine: 1, maxLines: 10 }))
        .rejects.toThrow(/Protected credential/u);
      const aliasedListing = await listDirectory({ context, path: outside, depth: 1, maxEntries: 100 });
      expect(aliasedListing.entries.some((entry) => entry.path === alias)).toBe(false);
    } finally {
      if (previousGrantsPath === undefined) delete process.env.CHATGPT_HYBRID_UI_GRANTS_PATH;
      else process.env.CHATGPT_HYBRID_UI_GRANTS_PATH = previousGrantsPath;
    }
  });

  it("preserves mixed-newline pagination, trailing empty lines, and reads beyond EOF", async () => {
    const { context, outside } = await fixture();
    const path = join(outside, "mixed-newlines.txt");
    await writeFile(path, "one\r\ntwo\rthree\nfour\n", "utf8");

    const middle = await readTextFile({ context, path, startLine: 2, maxLines: 2 });
    expect(middle).toMatchObject({
      text: "two\nthree",
      startLine: 2,
      endLine: 3,
      totalLines: 5,
      truncated: true,
    });
    const trailing = await readTextFile({ context, path, startLine: 4, maxLines: 2 });
    expect(trailing).toMatchObject({ text: "four\n", endLine: 5, totalLines: 5, truncated: true });
    const beyond = await readTextFile({ context, path, startLine: 10, maxLines: 2 });
    expect(beyond).toMatchObject({ text: "", endLine: 9, totalLines: 5, truncated: true });
  });

  it("allows an unmanaged sibling whose name only shares a foreign-root prefix", async () => {
    const { context, foreign } = await fixture();
    const sibling = `${foreign}-backup`;
    const path = join(sibling, "notes.txt");
    await mkdir(sibling, { recursive: true });
    await writeFile(path, "allowed\n", "utf8");
    const result = await readTextFile({ context, path, startLine: 1, maxLines: 10 });
    expect(result.text).toContain("allowed");
  });
});
