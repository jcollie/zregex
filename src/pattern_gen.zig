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
    "\xc3",   "ab",       "aa",        "\x00",
};

/// Literals and class members the generator draws from, non-ASCII included so
/// the helper paths are reached.
/// A NUL is an ordinary character to both this library and PCRE2 -- neither
/// takes its subject as a C string -- and it is the one byte a haystack is
/// most likely to be mishandled at, so it is in both alphabets.
pub const pattern_chars = [_][]const u8{
    "a", "b",      "@",        "-",  "1",    " ",
    "A", "\u{e9}", "\u{20ac}", "\n", "\x00",
};

/// POSIX bracket class names, all of which mean the same to zregex and to
/// PCRE2 without `PCRE2_UCP`: ASCII only, as `\d`, `\w` and `\s` are.
pub const posix_names = [_][]const u8{
    "alnum", "alpha", "ascii", "blank", "cntrl", "digit", "graph",
    "lower", "print", "punct", "space", "upper", "word",  "xdigit",
};

/// Defaults for the per-builder limits below. Most cases want small
/// patterns, which are quick to run and easy to read back when one fails.
pub const max_depth = 4;
pub const max_pattern = 96;
pub const max_gen_groups = 8;

/// Group numbers are one-based, so this holds `max_group_limit` of them.
/// `group_limit` must stay under its bit count.
const GroupSet = std.bit_set.IntegerBitSet(64);
pub const max_group_limit: u8 = GroupSet.bit_length - 1;

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
    named: GroupSet = .initEmpty(),
    /// Groups whose closing paren has not been emitted yet: a backreference
    /// generated here would point at the group enclosing it.
    open: GroupSet = .initEmpty(),
    allow_backrefs: bool = true,
    /// Raised on a minority of cases to reach patterns the defaults never
    /// build: deep nesting, long programs, and many capture groups, each of
    /// which runs into limits the small ones never touch.
    depth_limit: u8 = max_depth,
    length_limit: usize = max_pattern,
    group_limit: u8 = max_gen_groups,
    /// Restricts generation to what a PCRE2 comparison can actually judge.
    ///
    /// Part of that is syntax PCRE2 does not accept at all — a quantified
    /// anchor such as `^*` or `\b+`, which zregex compiles and PCRE2 turns
    /// down as a quantifier on an unrepeatable item. Left in, it was most of
    /// what the oracle generated and threw away.
    ///
    /// The rest is three constructs PCRE2 10.47 gets wrong, which without
    /// this would have the oracle reporting the reference's own bugs:
    /// a caseless class holding a wide non-ASCII range stops matching
    /// characters it matches without `(?i)`, a `{0}` repeat over some bodies
    /// makes the whole pattern fail rather than matching empty, and a
    /// backreference to the group enclosing it is honoured or not depending
    /// on which alternative it sits in — `1(\1*)` matches while `1(2|\1*)`
    /// does not. Python agrees with zregex on the first two and rejects the
    /// third outright as a reference to an open group.
    avoid_pcre2_quirks: bool = false,
    /// Set by `atom` when what it emitted cannot carry a quantifier — an
    /// unscoped `(?i)` is the only such case — and cleared by `quantified`.
    no_quantifier: bool = false,

    const Error = std.mem.Allocator.Error;

    /// Append `bytes` unless doing so would run past `length_limit`, in which
    /// case they are dropped. Only ever used for content whose absence still
    /// leaves a well-formed pattern behind.
    pub fn put(self: *Builder, bytes: []const u8) Error!void {
        if (self.buf.items.len + bytes.len > self.length_limit) return;
        try self.buf.appendSlice(self.gpa, bytes);
    }

    /// Append `bytes` whatever the length limit says. Closing delimiters go
    /// through this: dropping one would leave a `(` or `[` unmatched and the
    /// pattern would be rejected outright, which is how nearly every case the
    /// limit truncated used to be spent. `atom` keeps `reserve` bytes free
    /// before opening anything, so the overshoot is a delimiter deep.
    fn close(self: *Builder, bytes: []const u8) Error!void {
        try self.buf.appendSlice(self.gpa, bytes);
    }

    /// Headroom `atom` requires before it will open a construct: enough for
    /// the longest opener the generator writes (`(?P<g40>`) and its closer.
    const reserve = 16;

    /// Smallest maximum to give a repeat. PCRE2's quirk is a repeat that can
    /// run no iterations at all over certain bodies -- `{0}` and the `{0,0}`
    /// that means the same thing -- where it fails the whole pattern rather
    /// than matching empty; Python and zregex both match. It handles `{0,}`
    /// and `{0,m}` for m of one or more exactly as zregex does, so only the
    /// maximum is held above zero and minimums stay free.
    ///
    /// This used to raise every minimum instead, which meant the oracle never
    /// generated a nullable loop with a zero minimum at all -- and that is
    /// where the Pike VM's guard-bit ceiling was producing a wrong capture.
    fn minRepeatMax(self: *Builder) u8 {
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
        // A NUL is spelled out too: the pattern reaches PCRE2 as a C string,
        // so a raw one would cut it short there and nowhere else, and the
        // two libraries would be compared on different patterns.
        if (std.mem.eql(u8, c, "\x00")) return self.put("\\x00");
        if (std.mem.eql(u8, c, "\n")) return self.put("\\n");
        if (std.mem.eql(u8, c, ".")) return self.put("\\.");
        // Now and then spell an ASCII character as an escape instead. The
        // pattern means the same thing, so this costs no generality, and it
        // reaches the escape parser -- including the octal form, whose split
        // from a backreference depends on the group count and on how many
        // digits follow.
        if (c.len == 1 and c[0] > ' ' and self.src.index(6) == 0) {
            var buf: [10]u8 = undefined;
            const spelled = switch (self.src.choice(enum { octal, hex, braced })) {
                .octal => std.fmt.bufPrint(&buf, "\\{o}", .{c[0]}),
                .hex => std.fmt.bufPrint(&buf, "\\x{x:0>2}", .{c[0]}),
                .braced => std.fmt.bufPrint(&buf, "\\x{{{x}}}", .{c[0]}),
            } catch return self.put(c);
            return self.put(spelled);
        }
        try self.put(c);
    }

    /// A shorthand set, written the same way inside a class or out.
    /// The negated spellings reach the complement of a range list, which is
    /// built by a different path in the compiler than the positive one.
    fn shorthand(self: *Builder) Error!void {
        try self.put(switch (self.src.choice(enum { d, w, s, D, W, S })) {
            .d => "\\d",
            .w => "\\w",
            .s => "\\s",
            .D => "\\D",
            .W => "\\W",
            .S => "\\S",
        });
    }

    /// One member of a bracketed class: a character, a range, a shorthand,
    /// or one of the positions where `]` and `-` are literal.
    fn classMember(self: *Builder, first: bool) Error!void {
        switch (self.src.choice(enum {
            char,
            ascii_range,
            high_range,
            shorthand,
            posix,
            dash,
            bracket,
            escaped,
        })) {
            .char => {
                const c = pattern_chars[self.src.index(pattern_chars.len)];
                // A newline has to be written as an escape, and a bare `-`
                // would start a range rather than stand for itself. A NUL is
                // spelled out for the reason `literal` gives.
                if (std.mem.eql(u8, c, "\x00")) return self.put("\\x00");
                if (std.mem.eql(u8, c, "\n")) return self.put("\\n");
                if (std.mem.eql(u8, c, "-")) return self.put("\\-");
                try self.put(c);
            },
            .ascii_range => try self.put(switch (self.src.choice(enum { az, AZ, d09, sym })) {
                .az => "a-c",
                .AZ => "A-C",
                .d09 => "0-3",
                .sym => " -@",
            }),
            // A range reaching past ASCII cannot use the inlined bitmap or
            // the vector scanner, so it takes the helper path. Under `(?i)`
            // PCRE2 10.47 stops matching characters such a range matches
            // without the flag, so it is left out when it is the reference.
            .high_range => try self.put(if (self.avoid_pcre2_quirks)
                "\u{e9}"
            else
                "\u{a0}-\u{2fff}"),
            .shorthand => try self.shorthand(),
            // A POSIX bracket class, which only means anything in here. Half
            // are negated, which reaches the complement of a range list.
            .posix => {
                const name = posix_names[self.src.index(posix_names.len)];
                // One piece: a dropped name would leave `[::]`, which is not
                // a class either engine knows.
                var buf: [16]u8 = undefined;
                try self.put(std.fmt.bufPrint(&buf, "[:{s}{s}:]", .{
                    if (self.src.boolean()) "^" else "",
                    name,
                }) catch unreachable);
            },
            // `-` is a literal first, last, or after a range; anywhere else
            // it would start one.
            .dash => try self.put(if (first) "-" else "\\-"),
            // `]` is a literal only as the very first member.
            .bracket => try self.put(if (first) "]" else "\\]"),
            .escaped => {
                const c = pattern_chars[self.src.index(pattern_chars.len)];
                if (c.len != 1 or c[0] <= ' ') return self.put("\\x00");
                var buf: [10]u8 = undefined;
                const spelled = switch (self.src.choice(enum { octal, hex, braced })) {
                    .octal => std.fmt.bufPrint(&buf, "\\{o}", .{c[0]}),
                    .hex => std.fmt.bufPrint(&buf, "\\x{x:0>2}", .{c[0]}),
                    .braced => std.fmt.bufPrint(&buf, "\\x{{{x}}}", .{c[0]}),
                } catch return self.put(c);
                try self.put(spelled);
            },
        }
    }

    /// A bracketed class of one to four members, negated half the time.
    fn bracketed(self: *Builder) Error!void {
        try self.close(if (self.src.boolean()) "[^" else "[");
        const opened = self.buf.items.len;
        const n = self.src.intRange(u8, 1, 4);
        for (0..n) |i| try self.classMember(i == 0);
        // Every member ran into the length limit. `[]` and `[^]` are not
        // empty classes to either zregex or PCRE2 -- both read that `]` as a
        // literal and then look for the real one -- so put a member back.
        if (self.buf.items.len == opened) try self.close("a");
        try self.close("]");
    }

    pub fn class(self: *Builder) Error!void {
        switch (self.src.choice(enum {
            shorthand,
            dot,
            bracketed,
            set,
            negated,
            high_set,
            mixed,
        })) {
            .shorthand => try self.shorthand(),
            .dot => try self.put("."),
            .bracketed => try self.bracketed(),
            .set => try self.put("[ab1]"),
            .negated => try self.put("[^ab]"),
            // Classes reaching past ASCII cannot use the inlined bitmap or
            // the vector scanner, so these take the helper path.
            .high_set => try self.put("[\u{e9}\u{20ac}]"),
            .mixed => try self.put("[a\u{e9}1]"),
        }
    }

    pub fn atom(self: *Builder, depth: u8) Error!void {
        if (depth >= self.depth_limit or self.buf.items.len + reserve > self.length_limit) {
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
                if (self.groups >= @min(self.group_limit, max_group_limit)) return self.literal();
                self.groups += 1;
                self.open.set(self.groups);
                // Half the groups are named, so that named capture and
                // `\k<name>` are exercised alongside the numbered forms. All
                // three spellings of a named group mean the same thing, so
                // rotating between them costs no generality and reaches the
                // two the parser would otherwise never see.
                if (self.src.boolean()) {
                    self.named.set(self.groups);
                    var buf: [16]u8 = undefined;
                    // Written in one piece: half an opener would either be a
                    // parse error or, worse, silently name two groups alike.
                    const opener = switch (self.src.choice(enum { angle, python, quoted })) {
                        .angle => std.fmt.bufPrint(&buf, "(?<g{d}>", .{self.groups}),
                        .python => std.fmt.bufPrint(&buf, "(?P<g{d}>", .{self.groups}),
                        .quoted => std.fmt.bufPrint(&buf, "(?'g{d}'", .{self.groups}),
                    } catch unreachable;
                    try self.close(opener);
                } else {
                    try self.close("(");
                }
                const opened = self.groups;
                try self.sequence(depth + 1);
                try self.close(")");
                self.open.unset(opened);
            },
            .noncapturing => {
                try self.close("(?:");
                try self.sequence(depth + 1);
                try self.close(")");
            },
            .alternation => {
                try self.close("(?:");
                const branches = self.src.intRange(u8, 2, 4);
                for (0..branches) |i| {
                    // Structural, like the parens: a dropped `|` would not
                    // fail to parse, it would quietly concatenate two
                    // branches into one and generate something else.
                    if (i != 0) try self.close("|");
                    // An empty branch makes the whole alternation able to
                    // match nothing, which is what the empty-loop guard in
                    // every engine has to agree about once a quantifier
                    // follows.
                    if (self.src.index(5) == 0) continue;
                    try self.sequence(depth + 1);
                }
                try self.close(")");
            },
            .anchor => {
                // PCRE2 will not compile a quantified anchor, so when it is
                // the reference the caller is told to leave this one alone.
                if (self.avoid_pcre2_quirks) self.no_quantifier = true;
                switch (self.src.choice(enum {
                    start,
                    end,
                    word,
                    not_word,
                    text_start,
                    text_end,
                    text_end_or_newline,
                })) {
                    .start => try self.put("^"),
                    .end => try self.put("$"),
                    .word => try self.put("\\b"),
                    .not_word => try self.put("\\B"),
                    .text_start => try self.put("\\A"),
                    .text_end => try self.put("\\z"),
                    // `\Z` differs from `\z` only when the haystack ends in a
                    // newline, which the chunk alphabet makes happen often.
                    .text_end_or_newline => try self.put("\\Z"),
                }
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
                try self.close(if (self.src.boolean()) "(?=" else "(?!");
                // A whole sequence, not just one character: a lookahead may
                // hold groups, alternation and unbounded repeats, and the
                // captures it records survive a positive assertion while a
                // negative one has to leave them unset.
                try self.sequence(depth + 1);
                try self.close(")");
            },
            .lookbehind => {
                try self.close(if (self.src.boolean()) "(?<=" else "(?<!");
                try self.lookbehindBody();
                try self.close(")");
            },
            .flags => {
                const setting = switch (self.src.choice(enum { i, s, m, minus_i, ms })) {
                    .i => "i",
                    .s => "s",
                    .m => "m",
                    .minus_i => "-i",
                    .ms => "ms",
                };
                // The unscoped form runs to the end of the enclosing group
                // and crosses `|` on the way, which is a different rule from
                // the scoped one and the only place it is exercised. Nothing
                // may be quantified after it, so the caller is told to stop.
                if (self.src.boolean()) {
                    try self.close("(?");
                    try self.close(setting);
                    try self.close(")");
                    self.no_quantifier = true;
                    return;
                }
                try self.close("(?");
                try self.close(setting);
                try self.close(":");
                try self.sequence(depth + 1);
                try self.close(")");
            },
        }
    }

    /// The body of a lookbehind. zregex allows a variable-length one, which
    /// most engines do not, so this is where that support is exercised; the
    /// lengths stay bounded because PCRE2 — the oracle's reference — accepts
    /// a variable-length lookbehind only when its branches have a known
    /// maximum, and an unbounded body would just be skipped there.
    fn lookbehindBody(self: *Builder) Error!void {
        const n = self.src.intRange(u8, 1, 3);
        for (0..n) |_| {
            const before = self.buf.items.len;
            if (self.src.boolean()) {
                try self.literal();
            } else {
                try self.class();
            }
            // Nothing was written, so there is nothing to quantify.
            if (self.buf.items.len == before) continue;
            var buf: [16]u8 = undefined;
            try self.close(switch (self.src.choice(enum { none, none2, opt, exact, range })) {
                .none, .none2 => continue,
                .opt => "?",
                .exact => std.fmt.bufPrint(&buf, "{{{d}}}", .{
                    self.src.intRange(u8, 1, 3),
                }) catch unreachable,
                .range => blk: {
                    const lo = self.src.intRange(u8, 0, 2);
                    const hi = @max(self.src.intRange(u8, lo, 4), self.minRepeatMax());
                    break :blk std.fmt.bufPrint(&buf, "{{{d},{d}}}", .{ lo, hi }) catch unreachable;
                },
            });
        }
    }

    pub fn quantified(self: *Builder, depth: u8) Error!void {
        self.no_quantifier = false;
        const before = self.buf.items.len;
        try self.atom(depth);
        if (self.no_quantifier) {
            self.no_quantifier = false;
            return;
        }
        // The atom hit the length limit and wrote nothing, so a quantifier
        // here would have nothing to apply to and the pattern would not
        // parse. That is what most of the truncated cases used to become.
        if (self.buf.items.len == before) return;
        if (self.src.boolean()) return;
        var buf: [16]u8 = undefined;
        // Written in one piece: a `{` whose `}` was dropped would be read as
        // a literal brace rather than as the quantifier meant here.
        const quant = switch (self.src.choice(enum { star, plus, opt, exact, range, open })) {
            .star => "*",
            .plus => "+",
            .opt => "?",
            // Bounds reach past the peeling threshold on purpose: above it
            // the compiler and both JIT backends switch to a counted loop.
            .exact => std.fmt.bufPrint(&buf, "{{{d}}}", .{
                self.src.intRange(u8, self.minRepeatMax(), 12),
            }) catch unreachable,
            .range => blk: {
                const lo = self.src.intRange(u8, 0, 6);
                // Now and then the upper bound runs well past the peeling
                // threshold, where the counted loop a repeat compiles to is
                // the only thing keeping the program a reasonable size.
                const hi_max: u8 = if (self.src.index(8) == 0) 60 else 12;
                const hi = @max(self.src.intRange(u8, lo, hi_max), self.minRepeatMax());
                break :blk std.fmt.bufPrint(&buf, "{{{d},{d}}}", .{ lo, hi }) catch unreachable;
            },
            .open => std.fmt.bufPrint(&buf, "{{{d},}}", .{
                self.src.intRange(u8, 0, 10),
            }) catch unreachable,
        };
        try self.close(quant);
        if (self.src.boolean()) try self.close("?"); // lazy
    }

    pub fn sequence(self: *Builder, depth: u8) Error!void {
        const n = self.src.intRange(u8, 1, 3);
        for (0..n) |_| try self.quantified(depth);
    }
};
