---
status: draft
tags:
  - bootstrap
  - study
  - compiler
  - parser
---

# Parsing

The parser turns the token list into a syntax tree, one per file. It is stage 2 of JogCompiler, and it is checked the same way as the lexer: `jogc parse f` must print exactly what `jog parse f` prints. The printed form is defined by `compiler/src/ast_print.c`, and `tests/parse/*.ast` are golden files.

## Key ideas

### Recursive descent

Each grammar rule becomes a function that consumes tokens and returns a node: `parseFn`, `parseBlock`, `parseStmt`, `parseType`, `parseExpr`. A function looks at the current token to decide which alternative applies, calls the functions for the sub-rules, and builds the node. Three tiny helpers carry most of the work:

- `check(kind)`: is the current token this kind?
- `eat(kind)`: if so, consume it and return true.
- `expect(kind, what)`: consume it or report "expected X, found Y".

Hand-written recursive descent is what most production compilers use (Go, Clang, rustc, Zig). It is easy to debug, gives the parser full control over error messages and recovery, and handles context-sensitive corners that a generator would fight.

### Precedence climbing

Writing one function per precedence level (`parseOr`, `parseAnd`, `parseCmp`, ...) works but is long. Precedence climbing replaces all of them with one loop:

```
parseExpr(minPrec):
    left = parseUnary()
    loop:
        op = current token
        if prec(op) < minPrec: stop
        consume op
        right = parseExpr(prec(op) + 1)     // +1 makes the operator left-associative
        left = Binary(op, left, right)
    return left
```

The `+ 1` is the whole associativity story: a right-associative operator would recurse with `prec(op)` instead. Prefix operators are handled in `parseUnary`, and postfix forms (calls, indexing, `.field`, `!!`) in a postfix loop below it, since they bind tighter than any infix operator. This is the same algorithm as Pratt parsing, written as a loop instead of a table of functions.

Jog adds two twists, both in [[design/language/Grammar]]:

- **Non-associative operators.** `a < b < c` is an error, not `(a < b) < c`. After building a comparison, the parser checks whether the next operator has the same precedence and reports "does not chain".
- **Bitwise operators bind tighter than comparisons**, unlike C, so `x & MASK == 0` means `(x & MASK) == 0`. That is only a different table.

### Statements, separators and the newline rule

The lexer has already turned significant newlines into `SEP` tokens, so a block is "statements separated by one or more `SEP`". The parser skips extra separators, and it ignores a `SEP` in two places the grammar names: between attributes and the declaration they annotate, and right before `else`.

### Ambiguities a context-free grammar cannot settle

Jog's grammar resolves several ambiguities with rules stated in prose. Each one becomes a small piece of lookahead or backtracking:

- **Heads of `if`, `when`, `for` and `with`** do not take a trailing lambda, so `{` always opens the body. The parser passes a "trailing lambda allowed" flag down through expression parsing.
- **`<` as type arguments or less-than.** After an identifier, try to parse type arguments. Keep them only if that succeeds and the next token can follow a generic name; otherwise rewind and read `<` as less-than. This is backtracking with a saved position.
- **`>>` closing two type-argument lists** is split into two `>` tokens on the fly.
- **Lambda or parenthesized expression.** At `(`, scan to the matching `)` and look at the next token: `:` or `->` means a lambda.

### Error recovery

A parser that stops at the first error is fine for a batch compiler and useless for an editor. The classic technique is **panic mode**:

1. On the first error in a construct, report it and set a `panic` flag.
2. While `panic` is set, report nothing more, so one mistake produces one message instead of a cascade.
3. **Synchronize:** skip tokens until a point where parsing can safely restart, such as the next `SEP` at the current brace depth or the `}` that closes the current block. Then clear the flag.
4. Guarantee progress: if a statement or declaration parser consumed nothing, skip at least one token, or the loop never ends.

The result is a tree that is complete except for the broken statements. The LSP will want more than this: a tree with explicit error nodes where things are missing, so hover and completion still work inside a half-written function. That is the subject of matklad's resilient parsing tutorial, and it comes in P4. See [[bootstrap/study/LSP]].

### The AST

Nodes are a tagged union: a kind, a position, and per-kind data. Children are fixed lists allocated in the arena once a construct is finished. The parser fills only syntax; later phases attach a type and a symbol to each node without changing its shape.

## How the C V1 does it

All in `compiler/src/parser.c`, with the node definitions in `compiler/src/ast.h` and the entry point `jog_parse` in `phases.h`.

- **The AST** is `JogNode` with a `JogNodeKind` generated by the `JOG_NODE_KINDS` X-macro in `ast.h`, a `JogPos`, `type` and `symbol` slots for the checker, and a union `as`. Child lists are `JogList` (a pointer and a count in the arena), and names are `JogNames` of interned strings.
- **Token helpers:** `cur`, `peek_kind`, `peek_n`, `advance`, `check`, `eat`, `expect`, `skip_seps`. `at_gt` and `eat_gt` split `>>` using `pending_gt`.
- **Declarations:** `jog_parse` loops over `parse_top`, which reads attributes and visibility and dispatches on the keyword to `parse_import`, `parse_fn`, `parse_binding`, `parse_type_decl`, `parse_aggregate` and `parse_extern_block`.
- **Statements:** `parse_block` and `parse_until_rbrace` loop over `parse_stmt`, which handles `return`, `for`, `defer`, `with`, attribute blocks, bindings and expression statements (`parse_expr_stmt`, which also detects assignment).
- **Expressions:** `parse_prec` is precedence climbing, with levels in `infix_prec` (1 for `||` up to 14 for `as`), `non_assoc` for the comparison-like operators and the "does not chain" error, and `range_ok` so a slice bound stops at `..`. `as`, `as?` and `is` take a type on the right, not an expression. Below that are `parse_unary`, `parse_postfix` (calls, members, index and slice, `!!`, trailing lambdas through `attach_trailing`) and `parse_primary`.
- **Disambiguation:** `parse_expr_trail(p, false)` parses a head without trailing lambdas. `mark_here` and `mark_back` save and restore the parser for the type-argument try, and `keeps_type_args` is the follow set. `at_paren_lambda` implements rule 3. `parse_if` skips a `SEP` before `else`.
- **Error recovery:** `report` drops messages while `panic` is set, and `error_here` sets it. `recover` skips to a `SEP` at brace depth 0 or stops before an unmatched `}`, then clears `panic`. `parse_until_rbrace` and `jog_parse` use `same_place` to detect a construct that consumed nothing and force an `advance`. `give_up` stops work after a fatal error or out of memory.
- **Printing:** `jog_ast_print` in `compiler/src/ast_print.c` writes the indented S-expression form, which `compiler/src/cmd_parse.c` prints for `jog parse`. `tests/parse/extract-notes.ps1` pulls every code block out of the language notes, so the parser is tested on the specification itself.

## Questions to answer in your own words

1. Trace `parseExpr(1)` on `1 + 2 * 3 - 4`. At which calls does `minPrec` stop the loop, and why does the result come out left-associative?
2. What single change makes an operator right-associative? Which Jog operators would want that, if any?
3. How does `parse_prec` turn `a < b < c` into an error instead of a tree? Why is that check done after building the left comparison?
4. Why can `if x {` not allow a trailing lambda on `x`? Write the Jog line that would be ambiguous.
5. In `Map<str, i32>(m)` versus `a < b`, what does the parser try first, and what makes it give up and rewind?
6. In panic mode, why skip to a `SEP` at the current brace depth rather than to the next `SEP` anywhere?
7. Why does the parser need the "consumed nothing" check even with `recover` in place? Construct an input that would loop without it.
8. What extra structure does an LSP want from the parser that a batch compiler does not?

## Jog exercise

Write a precedence-climbing evaluator for integer expressions with `+ - * /` and parentheses, reading directly from a `str`. It has no AST yet, so the loop is all there is to look at.

```
import std.testing

struct Parser {
    src: str
    at: usize
}

// `op` is a keyword (operator overloading), so the operator byte is `sym`.
// A char literal next to a u8 defaults to i64 in V1, hence the `as u8`.
fn prec(sym: u8): i32 {
    if sym == '+' as u8 || sym == '-' as u8 {
        return 1
    }
    if sym == '*' as u8 || sym == '/' as u8 {
        return 2
    }
    return -1
}

fn apply(sym: u8, a: i64, b: i64): i64 {
    if sym == '+' as u8 {
        return a + b
    }
    if sym == '-' as u8 {
        return a - b
    }
    if sym == '*' as u8 {
        return a * b
    }
    return a / b
}

fn *Parser.peek(): u8 {
    for self.at < self.src.len && self.src.ptr[self.at] == ' ' as u8 {
        self.at += 1
    }
    if self.at >= self.src.len {
        return 0
    }
    return self.src.ptr[self.at]
}

fn *Parser.primary(): i64 {
    if self.peek() == '(' as u8 {
        self.at += 1
        val v = self.expr(1)
        if self.peek() != ')' as u8 {
            panic("expected ')'")
        }
        self.at += 1
        return v
    }
    var v: i64 = 0
    for self.peek() >= '0' as u8 && self.peek() <= '9' as u8 {
        v = v * 10 + ((self.peek() - '0' as u8) as i64)
        self.at += 1
    }
    return v
}

fn *Parser.expr(minPrec: i32): i64 {
    var left = self.primary()
    for {
        val sym = self.peek()
        val p = prec(sym)
        if p < minPrec {
            break
        }
        self.at += 1
        val right = self.expr(p + 1)
        left = apply(sym, left, right)
    }
    return left
}

@test
fn precedence() with (t: testing.Testing) {
    var p = Parser(src: "1 + 2 * 3 - (4 - 1)", at: 0)
    t.expect(p.expr(1) == 4)
    var q = Parser(src: "8 - 4 - 2", at: 0)
    t.expect(q.expr(1) == 2)
}
```

Then extend it:

- Add unary minus in `primary`, and check that `-2 * 3` and `2 * -3` both work.
- Add `<` and `==` at a lower precedence and make them non-associative: `1 < 2 < 3` reports "does not chain".
- Build a tree instead of a value. An `enum Expr { Num(n: i64), Bin(sym: u8, l: *Expr, r: *Expr) }` needs an allocator for the nodes, which is where the arena from [[bootstrap/study/DataStructures]] comes in. Print it in the `ast_print.c` style.
- Replace `panic` with a diagnostic and recovery: on a bad token, report once, skip to the end of the line, and keep parsing the next line.

## Reading

From [[bootstrap/Reading]]:

- matklad, "Simple but Powerful Pratt Parsing" (start here).
- Eli Bendersky, "Parsing expressions by precedence climbing": the exact algorithm in `parse_prec`.
- Crafting Interpreters, "Compiling Expressions", for a table-driven Pratt parser in C.
- matklad, "Resilient LL Parsing Tutorial", before P4.
- The specification is [[design/language/Grammar]]: productions, the precedence table and the disambiguation rules.

## See also

- [[bootstrap/Roadmap]]
- [[bootstrap/Checks]]
- [[bootstrap/Friction]]
- [[bootstrap/study/Lexing]]
- [[bootstrap/study/NameResolution]]
- [[bootstrap/study/LSP]]
- [[design/language/Grammar]]
- [[design/language/Syntax]]
