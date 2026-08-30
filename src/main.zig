// SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

//! Demo CLI: `zregex <pattern> <text>` prints every match with its captures.
const std = @import("std");
const Io = std.Io;
const zregex = @import("zregex");

pub fn main(init: std.process.Init) !void {
    const arena: std.mem.Allocator = init.arena.allocator();
    const io = init.io;

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_file_writer: Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const out = &stdout_file_writer.interface;

    const args = try init.minimal.args.toSlice(arena);
    if (args.len != 3) {
        std.debug.print("usage: {s} <pattern> <text>\n", .{if (args.len > 0) args[0] else "zregex"});
        std.process.exit(1);
    }
    const pattern = args[1];
    const text = args[2];

    var re = zregex.Regex.compile(arena, pattern) catch |err| {
        std.debug.print("error: invalid pattern: {t}\n", .{err});
        std.process.exit(1);
    };
    defer re.deinit();

    try out.print("engine: {t}\n", .{re.engine});
    var it = re.iterator(arena, text);
    var n: usize = 0;
    while (try it.next()) |m| {
        var match = m;
        defer match.deinit(arena);
        n += 1;
        const sp = match.span();
        try out.print("match {d}: \"{s}\" [{d}..{d}]\n", .{ n, sp.slice(text), sp.start, sp.end });
        for (match.groups[1..], 1..) |g, i| {
            if (g) |span| {
                try out.print("  group {d}: \"{s}\" [{d}..{d}]\n", .{ i, span.slice(text), span.start, span.end });
            } else {
                try out.print("  group {d}: <unset>\n", .{i});
            }
        }
    }
    if (n == 0) try out.print("no match\n", .{});
    try out.flush();
}
