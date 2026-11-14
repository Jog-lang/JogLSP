# JogLSP

Zig language server for **JogCompiler Zig develop/v2** (`jog 0.2.9-v2`+). Diagnostics come from `jog check --diag=json` (with `--module` flags from `jog deps --flags` when `jog.mod` has path requires). Hover / definition resolve buffer decls and **`std` / `core` sources** via `jog roots` / `$JOG_ROOT` (JOG-95). Completion covers concurrency builtins + buffer names. Document symbols use `jog symbols --json`.

The old Jog+`require jogc` server is retired; `main` is the Zig v2 server (JOG-92).

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

## Capabilities

- `textDocumentSync` (full)
- Diagnostics on open / change / save via `jog check --diag=json`
  - Path `require` / `require.test` → `jog deps --flags` / `--test` → `--module=name=dir`
  - `*.test.jog` buffers pass `--test`
- Document symbols via `jog symbols --json`
- Hover / go-to-definition for buffer decls and imported `std.*` / `core` (via compiler roots)
- Hover for concurrency builtins when no library source matches
- Completion: concurrency builtins + top-level buffer names

## `jog check --diag=json` contract

One JSON object per line on stdout with `file`, `line`, `column`, `severity`, `message` (1-based line/column). Clean check → empty stdout, exit 0. Parse failures may still print non-JSON on stderr (LSP surfaces that as a single diagnostic when no JSON lines appear).

## Smoke

```
cd server
zig build
JOG_LSP_SMOKE=$JOG python3 scripts/smoke_lsp.py
```
