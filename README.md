# JogLSP (v2)

Zig language server for **JogCompiler v2** (post-concurrency: Gates 1–4 + Chase-Lev). Diagnostics come from `jog check --diag=json` (contract unchanged). Hover / definition / completion cover buffer decls plus concurrency builtins (`go`, `yield`, `with (Dispatcher)`, `dispatcher_io`, spawn/pool APIs).

v1 (Jog server + `require jogc`) stays on `main` and older branches.

## Build server

```
export JOG=~/.local/bin/jog-v2   # or JogCompiler-v2/zig-out/bin/jog
cd server
zig build
cp zig-out/bin/server ../editors/vscode/bin/server
```

Discovery order when argv[1] / `JOG` unset: `~/.local/bin/jog-v2`, sibling `../JogCompiler-v2/zig-out/bin/jog`, then PATH `jog-v2` / v2 `jog`.

## Editor

```
cd editors/vscode
npm install
# ensure bin/server exists (copied above)
npx @vscode/vsce package --allow-missing-repository
cursor --install-extension jog-0.0.1.vsix --force
```

Settings: `jog.compilerPath` → v2 `jog` (or `jog-v2`). The client still passes that path as argv[1] and sets `JOG`.

## Capabilities (v2)

- `textDocumentSync` (full)
- Diagnostics on open / change / save via `jog check --diag=json`
- Hover / go-to-definition for buffer decls; hover for concurrency builtins
- Completion: concurrency builtins + top-level buffer names

## `jog check --diag=json` contract

Unchanged: one JSON object per line on stdout with `file`, `line`, `column`, `severity`, `message` (1-based line/column). Clean check → empty stdout, exit 0. Parse failures may still print non-JSON on stderr (LSP surfaces that as a single diagnostic when no JSON lines appear).
