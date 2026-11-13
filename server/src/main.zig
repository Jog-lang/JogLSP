const std = @import("std");

/// JogLSP for JogCompiler v2: diagnostics via `jog check --diag=json` (+ `--module`
/// from `jog deps --flags` when jog.mod has path requires), document symbols via
/// `jog symbols --json`, plus buffer-local hover / definition / completion with
/// concurrency builtins. argv[1] or JOG / jog-v2 / sibling JogCompiler-v2 selects jog.

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();
    _ = args.skip();
    const jog_arg = args.next();

    var server = Server{
        .allocator = allocator,
        .jog = try resolveJog(allocator, jog_arg),
        .stdin = std.io.getStdIn(),
        .stdout = std.io.getStdOut(),
        .documents = .{},
    };
    defer {
        allocator.free(server.jog);
        var it = server.documents.iterator();
        while (it.next()) |e| {
            allocator.free(e.key_ptr.*);
            allocator.free(e.value_ptr.*);
        }
        server.documents.deinit(allocator);
    }

    try server.loop();
}

const Server = struct {
    allocator: std.mem.Allocator,
    jog: []const u8,
    stdin: std.fs.File,
    stdout: std.fs.File,
    documents: std.StringHashMapUnmanaged([]u8),

    fn loop(self: *Server) !void {
        var buf: std.ArrayListUnmanaged(u8) = .{};
        defer buf.deinit(self.allocator);
        var tmp: [4096]u8 = undefined;
        while (true) {
            const n = self.stdin.read(&tmp) catch |err| switch (err) {
                error.BrokenPipe => return,
                else => return err,
            };
            if (n == 0) return;
            try buf.appendSlice(self.allocator, tmp[0..n]);
            while (try self.tryHandleMessage(&buf)) {}
        }
    }

    fn tryHandleMessage(self: *Server, buf: *std.ArrayListUnmanaged(u8)) !bool {
        const header_end = std.mem.indexOf(u8, buf.items, "\r\n\r\n") orelse return false;
        const headers = buf.items[0..header_end];
        var content_length: ?usize = null;
        var hit = std.mem.tokenizeSequence(u8, headers, "\r\n");
        while (hit.next()) |line| {
            if (std.ascii.startsWithIgnoreCase(line, "Content-Length:")) {
                const v = std.mem.trim(u8, line["Content-Length:".len..], " \t");
                content_length = try std.fmt.parseInt(usize, v, 10);
            }
        }
        const len = content_length orelse return error.MissingContentLength;
        const total = header_end + 4 + len;
        if (buf.items.len < total) return false;
        const body = buf.items[header_end + 4 .. total];
        try self.dispatch(body);
        const rest = try self.allocator.dupe(u8, buf.items[total..]);
        buf.clearRetainingCapacity();
        try buf.appendSlice(self.allocator, rest);
        self.allocator.free(rest);
        return true;
    }

    fn dispatch(self: *Server, body: []const u8) !void {
        const parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, body, .{});
        defer parsed.deinit();
        const root = parsed.value;
        if (root != .object) return;
        const method = root.object.get("method") orelse {
            return;
        };
        if (method != .string) return;
        const id = root.object.get("id");

        if (std.mem.eql(u8, method.string, "initialize")) {
            try self.reply(id, .{
                .capabilities = .{
                    .textDocumentSync = .{
                        .openClose = true,
                        .change = 1, // Full
                        .save = .{ .includeText = true },
                    },
                    .hoverProvider = true,
                    .definitionProvider = true,
                    .documentSymbolProvider = true,
                    .completionProvider = .{
                        .triggerCharacters = .{ ".", "(" },
                        .resolveProvider = false,
                    },
                },
                .serverInfo = .{ .name = "jog-lsp", .version = "0.2.8-v2" },
            });
            return;
        }
        if (std.mem.eql(u8, method.string, "initialized")) return;
        if (std.mem.eql(u8, method.string, "shutdown")) {
            try self.reply(id, null);
            return;
        }
        if (std.mem.eql(u8, method.string, "exit")) {
            std.process.exit(0);
        }
        if (std.mem.eql(u8, method.string, "textDocument/didOpen")) {
            const params = root.object.get("params").?;
            const doc = params.object.get("textDocument").?;
            const uri = doc.object.get("uri").?.string;
            const text = doc.object.get("text").?.string;
            try self.setDoc(uri, text);
            try self.publishDiags(uri);
            return;
        }
        if (std.mem.eql(u8, method.string, "textDocument/didChange")) {
            const params = root.object.get("params").?;
            const uri = params.object.get("textDocument").?.object.get("uri").?.string;
            const changes = params.object.get("contentChanges").?.array;
            if (changes.items.len > 0) {
                const last = changes.items[changes.items.len - 1];
                if (last.object.get("text")) |t| {
                    try self.setDoc(uri, t.string);
                    try self.publishDiags(uri);
                }
            }
            return;
        }
        if (std.mem.eql(u8, method.string, "textDocument/didSave")) {
            const params = root.object.get("params").?;
            const uri = params.object.get("textDocument").?.object.get("uri").?.string;
            if (params.object.get("text")) |t| {
                if (t == .string) try self.setDoc(uri, t.string);
            }
            try self.publishDiags(uri);
            return;
        }
        if (std.mem.eql(u8, method.string, "textDocument/didClose")) {
            const params = root.object.get("params").?;
            const uri = params.object.get("textDocument").?.object.get("uri").?.string;
            if (self.documents.fetchRemove(uri)) |kv| {
                self.allocator.free(kv.key);
                self.allocator.free(kv.value);
            }
            var empty: std.ArrayListUnmanaged(u8) = .{};
            defer empty.deinit(self.allocator);
            try empty.appendSlice(self.allocator, "{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/publishDiagnostics\",\"params\":{\"uri\":");
            try std.json.stringify(uri, .{}, empty.writer(self.allocator));
            try empty.appendSlice(self.allocator, ",\"diagnostics\":[]}}");
            try self.writeRaw(empty.items);
            return;
        }
        if (std.mem.eql(u8, method.string, "textDocument/hover")) {
            const params = root.object.get("params").?;
            const uri = params.object.get("textDocument").?.object.get("uri").?.string;
            const pos = params.object.get("position").?;
            const line: i64 = switch (pos.object.get("line").?) {
                .integer => |n| n,
                else => 0,
            };
            const character: i64 = switch (pos.object.get("character").?) {
                .integer => |n| n,
                else => 0,
            };
            const text = self.documents.get(uri) orelse {
                try self.reply(id, null);
                return;
            };
            if (findSymbolAt(text, @intCast(line), @intCast(character))) |sym| {
                if (findDeclLine(text, sym)) |decl| {
                    const md = try std.fmt.allocPrint(self.allocator, "```jog\n{s}\n```", .{decl});
                    defer self.allocator.free(md);
                    try self.reply(id, .{
                        .contents = .{ .kind = "markdown", .value = md },
                    });
                    return;
                }
                if (lookupBuiltin(sym)) |b| {
                    const md = try std.fmt.allocPrint(
                        self.allocator,
                        "```jog\n{s}\n```\n\n{s}",
                        .{ b.signature, b.doc },
                    );
                    defer self.allocator.free(md);
                    try self.reply(id, .{
                        .contents = .{ .kind = "markdown", .value = md },
                    });
                    return;
                }
            }
            try self.reply(id, null);
            return;
        }
        if (std.mem.eql(u8, method.string, "textDocument/definition")) {
            const params = root.object.get("params").?;
            const uri = params.object.get("textDocument").?.object.get("uri").?.string;
            const pos = params.object.get("position").?;
            const line: i64 = switch (pos.object.get("line").?) {
                .integer => |n| n,
                else => 0,
            };
            const character: i64 = switch (pos.object.get("character").?) {
                .integer => |n| n,
                else => 0,
            };
            const text = self.documents.get(uri) orelse {
                try self.reply(id, null);
                return;
            };
            if (findSymbolAt(text, @intCast(line), @intCast(character))) |sym| {
                // Builtins have no source location; only jump to buffer decls.
                if (lookupBuiltin(sym) != null and findDeclLocation(text, sym) == null) {
                    try self.reply(id, null);
                    return;
                }
                if (findDeclLocation(text, sym)) |loc| {
                    try self.reply(id, .{
                        .uri = uri,
                        .range = .{
                            .start = .{ .line = loc.line, .character = loc.character },
                            .end = .{ .line = loc.line, .character = loc.character + sym.len },
                        },
                    });
                    return;
                }
            }
            try self.reply(id, null);
            return;
        }
        if (std.mem.eql(u8, method.string, "textDocument/completion")) {
            const params = root.object.get("params").?;
            const uri = params.object.get("textDocument").?.object.get("uri").?.string;
            const pos = params.object.get("position").?;
            const line: i64 = switch (pos.object.get("line").?) {
                .integer => |n| n,
                else => 0,
            };
            const character: i64 = switch (pos.object.get("character").?) {
                .integer => |n| n,
                else => 0,
            };
            const text = self.documents.get(uri) orelse {
                try self.reply(id, &.{});
                return;
            };
            const prefix = completionPrefix(text, @intCast(line), @intCast(character));
            var items: std.ArrayListUnmanaged(CompletionItem) = .{};
            defer items.deinit(self.allocator);

            for (builtins) |b| {
                if (prefix.len == 0 or std.mem.startsWith(u8, b.name, prefix)) {
                    try items.append(self.allocator, .{
                        .label = b.name,
                        .kind = b.completionKind(),
                        .detail = b.signature,
                        .documentation = b.doc,
                    });
                }
            }
            try appendLocalCompletions(self.allocator, &items, text, prefix);

            // Manual JSON: CompletionItem with optional fields
            var result_buf: std.ArrayListUnmanaged(u8) = .{};
            defer result_buf.deinit(self.allocator);
            try result_buf.append(self.allocator, '[');
            for (items.items, 0..) |it, i| {
                if (i > 0) try result_buf.append(self.allocator, ',');
                try result_buf.appendSlice(self.allocator, "{\"label\":");
                try std.json.stringify(it.label, .{}, result_buf.writer(self.allocator));
                try result_buf.writer(self.allocator).print(",\"kind\":{d},\"detail\":", .{it.kind});
                try std.json.stringify(it.detail, .{}, result_buf.writer(self.allocator));
                try result_buf.appendSlice(self.allocator, ",\"documentation\":{\"kind\":\"markdown\",\"value\":");
                try std.json.stringify(it.documentation, .{}, result_buf.writer(self.allocator));
                try result_buf.appendSlice(self.allocator, "}}");
            }
            try result_buf.append(self.allocator, ']');

            var msg: std.ArrayListUnmanaged(u8) = .{};
            defer msg.deinit(self.allocator);
            try msg.appendSlice(self.allocator, "{\"jsonrpc\":\"2.0\",\"result\":");
            try msg.appendSlice(self.allocator, result_buf.items);
            try msg.appendSlice(self.allocator, ",\"id\":");
            if (id) |i| {
                try std.json.stringify(i, .{}, msg.writer(self.allocator));
            } else {
                try msg.appendSlice(self.allocator, "null");
            }
            try msg.append(self.allocator, '}');
            try self.writeRaw(msg.items);
            return;
        }
        if (std.mem.eql(u8, method.string, "textDocument/documentSymbol")) {
            const params = root.object.get("params").?;
            const uri = params.object.get("textDocument").?.object.get("uri").?.string;
            const text = self.documents.get(uri) orelse {
                try self.reply(id, &.{});
                return;
            };
            const path = try uriToPath(self.allocator, uri);
            defer self.allocator.free(path);
            const tmp_path = try std.fmt.allocPrint(self.allocator, "{s}.jog-lsp-tmp", .{path});
            defer self.allocator.free(tmp_path);
            {
                const f = try std.fs.cwd().createFile(tmp_path, .{});
                defer f.close();
                try f.writeAll(text);
            }
            defer std.fs.cwd().deleteFile(tmp_path) catch {};

            var child = std.process.Child.init(&.{ self.jog, "symbols", "--json", tmp_path }, self.allocator);
            child.stdout_behavior = .Pipe;
            child.stderr_behavior = .Ignore;
            try child.spawn();
            const out = try child.stdout.?.readToEndAlloc(self.allocator, 2 * 1024 * 1024);
            defer self.allocator.free(out);
            _ = try child.wait();

            var result_buf: std.ArrayListUnmanaged(u8) = .{};
            defer result_buf.deinit(self.allocator);
            try result_buf.append(self.allocator, '[');
            var first = true;
            var lines = std.mem.splitScalar(u8, out, '\n');
            while (lines.next()) |line| {
                if (line.len == 0) continue;
                const obj = std.json.parseFromSlice(std.json.Value, self.allocator, line, .{}) catch continue;
                defer obj.deinit();
                if (obj.value != .object) continue;
                const name = if (obj.value.object.get("name")) |n| (if (n == .string) n.string else continue) else continue;
                const kind_s = if (obj.value.object.get("kind")) |k| (if (k == .string) k.string else "function") else "function";
                const line_n: i64 = if (obj.value.object.get("line")) |l| switch (l) {
                    .integer => l.integer,
                    else => 1,
                } else 1;
                const col_n: i64 = if (obj.value.object.get("column")) |c| switch (c) {
                    .integer => c.integer,
                    else => 1,
                } else 1;
                const kind: u8 = if (std.mem.eql(u8, kind_s, "function")) 12 else if (std.mem.eql(u8, kind_s, "struct")) 23 else if (std.mem.eql(u8, kind_s, "enum")) 10 else if (std.mem.eql(u8, kind_s, "interface")) 11 else if (std.mem.eql(u8, kind_s, "constant")) 14 else if (std.mem.eql(u8, kind_s, "type")) 26 else 13;
                const zl: i64 = if (line_n > 0) line_n - 1 else 0;
                const zc: i64 = if (col_n > 0) col_n - 1 else 0;
                if (!first) try result_buf.append(self.allocator, ',');
                first = false;
                try result_buf.appendSlice(self.allocator, "{\"name\":");
                try std.json.stringify(name, .{}, result_buf.writer(self.allocator));
                try result_buf.writer(self.allocator).print(
                    ",\"kind\":{d},\"range\":{{\"start\":{{\"line\":{d},\"character\":{d}}},\"end\":{{\"line\":{d},\"character\":{d}}}}},\"selectionRange\":{{\"start\":{{\"line\":{d},\"character\":{d}}},\"end\":{{\"line\":{d},\"character\":{d}}}}}",
                    .{ kind, zl, zc, zl, zc + @as(i64, @intCast(name.len)), zl, zc, zl, zc + @as(i64, @intCast(name.len)) },
                );
                try result_buf.append(self.allocator, '}');
            }
            try result_buf.append(self.allocator, ']');

            var msg: std.ArrayListUnmanaged(u8) = .{};
            defer msg.deinit(self.allocator);
            try msg.appendSlice(self.allocator, "{\"jsonrpc\":\"2.0\",\"result\":");
            try msg.appendSlice(self.allocator, result_buf.items);
            try msg.appendSlice(self.allocator, ",\"id\":");
            if (id) |i| {
                try std.json.stringify(i, .{}, msg.writer(self.allocator));
            } else {
                try msg.appendSlice(self.allocator, "null");
            }
            try msg.append(self.allocator, '}');
            try self.writeRaw(msg.items);
            return;
        }
    }

    fn setDoc(self: *Server, uri: []const u8, text: []const u8) !void {
        const key = try self.allocator.dupe(u8, uri);
        const val = try self.allocator.dupe(u8, text);
        const gop = try self.documents.getOrPut(self.allocator, key);
        if (gop.found_existing) {
            self.allocator.free(key);
            self.allocator.free(gop.value_ptr.*);
            gop.value_ptr.* = val;
        } else {
            gop.value_ptr.* = val;
        }
    }

    fn publishDiags(self: *Server, uri: []const u8) !void {
        const text = self.documents.get(uri) orelse return;
        const path = try uriToPath(self.allocator, uri);
        defer self.allocator.free(path);

        // Write buffer to a temp file so unsaved edits are checked.
        // Contract: `jog check --diag=json [--module=…] [--test] <path>` —
        // JSON lines on stdout (`file`,`line`,`column`,`severity`,`message`).
        const tmp_path = try std.fmt.allocPrint(self.allocator, "{s}.jog-lsp-tmp", .{path});
        defer self.allocator.free(tmp_path);
        {
            const f = try std.fs.cwd().createFile(tmp_path, .{});
            defer f.close();
            try f.writeAll(text);
        }
        defer std.fs.cwd().deleteFile(tmp_path) catch {};

        var argv: std.ArrayListUnmanaged([]const u8) = .{};
        defer argv.deinit(self.allocator);
        try argv.append(self.allocator, self.jog);
        try argv.append(self.allocator, "check");
        try argv.append(self.allocator, "--diag=json");
        if (std.mem.endsWith(u8, path, ".test.jog")) {
            try argv.append(self.allocator, "--test");
        }
        // Path requires from nearest jog.mod → `--module=name=dir`.
        var flag_storage: std.ArrayListUnmanaged([]u8) = .{};
        defer {
            for (flag_storage.items) |s| self.allocator.free(s);
            flag_storage.deinit(self.allocator);
        }
        if (try moduleRootOf(self.allocator, path)) |root| {
            defer self.allocator.free(root);
            if (try fetchModuleFlags(self.allocator, self.jog, root, std.mem.endsWith(u8, path, ".test.jog"))) |flags| {
                defer {
                    for (flags) |f| self.allocator.free(f);
                    self.allocator.free(flags);
                }
                for (flags) |f| {
                    const owned = try self.allocator.dupe(u8, f);
                    try flag_storage.append(self.allocator, owned);
                    try argv.append(self.allocator, owned);
                }
            }
        }
        try argv.append(self.allocator, tmp_path);

        var child = std.process.Child.init(argv.items, self.allocator);
        child.stdout_behavior = .Pipe;
        child.stderr_behavior = .Pipe;
        try child.spawn();
        const out = try child.stdout.?.readToEndAlloc(self.allocator, 4 * 1024 * 1024);
        defer self.allocator.free(out);
        const err = try child.stderr.?.readToEndAlloc(self.allocator, 1024 * 1024);
        defer self.allocator.free(err);
        _ = try child.wait();

        var diags: std.ArrayListUnmanaged(Diag) = .{};
        defer diags.deinit(self.allocator);

        var lines = std.mem.splitScalar(u8, out, '\n');
        while (lines.next()) |line| {
            if (line.len == 0) continue;
            const obj = std.json.parseFromSlice(std.json.Value, self.allocator, line, .{}) catch continue;
            defer obj.deinit();
            if (obj.value != .object) continue;
            const msg = if (obj.value.object.get("message")) |m| (if (m == .string) m.string else "error") else "error";
            const line_n: i64 = if (obj.value.object.get("line")) |l| switch (l) {
                .integer => l.integer,
                else => 1,
            } else 1;
            const col_n: i64 = if (obj.value.object.get("column")) |c| switch (c) {
                .integer => c.integer,
                else => 1,
            } else 1;
            const zero_line: i64 = if (line_n > 0) line_n - 1 else 0;
            const zero_col: i64 = if (col_n > 0) col_n - 1 else 0;
            try diags.append(self.allocator, .{
                .message = try self.allocator.dupe(u8, msg),
                .line = @intCast(zero_line),
                .character = @intCast(zero_col),
            });
        }
        // Also surface stderr parse chatter if no JSON lines
        if (diags.items.len == 0 and err.len > 0) {
            try diags.append(self.allocator, .{
                .message = try self.allocator.dupe(u8, std.mem.trim(u8, err, " \n\r\t")),
                .line = 0,
                .character = 0,
            });
        }

        // Build JSON manually for diagnostics array
        var payload: std.ArrayListUnmanaged(u8) = .{};
        defer payload.deinit(self.allocator);
        try payload.appendSlice(self.allocator, "{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/publishDiagnostics\",\"params\":");
        {
            var params_buf: std.ArrayListUnmanaged(u8) = .{};
            defer params_buf.deinit(self.allocator);
            try params_buf.appendSlice(self.allocator, "{\"uri\":");
            try std.json.stringify(uri, .{}, params_buf.writer(self.allocator));
            try params_buf.appendSlice(self.allocator, ",\"diagnostics\":[");
            for (diags.items, 0..) |d, i| {
                if (i > 0) try params_buf.append(self.allocator, ',');
                try params_buf.appendSlice(self.allocator, "{\"severity\":1,\"message\":");
                try std.json.stringify(d.message, .{}, params_buf.writer(self.allocator));
                try params_buf.writer(self.allocator).print(
                    ",\"range\":{{\"start\":{{\"line\":{d},\"character\":{d}}},\"end\":{{\"line\":{d},\"character\":{d}}}}}",
                    .{ d.line, d.character, d.line, d.character + 1 },
                );
                try params_buf.append(self.allocator, '}');
                self.allocator.free(d.message);
            }
            try params_buf.appendSlice(self.allocator, "]}");
            try payload.appendSlice(self.allocator, params_buf.items);
        }
        try payload.append(self.allocator, '}');
        try self.writeRaw(payload.items);
    }

    fn reply(self: *Server, id: ?std.json.Value, result: anytype) !void {
        var buf: std.ArrayListUnmanaged(u8) = .{};
        defer buf.deinit(self.allocator);
        try buf.appendSlice(self.allocator, "{\"jsonrpc\":\"2.0\",\"result\":");
        try std.json.stringify(result, .{}, buf.writer(self.allocator));
        try buf.appendSlice(self.allocator, ",\"id\":");
        if (id) |i| {
            try std.json.stringify(i, .{}, buf.writer(self.allocator));
        } else {
            try buf.appendSlice(self.allocator, "null");
        }
        try buf.append(self.allocator, '}');
        try self.writeRaw(buf.items);
    }

    fn writeRaw(self: *Server, body: []const u8) !void {
        var header_buf: [64]u8 = undefined;
        const header = try std.fmt.bufPrint(&header_buf, "Content-Length: {d}\r\n\r\n", .{body.len});
        try self.stdout.writeAll(header);
        try self.stdout.writeAll(body);
    }
};

const Diag = struct {
    message: []u8,
    line: u32,
    character: u32,
};

const DeclLoc = struct { line: u32, character: u32 };

const CompletionItem = struct {
    label: []const u8,
    kind: u8,
    detail: []const u8,
    documentation: []const u8,
};

const BuiltinKind = enum { fn_builtin, type_builtin, keyword };

const Builtin = struct {
    name: []const u8,
    kind: BuiltinKind,
    signature: []const u8,
    doc: []const u8,

    fn completionKind(self: Builtin) u8 {
        return switch (self.kind) {
            .fn_builtin => 3, // Function
            .type_builtin => 25, // TypeParameter / Class-ish
            .keyword => 14, // Keyword
        };
    }
};

/// Language + runtime surface present in JogCompiler v2 after Gates 1–4 + Chase-Lev.
const builtins = [_]Builtin{
    .{ .name = "go", .kind = .fn_builtin, .signature = "fn go(entry: fn(*byte), arg: *byte)", .doc = "Enqueue a stackful coroutine on the current Dispatcher pool." },
    .{ .name = "yield", .kind = .fn_builtin, .signature = "fn yield()", .doc = "Cooperatively yield to another ready coroutine on this worker." },
    .{ .name = "with", .kind = .keyword, .signature = "with (dispatcher: Dispatcher) { ... }", .doc = "Run the block on `dispatcher` (Kotlin `withContext` shape); migrates the stackful coro across pools." },
    .{ .name = "Dispatcher", .kind = .type_builtin, .signature = "type Dispatcher", .doc = "Opaque pool handle (i64-sized). Use with `with (Dispatcher)` and dispatcher_* APIs." },
    .{ .name = "dispatcher_io", .kind = .fn_builtin, .signature = "fn dispatcher_io() -> Dispatcher", .doc = "Elastic blocking/IO Dispatcher pool (gate 4)." },
    .{ .name = "dispatcher_single", .kind = .fn_builtin, .signature = "fn dispatcher_single() -> Dispatcher", .doc = "Deterministic single-worker Dispatcher (cooperative interleaving)." },
    .{ .name = "dispatcher_pool", .kind = .fn_builtin, .signature = "fn dispatcher_pool(workers: i64 = 0) -> Dispatcher", .doc = "Primary M:N worker pool (0 = default sizing)." },
    .{ .name = "dispatcher_new", .kind = .fn_builtin, .signature = "fn dispatcher_new(workers: i64 = 0) -> Dispatcher", .doc = "Create an additional Dispatcher pool (secondary id)." },
    .{ .name = "dispatcher_get", .kind = .fn_builtin, .signature = "fn dispatcher_get(id: i64) -> Dispatcher", .doc = "Look up a Dispatcher by pool id." },
    .{ .name = "coro_drain", .kind = .fn_builtin, .signature = "fn coro_drain()", .doc = "Run until only the main coroutine remains." },
    .{ .name = "coro_alive", .kind = .fn_builtin, .signature = "fn coro_alive() -> i64", .doc = "Count of live coroutines." },
    .{ .name = "coro_id", .kind = .fn_builtin, .signature = "fn coro_id() -> i64", .doc = "Current coroutine id." },
    .{ .name = "coro_park", .kind = .fn_builtin, .signature = "fn coro_park()", .doc = "Park the current coroutine." },
    .{ .name = "coro_unpark", .kind = .fn_builtin, .signature = "fn coro_unpark(id: i64)", .doc = "Unpark a parked coroutine by id." },
    .{ .name = "spawn", .kind = .fn_builtin, .signature = "fn spawn(entry: fn(*byte), arg: *byte)", .doc = "Synchronous OS-thread spawn via `jogrt_spawn`." },
    .{ .name = "sleep_ms", .kind = .fn_builtin, .signature = "fn sleep_ms(ms: i64)", .doc = "Block the current coro for `ms` (IO pool grows under load)." },
    .{ .name = "print_tid", .kind = .fn_builtin, .signature = "fn print_tid()", .doc = "Print OS tid / worker id for concurrency proofs." },
    .{ .name = "worker_id", .kind = .fn_builtin, .signature = "fn worker_id() -> i64", .doc = "Current pool worker id." },
    .{ .name = "gettid", .kind = .fn_builtin, .signature = "fn gettid() -> i64", .doc = "Current OS thread id." },
    .{ .name = "print", .kind = .fn_builtin, .signature = "fn print(msg: str)", .doc = "Write a string to stdout." },
    .{ .name = "alloc", .kind = .fn_builtin, .signature = "fn alloc(n: usize) -> *byte", .doc = "Allocate `n` bytes." },
};

fn lookupBuiltin(name: []const u8) ?Builtin {
    for (builtins) |b| {
        if (std.mem.eql(u8, b.name, name)) return b;
    }
    return null;
}

fn isIdentChar(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9') or c == '_';
}

fn findSymbolAt(text: []const u8, line: u32, character: u32) ?[]const u8 {
    var line_i: u32 = 0;
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        if (line_i == line) {
            const line_start = i;
            while (i < text.len and text[i] != '\n') : (i += 1) {}
            const line_text = text[line_start..i];
            if (character >= line_text.len) return null;
            var start = character;
            while (start > 0 and isIdentChar(line_text[start - 1])) : (start -= 1) {}
            var end = character;
            while (end < line_text.len and isIdentChar(line_text[end])) : (end += 1) {}
            if (start == end) return null;
            return line_text[start..end];
        }
        if (text[i] == '\n') line_i += 1;
    }
    return null;
}

fn completionPrefix(text: []const u8, line: u32, character: u32) []const u8 {
    var line_i: u32 = 0;
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        if (line_i == line) {
            const line_start = i;
            while (i < text.len and text[i] != '\n') : (i += 1) {}
            const line_text = text[line_start..i];
            const col: usize = @min(character, line_text.len);
            var start = col;
            while (start > 0 and isIdentChar(line_text[start - 1])) : (start -= 1) {}
            return line_text[start..col];
        }
        if (text[i] == '\n') line_i += 1;
    }
    return "";
}

fn findDeclLine(text: []const u8, name: []const u8) ?[]const u8 {
    var line_start: usize = 0;
    var i: usize = 0;
    while (i <= text.len) : (i += 1) {
        if (i == text.len or text[i] == '\n') {
            const line = text[line_start..i];
            if (lineContainsDecl(line, name)) {
                return std.mem.trim(u8, line, " \t\r");
            }
            line_start = i + 1;
        }
    }
    return null;
}

fn findDeclLocation(text: []const u8, name: []const u8) ?DeclLoc {
    var line_i: u32 = 0;
    var line_start: usize = 0;
    var i: usize = 0;
    while (i <= text.len) : (i += 1) {
        if (i == text.len or text[i] == '\n') {
            const line = text[line_start..i];
            if (lineContainsDecl(line, name)) {
                if (std.mem.indexOf(u8, line, name)) |col| {
                    return .{ .line = line_i, .character = @intCast(col) };
                }
            }
            line_start = i + 1;
            line_i += 1;
        }
    }
    return null;
}

fn lineContainsDecl(line: []const u8, name: []const u8) bool {
    const trimmed = std.mem.trim(u8, line, " \t");
    const prefixes = [_][]const u8{ "fn ", "struct ", "type ", "interface ", "val ", "var " };
    for (prefixes) |p| {
        if (std.mem.startsWith(u8, trimmed, p)) {
            const rest = trimmed[p.len..];
            var r = rest;
            if (r.len > 0 and r[0] == '*') r = r[1..];
            if (std.mem.startsWith(u8, r, name)) {
                const after = r[name.len..];
                if (after.len == 0 or !isIdentChar(after[0])) return true;
            }
            if (std.mem.indexOfScalar(u8, r, '.')) |dot| {
                const after_dot = r[dot + 1 ..];
                if (std.mem.startsWith(u8, after_dot, name)) {
                    const after = after_dot[name.len..];
                    if (after.len == 0 or !isIdentChar(after[0])) return true;
                }
            }
        }
    }
    return false;
}

fn appendLocalCompletions(
    allocator: std.mem.Allocator,
    items: *std.ArrayListUnmanaged(CompletionItem),
    text: []const u8,
    prefix: []const u8,
) !void {
    var line_start: usize = 0;
    var i: usize = 0;
    while (i <= text.len) : (i += 1) {
        if (i == text.len or text[i] == '\n') {
            const line = std.mem.trim(u8, text[line_start..i], " \t\r");
            if (extractDeclName(line)) |name| {
                if (prefix.len == 0 or std.mem.startsWith(u8, name, prefix)) {
                    // Skip if already offered as a builtin
                    if (lookupBuiltin(name) == null) {
                        var dup = false;
                        for (items.items) |it| {
                            if (std.mem.eql(u8, it.label, name)) {
                                dup = true;
                                break;
                            }
                        }
                        if (!dup) {
                            try items.append(allocator, .{
                                .label = name,
                                .kind = 3,
                                .detail = line,
                                .documentation = "Local declaration",
                            });
                        }
                    }
                }
            }
            line_start = i + 1;
        }
    }
}

fn extractDeclName(line: []const u8) ?[]const u8 {
    const prefixes = [_][]const u8{ "fn ", "struct ", "type ", "interface ", "val ", "var " };
    for (prefixes) |p| {
        if (std.mem.startsWith(u8, line, p)) {
            var r = line[p.len..];
            if (r.len > 0 and r[0] == '*') r = r[1..];
            // skip Type. for methods — return method name
            if (std.mem.indexOfScalar(u8, r, '.')) |dot| {
                r = r[dot + 1 ..];
            }
            var end: usize = 0;
            while (end < r.len and isIdentChar(r[end])) : (end += 1) {}
            if (end == 0) return null;
            return r[0..end];
        }
    }
    return null;
}

fn parentDir(allocator: std.mem.Allocator, path: []const u8) !?[]u8 {
    const dir = std.fs.path.dirname(path) orelse return null;
    return try allocator.dupe(u8, dir);
}

fn moduleRootOf(allocator: std.mem.Allocator, file_path: []const u8) !?[]u8 {
    var dir = (try parentDir(allocator, file_path)) orelse return null;
    while (true) {
        const mod_path = try std.fs.path.join(allocator, &.{ dir, "jog.mod" });
        const found = fileExists(mod_path);
        allocator.free(mod_path);
        if (found) return dir;
        const up = (try parentDir(allocator, dir)) orelse {
            allocator.free(dir);
            return null;
        };
        if (std.mem.eql(u8, up, dir)) {
            allocator.free(up);
            allocator.free(dir);
            return null;
        }
        allocator.free(dir);
        dir = up;
    }
}

/// Run `jog deps --flags [--test]` in the module root; returns owned `--module=…` lines.
fn fetchModuleFlags(allocator: std.mem.Allocator, jog: []const u8, root: []const u8, include_test: bool) !?[][]u8 {
    var argv: std.ArrayListUnmanaged([]const u8) = .{};
    defer argv.deinit(allocator);
    try argv.append(allocator, jog);
    try argv.append(allocator, "deps");
    try argv.append(allocator, "--flags");
    if (include_test) try argv.append(allocator, "--test");
    try argv.append(allocator, root);

    var child = std.process.Child.init(argv.items, allocator);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Ignore;
    child.cwd = root;
    try child.spawn();
    const out = try child.stdout.?.readToEndAlloc(allocator, 1024 * 1024);
    defer allocator.free(out);
    _ = try child.wait();

    var list: std.ArrayListUnmanaged([]u8) = .{};
    errdefer {
        for (list.items) |s| allocator.free(s);
        list.deinit(allocator);
    }
    var lines = std.mem.splitScalar(u8, out, '\n');
    while (lines.next()) |line| {
        const t = std.mem.trim(u8, line, " \t\r");
        if (t.len == 0) continue;
        if (!std.mem.startsWith(u8, t, "--module")) continue;
        try list.append(allocator, try allocator.dupe(u8, t));
    }
    if (list.items.len == 0) {
        list.deinit(allocator);
        return null;
    }
    return try list.toOwnedSlice(allocator);
}

fn resolveJog(allocator: std.mem.Allocator, arg: ?[]const u8) ![]u8 {
    if (arg) |a| {
        if (a.len > 0) return try allocator.dupe(u8, a);
    }
    if (std.posix.getenv("JOG")) |j| {
        if (j.len > 0) return try allocator.dupe(u8, j);
    }
    if (std.posix.getenv("HOME")) |home| {
        const p = try std.fs.path.join(allocator, &.{ home, ".local/bin/jog-v2" });
        if (fileExists(p)) return p;
        allocator.free(p);
        const jog_home = try std.fs.path.join(allocator, &.{ home, ".local/bin/jog" });
        defer allocator.free(jog_home);
        if (fileExists(jog_home)) {
            if (try isV2Jog(allocator, jog_home)) return try allocator.dupe(u8, jog_home);
        }
    }
    if (try siblingCompilerJog(allocator)) |p| return p;

    const candidates = [_][]const u8{ "jog-v2", "jog" };
    for (candidates) |name| {
        if (try which(allocator, name)) |p| {
            if (try isV2Jog(allocator, p) or std.mem.eql(u8, name, "jog-v2")) return p;
            allocator.free(p);
        }
    }
    std.debug.print("jog-lsp: JogCompiler v2 not found. Set JOG or pass jog as argv[1].\n", .{});
    std.process.exit(1);
}

fn siblingCompilerJog(allocator: std.mem.Allocator) !?[]u8 {
    const rel = "JogCompiler-v2/zig-out/bin/jog";
    const cwd_cand = try std.fs.path.join(allocator, &.{ "..", rel });
    defer allocator.free(cwd_cand);
    if (fileExists(cwd_cand)) {
        if (try isV2Jog(allocator, cwd_cand)) return try allocator.dupe(u8, cwd_cand);
    }

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const exe = std.fs.selfExePath(&buf) catch return null;
    const exe_dir = std.fs.path.dirname(exe) orelse return null;
    // JogLSP/server/zig-out/bin → ../../../JogCompiler-v2/...
    const from_bin = try std.fs.path.join(allocator, &.{ exe_dir, "../../..", rel });
    defer allocator.free(from_bin);
    if (fileExists(from_bin)) {
        if (try isV2Jog(allocator, from_bin)) return try allocator.dupe(u8, from_bin);
    }
    // editors/vscode/bin/server → ../../../JogCompiler-v2/...
    const from_ext = try std.fs.path.join(allocator, &.{ exe_dir, "../..", rel });
    defer allocator.free(from_ext);
    if (fileExists(from_ext)) {
        if (try isV2Jog(allocator, from_ext)) return try allocator.dupe(u8, from_ext);
    }
    return null;
}

fn isV2Jog(allocator: std.mem.Allocator, path: []const u8) !bool {
    var child = std.process.Child.init(&.{ path, "version" }, allocator);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Ignore;
    try child.spawn();
    const out = try child.stdout.?.readToEndAlloc(allocator, 4096);
    defer allocator.free(out);
    _ = try child.wait();
    return std.mem.indexOf(u8, out, "-v2") != null or std.mem.indexOf(u8, out, "v2") != null;
}

fn which(allocator: std.mem.Allocator, name: []const u8) !?[]u8 {
    const path_env = std.posix.getenv("PATH") orelse return null;
    var it = std.mem.splitScalar(u8, path_env, ':');
    while (it.next()) |dir| {
        if (dir.len == 0) continue;
        const cand = try std.fs.path.join(allocator, &.{ dir, name });
        if (fileExists(cand)) return cand;
        allocator.free(cand);
    }
    return null;
}

fn fileExists(path: []const u8) bool {
    std.fs.cwd().access(path, .{}) catch return false;
    return true;
}

fn uriToPath(allocator: std.mem.Allocator, uri: []const u8) ![]u8 {
    const prefix = "file://";
    if (!std.mem.startsWith(u8, uri, prefix)) return try allocator.dupe(u8, uri);
    const path = uri[prefix.len..];
    var out: std.ArrayListUnmanaged(u8) = .{};
    errdefer out.deinit(allocator);
    var i: usize = 0;
    while (i < path.len) : (i += 1) {
        if (path[i] == '%' and i + 2 < path.len) {
            const hex = path[i + 1 .. i + 3];
            const b = std.fmt.parseInt(u8, hex, 16) catch {
                try out.append(allocator, path[i]);
                continue;
            };
            try out.append(allocator, b);
            i += 2;
        } else {
            try out.append(allocator, path[i]);
        }
    }
    return try out.toOwnedSlice(allocator);
}
