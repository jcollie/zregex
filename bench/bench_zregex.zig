// SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

//! Benchmark harness.
//!
//! Usage: `bench-zregex <corpus-file>`, or `bench-zregex --builtin` to
//! generate an equivalent corpus in memory. The built-in one is what CI uses:
//! it needs no Python, and being seeded it is identical on every platform, so
//! numbers from different machines describe the same work.
//!
//! Output protocol (one line per benchmark): impl \t name \t best_ms \t count
const std = @import("std");
const zregex = @import("zregex");
const builtin = @import("builtin");

/// Roughly the size and shape of `bench/gen_corpus.py`'s output: log-like
/// lines of short words, with the occasional date, address, doubled word, and
/// rare marker for the sparse-match benchmarks to find.
fn generateCorpus(gpa: std.mem.Allocator) ![]u8 {
    const target = 4 << 20;
    const words = [_][]const u8{
        "the",      "quick",   "brown",   "fox",     "jumps",   "over",
        "lazy",     "dog",     "server",  "client",  "request", "response",
        "database", "index",   "query",   "buffer",  "cache",   "thread",
        "process",  "socket",  "packet",  "stream",  "channel", "worker",
        "running",  "parsing", "loading", "writing", "reading", "handling",
        "kernel",   "module",  "driver",  "signal",  "inode",   "mount",
        "cluster",  "node",    "region",  "shard",   "replica", "leader",
    };
    const levels = [_][]const u8{ "info", "debug", "warning", "error", "trace" };
    const users = [_][]const u8{ "alice", "bob", "carol", "dave", "erin" };
    const hosts = [_][]const u8{ "example.org", "test.net", "ocjtech.us" };

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var prng = std.Random.DefaultPrng.init(42);
    const rand = prng.random();
    while (out.items.len < target) {
        if (rand.float(f32) < 0.3) {
            try out.print(gpa, "2026-{d:0>2}-{d:0>2} ", .{
                rand.intRangeAtMost(u8, 1, 12),
                rand.intRangeAtMost(u8, 1, 28),
            });
        }
        try out.appendSlice(gpa, levels[rand.uintLessThan(usize, levels.len)]);
        const n = rand.intRangeAtMost(usize, 6, 14);
        for (0..n) |_| {
            try out.append(gpa, ' ');
            const r = rand.float(f32);
            if (r < 0.02) {
                try out.print(gpa, "{s}@{s}", .{
                    users[rand.uintLessThan(usize, users.len)],
                    hosts[rand.uintLessThan(usize, hosts.len)],
                });
            } else if (r < 0.03) {
                const w = words[rand.uintLessThan(usize, words.len)];
                try out.print(gpa, "{s}-{s}", .{ w, w });
            } else {
                try out.appendSlice(gpa, words[rand.uintLessThan(usize, words.len)]);
            }
        }
        if (rand.float(f32) < 0.01) {
            try out.print(gpa, " ERROR operation {s} failed", .{
                words[rand.uintLessThan(usize, words.len)],
            });
        }
        if (rand.float(f32) < 0.002) try out.appendSlice(gpa, " synchronization");
        try out.append(gpa, '\n');
    }
    return out.toOwnedSlice(gpa);
}

const Case = struct {
    name: []const u8,
    pattern: []const u8,
    reps: usize = 5,
    /// If set, run against this haystack instead of the corpus.
    haystack: ?[]const u8 = null,
};

const patho_haystack = "a" ** 22 ++ "!";

const cases = [_]Case{
    .{ .name = "literal", .pattern = "synchronization" },
    .{ .name = "ci_literal", .pattern = "(?i)SYNCHRONIZATION" },
    .{ .name = "date", .pattern = "\\d{4}-\\d{2}-\\d{2}" },
    .{ .name = "email", .pattern = "[\\w.]+@[\\w.]+" },
    .{ .name = "alt", .pattern = "error|warning|fatal|panic" },
    .{ .name = "ing_suffix", .pattern = "[a-z]+ing" },
    .{ .name = "spanning", .pattern = "ERROR.{0,40}failed" },
    .{ .name = "groups", .pattern = "(\\w+)@([\\w.]+)" },
    .{ .name = "lookahead", .pattern = "\\w+(?=@)" },
    .{ .name = "backref", .pattern = "(\\w{3,})-\\1" },
    .{ .name = "pathological", .pattern = "(a+)+$", .reps = 1, .haystack = patho_haystack },
};

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const gpa = std.heap.smp_allocator;
    const io = init.io;

    const args = try init.minimal.args.toSlice(arena);
    if (args.len != 2) {
        std.debug.print("usage: {s} <corpus>|--builtin\n", .{args[0]});
        std.process.exit(1);
    }
    const corpus = if (std.mem.eql(u8, args[1], "--builtin"))
        try generateCorpus(arena)
    else
        try std.Io.Dir.cwd().readFileAlloc(io, args[1], arena, .limited(64 << 20));

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_file_writer: std.Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const out = &stdout_file_writer.interface;

    // Which engine each row picks is the interesting part on a new platform,
    // so say up front whether native code was available at all.
    try out.print("# target={s}-{s} jit_available={} corpus={d} bytes\n", .{
        @tagName(builtin.cpu.arch),
        @tagName(builtin.os.tag),
        zregex.jit_available,
        corpus.len,
    });
    try out.flush();

    for (cases) |case| {
        var re = try zregex.Regex.compile(gpa, case.pattern);
        defer re.deinit();
        const haystack = case.haystack orelse corpus;

        var best_ns: i96 = std.math.maxInt(i96);
        var count: usize = 0;
        for (0..case.reps) |_| {
            const t0 = std.Io.Timestamp.now(io, .awake);
            var c: usize = 0;
            var it = re.iterator(gpa, haystack);
            defer it.deinit();
            while (try it.next()) |m| {
                var mm = m;
                mm.deinit(gpa);
                c += 1;
            }
            const t1 = std.Io.Timestamp.now(io, .awake);
            const ns = t0.durationTo(t1).nanoseconds;
            if (ns < best_ns) best_ns = ns;
            count = c;
        }
        const ms = @as(f64, @floatFromInt(@as(i64, @intCast(best_ns)))) / 1e6;
        try out.print("zregex/{t}\t{s}\t{d:.2}\t{d}\n", .{ re.engine, case.name, ms, count });
        try out.flush();
    }
}
