// SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

//! Serves the generated API documentation over HTTP, the way `zig std` serves
//! the standard library's.
//!
//! A server is needed rather than just opening `index.html`, because the
//! viewer fetches `sources.tar` and `main.wasm` at runtime and a browser
//! refuses those requests from a `file://` page.
//!
//! Run through the build system: `zig build docs-serve`. It is deliberately
//! minimal, serving one directory to one person on the loopback interface.
//!
//! Every connection gets its own thread, which is not a throughput concern but
//! a correctness one: a browser opens several connections at once and holds
//! some of them open without sending anything, so a server that reads them one
//! at a time blocks on a speculative connection and never answers the real
//! requests.
//!
//! A thread each, rather than a pool: a connection handler blocks until its
//! client goes away, which can be minutes, and a pool sized for short tasks
//! wedges once every worker is parked on an idle socket. A browser opens a
//! handful of connections, so the thread count stays small in practice.

const std = @import("std");
const Io = std.Io;

/// Nothing in a documentation bundle comes close to this; it exists so that a
/// stray huge file cannot exhaust memory.
const max_file_size = 64 * 1024 * 1024;

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());

    var stderr_buffer: [512]u8 = undefined;
    var stderr_writer: Io.File.Writer = .init(.stderr(), io, &stderr_buffer);
    const stderr = &stderr_writer.interface;

    if (args.len != 3) {
        try stderr.writeAll("usage: docs-server <directory> <port>\n");
        try stderr.flush();
        std.process.exit(2);
    }
    const docs_path = args[1];
    const port = try std.fmt.parseInt(u16, args[2], 10);

    var docs_dir = Io.Dir.cwd().openDir(io, docs_path, .{}) catch |err| {
        try stderr.print("cannot open {s}: {s}\n", .{ docs_path, @errorName(err) });
        try stderr.flush();
        std.process.exit(1);
    };
    defer docs_dir.close(io);

    const address: Io.net.IpAddress = .{ .ip4 = .{ .bytes = .{ 127, 0, 0, 1 }, .port = port } };
    var server = address.listen(io, .{ .reuse_address = true }) catch |err| {
        try stderr.print("cannot listen on 127.0.0.1:{d}: {s}\n", .{ port, @errorName(err) });
        if (err == error.AddressInUse) {
            try stderr.writeAll("another port can be chosen with -Ddocs-port=N\n");
        }
        try stderr.flush();
        std.process.exit(1);
    };
    defer server.deinit(io);

    try stderr.print("serving {s} at http://127.0.0.1:{d}/\npress ctrl-c to stop\n", .{ docs_path, port });
    try stderr.flush();

    while (true) {
        const stream = server.accept(io) catch |err| switch (err) {
            // One client giving up is not a reason to stop serving.
            error.ConnectionAborted, error.WouldBlock, error.ProtocolFailure => continue,
            else => return err,
        };

        const thread = std.Thread.spawn(.{}, handleConnection, .{ io, gpa, docs_dir, stream }) catch {
            // Out of threads. Serving it here blocks the ones behind it, but
            // dropping it silently would look like the same hang from the
            // browser's side with none of the progress.
            handleConnection(io, gpa, docs_dir, stream);
            continue;
        };
        // Nothing joins these: each ends when its client disconnects, and the
        // process runs until interrupted.
        thread.detach();
    }
}

/// Serves one connection until the client goes away, then closes it.
fn handleConnection(io: Io, gpa: std.mem.Allocator, docs_dir: Io.Dir, stream: Io.net.Stream) void {
    defer stream.close(io);

    var recv_buffer: [16 * 1024]u8 = undefined;
    var send_buffer: [64 * 1024]u8 = undefined;
    var stream_reader = stream.reader(io, &recv_buffer);
    var stream_writer = stream.writer(io, &send_buffer);
    var http_server: std.http.Server = .init(&stream_reader.interface, &stream_writer.interface);

    // Keep answering on the same connection, so that one page load does not
    // need a connection per file.
    while (true) {
        var request = http_server.receiveHead() catch return;
        serve(&request, io, gpa, docs_dir) catch return;
        // A client that asked to close is waiting for exactly that; waiting
        // for another request it will never send would hang it until it times
        // out.
        if (!request.head.keep_alive) return;
    }
}

fn serve(
    request: *std.http.Server.Request,
    io: Io,
    gpa: std.mem.Allocator,
    docs_dir: Io.Dir,
) !void {
    const target = request.head.target;
    const path_end = std.mem.indexOfAny(u8, target, "?#") orelse target.len;
    var path = target[0..path_end];
    if (std.mem.startsWith(u8, path, "/")) path = path[1..];
    if (path.len == 0) path = "index.html";

    // The documentation directory is the whole world this server knows about.
    if (std.mem.indexOf(u8, path, "..") != null or std.fs.path.isAbsolute(path)) {
        return request.respond("bad request\n", .{ .status = .bad_request });
    }

    const content = docs_dir.readFileAlloc(io, path, gpa, .limited(max_file_size)) catch {
        return request.respond("not found\n", .{ .status = .not_found });
    };
    defer gpa.free(content);

    try request.respond(content, .{
        .extra_headers = &.{.{ .name = "content-type", .value = mimeType(path) }},
    });
}

/// Enough of a MIME table for what `zig build docs` emits.
fn mimeType(path: []const u8) []const u8 {
    const extension = std.fs.path.extension(path);
    const table = [_]struct { []const u8, []const u8 }{
        .{ ".html", "text/html; charset=utf-8" },
        .{ ".js", "text/javascript; charset=utf-8" },
        .{ ".css", "text/css; charset=utf-8" },
        .{ ".wasm", "application/wasm" },
        .{ ".tar", "application/x-tar" },
        .{ ".json", "application/json" },
        .{ ".svg", "image/svg+xml" },
    };
    for (table) |entry| {
        if (std.mem.eql(u8, extension, entry[0])) return entry[1];
    }
    return "application/octet-stream";
}

const testing = std.testing;

test mimeType {
    try testing.expectEqualStrings("text/html; charset=utf-8", mimeType("index.html"));
    try testing.expectEqualStrings("application/wasm", mimeType("main.wasm"));
    try testing.expectEqualStrings("application/x-tar", mimeType("sources.tar"));
    try testing.expectEqualStrings("text/javascript; charset=utf-8", mimeType("main.js"));
    try testing.expectEqualStrings("application/octet-stream", mimeType("noextension"));
}
