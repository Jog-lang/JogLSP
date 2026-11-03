# Jog for VS Code and Cursor

Syntax highlighting for `.jog` files, and diagnostics from the Jog language server on save.

The client starts `bin/server` (or `bin/server.exe` on Windows) when this extension is installed, or `server/out/server` when it is running from the JogLSP checkout. That server runs `jog check --diag=json`.

Settings:

- `jog.serverPath` — language server executable
- `jog.compilerPath` — `jog` / `jogc` binary (else `JOG`, else `~/.local/bin/jog`)

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
