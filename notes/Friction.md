---
status: draft
tags:
  - bootstrap
  - usability
  - log
---

# Friction log

This log is the usability result of [[bootstrap/Roadmap]]. Every time Jog gets in the way while writing std, JogLSP or JogCompiler, add an entry: a missing std function, an awkward syntax, a confusing error message, a C compiler bug, a feature you reached for that doesn't exist. Write it when it happens, even if it seems small. Small things that repeat are the most useful findings.

Newest entries go at the top of the log. When an entry leads to a change in the language notes or the compiler, link the change and set the status to `fixed` or `decided`.

## Template

```
### YYYY-MM-DD: short title

- **Phase:** P1 / P2 / P3 stage N / P4 / P5
- **Where:** repo and file, e.g. JogCompiler src/lexer.jog
- **Kind:** language / std / compiler bug / error message / tooling
- **Symptom:** what you tried to write and what happened.
- **Workaround:** what you wrote instead.
- **Proposal:** the language, std or compiler change that would fix it, with a link to the relevant note in design/language/.
- **Status:** open / fixed / decided / won't fix
```

## Log

### 2026-10-25: `pkg.fn<T>()` does not apply the type argument

- **Phase:** P2
- **Where:** JogLSP `server/src/json.test.jog`
- **Kind:** compiler bug
- **Symptom:** `lists.empty<str>()` fails with "cannot infer type parameter 'T'". The same call written `empty<str>()` in the `list` package itself typechecks. A type argument after a dotted name is dropped, so the call is treated as `empty()` with no `T`.
- **Workaround:** Give the variable a type (`var xs: lists.List<str>`) or avoid the call. The server builds lists with `var xs: lists.List<T>` and `push`.
- **Proposal:** Parse type arguments on a selector the same way as on a bare name, then typecheck `pkg.fn<T>(...)`. See [[design/language/Generics]].
- **Status:** open

### 2026-10-25: `jog test` runs tests from imported std packages

- **Phase:** P2
- **Where:** JogLSP `server/`, importing `std.testing`, `std.list`, `std.strbuilder`, `std.os`, `std.proc`
- **Kind:** tooling
- **Symptom:** `jog test` in the server module executes `@test` functions inside those std packages, including `expectPanic` cases that print `panic:` lines. The server tests can still pass, but the output is the std suite's as well.
- **Workaround:** Treat a nonzero exit as failure. Ignore `panic:` lines that name a `std/` file.
- **Proposal:** Load `*.test.jog` only for the package under test, not for every imported dependency. See [[design/language/Syntax]], section "Tests".
- **Status:** open

### 2026-10-25: `*c.char` cannot redeclare `const char *`

- **Phase:** P1
- **Where:** CTools `std/os/os.jog`, `std/c/c.jog`, `runtime/jogrt.h`
- **Kind:** compiler bug
- **Symptom:** `fn jogrt_argv(i: c.int, len: *c.size_t): *const c.char?` fails when the generated C is compiled. `c.char` is `i8`, so the backend emits `const int8_t *`. `jogrt.h` declares `const char *jogrt_argv`, and those pointer types conflict. Clang reports `conflicting types for 'jogrt_argv'`.
- **Workaround:** Call `jogrt_arg_ptr`, which returns `const int8_t *` and is not in `jogrt.h`. The wasm runtime already had it. The native runtime now has the same function. `std.os.argv` takes the length with `strlen`.
- **Proposal:** Emit C `char` for an extern `*c.char`, so a binding can redeclare a libc or runtime function that uses `char *`. See [[design/language/CInterop]].
- **Status:** open

### 2026-10-25: private `bytes` field store keeps the first local

- **Phase:** P1
- **Where:** CTools `std/arena/arena.jog`, `compiler/src/check_package.c`
- **Kind:** compiler bug
- **Symptom:** A private function with no `with` clause is checked twice, once while inferring contexts and once for real. The second pass binds a new local. `view.ptr = p` and `view.len = n` did not look that name up again, so lowering still held the first local and failed with "cannot assign to field 'ptr'". The same store in a public function, or in a private function that already declares a context, succeeded.
- **Workaround:** None. The arena builds a `bytes` header in private helpers.
- **Proposal:** On the second check, resolve an ident base of a `bytes` or slice field store again, so the store uses the local from that pass. See [[design/language/Contexts]] and [[design/language/Memory]].
- **Status:** fixed. `jog_check_package_view_assign` rechecks an ident base. `tests/jog/private_bytes.jog` stores `ptr` and `len` from a private function and a private method.

### 2026-10-25: `bytes` does not convert to `str`

- **Phase:** P1
- **Where:** CTools `std/strbuilder/strbuilder.jog`, `compiler/src/check_body.c`, `compiler/src/lower.c`
- **Kind:** compiler bug
- **Symptom:** `str` is const `bytes`. Building a header with `view.ptr` and `view.len` on a `bytes` value, then returning it as `str`, failed with "type mismatch: expected str, got bytes". `view as str` failed with "cannot cast bytes to str". The fields of a `str` cannot be assigned, because the view is const. `StrBuilder.str` needs that header and must not copy the bytes.
- **Workaround:** None. The builder returns the live block as a `str`.
- **Proposal:** Accept the implicit `bytes` to const `bytes` conversion [[design/language/Types]] already describes, and the same conversion as an `as` cast. Lower it as a bitcast of the header. The reverse stays rejected.
- **Status:** fixed. `expect_type` and `as` accept `bytes` to `str`. Lowering bitcasts the header. `tests/jog/bytes_str.jog` assigns the view, casts it, and returns an empty `bytes()`.

### 2026-10-25: `null` keeps an open `*T?` type

- **Phase:** P1
- **Where:** CTools `std/map/map.jog`, `compiler/src/lower_error.c`
- **Kind:** compiler bug
- **Symptom:** `self.ptr = null`, with `ptr: *Slot<K, V>?`, lowered the null as `*Slot<K, V>?` instead of the concrete pointer. The C backend then failed with "Slot<K, V> has no layout". A niche option takes the null path and did not substitute.
- **Workaround:** None. `free` clears the slot pointer.
- **Proposal:** Run `null`'s type through the generic substitution before emitting it, as other operands already do. See [[design/language/Types]].
- **Status:** fixed. `jog_lower_error_null` substitutes first. `tests/jog/open_index.jog` assigns `null` to `*Box<T>?`.

### 2026-10-25: `*Slot<K, V>` cannot be indexed inside a generic

- **Phase:** P1
- **Where:** CTools `std/map/map.jog`, `compiler/src/check_memory.c`
- **Kind:** compiler bug
- **Symptom:** `slots[i]` with `slots` a `*Slot<K, V>` inside `Map<K, V>` failed with "pointer arithmetic needs a size". `*T` was already accepted. `Slot<K, V>` still names type parameters, so the open struct has no layout yet.
- **Workaround:** None. The map stores entries in one block of slots.
- **Proposal:** Treat an open generic type as sized while checking the template, the same way a bare type parameter is. Lowering substitutes the concrete layout. `*void` stays unsized. See [[design/language/Memory]].
- **Status:** fixed. `has_size` in `compiler/src/check_memory.c` accepts a type that still contains a type parameter. `tests/jog/open_index.jog` writes through `*Box<T>` for `i32` and a struct whose size is not 4.

### 2026-10-25: method type parameters drop the struct constraint

- **Phase:** P1
- **Where:** CTools `std/map/map.jog`, `compiler/src/check_generic.c`
- **Kind:** compiler bug
- **Symptom:** `struct Map<K: cmp.Comparable, V>` stores the constraint on the struct, but `fn *Map<K, V>.get` bound a fresh `K` with a null constraint. `key == slot.key` in the method failed with "operator '==' does not apply to K".
- **Workaround:** None. The map compares keys in its methods.
- **Proposal:** Copy each struct or enum type parameter's constraint onto the method type parameter in the same position. The body then has those operations, and a call checks the same constraint. See [[design/language/Generics]].
- **Status:** fixed. `jog_generic_bind_receiver_params` waits until the struct or enum has bound its parameters, then copies the constraint. `tests/jog/method_constraint.jog` compares through `Box<T: Ordered>.max` and `EqBox<T: Eq>.same`, including `str`.

### 2026-10-25: `*T` cannot be indexed inside a generic

- **Phase:** P1
- **Where:** CTools `std/list/list.jog`, `compiler/src/check_memory.c`
- **Kind:** compiler bug
- **Symptom:** `fresh[i] = old[i]`, with `fresh` a `*T` inside `List<T>`, failed with "pointer arithmetic needs a size". `T` is a type parameter, so the template has no layout yet. `raw.ptr as *T` already typechecked, and `size(T)` / `align(T)` already fold after monomorphization.
- **Workaround:** None. The list keeps a `*T?` buffer and indexes it.
- **Proposal:** Treat a type parameter as sized while checking the template. Lowering substitutes the concrete layout, and C pointer arithmetic scales by that size. `*void` stays unsized. See [[design/language/Memory]].
- **Status:** fixed. `has_size` in `compiler/src/check_memory.c` accepts a type parameter. `tests/jog/ptr_index.jog` stores through `*u8 as *T` for `i32` and a struct whose size is not 4.

### 2026-10-24: `self.xs[i]` is "not lowered yet" in some methods

- **Phase:** P3 stage 4, P3 stage 5
- **Where:** CTools [[bootstrap/study/TypeChecking]] and [[bootstrap/study/IR]], Jog exercises
- **Kind:** compiler bug
- **Symptom:** In a pointer-receiver method, `when self.nodes[i] { ... }` fails with "name 'self' is not lowered yet". A probe showed `self.xs[i]` failing the same way in a pointer-receiver method that is never called. Copying the element into a local first did not help.
- **Workaround:** Copy the slice into a local and index that: `val nodes = self.nodes`, then `nodes[i]`.
- **Proposal:** Fix lowering of indexed field access on `self`; `compiler/src/lower.c` should treat `self` like any other bound parameter. No language change. See [[design/language/Structs]].
- **Status:** open

### 2026-10-24: field access through a pointer stored in a field fails

- **Phase:** P3 stage 5
- **Where:** CTools [[bootstrap/study/IR]], Jog exercise
- **Kind:** compiler bug
- **Symptom:** With `struct L { f: *F }`, `self.f.n` fails with "missing field" at `jog emit-ir`, for both `fn L.m()` and `fn *L.m()` receivers. The checker accepts it; lowering does not auto-dereference the inner pointer.
- **Workaround:** Copy the pointer into a local first: `val f = self.f`, then `f.n`. Every `Lower` method in the exercise starts this way.
- **Proposal:** Auto-dereference every pointer step in a field chain during lowering, as the checker already does. See [[design/language/Structs]].
- **Status:** open

### 2026-10-24: cannot assign to a field of an array element in a struct

- **Phase:** P3 stage 6
- **Where:** CTools [[bootstrap/study/CodeGen]], Jog exercise
- **Kind:** compiler bug
- **Symptom:** With `var f: Func`, `f.blocks[0].term = Term(...)` fails with "cannot assign to field 'term'". The place is a mutable local, so it should be assignable.
- **Workaround:** Take the element's address and assign through it, in a helper: `val blk = &f.blocks[b]; blk.term = t`.
- **Proposal:** Treat `x.arr[i].field` as an lvalue whenever `x` is. See [[design/language/Structs]].
- **Status:** open

### 2026-10-24: pointer method cannot be called on an array element

- **Phase:** P3 stage 3
- **Where:** CTools [[bootstrap/study/NameResolution]], Jog exercise
- **Kind:** compiler bug
- **Symptom:** With `var scopes: [16]StrMap`, `scopes[depth - 1].put(name, next)` is rejected. The element is addressable, and [[design/language/Structs]] says `&` is taken automatically for a pointer receiver on an addressable value.
- **Workaround:** `val top = &scopes[depth - 1]`, then `top.put(name, next)`.
- **Proposal:** Take the address automatically for indexed elements, as for locals and fields. See [[design/language/Structs]].
- **Status:** open

### 2026-10-24: clang warns `-Wbuiltin-requires-header` on `fopen`, `fread`, `fwrite`

- **Phase:** P1 (any program that imports `std.io`)
- **Where:** CTools std/io/io.jog and compiler/src/emit_c.c, seen building the [[bootstrap/study/DataStructures]] and later exercises
- **Kind:** compiler bug
- **Symptom:** Every build that pulls in `std.io` prints, for example, `warning: declaration of built-in function 'fopen' requires inclusion of the header <stdio.h> [-Wbuiltin-requires-header]`, pointing at `extern jt38 fopen(jt34 l0, jt34 l1);` in the generated C. The same warning appears for `fread` and `fwrite`. `mismatch_flag` in compiler/src/cc.c silences `-Wincompatible-library-redeclaration`, not this one. Generated C is meant to be warning-free.
- **Workaround:** None; the warning is harmless today and was ignored.
- **Proposal:** Either include `<stdio.h>` in the prelude when these externs are used and skip emitting their declarations, or add `-Wno-builtin-requires-header` next to the existing clang flag. See [[design/language/CInterop]].
- **Status:** open

### 2026-10-24: a value does not convert to `T?`, and `Some` cannot be written

- **Phase:** P1
- **Where:** CTools [[bootstrap/study/DataStructures]], Jog exercise (`StrMap.find`)
- **Kind:** language
- **Symptom:** Returning a `usize` where `usize?` is expected (and `i32` for `i32?`) is rejected, although [[design/language/Types]] says `T` converts implicitly to `T?`. Writing `.Some(value: i)` fails with "enum variant needs a known type", and there is no `Option` name to qualify it with.
- **Workaround:** Return a sentinel instead of an option: `find` uses `slots.len` to mean "no tombstone seen", and lookups return `(value, bool)`.
- **Proposal:** Implement the implicit `T` to `T?` wrap and make `Option` and `Some` nameable, as [[design/language/Types]] specifies.
- **Status:** open

### 2026-10-24: indexing a `str` and casting to `u8` is rejected

- **Phase:** P1, P3 stage 1
- **Where:** CTools [[bootstrap/study/DataStructures]] and [[bootstrap/study/Lexing]], Jog exercises
- **Kind:** language
- **Symptom:** `key[i] as u8` and `src[at] as u8` are rejected. [[design/language/Types]] makes indexing a byte view give `bytes[1]`, which should cast to `u8`.
- **Workaround:** Read `key.ptr[i]`, which gives a `u8` but is not bounds-checked, with an explicit length check before it.
- **Proposal:** Allow `bytes[1] as u8` (or make indexing a `str` give `u8` directly), so byte loops stay bounds-checked. See [[design/language/Types]].
- **Status:** open

### 2026-10-24: char literal compared with `u8` defaults to `i64`

- **Phase:** P1, P2, P3 stage 1, P3 stage 2, P5
- **Where:** CTools [[bootstrap/study/Lexing]], [[bootstrap/study/Parsing]], [[bootstrap/study/CodeGen]], [[bootstrap/study/LSP]] and [[bootstrap/study/Bootstrapping]], Jog exercises
- **Kind:** language
- **Symptom:** `c >= 'a'` with `c: u8` is a type mismatch: the char literal is typed as `i64` instead of adapting to `u8` the way an untyped integer constant does.
- **Workaround:** Write `'a' as u8` everywhere a char literal meets a byte.
- **Proposal:** Make char literals untyped constants that adapt to the integer type they meet and fail only if the code point does not fit, and say so in the literal table in [[design/language/Syntax]] and in [[design/language/Types]].
- **Status:** open

### 2026-10-24: `==` is not defined on enums

- **Phase:** P3 stage 1, P3 stage 4
- **Where:** CTools [[bootstrap/study/Lexing]] and [[bootstrap/study/TypeChecking]], Jog exercises
- **Kind:** language
- **Symptom:** `tok.kind == Kind.Eof` and `t == Ty.Int` are rejected for payload-free variants.
- **Workaround:** Use `x is Variant` in tests and conditions, and a `same(a, b)` helper written with `when` where two enum values are compared.
- **Proposal:** Define `==` for enums whose variants have no payloads (or whose payloads are all comparable), or record in [[design/language/OpenQuestions]] that `is` is the only way. See [[design/language/Types]].
- **Status:** open

### 2026-10-24: enums have no zero value

- **Phase:** P3 stage 5
- **Where:** CTools [[bootstrap/study/IR]], Jog exercise
- **Kind:** language
- **Symptom:** A fixed array of an enum type, or a struct containing one, cannot be declared without an initializer. [[design/language/Types]] says an enum's zero value is the variant with tag 0, the first variant by default.
- **Workaround:** Instructions and terminators are structs with a `u8` opcode field and named `u8` constants instead of enums.
- **Proposal:** Give enums the zero value the spec describes (`jog_check_type_has_zero` in compiler/src/check_body.c). See [[design/language/Types]].
- **Status:** open

### 2026-10-24: `[]u8` does not convert to `[]const u8`

- **Phase:** P2
- **Where:** CTools [[bootstrap/study/LSP]], Jog exercise (`readFrame`)
- **Kind:** language
- **Symptom:** Passing a `[]u8` slice of a buffer to a `[]const u8` parameter is a type mismatch. [[design/language/Types]] says `[]T` converts implicitly to `[]const T`.
- **Workaround:** Declare the reader's parameters as `[]u8`, although they never write.
- **Proposal:** Implement the implicit `[]T` to `[]const T` conversion. See [[design/language/Types]].
- **Status:** open

### 2026-10-24: `[]u8` cannot become a `str`

- **Phase:** P2, P3 stage 6, P5
- **Where:** CTools [[bootstrap/study/CodeGen]], [[bootstrap/study/LSP]] and [[bootstrap/study/Bootstrapping]], Jog exercises
- **Kind:** language
- **Symptom:** After writing text into a `[N]u8` buffer, `val s: str = buf[0..n]` is a type mismatch and `buf[0..n] as str` fails with "cannot cast []u8 to str". The fields of a `str` cannot be assigned either. There is no way to return built text as a `str`.
- **Workaround:** Compare the buffer with expected text through a helper (`same(want: str, got: []u8)`) instead of producing a `str`.
- **Proposal:** Decide in [[design/language/Types]] whether `[]u8` is `bytes`. If it is, `[]u8` should convert to `str` the way `bytes` converts to `const bytes`, perhaps with UTF-8 validity left to the caller.
- **Status:** open

### 2026-10-24: no typed slice allocation

- **Phase:** P1
- **Where:** CTools [[bootstrap/study/DataStructures]], Jog exercise (`StrMap.grow`)
- **Kind:** std
- **Symptom:** `a.alloc` returns `bytes`, and `bytes as []Slot` is rejected. There is no `newSlice<T>` in std. The byte size of a type is `size(T): usize` and the alignment is `align(T): usize`, both compile-time constants, including inside a generic. The slice still has to be built by hand.
- **Workaround:** Use `size(Slot)` for the byte length and `align(Slot)` for the alignment `Allocator.alloc` asks for. Build the slice by assigning `fresh.ptr = raw.ptr as *Slot` and `fresh.len = cap`, and rebuild a `bytes` the same way to free it.
- **Proposal:** Add `newSlice<T>(n)` and `freeSlice<T>(s)` to std.mem, using `size(T)` and `align(T)`. Allowing `bytes as []T` as an unchecked cast is still open. See [[design/language/Memory]] and [[design/language/Types]].
- **Status:** open

### 2026-10-24: no `wrappingMul`

- **Phase:** P1
- **Where:** CTools [[bootstrap/study/DataStructures]], Jog exercise (`fnv1a`)
- **Kind:** std
- **Symptom:** `h.wrappingMul(prime)` fails with "unknown field". [[design/language/Types]] promises explicit wrapping operations for hashing, and checked arithmetic traps on the 64-bit FNV product.
- **Workaround:** Compute 32-bit FNV-1a in `u64` and mask after each step, so the product always fits.
- **Proposal:** Add `wrappingAdd`, `wrappingSub` and `wrappingMul` on the integer types. See [[design/language/Types]].
- **Status:** open

### 2026-10-24: `op` is a reserved word

- **Phase:** P3 stage 2
- **Where:** CTools [[bootstrap/study/Parsing]], Jog exercise
- **Kind:** language
- **Symptom:** A field named `op` in a binary expression node fails to parse. This matches the spec, which lists `op` among the keywords for operator methods (`fn u32.op+`), but `op` is the natural name for an operator field in every compiler.
- **Workaround:** Name the field `sym`.
- **Proposal:** Make `op` a contextual keyword, special only directly after `fn T.`, and update the keyword list in [[design/language/Syntax]] and [[design/language/Grammar]].
- **Status:** open

### 2026-10-24: unused imports are not reported

- **Phase:** P3 stage 3
- **Where:** CTools compiler/src/resolve_package.c, found while writing [[bootstrap/study/NameResolution]]
- **Kind:** language
- **Symptom:** [[design/language/Syntax]] makes an unused import an error, but the resolver does not report it, and `resolve_package.h` says so.
- **Workaround:** None needed in Jog code. `jogc` must match `jog`'s current behavior while it is compared against it.
- **Proposal:** Report unused imports in `jog`, then in `jogc`, or relax the rule in [[design/language/Syntax]].
- **Status:** open

### 2026-10-24: `jog test` exits 0 when a test fails

- **Phase:** P1 and every later phase that runs tests
- **Where:** CTools std/testing/testing.jog, seen while checking every study exercise
- **Kind:** std
- **Symptom:** A failing `t.expect` prints `fail` to stderr, without the test name, and the test program still exits with status 0, so `jog test` reports success to scripts. `Test.expect` and `Test.expectEq` only print; nothing records the failure. `cmd_build.c` already turns a nonzero exit into an error.
- **Workaround:** Treat any `fail` line in the output as a failure, and break a test on purpose once to make sure it can fail.
- **Proposal:** Record failures in the `Test` value and exit nonzero at the end of the run, naming the failing test and its `file:line`. See [[design/language/Syntax]], section "Tests".
- **Status:** fixed. `expect`, `expectEq`, and `fail` increment a counter, and the test harness calls `finish`, which exits 1 when that count is nonzero.

## See also

- [[bootstrap/Roadmap]]
- [[bootstrap/Checks]]
- [[design/language/OpenQuestions]]
