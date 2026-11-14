# Agents (JogLSP)

## Jog knowledge

- Jog language notes, plans, checklists and the friction log live in JogDocs:
  Fedora `~/Documents/Projects/Jog/JogDocs` (or `/home/plague_doc/Documents/Projects/Jog/JogDocs`);
  Windows `D:/Projects/Jog/JogDocs`
  (https://github.com/Jog-lang/JogDocs).
- Read JogDocs `AGENTS.md` first, then `guide/JogQuickRef.md` before writing or reviewing Jog.
- Agent skills canon: JogDocs `.agents/skills/` (pointer: `.agents/skills/README.md` here). See `guide/UsingJogDocs.md`.
- Log rough edges in JogDocs `bootstrap/Friction.md`. Project note: `projects/JogLSP.md`.

## This repo

- `main` is the Zig server for JogCompiler Zig **`develop`** / v2 (JOG-92, JOG-95). Do not revive the Jog+jogc in-process server.
- Build: `cd server && zig build`. Install `zig-out/bin/server` into `editors/vscode/bin/server`.
- Compiler: argv[1] or `JOG` / `jog-v2` / sibling `JogCompiler-v2` / PATH (`jog 0.2.9-v2`+ for roots, locations, `--module`, `symbols`).
- Library goto: hover / definition resolve into `std` / `core` via `jog roots` or `$JOG_ROOT`.
- Gate: `initialize` succeeds; opening a `.jog` publishes diagnostics from `jog check --diag=json`; hover/completion know `go`/`yield`/`Dispatcher`/`dispatcher_*`; `documentSymbol` works via `jog symbols --json`; `JOG_LSP_SMOKE` smoke covers std.math goto when examples exist.
- Ivan writes Jog feature bodies by hand. Zig LSP wiring for compiler contracts is in scope when assigned.
- Do not start JogSDL/Emscripten from this repo.
