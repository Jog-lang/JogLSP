---
status: draft
tags:
  - bootstrap
  - study
  - compiler
  - checker
---

# Type checking

The checker decides whether a program means anything, and what. For every expression it computes a type, for every name a symbol, and for every rule in the language notes an error when the rule is broken. It is stage 4 of JogCompiler and by far the largest: in the C V1, `check.c` and the `check_*.c` files are a large share of `compiler/src`. The plan in [[bootstrap/Roadmap]] is to write it first for the subset of Jog that JogCompiler itself uses, and only then for the rest.

## Key ideas

### Types are data

A type is a value the compiler builds and compares. Scalars (`i32`, `bool`) are a fixed set. Structural types (`*T`, `[]T`, `[N]T`, `T?`, tuples, function types) are built from other types. Nominal types (structs, enums, interfaces, distinct types) are created once per declaration and are equal only to themselves.

If structural types are **interned**, building `*i32` twice returns the same object, and type equality becomes pointer equality. That makes the checker simpler and faster, and is the same trick as name interning. See [[bootstrap/study/DataStructures]].

### Checking and inference: the expected type

There are two directions information can flow:

- **Inference** (synthesis): look at an expression and compute its type. `a + b` with `a: i32` is `i32`.
- **Checking**: an expected type is known from context, and the expression is checked against it. In `val x: u8 = 200`, the literal is checked against `u8`.

Passing an optional expected type down into `checkExpr(node, target)` gets most of the benefit of bidirectional typing with very little machinery. With a target, untyped constants take the target type, `null` becomes the right option type, `.Variant` finds its enum, and a lambda's parameter types come from the function type it is assigned to. Without a target, the expression synthesizes its own type, and constants fall back to a default (`i64`, `f64`).

### Untyped constants

`200 + 100 - 50` is a valid `u8` in Jog, because constant expressions are evaluated exactly and only the final value must fit. So integer literals start with an "untyped integer" type, constant subexpressions are folded with arbitrary precision, and the untyped value is converted, with a range check, once it meets a typed context. Operands that already have different integer types do not mix. Go works the same way. See [[design/language/Types]].

### Conversions and assignability

Jog has very few implicit conversions, and the checker must know every one: `T` to `T?`, `*T` to `*const T` (planned), a pointer to a struct to an interface it satisfies, untyped constants to a typed context. Everything else needs `as`, and `as` itself has rules about what may convert to what. One function, "is a value of type A assignable to B", used everywhere (arguments, returns, assignments, fields), keeps these rules consistent.

### The error type

After reporting "undefined name `x`", the checker still has to give `x` some type. If it picks `i32`, every later use of `x` produces another, misleading error. The fix is a **poison** type that is compatible with everything and never reported again. One mistake then produces one message, which is what [[bootstrap/Reading]]'s "Compiler Errors for Humans" asks for.

### Declaration order and cycles

Top-level declarations may refer to each other in any order. Checking `fn f(): Point` needs the type `Point`, which may be declared later or in another file. Two strategies:

- **On demand with an in-progress mark.** Check declarations lazily. When `f` needs `Point`, check `Point` right now (recursively), marking it "in progress" first. Reaching an in-progress declaration again is a cycle.
- **On demand with coroutines.** Check each declaration in its own coroutine. When one needs a declaration that is not finished, it parks until that one is done. If every remaining coroutine is parked, the parked-on chain is a cycle, and it is also the error message.

Not every reference is a dependency on a *finished* declaration. `struct Node { next: *Node? }` needs only the identity of `Node`, not its layout, so a pointer to a type in progress is fine while a by-value field is a real cycle.

### Generics by monomorphization

Jog generics are monomorphized: each distinct instantiation (`Box<i32>`, `Box<bool>`) is checked and later lowered as its own copy. The checker has to:

1. solve the type arguments at a call, from explicit `<...>` or by matching parameter types against argument types;
2. substitute them into the signature (rebuilding only the parts that change, to keep interning intact);
3. cache the instance by its argument list, so the same instance is never built twice.

Constraints (`T: Ordered`, type sets) are checked when the arguments are known. See [[design/language/Generics]].

### Flow-sensitive checks

Some rules depend on control flow, not just on types:

- **Definite assignment.** A `var p: *T` with no initializer has no zero value, so it must be assigned on every path before it is read.
- **Reachability and missing returns.** A function with a result type must not fall off the end. `return`, `panic` and an exhaustive `when` end a path.
- **Exhaustiveness.** A `when` over an enum must cover every variant, or have `else`.
- **Narrowing.** After `if s is Circle`, `s` is a `Circle` inside the branch; on the right of `&&`, too.

These are computed while walking a body, by carrying a small "state" (assigned variables, reachable or not) and merging it at joins.

## How the C V1 does it

- **Types: `compiler/src/types.h` and `types.c`.** `JogType` with `JogTypeKind` (`JOG_TY_ERROR` is the poison type, `JOG_TY_UNTYPED_INT` and `JOG_TY_UNTYPED_FLOAT` the constant types). Structural constructors `jog_type_ptr`, `jog_type_slice`, `jog_type_array`, `jog_type_option`, `jog_type_tuple` and `jog_type_fn` intern by a canonical key. Nominal types come from `jog_type_new_nominal`. `jog_type_layout` computes C-compatible size, alignment and field offsets, and `jog_type_print` spells a type for messages.
- **The scheduler: `compiler/src/check.c`, entry `jog_check`.** It builds the universe (`jog_universe_scope`), runs `jog_resolve_packages`, then `collect_jobs` makes one `CheckJob` per top-level declaration, and `run_jobs` starts one coroutine per job with `coroutine_go` from `tools/coro.h`. `run_job` calls `check_decl`, which dispatches to `check_type_decl`, `check_fn` and `check_binding`. A job that needs another declaration calls `wait_for_symbol` (exposed as `jog_check_wait`), which sets `waiting_for` and `parked` and yields until the other job is `done`. The struct and enum identity exception described above is the `until_done` case in `wait_for_symbol`. When `blocked` reports that every live job is parked, `report_wait_cycles` walks the `waiting_for` chains and `report_cycle` prints "declaration cycle: a -> b -> a".
- **Bodies: `compiler/src/check_body.c`.** `check_expr(env, node, target)` is the bidirectional entry: `target` is the expected type, or NULL to infer. Read `check_binary`, `check_call`, `check_cast`, `check_if`, `check_local_binding`, `check_assign`, `check_return` and `check_for`. `jog_check_type_has_zero` decides which types need definite assignment, and `jog_check_body_unreachable` records that a path has ended.
- **Constants: `compiler/src/const_eval.c`, entry `jog_const_eval`.** Exact integer folding with `JOG_TY_UNTYPED_INT` intermediates, range checks against the target, and hex literals as `bytes[N]`.
- **Generics: `compiler/src/check_generic.c`.** `jog_check_generic_instantiate` solves a call's type arguments and returns the substituted signature; `jog_check_generic_method` does the same for methods. `jog_generic_subst` substitutes while preserving interned identity, and `jog_generic_struct_instance` and `jog_generic_enum_instance` create one nominal type per argument list. Instances are recorded on the symbol (`generic_insts`, `nominal_insts` in `symbols.h`). Constraints are in `check_constraint.c`.
- **Feature files**, each owning one area of the language notes: `check_struct.c` (fields, literals, embedding, methods), `check_enum.c` (enums, `when`, patterns, exhaustiveness, `is`), `check_interface.c`, `check_error.c` (`error?` returns), `check_memory.c` (pointers, slices, indexing, pointer arithmetic, `@unchecked`), `check_string.c` (interpolation), `check_context.c` (contexts and inference of private `with` clauses), `check_coro.c`, `check_comptime.c` and `check_package.c` (cross-package names and `@test`).
- **Tests:** `tests/check/ok_*.jog` must check cleanly and `tests/check/err_*.jog` must report specific errors, driven by `tests/check_test.c`. These are the differential corpus for `jogc`.

## Questions to answer in your own words

1. What does passing an expected type into `check_expr` buy you? Give three Jog expressions that cannot be typed without one.
2. Why is `200 + 100 - 50` a valid `u8`, but `var a: u8 = 200; val b = a + 100` an overflow risk the checker cannot rule out? Where does the untyped type stop?
3. What goes wrong, concretely, if an undefined name is given type `i32` instead of the error type?
4. Why is `struct Node { next: *Node? }` not a cycle, while `struct A { b: B }` with `struct B { a: A }` is? Where does `wait_for_symbol` make that distinction?
5. Compare the coroutine scheduler in `check.c` with a recursive "in progress" mark. Which gives the better cycle message, which is easier to debug, and which would you write in Jog? (This is the open decision in [[bootstrap/Roadmap]].)
6. Why must instantiations be cached by their type arguments? What happens to type identity if `Box<i32>` is created twice?
7. How would you compute "every path assigns `p` before it is read" across an `if` without an `else`?
8. When is a `when` exhaustive without an `else`, and why does that matter for a function's missing-return check?

## Jog exercise

Write a checker for a tiny expression language: integer and boolean literals, `+`, `<`, and `if`. The AST is stored as an array of nodes that refer to their children by index, which avoids allocating each node, and is how several real compilers (Zig, Carbon) lay out their trees. The checker infers a type for each node, records it, and counts errors without cascading.

```
import std.testing

enum Ty {
    Int
    Bool
    Bad
}

enum Node {
    IntLit(v: i64)
    BoolLit(v: bool)
    Add(l: usize, r: usize)
    Less(l: usize, r: usize)
    If(c: usize, yes: usize, no: usize)
}

fn same(a: Ty, b: Ty): bool {
    return when a {
        Int -> b is Int
        Bool -> b is Bool
        Bad -> b is Bad
    }
}

struct Checker {
    nodes: []const Node
    types: []Ty
    errors: i32
}

// Infers node i, checks it against want, and reports at most one error.
// Bad is compatible with everything, so one mistake gives one message.
fn *Checker.expect(i: usize, want: Ty): Ty {
    val got = self.infer(i)
    if !(got is Bad) && !same(got, want) {
        self.errors += 1
        return Ty.Bad
    }
    return got
}

fn *Checker.infer(i: usize): Ty {
    val nodes = self.nodes
    val t = when nodes[i] {
        IntLit(_) -> Ty.Int
        BoolLit(_) -> Ty.Bool
        Add(l, r) -> self.arith(l, r, Ty.Int)
        Less(l, r) -> self.arith(l, r, Ty.Bool)
        If(c, yes, no) -> self.ifExpr(c, yes, no)
    }
    self.types[i] = t
    return t
}

fn *Checker.arith(l: usize, r: usize, result: Ty): Ty {
    val a = self.expect(l, Ty.Int)
    val b = self.expect(r, Ty.Int)
    if a is Bad || b is Bad {
        return Ty.Bad
    }
    return result
}

fn *Checker.ifExpr(c: usize, yes: usize, no: usize): Ty {
    self.expect(c, Ty.Bool)
    val a = self.infer(yes)
    if a is Bad {
        return self.infer(no)
    }
    return self.expect(no, a)
}

@test
fn oneErrorPerMistake() with (t: testing.Testing) {
    // if 1 < true { 1 } else { 2 } + 3
    val nodes = []const Node(
        Node.IntLit(v: 1),
        Node.BoolLit(v: true),
        Node.Less(l: 0, r: 1),
        Node.IntLit(v: 1),
        Node.IntLit(v: 2),
        Node.If(c: 2, yes: 3, no: 4),
        Node.IntLit(v: 3),
        Node.Add(l: 5, r: 6),
    )
    var types = [8]Ty(Ty.Bad, Ty.Bad, Ty.Bad, Ty.Bad, Ty.Bad, Ty.Bad, Ty.Bad, Ty.Bad)
    var ck = Checker(nodes: nodes, types: types[..], errors: 0)
    val root = ck.infer(7)
    t.expect(ck.errors == 1)
    t.expect(root is Int)
}
```

Two workarounds here belong in [[bootstrap/Friction]]: the `same` helper exists because V1 does not define `==` on enums yet, and `infer` copies `self.nodes` into a local because V1 fails to lower `self.nodes[i]` there ("name 'self' is not lowered yet").

Then extend it:

- Add an untyped integer: `IntLit` infers `Untyped`, which converts to `Int` or to a new `Byte` type when an expected type asks for it, and defaults to `Int` otherwise. That means turning `infer` into `check(i, want: Ty)` with an optional expected type.
- Add `Var(name)` and `Let(name, value, body)` nodes and a scope, reusing [[bootstrap/study/NameResolution]].
- Add a declaration list where one declaration can refer to another, and detect cycles with an "in progress" state per declaration. Print the chain the way `report_cycle` does.
- Make types interned: `Ptr(elem)` and `Slice(elem)` built through a table so equality is index equality.

## Reading

From [[bootstrap/Reading]]:

- Dunfield and Krishnaswami, "Bidirectional Typing": read sections 1 to 3 for the idea behind `target`.
- go/types tutorial: untyped constants, assignability and method sets in a language close to Jog.
- Modern Compiler Implementation in C, the type-checking chapter.
- Elm, "Compiler Errors for Humans", before writing any diagnostic text.

## See also

- [[bootstrap/Roadmap]]
- [[bootstrap/Checks]]
- [[bootstrap/Friction]]
- [[bootstrap/study/NameResolution]]
- [[bootstrap/study/IR]]
- [[design/language/Types]]
- [[design/language/Generics]]
- [[design/language/Errors]]
- [[plans/V1Compiler]]
