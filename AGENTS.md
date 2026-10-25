# Agents

This repo is the Jog language server, written in Jog. Target P2 in `notes/Roadmap.md`: a diagnostics-only server.

Ivan writes the Jog server himself. Do not rewrite it unasked, and do not reimplement the compiler here.

Compiler and std stay in `D:/Projects/CTools`. The binary is `D:/Projects/CTools/build/jog.exe`, and std is found relative to that compiler. Diagnostics come from `jog check --diag=json`: one JSON object per line, with `file`, `line`, `column`, `severity`, and `message`. Text is the default.

A panic in a test is `t.expectPanic(() -> { ... })`. Packages already used by a server include `std/list`, `std/map`, `std/strbuilder`, `std/os`, `std/fs`, and `std/proc`.

Suggested layout, not created: `server/` for the Jog sources, and `editors/vscode/` for the extension later. Do not generate the server sources.

Read `notes/study/LSP.md`, and use the P2 boxes in `notes/Checks.md`.
