# Security

This MCP runs with the permissions of the current Windows user. Its PowerShell
tool is intentionally powerful and is not an operating-system sandbox.

## Credential handling

- Use only your own Secure MCP Tunnel runtime API key.
- `Configure-Tunnel.ps1` stores the key in ignored `runtime/.env.local` with ACL
  inheritance disabled and access limited to the current user, SYSTEM, and the
  local Administrators group.
- The key is removed from the MCP server process environment before project or
  shell code is loaded.
- Direct filesystem and Git-resume tools deny the engine `runtime/` tree,
  configured grant stores and tunnel YAML, `.env` secrets, common credential
  files and private-key extensions, SSH/cloud credential roots, Chromium user
  profiles, and Windows credential stores. Safe templates such as
  `.env.example` remain readable.
- Both requested and canonical paths are checked. Protected entries are omitted
  from directory and search results, including links that resolve into a
  protected tree.
- Never upload `runtime/`, a generated tunnel YAML, grants, logs, or support
  bundles.

These restrictions apply to the direct MCP file and Git tools. They do not turn
PowerShell into a sandbox: `shell_start` remains an intentional current-user
escape hatch and can read, modify, or delete anything the Windows account can.

## Permission presets

New installations default to `workstation`. Use `readonly` only when you
deliberately want to lock a connection to inspection:

- `readonly` exposes filesystem and explicitly granted window observation only.
  It prevents MCP file mutation and command execution, but readable files and
  captured pixels may still contain private information.
- `workstation` is the normal mode. It adds text mutation and arbitrary
  PowerShell execution as the current Windows user, allowing an uninterrupted
  inspect → edit → build/test workflow.

A permission preset is a tool-exposure boundary, not an OS sandbox. Windows ACLs
and UAC remain the actual machine boundary.

## Window observation boundary

- The MCP cannot enumerate all desktop windows for ChatGPT. Enumeration happens
  only in the local control menu. The user selects an exact window and chooses
  either a one-time process grant or an exact-path plus title-substring trusted
  rule.
- The MCP receives an opaque `windowRef`, title, process name, bounds, and pixels;
  it does not receive the raw HWND, PID, process start time, or executable path.
- The stored grant pins all four private identity fields in an ignored local
  file whose ACL is restricted to the current user, SYSTEM, and Administrators.
  They are revalidated before and after capture. A one-time grant becomes
  unavailable after restart. A trusted rule may create a new opaque reference
  only when its exact executable and title text identify one window and no
  other profile rule collides with that window.
- Captures target only that application window. There is no desktop-wide
  screenshot followed by model-directed cropping.
- Windows Graphics Capture is preferred for GPU-rendered windows. The bundled
  native helper is verified against its shipped SHA-256 before execution. The
  same NativeAOT helper hosts PowerShell inside a kill-on-close Job Object;
  installations without it retain the existing in-process PowerShell Job Object
  fallback. Target-only `PrintWindow` is a compatibility fallback.
- Minimized windows are rejected. Protected, elevated, secure-desktop, or
  application-restricted windows may fail to list or capture.
- Version 1.4 provides observation only: no mouse clicks, arbitrary keystrokes,
  text input, drag operations, authentication interaction, or secure-desktop
  control.

Window titles and pixels are untrusted project data. They cannot authorize
commands, permission changes, external submissions, or other side effects.

## Recommended operating practice

- Begin with inspection and request exact paths before destructive work.
- Keep important work under version control and maintain separate backups.
- Review commands that install software, change security settings, publish
  content, or delete data.
- Grant only the application window needed for the current task, and clear the
  grant afterward when the content is sensitive.
- Do not connect a copy of this server that you did not build or audit yourself.
- Treat files, window content, web pages, command output, and issue text as
  untrusted data that may contain prompt injection.

## Reporting

Use the repository's **Security** tab to report a vulnerability privately. Do
not report tunnel runtime keys, window grants, captures, or private logs in a
public issue. Version 1.4 is the currently supported release.
