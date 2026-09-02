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
const fuzz_options = @import("fuzz_options");
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
    /// Run against the copy compiled with AVX2 forced off. The x86-64 JIT has
    /// two vector code generators and picks between them at compile time, so
    /// the one the host CPU does not select is never reached otherwise --
    /// on a machine with AVX2, that is the whole SSE2 path.
    sse2: bool = false,
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
        .name = "jit-sse2",
        .handles_backtrack_only = true,
        .sse2 = true,
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

/// Whether a second compilation with AVX2 forced off would exercise anything
/// the first does not. Only the x86-64 backend has two vector widths, and a
/// host without AVX2 already emits the SSE2 one.
const sse2_worth_testing = zregex.jit_available and
    @import("builtin").cpu.arch == .x86_64;

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

    // Usually the defaults, but now and then a flag is set for the whole
    // pattern rather than written into it. `compileWithFlags` starts the
    // parser from a different state than `(?i:...)` mutating it partway, and
    // a top-level flag reaches constructs an inline group never wraps -- the
    // `^` and `$` of an unparenthesised alternation, for one.
    const flags: zregex.Flags = if (src.index(4) == 0) .{
        .case_insensitive = src.boolean(),
        .multiline = src.boolean(),
        .dot_all = src.boolean(),
    } else .{};

    var re = Regex.compileWithFlags(gpa, pattern, flags) catch return; // invalid is fine
    defer re.deinit();
    // Keep a runaway pattern from stalling the fuzzer; a configuration that
    // gives up is skipped rather than compared.
    re.max_steps = 100_000;

    // The same pattern again with AVX2 forced off. Which vector code the
    // x86-64 JIT emits is decided while compiling, so the generator the host
    // CPU does not select cannot be reached by flipping a field afterwards --
    // it needs its own `Regex`. Everything else about the two is identical,
    // which is exactly what makes them comparable.
    var re_sse2: ?Regex = null;
    defer if (re_sse2) |*r| r.deinit();
    if (sse2_worth_testing) {
        zregex.overrideAvx2(false);
        defer zregex.overrideAvx2(null);
        if (Regex.compileWithFlags(gpa, pattern, flags)) |alt| {
            re_sse2 = alt;
            re_sse2.?.max_steps = re.max_steps;
        } else |_| {}
    }

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
        const base = if (cfg.sse2) (re_sse2 orelse continue) else re;
        if (std.mem.startsWith(u8, cfg.name, "jit") and base.jit_code == null) continue;

        var probe = base;
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

        // `isMatch` is not `find` with the captures thrown away: the lazy DFA
        // answers it in a mode of its own that never materialises them, and
        // the JIT has a separate entry point too. Either could disagree with
        // `find` about whether there is a match at all.
        if (probe.isMatch(gpa, hay.items)) |yes| {
            if (probe.find(gpa, hay.items)) |found| {
                if (found) |m| {
                    var mm = m;
                    mm.deinit(gpa);
                }
                std.testing.expectEqual(found != null, yes) catch |err| {
                    std.debug.print(
                        "pattern={s}\nhaystack={f}\n{s}: isMatch={} but find={}\n",
                        .{ pattern, std.zig.fmtString(hay.items), cfg.name, yes, found != null },
                    );
                    return err;
                };
            } else |err| switch (err) {
                error.StepLimitExceeded => {},
                else => return err,
            }
        } else |err| switch (err) {
            error.StepLimitExceeded => {},
            else => return err,
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

/// Compile `pattern` and run the whole public surface over `hay`, letting
/// every allocation error out. Written for `checkAllAllocationFailures`, which
/// calls it once per allocation the successful run makes, failing that one.
fn allocFailureCase(
    gpa: std.mem.Allocator,
    pattern: []const u8,
    hay: []const u8,
    engine: zregex.Engine,
    memo: bool,
) anyerror!void {
    var re = Regex.compile(gpa, pattern) catch |err| switch (err) {
        error.OutOfMemory => return err,
        // A pattern this generator will not compile is not what is being
        // tested, and the caller has already seen it compile once.
        else => return,
    };
    defer re.deinit();
    re.max_steps = 10_000;
    re.memo = memo;
    if (re.fallback_engine == .pike) re.fallback_engine = engine;

    if (re.find(gpa, hay)) |m| {
        if (m) |found| {
            var mm = found;
            mm.deinit(gpa);
        }
    } else |err| switch (err) {
        error.OutOfMemory => return err,
        error.StepLimitExceeded => {},
    }

    _ = re.isMatch(gpa, hay) catch |err| switch (err) {
        error.OutOfMemory => return err,
        error.StepLimitExceeded => {},
    };

    var it = re.iterator(gpa, hay);
    defer it.deinit();
    var seen: usize = 0;
    while (seen < 8) : (seen += 1) {
        const step = it.next() catch |err| switch (err) {
            error.OutOfMemory => return err,
            error.StepLimitExceeded => break,
        };
        var mm = step orelse break;
        mm.deinit(gpa);
    }
}

test "no allocation failure leaks or is swallowed" {
    // Every other test runs with memory always available, so the paths taken
    // when an allocation fails partway are otherwise never executed: what has
    // been allocated by then still has to be released, and the error still
    // has to reach the caller rather than being reported as a clean result.
    //
    // `checkAllAllocationFailures` reruns each case once per allocation,
    // failing a different one each time, so the case count here is small on
    // purpose -- the work is quadratic in what a single case allocates.
    var prng = std.Random.DefaultPrng.init(0x0a11_0c_fa11);
    const src = Source{ .random = prng.random() };
    const gpa = std.testing.allocator;

    for (0..fuzz_options.alloc_cases) |_| {
        var b = Builder{ .src = src, .gpa = gpa };
        defer b.buf.deinit(gpa);
        try b.sequence(0);
        if (b.buf.items.len == 0) continue;

        var hay: std.ArrayList(u8) = .empty;
        defer hay.deinit(gpa);
        const hay_len = src.intRange(u8, 0, 12);
        for (0..hay_len) |_| try hay.appendSlice(gpa, chunks[src.index(chunks.len)]);

        // The two fallbacks allocate quite differently -- the backtracker has
        // an explicit stack and a memo table the Pike VM has no equivalent of.
        for ([_]zregex.Engine{ .pike, .backtrack }) |engine| {
            // Without the memo, every allocation failure must come back out
            // as one: a run that reports a clean result after an allocation
            // was refused has lost an error somewhere.
            try std.testing.checkAllAllocationFailures(
                gpa,
                allocFailureCase,
                .{ b.buf.items, hay.items, engine, false },
            );

            // With it, that last part cannot be required. `std.HashMap`
            // answers a `getOrPut` whose growth failed by looking the key up
            // anyway and reporting it found when it is already there -- the
            // memo's question is answered, so nothing is wrong, but from the
            // outside it looks like a swallowed error. Leaks are still
            // faults, and this is the only run that reaches the memo at all.
            std.testing.checkAllAllocationFailures(
                gpa,
                allocFailureCase,
                .{ b.buf.items, hay.items, engine, true },
            ) catch |err| switch (err) {
                error.SwallowedOutOfMemoryError => {},
                else => return err,
            };
        }
    }
}

test "engines agree on randomized patterns" {
    // Fixed seed so a failure is reproducible and CI is deterministic; this
    // is the cheap standing check that every build pays for. A longer run is
    // `zig build test -Dfuzz-cases=200000 -Dfuzz-seed=<n>`, walking the seed
    // to reach the patterns one stream never produces.
    var prng = std.Random.DefaultPrng.init(fuzz_options.seed);
    for (0..fuzz_options.cases) |_| try oneCase(.{ .random = prng.random() });
}
