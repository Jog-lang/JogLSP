---
status: draft
tags:
  - bootstrap
  - study
  - compiler
  - codegen
---

# CodeGen

Code generation turns the IR into something a machine can run. The C V1 does not produce machine code itself: it writes one C file and hands it to clang or gcc. That is stage 6 of the compiler, and in the bootstrap it is the stage whose output matters most, because `jogc` will be judged by whether the programs it builds behave exactly like the ones `jog` builds. See [[bootstrap/Roadmap]].

## Key ideas

### C as a target

Emitting C trades control for reach. The C compiler supplies register allocation, instruction selection, optimization, debug info, every operating system and architecture it supports, and WebAssembly through clang. What Jog gives up is control over the details: the backend must express everything through C's semantics, and C has sharp edges. Nim, early C++ (Cfront), Vala and many research compilers made the same trade. [[plans/V1Compiler]] makes it deliberately, with a native backend left for later, reading the same IR.

The trade is only safe if the generated C never relies on behavior C leaves undefined. The backend, not the C compiler, is responsible for Jog's semantics.

### Undefined behavior is the backend's problem

Several things are defined in Jog and undefined in C, so the backend has to spell them out:

- **Signed overflow.** Jog traps on overflow, while in C it is undefined, and the optimizer is allowed to assume it never happens. Checked arithmetic uses `__builtin_add_overflow` and friends, which compute the wrapped result and report whether it overflowed, with no undefined behavior.
- **Division.** `x / 0` and `INT_MIN / -1` are both undefined in C. The backend tests for them first.
- **Shifts.** Shifting by the type's width or more is undefined in C. The backend checks the shift count.
- **Type punning.** Reading an `f64`'s bits as a `u64` through a pointer cast breaks C's aliasing rules. A union (or `memcpy`) is the defined way.
- **Literals.** `-9223372036854775808` in C is unary minus applied to a constant that does not fit in `int64_t`. The smallest value has to be written some other way, for example as `INT64_MIN`.

### One file, in the right order

C needs declarations before uses, which a Jog program does not. The emitter therefore writes the file in layers:

1. A prelude: `stdint.h`, `stddef.h`, `stdbool.h` and the runtime header.
2. Forward declarations of every struct, so pointers between types can refer to each other in any order.
3. Type definitions in dependency order. A struct that contains another **by value** needs the inner definition first. A pointer only needs the forward declaration. This is a topological sort over "contains by value", and a by-value cycle is impossible, because the checker has already rejected infinitely sized types.
4. Prototypes for every function, so functions can call each other in any order.
5. Globals and their initial data.
6. Function bodies.

### Mapping types and names

Every Jog type needs a C spelling. Integers become `int32_t`, `uint8_t` and so on. Slices and `str` become a struct of pointer and length. Enums become a tag plus a union of payloads. Options become either a nullable pointer or a struct with a flag. Tuples and function values become small structs. Structural types such as `[]i32` are named by number (`jt29`), because their Jog spelling is not a C identifier.

Names must not collide, in C or with C: two packages may both define `parse`, and a Jog function may be called `free`. **Name mangling** gives each symbol a prefix that encodes its package, so `fn sum` in package `probe` becomes `jog_probe__sum`. The mangling must be deterministic: the same program must always produce the same C, or nothing can be compared byte for byte.

### Lowering blocks to C

JIR is already flat, so emitting a body is mostly translation:

- Every IR local becomes a C local declared at the top of the function.
- Every basic block becomes a label (`b0:;`, `b1:;`).
- `br` becomes `goto`, `cond_br` becomes `if (...) goto ...; goto ...;`, `switch` becomes a C `switch` of `goto`s, and `ret` becomes `return`.
- Each instruction becomes one C statement, and a check instruction becomes an `if` that calls a runtime panic function with the source location.

C with `goto` is not pretty, but it is exactly what a C compiler's optimizer turns into a control-flow graph anyway.

### Source positions

A panic, a debugger or a sanitizer report should point at the Jog source, not the generated C. The C preprocessor directive `#line 8 "main.jog"` says "the following line came from line 8 of main.jog". With it, `-g` debug info and compiler diagnostics refer to Jog lines.

### Driving the C compiler

The last step runs a C compiler: find one (an override variable, then clang, then gcc), pass mode flags (`-O0 -g` for debug, `-O2` for release), compile the generated file together with the runtime, and link. Warnings in generated C are bugs in the backend. A warning means the emitter wrote something it did not intend, and the user cannot fix it.

## How the C V1 does it

- **Entry: `jog_emit_c` in `compiler/src/emit_c.c`.** It takes a `JirModule` and a build mode and appends C text to a `CtSb`.
- **Which types are needed and what they are called.** `reach_module` collects every type the module uses. `assign_names` gives each a C name, and when two nominal types would get the same name, it adds the type's id as a suffix (`with_id_suffix`) to the later one, which stays deterministic.
- **Definition order.** `order_defs` does the topological sort described above (`child_first` distinguishes by-value from by-pointer children). `emit_forwards` and `emit_def` (`emit_struct_body`, `emit_enum`, `emit_alias`) write the definitions.
- **Bodies.** `emit_functions`, `emit_signature`, `emit_body`, `emit_inst` and `emit_term`. In `emit_term` a branch becomes `goto b%u`, a switch a C `switch`, and "unreachable" a call to `jogrt_panic_unreachable`. `begin_stmt` writes the `#line` directive before each statement.
- **Checks.** `emit_binary` uses `overflow_builtin` to pick `__builtin_add_overflow` and its siblings for checked integer arithmetic, and calls `jogrt_panic_overflow` with the location. `emit_checked_divmod` and `emit_checked_shift` handle division and shifts. `emit_bitcast` puns through a union. `emit_convert` and `emit_cast_assign` handle numeric conversions. `emit_call` and `emit_panic` handle calls and panics.
- **Data.** `emit_string_data`, `emit_globals` (initial data, ordered by `emit_ordered`), `emit_vtables` (interface method tables), and `emit_entry`, which writes the C `main`.
- **The prelude.** `emit_prelude` writes the includes, and the runtime lives in `runtime/`.
- **Driving the C compiler: `compiler/src/cc.c`.** `jog_cc_build` builds the command line, `find_compiler` checks `JOG_CC`, then `clang`, then `gcc` (`search_path` walks `PATH`), `push_mode_flags` adds `-O0 -g` or `-O2`, and `mismatch_flag` silences the warning about libc functions that Jog declares itself. `jog_cc_build_wasm` targets WebAssembly.
- **Try it.** `jog emit-c` prints the generated C. For

```
fn sum(p: Point, k: i32): i32 {
    if k > 0 {
        return p.x + p.y * k
    }
    return 0
}
```

the body contains (with the `#line` directives removed):

```
b0:;
    l2 = (l1) > (0);
    if ((l2)) {
        goto b1;
    }
    goto b2;
b1:;
    l3 = &l0;
    l4 = &(l3)->f_x;
    l5 = *(l4);
    ...
    if (__builtin_mul_overflow((l8), (l1), &l9)) {
        jogrt_panic_overflow("main.jog", 8);
    }
    if (__builtin_add_overflow((l5), (l9), &l10)) {
        jogrt_panic_overflow("main.jog", 8);
    }
    return (l10);
b2:;
    return (0);
```

## Questions to answer in your own words

1. What does emitting C give Jog for free, and what does it cost? When would a native backend be worth writing?
2. Why is `a + b` on `i32` not simply emitted as `a + b`? What could an optimizing C compiler do to a program that overflows?
3. Why must struct definitions be ordered, while prototypes let functions appear in any order? Why can a by-value cycle never reach the emitter?
4. Two packages each define `fn parse`. What does mangling have to guarantee, and why must it be deterministic?
5. What does `#line` change for a user who hits a panic, and for one who runs a debugger?
6. Why is every warning in generated C a backend bug, even when the program works?
7. How would you compare `jogc`'s output with `jog`'s: by diffing the C, or by running the programs? What does each catch?

## Jog exercise

Emit C for the block-structured IR from [[bootstrap/study/IR]]. The emitter writes into a fixed buffer and the test checks the output line by line, so you can see exactly what C each instruction becomes.

```
import std.testing

val OpConst: u8 = 0
val OpAdd: u8 = 1
val OpLess: u8 = 2
val OpCopy: u8 = 3

val TermBr: u8 = 1
val TermCondBr: u8 = 2
val TermRet: u8 = 3

struct Inst {
    code: u8
    dst: usize
    a: usize
    b: usize
    imm: i64
}

struct Term {
    kind: u8
    value: usize
    yes: usize
    no: usize
}

struct Block {
    insts: [8]Inst
    count: usize
    term: Term
}

struct Func {
    blocks: [8]Block
    blockCount: usize
    localCount: usize
}

struct Out {
    buf: [2048]u8
    len: usize
}

fn *Out.put(s: str) {
    for i in 0..s.len {
        self.buf[self.len] = s.ptr[i]
        self.len += 1
    }
}

fn *Out.byte(c: u8) {
    self.buf[self.len] = c
    self.len += 1
}

fn *Out.num(v: u64) {
    var digits: [20]u8
    var n: usize = 0
    var x = v
    for {
        digits[n] = '0' as u8 + (x % 10) as u8
        n += 1
        x = x / 10
        if x == 0 {
            break
        }
    }
    for n > 0 {
        n -= 1
        self.byte(digits[n])
    }
}

fn *Out.int(v: i64) {
    if v < 0 {
        self.byte('-' as u8)
        self.num((0 - (v + 1)) as u64 + 1)
    } else {
        self.num(v as u64)
    }
}

fn *Out.local(l: usize) {
    self.byte('l' as u8)
    self.num(l as u64)
}

fn *Out.label(b: usize) {
    self.byte('b' as u8)
    self.num(b as u64)
}

fn *Out.end() {
    self.byte('\n' as u8)
}

fn emitInst(o: *Out, inst: Inst) {
    o.put("    ")
    o.local(inst.dst)
    o.put(" = ")
    if inst.code == OpConst {
        o.int(inst.imm)
    } else if inst.code == OpCopy {
        o.local(inst.a)
    } else {
        o.local(inst.a)
        if inst.code == OpAdd {
            o.put(" + ")
        } else {
            o.put(" < ")
        }
        o.local(inst.b)
    }
    o.put(";")
    o.end()
}

fn emitTerm(o: *Out, t: Term) {
    if t.kind == TermRet {
        o.put("    return ")
        o.local(t.value)
        o.put(";")
        o.end()
    } else if t.kind == TermBr {
        o.put("    goto ")
        o.label(t.yes)
        o.put(";")
        o.end()
    } else {
        o.put("    if (")
        o.local(t.value)
        o.put(") goto ")
        o.label(t.yes)
        o.put(";")
        o.end()
        o.put("    goto ")
        o.label(t.no)
        o.put(";")
        o.end()
    }
}

fn emitFunc(o: *Out, name: str, f: *Func) {
    o.put("int64_t ")
    o.put(name)
    o.put("(void) {")
    o.end()
    for l in 0..f.localCount {
        o.put("    int64_t ")
        o.local(l)
        o.put(" = 0;")
        o.end()
    }
    for b in 0..f.blockCount {
        val blk = &f.blocks[b]
        o.label(b)
        o.put(":;")
        o.end()
        for k in 0..blk.count {
            emitInst(o, blk.insts[k])
        }
        emitTerm(o, blk.term)
    }
    o.put("}")
    o.end()
}

fn push(f: *Func, b: usize, inst: Inst) {
    val blk = &f.blocks[b]
    blk.insts[blk.count] = inst
    blk.count += 1
}

// V1 rejects f.blocks[b].term = t directly; assigning through a pointer works.
fn setTerm(f: *Func, b: usize, t: Term) {
    val blk = &f.blocks[b]
    blk.term = t
}

fn same(want: str, got: []u8): bool {
    if want.len != got.len {
        return false
    }
    for i in 0..want.len {
        if want.ptr[i] != got[i] {
            return false
        }
    }
    return true
}

// Compares the output with the expected lines and returns the index of the
// first line that differs, or want.len when they all match.
fn firstDiff(o: *Out, want: []const str): usize {
    var start: usize = 0
    var line: usize = 0
    for i in 0..o.len {
        if o.buf[i] == '\n' as u8 {
            if line >= want.len || !same(want[line], o.buf[start..i]) {
                return line
            }
            line += 1
            start = i + 1
        }
    }
    return line
}

fn konst(dst: usize, v: i64): Inst {
    return Inst(code: OpConst, dst: dst, a: 0, b: 0, imm: v)
}

fn copy(dst: usize, a: usize): Inst {
    return Inst(code: OpCopy, dst: dst, a: a, b: 0, imm: 0)
}

@test
fn emitIfExpr() with (t: testing.Testing) {
    // if 1 < 2 { 10 } else { -20 }, as lowered by the IR exercise
    var f: Func
    f.blockCount = 4
    f.localCount = 6
    push(&f, 0, konst(1, 1))
    push(&f, 0, konst(2, 2))
    push(&f, 0, Inst(code: OpLess, dst: 3, a: 1, b: 2, imm: 0))
    setTerm(&f, 0, Term(kind: TermCondBr, value: 3, yes: 1, no: 2))
    push(&f, 1, konst(4, 10))
    push(&f, 1, copy(0, 4))
    setTerm(&f, 1, Term(kind: TermBr, value: 0, yes: 3, no: 0))
    push(&f, 2, konst(5, -20))
    push(&f, 2, copy(0, 5))
    setTerm(&f, 2, Term(kind: TermBr, value: 0, yes: 3, no: 0))
    setTerm(&f, 3, Term(kind: TermRet, value: 0, yes: 0, no: 0))

    var o: Out
    emitFunc(&o, "jog_ex__pick", &f)
    val want = []const str(
        "int64_t jog_ex__pick(void) {",
        "    int64_t l0 = 0;",
        "    int64_t l1 = 0;",
        "    int64_t l2 = 0;",
        "    int64_t l3 = 0;",
        "    int64_t l4 = 0;",
        "    int64_t l5 = 0;",
        "b0:;",
        "    l1 = 1;",
        "    l2 = 2;",
        "    l3 = l1 < l2;",
        "    if (l3) goto b1;",
        "    goto b2;",
        "b1:;",
        "    l4 = 10;",
        "    l0 = l4;",
        "    goto b3;",
        "b2:;",
        "    l5 = -20;",
        "    l0 = l5;",
        "    goto b3;",
        "b3:;",
        "    return l0;",
        "}",
    )
    t.expect(firstDiff(&o, want) == want.len)
}
```

Then extend it:

- Paste the output into a `.c` file with `#include <stdint.h>` and a `main` that prints `jog_ex__pick()`, and compile it with `clang -Wall -Wextra`. Fix every warning in the emitter, not in the C.
- Make `OpAdd` checked: emit `if (__builtin_add_overflow(a, b, &dst)) { panic(...); }`, and test it with operands near `i64` limits.
- Emit `#line` directives from a position stored on each instruction.
- Try `o.int` with the smallest `i64`. Does the emitted literal compile without a warning? If not, emit `INT64_MIN` instead.
- Emit only blocks reachable from `b0`, and see that the C compiler no longer warns about unused labels.

## Reading

From [[bootstrap/Reading]]:

- chibicc's `codegen.c`, a complete C backend in one readable file (it targets assembly, but the structure is the same).
- John Regehr's "A Guide to Undefined Behavior in C and C++", for why the checks above are necessary.
- The GCC manual's pages on integer overflow builtins and on `#line` (line control).
- [[plans/V1Compiler]], section "The C backend", is the design of `emit_c.c`.

## See also

- [[bootstrap/Roadmap]]
- [[bootstrap/Checks]]
- [[bootstrap/Friction]]
- [[bootstrap/study/IR]]
- [[bootstrap/study/Bootstrapping]]
- [[design/Compiler]]
- [[design/language/CInterop]]
- [[plans/V1Compiler]]
