---
status: draft
tags:
  - plan
  - bootstrap
  - checklist
---

# Bootstrap checks

One checklist per phase of [[bootstrap/Roadmap]]. A phase is done when every box in its section is ticked. Commands assume PowerShell, the C compiler built by `pwsh scripts/check.ps1` (it lands in `build/`), and the self-hosted compiler called `jogc`.

When a check fails because of Jog itself rather than your code, log it in [[bootstrap/Friction]] before working around it.

## P0: C compiler support

- [x] `jog check --diag=json` prints one JSON object per line on stdout: `{"file": ..., "line": ..., "column": ..., "severity": ..., "message": ...}`.
- [x] Lines and columns are 1-based and match the text output of `jog check` for the same input.
- [x] Messages with quotes, backslashes and non-ASCII text are escaped correctly. Test with a `tests/check` case whose message quotes a string literal.
- [x] A clean package prints nothing and exits 0. A package with errors exits non-zero.
- [ ] Every C compiler bug found in later phases has a regression test under `tests/` and a line in [[bootstrap/Friction]].
- [ ] `pwsh scripts/check.ps1` prints `check: OK`.

## P1: std in Jog

Repos and setup:

- [ ] JogCompiler has a skeleton: `jog.mod`, `src/`, `tests/`, `scripts/`, and a README that says how to build with stage 0.
- [x] JogLSP has a skeleton: `server/jog.mod`, `server/src/`, `editors/vscode/`, and a README.

Packages (each has `*.test.jog` files):

- [x] `List<T>`: push, pop, index, insert, remove, clear, and a slice view. Pushing 1 million items works and keeps amortized O(1) growth.
- [x] `Map<K, V>`: insert, get, remove, iterate. Tests cover growth across several resizes, deleting half the keys and reinserting them, and forced collisions (a test hash that maps every key to the same bucket).
- [x] `Map` iteration order is deterministic for the same sequence of operations. P5 depends on this.
- [x] `StrBuilder`: a growable buffer; append text and a byte; clear keeps capacity; `str` returns the live bytes with no copy; free releases the block. Growth starts at 8 and doubles.
- [x] Arena: implements the `std.mem` `Allocator`; alignment is respected for 1, 2, 4, 8 and 16 bytes; reset reuses memory; a large allocation spanning several chunks works.
- [x] Integer formatting and parsing: round-trip `i64` min, max, 0 and -1 in bases 2, 10 and 16; parsing rejects overflow and empty input. `StrBuilder` still needs chars, integer formatting, and inputs over 1 MiB.
- [x] `fs`: read a file into bytes, write a file, list a directory (sorted by the caller, not by the OS), join paths with either separator on Windows.
- [x] `proc`: spawn `jog --help` (or any short command), capture stdout and stderr separately, return the exit code. A missing executable is an error return, not a panic.
- [x] `os`: program arguments and environment variables.
- [ ] A counting allocator wrapped around the test allocator shows zero bytes outstanding at the end of every test that frees what it allocates.

Commands:

- [ ] `jog test std/<package>` passes for each new package. If the loader does not yet accept a std folder directly, that is a P0 fix.
- [ ] `jog test --all` from a module that imports every new package passes.

## P2: JogLSP v0

Server:

- [x] Framing round-trip: a test writes several messages with `Content-Length` headers into a buffer, reads them back, and gets the same bodies. Split reads (a header cut in half, a body arriving in two chunks) work.
- [x] JSON corpus passes: a folder of valid documents parses and re-serializes to equivalent JSON; a folder of invalid documents (trailing commas, bad escapes, unterminated strings, deep nesting) is rejected with an error, never a crash.
- [x] `\u` escapes with surrogate pairs decode to correct UTF-8.
- [x] `initialize` replies with the server capabilities; `shutdown` then `exit` ends the process with code 0; `exit` without `shutdown` ends it with code 1.
- [x] A malformed request (bad JSON, unknown method, missing `id`) gets an error response or is ignored, and the server keeps running.
- [x] On `didSave`, the server runs `jog check --diag=json` through `proc` and sends `publishDiagnostics` for each affected file.
- [x] A file whose errors are fixed gets an empty diagnostics list, so the squiggles clear.
- [x] Positions are converted from compiler columns (bytes, 1-based) to LSP positions (UTF-16 code units, 0-based). Test with a line containing non-ASCII text before the error.

Editor:

- [ ] Opening a `.jog` file in Cursor shows syntax highlighting from the TextMate grammar.
- [ ] Comment toggling, bracket matching and auto-closing pairs work.
- [ ] A syntax error is underlined within about a second of saving, and the underline clears when it is fixed and saved again.
- [ ] Closing the editor shuts the server down cleanly: no orphaned `jog` or server processes in Task Manager.

## P3: JogCompiler

The differential script:

- [ ] Write `scripts/diff_stage.ps1` in JogCompiler. It is the definition of "matches the C compiler" for every stage below.
  - Parameters: `-Stage lex|parse|check|ir|run`, `-Jog <path to stage 0>` (default `jog` on PATH), `-Jogc <path to jogc>`, and an optional `-Filter` glob to rerun one file.
  - Inputs: every `.jog` file under CTools `std/`, `tests/jog`, `tests/parse`, `tests/check`, `playground/` and `examples/`, plus JogCompiler's own `src/`. Take the CTools root from a `-CTools` parameter or a `CTOOLS` environment variable.
  - For `lex` and `parse`: run `jog <stage> <file>` and `jogc <stage> <file>`, capture stdout and the exit code, normalize line endings to `\n`, and compare.
  - For `check`: run both on each `tests/check` case and compare the diagnostics. Start by comparing only the first error's line and column, then tighten to the full message list.
  - For `ir`: compare `emit-ir` output on `tests/jog` programs. Expect to need a normalization step for temporary names.
  - For `run`: build each `tests/jog` program with both compilers, run both executables, and compare stdout and the exit code.
  - Output: one line per mismatch with the file and the first differing line from each side, then a summary such as `lex: 212 files, 0 mismatches`. Exit non-zero on any mismatch, so it can gate commits.
  - Keep the outputs of the last run under `out/diff/<stage>/` so a mismatch can be inspected with a normal diff tool.

Stages, in order:

- [ ] **Lexer.** `pwsh scripts/diff_stage.ps1 -Stage lex` reports 0 mismatches, including on JogCompiler's own source.
- [ ] Lexer errors (unterminated string, bad escape, stray character) report the same position as `jog lex`.
- [ ] **Parser.** `pwsh scripts/diff_stage.ps1 -Stage parse` reports 0 mismatches. `tests/parse/*.jog` produce exactly `tests/parse/*.ast`.
- [ ] Parse errors report the same first error position as `jog parse`.
- [ ] **Loader and resolver.** `jogc check` finds the module root from any subfolder, loads std from the same place `jog` does (`<exe>/../std` or `JOG_ROOT`), and reports undefined and duplicate names at the same positions as `jog check`.
- [ ] **Checker, subset.** `jogc check` on JogCompiler's own source reports no errors, and on a deliberately broken copy reports the same first error as `jog check`.
- [ ] **Checker, full.** `pwsh scripts/diff_stage.ps1 -Stage check` reports the same first error position for every `tests/check` case.
- [ ] The decision between coroutines and a worklist for on-demand checking is recorded in [[bootstrap/Roadmap]].
- [ ] **Lowering.** `pwsh scripts/diff_stage.ps1 -Stage ir` reports 0 mismatches after normalization, or every remaining difference is explained in a note.
- [ ] **C emitter and driver.** `pwsh scripts/diff_stage.ps1 -Stage run` reports 0 mismatches: every `tests/jog` program built with `jogc` gives the same stdout and exit code as with `jog`.
- [ ] `jogc build`, `jogc run` and `jogc test` accept the same arguments as the `jog` commands listed in [[plans/V1Compiler]].

## P4: LSP v1

- [ ] JogLSP imports the JogCompiler frontend as a package and no longer spawns `jog check`.
- [ ] Diagnostics update on `didChange` (not only on save) without noticeable typing lag on the largest file in JogCompiler.
- [ ] The parser recovers from errors: a file with a missing closing brace still yields document symbols for every function before and after it.
- [ ] Hover on a name shows its type and declaration.
- [ ] Go to definition works across files and packages, including into std.
- [ ] Document symbols list every top-level declaration with its kind.
- [ ] Completion offers names in scope and the fields and methods after `.`.
- [ ] A fuzz pass (truncate every file in `tests/jog` at random offsets and send it as `didChange`) never crashes the server.

## P5: bootstrap

Run from the JogCompiler root, with stage 0 being the C `jog`:

```
jog build . -o out/stage1.exe
out/stage1.exe build . -o out/stage2.exe --keep-c
out/stage2.exe build . -o out/stage3.exe --keep-c
```

- [ ] Stage 1 passes `pwsh scripts/diff_stage.ps1 -Stage run -Jogc out/stage1.exe`.
- [ ] The C generated by stage 2 and stage 3 is byte-identical. Compare with `Compare-Object (Get-Content <stage2 C>) (Get-Content <stage3 C>)` or `fc.exe /b`.
- [ ] If they differ, the cause (map iteration order, pointer values in names, timestamps, paths) is found and fixed, not normalized away.
- [ ] Self-compile time for stage 2 building stage 3 is recorded here, with the machine and build mode: ______.
- [ ] The C compiler is frozen as the seed: its README says it exists only to build `jogc`.

## See also

- [[bootstrap/Roadmap]]
- [[bootstrap/Friction]]
- [[bootstrap/study/Bootstrapping]]
- [[plans/V1Compiler]]
