// SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

//! Differential fuzzing across every engine.
//!
//! The engines are independent implementations of one specification, which
//! makes them checkable against each other: for any pattern and any input
//! they must report the same matches and the same captures. This generates
//! both, runs each engine that can handle the pattern, and compares.
//!
//! Patterns are built from a grammar rather than from raw bytes, so the
//! fuzzer spends its time on the engines instead of on the parser rejecting
//! noise, and both are drawn from deliberately tiny, overlapping alphabets
//! so that matches, backtracking, and ambiguity actually happen. Those
//! alphabets include multi-byte codepoints and bytes that are not valid
//! UTF-8, which is what reaches the decoder's fallback, the helper paths the
//! JIT takes for non-ASCII, and the lead-byte handling in the prefilter.
//!
//! The generator is driven through `Source`, which reads its decisions either
//! from the fuzzer's `Smith` or from a seeded PRNG. Both are wired up: `zig
//! build test` runs thousands of seeded cases every time, and `zig build test
//! --fuzz` hands the same generator to the coverage-guided fuzzer.
//!
//! The seeded path is not a stand-in that happens to be convenient — as of
//! Zig 0.16.0 it is the only one that works. The compiler's own test runner
//! fails to build in fuzz mode (`expected type '*const debug.StackTrace',
//! found '*builtin.StackTrace'` in compiler/test_runner.zig), which a
//! two-line fuzz test reproduces with no zregex involved. When that is fixed
//! upstream the `--fuzz` test starts working with no changes here.
const std = @import("std");
const zregex = @import("root.zig");
const Regex = zregex.Regex;
const Span = zregex.Span;
const gen = @import("pattern_gen");
const Source = gen.Source;
const Builder = gen.Builder;
const chunks = gen.chunks;

/// Haystacks are built from these pieces rather than single bytes, so that
/// multi-byte codepoints stay intact while the decoder's fallback still gets
/// exercised: a lone 0xFF is not valid UTF-8 and must be treated as a
/// one-byte codepoint of its own value, and a stray continuation byte or a
/// truncated lead byte reaches the same path from the other side. Small and
/// overlapping on purpose — that is what produces interesting backtracking.
/// One engine configuration to compare. Not every one applies to every
/// pattern: the Pike VM and the lazy DFA cannot run backreferences or
/// lookaround, and the JIT is only present where it could be generated.
const Config = struct {
    name: []const u8,
    apply: *const fn (*Regex) void,
    /// Whether this configuration can run a pattern needing the backtracker.
    handles_backtrack_only: bool,
};

const configs = [_]Config{
    .{
        .name = "jit",
        .handles_backtrack_only = true,
        .apply = struct {
            fn f(re: *Regex) void {
                re.jit_mode = .on;
            }
        }.f,
    },
    .{
        .name = "dfa",
        .handles_backtrack_only = false,
        .apply = struct {
            fn f(re: *Regex) void {
                re.jit_mode = .off;
                re.dfa_mode = .on;
            }
        }.f,
    },
    .{
        .name = "pike",
        .handles_backtrack_only = false,
        .apply = struct {
            fn f(re: *Regex) void {
                re.jit_mode = .off;
                re.dfa_mode = .off;
            }
        }.f,
    },
    .{
        .name = "backtrack",
        .handles_backtrack_only = true,
        .apply = struct {
            fn f(re: *Regex) void {
                re.jit_mode = .off;
                // Sound for any program: the backtracker implements every
                // instruction, including the ones the Pike VM cannot.
                re.fallback_engine = .backtrack;
                re.memo = true;
            }
        }.f,
    },
    .{
        .name = "backtrack-nomemo",
        .handles_backtrack_only = true,
        .apply = struct {
            fn f(re: *Regex) void {
                re.jit_mode = .off;
                re.fallback_engine = .backtrack;
                re.memo = false;
            }
        }.f,
    },
};

/// Properties that must hold of any result, whatever engine produced it and
/// whether or not the engines agree with each other. Cross-checking finds
/// disagreements; this finds the things they could get wrong together.
fn checkInvariants(
    re: *const Regex,
    haystack: []const u8,
    m: zregex.Match,
    prev_end: ?usize,
) !void {
    const span = m.span();
    try std.testing.expect(span.start <= span.end);
    try std.testing.expect(span.end <= haystack.len);
    // Group 0 is the match and always participates.
    try std.testing.expect(m.groups[0] != null);
    try std.testing.expectEqual(re.group_count, m.groups.len);
    for (m.groups) |g| {
        // A capture may sit outside the match — a lookahead can record one
        // past the end — but never outside the haystack.
        if (g) |sp| {
            try std.testing.expect(sp.start <= sp.end);
            try std.testing.expect(sp.end <= haystack.len);
        }
    }
    // Iteration moves forward and never returns overlapping matches.
    if (prev_end) |pe| try std.testing.expect(span.start >= pe);
}

/// Every match in `haystack`, flattened to spans so the results of two
/// configurations can be compared directly.
///
fn collect(
    gpa: std.mem.Allocator,
    re: *const Regex,
    haystack: []const u8,
    out: *std.ArrayList(?Span),
) !void {
    var it = re.iterator(gpa, haystack);
    defer it.deinit();
    var count: usize = 0;
    var prev_end: ?usize = null;
    while (try it.next()) |m| {
        var mm = m;
        defer mm.deinit(gpa);
        try checkInvariants(re, haystack, mm, prev_end);
        prev_end = mm.span().end;
        try out.appendSlice(gpa, mm.groups);
        count += 1;
        // A pathological pattern should not turn one fuzz case into a hang;
        // agreement over the first matches is just as strong a signal.
        if (count >= 64) break;
    }
}

/// Generate one pattern and one haystack, run every applicable engine, and
/// require them to report the same matches and captures.
fn oneCase(src: Source) anyerror!void {
    const gpa = std.testing.allocator;

    var b = Builder{ .src = src, .gpa = gpa };
    // Every so often, build something far bigger than the default: deep
    // nesting, a long program, and enough capture groups to run past what a
    // small pattern ever allocates.
    if (src.index(8) == 0) {
        b.depth_limit = 7;
        b.length_limit = 400;
        b.group_limit = 40;
    }
    defer b.buf.deinit(gpa);
    try b.sequence(0);
    if (b.buf.items.len == 0) return;
    const pattern = b.buf.items;

    var re = Regex.compile(gpa, pattern) catch return; // invalid is fine
    defer re.deinit();
    // Keep a runaway pattern from stalling the fuzzer; a configuration that
    // gives up is skipped rather than compared.
    re.max_steps = 100_000;

    var hay: std.ArrayList(u8) = .empty;
    defer hay.deinit(gpa);
    // Most haystacks stay short, where a bug is easiest to read back. Some
    // are long, with long runs of one character: nothing shorter than a
    // vector block ever reaches the SIMD scanners, the lead-run skip, or a
    // prefilter search that has to cross real distance.
    if (src.intRange(u8, 0, 3) == 0) {
        const runs = src.intRange(u8, 1, 8);
        for (0..runs) |_| {
            const piece = chunks[src.index(chunks.len)];
            const n = src.intRange(u16, 1, 200);
            for (0..n) |_| try hay.appendSlice(gpa, piece);
            try hay.appendSlice(gpa, chunks[src.index(chunks.len)]);
        }
    } else {
        const hay_len = src.intRange(u8, 0, 24);
        for (0..hay_len) |_| try hay.appendSlice(gpa, chunks[src.index(chunks.len)]);
    }

    const needs_backtrack = re.fallback_engine == .backtrack;

    var reference: std.ArrayList(?Span) = .empty;
    defer reference.deinit(gpa);
    var reference_name: []const u8 = "";

    var actual: std.ArrayList(?Span) = .empty;
    defer actual.deinit(gpa);

    // A few offsets to search from, the same ones for every configuration.
    var starts: [4]usize = undefined;
    var start_count: usize = 0;
    if (hay.items.len != 0) {
        while (start_count < starts.len) : (start_count += 1) {
            starts[start_count] = src.index(hay.items.len + 1);
        }
    }

    configs: for (configs) |cfg| {
        if (needs_backtrack and !cfg.handles_backtrack_only) continue;
        if (std.mem.eql(u8, cfg.name, "jit") and re.jit_code == null) continue;

        var probe = re;
        cfg.apply(&probe);
        actual.clearRetainingCapacity();
        collect(gpa, &probe, hay.items, &actual) catch |err| switch (err) {
            error.StepLimitExceeded => continue :configs,
            else => return err,
        };

        // Searching from an offset is its own path: assertions and lookbehind
        // have to see the text before the start, which `find` never exercises.
        for (starts[0..start_count]) |st| {
            if (st > hay.items.len) continue;
            // Giving up part way would leave this configuration with fewer
            // results than the reference and read as a disagreement, so a
            // configuration that runs out of budget is dropped whole.
            const m = probe.findAt(gpa, hay.items, st) catch |err| switch (err) {
                error.StepLimitExceeded => continue :configs,
                else => return err,
            };
            if (m) |mm| {
                var owned = mm;
                defer owned.deinit(gpa);
                try actual.append(gpa, owned.span());
            } else {
                try actual.append(gpa, null);
            }
        }

        if (reference_name.len == 0) {
            reference_name = cfg.name;
            reference.clearRetainingCapacity();
            try reference.appendSlice(gpa, actual.items);
            continue;
        }
        std.testing.expectEqualSlices(?Span, reference.items, actual.items) catch |err| {
            std.debug.print(
                "pattern={s}\nhaystack={f}\n{s} and {s} disagree\n",
                .{ pattern, std.zig.fmtString(hay.items), reference_name, cfg.name },
            );
            return err;
        };
    }
}

fn testOne(_: void, smith: *std.testing.Smith) anyerror!void {
    return oneCase(.{ .smith = smith });
}

test "engines agree under fuzzing" {
    try std.testing.fuzz({}, testOne, .{});
}

/// `isMatch` and `find` must never disagree about whether there is a match.
fn checkIsMatch(gpa: std.mem.Allocator, re: *const Regex, haystack: []const u8) !void {
    const found = re.find(gpa, haystack) catch |err| switch (err) {
        error.StepLimitExceeded => return,
        else => return err,
    };
    const yes = re.isMatch(gpa, haystack) catch |err| switch (err) {
        error.StepLimitExceeded => return,
        else => return err,
    };
    if (found) |m| {
        var mm = m;
        mm.deinit(gpa);
    }
    try std.testing.expectEqual(found != null, yes);
}

test "arbitrary bytes never crash the parser or the engines" {
    const gpa = std.testing.allocator;
    var prng = std.Random.DefaultPrng.init(0x50a7_7e12);
    const rand = prng.random();
    var pattern: [24]u8 = undefined;
    var hay: [16]u8 = undefined;
    // Mostly syntax characters, so that random input has a real chance of
    // parsing and reaching the engines rather than being rejected at once.
    const soup = "ab01()[]{}|*+?.^$\\-,:<>=!  \u{e9}";
    for (0..20000) |_| {
        const plen = rand.uintLessThan(usize, pattern.len);
        for (pattern[0..plen]) |*c| c.* = soup[rand.uintLessThan(usize, soup.len)];
        var re = Regex.compile(gpa, pattern[0..plen]) catch continue;
        defer re.deinit();
        re.max_steps = 10_000;
        const hlen = rand.uintLessThan(usize, hay.len);
        for (hay[0..hlen]) |*c| c.* = soup[rand.uintLessThan(usize, soup.len)];
        try checkIsMatch(gpa, &re, hay[0..hlen]);
    }
}

test "engines agree on randomized patterns" {
    // Fixed seed so a failure is reproducible and CI is deterministic. Raise
    // the count when changing an engine; this is the cheap standing check.
    var prng = std.Random.DefaultPrng.init(0x2026_08_31);
    for (0..3000) |_| try oneCase(.{ .random = prng.random() });
}
