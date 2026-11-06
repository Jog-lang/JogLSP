# Jog for VS Code and Cursor

Syntax highlighting for `.jog` files, and language-server features from JogLSP: diagnostics on open/change/save, document symbols, hover, go to definition, and completion.

The client starts `bin/server` (or `bin/server.exe` on Windows) when this extension is installed, or `server/out/server` when it is running from the JogLSP checkout. The server loads the JogCompiler **develop** frontend in-process (`require jogc`); it no longer spawns `jog check` for diagnostics. Build the server against a develop checkout (`jog-build build -o out/server` from `server/`, with `JOG_ROOT` pointing at JogCompiler develop). Rebuild after compiler `jog.mod` changes (for example `require.test` / `libdir`) so the embedded frontend stays current.

Settings:

- `jog.serverPath` — language server executable
- `jog.compilerPath` — seed `jog` binary used to build/run tools and resolve `jog-build` (else `JOG`, else `~/.local/bin/jog`)

## Features (P4)

- **Diagnostics** — published on `didOpen`, `didChange`, and `didSave` from an in-process load+check (open buffers override disk).
- **Document symbols** — top-level declarations (functions, types, bindings).
- **Hover** — type and declaration site when known; empty on unknown/error nodes.
- **Go to definition** — across files and packages, including std.
- **Completion** — names in scope; fields/methods after `.` (incomplete tokens still complete).

## Install (Linux / Cursor)

From this directory, with `server/out/server` already built:

```
npm install
cp ../../server/out/server bin/server
npx @vscode/vsce package --allow-missing-repository
cursor --install-extension jog-0.0.1.vsix --force
```

Set `JOG` to your seed `jog` (or set `jog.compilerPath`). Reload the window after installing.

## Verify P2 editor boxes

```
JOG=~/.local/bin/jog node verify-p2.js
```

That script checks the TextMate grammar contribution, language configuration (comments / brackets / auto-close), save-time diagnostics that clear on a fixed save, and clean `shutdown`/`exit` with no leftover server pid.
