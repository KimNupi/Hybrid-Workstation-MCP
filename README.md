# Hybrid Workstation MCP

A Windows package that connects one general-purpose local workstation profile
to a ChatGPT developer-mode app through OpenAI Secure MCP Tunnel.

The package exposes bounded tools for bootstrap context, Git resume snapshots,
directory and text search, text and image reads, explicitly granted application
window observation, SHA-guarded UTF-8 writes, and asynchronous PowerShell jobs
with status, output, and cancellation.

## Release status

Version 1.3 adds optional trusted-app observation rules. A local user may keep
a one-time exact process grant or register an exact executable path plus a stable
window-title substring. After an application restart, ChatGPT auto-rebinds only
when exactly one live window matches and no rule from another profile claims the
same window. Ambiguous or colliding matches fail closed. Windows Graphics Capture
remains the primary GPU-aware backend with target-only `PrintWindow` fallback,
and the package still provides no UI clicking or text input.

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
Windows account. Windows ACLs and UAC remain the real machine boundary.

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

- `workstation` (default): normal operation with all fourteen tools. ChatGPT can
  inspect, observe granted windows, edit, build, test, and run commands as the
  conversation naturally progresses. A separate mode approval is not required
  for each task.
- `readonly`: an optional deliberate lock exposing eight inspection and window-
  observation tools, with no file mutation or command execution.

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
- Commands are never replayed automatically.

## Commands

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File scripts\Install.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File scripts\Configure-Tunnel.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File scripts\Doctor.ps1 -Online
powershell.exe -NoProfile -ExecutionPolicy Bypass -File scripts\Manage-Window-Grants.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File scripts\Set-Permission-Preset.ps1 -PermissionPreset readonly
powershell.exe -NoProfile -ExecutionPolicy Bypass -File scripts\Control.ps1 -Action start
powershell.exe -NoProfile -ExecutionPolicy Bypass -File scripts\Control.ps1 -Action status
powershell.exe -NoProfile -ExecutionPolicy Bypass -File scripts\Control.ps1 -Action stop
```

Local development:

```powershell
npm.cmd ci
npm.cmd run check
npm.cmd run build:native
npm.cmd run smoke:stdio -- workstation
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
