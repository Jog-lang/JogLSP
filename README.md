# JogLSP

Zig language server for **JogCompiler Zig develop/v2** (`jog 0.2.11-v2`+). Diagnostics come from `jog check --diag=json` (with `--module` flags from `jog deps --flags` when `jog.mod` has path requires). Hover, definition, completion, references, signature help, rename, and workspace symbols go through **`jog ide`** over the same load graph (siblings, std/core, `.jog-lsp-tmp`). Concurrency builtins remain as a fallback when the compiler has no source.

The old Jog+`require jogc` server is retired; `main` is the Zig v2 server (JOG-92).

## Build server

```
export JOG=~/.local/bin/jog-v2   # or JogCompiler-v2/zig-out/bin/jog
cd server
zig build
cp zig-out/bin/server ../editors/vscode/bin/server
```

Discovery order when argv[1] / `JOG` unset: `~/.local/bin/jog-v2`, sibling `../JogCompiler-v2` or `../jogcompiler`, then PATH `jog-v2` / v2 `jog`.

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

- `textDocumentSync` (full); diagnostics on open / save immediately, **debounced** on `didChange`
- Diagnostics via `jog check --diag=json` (maps `end_line`/`end_column` + `severity` when present)
  - Path `require` / `require.test` → `jog deps --flags` / `--test` → `--module=name=dir`
  - `*.test.jog` buffers pass `--test`
- Document symbols via `jog symbols --json`
- Hover / definition / completion / references via `jog ide …`
- Signature help via callable hover at `(`
- Rename / prepareRename via `jog ide references` + `WorkspaceEdit`
- Workspace symbols via `jog ide symbols`
- Builtin hover/completion fallback for concurrency intrinsics without source

## `jog ide` / diag contracts

See JogCompiler Phase 1 result / `jog help`. Position flags are 1-based; LSP uses 0-based and converts.

## Smoke

```
cd server
zig build
JOG_LSP_SMOKE=$JOG JOG_ROOT=<JogCompiler-v2-or-jogcompiler> python3 scripts/smoke_lsp.py
```
