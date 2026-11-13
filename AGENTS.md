# Agents (JogLSP v2)

- Branch `v2`: Zig `server/` talking to JogCompiler v2 (post-concurrency). Do not merge the Jog+jogc server into it.
- Build: `cd server && zig build`. Install `zig-out/bin/server` into `editors/vscode/bin/server`.
- Compiler: argv[1] or `JOG` / `jog-v2` / sibling `JogCompiler-v2` / PATH.
- Gate: server starts, `initialize` succeeds, opening a `.jog` file publishes diagnostics from `jog check --diag=json`; hover/completion know `go`/`yield`/`Dispatcher`/`dispatcher_*`.
- Do not start JogSDL/Emscripten from this repo.
