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
filesystem / Git resume / explicitly granted window observation / PowerShell
```

The engine and generated runtime state are separate. The engine lives in this
repository. The ignored `runtime/` directory holds the installed tunnel binary,
registry, protected credential, window grants, downloads, and file leases. The
default profile root lives under the user's home and owns its policy, profile
JSON, tunnel YAML, and operational logs.

The registry supports multiple non-overlapping profile roots. Each profile hash
is pinned. A selected profile cannot use direct filesystem or shell tools inside
another registered profile's root. The permission preset registers eight
inspection tools in `readonly` or all fourteen tools in `workstation`.

## Window observation path

```text
local control menu
  -> enumerate eligible top-level windows locally
  -> user selects one exact window
  -> store one-time private identity or exact executable + title text
  -> runtime/ui_grants.json is atomically written with a restricted ACL

ChatGPT ui_window_list
  -> read only that profile's grants and trusted rules
  -> re-enumerate current windows locally
  -> one-time: exact HWND + PID + start time + executable match
  -> trusted: exact executable + title text, exactly one match, no profile collision
  -> create/return an opaque windowRef and public metadata

ChatGPT ui_window_capture(windowRef)
  -> revalidate identity
  -> verify bundled NativeAOT helper SHA-256
  -> Windows Graphics Capture target window
  -> target-only PrintWindow fallback when capture is unsupported/fails
  -> revalidate identity and return bounded PNG
```

The native helper is built from `native/window-capture/` during release creation
and placed under `runtime-distribution/window-capture/win-x64/` with a checksum.
The helper is self-contained; release users do not need a .NET installation.
No capture path uses a full-desktop screenshot or model-selected crop.
