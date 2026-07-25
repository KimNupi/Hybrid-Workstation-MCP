# Hybrid Workstation

This small repository is the operating root for a general-purpose workstation
MCP profile. Relative paths begin here. Absolute paths may reach other locations
available to the current Windows account, except roots assigned to another
registered profile. The permission preset selects either read-only inspection
or the normal full workstation surface.

Application-window observation remains separately opt-in. The local control
menu can grant one exact currently open window. ChatGPT receives only an opaque
reference and can list or capture that exact live window; it cannot enumerate
ungranted desktop windows or control the UI.

Runtime state and logs are written under `artifacts/chatgpt-hybrid-mcp/` and
the local tunnel profile is stored under `tools/chatgpt-hybrid-mcp/`. Those
files are intentionally ignored by Git.
