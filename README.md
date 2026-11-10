# JogLSP (v2)

Zig language server for **JogCompiler v2**. Diagnostics come from `jog check --diag=json` (no in-process jogc frontend).

v1 (Jog server + `require jogc`) stays on `main` and older branches.

## Build server

```
export JOG=~/.local/bin/jog-v2   # or JogCompiler-v2/zig-out/bin/jog
cd server
zig build
cp zig-out/bin/server ../editors/vscode/bin/server
```

## Editor

```
cd editors/vscode
npm install
# ensure bin/server exists (copied above)
npx @vscode/vsce package --allow-missing-repository
cursor --install-extension jog-0.0.1.vsix --force
```

Settings: `jog.compilerPath` → v2 `jog` (or `jog-v2`). The client still passes that path as argv[1] and sets `JOG`.

## Capabilities (v2 MVP)

- `textDocumentSync` (full)
- Diagnostics on open / change / save via `jog check --diag=json`

Hover, definition, completion, and jog-build `--module` deps are deferred until the v2 compiler exposes them.
