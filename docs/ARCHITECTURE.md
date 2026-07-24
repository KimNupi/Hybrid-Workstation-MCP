# Architecture

```text
ChatGPT developer-mode app
        |
OpenAI Secure MCP Tunnel endpoint
        |
tunnel-client (outbound HTTPS, manual start)
        |
stdio: node dist/stdio.js --profile workstation
        |
profile registry + profile SHA-256 + identity marker + permission preset
        |
permission-filtered filesystem / Git resume / PowerShell tools
```

The engine and generated runtime state are separate. The engine lives in this
repository. The ignored `runtime/` directory holds the installed tunnel binary,
registry, protected credential, downloads, and file leases. The default profile
root lives under the user's home and owns its policy, profile JSON, tunnel YAML,
and operational logs.

The registry supports multiple non-overlapping profile roots. Each profile hash
is pinned. A selected profile cannot use direct filesystem or shell tools inside
another registered profile's root. The profile permission preset determines
whether the server registers six read-only tools or the full twelve-tool
workstation surface.
