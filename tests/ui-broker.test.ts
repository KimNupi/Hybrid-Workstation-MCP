import { describe, expect, it } from "vitest";
import { resolveGrantedWindowList } from "../src/ui-broker.js";

const identity = {
  windowHandle: "12345",
  processId: 42,
  processStartedAt: "2026-07-25T00:00:00.0000000+00:00",
  executablePath: "C:\\Apps\\Game.exe",
};

describe("window grants", () => {
  it("publishes only exact live identities for the selected profile", () => {
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
    }, [{
      ...identity,
      executablePath: "c:\\apps\\game.exe",
      processName: "Game",
      title: "Game Preview",
      left: 10,
      top: 20,
      width: 1280,
      height: 720,
      minimized: false,
    }], "workstation");

    expect(result).toEqual({
      windows: [{
        windowRef: "window:11111111-1111-4111-8111-111111111111",
        label: "Game",
        title: "Game Preview",
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
});
