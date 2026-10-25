---
status: draft
tags:
  - bootstrap
  - study
  - lsp
  - tooling
---

# LSP

A language server is a separate process that an editor talks to over a pipe. The editor sends the text the user is typing; the server answers with diagnostics, hover text, definitions and completions. The Language Server Protocol (LSP) fixes the message format, so one server works in VS Code, Neovim, Helix, Zed and the rest. In the bootstrap, JogLSP comes twice: a diagnostics-only v0 in P2, built before the compiler as a first real Jog program, and LSP v1 in P4, built on the self-hosted frontend. See [[bootstrap/Roadmap]].

## Key ideas

### JSON-RPC over stdio

LSP messages are JSON-RPC 2.0 objects. There are three kinds:

- A **request** has an `id`, a `method` and `params`, and must get exactly one response: `{"jsonrpc":"2.0","id":1,"method":"initialize","params":{...}}`.
- A **response** carries the same `id` and either a `result` or an `error` with a numeric `code` and a `message`.
- A **notification** has a `method` and no `id`, and gets no response: `textDocument/didChange` is one.

Both sides can send requests. The server sends notifications too, most importantly diagnostics. Messages may arrive while the server is still busy with an earlier one, so the server should be written as a loop that reads a message, handles it, and writes zero or more messages back.

### Content-Length framing

stdin and stdout are byte streams, so messages need boundaries. LSP borrows HTTP's: each message is a header block, a blank line, and a body of exactly the stated length.

```
Content-Length: 52\r\n
\r\n
{"jsonrpc":"2.0","method":"initialized","params":{}}
```

Header lines end in `\r\n`, header names are case-insensitive, `Content-Type` may appear and can be ignored, and the length counts **bytes** of the UTF-8 body, not characters. A read from a pipe may return half a message or three messages at once, so the reader must buffer, parse headers only when the blank line has arrived, and wait until the whole body is there. On Windows, stdin and stdout must be in binary mode, or the C runtime will turn `\n` into `\r\n` and every length will be wrong.

stdout belongs to the protocol. A stray debug print corrupts the stream, so logs go to stderr.

### The lifecycle

1. The client sends the `initialize` request, with the workspace root and the client's capabilities. The server answers with **its** capabilities, such as "I want full text sync" or "I can hover". The client will only use what the server advertised.
2. The client sends the `initialized` notification, and normal traffic starts.
3. On close, the client sends the `shutdown` request. The server stops work and answers with `null`.
4. The client sends the `exit` notification, and the server exits with status 0 if `shutdown` came first and 1 otherwise.

Before `initialize`, a server answers requests with an error. After `shutdown`, it ignores everything except `exit`.

### Text synchronization

The server never reads the user's files from disk while they are open. It keeps its own copy, updated by notifications:

- `textDocument/didOpen` carries the document's URI, language id, version and full text.
- `textDocument/didChange` carries the new version and changes. With **full** sync (capability `textDocumentSync: 1`) each change is the whole text, which is simple and fast enough for files of normal size. With **incremental** sync (`2`) each change is a range and replacement text, which needs position arithmetic.
- `textDocument/didClose` drops the copy.

Positions are a zero-based line and a zero-based character, and by default the character offset counts **UTF-16 code units**, not bytes. Jog source is UTF-8, so converting between a byte offset and an LSP position must walk the line. LSP 3.17 lets the server negotiate `positionEncoding: "utf-8"` if the client supports it.

### Diagnostics

The server **pushes** diagnostics. After each change it runs the frontend and sends a `textDocument/publishDiagnostics` notification with the URI, the version and the full list of diagnostics for that file, each with a range, a severity and a message. Sending an empty list clears the old diagnostics. This is all P2 needs: the server can call `jog check --diag=json` on a temporary copy, translate the compiler's JSON into LSP diagnostics, and publish them. See [[bootstrap/Checks]] for that JSON contract.

### Hover, definition, completion

These are requests at a position, and they need more than errors:

- **`textDocument/hover`**: find the innermost node at the position, and answer with its type or signature as Markdown.
- **`textDocument/definition`**: resolve the identifier at the position to its symbol, and answer with the location of the declaration. This needs the resolver to record, for each use, which declaration it found.
- **`textDocument/completion`**: after `.`, list the members of the receiver's type; elsewhere, list the names in scope. This needs a type for an expression the user has not finished typing.

All three need a position-to-node lookup, which means every node must carry its source span, and they need the frontend to be fast enough to rerun on every keystroke or to reuse work from the last run.

### Error tolerance

A compiler can stop at the first error. A language server cannot: the file being edited is broken most of the time, and the user still wants hover and completion in the parts that are fine. That requires a frontend that:

- **recovers** in the parser, skipping to a synchronizing token (the end of a statement, a `}`) and producing an error node instead of giving up;
- **keeps going** in the checker, giving broken expressions an error type that is compatible with everything, so one mistake does not cascade into twenty;
- produces a tree for the whole file, so position lookups work everywhere.

The C V1 already does the first two for batch use. The LSP raises the bar: the tree must stay useful, not just the error count low.

### The VS Code client

The VS Code side is small. A `package.json` declares the `jog` language and the `.jog` extension, points at a **TextMate grammar** for highlighting and a language configuration for comments and brackets, and has an activation script that starts the server with `vscode-languageclient` over stdio. Highlighting does not need the server at all. A TextMate grammar is a JSON or YAML file of regular expressions (`match`, and `begin`/`end` for strings and comments) that assign scope names such as `keyword.control.jog` or `string.quoted.double.jog`, and the theme colors the scopes. The language server adds what regular expressions cannot know: errors, types and definitions.

## How the C V1 does it

There is no language server in the C V1, and there will not be one. The pieces that JogLSP builds on are:

- **Diagnostics.** `tools/diag.h` and `tools/diag.c` (`ct_diag_emit`) print `file:line:col: error: message`. A `--diag=json` mode does not exist yet; adding it is P0 in [[bootstrap/Roadmap]], and P2 parses that output.
- **Recovery in the parser.** `compiler/src/parser.c`: `report` drops errors while `panic` is set, `recover` skips to the end of the statement or block, `same_place` and `give_up` stop the parser from looping when it cannot make progress. See [[bootstrap/study/Parsing]].
- **Poison types in the checker.** `JOG_TY_ERROR` in `compiler/src/types.h` is accepted everywhere, so a broken expression reports once. See [[bootstrap/study/TypeChecking]].
- **Spans.** Every token (`JogToken` in `compiler/src/token.h`) and node (`JogNode` in `compiler/src/ast.h`) carries a position, which is what a position-to-node lookup needs.
- **Running a tool.** `tools/proc.h` (`ct_proc_run`) is how the C code runs a child process, the same thing JogLSP v0 does to call `jog check`.

## Questions to answer in your own words

1. Why does LSP frame messages with `Content-Length` instead of one JSON object per line? What breaks if the length is counted in characters?
2. A single read returns one and a half messages. What does your reader do with the extra half?
3. What is the difference between a request and a notification, and what goes wrong if the server answers a notification?
4. Walk through the lifecycle from `initialize` to `exit`. Why does `exit` without `shutdown` exit with status 1?
5. Why does the server keep its own copy of open documents instead of reading them from disk?
6. A diagnostic is at byte 14 of a line that contains `é`. What character offset does the client expect, and why?
7. What does the parser need to do so that hover still works on line 40 when line 12 has a syntax error?
8. What does a TextMate grammar give the user without a server, and what can only the server provide?

## Jog exercise

Write and read Content-Length frames. The writer is what the server uses for every reply, and the reader is the first thing it runs on stdin. The test writes two messages into one buffer, as a pipe might deliver them, reads them back, checks a partial buffer, and checks a header block with a lowercase name and an extra header.

The reader takes `[]u8` where `[]const u8` would be the honest type, because V1 does not yet convert `[]u8` to `[]const u8` implicitly.

```
import std.testing

val FrameOk: u8 = 0
val FrameIncomplete: u8 = 1
val FrameBad: u8 = 2

struct Frame {
    status: u8
    bodyStart: usize
    bodyLen: usize
    next: usize
}

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

fn *Out.num(v: usize) {
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
        self.buf[self.len] = digits[n]
        self.len += 1
    }
}

fn writeFrame(o: *Out, body: str) {
    o.put("Content-Length: ")
    o.num(body.len)
    o.put("\r\n\r\n")
    o.put(body)
}

fn lower(c: u8): u8 {
    if c >= 'A' as u8 && c <= 'Z' as u8 {
        return c + 32
    }
    return c
}

// name must be lowercase.
fn hasName(buf: []u8, start: usize, end: usize, name: str): bool {
    if end - start < name.len {
        return false
    }
    for i in 0..name.len {
        if lower(buf[start + i]) != name.ptr[i] {
            return false
        }
    }
    return true
}

fn parseLength(buf: []u8, start: usize, end: usize): (usize, bool) {
    var i = start
    for i < end && buf[i] == ' ' as u8 {
        i += 1
    }
    if i == end {
        return (0, false)
    }
    var n: usize = 0
    for i < end {
        val c = buf[i]
        if c < '0' as u8 || c > '9' as u8 {
            return (0, false)
        }
        n = n * 10 + (c - '0' as u8) as usize
        i += 1
    }
    return (n, true)
}

fn incomplete(pos: usize): Frame {
    return Frame(status: FrameIncomplete, bodyStart: 0, bodyLen: 0, next: pos)
}

fn bad(pos: usize): Frame {
    return Frame(status: FrameBad, bodyStart: 0, bodyLen: 0, next: pos)
}

fn readFrame(buf: []u8, pos: usize): Frame {
    val name = "content-length:"
    var length: usize = 0
    var haveLength = false
    var line = pos
    for {
        var end = line
        for end + 1 < buf.len && !(buf[end] == '\r' as u8 && buf[end + 1] == '\n' as u8) {
            end += 1
        }
        if end + 1 >= buf.len {
            return incomplete(pos)
        }
        if end == line {
            val body = end + 2
            if !haveLength {
                return bad(pos)
            }
            if buf.len - body < length {
                return incomplete(pos)
            }
            return Frame(status: FrameOk, bodyStart: body, bodyLen: length, next: body + length)
        }
        if hasName(buf, line, end, name) {
            val (n, ok) = parseLength(buf, line + name.len, end)
            if !ok {
                return bad(pos)
            }
            length = n
            haveLength = true
        }
        line = end + 2
    }
}

fn bodyIs(buf: []u8, f: Frame, want: str): bool {
    if f.status != FrameOk || f.bodyLen != want.len {
        return false
    }
    for i in 0..want.len {
        if buf[f.bodyStart + i] != want.ptr[i] {
            return false
        }
    }
    return true
}

@test
fn twoMessagesInOneRead() with (t: testing.Testing) {
    val first = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{}}"
    val second = "{\"jsonrpc\":\"2.0\",\"method\":\"initialized\",\"params\":{}}"
    var o: Out
    writeFrame(&o, first)
    writeFrame(&o, second)
    val buf = o.buf[0..o.len]

    val a = readFrame(buf, 0)
    t.expect(bodyIs(buf, a, first))
    val b = readFrame(buf, a.next)
    t.expect(bodyIs(buf, b, second))
    t.expect(b.next == o.len)
    t.expect(readFrame(buf, b.next).status == FrameIncomplete)
}

@test
fn partialBody() with (t: testing.Testing) {
    var o: Out
    writeFrame(&o, "{\"method\":\"exit\"}")
    t.expect(readFrame(o.buf[0..o.len - 3], 0).status == FrameIncomplete)
    t.expect(readFrame(o.buf[0..10], 0).status == FrameIncomplete)
}

@test
fn headerNamesIgnoreCase() with (t: testing.Testing) {
    var o: Out
    o.put("Content-Type: application/vscode-jsonrpc; charset=utf-8\r\ncontent-length: 2\r\n\r\n{}")
    val buf = o.buf[0..o.len]
    t.expect(bodyIs(buf, readFrame(buf, 0), "{}"))

    var missing: Out
    missing.put("Content-Type: x\r\n\r\n{}")
    t.expect(readFrame(missing.buf[0..missing.len], 0).status == FrameBad)
}
```

Then extend it:

- Write a JSON scanner over the body (strings with escapes, numbers, `true`, `false`, `null`, punctuation) and a function that finds the top-level `"method"` and `"id"`. That is enough to dispatch every message P2 needs.
- Write the server loop with a buffer that keeps the unread tail between reads: read from stdin, call `readFrame` until it returns `FrameIncomplete`, move the tail to the front, read again.
- Implement the lifecycle as a small state machine: before `initialize`, running, after `shutdown`. Answer each request in the wrong state with error `-32002` or `-32600` as the specification says.
- Write `utf16Column(line: []const u8, byteCol: usize): usize` and test it with a line containing `é` and an emoji, which takes two UTF-16 code units.

## Reading

From [[bootstrap/Reading]]:

- The LSP 3.17 specification: "Base Protocol", "Lifecycle Messages", "Document Synchronization", then `publishDiagnostics`, `hover`, `definition` and `completion`.
- The JSON-RPC 2.0 specification and RFC 8259, for the message layer and the JSON grammar.
- The VS Code guides on syntax highlighting, language configuration and language server extensions, and the TextMate grammar manual.
- matklad's "Resilient LL Parsing Tutorial", for a parser that keeps a full tree through errors.
- "Three Architectures for a Responsive IDE" and the rust-analyzer architecture notes, before designing LSP v1.

## See also

- [[bootstrap/Roadmap]]
- [[bootstrap/Checks]]
- [[bootstrap/Friction]]
- [[bootstrap/study/Parsing]]
- [[bootstrap/study/TypeChecking]]
- [[bootstrap/study/NameResolution]]
- [[design/Compiler]]
