# Agents

This repo is the Jog language server, written in Jog. Target P2 in JogDocs `bootstrap/Roadmap.md`: a diagnostics-only server.

The Jog notes live in JogDocs, at `D:/Projects/Jog/JogDocs` ([github.com/Jog-lang/JogDocs](https://github.com/Jog-lang/JogDocs)). Read its `AGENTS.md`, then `guide/JogQuickRef.md`, before writing or reviewing Jog. This project's note is `projects/JogLSP.md`. Log every Jog rough edge in JogDocs `bootstrap/Friction.md`. `notes/` here only points to JogDocs.

Ivan writes the Jog server himself. Do not rewrite it unasked, and do not reimplement the compiler here.

The compiler command is `jog`. The local binary is `D:/Projects/Jog/JogCompiler/build/jog.exe`, and `JOG` wins when it is set. Std is found relative to that compiler. Diagnostics come from `jog check --diag=json`: one JSON object per line, with `file`, `line`, `column`, `severity`, and `message`. Text is the default. On save the server checks the file on disk and passes no `--module` flags.

A panic in a test is `t.expectPanic(() -> { ... })`. Packages already used by the server include `std/list`, `std/map`, `std/strbuilder`, `std/os`, `std/fs`, and `std/proc`.

The server is `server/`. The editor extension is `editors/vscode/`. Do not generate or rewrite the server sources.

Read JogDocs `bootstrap/study/LSP.md`, and use the P2 boxes in JogDocs `bootstrap/Checks.md`.
