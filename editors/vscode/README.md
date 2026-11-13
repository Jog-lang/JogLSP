# Jog for VS Code and Cursor (v2)

Syntax highlighting for `.jog` files, and language-server features from JogLSP **v2**: diagnostics via `jog check --diag=json`, hover, go-to-definition, and completion (including post-concurrency builtins).

The client starts `bin/server` (or `bin/server.exe` on Windows) when this extension is installed, or `server/zig-out/bin/server` when running from the JogLSP checkout. Build the Zig server (`cd server && zig build`) against JogCompiler v2.

Settings:

- `jog.serverPath` — language server executable
- `jog.compilerPath` — JogCompiler v2 `jog` / `jog-v2` (else `JOG`, else `~/.local/bin/jog-v2`, else sibling checkout)

## Features

- **Diagnostics** — `didOpen` / `didChange` / `didSave` → `jog check --diag=json` on a temp copy of the buffer
- **Hover** — local decls; concurrency builtins (`go`, `yield`, `with`, `Dispatcher`, `dispatcher_io`, …)
- **Go to definition** — buffer-local decls (builtins have no source location)
- **Completion** — concurrency APIs + top-level names in the open buffer
- **Syntax** — TextMate keywords include `go` / `yield` / `with`; support scopes for `Dispatcher` and dispatcher/coro helpers

## Install (Linux / Cursor)

```
cd ../../server && zig build && cp zig-out/bin/server ../editors/vscode/bin/server
cd ../editors/vscode
npm install
npx @vscode/vsce package --allow-missing-repository
cursor --install-extension jog-0.0.1.vsix --force
```

Set `JOG` or `jog.compilerPath` to your v2 `jog`. Reload the window after installing.
