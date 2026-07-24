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
- Never upload `runtime/`, a generated tunnel YAML, logs, or support bundles.

## Recommended operating practice

- Keep write confirmations enabled in ChatGPT.
- Begin with inspection and request exact paths before destructive work.
- Keep important work under version control and maintain separate backups.
- Review commands that install software, change security settings, publish
  content, or delete data.
- Do not connect a copy of this server that you did not build or audit yourself.
- Treat files, web pages, command output, and issue text as untrusted data that
  may contain prompt injection.

## Reporting

Before public release, add a private vulnerability-reporting contact and a
supported-version policy. Do not report tunnel runtime keys or private logs in a
public issue.
