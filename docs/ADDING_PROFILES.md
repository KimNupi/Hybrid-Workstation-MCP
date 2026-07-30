# Adding profiles

Hybrid Workstation MCP installs one `workstation` profile. Advanced users may
add another profile with the same installer; existing registry entries are
preserved:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File scripts\Install.ps1 `
  -WorkspaceRoot "$env:USERPROFILE\Hybrid Workstation Art" `
  -ProfileId art-workstation `
  -DisplayName "Art Workstation" `
  -HttpPort 2099 `
  -SkipTunnelDownload `
  -NoDesktopShortcut

powershell.exe -NoProfile -ExecutionPolicy Bypass -File scripts\Configure-Tunnel.ps1 `
  -ProfileId art-workstation
```

Preserve these invariants:

1. Store the profile at `<root>\tools\chatgpt-hybrid-mcp\profile.json`.
2. Give every profile a unique lowercase ID and unique HTTP metadata port.
3. Set `permissionPreset` to `readonly` or `workstation`. Profiles without the
   field retain the normal `workstation` behavior.
4. Include at least one bounded identity marker inside that root.
5. Let `Install.ps1` hash the exact UTF-8 profile and merge it into
   `runtime\profile_registry.json`; do not edit a live registry by hand.
6. Keep registered roots distinct and non-overlapping.
7. Generate a separate tunnel profile and runtime directory.
8. Run tests and `scripts\Doctor.ps1` before connecting it in ChatGPT.

When more than one profile is registered, the Control Center automatically
shows a profile selector and whole-registry controls. `start-all` skips profiles
that are already active or recovering and starts the remainder with a maximum
concurrency of three. Status checks use at most four workers. Individual
failures remain profile-scoped and do not hide successful results.

This remains an advanced workflow: each profile needs its own OpenAI tunnel ID
and must be connected as its own developer-mode app. The runtime API key remains
in the shared protected local credential file and is never displayed by the
Control Center.
