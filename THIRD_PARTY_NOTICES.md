# Third-party notices

Hybrid Workstation MCP does not vendor npm dependency source code in Git.
`npm ci` installs the versions pinned by `package-lock.json`.

| Component | Version | License |
|---|---:|---|
| `@modelcontextprotocol/sdk` | 1.29.0 | MIT |
| `zod` | 4.4.3 | MIT |
| `typescript` | 7.0.2 | Apache-2.0 |
| `vitest` | 4.1.10 | MIT |
| `@vitest/coverage-v8` | 4.1.10 | MIT |
| `@biomejs/biome` | 2.5.5 | MIT or Apache-2.0 |
| `@types/node` | 24.13.3 | MIT |
| OpenAI `tunnel-client` | 0.0.10 | Apache-2.0 |
| .NET runtime components linked into `HybridWindowCapture.exe` | 10.0.x | MIT |
| Microsoft Windows SDK for .NET targeting pack | 10.0.19041.57 | Microsoft Windows SDK license |

The installer downloads the pinned official Windows x64 `tunnel-client`
release from `openai/tunnel-client` and verifies both its release archive and
executable SHA-256 before installation.

The release builder compiles the window-capture source with .NET NativeAOT into
a self-contained x64 executable and ships a separate SHA-256 file. The Windows
SDK targeting pack is used at build time; Windows system capture and Direct3D
APIs are provided by the user's operating system. Review the upstream license
texts and dependency graph whenever dependencies or SDK versions are updated.
