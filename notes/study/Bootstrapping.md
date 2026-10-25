---
status: draft
tags:
  - bootstrap
  - study
  - compiler
---

# Bootstrapping

A compiler is **self-hosted** when it is written in the language it compiles. Getting there is a chicken-and-egg problem, solved the same way every time: an existing compiler, written in something else, builds the first binary of the new one, and from then on the new compiler builds itself. This note covers the stages, the fixpoint check that proves the loop is closed, what to keep as the seed, and the discipline that keeps the loop buildable. It is P5 in [[bootstrap/Roadmap]], and [[bootstrap/Checks]] has the exact commands.

## Key ideas

### Stages

Name every compiler binary by who built it:

- **Stage 0** is the compiler you already have: the C `jog` in this repo. It is not written in Jog.
- **Stage 1** is `jogc`'s source built by stage 0. It is the first `jogc` binary. Its machine code comes from `jog`'s C backend and the C compiler, so it may be slower or larger, but if both compilers are correct it **behaves** exactly like any other correct build of `jogc`.
- **Stage 2** is `jogc`'s source built by stage 1. It is the first binary produced entirely by `jogc`'s own backend.
- **Stage 3** is `jogc`'s source built by stage 2.

Stage 1 and stage 2 are built from the same source by different compilers, so their binaries differ. But they run the same program, so given the same input they must produce the same output.

### The fixpoint

That observation is the test. Stage 1 compiles `jogc`'s source to C (the C for stage 2), and stage 2 compiles the same source to C (the C for stage 3). If `jogc` is correct and deterministic, the two outputs are **byte-identical**: the compiler has reached a **fixpoint**, where compiling it again changes nothing.

When the outputs differ, one of two things is wrong:

- **A miscompilation.** Stage 0 or stage 1 compiled some part of `jogc` incorrectly, so stage 2 behaves differently from stage 1. The first differing line in the generated C points at the code path that diverged.
- **Nondeterminism.** The output depends on something other than the input: iteration order of a hash map keyed by pointers, addresses printed into names, timestamps, absolute paths, the order a directory listing returns files, uninitialized memory. These are bugs even when the program works, because they make every later comparison meaningless.

The fixpoint is necessary, not sufficient. A compiler that is wrong in the same way at every stage still reaches it. That is why stage 1 must also pass the full differential test against stage 0 on every test program before the fixpoint means anything.

### The seed

Once `jogc` builds itself, something still has to build the very first binary on a fresh machine. That something is the **seed**, and there are a few ways to keep one:

- **Keep the old compiler**, frozen. The C `jog` stays in the repo and changes only when `jogc` needs something it cannot build. This is the plan for Jog. It is honest (the seed is readable source), but it is a second compiler to maintain, and `jogc` can only use what the seed supports.
- **Keep the generated C.** Commit `jogc`'s own generated C as the seed. A C compiler builds it into a stage 1, and the old compiler can be deleted. The generated C is large and not meant for humans, but it never needs editing: it is regenerated whenever `jogc` needs a newer seed.
- **Keep a portable binary.** Zig keeps `zig1.wasm`, a WebAssembly build of its own compiler, in its repository. A small C program translates it to C and builds it, and the result builds the real compiler. This let Zig delete its C++ implementation entirely.
- **Use the previous release.** Go 1.5 onward is built by an earlier Go (originally Go 1.4, the last release with a C compiler), and Rust is built by the previous release of Rust. The chain of releases is the seed, which is convenient for users but means a fresh bootstrap from source walks back through history.

Generated C fits Jog well, because Jog's only backend is C. If maintaining the C `jog` ever costs more than it is worth, emitting `jogc`'s own C into a `bootstrap/` folder is a small step.

### Trusting trust

In "Reflections on Trusting Trust" (1984) Ken Thompson showed that a compiler binary can carry behavior its source does not: a compiler can be modified to insert a backdoor into `login`, and also to insert that same modification into any compiler it compiles, after which the modification can be removed from the source and still survive every rebuild. Reading the source of a self-hosted compiler therefore does not tell you what its binary does. The binary is explained by its source **and** by the binary that built it, and so on back to the seed.

David Wheeler's **diverse double-compiling** is the practical answer. Build the compiler's source with an independent, trusted compiler, use that result to build the source again, and compare with the self-built binary. If they match, the self-built binary corresponds to its source. Keeping a readable seed, as Jog does with the C `jog`, keeps this check possible. The same concern drives bootstrappable.org and Reproducible Builds.

### The subset discipline

Stage 0 has to compile `jogc`'s source. So `jogc` can only use what stage 0 supports **and supports correctly**, and every new language feature has a cost: implement it in the C compiler first, or wait until after the bootstrap to use it in `jogc`. [[plans/Bootstrap]] fixes this as the bootstrap subset: functions, structs, pointers, modules and compile-time execution. Coroutines and dependency injection stay outside it, which is why [[bootstrap/Roadmap]] leaves open whether `jogc`'s checker uses coroutines like the C one or a worklist.

The subset is a rule about `jogc`'s own source, not about what `jogc` accepts. `jogc` must eventually check and compile every Jog program, including ones that use coroutines; it just must not use them itself until the seed can build them. Writing the study exercises already showed where stage 0 lags the specification (see [[bootstrap/Friction]]); each of those gaps is either fixed in the C compiler or avoided in `jogc`, and the choice should be written down.

## How the C V1 does it

The C V1 is stage 0, so this note is about what it provides to the loop rather than how it bootstraps itself:

- **Building a compiler binary.** `jog build . -o out/stage1.exe` runs the whole pipeline. `link_program` in `compiler/src/cmd_build.c` writes the generated C to `out/<module>.c` and calls `jog_cc_build` in `compiler/src/cc.c`; with `--keep-c` the C file is kept instead of deleted, which is what the fixpoint comparison reads.
- **WebAssembly.** `jog build --target wasm32` goes through `jog_cc_build_wasm`, the same route Zig's seed takes. A `jogc.wasm` seed is possible without new compiler work.
- **Deterministic output.** `assign_names` in `compiler/src/emit_c.c` resolves C name collisions with type ids instead of addresses, `order_defs` sorts definitions by dependency, and interned names and types are numbered in the order they are created. Stage 0's output is a reference for how `jogc`'s must behave.
- **Paths in the output.** `begin_stmt` writes `#line` directives and panic calls carry the source file path, as written to the C compiler. Building stage 2 and stage 3 from the same checkout gives the same paths; building from two different directories does not, and the comparison has to account for it.
- **The commands.** `jog build`, `run` and `test` (`compiler/src/main.c`) are what `jogc` must reproduce, and [[plans/V1Compiler]] lists them.

## Questions to answer in your own words

1. Why are the stage 1 and stage 2 **binaries** different, while their **outputs** must be the same?
2. The C for stage 3 differs from the C for stage 2 in the order of two struct definitions. List three causes to check, in the order you would check them.
3. Why is reaching the fixpoint not enough to show `jogc` is correct? What has to pass first?
4. Compare keeping the C `jog` as the seed with committing `jogc`'s generated C. What does each cost, and what does each make possible?
5. Explain Thompson's attack in three sentences. Why does keeping a readable seed matter for Wheeler's defense?
6. `jogc`'s checker would be simpler with coroutines, but they are outside the bootstrap subset. What are the options, and what does each cost later?
7. Which features of `jogc`'s own `Map` and string interner affect whether the fixpoint can be reached?

## Jog exercise

Two tools the fixpoint needs. `firstDifference` finds where two outputs diverge, as a line and column, which is the first thing you look at when stage 2 and stage 3 disagree. `emitDecls` shows the cure for one common cause: it sorts names before emitting them, so the output no longer depends on the order the compiler happened to discover them in.

```
import std.testing

struct Out {
    buf: [1024]u8
    len: usize
}

fn *Out.put(s: str) {
    for i in 0..s.len {
        self.buf[self.len] = s.ptr[i]
        self.len += 1
    }
}

struct Diff {
    same: bool
    line: usize
    col: usize
}

// Lines and columns are 1-based. Reaching the end of the shorter input
// while the other continues is a difference at that position.
fn firstDifference(a: []u8, b: []u8): Diff {
    var line: usize = 1
    var col: usize = 1
    var i: usize = 0
    for i < a.len && i < b.len {
        if a[i] != b[i] {
            return Diff(same: false, line: line, col: col)
        }
        if a[i] == '\n' as u8 {
            line += 1
            col = 1
        } else {
            col += 1
        }
        i += 1
    }
    return Diff(same: a.len == b.len, line: line, col: col)
}

fn less(a: str, b: str): bool {
    var i: usize = 0
    for i < a.len && i < b.len {
        if a.ptr[i] != b.ptr[i] {
            return a.ptr[i] < b.ptr[i]
        }
        i += 1
    }
    return a.len < b.len
}

fn sortNames(names: []str) {
    for i in 1..names.len {
        val key = names[i]
        var j = i
        for j > 0 && less(key, names[j - 1]) {
            names[j] = names[j - 1]
            j -= 1
        }
        names[j] = key
    }
}

fn emitDecls(o: *Out, names: []str, sorted: bool) {
    if sorted {
        sortNames(names)
    }
    for name in names {
        o.put("void jog_ex__")
        o.put(name)
        o.put("(void);\n")
    }
}

@test
fn differenceIsLocated() with (t: testing.Testing) {
    var a: Out
    var b: Out
    a.put("int x;\nint y;\n")
    b.put("int x;\nint z;\n")
    val d = firstDifference(a.buf[0..a.len], b.buf[0..b.len])
    t.expect(!d.same)
    t.expect(d.line == 2)
    t.expect(d.col == 5)

    var c: Out
    c.put("int x;\n")
    val e = firstDifference(a.buf[0..a.len], c.buf[0..c.len])
    t.expect(!e.same)
    t.expect(e.line == 2)
    t.expect(e.col == 1)
}

@test
fn sortedOutputIgnoresDiscoveryOrder() with (t: testing.Testing) {
    var first: [3]str
    first[0] = "parse"
    first[1] = "lex"
    first[2] = "check"
    var second: [3]str
    second[0] = "check"
    second[1] = "parse"
    second[2] = "lex"

    var raw1: Out
    var raw2: Out
    emitDecls(&raw1, first[0..3], false)
    emitDecls(&raw2, second[0..3], false)
    val unsorted = firstDifference(raw1.buf[0..raw1.len], raw2.buf[0..raw2.len])
    t.expect(!unsorted.same)
    t.expect(unsorted.line == 1)
    t.expect(unsorted.col == 14)

    var out1: Out
    var out2: Out
    emitDecls(&out1, first[0..3], true)
    emitDecls(&out2, second[0..3], true)
    t.expect(firstDifference(out1.buf[0..out1.len], out2.buf[0..out2.len]).same)
}
```

Then extend it:

- Turn `firstDifference` into a small `fixpoint` program that reads two files with `io.read_all` and prints `file:line:col` and both lines at the first difference. Use it in place of `fc.exe` in the P5 checklist.
- Build the StrMap from [[bootstrap/study/DataStructures]] twice with the same keys in different orders and iterate over its slots. Is the iteration order the same? What does that mean for any compiler pass that iterates a map to produce output?
- Write a two-line program that prints its own source code (a quine) in Jog. It is the smallest version of a program that reproduces itself, and the starting point of Thompson's paper.
- Once stage 1 exists, build stage 2 and stage 3 from two different directories, compare their C, and decide how `jogc` should handle the paths that differ.

## Reading

From [[bootstrap/Reading]]:

- **Start here:** "Goodbye to the C++ Implementation of Zig", for a seed kept as a WebAssembly binary.
- The Go 1.5 bootstrap plan, for a release chain as the seed.
- Thompson's "Reflections on Trusting Trust" and Wheeler's diverse double-compiling.
- bootstrappable.org and Reproducible Builds, for why the seed and determinism matter beyond one project.
- [[plans/Bootstrap]], for the bootstrap subset.

## See also

- [[bootstrap/Roadmap]]
- [[bootstrap/Checks]]
- [[bootstrap/Friction]]
- [[bootstrap/study/CodeGen]]
- [[bootstrap/study/DataStructures]]
- [[plans/Bootstrap]]
- [[plans/V1Compiler]]
- [[design/Language]]
