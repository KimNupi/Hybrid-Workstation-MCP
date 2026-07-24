# Third-party notices

Hybrid Workstation MCP does not vendor npm dependency source code in Git. `npm ci` installs
the versions pinned by `package-lock.json`.

| Component | Version | License |
|---|---:|---|
| `@modelcontextprotocol/sdk` | 1.29.0 | MIT |
| `zod` | 4.4.3 | MIT |
| `typescript` | 7.0.2 | Apache-2.0 |
| `vitest` | 4.1.10 | MIT |
| `@types/node` | 24.13.3 | MIT |
| OpenAI `tunnel-client` | 0.0.10 | Apache-2.0 |

The installer downloads the pinned official Windows x64 `tunnel-client`
release from `openai/tunnel-client` and verifies both its release archive and
executable SHA-256 before installation. Review the upstream license texts and
dependency graph again before a public release.
