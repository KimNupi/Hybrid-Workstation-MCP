# Hybrid Workstation MCP Starter

A Windows starter that connects one general-purpose local workstation profile
to a ChatGPT developer-mode app through OpenAI Secure MCP Tunnel.

The starter exposes twelve bounded MCP tools for bootstrap context, Git resume
snapshots, directory and text search, text and image reads, SHA-guarded UTF-8
writes, and asynchronous PowerShell jobs with status, output, and cancellation.

## Preview status

This repository is a local distribution candidate. Its source, tests, setup
flow, and release package are being prepared for clean-machine validation.
No public redistribution license has been selected yet. Do not publish this
repository publicly until that decision and the third-party license review are
complete.

## Requirements

- Windows 10 or 11 on x64
- Node.js 20 or newer
- Git for Windows
- ripgrep (`rg.exe`)
- A ChatGPT account or workspace allowed to use Developer mode
- An OpenAI Platform tunnel with a `tunnel_id` and runtime API key

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
powershell.exe -NoProfile -ExecutionPolicy Bypass -File scripts\Control.ps1 -Action start
powershell.exe -NoProfile -ExecutionPolicy Bypass -File scripts\Control.ps1 -Action status
powershell.exe -NoProfile -ExecutionPolicy Bypass -File scripts\Control.ps1 -Action stop
```

Local development:

```powershell
npm.cmd ci
npm.cmd run check
npm.cmd run smoke:stdio -- workstation
```

## What is intentionally not included

- Personal project profiles or absolute user paths
- API keys, tunnel YAML, logs, runtime state, or browser data
- Browser control, desktop UI automation, or specialized application workers
- A Windows service, scheduled task, or startup item
- Automatic software installation or privilege elevation

See [SECURITY.md](SECURITY.md) before enabling the shell tools, and
[docs/ADDING_PROFILES.md](docs/ADDING_PROFILES.md) before extending the registry.
