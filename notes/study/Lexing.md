---
status: draft
tags:
  - bootstrap
  - study
  - compiler
  - lexer
---

# Lexing

The lexer turns a file of bytes into a flat list of tokens. It is the first stage of JogCompiler, and the easiest to check: `jogc lex f` has to print exactly what `jog lex f` prints, for every `.jog` file you can find. See [[bootstrap/Checks]].

## Key ideas

### What a token is

A token is a kind plus a position and, for some kinds, a value. The kind is an enum: identifier, integer literal, `fn`, `(`, `+=`, and so on. The position is the line and column of the first byte, which every later diagnostic is built from. The lexeme is the slice of the source the token covers. For identifiers the value is the interned name; for strings it is the decoded text with escapes applied. Keeping the lexeme as a slice of the source, not a copy, makes tokens cheap.

### Scanning

A hand-written lexer is a loop over bytes with one cursor. At each step it skips whitespace and comments, looks at the current byte, and dispatches: a letter starts an identifier or keyword, a digit starts a number, `"` starts a string, and anything else is punctuation.

- **Keywords** are lexed as identifiers and then looked up in a keyword table. That is simpler than a separate rule for each keyword.
- **Longest match** settles punctuation: `<` might be `<`, `<=`, `<<`, `<<=` or `<=>`, so the lexer reads as many bytes as still form a token. A few tokens need more care: `as?` is one token in Jog, but `as` followed by `?.` is not.
- **Numbers** cover decimal, `0x`, `0b`, `0o`, `_` separators, floats with a fraction or exponent, and the error cases (`0x` with no digits, a digit out of range).
- **Strings** decode escapes into a buffer. Raw strings in backticks do not.
- **Errors do not stop the lexer.** It reports the error, skips the bad bytes, and keeps going, so one stray character does not hide every later error.

### The newline rule

Jog has no mandatory semicolons. The lexer inserts a separator token (`SEP`) at a newline when the previous token could end an expression: an identifier, a literal, `)`, `]`, `}`, `?`, `!!`, `>`, `>>`, or one of `return`, `break`, `continue`, `true`, `false`, `null`, `bytes`. Two exceptions:

- Inside `(` or `[`, newlines are ignored. Inside `{` the rule applies again, even when that `{` is nested in parentheses. So the lexer keeps a stack of open brackets, not a counter.
- If the next non-blank line starts with `.`, `?.` or `?:`, it continues the current line, so method chains can be split. That needs lookahead past blank lines and comments.

This is the same idea as Go's semicolon insertion. Putting it in the lexer means the parser only ever sees explicit separators. The full rule is in [[design/language/Grammar]] and [[design/language/Syntax]].

### String interpolation

`"a ${x + 1} b"` is not one token. The lexer emits a string head (`"a `), then the ordinary tokens of the expression, then a string tail (` b"`), with string-middle pieces between several splices. To know where a splice ends, the lexer pushes a `$` marker on the same bracket stack when it sees `${`, and when the matching `}` closes that marker it resumes scanning string text. Nested braces inside the splice push and pop as usual. Newlines inside `${...}` are ignored, like inside parentheses.

### Positions

Lines start at 1. Columns in the C compiler are byte offsets from the start of the line, plus 1. The LSP will need UTF-16 columns instead, which is a conversion at the boundary, not a change to the lexer. See [[bootstrap/study/LSP]].

## How the C V1 does it

All of it is in `compiler/src/lexer.c`, with token kinds in `compiler/src/token.h` and the entry point `jog_lex` in `lexer.h`.

- **Token kinds** are one X-macro, `JOG_TOKEN_KINDS` in `token.h`, which generates the `JogTokenKind` enum, the spellings used in messages (`jog_token_spelling`), and the names printed by `jog lex` (`jog_token_name`). `JogToken` holds `kind`, `line`, `column`, `start`/`length` (the lexeme) and `value`/`value_len` (the decoded value).
- **The state** is the `Lexer` struct: cursor `p`, `end`, `line` and `line_start` for columns (`column_of`), the last token kind (`last`, `has_last`), a bracket stack of `Open` entries whose `kind` is `(`, `[`, `{` or `$`, and a `CtSb` buffer for decoding.
- **The main loop** is `run`, which dispatches to `lex_ident`, `lex_number`, `lex_string_body`, `lex_raw_string`, `lex_cstring`, `lex_char`, `lex_hexblob`, `lex_attribute`, `lex_block_comment` and `lex_punct`. `emit` appends a token to the output `CtDa` and records it as `last`.
- **Keywords:** `lex_ident` scans the identifier, asks `keyword_kind`, special-cases `as?`, and otherwise interns the name with `ct_intern`.
- **The newline rule:** `ends_statement` is the list of kinds that can end a statement. `newline_rule` emits `SEP` only when the top of the bracket stack is empty or `{`, the last token ends a statement, and `continues_line` does not see a leading `.`, `?.` or `?:` on the next significant line. `continues_line` skips whitespace and both kinds of comment, using `skip_block_comment_raw`, which honors nesting.
- **Interpolation:** `lex_string_body` stops at `${`, emits `STR_HEAD` or `STR_MID`, and calls `push_open(lx, '$', ...)`. When a `}` closes the `$` entry, scanning resumes with `lex_string_body` in continuation mode, which ends in `STR_MID` or `STR_TAIL`.
- **Errors:** `lex_error` emits through `CtDiag` and counts. `close_bracket` reports a mismatch with the position of the bracket that was opened. Lexing always reaches the end, and `finish` emits the final `EOF`.
- **Output format:** `compiler/src/cmd_lex.c` prints each token as `line:column KIND lexeme`, with string values escaped by `print_escaped`. That format is what your `jogc lex` must reproduce byte for byte.
- **Tests:** `tests/lexer_test.c`.

## Questions to answer in your own words

1. Why does the newline rule live in the lexer and not in the parser? What would the grammar look like if the parser had to decide?
2. Why does the lexer need a stack of open brackets rather than a nesting counter? Give a Jog snippet where a counter gets the rule wrong.
3. `>` and `>>` end a statement. Why, and what does that cost when writing a long comparison across lines?
4. How does the lexer know where a `${...}` splice ends when the splice itself contains `{` and `}`?
5. Why is it acceptable to keep the lexeme as a slice of the file buffer, and what must outlive the token list for that to stay valid?
6. What should the lexer do after an invalid character so that later errors are still reported, and how do you keep it from reporting the same problem many times?
7. Why are identifiers interned in the lexer rather than later?

## Jog exercise

Write a lexer for a tiny subset: identifiers, decimal integers, `(`, `)`, `{`, `}`, and the newline rule. It already shows the important structure: a cursor, a dispatch on the current byte, and `SEP` insertion that depends on the last token and on bracket depth.

```
import std.testing

enum Kind {
    Ident
    Int
    LParen
    RParen
    LBrace
    RBrace
    Sep
    Eof
}

struct Token {
    kind: Kind
    start: usize
    len: usize
    line: u32
}

fn endsStatement(k: Kind): bool {
    return when k {
        Ident, Int, RParen, RBrace -> true
        else -> false
    }
}

// A char literal next to a u8 defaults to i64 in V1, hence the `as u8`.
fn isDigit(b: u8): bool = b >= '0' as u8 && b <= '9' as u8

fn isIdentStart(b: u8): bool {
    return (b >= 'a' as u8 && b <= 'z' as u8) || (b >= 'A' as u8 && b <= 'Z' as u8) || b == '_' as u8
}

struct Lexer {
    src: str
    at: usize
    line: u32
    parens: u32
    last: Kind
}

fn Lexer.peek(): u8 {
    if self.at >= self.src.len {
        return 0
    }
    return self.src.ptr[self.at]
}

fn *Lexer.make(kind: Kind, start: usize): Token {
    self.last = kind
    return Token(kind: kind, start: start, len: self.at - start, line: self.line)
}

fn *Lexer.next(): Token {
    for {
        val b = self.peek()
        if b == ' ' as u8 || b == '\t' as u8 || b == '\r' as u8 {
            self.at += 1
        } else if b == '\n' as u8 {
            val start = self.at
            self.at += 1
            val sep = self.parens == 0 && endsStatement(self.last)
            val tok = self.make(Kind.Sep, start)
            self.line += 1
            if sep {
                return tok
            }
        } else {
            break
        }
    }
    val start = self.at
    val b = self.peek()
    if b == 0 {
        return self.make(Kind.Eof, start)
    }
    self.at += 1
    if isDigit(b) {
        for isDigit(self.peek()) {
            self.at += 1
        }
        return self.make(Kind.Int, start)
    }
    if isIdentStart(b) {
        for isIdentStart(self.peek()) || isDigit(self.peek()) {
            self.at += 1
        }
        return self.make(Kind.Ident, start)
    }
    if b == '(' as u8 {
        self.parens += 1
        return self.make(Kind.LParen, start)
    }
    if b == ')' as u8 {
        self.parens -= 1
        return self.make(Kind.RParen, start)
    }
    if b == '{' as u8 {
        return self.make(Kind.LBrace, start)
    }
    if b == '}' as u8 {
        return self.make(Kind.RBrace, start)
    }
    panic("unexpected byte")
}

@test
fn newlineRule() with (t: testing.Testing) {
    var lx = Lexer(src: "f(a\n b)\nx\n", at: 0, line: 1, parens: 0, last: Kind.Sep)
    var seps = 0
    for {
        val tok = lx.next()
        if tok.kind is Eof {
            break
        }
        if tok.kind is Sep {
            seps += 1
        }
    }
    t.expect(seps == 2)
}
```

V1 does not define `==` on enums, so the test uses `is`. `peek` reads `src.ptr[at]` because V1 rejects `src[at] as u8`; the length check above it is what keeps that unchecked read in bounds. Both are worth an entry in [[bootstrap/Friction]].

Then extend it toward the real lexer:

- Replace `parens` with a bracket stack, so `{` inside `(` turns the rule back on. Write the test from question 2.
- Add the continuation rule: a newline is not a `SEP` when the next non-blank line starts with `.`.
- Replace `panic` with a diagnostic list and keep lexing.
- Add `//` and nested `/* */` comments, then strings with escapes, then interpolation with the `$` marker on the stack.
- Print tokens in the `cmd_lex.c` format and diff against `jog lex` on `std/*.jog`.

The `make` call for `SEP` sets `last` even when no token is returned. Decide whether that is right, compare with `newline_rule` and `emit` in `lexer.c`, and fix it if not.

## Reading

From [[bootstrap/Reading]]:

- Crafting Interpreters, chapter "Scanning" (start here).
- The newline rule in [[design/language/Grammar]] and the lexical rules in [[design/language/Syntax]] are the specification.

## See also

- [[bootstrap/Roadmap]]
- [[bootstrap/Checks]]
- [[bootstrap/Friction]]
- [[bootstrap/study/DataStructures]]
- [[bootstrap/study/Parsing]]
- [[design/language/Grammar]]
- [[design/language/Syntax]]
- [[plans/V1Compiler]]
