import { readFile } from "node:fs/promises";
import { resolve } from "node:path";
import { describe, expect, it } from "vitest";
import { resolveGrantedWindowList, resolveTrustedWindowRuleCandidates } from "../src/ui-broker.js";

const identity = {
  windowHandle: "12345",
  processId: 42,
  processStartedAt: "2026-07-25T00:00:00.0000000+00:00",
  executablePath: "C:\\Apps\\Game.exe",
};
const observed = {
  ...identity,
  executablePath: "c:\\apps\\game.exe",
  processName: "Game",
  title: "Game Preview - Development",
  left: 10,
  top: 20,
  width: 1280,
  height: 720,
  minimized: false,
};

function trustedRule(profileId: string, ref: string, titleContains = "Game Preview") {
  return {
    profileId,
    ref,
    label: `${profileId} game`,
    createdAt: "2026-07-25T00:00:00.000Z",
    executablePath: "C:\\Apps\\Game.exe",
    titleContains,
  };
}

describe("window grants", () => {
  it("publishes only exact live identities for the selected profile and migrates v1 in memory", () => {
    const result = resolveGrantedWindowList({
      version: 1,
      grants: [
        {
          profileId: "workstation",
          ref: "window:11111111-1111-4111-8111-111111111111",
          label: "Game",
          createdAt: "2026-07-25T00:00:00.000Z",
          identity,
        },
        {
          profileId: "other",
          ref: "window:22222222-2222-4222-8222-222222222222",
          label: "Other",
          createdAt: "2026-07-25T00:00:00.000Z",
          identity: { ...identity, windowHandle: "999" },
        },
      ],
    }, [observed], "workstation");

    expect(result).toEqual({
      windows: [{
        windowRef: "window:11111111-1111-4111-8111-111111111111",
        label: "Game",
        title: "Game Preview - Development",
        processName: "Game",
        bounds: { left: 10, top: 20, width: 1280, height: 720 },
        minimized: false,
      }],
      unavailableCount: 0,
    });
  });

  it("counts stale grants without exposing their private executable identity", () => {
    const result = resolveGrantedWindowList({
      version: 1,
      grants: [{
        profileId: "workstation",
        ref: "window:11111111-1111-4111-8111-111111111111",
        label: "Game",
        createdAt: "2026-07-25T00:00:00.000Z",
        identity,
      }],
    }, [], "workstation");

    expect(result).toEqual({ windows: [], unavailableCount: 1 });
  });

  it("auto-binds only one exact executable and title match", () => {
    const result = resolveTrustedWindowRuleCandidates({
      version: 2,
      grants: [],
      trustedApps: [trustedRule("workstation", "trusted-app:33333333-3333-4333-8333-333333333333")],
    }, [observed], "workstation");

    expect(result).toMatchObject({
      trustedRuleCount: 1,
      autoBoundCount: 1,
      autoUnmatchedCount: 0,
      autoAmbiguousCount: 0,
      autoCollisionCount: 0,
      matches: [{ profileId: "workstation", window: { windowHandle: "12345" } }],
    });
  });

  it("fails closed for ambiguous and cross-profile trusted rules", () => {
    const alpha = trustedRule("workstation", "trusted-app:44444444-4444-4444-8444-444444444444");
    const beta = trustedRule("other", "trusted-app:55555555-5555-4555-8555-555555555555");

    const collision = resolveTrustedWindowRuleCandidates({
      version: 2,
      grants: [],
      trustedApps: [alpha, beta],
    }, [observed], "workstation");
    expect(collision).toMatchObject({ autoBoundCount: 0, autoCollisionCount: 1, matches: [] });

    const ambiguous = resolveTrustedWindowRuleCandidates({
      version: 2,
      grants: [],
      trustedApps: [alpha],
    }, [observed, { ...observed, windowHandle: "67890", processId: 43 }], "workstation");
    expect(ambiguous).toMatchObject({ autoBoundCount: 0, autoAmbiguousCount: 1, matches: [] });
  });

  it("keeps trusted registration exact-path, title-bounded, and ACL-protected", async () => {
    const source = await readFile(resolve("scripts", "Manage-Window-Grants.ps1"), "utf8");
    expect(source).toContain('[ValidateSet("menu", "list", "grant", "trust", "clear")]');
    expect(source).toContain("trustedApps");
    expect(source).toContain("[IO.Path]::GetFullPath");
    expect(source).toContain("IndexOf($TitleContains, [StringComparison]::OrdinalIgnoreCase)");
    expect(source).toContain("exactly one currently open window");
    expect(source).toContain("SetAccessRuleProtection($true, $false)");
    expect(source).not.toContain("titleRegex");
  });
});
