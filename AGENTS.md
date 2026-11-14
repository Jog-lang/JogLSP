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

- `main` is the Zig v2 server (JOG-92). Do not revive the Jog+jogc in-process server.
- Build: `cd server && zig build`. Install `zig-out/bin/server` into `editors/vscode/bin/server`.
- Compiler: argv[1] or `JOG` / `jog-v2` / sibling `JogCompiler-v2` / PATH (`jog 0.2.8-v2`+ for locations, `--module`, `symbols`).
- Gate: `initialize` succeeds; opening a `.jog` publishes diagnostics from `jog check --diag=json`; hover/completion know `go`/`yield`/`Dispatcher`/`dispatcher_*`; `documentSymbol` works via `jog symbols --json`.
- Ivan writes the server by hand. Do not rewrite it unasked; do not reimplement the compiler here.
- Do not start JogSDL/Emscripten from this repo.
