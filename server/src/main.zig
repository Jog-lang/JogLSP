const std = @import("std");

/// Minimal LSP for JogCompiler v2: diagnostics via `jog check --diag=json`.
/// argv[1] or JOG selects the compiler. No in-process jogc frontend.

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
            // response to our request — ignore
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
                },
                .serverInfo = .{ .name = "jog-lsp", .version = "0.2.0-v2" },
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
        const tmp_path = try std.fmt.allocPrint(self.allocator, "{s}.jog-lsp-tmp", .{path});
        defer self.allocator.free(tmp_path);
        {
            const f = try std.fs.cwd().createFile(tmp_path, .{});
            defer f.close();
            try f.writeAll(text);
        }
        defer std.fs.cwd().deleteFile(tmp_path) catch {};

        var child = std.process.Child.init(&.{ self.jog, "check", "--diag=json", tmp_path }, self.allocator);
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

    fn notify(self: *Server, method: []const u8, params: anytype) !void {
        var buf: std.ArrayListUnmanaged(u8) = .{};
        defer buf.deinit(self.allocator);
        try buf.appendSlice(self.allocator, "{\"jsonrpc\":\"2.0\",\"method\":");
        try std.json.stringify(method, .{}, buf.writer(self.allocator));
        try buf.appendSlice(self.allocator, ",\"params\":");
        try std.json.stringify(params, .{}, buf.writer(self.allocator));
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

fn resolveJog(allocator: std.mem.Allocator, arg: ?[]const u8) ![]u8 {
    if (arg) |a| {
        if (a.len > 0) return try allocator.dupe(u8, a);
    }
    if (std.posix.getenv("JOG")) |j| {
        if (j.len > 0) return try allocator.dupe(u8, j);
    }
    if (std.posix.getenv("HOME")) |home| {
        const p = try std.fs.path.join(allocator, &.{ home, ".local/bin/jog-v2" });
        std.fs.cwd().access(p, .{}) catch {
            allocator.free(p);
            std.debug.print("jog-lsp: set JOG or pass jog as argv[1]\n", .{});
            std.process.exit(1);
        };
        return p;
    }
    std.debug.print("jog-lsp: set JOG or pass jog as argv[1]\n", .{});
    std.process.exit(1);
}

fn uriToPath(allocator: std.mem.Allocator, uri: []const u8) ![]u8 {
    const prefix = "file://";
    if (!std.mem.startsWith(u8, uri, prefix)) return try allocator.dupe(u8, uri);
    var path = uri[prefix.len..];
    // file:///home/... → /home/...
    if (path.len >= 2 and path[0] == '/' and path[1] != '/') {
        // already absolute with one slash after file://
    }
    // Decode %XX minimally
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
