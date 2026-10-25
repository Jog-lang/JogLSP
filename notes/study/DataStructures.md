---
status: draft
tags:
  - bootstrap
  - study
  - std
---

# Data structures

A compiler is mostly a few data structures used very heavily: an allocator that makes millions of small objects cheap, a table that turns every identifier into one canonical pointer, hash maps for scopes and type tables, growable arrays while lists are being built, and a string builder for output. P1 of [[bootstrap/Roadmap]] writes these in Jog first, because the LSP and the compiler both stand on them.

## Key ideas

### Arenas

An arena (or bump allocator) owns a few large blocks of memory. Allocation rounds a pointer up to the requested alignment, checks that the block has room, and moves the pointer forward. There is no per-object free. Everything is released at once, by resetting the arena or destroying it.

This fits a compiler because its objects have **phase lifetimes**, not individual ones. Tokens, AST nodes, symbols and types are all created during a run and all die at the end of it. Tracking each one with `malloc`/`free` costs time, invites leaks and use-after-free bugs, and buys nothing. With an arena, a node can point at any other node without anyone asking who owns what.

The cost is that memory is never reused inside one arena. A table that grows leaves its old bucket array behind. That is fine for a batch compiler. It is not fine for a long-running LSP, which is why the LSP will want one arena per analysis that it drops and rebuilds.

Alignment is the subtle part: `aligned = (p + align - 1) & ~(align - 1)` works only when `align` is a power of two, and the check for room has to include the padding.

### Interning

Interning maps every distinct string to one canonical copy. After that, two names are equal exactly when their pointers are equal. The lexer interns each identifier once, and from then on the resolver and checker compare names with one pointer comparison instead of `strcmp`, and can use the pointer as a hash key.

An interner is a hash set of strings: hash the bytes, probe for an equal entry, and insert a copy if there is none. Storing the hash and length in each slot makes most failed probes cheap, because two strings with different hashes or lengths cannot be equal.

The same idea applies to types. If every structural type (`*T`, `[]T`, `(A, B)`) is built through one table keyed by its shape, then type equality is pointer equality too.

### Hash maps with open addressing

Open addressing stores entries directly in one array of slots. To find a key, hash it, start at `hash & (capacity - 1)`, and walk forward one slot at a time (linear probing) until you find the key or an empty slot. A power-of-two capacity turns the modulo into a mask.

- **Load factor.** Probes get long as the table fills. Grow, usually by doubling, once `count / capacity` passes a threshold such as 3/4. Growth means rehashing every live entry into the new array, because positions depend on the capacity.
- **Deletion.** You cannot just empty a slot, because that would cut a probe chain and make later keys unreachable. A **tombstone** marks the slot as deleted: lookups skip over it, and inserts may reuse it. Tombstones count toward the load factor, otherwise a table with many deletions can fill up with them and never stop probing. Growth drops them. The alternative is backward-shift deletion, which moves later entries back and needs no tombstones.
- **Hash function.** FNV-1a is a few lines (`h = (h ^ byte) * prime`, starting from an offset basis) and good enough for identifiers. It needs multiplication that wraps modulo 2^64 (or 2^32 for the 32-bit variant).
- **Iteration order** follows slot positions, so it depends on the capacity and on insertion history. Anything that has to be deterministic, such as the order of generated C, must not iterate a hash map. This matters again for the fixpoint in [[bootstrap/study/Bootstrapping]].

### Growable arrays and string builders

A growable array keeps `data`, `len` and `cap`, and doubles `cap` when a push does not fit, which makes push amortized O(1). Any pointer into `data` dies on a growing push. A compiler typically collects children into a growable array while parsing and then copies the finished list into the arena as a fixed slice.

A string builder is a growable array of bytes plus append helpers. Generated C, diagnostics and printed ASTs all go through one.

## How the C V1 does it

- **Arena: `tools/arena.c`.** `CtArena` is a linked list of `CtChunk`s of at least 8 KiB. `ct_arena_alloc` tries the current chunk with `chunk_try` (align up, check padding plus size), then later chunks, then allocates a new one big enough for the request. `ct_arena_reset` rewinds every chunk, and `ct_arena_destroy` frees them. `ct_arena_strdup` and `ct_arena_copy` are the helpers everything else uses. As [[plans/V1Compiler]] says, the whole compiler run uses one arena and frees nothing until exit.
- **Interning: `tools/intern.c`.** `ct_intern` hashes with `fnv1a_n`, then `probe` walks linear slots that store `str`, `len` and `hash`, comparing hash and length before `memcmp`. The table grows (`grow`) when it would pass 3/4 full, and the old slot array is simply abandoned in the arena. The lexer calls `ct_intern` in `lex_ident` and `lex_attribute` in `compiler/src/lexer.c`, so every `JogToken.value` for an identifier is canonical.
- **Hash map: `tools/map.c`.** `CtMap` maps NUL-terminated string keys to `void *`. Read `locate`: it stops at an empty slot, skips tombstones but remembers the first one so an insert can reuse it, and reports a live match. `load_reached` counts `count + tombstones` against 3/4 of capacity, `map_grow` doubles and rehashes only live entries (dropping tombstones), and `ct_map_remove` turns a slot into a tombstone. `ct_map_put` copies the key into the arena on first insert. Scope tables in `compiler/src/symbols.h` are `CtMap`s keyed by interned names.
- **Type interning: `compiler/src/types.c`.** Each structural constructor builds a canonical key in a `CtSb` (`key_begin`, `key_id`), looks it up in the `interned` `CtMap` (`lookup`), and only creates a new `JogType` when it is missing (`remember`). That is why `types.h` can promise pointer equality for structural types.
- **Growable array: `tools/da.c`.** `CtDa` is `data`, `count`, `capacity` and `item_size`, backed by `realloc`. `ct_da_push` starts at 8 slots and doubles. The parser collects nodes into a `CtDa` and then `take_nodes` in `parser.c` copies them into a fixed `JogList` in the arena.
- **Strings: `tools/str.c`.** `CtStr` is a pointer-and-length view, the same shape as Jog's `str`. `CtSb` is the string builder, with a sticky `failed` flag so callers check once at the end. The C backend writes the whole program through `CtSb`.

## Questions to answer in your own words

1. Why is an arena a good fit for AST nodes and types, and a poor fit for the documents an LSP keeps open for hours?
2. Write the align-up expression. Why does it require a power-of-two alignment, and what does `chunk_try` check besides "is there room for `size`"?
3. After interning, why is comparing two identifiers a pointer comparison? What would break if two interners were used for the same program?
4. In `tools/map.c`, why does `locate` keep scanning after it sees a tombstone instead of returning it immediately?
5. Why do tombstones count toward the load factor in `load_reached`? Construct a sequence of operations that would loop forever if they did not.
6. Why is iterating a hash map a problem for a compiler whose output must be byte-identical between runs?
7. `CtDa` uses `realloc`, but everything else lives in the arena. Why is that split sensible for lists that are still being built?

## Jog exercise

Write FNV-1a and a small string-keyed map with linear probing, tombstones and growth. It is deliberately not generic yet: `std` has no `newSlice<T>` and the language has no size-of intrinsic, so the slot size is written by hand. When you hit that, record it in [[bootstrap/Friction]] and make the map generic once the std helper exists.

```
import std.mem
import std.testing

// 32-bit FNV-1a, computed in u64 and masked. Overflow is checked
// everywhere and V1 has no wrappingMul yet, so the product must fit:
// h < 2^32 and the prime < 2^25.
val FnvOffset: u64 = 0x811c9dc5
val FnvPrime: u64 = 0x01000193

val Empty: u8 = 0
val Live: u8 = 1
val Tomb: u8 = 2

fn fnv1a(key: str): u32 {
    var h = FnvOffset
    for i in 0..key.len {
        h = ((h ^ (key.ptr[i] as u64)) * FnvPrime) & 0xFFFFFFFF
    }
    return h as u32
}

struct Slot {
    key: str
    value: i32
    state: u8
}

// str is 16 bytes, i32 4, u8 1, padded to 8: 24 bytes on x64.
val SlotSize: usize = 24

struct StrMap {
    slots: []Slot
    count: usize
    tombs: usize
}

// The index of a live match, or of the slot an insert should use.
fn StrMap.find(key: str): (usize, bool) {
    if self.slots.len == 0 {
        return 0, false
    }
    val mask = self.slots.len - 1
    var i = (fnv1a(key) as usize) & mask
    var tomb = self.slots.len
    for {
        val s = self.slots[i]
        if s.state == Empty {
            if tomb < self.slots.len {
                return tomb, false
            }
            return i, false
        }
        if s.state == Tomb {
            if tomb == self.slots.len {
                tomb = i
            }
        } else if s.key == key {
            return i, true
        }
        i = (i + 1) & mask
    }
}

fn *StrMap.grow() with (a: mem.Allocator) {
    var cap: usize = 8
    if self.slots.len > 0 {
        cap = self.slots.len * 2
    }
    val (raw, err) = a.alloc(cap * SlotSize, 8)
    if err != null {
        panic("out of memory")
    }
    val old = self.slots
    var fresh = []Slot()
    fresh.ptr = raw.ptr as *Slot
    fresh.len = cap
    self.slots = fresh
    self.count = 0
    self.tombs = 0
    for s in old {
        if s.state == Live {
            val (i, _) = self.find(s.key)
            self.slots[i] = s
            self.count += 1
        }
    }
    if old.len > 0 {
        var block = bytes()
        block.ptr = old.ptr as *u8
        block.len = old.len * SlotSize
        a.free(block)
    }
}

fn *StrMap.put(key: str, value: i32) with (a: mem.Allocator) {
    if (self.count + self.tombs + 1) * 4 > self.slots.len * 3 {
        self.grow()
    }
    val (i, found) = self.find(key)
    if !found {
        if self.slots[i].state == Tomb {
            self.tombs -= 1
        }
        self.count += 1
    }
    self.slots[i] = Slot(key: key, value: value, state: Live)
}

@test
fn putGetGrow() with (t: testing.Testing) {
    var m = StrMap(slots: []Slot(), count: 0, tombs: 0)
    with (mem.heap()) {
        m.put("a", 1)
        m.put("b", 2)
        m.put("a", 3)
        for i in 0..20 {
            m.put("k${i}", 0)
        }
    }
    val (i, found) = m.find("a")
    t.expect(found && m.slots[i].value == 3)
    t.expect(m.count == 22 && m.slots.len == 32)
}
```

Four lines in this code work around places where V1 is behind the language notes, and each belongs in [[bootstrap/Friction]]:

- There is no `wrappingMul` yet, although [[design/language/Types]] plans one, so the hash is 32-bit FNV-1a computed in `u64`.
- `bytes as []Slot` is rejected, so the slice is assembled from `.ptr` and `.len`.
- A `usize` does not convert to `usize?` yet, so `find` uses `slots.len` to mean "no tombstone seen".
- `key[i] as u8` (from `bytes[1]`) is rejected, so the loop reads `key.ptr[i]`, which is not bounds-checked.

Then extend it:

- Add `get(key): (i32, bool)` and `remove(key): bool`. Removing turns the slot into a tombstone. Write a test that removes and reinserts 1000 keys and checks that the table does not grow without bound.
- Answer question 5 with a test: what happens to `find` if `put` stops counting `tombs`?
- Copy the key into the allocator on first insert, the way `ct_map_put` does, and decide who frees it.
- Write the interner: the same probe loop over `str` slots that also store the hash and length, returning the canonical `str`.
- Write `Arena` as a struct that implements `mem.Allocator` (`alloc`, `resize`, `free`), so `with (&arena) { ... }` sends a whole call tree's allocations to it. See [[design/language/Memory]].

## Reading

From [[bootstrap/Reading]]:

- Ryan Fleury, "Untangling Lifetimes: The Arena Allocator" (start here).
- Crafting Interpreters, chapter "Hash Tables": open addressing, tombstones, FNV-1a and string interning in C.
- Abseil, "Swiss Tables Design Notes", after your first map works.

## See also

- [[bootstrap/Roadmap]]
- [[bootstrap/Checks]]
- [[bootstrap/Friction]]
- [[bootstrap/Reading]]
- [[bootstrap/study/Lexing]]
- [[bootstrap/study/NameResolution]]
- [[design/language/Memory]]
- [[design/language/Types]]
- [[plans/V1Compiler]]
