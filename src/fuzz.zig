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
//! noise, and they are drawn from a deliberately tiny alphabet so that
//! matches, backtracking, and ambiguity actually happen.
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

/// Small on purpose: overlapping literals and classes are what produce
/// interesting backtracking and capture disagreements.
const alphabet = "aab@-. 1";

const max_depth = 4;
const max_pattern = 96;

/// Where the generator's decisions come from. The fuzzer supplies bytes it
/// can mutate under coverage feedback; the seeded PRNG supplies a
/// reproducible stream.
const Source = union(enum) {
    smith: *std.testing.Smith,
    random: std.Random,

    fn index(self: Source, len: usize) usize {
        return switch (self) {
            .smith => |s| s.index(len),
            .random => |r| r.uintLessThan(usize, len),
        };
    }

    fn intRange(self: Source, comptime T: type, lo: T, hi: T) T {
        return switch (self) {
            .smith => |s| s.valueRangeAtMost(T, lo, hi),
            .random => |r| r.intRangeAtMost(T, lo, hi),
        };
    }

    fn boolean(self: Source) bool {
        return switch (self) {
            .smith => |s| s.value(bool),
            .random => |r| r.boolean(),
        };
    }

    fn choice(self: Source, comptime T: type) T {
        return switch (self) {
            .smith => |s| s.value(T),
            .random => |r| r.enumValue(T),
        };
    }
};

const Builder = struct {
    src: Source,
    buf: std.ArrayList(u8) = .empty,
    gpa: std.mem.Allocator,
    /// Capture groups opened so far, so a backreference can name a real one.
    groups: u8 = 0,

    const Error = std.mem.Allocator.Error;

    fn put(self: *Builder, bytes: []const u8) Error!void {
        if (self.buf.items.len + bytes.len > max_pattern) return;
        try self.buf.appendSlice(self.gpa, bytes);
    }

    fn literal(self: *Builder) Error!void {
        const c = alphabet[self.src.index(alphabet.len)];
        // '.' is the only alphabet character that is also syntax.
        if (c == '.') try self.put("\\.") else try self.put(&.{c});
    }

    fn class(self: *Builder) Error!void {
        switch (self.src.choice(enum { digit, word, space, set, negated, dot })) {
            .digit => try self.put("\\d"),
            .word => try self.put("\\w"),
            .space => try self.put("\\s"),
            .dot => try self.put("."),
            .set => try self.put("[ab1]"),
            .negated => try self.put("[^ab]"),
        }
    }

    fn atom(self: *Builder, depth: u8) Error!void {
        if (depth >= max_depth or self.buf.items.len > max_pattern - 8) {
            try self.literal();
            return;
        }
        switch (self.src.choice(enum {
            literal,
            class,
            group,
            noncapturing,
            alternation,
            anchor,
            backref,
            lookahead,
            lookbehind,
        })) {
            .literal => try self.literal(),
            .class => try self.class(),
            .group => {
                if (self.groups >= 8) return self.literal();
                self.groups += 1;
                try self.put("(");
                try self.sequence(depth + 1);
                try self.put(")");
            },
            .noncapturing => {
                try self.put("(?:");
                try self.sequence(depth + 1);
                try self.put(")");
            },
            .alternation => {
                try self.put("(?:");
                try self.sequence(depth + 1);
                try self.put("|");
                try self.sequence(depth + 1);
                try self.put(")");
            },
            .anchor => switch (self.src.choice(enum { start, end, word, not_word })) {
                .start => try self.put("^"),
                .end => try self.put("$"),
                .word => try self.put("\\b"),
                .not_word => try self.put("\\B"),
            },
            .backref => {
                // Only ever names a group that is already open or closed.
                if (self.groups == 0) return self.literal();
                const n = self.src.intRange(u8, 1, self.groups);
                try self.put(&.{ '\\', '0' + n });
            },
            .lookahead => {
                try self.put(if (self.src.boolean()) "(?=" else "(?!");
                try self.literal();
                try self.put(")");
            },
            .lookbehind => {
                try self.put(if (self.src.boolean()) "(?<=" else "(?<!");
                try self.literal();
                try self.put(")");
            },
        }
    }

    fn quantified(self: *Builder, depth: u8) Error!void {
        try self.atom(depth);
        if (self.src.boolean()) return;
        switch (self.src.choice(enum { star, plus, opt, exact, range, open })) {
            .star => try self.put("*"),
            .plus => try self.put("+"),
            .opt => try self.put("?"),
            .exact => {
                const n = self.src.intRange(u8, 0, 3);
                try self.put(&.{ '{', '0' + n, '}' });
            },
            .range => {
                const lo = self.src.intRange(u8, 0, 2);
                const hi = self.src.intRange(u8, lo, 3);
                try self.put(&.{ '{', '0' + lo, ',', '0' + hi, '}' });
            },
            .open => {
                const n = self.src.intRange(u8, 0, 2);
                try self.put(&.{ '{', '0' + n, ',', '}' });
            },
        }
        if (self.src.boolean()) try self.put("?"); // lazy
    }

    fn sequence(self: *Builder, depth: u8) Error!void {
        const n = self.src.intRange(u8, 1, 3);
        for (0..n) |_| try self.quantified(depth);
    }
};

/// One engine configuration to compare. Not every one applies to every
/// pattern: the Pike VM and the lazy DFA cannot run backreferences or
/// lookaround, and the JIT is only present where it could be generated.
const Config = struct {
    name: []const u8,
    apply: *const fn (*Regex) void,
    /// Whether this configuration can run a pattern needing the backtracker.
    handles_backtrack_only: bool,
    /// Which implementation strategy this is. The two families agree on
    /// everything except empty-bodied loops, where `Regex` picks one family
    /// and sticks to it, so the oracle compares within a family there.
    family: enum { backtracking, automaton },
};

const configs = [_]Config{
    .{
        .name = "jit",
        .family = .backtracking,
        .handles_backtrack_only = true,
        .apply = struct {
            fn f(re: *Regex) void {
                re.jit_mode = .on;
            }
        }.f,
    },
    .{
        .name = "dfa",
        .family = .automaton,
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
        .family = .automaton,
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
        .family = .backtracking,
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
        .family = .backtracking,
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

/// Every match in `haystack`, flattened to spans so the results of two
/// configurations can be compared directly.
///
/// `groups_too` is false for patterns with an empty-bodied loop, where the
/// engines legitimately differ on one detail — see `oneCase`.
fn collect(
    gpa: std.mem.Allocator,
    re: *const Regex,
    haystack: []const u8,
    groups_too: bool,
    out: *std.ArrayList(?Span),
) !void {
    var it = re.iterator(gpa, haystack);
    defer it.deinit();
    var count: usize = 0;
    while (try it.next()) |m| {
        var mm = m;
        defer mm.deinit(gpa);
        if (groups_too) {
            try out.appendSlice(gpa, mm.groups);
        } else {
            try out.append(gpa, mm.groups[0]);
        }
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
    const hay_len = src.intRange(u8, 0, 40);
    for (0..hay_len) |_| try hay.append(gpa, alphabet[src.index(alphabet.len)]);

    const needs_backtrack = re.fallback_engine == .backtrack;

    // Whether a loop iteration that consumes nothing leaves its captures
    // behind is where backtracking and automaton engines genuinely part
    // company, and neither is wrong. For `(a*)*` against "aa", PCRE and
    // Python run a final empty iteration and report group 1 as (2,2); RE2 and
    // Go report (0,2), because a Pike VM cannot re-enter a loop body at a
    // position it has already visited — the very rule that stops it looping
    // forever. zregex inherits both behaviors from its two engine families,
    // so for these patterns the oracle checks match spans, which do agree,
    // and leaves the captures of empty iterations alone.
    // With an empty-bodied loop the two families disagree by design, and
    // `Regex` never mixes them for such a pattern, so compare within a family.
    const per_family = re.has_loop_guard;
    const compare_groups = !re.has_loop_guard;

    var reference: std.ArrayList(?Span) = .empty;
    defer reference.deinit(gpa);
    var reference_name: []const u8 = "";
    var reference_family: @TypeOf(configs[0].family) = .backtracking;

    var actual: std.ArrayList(?Span) = .empty;
    defer actual.deinit(gpa);

    for (configs) |cfg| {
        if (needs_backtrack and !cfg.handles_backtrack_only) continue;
        if (std.mem.eql(u8, cfg.name, "jit") and re.jit_code == null) continue;

        var probe = re;
        cfg.apply(&probe);
        actual.clearRetainingCapacity();
        collect(gpa, &probe, hay.items, compare_groups, &actual) catch |err| switch (err) {
            error.StepLimitExceeded => continue,
            else => return err,
        };

        if (reference_name.len == 0 or (per_family and cfg.family != reference_family)) {
            reference_name = cfg.name;
            reference_family = cfg.family;
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

test "engines agree on randomized patterns" {
    // Fixed seed so a failure is reproducible and CI is deterministic. Raise
    // the count when changing an engine; this is the cheap standing check.
    var prng = std.Random.DefaultPrng.init(0x2026_08_31);
    for (0..3000) |_| try oneCase(.{ .random = prng.random() });
}
