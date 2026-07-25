# Hybrid Workstation

This small repository is the operating root for a general-purpose workstation
MCP profile. Relative paths begin here. Absolute paths may reach other locations
available to the current Windows account, except roots assigned to another
registered profile. The permission preset selects either read-only inspection
or the normal full workstation surface.

Application-window observation remains separately opt-in. The local control
menu can create a one-time exact process grant or an exact executable-and-title
trusted rule that rebinds only to one unambiguous live window. ChatGPT receives
only opaque references and can list or capture those windows; it cannot
enumerate ungranted desktop windows or control the UI.

Runtime state and logs are written under `artifacts/chatgpt-hybrid-mcp/` and
the local tunnel profile is stored under `tools/chatgpt-hybrid-mcp/`. Those
files are intentionally ignored by Git.
