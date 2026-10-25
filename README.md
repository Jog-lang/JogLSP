# JogLSP

A diagnostics-only language server for Jog. The server is written in Jog. It speaks Language Server Protocol messages over stdin and stdout, and on save it runs `jog check --diag=json`.

The compiler is `D:\Projects\CTools\build\jog.exe`. Standard library packages are found relative to that binary.

## Server

`server/jog.mod` marks the module root. `server/main.jog` is the root package and starts `src.serve`. The server itself is the `src` package. The loader always builds that root, so the commands below are run from `server/` with no package argument.

From `server/`:

```
D:\Projects\CTools\build\jog.exe test
D:\Projects\CTools\build\jog.exe build
```

`jog build` writes `server/out/server.exe`. `jog test` writes that same path, so build again after a test run when you want the server rather than the test runner. The process reads framed messages from stdin and writes them to stdout. Logs go to stderr. On Windows the server sets stdin and stdout to binary mode so `Content-Length` counts bytes.

The compiler path is the first argument, or the `JOG` environment variable when that argument is absent. If neither is set, the server uses `D:\Projects\CTools\build\jog.exe`.

## Editor

`editors/vscode` is a VS Code and Cursor extension: a TextMate grammar, a language configuration, and a small client that starts the language server. Highlighting comes from the grammar and does not need the server.

From `editors/vscode`, with `server/out/server.exe` already built:

```
npm install
Copy-Item ..\..\server\out\server.exe bin\server.exe
npx @vscode/vsce package --allow-missing-repository
cursor --install-extension jog-0.0.1.vsix
```

Reload the window after installing. The client starts `bin/server.exe` and passes `jog.compilerPath`, which defaults to `D:\Projects\CTools\build\jog.exe`.
