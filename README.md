# JogLSP

A diagnostics-only language server for Jog. The server is written in Jog. It speaks Language Server Protocol messages over stdin and stdout, and on save it runs `jog check --diag=json`.

The compiler command is `jog`. On this machine the binary is `D:\Projects\Jog\JogCompiler\build\jog.exe`. When `JOG` is set, that path is the compiler. Standard library packages are found relative to the binary.

## Start here

The design notes live in JogDocs, at `D:/Projects/Jog/JogDocs` ([github.com/Jog-lang/JogDocs](https://github.com/Jog-lang/JogDocs)), not in this repo:

- `AGENTS.md` and `guide/JogQuickRef.md`: how the notes are organized, and what V1 compiles.
- `projects/JogLSP.md`: this project's note.
- `bootstrap/study/LSP.md`: the protocol, framing, and positions.
- `bootstrap/Checks.md`, section P2: the checklist for this server.

`notes/README.md` here only points to those files.

## Server

`server/jog.mod` marks the module root. `server/main.jog` is the root package and starts `src.serve`. The server itself is the `src` package. The loader always builds that root, so the commands below are run from `server/` with no package argument.

From `server/`:

```
jog test
jog build
```

`jog build` writes `server/out/server.exe`. `jog test` writes that same path, so build again after a test run when you want the server rather than the test runner. The process reads framed messages from stdin and writes them to stdout. Logs go to stderr. On Windows the server sets stdin and stdout to binary mode so `Content-Length` counts bytes.

Diagnostics use the in-process JogCompiler **develop** frontend (`frontend.analyze`). When that module’s `jog.mod` has `require` / `require.test` lines, the server runs `jog-build deps --flags` in the module root (plus `--test` for `*.test.jog` buffers) and passes those `--module=…` mappings through. `jog-build` is `JOG_BUILD`, else a binary next to `jog`, else `jog-build` on `PATH`. Rebuild the server whenever develop’s manifest grammar changes so `jog.mod` directives like `require.test` are not reported as reserved.

## Editor

`editors/vscode` is a VS Code and Cursor extension: a TextMate grammar, a language configuration, and a small client that starts the language server. Highlighting comes from the grammar and does not need the server.

From `editors/vscode`, with `server/out/server` already built (`.exe` on Windows):

**Linux**

```
npm install
cp ../../server/out/server bin/server
npx @vscode/vsce package --allow-missing-repository
cursor --install-extension jog-0.0.1.vsix --force
```

**Windows**

```
npm install
Copy-Item ..\..\server\out\server.exe bin\server.exe
npx @vscode/vsce package --allow-missing-repository
cursor --install-extension jog-0.0.1.vsix --force
```

Reload the window after installing. The client starts `bin/server` / `bin/server.exe`, or `server/out/server` from this checkout. It passes `jog.compilerPath` when that setting is set in user or workspace settings; otherwise it uses `JOG`, then `~/.local/bin/jog`, then the historical Windows seed path.

P2 editor smoke: `JOG=/path/to/jog node editors/vscode/verify-p2.js`.
