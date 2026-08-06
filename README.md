# Hybrid Workstation MCP

A Windows package that connects a general-purpose local workstation profile to
a ChatGPT developer-mode app through OpenAI Secure MCP Tunnel. One profile is
installed by default; advanced users can register and manage additional,
non-overlapping profiles.

The package exposes bounded tools for bootstrap context, Git resume and change
snapshots, directory and text search, text and image reads, explicitly granted
application window observation, SHA-guarded single-file writes, atomic guarded
multi-file patches, managed Git worktrees, and asynchronous PowerShell jobs with status, output, and
cancellation.

## Release status

Version 1.6 adds `git_worktree_create`, `git_worktree_list`, and
`git_worktree_remove` for isolated branch work in the registered project. The
branch name is the stable request identity: storage paths and worktree IDs are
assigned automatically, repeated creation returns the same verified worktree,
and a preserved branch can be reopened after removal. Normal clean removal is a
single operation. The tool refuses dirty worktrees, branches already checked out
elsewhere, unverified path collisions, and uncertain cleanup instead of risking
local work.

Version 1.5 introduced bounded Git change review with `show_changes(path)`,
atomic SHA-guarded multi-file editing with `apply_patch`, and a dependency lock
with no currently reported moderate-or-higher npm advisories. Version 1.4
introduced the hardened direct-filesystem boundary, `project_resume(path)`,
checksum-pinned native shell hosting, deterministic build/tool-schema IDs, and
the current validation gates.

Each public server process is now a nineteen-tool, single-profile stdio MCP. It
does not add an HTTP MCP listener. The local manager can inspect registered
profiles concurrently and start, stop, or restart up to three profiles at a
time; already active or recovering profiles are skipped by **Connect all**.
Trusted-app window observation from version 1.3 remains available: ambiguous or
cross-profile matches fail closed, Windows Graphics Capture remains the primary
backend with target-only `PrintWindow` fallback, and there is still no UI
clicking or text input.

The source, tests, setup flow, native helper, and release package have completed
automated validation on Windows x64. A clean machine with a real OpenAI Secure
MCP Tunnel is still recommended before wider deployment.

## Requirements

- Windows 10 or 11 on x64
- Node.js 20 or newer
- Git for Windows
- ripgrep (`rg.exe`)
- A ChatGPT account or workspace allowed to use Developer mode
- An OpenAI Platform tunnel with a `tunnel_id` and runtime API key

The release ZIP includes the self-contained x64 window-capture helper. End users
do not need to install .NET. Building a release from source requires .NET SDK 10.

Secure MCP Tunnel permissions and ChatGPT Developer mode are separate. Each
user must use their own Platform organization, tunnel, API key, and ChatGPT
workspace permission. Never share another person's runtime key.

Official setup references:

- [Secure MCP Tunnel](https://developers.openai.com/api/docs/guides/secure-mcp-tunnels)
- [Connect from ChatGPT](https://developers.openai.com/apps-sdk/deploy/connect-chatgpt)

## Quick start

1. Extract the release ZIP to a normal local directory.
2. Double-click `Install.cmd`.
3. Create a tunnel in OpenAI Platform tunnel settings and keep its runtime key
   private.
4. Double-click `Configure Tunnel.cmd`, then enter your own `tunnel_id` and
   runtime API key.
5. Double-click `Hybrid MCP Control.cmd` and choose `Start`.
6. In ChatGPT, enable **Settings → Security and login → Developer mode**.
7. Open **Settings → Plugins**, create a developer-mode app, select **Tunnel**,
   and choose the same tunnel.
8. Start a new chat, attach the app, and ask it to inspect the workstation
   context before making changes.

The default operating profile is created at `%USERPROFILE%\Hybrid Workstation`.
It is a small Git repository containing durable instructions and the local
profile manifest. The profile can access other paths available to the current
Windows account, except that direct file and Git tools deny known credential,
runtime, private-key, browser-profile, and other registered-profile paths.
PowerShell still runs with the current Windows account and can access anything
that account can access. Windows ACLs and UAC remain the real machine boundary.

## Control Center

`Hybrid MCP Control.cmd` and the installed desktop shortcut open a simple
Windows Control Center. The main screen shows only the connection state, one
Connect or Disconnect button, and the current access mode. Tunnel setup,
connection checks, window access, logs, and the classic text menu remain under
**Setup & troubleshooting**.

With one registered profile, the screen remains unchanged. With two or more,
the Control Center reveals a profile selector plus **Connect all**, **Connect
remaining**, or **Disconnect all** as appropriate. Multi-profile status checks
use at most four workers, lifecycle actions use at most three, and one profile's
failure is reported without hiding the results from the others.

The Control Center uses the same fail-closed start, stop, status, recovery, and
permission scripts as the command line. It does not store or display the tunnel
runtime key. Status refresh is local and runs every 15 seconds; the online
connection check runs only when requested.

## Window observation

Window observation is off until the local user grants one open window.

1. Open the application or game preview you want ChatGPT to see.
2. Open `Hybrid MCP Control.cmd`.
3. Choose **Window access**.
4. Choose **Grant one currently open window** for temporary access, or **Trust
   app and auto-rebind** for repeated development runs.
5. For a trusted rule, keep the suggested stable project/file title text or
   enter a narrower title substring.
6. Ask ChatGPT to list or capture the granted window.

A one-time grant pins the exact window handle, process ID, process start time,
and executable identity. A trusted rule stores only the exact executable path
and bounded title substring, then creates a fresh opaque window reference after
a restart when exactly one safe match exists. ChatGPT never receives the raw
handle, PID, process start time, or executable path. Multiple matches and
cross-profile collisions remain unavailable, and the local menu can clear both
entry types at any time.

`ui_window_capture` captures only the target window. It does not take a desktop
screenshot and crop it afterward. Minimized windows are rejected; restore the
window before capture.

## Permission presets

- `workstation` (default): normal operation with all nineteen tools. ChatGPT can
  inspect, review Git changes, create isolated branch worktrees, observe granted
  windows, apply guarded single- or multi-file edits, build, test, and run
  commands as the conversation naturally progresses. A separate mode approval
  is not required for each task.
- `readonly`: an optional deliberate lock exposing nine inspection, Git-review,
  and window-observation tools, with no file mutation or command execution.

The preset is a coarse connection-level lock, not a per-action confirmation
system or an operating-system sandbox. The control menu automatically stops and
restarts an active tunnel when changing the lock. Most users should leave it on
`workstation`.

## Runtime behavior

- Nothing is registered to start with Windows.
- After a reboot, the tunnel remains stopped until the user starts it manually.
- While running, an unexpected tunnel exit is retried after bounded delays by a
  same-profile supervisor.
- A deliberate Stop records intent before terminating the tunnel so recovery
  cannot race the user's request.
- Active connection-owned PowerShell jobs are cancelled when that exact MCP
  connection closes. Completed evidence remains inspectable after reconnect.
- Arbitrary PowerShell jobs are serialized only within the same detected
  workspace across profiles. The nearest Git root is preferred, followed by the
  registered project root and then the exact working directory. Unrelated
  workspaces and direct read/search tools remain concurrent.
- Commands are never replayed automatically.
- `workstation_context` reports `transport: "stdio"`, `buildRevision`, and
  `toolSchemaRevision` so a running build and tool contract can be identified.
- `project_resume` accepts an optional path and runs fixed read-only Git
  commands there. It permits unrelated worktrees but still rejects another
  registered profile and protected direct-file locations.
- Managed worktree tools operate only on the current registered profile root.
  Paths and IDs are deterministic, repeated creation is idempotent by branch,
  clean removal preserves the branch, and dirty removal is refused.
- Multi-profile lifecycle actions retain each profile's existing operation
  lock. Registry updates are serialized, preserve existing entries, reject
  duplicate ports and overlapping roots, and are committed with rollback.

## Commands

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File scripts\Install.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File scripts\Configure-Tunnel.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File scripts\Doctor.ps1 -Online
powershell.exe -NoProfile -ExecutionPolicy Bypass -File scripts\Manage-Window-Grants.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File scripts\Set-Permission-Preset.ps1 -PermissionPreset readonly
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File scripts\ControlCenter.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File scripts\Control.ps1 -Action start
powershell.exe -NoProfile -ExecutionPolicy Bypass -File scripts\Control.ps1 -Action status
powershell.exe -NoProfile -ExecutionPolicy Bypass -File scripts\Control.ps1 -Action stop
powershell.exe -NoProfile -ExecutionPolicy Bypass -File scripts\Control.ps1 -Action status-all
powershell.exe -NoProfile -ExecutionPolicy Bypass -File scripts\Control.ps1 -Action start-all
powershell.exe -NoProfile -ExecutionPolicy Bypass -File scripts\Control.ps1 -Action stop-all
```

Advanced users can add another profile without replacing existing registry
entries. Use a distinct root, ID, metadata port, and tunnel:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File scripts\Install.ps1 `
  -WorkspaceRoot "$env:USERPROFILE\Hybrid Workstation Art" `
  -ProfileId art-workstation -DisplayName "Art Workstation" -HttpPort 2099 `
  -SkipTunnelDownload -NoDesktopShortcut
powershell.exe -NoProfile -ExecutionPolicy Bypass -File scripts\Configure-Tunnel.ps1 `
  -ProfileId art-workstation
```

Local development:

```powershell
npm.cmd ci
npm.cmd run check
npm.cmd run security:audit
npm.cmd run build:native
npm.cmd run smoke:native-shell
npm.cmd run smoke:stdio
npm.cmd run release
```

## What is intentionally not included

- Personal project profiles or absolute user paths
- API keys, tunnel YAML, grants, logs, runtime state, or browser data
- Browser control, desktop UI clicking or typing, or specialized application
  workers
- A Windows service, scheduled task, or startup item
- Automatic software installation or privilege elevation

See [SECURITY.md](SECURITY.md) before enabling the shell tools, and
[docs/ADDING_PROFILES.md](docs/ADDING_PROFILES.md) before extending the registry.

## License

Hybrid Workstation MCP is released under the
[MIT No Attribution License (MIT-0)](LICENSE).
