# Adding profiles

Hybrid Workstation MCP installs one `workstation` profile. Advanced users may add another
profile later, but should preserve these invariants:

1. Store the profile at `<root>\tools\chatgpt-hybrid-mcp\profile.json`.
2. Give every profile a unique lowercase ID and unique HTTP metadata port.
3. Set `permissionPreset` to `readonly` or `workstation`. Profiles without the
   field retain the normal `workstation` behavior.
4. Include at least one bounded identity marker inside that root.
5. Hash the exact UTF-8 profile bytes with SHA-256.
6. Add the absolute profile path and hash to `runtime\profile_registry.json`.
7. Keep registered roots distinct and non-overlapping.
8. Generate a separate tunnel profile and runtime directory.
9. Run tests and `scripts\Doctor.ps1` before connecting it in ChatGPT.

The first public release should add a dedicated profile-creation command before
multi-profile setup is advertised as a beginner workflow.
