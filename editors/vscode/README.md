# Jog for VS Code and Cursor

Syntax highlighting for `.jog` files, and diagnostics from the Jog language server on save.

The client starts `bin/server.exe` when this extension is installed, or `server/out/server.exe` when it is running from the JogLSP checkout. That server runs `jog check --diag=json`.

Settings:

- `jog.serverPath` — language server executable
- `jog.compilerPath` — `jog.exe`
