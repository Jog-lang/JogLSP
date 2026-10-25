---
status: draft
tags:
  - bootstrap
  - study
  - compiler
  - ir
---

# IR

Lowering turns the checked AST into an intermediate representation (IR): a small, explicit language with no nesting, no sugar and no implicit behavior. It is stage 5 of JogCompiler. The C V1's IR is called JIR, and `jog emit-ir` prints it, so `jogc emit-ir` can be compared against it the same way the lexer and parser were.

## Key ideas

### Why an IR at all

The AST is shaped like the source: nested expressions, `defer`, `when` with patterns, `?.`, `!!`, string interpolation, contexts. A backend that worked on the AST would have to understand all of that, and so would the compile-time interpreter, and so would a future native backend. An IR moves that understanding into **one** place, lowering, and gives every consumer a small language instead. [[plans/V1Compiler]] makes exactly this argument: the C backend, the interpreter, and a later x64 backend all read the same IR.

### Three-address code

Each instruction does one thing to at most two operands and writes at most one destination: `t3 = add t1, t2`, `t4 = load p`, `store p, t4`, `t5 = call f(t1, t2)`. Operands are locals or constants. A nested expression such as `a + b * c` becomes a sequence of instructions with temporaries:

```
t1 = mul b, c
t2 = add a, t1
```

Temporaries are just locals without a source name. The order of evaluation, which is invisible in the tree, is now explicit.

### Basic blocks and the control-flow graph

A **basic block** is a straight-line list of instructions that ends in exactly one **terminator**: an unconditional branch, a conditional branch, a switch, a return, or "unreachable". Control enters a block only at its top and leaves only through its terminator. The blocks and the edges between them form the **control-flow graph** (CFG), which is what analyses and backends walk.

Structured control flow becomes blocks and branches:

- `if c { A } else { B }`: evaluate `c`, `cond_br` to a then-block and an else-block, each ending in `br join`.
- `for cond { body }`: a head block that tests the condition, a body block that branches back to the head, and an exit block. `break` is `br exit`, `continue` is `br head` (or the step block for a range loop).
- `a && b`: **short-circuit** evaluation is control flow, not an operator. Evaluate `a`, `cond_br` to a block that evaluates `b` or to a block that produces `false`, and join.
- `if` and `when` used as values write their result into one local from each arm, and the join block reads it.

### SSA, and why V1 does not use it

In **SSA form** every local is assigned exactly once, and values that merge at a join are combined by `phi` instructions. SSA makes many optimizations simpler. It also makes the IR harder to produce and to read. JIR is not SSA: a local may be written many times, so `if` arms just copy into the same result local. A C compiler does the optimization anyway. SSA can come later, built from this IR, with the Braun et al. algorithm in [[bootstrap/Reading]].

### Lowering removes the language

By the time code is in the IR, these have become plain blocks and instructions:

- **`defer` and `errdefer`.** The lowerer keeps a stack of pending cleanups. Every path out of a scope (falling off the end, `return`, `break`, `continue`) emits copies of the cleanups that are on the stack above that scope's depth, innermost first. `errdefer` cleanups are emitted only on paths that return an error.
- **`when` and patterns** become tag reads, comparisons and `switch`, with bindings extracted from payloads.
- **Option and error sugar** (`?.`, `?:`, `!!`, `error?` returns) become tag tests and branches.
- **Contexts** become ordinary trailing parameters.
- **Generics** are already monomorphized, so each instance is its own function with concrete types.
- **Checks are explicit instructions:** overflow-checked arithmetic, bounds checks, null checks for `!!`, and `panic`. Every backend then implements them identically, and `@unchecked` simply omits bounds checks.

### Globals and initialization order

A top-level `var` whose initializer cannot be computed at compile time runs at startup. Lowering builds one init function that runs these initializers in dependency order: if one initializer reads another global, directly or through functions it calls, that global goes first. That is a topological sort over a dependency graph, and a cycle is a compile error. See [[design/language/Syntax]].

### Verifying the IR

A cheap structural verifier (every block terminated, every branch target and local index in range, a destination where an instruction produces a value) catches most lowering bugs at the point they are made, instead of as a confusing C compiler error later.

## How the C V1 does it

- **The IR: `compiler/src/ir.h`.** `JirOperand` is a local, an integer, float, string or C-string constant, `null`, a global's address, or a function. `JirOp` lists the instructions: `JIR_COPY`, `JIR_ZERO`, `JIR_BINARY` (with `JirBinOp` in `aux` and a `checked` flag), `JIR_UNARY`, `JIR_CONVERT`, `JIR_BITCAST`, `JIR_LOAD`, `JIR_STORE`, `JIR_ADDR`, `JIR_FIELD_ADDR`, `JIR_ELEM_ADDR`, `JIR_EXTRACT`, `JIR_AGGREGATE`, `JIR_ENUM_TAG`, `JIR_CALL`, `JIR_BOUNDS_CHECK`, `JIR_NULL_CHECK` and `JIR_PANIC`. `JirTerm` is `JIR_TERM_BR`, `JIR_TERM_COND_BR`, `JIR_TERM_SWITCH`, `JIR_TERM_RET` or `JIR_TERM_UNREACHABLE`. A `JirFunc` has `locals` (parameters first) and `blocks` (block 0 is the entry); a `JirModule` has `funcs`, `globals`, `main_func` and `init_func`. Builders: `jir_func_add`, `jir_local_add`, `jir_block_add`, `jir_emit`, `jir_terminate`, `jir_global_add`. `jir_verify` is the structural verifier, and `jir_dump` in `compiler/src/ir_dump.c` is the text form.
- **Lowering: `compiler/src/lower.c`, entry `jog_lower`.** The state is the `Lower` struct in `compiler/src/lower_internal.h`: the current function and block, a `terminated` flag, local bindings, a `loops` stack of `LoopFrame` (`cont`, `brk`, `cleanup_base`), the `cleanups` stack, and the active generic substitution (`subst_from`, `subst_to`). Read `lower_body`, `lower_block`, `lower_stmt` and `lower_expr`; `new_block`, `emit_br`, `emit_cond` and `emit_ret` for building the CFG; `lower_if_stmt` and `lower_if_expr`; `lower_logic` for `&&` and `||` (labels `and.rhs`, `and.false`, `and.join`); `lower_for` and `lower_collection_for`; `lower_call`; and `emit_binop`, which sets `checked`. Function names are built by `mangle_fn` and `mangle_global`.
- **`defer`, `errdefer` and error returns: `compiler/src/lower_error.c`.** `jog_lower_error_block_end` runs the cleanups at the end of a block, `jog_lower_error_exit` runs them on `break` and `continue` (down to the loop's `cleanup_base`), `chain` emits a sequence of cleanup bodies, and `return_plain` and `return_err` handle `return`, with `errdefer` only on the error path.
- **The other `lower_*.c` files** mirror the checker's feature files: `lower_enum.c` (`when`, patterns, options), `lower_struct.c`, `lower_interface.c` (method tables), `lower_memory.c`, `lower_string.c`, `lower_context.c`, `lower_generic.c`, `lower_coro.c` and `lower_comptime.c`.
- **Globals:** `lower_init` builds the init function, and `jog_lower_walk_init_deps` records which runtime globals each initializer reads, which is the dependency graph for the ordering.
- **The interpreter: `compiler/src/interp.c`, entry `jir_interp_call`.** It runs JIR functions at compile time for top-level `val` and `@comptime`, with a step budget.
- **Golden tests:** `tests/lower/*.jog` with their expected `*.ir` dumps. Here is part of `tests/lower/loops.ir`, for `for i in 0..n { if i == 0 { continue }; sum = sum + i }`:

```
b1 "for.head":
  l4 = lt l2, l3  ; loops.jog:6:5
  cond_br l4, b2 "for.body", b4 "for.exit"  ; loops.jog:6:5
b2 "for.body":
  l5 = eq l2, i32 0  ; loops.jog:7:14
  cond_br l5, b5 "if.then", b6 "if.join"  ; loops.jog:7:9
b3 "for.step":
  l7 = checked add l2, i32 1  ; loops.jog:6:5
  l2 = copy l7  ; loops.jog:6:5
  br b1 "for.head"  ; loops.jog:6:5
b5 "if.then":
  br b3 "for.step"  ; loops.jog:8:13
b6 "if.join":
  l6 = checked add l0, l2  ; loops.jog:10:19
  l0 = copy l6  ; loops.jog:10:13
  br b3 "for.step"  ; loops.jog:6:5
```

## Questions to answer in your own words

1. What would the C backend, the interpreter and a native backend each have to understand if there were no IR?
2. Lower `if a && b { x = 1 }` to blocks by hand. How many blocks, and which terminators?
3. Why does `continue` in a range loop branch to a step block and not to the head?
4. A `return` sits inside two nested blocks, each with a `defer`, inside a loop. Which cleanups run, in what order, and how does the lowerer know?
5. Why are bounds and overflow checks instructions rather than something each backend adds on its own?
6. What does SSA buy, and why is it reasonable for V1 to skip it?
7. Why must global initializers be ordered by dependency rather than by source order? What does a cycle look like?
8. What does `jir_verify` catch that the C compiler would otherwise report in a far less useful way?

## Jog exercise

Lower the tiny expression language from [[bootstrap/study/TypeChecking]] to basic blocks, then interpret the result. `If` becomes a conditional branch, two arm blocks that copy into one result local, and a join. The interpreter checks that lowering preserved the meaning, which is how you will test your real lowering against the C compiler later: by running the programs.

Instructions and terminators are small structs with an opcode field rather than enums, because V1 gives enums no zero value and fixed arrays of them cannot be declared without initializers.

```
import std.testing

val OpConst: u8 = 0
val OpAdd: u8 = 1
val OpLess: u8 = 2
val OpCopy: u8 = 3

val TermNone: u8 = 0
val TermBr: u8 = 1
val TermCondBr: u8 = 2
val TermRet: u8 = 3

enum Node {
    IntLit(v: i64)
    Add(l: usize, r: usize)
    Less(l: usize, r: usize)
    If(c: usize, yes: usize, no: usize)
}

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
    insts: [16]Inst
    count: usize
    term: Term
}

struct Func {
    blocks: [16]Block
    blockCount: usize
    localCount: usize
}

struct Lower {
    nodes: []const Node
    f: *Func
    cur: usize
}

// Each method copies self.f into a local first: V1 does not lower a field
// access through a pointer stored in a field (self.f.localCount).
fn *Lower.local(): usize {
    val f = self.f
    val l = f.localCount
    f.localCount += 1
    return l
}

fn *Lower.block(): usize {
    val f = self.f
    val b = f.blockCount
    f.blockCount += 1
    return b
}

fn *Lower.emit(inst: Inst) {
    val f = self.f
    val blk = &f.blocks[self.cur]
    blk.insts[blk.count] = inst
    blk.count += 1
}

fn *Lower.terminate(t: Term) {
    val f = self.f
    val blk = &f.blocks[self.cur]
    blk.term = t
}

fn *Lower.expr(i: usize): usize {
    val nodes = self.nodes
    return when nodes[i] {
        IntLit(v) -> self.constant(v)
        Add(l, r) -> self.binary(OpAdd, l, r)
        Less(l, r) -> self.binary(OpLess, l, r)
        If(c, yes, no) -> self.ifExpr(c, yes, no)
    }
}

fn *Lower.constant(v: i64): usize {
    val dst = self.local()
    self.emit(Inst(code: OpConst, dst: dst, a: 0, b: 0, imm: v))
    return dst
}

fn *Lower.binary(code: u8, l: usize, r: usize): usize {
    val a = self.expr(l)
    val b = self.expr(r)
    val dst = self.local()
    self.emit(Inst(code: code, dst: dst, a: a, b: b, imm: 0))
    return dst
}

fn *Lower.ifExpr(c: usize, yes: usize, no: usize): usize {
    val result = self.local()
    val cond = self.expr(c)
    val thenB = self.block()
    val elseB = self.block()
    val join = self.block()
    self.terminate(Term(kind: TermCondBr, value: cond, yes: thenB, no: elseB))
    self.cur = thenB
    val a = self.expr(yes)
    self.emit(Inst(code: OpCopy, dst: result, a: a, b: 0, imm: 0))
    self.terminate(Term(kind: TermBr, value: 0, yes: join, no: 0))
    self.cur = elseB
    val b = self.expr(no)
    self.emit(Inst(code: OpCopy, dst: result, a: b, b: 0, imm: 0))
    self.terminate(Term(kind: TermBr, value: 0, yes: join, no: 0))
    self.cur = join
    return result
}

fn lowerFn(nodes: []const Node, root: usize, f: *Func) {
    f.blockCount = 1
    var lw = Lower(nodes: nodes, f: f, cur: 0)
    val v = lw.expr(root)
    lw.terminate(Term(kind: TermRet, value: v, yes: 0, no: 0))
}

fn run(f: *Func): i64 {
    var locals: [64]i64
    var b: usize = 0
    for {
        val blk = &f.blocks[b]
        for k in 0..blk.count {
            val inst = blk.insts[k]
            if inst.code == OpConst {
                locals[inst.dst] = inst.imm
            } else if inst.code == OpAdd {
                locals[inst.dst] = locals[inst.a] + locals[inst.b]
            } else if inst.code == OpLess {
                locals[inst.dst] = if locals[inst.a] < locals[inst.b] { 1 } else { 0 }
            } else {
                locals[inst.dst] = locals[inst.a]
            }
        }
        val t = blk.term
        if t.kind == TermRet {
            return locals[t.value]
        }
        if t.kind == TermBr {
            b = t.yes
        } else if t.kind == TermCondBr {
            if locals[t.value] != 0 {
                b = t.yes
            } else {
                b = t.no
            }
        } else {
            panic("block is not terminated")
        }
    }
}

@test
fn lowerAndRun() with (t: testing.Testing) {
    // if 1 < 2 { 10 } else { 20 } + 5
    val nodes = []const Node(
        Node.IntLit(v: 1),
        Node.IntLit(v: 2),
        Node.Less(l: 0, r: 1),
        Node.IntLit(v: 10),
        Node.IntLit(v: 20),
        Node.If(c: 2, yes: 3, no: 4),
        Node.IntLit(v: 5),
        Node.Add(l: 5, r: 6),
    )
    var f: Func
    lowerFn(nodes, 7, &f)
    t.expect(f.blockCount == 4)
    t.expect(run(&f) == 15)
}
```

Then extend it:

- Write `dump(f)` in the style of `ir_dump.c` (`b0 entry:`, `l3 = add l1, l2`, `cond_br l4, b1, b2`) and compare your output for a few inputs with what you expect by hand.
- Add `And(l, r)` with short-circuit lowering, and a test where the right side would divide by zero if it were evaluated.
- Add a `Let` with a block scope and a `Defer` node, and emit the deferred instructions on every exit from the scope.
- Write a verifier: every block below `blockCount` has a terminator, and every branch target and local index is in range. Break the lowerer on purpose and watch it catch the bug.

## Reading

From [[bootstrap/Reading]]:

- Engineering a Compiler, the chapters on intermediate representations and on translating control flow.
- QBE's documentation, for a small, readable IR to compare with JIR.
- Braun et al., "Simple and Efficient Construction of SSA Form", later, if JIR ever moves to SSA.
- [[plans/V1Compiler]], section "IR", is the design of JIR.

## See also

- [[bootstrap/Roadmap]]
- [[bootstrap/Checks]]
- [[bootstrap/Friction]]
- [[bootstrap/study/TypeChecking]]
- [[bootstrap/study/CodeGen]]
- [[design/Compiler]]
- [[design/language/Errors]]
- [[plans/V1Compiler]]
