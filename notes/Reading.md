---
status: draft
tags:
  - bootstrap
  - reading
---

# Reading

A short, curated reading list for the bootstrap. It is grouped by topic, and each item is tagged with the phase from [[bootstrap/Roadmap]] where it pays off: **P1** std, **P2** JogLSP v0, **P3** JogCompiler, **P4** LSP v1, **P5** bootstrap. Items marked **start here** are the ones to read first if time is short. Each study note in `bootstrap/study/` points back to the items it relies on.

Nothing here is required reading before writing code. The point is to read one item, write the matching piece of Jog, and then read the next.

## Lexing and parsing

- **Start here.** [Crafting Interpreters](https://craftinginterpreters.com/), Robert Nystrom. `P3` The whole book is free online and is the clearest walk through a scanner, a recursive descent parser, a resolver and a bytecode compiler; its C half is close in spirit to the C V1.
  - [Scanning](https://craftinginterpreters.com/scanning.html) `P3` The chapter to read before writing the Jog lexer.
  - [Compiling Expressions](https://craftinginterpreters.com/compiling-expressions.html) `P3` A Pratt parser in C, one table row per token.
- **Start here.** [Simple but Powerful Pratt Parsing](https://matklad.github.io/2020/04/13/simple-but-powerful-pratt-parsing.html), Alex Kladov (matklad). `P3` Shows that Pratt parsing and precedence climbing are the same loop, in about a hundred lines.
- [Parsing expressions by precedence climbing](https://eli.thegreenplace.net/2012/08/02/parsing-expressions-by-precedence-climbing), Eli Bendersky. `P3` The exact algorithm `parse_prec` in `compiler/src/parser.c` uses, explained step by step with a worked trace.
- [Resilient LL Parsing Tutorial](https://matklad.github.io/2023/05/21/resilient-ll-parsing-tutorial.html), Alex Kladov. `P3` `P4` How to make a hand-written parser keep going after errors and still produce a full tree; this is what the LSP needs.

## Compiler books

- [Engineering a Compiler](https://shop.elsevier.com/books/engineering-a-compiler/cooper/978-0-12-815412-0), Keith Cooper and Linda Torczon. `P3` The best general textbook for the middle and back end: IR design, CFGs, SSA, instruction selection. Read the IR chapters before writing lowering.
- [Modern Compiler Implementation in C](https://www.cs.princeton.edu/~appel/modern/c/), Andrew Appel. `P3` A whole compiler for a small language in C, with a clean treatment of symbol tables, type checking and translation to an IR tree.

## A small C compiler to study

- **Start here.** [chibicc](https://github.com/rui314/chibicc), Rui Ueyama. `P3` A small C compiler built one commit per feature. Reading its history in order is a model for writing JogCompiler stage by stage.

## Memory and data structures

- **Start here.** [Untangling Lifetimes: The Arena Allocator](https://www.rfleury.com/p/untangling-lifetimes-the-arena-allocator), Ryan Fleury. `P1` Why a compiler wants one arena per phase instead of `malloc`/`free` per object; the same design as `tools/arena.c`.
- [Hash Tables](https://craftinginterpreters.com/hash-tables.html), Crafting Interpreters. `P1` Open addressing, linear probing, tombstones and string interning, with FNV-1a, exactly the shape of `tools/map.c` and `tools/intern.c`.
- [Swiss Tables Design Notes](https://abseil.io/about/design/swisstables), Abseil. `P1` A modern open-addressing table with control bytes; read it after your first map works, to see where the next speedup comes from.

## Name resolution and type checking

- [Resolving and Binding](https://craftinginterpreters.com/resolving-and-binding.html), Crafting Interpreters. `P3` A separate pass that binds each name to its declaration through a stack of scopes; compare it with `symbols.h`.
- [Bidirectional Typing](https://arxiv.org/abs/1908.05839), Jana Dunfield and Neel Krishnaswami. `P3` The survey behind "check against an expected type, otherwise infer"; the C checker's `target` argument is this idea.
- [go/types: The Go Type Checker](https://github.com/golang/example/tree/master/gotypes), Alan Donovan. `P3` A tutorial on a production checker for a language close to Jog: objects, scopes, untyped constants and method sets.

## Error messages

- [Compiler Errors for Humans](https://elm-lang.org/news/compiler-errors-for-humans), Evan Czaplicki. `P3` `P4` What a good diagnostic looks like, and why the first error matters more than the count.

## IR and code generation

- [Simple and Efficient Construction of Static Single Assignment Form](https://c9x.me/compile/bib/braun13cc.pdf), Braun, Buchwald, Hack, Leißa, Mallon and Zwinkau (CC 2013). `P3`, later. Builds SSA straight from the AST without dominance frontiers. Not needed for V1's non-SSA IR; read it when an optimizer or a native backend comes up.
- [QBE](https://c9x.me/compile/), Quentin Carbonneaux. `P3` A small compiler backend with a readable IR and its own reading list; a good point of comparison for JIR.
- [A Guide to Undefined Behavior in C and C++, Part 1](https://blog.regehr.org/archives/213), John Regehr. `P3` Why a C backend must never emit signed overflow, oversized shifts or bad casts, and what the optimizer does if it does.
- [Integer Overflow Builtins](https://gcc.gnu.org/onlinedocs/gcc/Integer-Overflow-Builtins.html), GCC manual. `P3` `__builtin_add_overflow` and its siblings, which `emit_c.c` uses for checked arithmetic; clang supports the same set.
- [Line Control](https://gcc.gnu.org/onlinedocs/cpp/Line-Control.html), GCC preprocessor manual. `P3` The `#line` directive that maps generated C back to Jog source.

## Language servers and editors

- **Start here.** [Language Server Protocol 3.17 specification](https://microsoft.github.io/language-server-protocol/specifications/lsp/3.17/specification/), Microsoft. `P2` The reference for framing, the lifecycle and every message. Read "Base Protocol", "Lifecycle Messages" and "Document Synchronization" first.
- [JSON-RPC 2.0 Specification](https://www.jsonrpc.org/specification). `P2` Two pages. Requests, notifications, responses and error codes, which LSP builds on.
- [RFC 8259: The JSON Data Interchange Format](https://www.rfc-editor.org/rfc/rfc8259). `P2` The grammar to implement in the JSON parser, short enough to read in full.
- [VS Code Language Extensions Overview](https://code.visualstudio.com/api/language-extensions/overview). `P2` The map of what an editor extension can provide declaratively and what needs a server.
  - [Syntax Highlight Guide](https://code.visualstudio.com/api/language-extensions/syntax-highlight-guide) `P2` TextMate grammars and scopes for `.jog` highlighting.
  - [Language Configuration Guide](https://code.visualstudio.com/api/language-extensions/language-configuration-guide) `P2` Comments, brackets and auto-closing pairs.
  - [Language Server Extension Guide](https://code.visualstudio.com/api/language-extensions/language-server-extension-guide) `P2` The thin client that starts a server over stdio.
- [TextMate Language Grammars](https://macromates.com/manual/en/language_grammars). `P2` The original definition of `match`, `begin`/`end` and scope names that VS Code grammars follow.
- [Three Architectures for a Responsive IDE](https://rust-analyzer.github.io/blog/2020/07/20/three-architectures-for-responsive-ide.html), Alex Kladov. `P4` How to structure a frontend so an editor can ask small questions quickly; the decision P4 has to make.
- [rust-analyzer architecture](https://rust-analyzer.github.io/book/contributing/architecture.html). `P4` A large, real example of an error-tolerant, incremental frontend; skim for the layering.

## Bootstrapping

- **Start here.** [Goodbye to the C++ Implementation of Zig](https://ziglang.org/news/goodbye-cpp/), Andrew Kelley. `P5` How Zig keeps a WebAssembly build of its own compiler as the bootstrap seed, so the old implementation can be deleted.
- [Go 1.5 Bootstrap Plan](https://go.dev/s/go15bootstrap), Russ Cox. `P5` How Go replaced its C compiler with a Go one, with the previous release as stage 0. The [Go 1.5 release notes](https://go.dev/doc/go1.5) record the result.
- [Reflections on Trusting Trust](https://www.cs.cmu.edu/~rdriley/487/papers/Thompson_1984_ReflectionsonTrustingTrust.pdf), Ken Thompson (1984). `P5` Three pages on why a self-hosted compiler's binary is not explained by its source.
- [Countering Trusting Trust through Diverse Double-Compiling](https://dwheeler.com/trusting-trust/), David A. Wheeler. `P5` The practical answer to Thompson: rebuild with an independent compiler and compare.
- [bootstrappable.org](https://bootstrappable.org/). `P5` Why it matters that a compiler can be built from a small, auditable seed, and how projects keep that path open.
- [Reproducible Builds](https://reproducible-builds.org/). `P5` The sources of nondeterminism (timestamps, paths, ordering) that break a byte-identical fixpoint.

## Testing

- [Finding and Understanding Bugs in C Compilers](https://users.cs.utah.edu/~regehr/papers/pldi11-preprint.pdf), Yang, Chen, Eide and Regehr (PLDI 2011). `P3` The Csmith paper. Differential testing, comparing two compilers on the same input, is how every stage of JogCompiler is checked against the C compiler. [Csmith](https://github.com/csmith-project/csmith) is the tool.

## See also

- [[bootstrap/Roadmap]]
- [[bootstrap/Checks]]
- [[bootstrap/Friction]]
- [[bootstrap/study/DataStructures]]
- [[bootstrap/study/Lexing]]
- [[bootstrap/study/Parsing]]
- [[bootstrap/study/NameResolution]]
- [[bootstrap/study/TypeChecking]]
- [[bootstrap/study/IR]]
- [[bootstrap/study/CodeGen]]
- [[bootstrap/study/LSP]]
- [[bootstrap/study/Bootstrapping]]
