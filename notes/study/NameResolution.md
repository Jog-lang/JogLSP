---
status: draft
tags:
  - bootstrap
  - study
  - compiler
  - resolver
---

# Name resolution

Name resolution answers one question for every identifier in the program: which declaration does this name mean? It is stage 3 of JogCompiler, together with the loader that finds the packages in the first place. The answer is stored on the AST (each identifier node gets a pointer to a symbol) so that the checker, lowering and later the LSP's go-to-definition never have to search again.

## Key ideas

### Symbols and scopes

A **symbol** is the record of one declaration: its kind (type, function, variable, constant, field, method, parameter, package, ...), its name, the node that declared it, its type once the checker knows it, and the package it belongs to.

A **scope** maps names to symbols. Scopes nest, and lookup walks from the innermost scope outward, so an inner declaration **shadows** an outer one. In Jog the chain is:

1. block scopes, innermost first (function parameters are the outermost block of a body);
2. the **file scope**: the file's imports and its `private(file)` declarations;
3. the **package scope**: every top-level declaration that is visible in the package, from all files of the folder;
4. the **universe**: built-in names such as `i32`, `bool`, `str`, `true`, `false`, `null`.

Because names are interned, a scope is a hash map keyed by pointer-equal strings. See [[bootstrap/study/DataStructures]].

### Two kinds of order

Inside a function body, order matters: a local is visible only after its declaration, so body resolution walks statements in order, pushing a scope for each block and popping it at the end.

At the top level, order does not matter: a function can call one declared later in the file, or in another file of the same package. So top-level names are collected **before** any body is looked at. That is a pass over every file of a package that binds each declaration's name into the package or file scope. Only then are bodies resolved.

### Packages and imports

In Jog a folder is a package, and `import a.b.c` names a folder by its path from the module root (or `std`). The loader, not the resolver, turns imports into a graph:

- Find `jog.mod` by walking up from the start path. That folder is the module root.
- For each package, list its `.jog` files (plus `*.test.jog` under `jog test`), lex and parse them, read their imports, and load each imported package.
- Detect **import cycles** with the classic three-color depth-first search: a package is gray while its imports are being loaded, and reaching a gray package again is a cycle. The error names the chain, `left -> mid -> right -> left`.
- Emit the packages in **dependency order**, every package after the ones it imports. That order is also the order of global initialization at startup.

The resolver then binds an import as a symbol of kind package in the file scope, under its alias or its last path segment. `io.print` resolves `io` in the file scope, finds a package, and looks `print` up in that package's scope, subject to visibility.

### Visibility

Everything is public by default. `private` (or `private(package)`) restricts a name to its folder, `private(file)` to its file, and `private(scope)` to the enclosing declaration. The check is separate from lookup: lookup finds the symbol, and a visibility test from the use site decides whether the use is allowed. Keeping them separate gives better messages ("`x` is private" rather than "undefined name `x`").

### Things that look like names but are not resolved here

- **Fields and methods** depend on the type of the expression to their left, so `p.x` cannot be resolved until the checker knows the type of `p`. Methods are recorded on their declarations, not bound as package names.
- **Struct literals** look like calls: `Point(x: 1, y: 2)` is resolved to a type and only then reinterpreted as a literal.
- **Patterns** in `when`: a bare name is a variant if the subject's enum has one with that name, and a new binding otherwise. See [[design/language/Grammar]], rule 7.

So in practice, top-level binding is its own pass, and body resolution is interleaved with type checking. That is what the C compiler does.

## How the C V1 does it

- **Loader: `compiler/src/loader.c`, entry `jog_load`.** `open_module` and `find_manifest` locate `jog.mod`, and `parse_manifest` reads it. `load_package` lexes and parses a folder (`load_files`) and recurses through `collect_imports`. The `PkgState` colors `PKG_GRAY` and `PKG_DONE` are the depth-first search, and `report_cycle` prints the chain from the `stack` of import paths. `publish_order` fills `program->packages` in dependency order. The result is the `JogProgram` and `JogPackage` structs in `compiler/src/program.h`.
- **Symbols and scopes: `compiler/src/symbols.h`.** `JogSymbol` has `kind`, `name`, `decl`, `type` and `package`, plus generic instance lists. `JogPackageScope` holds a `CtMap` of bindings and one `JogBlockScope` per file (`file_scopes`). `JogBlockScope` is a `CtMap` with a `parent` pointer. `jog_block_scope_lookup` walks the chain and then falls through to the package scope. Every function is `static inline`, so there is no `symbols.c`.
- **Universe: `compiler/src/resolve_universe.c`, entry `jog_universe_scope`.** The scalar types, `bytes`, `str`, `void`, and `true`, `false`, `null`.
- **Package and file scopes: `compiler/src/resolve_package.c`, entry `jog_resolve_packages`.** `build_package` creates the scopes and calls `bind_file` twice per file: the first pass (`package_pass` true) binds package-visible declarations into the package map, and the second binds imports (`bind_import`) and file-private names into the file scope. `bind_decl` dispatches on the node kind, and `bind_named` reports duplicates. A function with a receiver becomes `JOG_SYM_METHOD` and is not a package name. `jog_file_lookup` walks file scope, package scope, then universe. `jog_symbol_visible_from` is the visibility test.
- **Names in bodies: `compiler/src/check_body.c`.** The checker resolves body names while it type-checks: `check_ident` looks the name up through the active block scopes and the file scope, and reports "undefined name". New locals go through `jog_check_body_bind`. Member access (`check_member`) resolves fields and package members once the left side's type is known, and reports "name '...' is not visible".
- **Ordering of top-level declarations** is handled by the checker's on-demand scheduler, not by the resolver. See [[bootstrap/study/TypeChecking]].
- **One difference from the specification to know about:** [[design/language/Syntax]] says an unused import is an error, and `resolve_package.h` notes that the resolver does not report it. When `jogc` is compared against `jog`, match what `jog` does and record the gap in [[bootstrap/Friction]].

## Questions to answer in your own words

1. Why must all top-level names of a package be bound before any function body is resolved? What breaks if you resolve file by file in one pass?
2. Why does `build_package` need two passes over the files? What would go wrong if imports were bound in the first pass?
3. Explain the three-color cycle detection in `loader.c`. Why is "reached a gray package" a cycle, while "reached a done package" is not?
4. Why does dependency order of packages matter for code generation, not only for checking?
5. Why are field and method names not resolved by the resolver?
6. Why keep lookup and the visibility check separate, instead of making private names simply invisible?
7. A local `val x` shadows a package-level `x`. Where in the chain is each found, and what does the AST node store?
8. What information must the resolver leave on the tree so that an LSP can implement go to definition and find references?

## Jog exercise

Resolve a toy program given as a list of events. A block opens and closes, names are declared and used, and the resolver counts uses of undefined names. It reuses `StrMap` from [[bootstrap/study/DataStructures]], so put it in the same package.

```
import std.mem
import std.testing

enum Event {
    Open
    Close
    Declare(name: str)
    Use(name: str)
}

// The declaration id, and whether the name resolved at all.
fn lookupIn(stack: []StrMap, name: str): (i32, bool) {
    var i = stack.len
    for i > 0 {
        i -= 1
        val (at, found) = stack[i].find(name)
        if found {
            return stack[i].slots[at].value, true
        }
    }
    return -1, false
}

// Returns the number of uses that did not resolve.
fn resolve(events: []const Event): i32 with (a: mem.Allocator) {
    var scopes: [16]StrMap
    var depth: usize = 1
    var next: i32 = 0
    var errors: i32 = 0
    for e in events {
        when e {
            Open -> {
                depth += 1
            }
            Close -> {
                scopes[depth - 1] = StrMap(slots: []Slot(), count: 0, tombs: 0)
                depth -= 1
            }
            Declare(name) -> {
                val top = &scopes[depth - 1]
                top.put(name, next)
                next += 1
            }
            Use(name) -> {
                val (_, found) = lookupIn(scopes[..depth], name)
                if !found {
                    errors += 1
                }
            }
        }
    }
    return errors
}

@test
fn blockScopes() with (t: testing.Testing) {
    val events = []const Event(
        Event.Declare(name: "x"),
        Event.Open,
        Event.Declare(name: "y"),
        Event.Use(name: "y"),
        Event.Close,
        Event.Use(name: "y"),
        Event.Use(name: "x"),
    )
    val errors = resolve(events) with (mem.heap())
    t.expect(errors == 1)
}
```

Then extend it:

- Return, for each `Use`, the id of the declaration it resolved to, and test shadowing: an inner `Declare("x")` hides the outer one, and the outer one is visible again after `Close`.
- Report a duplicate `Declare` in the same scope, the way `bind_named` does.
- Add a `Package` layer under the block stack that is filled in a first pass over every `Declare` at depth 1, so a `Use` before the top-level `Declare` still resolves. That is the two-pass idea in miniature.
- `Close` leaks the map's slots. Give each scope an arena, or reset one, and decide which fits a resolver better.
- Write the three-color import-cycle check over a small graph of package names, and print the cycle as `a -> b -> a`.

## Reading

From [[bootstrap/Reading]]:

- Crafting Interpreters, "Resolving and Binding": a separate resolver pass over a scope stack.
- Modern Compiler Implementation in C, the chapter on symbol tables.
- go/types tutorial, the sections on objects, scopes and packages; Go's model is the closest to Jog's.

## See also

- [[bootstrap/Roadmap]]
- [[bootstrap/Checks]]
- [[bootstrap/Friction]]
- [[bootstrap/study/Parsing]]
- [[bootstrap/study/TypeChecking]]
- [[bootstrap/study/DataStructures]]
- [[design/language/Syntax]]
- [[design/Modules]]
