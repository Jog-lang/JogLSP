# Agents (JogLSP)

- `main` is the Zig v2 server (JOG-92). Do not revive the Jog+jogc in-process server.
- Build: `cd server && zig build`. Install `zig-out/bin/server` into `editors/vscode/bin/server`.
- Compiler: argv[1] or `JOG` / `jog-v2` / sibling `JogCompiler-v2` / PATH (`jog 0.2.8-v2`+ for locations, `--module`, `symbols`).
- Gate: `initialize` succeeds; opening a `.jog` publishes diagnostics from `jog check --diag=json`; hover/completion know `go`/`yield`/`Dispatcher`/`dispatcher_*`; `documentSymbol` works via `jog symbols --json`.
- Do not start JogSDL/Emscripten from this repo.
