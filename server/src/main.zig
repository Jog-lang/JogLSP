const std = @import("std");

/// JogLSP for JogCompiler v2: diagnostics via `jog check --diag=json`, IDE
/// features via `jog ide` (hover/definition/complete/references/symbols), plus
/// concurrency builtins as fallback when the compiler has no source. argv[1] or
/// JOG / jog-v2 / sibling JogCompiler-v2 selects jog.

const server_version = "0.2.11-v2";
const diag_debounce_ms: i64 = 200;

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
        if (server.root_uri) |r| allocator.free(r);
        if (server.pending_diag_uri) |u| allocator.free(u);
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
    root_uri: ?[]u8 = null,
    pending_diag_uri: ?[]u8 = null,
    pending_diag_at_ms: i64 = 0,

    fn loop(self: *Server) !void {
        var buf: std.ArrayListUnmanaged(u8) = .{};
        defer buf.deinit(self.allocator);
        var tmp: [4096]u8 = undefined;
        while (true) {
            try self.maybeFlushPendingDiags();
            const timeout_ms: i32 = if (self.pending_diag_uri != null) 50 else -1;
            const ready = try pollReadable(self.stdin.handle, timeout_ms);
            if (!ready) {
                try self.maybeFlushPendingDiags();
                continue;
            }
            const n = self.stdin.read(&tmp) catch |err| switch (err) {
                error.BrokenPipe => return,
                else => return err,
            };
            if (n == 0) return;
            try buf.appendSlice(self.allocator, tmp[0..n]);
            while (try self.tryHandleMessage(&buf)) {}
        }
    }

    fn maybeFlushPendingDiags(self: *Server) !void {
        const uri = self.pending_diag_uri orelse return;
        const now = std.time.milliTimestamp();
        if (now - self.pending_diag_at_ms < diag_debounce_ms) return;
        const owned = uri;
        self.pending_diag_uri = null;
        defer self.allocator.free(owned);
        try self.publishDiags(owned);
    }

    fn scheduleDiags(self: *Server, uri: []const u8) !void {
        if (self.pending_diag_uri) |old| {
            if (!std.mem.eql(u8, old, uri)) {
                // Different doc: flush previous immediately.
                self.pending_diag_uri = null;
                defer self.allocator.free(old);
                try self.publishDiags(old);
            } else {
                self.allocator.free(old);
                self.pending_diag_uri = null;
            }
        }
        self.pending_diag_uri = try self.allocator.dupe(u8, uri);
        self.pending_diag_at_ms = std.time.milliTimestamp();
    }

    fn flushPendingBeforeQuery(self: *Server) !void {
        if (self.pending_diag_uri) |uri| {
            self.pending_diag_uri = null;
            defer self.allocator.free(uri);
            try self.publishDiags(uri);
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
        const method = root.object.get("method") orelse return;
        if (method != .string) return;
        const id = root.object.get("id");

        if (std.mem.eql(u8, method.string, "initialize")) {
            if (root.object.get("params")) |params| {
                if (params == .object) {
                    if (params.object.get("rootUri")) |ru| {
                        if (ru == .string and ru.string.len > 0) {
                            if (self.root_uri) |old| self.allocator.free(old);
                            self.root_uri = try self.allocator.dupe(u8, ru.string);
                        }
                    }
                }
            }
            try self.reply(id, .{
                .capabilities = .{
                    .textDocumentSync = .{
                        .openClose = true,
                        .change = 1, // Full
                        .save = .{ .includeText = true },
                    },
                    .hoverProvider = true,
                    .definitionProvider = true,
                    .referencesProvider = true,
                    .documentSymbolProvider = true,
                    .workspaceSymbolProvider = true,
                    .renameProvider = .{ .prepareProvider = true },
                    .signatureHelpProvider = .{
                        .triggerCharacters = .{"("},
                        .retriggerCharacters = .{ "," },
                    },
                    .completionProvider = .{
                        .triggerCharacters = .{ ".", "(" },
                        .resolveProvider = false,
                    },
                },
                .serverInfo = .{ .name = "jog-lsp", .version = server_version },
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
                    try self.scheduleDiags(uri);
                }
            }
            return;
        }
        if (std.mem.eql(u8, method.string, "textDocument/didSave")) {
            try self.flushPendingBeforeQuery();
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
            if (self.pending_diag_uri) |p| {
                if (std.mem.eql(u8, p, uri)) {
                    self.allocator.free(p);
                    self.pending_diag_uri = null;
                }
            }
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
            try self.flushPendingBeforeQuery();
            try self.handleHover(id, root.object.get("params").?);
            return;
        }
        if (std.mem.eql(u8, method.string, "textDocument/definition")) {
            try self.flushPendingBeforeQuery();
            try self.handleDefinition(id, root.object.get("params").?);
            return;
        }
        if (std.mem.eql(u8, method.string, "textDocument/completion")) {
            try self.flushPendingBeforeQuery();
            try self.handleCompletion(id, root.object.get("params").?);
            return;
        }
        if (std.mem.eql(u8, method.string, "textDocument/references")) {
            try self.flushPendingBeforeQuery();
            try self.handleReferences(id, root.object.get("params").?);
            return;
        }
        if (std.mem.eql(u8, method.string, "textDocument/signatureHelp")) {
            try self.flushPendingBeforeQuery();
            try self.handleSignatureHelp(id, root.object.get("params").?);
            return;
        }
        if (std.mem.eql(u8, method.string, "textDocument/prepareRename")) {
            try self.flushPendingBeforeQuery();
            try self.handlePrepareRename(id, root.object.get("params").?);
            return;
        }
        if (std.mem.eql(u8, method.string, "textDocument/rename")) {
            try self.flushPendingBeforeQuery();
            try self.handleRename(id, root.object.get("params").?);
            return;
        }
        if (std.mem.eql(u8, method.string, "workspace/symbol")) {
            try self.flushPendingBeforeQuery();
            try self.handleWorkspaceSymbol(id, root.object.get("params").?);
            return;
        }
        if (std.mem.eql(u8, method.string, "textDocument/documentSymbol")) {
            try self.flushPendingBeforeQuery();
            try self.handleDocumentSymbol(id, root.object.get("params").?);
            return;
        }
    }

    fn positionOf(params: std.json.Value) struct { line: u32, character: u32 } {
        const pos = params.object.get("position").?;
        const line: i64 = switch (pos.object.get("line").?) {
            .integer => |n| n,
            else => 0,
        };
        const character: i64 = switch (pos.object.get("character").?) {
            .integer => |n| n,
            else => 0,
        };
        return .{ .line = @intCast(line), .character = @intCast(character) };
    }

    fn handleHover(self: *Server, id: ?std.json.Value, params: std.json.Value) !void {
        const uri = params.object.get("textDocument").?.object.get("uri").?.string;
        const pos = positionOf(params);
        const text = self.documents.get(uri) orelse {
            try self.reply(id, null);
            return;
        };
        if (try self.runIdeJson(uri, text, "hover", pos.line, pos.character)) |raw| {
            defer self.allocator.free(raw);
            if (parseIdeObject(self.allocator, raw)) |obj| {
                defer obj.deinit();
                if (jsonBool(obj.value, "ok")) {
                    if (jsonString(obj.value, "contents")) |contents| {
                        if (contents.len > 0) {
                            const md = try std.fmt.allocPrint(self.allocator, "```jog\n{s}\n```", .{contents});
                            defer self.allocator.free(md);
                            try self.reply(id, .{
                                .contents = .{ .kind = "markdown", .value = md },
                            });
                            return;
                        }
                    }
                }
            }
        }
        // Builtins only when compiler has no source (intrinsics).
        if (findSymbolAt(text, pos.line, pos.character)) |sym| {
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
    }

    fn handleDefinition(self: *Server, id: ?std.json.Value, params: std.json.Value) !void {
        const uri = params.object.get("textDocument").?.object.get("uri").?.string;
        const pos = positionOf(params);
        const text = self.documents.get(uri) orelse {
            try self.reply(id, null);
            return;
        };
        if (try self.runIdeJson(uri, text, "definition", pos.line, pos.character)) |raw| {
            defer self.allocator.free(raw);
            if (parseIdeObject(self.allocator, raw)) |obj| {
                defer obj.deinit();
                if (jsonBool(obj.value, "ok")) {
                    if (jsonString(obj.value, "file")) |file| {
                        const loc = try locationFromIde(self.allocator, obj.value, file);
                        defer self.allocator.free(loc.uri);
                        try self.reply(id, .{
                            .uri = loc.uri,
                            .range = loc.range,
                        });
                        return;
                    }
                }
            }
        }
        // Builtins / unresolved: no source.
        try self.reply(id, null);
    }

    fn handleCompletion(self: *Server, id: ?std.json.Value, params: std.json.Value) !void {
        const uri = params.object.get("textDocument").?.object.get("uri").?.string;
        const pos = positionOf(params);
        const text = self.documents.get(uri) orelse {
            try self.replyRawResult(id, "[]");
            return;
        };
        var items: std.ArrayListUnmanaged(CompletionItem) = .{};
        defer items.deinit(self.allocator);

        const after_dot = textEndsWithDotContext(text, pos.line, pos.character);
        if (try self.runIdeJson(uri, text, "complete", pos.line, pos.character)) |raw| {
            defer self.allocator.free(raw);
            if (parseIdeObject(self.allocator, raw)) |obj| {
                defer obj.deinit();
                if (obj.value.object.get("items")) |arr| {
                    if (arr == .array) {
                        for (arr.array.items) |it| {
                            if (it != .object) continue;
                            const label = if (it.object.get("label")) |l| (if (l == .string) l.string else continue) else continue;
                            const kind_s = if (it.object.get("kind")) |k| (if (k == .string) k.string else "variable") else "variable";
                            const detail = if (it.object.get("detail")) |d| (if (d == .string) d.string else "") else "";
                            try items.append(self.allocator, .{
                                .label = try self.allocator.dupe(u8, label),
                                .kind = ideKindToCompletion(kind_s),
                                .detail = try self.allocator.dupe(u8, detail),
                                .documentation = try self.allocator.dupe(u8, ""),
                                .owned = true,
                            });
                        }
                    }
                }
            }
        }

        // Merge builtins unless member-completing after `.`.
        if (!after_dot) {
            const prefix = completionPrefix(text, pos.line, pos.character);
            for (builtins) |b| {
                if (prefix.len == 0 or std.mem.startsWith(u8, b.name, prefix)) {
                    var dup = false;
                    for (items.items) |it| {
                        if (std.mem.eql(u8, it.label, b.name)) {
                            dup = true;
                            break;
                        }
                    }
                    if (!dup) {
                        try items.append(self.allocator, .{
                            .label = b.name,
                            .kind = b.completionKind(),
                            .detail = b.signature,
                            .documentation = b.doc,
                            .owned = false,
                        });
                    }
                }
            }
        }

        var result_buf: std.ArrayListUnmanaged(u8) = .{};
        defer result_buf.deinit(self.allocator);
        try result_buf.append(self.allocator, '[');
        for (items.items, 0..) |it, i| {
            if (i > 0) try result_buf.append(self.allocator, ',');
            try result_buf.appendSlice(self.allocator, "{\"label\":");
            try std.json.stringify(it.label, .{}, result_buf.writer(self.allocator));
            try result_buf.writer(self.allocator).print(",\"kind\":{d}", .{it.kind});
            if (it.detail.len > 0) {
                try result_buf.appendSlice(self.allocator, ",\"detail\":");
                try std.json.stringify(it.detail, .{}, result_buf.writer(self.allocator));
            }
            if (it.documentation.len > 0) {
                try result_buf.appendSlice(self.allocator, ",\"documentation\":{\"kind\":\"markdown\",\"value\":");
                try std.json.stringify(it.documentation, .{}, result_buf.writer(self.allocator));
                try result_buf.append(self.allocator, '}');
            }
            try result_buf.append(self.allocator, '}');
            if (it.owned) {
                self.allocator.free(it.label);
                self.allocator.free(it.detail);
                self.allocator.free(it.documentation);
            }
        }
        try result_buf.append(self.allocator, ']');
        try self.replyRawResult(id, result_buf.items);
    }

    fn handleReferences(self: *Server, id: ?std.json.Value, params: std.json.Value) !void {
        const uri = params.object.get("textDocument").?.object.get("uri").?.string;
        const pos = positionOf(params);
        const text = self.documents.get(uri) orelse {
            try self.replyRawResult(id, "[]");
            return;
        };
        var result_buf: std.ArrayListUnmanaged(u8) = .{};
        defer result_buf.deinit(self.allocator);
        try result_buf.append(self.allocator, '[');
        var first = true;
        if (try self.runIdeJson(uri, text, "references", pos.line, pos.character)) |raw| {
            defer self.allocator.free(raw);
            if (parseIdeObject(self.allocator, raw)) |obj| {
                defer obj.deinit();
                if (obj.value.object.get("refs")) |arr| {
                    if (arr == .array) {
                        for (arr.array.items) |r| {
                            if (r != .object) continue;
                            const file = jsonString(r, "file") orelse continue;
                            const loc = try locationFromIde(self.allocator, r, file);
                            defer self.allocator.free(loc.uri);
                            if (!first) try result_buf.append(self.allocator, ',');
                            first = false;
                            try appendLocationJson(&result_buf, self.allocator, loc);
                        }
                    }
                }
            }
        }
        try result_buf.append(self.allocator, ']');
        try self.replyRawResult(id, result_buf.items);
    }

    fn handleSignatureHelp(self: *Server, id: ?std.json.Value, params: std.json.Value) !void {
        const uri = params.object.get("textDocument").?.object.get("uri").?.string;
        const pos = positionOf(params);
        const text = self.documents.get(uri) orelse {
            try self.reply(id, null);
            return;
        };
        // Walk back to the call name before `(` at/near the cursor.
        const call_pos = findCallNamePosition(text, pos.line, pos.character) orelse {
            try self.reply(id, null);
            return;
        };
        if (try self.runIdeJson(uri, text, "hover", call_pos.line, call_pos.character)) |raw| {
            defer self.allocator.free(raw);
            if (parseIdeObject(self.allocator, raw)) |obj| {
                defer obj.deinit();
                if (jsonBool(obj.value, "ok")) {
                    if (jsonString(obj.value, "contents")) |contents| {
                        if (contents.len > 0 and (std.mem.startsWith(u8, contents, "fn ") or std.mem.indexOf(u8, contents, "(") != null)) {
                            try self.reply(id, .{
                                .signatures = .{
                                    .{ .label = contents, .documentation = contents },
                                },
                                .activeSignature = 0,
                                .activeParameter = 0,
                            });
                            return;
                        }
                    }
                }
            }
        }
        if (findSymbolAt(text, call_pos.line, call_pos.character)) |sym| {
            if (lookupBuiltin(sym)) |b| {
                try self.reply(id, .{
                    .signatures = .{
                        .{ .label = b.signature, .documentation = b.doc },
                    },
                    .activeSignature = 0,
                    .activeParameter = 0,
                });
                return;
            }
        }
        try self.reply(id, null);
    }

    fn handlePrepareRename(self: *Server, id: ?std.json.Value, params: std.json.Value) !void {
        const uri = params.object.get("textDocument").?.object.get("uri").?.string;
        const pos = positionOf(params);
        const text = self.documents.get(uri) orelse {
            try self.reply(id, null);
            return;
        };
        if (findSymbolAt(text, pos.line, pos.character)) |sym| {
            if (lookupBuiltin(sym) != null) {
                try self.reply(id, null);
                return;
            }
            const range = symbolRangeAt(text, pos.line, pos.character, sym) orelse {
                try self.reply(id, null);
                return;
            };
            try self.reply(id, .{
                .range = range,
                .placeholder = sym,
            });
            return;
        }
        try self.reply(id, null);
    }

    fn handleRename(self: *Server, id: ?std.json.Value, params: std.json.Value) !void {
        const uri = params.object.get("textDocument").?.object.get("uri").?.string;
        const pos = positionOf(params);
        const new_name = params.object.get("newName").?.string;
        const text = self.documents.get(uri) orelse {
            try self.reply(id, null);
            return;
        };
        if (findSymbolAt(text, pos.line, pos.character)) |sym| {
            if (lookupBuiltin(sym) != null) {
                try self.reply(id, null);
                return;
            }
        }

        var result_buf: std.ArrayListUnmanaged(u8) = .{};
        defer result_buf.deinit(self.allocator);
        try result_buf.appendSlice(self.allocator, "{\"changes\":{");

        var file_edits: std.StringArrayHashMapUnmanaged(std.ArrayListUnmanaged(u8)) = .{};
        defer {
            var it = file_edits.iterator();
            while (it.next()) |e| {
                self.allocator.free(e.key_ptr.*);
                e.value_ptr.deinit(self.allocator);
            }
            file_edits.deinit(self.allocator);
        }

        if (try self.runIdeJson(uri, text, "references", pos.line, pos.character)) |raw| {
            defer self.allocator.free(raw);
            if (parseIdeObject(self.allocator, raw)) |obj| {
                defer obj.deinit();
                if (obj.value.object.get("refs")) |arr| {
                    if (arr == .array) {
                        for (arr.array.items) |r| {
                            if (r != .object) continue;
                            const file = jsonString(r, "file") orelse continue;
                            const loc = try locationFromIde(self.allocator, r, file);
                            defer self.allocator.free(loc.uri);

                            const gop = try file_edits.getOrPut(self.allocator, loc.uri);
                            if (!gop.found_existing) {
                                gop.key_ptr.* = try self.allocator.dupe(u8, loc.uri);
                                gop.value_ptr.* = .{};
                            }
                            var list = gop.value_ptr;
                            if (list.items.len > 0) try list.append(self.allocator, ',');
                            try list.appendSlice(self.allocator, "{\"range\":");
                            try appendRangeJson(list, self.allocator, loc.range);
                            try list.appendSlice(self.allocator, ",\"newText\":");
                            try std.json.stringify(new_name, .{}, list.writer(self.allocator));
                            try list.append(self.allocator, '}');
                        }
                    }
                }
            }
        }

        var first_file = true;
        var it = file_edits.iterator();
        while (it.next()) |e| {
            if (!first_file) try result_buf.append(self.allocator, ',');
            first_file = false;
            try std.json.stringify(e.key_ptr.*, .{}, result_buf.writer(self.allocator));
            try result_buf.appendSlice(self.allocator, ":[");
            try result_buf.appendSlice(self.allocator, e.value_ptr.items);
            try result_buf.append(self.allocator, ']');
        }
        try result_buf.appendSlice(self.allocator, "}}");
        try self.replyRawResult(id, result_buf.items);
    }

    fn handleWorkspaceSymbol(self: *Server, id: ?std.json.Value, params: std.json.Value) !void {
        const query = if (params.object.get("query")) |q| (if (q == .string) q.string else "") else "";

        var result_buf: std.ArrayListUnmanaged(u8) = .{};
        defer result_buf.deinit(self.allocator);
        try result_buf.append(self.allocator, '[');
        var first = true;
        var seen: std.StringHashMapUnmanaged(void) = .{};
        defer seen.deinit(self.allocator);

        // Try every open buffer whose path is still writable (skip deleted smoke temps).
        var doc_it = self.documents.iterator();
        while (doc_it.next()) |e| {
            const uri = e.key_ptr.*;
            const text = e.value_ptr.*;
            const path = try uriToPath(self.allocator, uri);
            defer self.allocator.free(path);
            const dir = std.fs.path.dirname(path) orelse continue;
            std.fs.cwd().access(dir, .{}) catch continue;

            if (try self.runIdeRaw(uri, text, "symbols", 1, 1)) |raw| {
                defer self.allocator.free(raw);
                var lines = std.mem.splitScalar(u8, raw, '\n');
                while (lines.next()) |line| {
                    if (line.len == 0) continue;
                    const obj = std.json.parseFromSlice(std.json.Value, self.allocator, line, .{}) catch continue;
                    defer obj.deinit();
                    if (obj.value != .object) continue;
                    const name = jsonString(obj.value, "name") orelse continue;
                    if (query.len > 0 and std.mem.indexOf(u8, name, query) == null) continue;
                    const file = jsonString(obj.value, "file") orelse continue;
                    const key = try std.fmt.allocPrint(self.allocator, "{s}\x00{s}:{d}", .{ file, name, jsonInt(obj.value, "line", 1) });
                    defer self.allocator.free(key);
                    if (seen.contains(key)) continue;
                    try seen.put(self.allocator, try self.allocator.dupe(u8, key), {});
                    const kind_s = jsonString(obj.value, "kind") orelse "function";
                    const loc = try locationFromIde(self.allocator, obj.value, file);
                    defer self.allocator.free(loc.uri);
                    if (!first) try result_buf.append(self.allocator, ',');
                    first = false;
                    try result_buf.appendSlice(self.allocator, "{\"name\":");
                    try std.json.stringify(name, .{}, result_buf.writer(self.allocator));
                    try result_buf.writer(self.allocator).print(",\"kind\":{d},\"location\":", .{ideKindToSymbol(kind_s)});
                    try appendLocationJson(&result_buf, self.allocator, loc);
                    try result_buf.append(self.allocator, '}');
                }
            }
        }

        // Free seen keys.
        var sit = seen.iterator();
        while (sit.next()) |e| self.allocator.free(e.key_ptr.*);

        try result_buf.append(self.allocator, ']');
        try self.replyRawResult(id, result_buf.items);
    }

    fn handleDocumentSymbol(self: *Server, id: ?std.json.Value, params: std.json.Value) !void {
        const uri = params.object.get("textDocument").?.object.get("uri").?.string;
        const text = self.documents.get(uri) orelse {
            try self.replyRawResult(id, "[]");
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
            const name = jsonString(obj.value, "name") orelse continue;
            const kind_s = jsonString(obj.value, "kind") orelse "function";
            const line_n = jsonInt(obj.value, "line", 1);
            const col_n = jsonInt(obj.value, "column", 1);
            const end_line = jsonInt(obj.value, "end_line", line_n);
            const end_col = jsonInt(obj.value, "end_column", col_n + @as(i64, @intCast(name.len)));
            const kind = ideKindToSymbol(kind_s);
            const zl: i64 = if (line_n > 0) line_n - 1 else 0;
            const zc: i64 = if (col_n > 0) col_n - 1 else 0;
            const zel: i64 = if (end_line > 0) end_line - 1 else zl;
            const zec: i64 = if (end_col > 0) end_col - 1 else zc + @as(i64, @intCast(name.len));
            if (!first) try result_buf.append(self.allocator, ',');
            first = false;
            try result_buf.appendSlice(self.allocator, "{\"name\":");
            try std.json.stringify(name, .{}, result_buf.writer(self.allocator));
            try result_buf.writer(self.allocator).print(
                ",\"kind\":{d},\"range\":{{\"start\":{{\"line\":{d},\"character\":{d}}},\"end\":{{\"line\":{d},\"character\":{d}}}}},\"selectionRange\":{{\"start\":{{\"line\":{d},\"character\":{d}}},\"end\":{{\"line\":{d},\"character\":{d}}}}}",
                .{ kind, zl, zc, zel, zec, zl, zc, zel, zec },
            );
            try result_buf.append(self.allocator, '}');
        }
        try result_buf.append(self.allocator, ']');
        try self.replyRawResult(id, result_buf.items);
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

    /// Run `jog ide <mode> …` against a `.jog-lsp-tmp` buffer. Returns owned stdout (trimmed).
    fn runIdeJson(self: *Server, uri: []const u8, text: []const u8, mode: []const u8, zero_line: u32, zero_character: u32) !?[]u8 {
        return self.runIdeRaw(uri, text, mode, zero_line + 1, zero_character + 1);
    }

    fn runIdeRaw(self: *Server, uri: []const u8, text: []const u8, mode: []const u8, one_line: u32, one_column: u32) !?[]u8 {
        const path = try uriToPath(self.allocator, uri);
        defer self.allocator.free(path);
        const tmp_path = try std.fmt.allocPrint(self.allocator, "{s}.jog-lsp-tmp", .{path});
        defer self.allocator.free(tmp_path);
        {
            const f = std.fs.cwd().createFile(tmp_path, .{}) catch return null;
            defer f.close();
            f.writeAll(text) catch return null;
        }
        defer std.fs.cwd().deleteFile(tmp_path) catch {};

        var argv: std.ArrayListUnmanaged([]const u8) = .{};
        defer argv.deinit(self.allocator);
        try argv.append(self.allocator, self.jog);
        try argv.append(self.allocator, "ide");
        try argv.append(self.allocator, mode);
        const line_s = try std.fmt.allocPrint(self.allocator, "{d}", .{one_line});
        defer self.allocator.free(line_s);
        const col_s = try std.fmt.allocPrint(self.allocator, "{d}", .{one_column});
        defer self.allocator.free(col_s);
        try argv.append(self.allocator, "--line");
        try argv.append(self.allocator, line_s);
        try argv.append(self.allocator, "--column");
        try argv.append(self.allocator, col_s);
        if (std.mem.endsWith(u8, path, ".test.jog")) {
            try argv.append(self.allocator, "--test");
        }
        var flag_storage: std.ArrayListUnmanaged([]u8) = .{};
        defer {
            for (flag_storage.items) |s| self.allocator.free(s);
            flag_storage.deinit(self.allocator);
        }
        if (try moduleRootOf(self.allocator, path)) |mod_root| {
            defer self.allocator.free(mod_root);
            if (try fetchModuleFlags(self.allocator, self.jog, mod_root, std.mem.endsWith(u8, path, ".test.jog"))) |flags| {
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
        child.stderr_behavior = .Ignore;
        child.spawn() catch return null;
        const out = child.stdout.?.readToEndAlloc(self.allocator, 4 * 1024 * 1024) catch {
            _ = child.wait() catch {};
            return null;
        };
        _ = child.wait() catch {};
        const trimmed = std.mem.trim(u8, out, " \t\r\n");
        if (trimmed.len == 0) {
            self.allocator.free(out);
            return null;
        }
        // Return owned slice of full buffer (caller frees). Keep original alloc.
        return out;
    }

    fn publishDiags(self: *Server, uri: []const u8) !void {
        const text = self.documents.get(uri) orelse return;
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

        var argv: std.ArrayListUnmanaged([]const u8) = .{};
        defer argv.deinit(self.allocator);
        try argv.append(self.allocator, self.jog);
        try argv.append(self.allocator, "check");
        try argv.append(self.allocator, "--diag=json");
        if (std.mem.endsWith(u8, path, ".test.jog")) {
            try argv.append(self.allocator, "--test");
        }
        var flag_storage: std.ArrayListUnmanaged([]u8) = .{};
        defer {
            for (flag_storage.items) |s| self.allocator.free(s);
            flag_storage.deinit(self.allocator);
        }
        if (try moduleRootOf(self.allocator, path)) |mod_root| {
            defer self.allocator.free(mod_root);
            if (try fetchModuleFlags(self.allocator, self.jog, mod_root, std.mem.endsWith(u8, path, ".test.jog"))) |flags| {
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
            const msg = jsonString(obj.value, "message") orelse "error";
            const sev_s = jsonString(obj.value, "severity") orelse "error";
            const line_n = jsonInt(obj.value, "line", 1);
            const col_n = jsonInt(obj.value, "column", 1);
            const end_line_n = jsonInt(obj.value, "end_line", 0);
            const end_col_n = jsonInt(obj.value, "end_column", 0);
            const zero_line: u32 = @intCast(if (line_n > 0) line_n - 1 else 0);
            const zero_col: u32 = @intCast(if (col_n > 0) col_n - 1 else 0);
            const zero_end_line: u32 = if (end_line_n > 0) @intCast(end_line_n - 1) else zero_line;
            const zero_end_col: u32 = if (end_col_n > 0) @intCast(end_col_n - 1) else zero_col + 1;
            try diags.append(self.allocator, .{
                .message = try self.allocator.dupe(u8, msg),
                .line = zero_line,
                .character = zero_col,
                .end_line = zero_end_line,
                .end_character = zero_end_col,
                .severity = severityToLsp(sev_s),
            });
        }
        if (diags.items.len == 0 and err.len > 0) {
            try diags.append(self.allocator, .{
                .message = try self.allocator.dupe(u8, std.mem.trim(u8, err, " \n\r\t")),
                .line = 0,
                .character = 0,
                .end_line = 0,
                .end_character = 1,
                .severity = 1,
            });
        }

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
                try params_buf.writer(self.allocator).print(
                    "{{\"severity\":{d},\"message\":",
                    .{d.severity},
                );
                try std.json.stringify(d.message, .{}, params_buf.writer(self.allocator));
                try params_buf.writer(self.allocator).print(
                    ",\"range\":{{\"start\":{{\"line\":{d},\"character\":{d}}},\"end\":{{\"line\":{d},\"character\":{d}}}}}",
                    .{ d.line, d.character, d.end_line, d.end_character },
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

    fn replyRawResult(self: *Server, id: ?std.json.Value, result_json: []const u8) !void {
        var msg: std.ArrayListUnmanaged(u8) = .{};
        defer msg.deinit(self.allocator);
        try msg.appendSlice(self.allocator, "{\"jsonrpc\":\"2.0\",\"result\":");
        try msg.appendSlice(self.allocator, result_json);
        try msg.appendSlice(self.allocator, ",\"id\":");
        if (id) |i| {
            try std.json.stringify(i, .{}, msg.writer(self.allocator));
        } else {
            try msg.appendSlice(self.allocator, "null");
        }
        try msg.append(self.allocator, '}');
        try self.writeRaw(msg.items);
    }

    fn writeRaw(self: *Server, body: []const u8) !void {
        var header_buf: [64]u8 = undefined;
        const header = try std.fmt.bufPrint(&header_buf, "Content-Length: {d}\r\n\r\n", .{body.len});
        try self.stdout.writeAll(header);
        try self.stdout.writeAll(body);
    }
};

fn pollReadable(fd: std.posix.fd_t, timeout_ms: i32) !bool {
    var pfd = [_]std.posix.pollfd{.{
        .fd = fd,
        .events = std.posix.POLL.IN,
        .revents = 0,
    }};
    const n = std.posix.poll(&pfd, timeout_ms) catch return true;
    return n > 0 and (pfd[0].revents & std.posix.POLL.IN) != 0;
}

const Diag = struct {
    message: []u8,
    line: u32,
    character: u32,
    end_line: u32,
    end_character: u32,
    severity: u8,
};

const CompletionItem = struct {
    label: []const u8,
    kind: u8,
    detail: []const u8,
    documentation: []const u8,
    owned: bool = false,
};

const LspRange = struct {
    start: struct { line: u32, character: u32 },
    end: struct { line: u32, character: u32 },
};

const LspLocation = struct {
    uri: []u8,
    range: LspRange,
};

const BuiltinKind = enum { fn_builtin, type_builtin, keyword };

const Builtin = struct {
    name: []const u8,
    kind: BuiltinKind,
    signature: []const u8,
    doc: []const u8,

    fn completionKind(self: Builtin) u8 {
        return switch (self.kind) {
            .fn_builtin => 3,
            .type_builtin => 25,
            .keyword => 14,
        };
    }
};

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

fn severityToLsp(s: []const u8) u8 {
    if (std.mem.eql(u8, s, "error")) return 1;
    if (std.mem.eql(u8, s, "warning")) return 2;
    if (std.mem.eql(u8, s, "info")) return 3;
    if (std.mem.eql(u8, s, "hint")) return 4;
    return 1;
}

fn ideKindToCompletion(kind: []const u8) u8 {
    if (std.mem.eql(u8, kind, "function")) return 3;
    if (std.mem.eql(u8, kind, "method")) return 2;
    if (std.mem.eql(u8, kind, "field")) return 5;
    if (std.mem.eql(u8, kind, "variable")) return 6;
    if (std.mem.eql(u8, kind, "constant")) return 21;
    if (std.mem.eql(u8, kind, "struct") or std.mem.eql(u8, kind, "object")) return 22;
    if (std.mem.eql(u8, kind, "enum")) return 13;
    if (std.mem.eql(u8, kind, "interface") or std.mem.eql(u8, kind, "type")) return 25;
    return 6;
}

fn ideKindToSymbol(kind: []const u8) u8 {
    if (std.mem.eql(u8, kind, "function") or std.mem.eql(u8, kind, "method")) return 12;
    if (std.mem.eql(u8, kind, "struct") or std.mem.eql(u8, kind, "object")) return 23;
    if (std.mem.eql(u8, kind, "enum")) return 10;
    if (std.mem.eql(u8, kind, "interface")) return 11;
    if (std.mem.eql(u8, kind, "constant")) return 14;
    if (std.mem.eql(u8, kind, "type")) return 26;
    if (std.mem.eql(u8, kind, "field")) return 8;
    return 13;
}

fn parseIdeObject(allocator: std.mem.Allocator, raw: []const u8) ?std.json.Parsed(std.json.Value) {
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    // First JSON object line.
    const line = blk: {
        if (std.mem.indexOfScalar(u8, trimmed, '\n')) |nl| break :blk trimmed[0..nl];
        break :blk trimmed;
    };
    return std.json.parseFromSlice(std.json.Value, allocator, line, .{}) catch null;
}

fn jsonBool(v: std.json.Value, key: []const u8) bool {
    if (v != .object) return false;
    const x = v.object.get(key) orelse return false;
    return switch (x) {
        .bool => |b| b,
        else => false,
    };
}

fn jsonString(v: std.json.Value, key: []const u8) ?[]const u8 {
    if (v != .object) return null;
    const x = v.object.get(key) orelse return null;
    return if (x == .string) x.string else null;
}

fn jsonInt(v: std.json.Value, key: []const u8, default: i64) i64 {
    if (v != .object) return default;
    const x = v.object.get(key) orelse return default;
    return switch (x) {
        .integer => |n| n,
        else => default,
    };
}

fn locationFromIde(allocator: std.mem.Allocator, v: std.json.Value, file: []const u8) !LspLocation {
    const line_n = jsonInt(v, "line", 1);
    const col_n = jsonInt(v, "column", 1);
    const end_line_n = jsonInt(v, "end_line", line_n);
    const end_col_n = jsonInt(v, "end_column", col_n + 1);
    const uri = try pathToFileUri(allocator, file);
    return .{
        .uri = uri,
        .range = .{
            .start = .{
                .line = @intCast(if (line_n > 0) line_n - 1 else 0),
                .character = @intCast(if (col_n > 0) col_n - 1 else 0),
            },
            .end = .{
                .line = @intCast(if (end_line_n > 0) end_line_n - 1 else 0),
                .character = @intCast(if (end_col_n > 0) end_col_n - 1 else 0),
            },
        },
    };
}

fn appendRangeJson(buf: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, range: LspRange) !void {
    try buf.writer(allocator).print(
        "{{\"start\":{{\"line\":{d},\"character\":{d}}},\"end\":{{\"line\":{d},\"character\":{d}}}}}",
        .{ range.start.line, range.start.character, range.end.line, range.end.character },
    );
}

fn appendLocationJson(buf: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, loc: LspLocation) !void {
    try buf.appendSlice(allocator, "{\"uri\":");
    try std.json.stringify(loc.uri, .{}, buf.writer(allocator));
    try buf.appendSlice(allocator, ",\"range\":");
    try appendRangeJson(buf, allocator, loc.range);
    try buf.append(allocator, '}');
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

fn symbolRangeAt(text: []const u8, line: u32, character: u32, sym: []const u8) ?LspRange {
    _ = sym;
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
            return .{
                .start = .{ .line = line, .character = @intCast(start) },
                .end = .{ .line = line, .character = @intCast(end) },
            };
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

fn textEndsWithDotContext(text: []const u8, line: u32, character: u32) bool {
    var line_i: u32 = 0;
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        if (line_i == line) {
            const line_start = i;
            while (i < text.len and text[i] != '\n') : (i += 1) {}
            const line_text = text[line_start..i];
            const col: usize = @min(character, line_text.len);
            var pos = col;
            while (pos > 0 and isIdentChar(line_text[pos - 1])) : (pos -= 1) {}
            return pos > 0 and line_text[pos - 1] == '.';
        }
        if (text[i] == '\n') line_i += 1;
    }
    return false;
}

fn findCallNamePosition(text: []const u8, line: u32, character: u32) ?struct { line: u32, character: u32 } {
    var line_i: u32 = 0;
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        if (line_i == line) {
            const line_start = i;
            while (i < text.len and text[i] != '\n') : (i += 1) {}
            const line_text = text[line_start..i];
            const col: usize = @min(character, line_text.len);
            // Walk back to `(`, then to the ident before it.
            var pos = col;
            while (pos > 0 and line_text[pos - 1] != '(') : (pos -= 1) {}
            if (pos == 0 or line_text[pos - 1] != '(') {
                // Maybe sitting on the name before `(` — use symbol at cursor.
                if (findSymbolAt(text, line, character) != null) {
                    return .{ .line = line, .character = character };
                }
                return null;
            }
            var name_end = pos - 1;
            while (name_end > 0 and (line_text[name_end - 1] == ' ' or line_text[name_end - 1] == '\t')) : (name_end -= 1) {}
            var name_start = name_end;
            while (name_start > 0 and isIdentChar(line_text[name_start - 1])) : (name_start -= 1) {}
            if (name_start >= name_end) return null;
            return .{ .line = line, .character = @intCast(name_start) };
        }
        if (text[i] == '\n') line_i += 1;
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

fn pathToFileUri(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const abs = std.fs.cwd().realpathAlloc(allocator, path) catch try allocator.dupe(u8, path);
    defer allocator.free(abs);
    return try std.fmt.allocPrint(allocator, "file://{s}", .{abs});
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
    const rels = [_][]const u8{
        "JogCompiler-v2/zig-out/bin/jog",
        "jogcompiler/zig-out/bin/jog",
    };
    for (rels) |rel| {
        const cwd_cand = try std.fs.path.join(allocator, &.{ "..", rel });
        defer allocator.free(cwd_cand);
        if (fileExists(cwd_cand)) {
            if (try isV2Jog(allocator, cwd_cand)) return try allocator.dupe(u8, cwd_cand);
        }
    }

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const exe = std.fs.selfExePath(&buf) catch return null;
    const exe_dir = std.fs.path.dirname(exe) orelse return null;
    for (rels) |rel| {
        const from_bin = try std.fs.path.join(allocator, &.{ exe_dir, "../../..", rel });
        defer allocator.free(from_bin);
        if (fileExists(from_bin)) {
            if (try isV2Jog(allocator, from_bin)) return try allocator.dupe(u8, from_bin);
        }
        const from_ext = try std.fs.path.join(allocator, &.{ exe_dir, "../..", rel });
        defer allocator.free(from_ext);
        if (fileExists(from_ext)) {
            if (try isV2Jog(allocator, from_ext)) return try allocator.dupe(u8, from_ext);
        }
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
