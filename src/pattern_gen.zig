// SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

//! Random pattern and haystack generation, shared by the in-tree differential
//! fuzzer and the external-oracle tool in tools/.
//!
//! Patterns come from a grammar rather than from raw bytes, so that time goes
//! on the engines instead of on the parser rejecting noise. Decisions are read
//! through `Source`, which draws either from the fuzzer's `Smith` or from a
//! seeded PRNG.
const std = @import("std");

pub const chunks = [_][]const u8{
    "a",      "a",        "b",         "@",    "-",
    ".",      " ",        "1",         "\n",   "A",
    "\u{e9}", "\u{20ac}", "\u{1F600}", "\xff", "\x80",
    "\xc3",   "ab",       "aa",
};

/// Literals and class members the generator draws from, non-ASCII included so
/// the helper paths are reached.
pub const pattern_chars = [_][]const u8{
    "a", "b",      "@",        "-",  "1", " ",
    "A", "\u{e9}", "\u{20ac}", "\n",
};

pub const max_depth = 4;
pub const max_pattern = 96;

/// Where the generator's decisions come from. The fuzzer supplies bytes it
/// can mutate under coverage feedback; the seeded PRNG supplies a
/// reproducible stream.
pub const Source = union(enum) {
    smith: *std.testing.Smith,
    random: std.Random,

    pub fn index(self: Source, len: usize) usize {
        return switch (self) {
            .smith => |s| s.index(len),
            .random => |r| r.uintLessThan(usize, len),
        };
    }

    pub fn intRange(self: Source, comptime T: type, lo: T, hi: T) T {
        return switch (self) {
            .smith => |s| s.valueRangeAtMost(T, lo, hi),
            .random => |r| r.intRangeAtMost(T, lo, hi),
        };
    }

    pub fn boolean(self: Source) bool {
        return switch (self) {
            .smith => |s| s.value(bool),
            .random => |r| r.boolean(),
        };
    }

    pub fn choice(self: Source, comptime T: type) T {
        return switch (self) {
            .smith => |s| s.value(T),
            .random => |r| r.enumValue(T),
        };
    }
};

pub const Builder = struct {
    src: Source,
    buf: std.ArrayList(u8) = .empty,
    gpa: std.mem.Allocator,
    /// Capture groups opened so far, so a backreference can name a real one.
    groups: u8 = 0,
    /// Which of those were given a name, so `\k<name>` only uses real ones.
    named: std.bit_set.IntegerBitSet(16) = .initEmpty(),
    /// Groups whose closing paren has not been emitted yet: a backreference
    /// generated here would point at the group enclosing it.
    open: std.bit_set.IntegerBitSet(16) = .initEmpty(),
    allow_backrefs: bool = true,
    /// Steers around three constructs PCRE2 10.47 gets wrong, so that the
    /// oracle reports real differences rather than the reference's own bugs:
    /// a caseless class holding a wide non-ASCII range stops matching
    /// characters it matches without `(?i)`, a `{0}` repeat over some bodies
    /// makes the whole pattern fail rather than matching empty, and a
    /// backreference to the group enclosing it is honoured or not depending
    /// on which alternative it sits in — `1(\1*)` matches while `1(2|\1*)`
    /// does not. Python agrees with zregex on the first two and rejects the
    /// third outright as a reference to an open group.
    avoid_pcre2_quirks: bool = false,

    const Error = std.mem.Allocator.Error;

    pub fn put(self: *Builder, bytes: []const u8) Error!void {
        if (self.buf.items.len + bytes.len > max_pattern) return;
        try self.buf.appendSlice(self.gpa, bytes);
    }

    /// Lowest repeat count to generate; `{0}` is one of the shapes PCRE2
    /// mishandles.
    fn minRepeat(self: *Builder) u8 {
        return if (self.avoid_pcre2_quirks) 1 else 0;
    }

    pub fn putDigits(self: *Builder, n: u8) Error!void {
        var buf: [3]u8 = undefined;
        try self.put(std.fmt.bufPrint(&buf, "{d}", .{n}) catch return);
    }

    pub fn literal(self: *Builder) Error!void {
        const c = pattern_chars[self.src.index(pattern_chars.len)];
        // A newline must be written as an escape and '.' would be syntax;
        // everything else goes in as itself, multi-byte codepoints included.
        if (std.mem.eql(u8, c, "\n")) return self.put("\\n");
        if (std.mem.eql(u8, c, ".")) return self.put("\\.");
        try self.put(c);
    }

    pub fn class(self: *Builder) Error!void {
        switch (self.src.choice(enum {
            digit,
            word,
            space,
            set,
            negated,
            dot,
            high_set,
            high_range,
            mixed,
        })) {
            .digit => try self.put("\\d"),
            .word => try self.put("\\w"),
            .space => try self.put("\\s"),
            .dot => try self.put("."),
            .set => try self.put("[ab1]"),
            .negated => try self.put("[^ab]"),
            // Classes reaching past ASCII cannot use the inlined bitmap or
            // the vector scanner, so these take the helper path.
            .high_set => try self.put("[\u{e9}\u{20ac}]"),
            .high_range => try self.put(if (self.avoid_pcre2_quirks)
                "[\u{e9}\u{20ac}]"
            else
                "[\u{a0}-\u{2fff}]"),
            .mixed => try self.put("[a\u{e9}1]"),
        }
    }

    pub fn atom(self: *Builder, depth: u8) Error!void {
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
            flags,
        })) {
            .literal => try self.literal(),
            .class => try self.class(),
            .group => {
                if (self.groups >= 8) return self.literal();
                self.groups += 1;
                self.open.set(self.groups);
                // Half the groups are named, so that named capture and
                // `\k<name>` are exercised alongside the numbered forms.
                if (self.src.boolean()) {
                    self.named.set(self.groups);
                    try self.put("(?<g");
                    try self.putDigits(self.groups);
                    try self.put(">");
                } else {
                    try self.put("(");
                }
                const opened = self.groups;
                try self.sequence(depth + 1);
                try self.put(")");
                self.open.unset(opened);
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
            .anchor => switch (self.src.choice(enum {
                start,
                end,
                word,
                not_word,
                text_start,
                text_end,
            })) {
                .start => try self.put("^"),
                .end => try self.put("$"),
                .word => try self.put("\\b"),
                .not_word => try self.put("\\B"),
                .text_start => try self.put("\\A"),
                .text_end => try self.put("\\z"),
            },
            .backref => {
                // Only ever refers to a group that is already open or closed.
                if (!self.allow_backrefs or self.groups == 0) return self.literal();
                var n = self.src.intRange(u8, 1, self.groups);
                if (self.avoid_pcre2_quirks) {
                    // Walk down to the nearest group that is already closed.
                    while (n > 0 and self.open.isSet(n)) n -= 1;
                    if (n == 0) return self.literal();
                }
                if (self.named.isSet(n) and self.src.boolean()) {
                    try self.put("\\k<g");
                    try self.putDigits(n);
                    try self.put(">");
                } else {
                    try self.put(&.{ '\\', '0' + n });
                }
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
            .flags => {
                // Always scoped and always with a body: a bare `(?i)` is not
                // something a quantifier may follow.
                try self.put(switch (self.src.choice(enum { i, s, m, minus_i })) {
                    .i => "(?i:",
                    .s => "(?s:",
                    .m => "(?m:",
                    .minus_i => "(?-i:",
                });
                try self.sequence(depth + 1);
                try self.put(")");
            },
        }
    }

    pub fn quantified(self: *Builder, depth: u8) Error!void {
        try self.atom(depth);
        if (self.src.boolean()) return;
        switch (self.src.choice(enum { star, plus, opt, exact, range, open })) {
            .star => try self.put("*"),
            .plus => try self.put("+"),
            .opt => try self.put("?"),
            // Bounds reach past the peeling threshold on purpose: above it
            // the compiler and both JIT backends switch to a counted loop.
            .exact => {
                try self.put("{");
                try self.putDigits(self.src.intRange(u8, self.minRepeat(), 12));
                try self.put("}");
            },
            .range => {
                const lo = self.src.intRange(u8, self.minRepeat(), 6);
                try self.put("{");
                try self.putDigits(lo);
                try self.put(",");
                try self.putDigits(self.src.intRange(u8, lo, 12));
                try self.put("}");
            },
            .open => {
                try self.put("{");
                try self.putDigits(self.src.intRange(u8, self.minRepeat(), 10));
                try self.put(",}");
            },
        }
        if (self.src.boolean()) try self.put("?"); // lazy
    }

    pub fn sequence(self: *Builder, depth: u8) Error!void {
        const n = self.src.intRange(u8, 1, 3);
        for (0..n) |_| try self.quantified(depth);
    }
};
