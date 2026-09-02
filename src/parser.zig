// SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

//! Recursive-descent regex parser producing an index-based AST.
//!
//! The parser writes into caller-provided buffers (`nodes`, `ranges`, `names`)
//! rather than allocating, so the exact same code runs at runtime (buffers from
//! an allocator) and at comptime (fixed arrays). `bufferSizes` gives safe
//! worst-case buffer lengths for a given pattern length.
const std = @import("std");
const common = @import("common.zig");
const casefold = @import("casefold");

pub const max_codepoint: u21 = 0x10FFFF;
/// Upper bound for `{n,m}` repeat counts (mirrors RE2's limit).
pub const max_repeat: u32 = 1000;
/// Maximum capture groups including group 0 (the whole match).
pub const max_groups: u8 = 100;

/// Where a digit escape stops being read as a group number. Past the largest
/// possible group it cannot be a backreference anyway, and stopping keeps a
/// long run of digits from overflowing the accumulator.
const max_group_number: u32 = max_groups;
/// Maximum nesting depth of groups.
pub const max_depth: u32 = 200;

pub const NodeIndex = u32;

pub const Node = union(enum) {
    empty,
    literal: Literal,
    /// `.`; the payload is whether it matches `\n` (`dot_all` at this point).
    any: bool,
    class: Class,
    concat: [2]NodeIndex,
    alt: [2]NodeIndex,
    repeat: Repeat,
    group: Group,
    assertion: common.Assertion,
    backref: Backref,
    look: Look,
};

pub const Literal = struct {
    cp: u21,
    /// ASCII case-insensitive (`case_insensitive` at this point).
    ci: bool,
};

pub const Class = struct {
    /// Contiguous run inside the parser's `ranges` buffer.
    start: u32,
    len: u32,
    negated: bool,
    ci: bool,
};

pub const Backref = struct {
    index: u8,
    ci: bool,
};

pub const Repeat = struct {
    child: NodeIndex,
    min: u32,
    /// null means unbounded.
    max: ?u32,
    greedy: bool,
};

pub const Group = struct {
    child: NodeIndex,
    /// Capture index; null for `(?:...)`.
    index: ?u8,
};

pub const LookKind = enum { ahead_pos, ahead_neg, behind_pos, behind_neg };

pub const Look = struct {
    child: NodeIndex,
    kind: LookKind,
};

pub const NamedGroup = struct {
    /// Slice into the pattern string.
    name: []const u8,
    index: u8,
};

pub const ParseError = error{
    UnexpectedEnd,
    UnbalancedParen,
    InvalidEscape,
    InvalidClass,
    InvalidRepeat,
    RepeatTooLarge,
    NothingToRepeat,
    TooManyGroups,
    InvalidBackref,
    InvalidGroupName,
    DuplicateGroupName,
    UnsupportedFeature,
    NestingTooDeep,
    PatternTooComplex,
    InvalidCodepoint,
};

pub const BufferSizes = struct {
    nodes: usize,
    ranges: usize,
    names: usize,
};

/// Worst-case buffer sizes for parsing a pattern of length `pattern_len`.
///
/// `caseless` must be true whenever the pattern might be matched without
/// regard to case, whether from the flags it is compiled with or from an
/// inline `(?i)`. Closing a class over case adds ranges that the pattern
/// itself does not account for -- `(?i)[\u{a0}-\u{2fff}]` reaches beyond its
/// own bounds to the `K` and `S` whose orbits it holds the far end of -- and
/// at most one per codepoint that folds, which is what the extra room is.
/// Over-reporting only costs a larger scratch buffer for one compile.
pub fn bufferSizes(pattern_len: usize, caseless: bool) BufferSizes {
    return .{
        .nodes = 2 * pattern_len + 16,
        .ranges = 4 * pattern_len + 16 + if (caseless) casefold.folds.len else 0,
        .names = max_groups,
    };
}

/// Whether `bufferSizes` has to leave room for case closure: either the
/// pattern is being compiled caseless, or it could turn itself caseless with
/// an inline flag. Looking for the letter is deliberately crude -- a literal
/// `i` costs nothing but a bigger scratch buffer.
pub fn mayBeCaseless(pattern: []const u8, flags: common.Flags) bool {
    return flags.case_insensitive or std.mem.indexOfScalar(u8, pattern, 'i') != null;
}

// Predefined (ASCII) shorthand classes, sorted and disjoint.
const digit_ranges = [_]common.ClassRange{.{ .lo = '0', .hi = '9' }};
const word_ranges = [_]common.ClassRange{
    .{ .lo = '0', .hi = '9' },
    .{ .lo = 'A', .hi = 'Z' },
    .{ .lo = '_', .hi = '_' },
    .{ .lo = 'a', .hi = 'z' },
};
const space_ranges = [_]common.ClassRange{
    .{ .lo = 0x09, .hi = 0x0D },
    .{ .lo = 0x20, .hi = 0x20 },
};

/// `\h` and `\v`, which unlike `\d`, `\w` and `\s` are not ASCII-only even
/// in PCRE without PCRE2_UCP: both are fixed lists of codepoints rather than
/// Unicode properties, so following PCRE exactly costs nothing. Taken from
/// HSPACE_LIST and VSPACE_LIST in PCRE2's pcre2_internal.h.
const hspace_ranges = [_]common.ClassRange{
    .{ .lo = 0x09, .hi = 0x09 }, // horizontal tab
    .{ .lo = 0x20, .hi = 0x20 }, // space
    .{ .lo = 0xA0, .hi = 0xA0 }, // no-break space
    .{ .lo = 0x1680, .hi = 0x1680 }, // ogham space mark
    .{ .lo = 0x180E, .hi = 0x180E }, // mongolian vowel separator
    .{ .lo = 0x2000, .hi = 0x200A }, // en quad .. hair space
    .{ .lo = 0x202F, .hi = 0x202F }, // narrow no-break space
    .{ .lo = 0x205F, .hi = 0x205F }, // medium mathematical space
    .{ .lo = 0x3000, .hi = 0x3000 }, // ideographic space
};
const vspace_ranges = [_]common.ClassRange{
    .{ .lo = 0x0A, .hi = 0x0D }, // LF, VT, FF, CR
    .{ .lo = 0x85, .hi = 0x85 }, // next line
    .{ .lo = 0x2028, .hi = 0x2029 }, // line and paragraph separator
};

/// POSIX bracket classes, usable only inside a class: `[[:alpha:]x]`. ASCII
/// like `\d`, `\w` and `\s`, which is also what PCRE gives them without
/// `PCRE2_UCP`. Each range list is sorted, disjoint, and wholly within ASCII,
/// all of which `addAsciiComplement` relies on for the `[:^name:]` form.
const PosixClass = struct { name: []const u8, ranges: []const common.ClassRange };

const posix_classes = [_]PosixClass{
    .{ .name = "alnum", .ranges = &.{
        .{ .lo = '0', .hi = '9' },
        .{ .lo = 'A', .hi = 'Z' },
        .{ .lo = 'a', .hi = 'z' },
    } },
    .{ .name = "alpha", .ranges = &.{
        .{ .lo = 'A', .hi = 'Z' },
        .{ .lo = 'a', .hi = 'z' },
    } },
    .{ .name = "ascii", .ranges = &.{.{ .lo = 0x00, .hi = 0x7F }} },
    .{ .name = "blank", .ranges = &.{
        .{ .lo = 0x09, .hi = 0x09 },
        .{ .lo = 0x20, .hi = 0x20 },
    } },
    .{ .name = "cntrl", .ranges = &.{
        .{ .lo = 0x00, .hi = 0x1F },
        .{ .lo = 0x7F, .hi = 0x7F },
    } },
    .{ .name = "digit", .ranges = &digit_ranges },
    // `graph` is the printable characters except space; `print` includes it.
    .{ .name = "graph", .ranges = &.{.{ .lo = 0x21, .hi = 0x7E }} },
    .{ .name = "lower", .ranges = &.{.{ .lo = 'a', .hi = 'z' }} },
    .{ .name = "print", .ranges = &.{.{ .lo = 0x20, .hi = 0x7E }} },
    .{ .name = "punct", .ranges = &.{
        .{ .lo = 0x21, .hi = 0x2F },
        .{ .lo = 0x3A, .hi = 0x40 },
        .{ .lo = 0x5B, .hi = 0x60 },
        .{ .lo = 0x7B, .hi = 0x7E },
    } },
    .{ .name = "space", .ranges = &space_ranges },
    .{ .name = "upper", .ranges = &.{.{ .lo = 'A', .hi = 'Z' }} },
    .{ .name = "word", .ranges = &word_ranges },
    .{ .name = "xdigit", .ranges = &.{
        .{ .lo = '0', .hi = '9' },
        .{ .lo = 'A', .hi = 'F' },
        .{ .lo = 'a', .hi = 'f' },
    } },
};

pub const Parser = struct {
    pattern: []const u8,
    flags: common.Flags,
    nodes: []Node,
    ranges: []common.ClassRange,
    names: []NamedGroup,
    pos: usize = 0,
    nodes_len: u32 = 0,
    ranges_len: u32 = 0,
    names_len: u32 = 0,
    /// Next capture index; starts at 1 because 0 is the whole match.
    group_count: u8 = 1,
    has_backref: bool = false,
    has_look: bool = false,

    const Self = @This();

    pub fn parse(self: *Self) ParseError!NodeIndex {
        const root = try self.parseAlternation(0);
        if (self.pos < self.pattern.len) {
            // The only way parseAlternation stops early is at ')'.
            return error.UnbalancedParen;
        }
        return root;
    }

    fn addNode(self: *Self, node: Node) ParseError!NodeIndex {
        if (self.nodes_len >= self.nodes.len) return error.PatternTooComplex;
        self.nodes[self.nodes_len] = node;
        self.nodes_len += 1;
        return self.nodes_len - 1;
    }

    /// Add every codepoint case-equivalent to one the class already holds, and
    /// report whether the class can now be matched without folding.
    ///
    /// Doing this here means `(?i)` is gone by the time anything runs: the
    /// engines, the JIT and the prefilter all see an ordinary class, and no
    /// hot loop has to fold a codepoint it reads. One pass is exact because
    /// case-equivalence classes are disjoint -- adding the rest of one can
    /// never bring a member of another into range.
    /// A literal, as the parser should record it. Under `(?i)` a codepoint
    /// with case variants becomes the class of them all rather than a literal
    /// carrying a flag, which is what keeps folding out of the engines.
    fn addLiteral(self: *Self, cp: u21) ParseError!NodeIndex {
        if (!self.flags.case_insensitive) {
            return self.addNode(.{ .literal = .{ .cp = cp, .ci = false } });
        }
        var one: [1]u21 = undefined;
        const orbit = common.caseOrbit(cp, &one);
        if (orbit.len == 1) {
            return self.addNode(.{ .literal = .{ .cp = cp, .ci = false } });
        }
        // An ASCII letter whose only other case is also ASCII keeps the
        // `ci` literal it has always been. Folding it is one instruction
        // everywhere, including inside the JIT, where turning it into a
        // two-member class instead cost about a third of the throughput on
        // the caseless-literal benchmark. `k` and `s` are the exceptions --
        // the Kelvin sign and the long s are in their classes -- and they
        // take the general path below with everything non-ASCII.
        if (orbit.len == 2 and orbit[0] < 0x80 and orbit[1] < 0x80) {
            return self.addNode(.{ .literal = .{ .cp = cp, .ci = true } });
        }
        const start = self.ranges_len;
        for (orbit) |m| try self.addRange(m, m);
        return self.addNode(.{ .class = .{
            .start = start,
            .len = self.ranges_len - start,
            .negated = false,
            .ci = false,
        } });
    }

    fn caseCloseRanges(self: *Self, start: u32) ParseError!void {
        const end = self.ranges_len;
        const original = self.ranges[start..end];
        for (casefold.orbits) |orbit| {
            var present = false;
            for (orbit) |m| {
                if (inRanges(original, m)) {
                    present = true;
                    break;
                }
            }
            if (!present) continue;
            for (orbit) |m| {
                if (!inRanges(original, m)) try self.addRange(m, m);
            }
        }
    }

    fn addRange(self: *Self, lo: u21, hi: u21) ParseError!void {
        if (self.ranges_len >= self.ranges.len) return error.PatternTooComplex;
        self.ranges[self.ranges_len] = .{ .lo = lo, .hi = hi };
        self.ranges_len += 1;
    }

    fn inRanges(ranges: []const common.ClassRange, cp: u21) bool {
        for (ranges) |r| {
            if (cp >= r.lo and cp <= r.hi) return true;
        }
        return false;
    }

    fn addRanges(self: *Self, rs: []const common.ClassRange) ParseError!void {
        for (rs) |r| try self.addRange(r.lo, r.hi);
    }

    /// Append the complement of a sorted, disjoint ASCII range set, closed
    /// over ASCII case first when `ci` is set.
    ///
    /// `[:^lower:]` is complemented here, at parse time, while the `ci` flag
    /// is not applied until match time -- so without the closure the two
    /// happen in the wrong order. `a` would fold to `A`, find it in the
    /// complement of `a-z`, and match, where PCRE reads the class as "not a
    /// letter of either case" and does not. Closing the set before
    /// complementing puts the two steps back in PCRE's order.
    ///
    /// Only reached for POSIX classes, whose sets are all ASCII, which is why
    /// a bitmap over the low 128 codepoints can hold one. `\D`, `\W` and
    /// `\S` complement sets that are already closed over case, so they can
    /// and do go straight to `addComplement`.
    fn addAsciiComplement(self: *Self, rs: []const common.ClassRange, ci: bool) ParseError!void {
        var in: [128]bool = @splat(false);
        for (rs) |r| {
            std.debug.assert(r.hi < in.len);
            for (r.lo..r.hi + 1) |c| in[c] = true;
        }
        if (ci) {
            for ('a'..'z' + 1) |c| {
                if (in[c]) in[c - 32] = true;
                if (in[c - 32]) in[c] = true;
            }
        }
        var c: u21 = 0;
        while (c < in.len) {
            if (in[c]) {
                c += 1;
                continue;
            }
            const lo = c;
            while (c < in.len and !in[c]) c += 1;
            try self.addRange(lo, c - 1);
        }
        // Everything past ASCII is outside any of these sets.
        try self.addRange(in.len, max_codepoint);
    }

    /// Append the complement of a sorted, disjoint range set.
    fn addComplement(self: *Self, rs: []const common.ClassRange) ParseError!void {
        var next: u21 = 0;
        for (rs) |r| {
            if (r.lo > next) try self.addRange(next, r.lo - 1);
            next = r.hi + 1;
        }
        if (next <= max_codepoint) try self.addRange(next, max_codepoint);
    }

    fn peek(self: *Self) ?u8 {
        return if (self.pos < self.pattern.len) self.pattern[self.pos] else null;
    }

    fn peekAt(self: *Self, off: usize) ?u8 {
        return if (self.pos + off < self.pattern.len) self.pattern[self.pos + off] else null;
    }

    fn eat(self: *Self, c: u8) bool {
        if (self.peek() == c) {
            self.pos += 1;
            return true;
        }
        return false;
    }

    /// Builds a balanced binary tree of `concat` or `alt` nodes from leaves
    /// pushed left to right, the way a binary counter carries: rank `i` holds
    /// a finished subtree of 2^i leaves, and pushing a leaf merges upward
    /// until it finds an empty rank.
    ///
    /// Shape is all this changes. Both node kinds are associative in every
    /// property derived from them -- instructions are emitted in leaf order,
    /// nullability is a fold, alternation priority is leaf order -- but the
    /// compiler recurses through them, and folding leftward, which is what
    /// this replaced, gave a pattern of a million plain characters a spine a
    /// million nodes deep. Walking that overran the stack and crashed before
    /// the program-size limit could reject the pattern; balanced, the same
    /// walk is twenty frames and the limit gets its say.
    fn TreeBuilder(comptime tag: std.meta.Tag(Node)) type {
        return struct {
            pending: [32]?NodeIndex = @splat(null),

            fn push(tb: *@This(), p: *Self, leaf: NodeIndex) ParseError!void {
                var node = leaf;
                for (&tb.pending) |*slot| {
                    const left = slot.* orelse {
                        slot.* = node;
                        return;
                    };
                    slot.* = null;
                    node = try p.addNode(@unionInit(Node, @tagName(tag), .{ left, node }));
                }
                // 2^32 leaves; no pattern the buffers can hold gets here.
                return error.PatternTooComplex;
            }

            /// Merge what remains, or null when nothing was pushed. Low ranks
            /// hold the latest leaves, so they end up rightmost.
            fn finish(tb: *@This(), p: *Self) ParseError!?NodeIndex {
                var acc: ?NodeIndex = null;
                for (tb.pending) |slot| {
                    const left = slot orelse continue;
                    acc = if (acc) |right|
                        try p.addNode(@unionInit(Node, @tagName(tag), .{ left, right }))
                    else
                        left;
                }
                return acc;
            }
        };
    }

    fn parseAlternation(self: *Self, depth: u32) ParseError!NodeIndex {
        if (depth > max_depth) return error.NestingTooDeep;
        var alts: TreeBuilder(.alt) = .{};
        try alts.push(self, try self.parseConcat(depth));
        while (self.eat('|')) {
            try alts.push(self, try self.parseConcat(depth));
        }
        return (try alts.finish(self)).?; // at least one branch was pushed
    }

    fn parseConcat(self: *Self, depth: u32) ParseError!NodeIndex {
        var seq: TreeBuilder(.concat) = .{};
        while (self.peek()) |c| {
            if (c == '|' or c == ')') break;
            switch (c) {
                '*', '+', '?' => return error.NothingToRepeat,
                '{' => if (try self.scanBounds() != null) return error.NothingToRepeat,
                else => {},
            }
            var atom = try self.parseAtom(depth);
            atom = try self.parseQuantifier(atom);
            try seq.push(self, atom);
        }
        return (try seq.finish(self)) orelse try self.addNode(.empty);
    }

    const Bounds = struct { min: u32, max: ?u32, next: usize };

    /// Pure lookahead at `self.pos` (which must be '{'). Returns null when the
    /// text is not quantifier-shaped (then '{' is a literal, PCRE-style).
    /// Step over the space and horizontal tab PCRE ignores inside braces.
    fn skipBraceSpace(pat: []const u8, from: usize) usize {
        var i = from;
        while (i < pat.len and (pat[i] == ' ' or pat[i] == '\t')) i += 1;
        return i;
    }

    fn scanBounds(self: *Self) ParseError!?Bounds {
        const pat = self.pattern;
        // PCRE ignores space and horizontal tab after `{`, before `}`, and on
        // either side of the comma, so `a{ 1 , 2 }` is `a{1,2}`. Anything else
        // between the braces means this is not a quantifier at all and the `{`
        // is the literal it is everywhere else.
        var i = skipBraceSpace(pat, self.pos + 1);

        var min: u32 = 0;
        var min_digits: usize = 0;
        while (i < pat.len and pat[i] >= '0' and pat[i] <= '9') : (i += 1) {
            min = min * 10 + (pat[i] - '0');
            min_digits += 1;
            if (min > max_repeat) return error.RepeatTooLarge;
        }
        i = skipBraceSpace(pat, i);

        var max: ?u32 = min;
        var max_digits: usize = 0;
        if (i < pat.len and pat[i] == ',') {
            i = skipBraceSpace(pat, i + 1);
            var m: u32 = 0;
            while (i < pat.len and pat[i] >= '0' and pat[i] <= '9') : (i += 1) {
                m = m * 10 + (pat[i] - '0');
                max_digits += 1;
                if (m > max_repeat) return error.RepeatTooLarge;
            }
            i = skipBraceSpace(pat, i);
            // `{n,}` has no upper bound; `{,m}` has no lower one and means
            // `{0,m}`, which is what PCRE and Python both read it as.
            max = if (max_digits == 0) null else m;
        }
        // A brace pair with no number in it at all -- `{}`, `{,}`, `{ , }` --
        // is not a quantifier, so `A{,}B` matches the text `A{,}B`.
        if (min_digits == 0 and max_digits == 0) return null;
        if (i >= pat.len or pat[i] != '}') return null;
        if (max) |m| {
            if (min > m) return error.InvalidRepeat;
        }
        return .{ .min = min, .max = max, .next = i + 1 };
    }

    /// Apply at most one postfix quantifier to `atom`.
    fn parseQuantifier(self: *Self, atom: NodeIndex) ParseError!NodeIndex {
        const c = self.peek() orelse return atom;
        var min: u32 = undefined;
        var max: ?u32 = undefined;
        switch (c) {
            '*' => {
                min = 0;
                max = null;
                self.pos += 1;
            },
            '+' => {
                min = 1;
                max = null;
                self.pos += 1;
            },
            '?' => {
                min = 0;
                max = 1;
                self.pos += 1;
            },
            '{' => {
                const b = (try self.scanBounds()) orelse return atom;
                min = b.min;
                max = b.max;
                self.pos = b.next;
            },
            else => return atom,
        }
        var greedy = true;
        if (self.eat('?')) greedy = false;
        // Reject a second quantifier (`a**`, `a*+` possessive, ...).
        if (self.peek()) |c2| switch (c2) {
            '*', '+', '?' => return error.InvalidRepeat,
            '{' => if (try self.scanBounds() != null) return error.InvalidRepeat,
            else => {},
        };
        return self.addNode(.{ .repeat = .{ .child = atom, .min = min, .max = max, .greedy = greedy } });
    }

    fn parseAtom(self: *Self, depth: u32) ParseError!NodeIndex {
        const c = self.peek().?;
        switch (c) {
            '(' => return self.parseGroup(depth),
            '[' => return self.parseClass(),
            '.' => {
                self.pos += 1;
                return self.addNode(.{ .any = self.flags.dot_all });
            },
            '^' => {
                self.pos += 1;
                const a: common.Assertion = if (self.flags.multiline) .begin_line else .begin_text;
                return self.addNode(.{ .assertion = a });
            },
            '$' => {
                self.pos += 1;
                // Outside multiline mode `$` is PCRE's: the end of the text,
                // or just before a newline that ends it. `\z` is the strict
                // one.
                const a: common.Assertion = if (self.flags.multiline)
                    .end_line
                else
                    .end_text_or_final_newline;
                return self.addNode(.{ .assertion = a });
            },
            '\\' => {
                const esc = try self.parseEscape(false);
                return switch (esc) {
                    .literal => |cp| try self.addLiteral(cp),
                    .class => |cl| self.addNode(.{ .class = cl }),
                    .assertion => |a| self.addNode(.{ .assertion = a }),
                    .backref => |n| blk: {
                        self.has_backref = true;
                        break :blk self.addNode(.{ .backref = .{
                            .index = n,
                            .ci = self.flags.case_insensitive,
                        } });
                    },
                };
            },
            else => {
                const d = common.decode(self.pattern, self.pos);
                self.pos += d.len;
                return self.addLiteral(d.cp);
            },
        }
    }

    fn parseGroup(self: *Self, depth: u32) ParseError!NodeIndex {
        self.pos += 1; // '('
        var capture_index: ?u8 = null;
        var look_kind: ?LookKind = null;
        if (self.eat('?')) {
            const k = self.peek() orelse return error.UnexpectedEnd;
            switch (k) {
                ':' => self.pos += 1,
                '=' => {
                    self.pos += 1;
                    look_kind = .ahead_pos;
                },
                '!' => {
                    self.pos += 1;
                    look_kind = .ahead_neg;
                },
                '<' => switch (self.peekAt(1) orelse return error.UnexpectedEnd) {
                    '=' => {
                        self.pos += 2;
                        look_kind = .behind_pos;
                    },
                    '!' => {
                        self.pos += 2;
                        look_kind = .behind_neg;
                    },
                    else => {
                        self.pos += 1; // '<'
                        capture_index = try self.parseGroupName('>');
                    },
                },
                'P' => {
                    self.pos += 1;
                    if (!self.eat('<')) return error.InvalidGroupName;
                    capture_index = try self.parseGroupName('>');
                },
                '\'' => {
                    self.pos += 1;
                    capture_index = try self.parseGroupName('\'');
                },
                'i', 'm', 's', '-' => return self.parseFlagGroup(depth),
                else => return error.UnsupportedFeature,
            }
        } else {
            if (self.group_count >= max_groups) return error.TooManyGroups;
            capture_index = self.group_count;
            self.group_count += 1;
        }
        // Inline flag changes inside a group are scoped to that group.
        const saved_flags = self.flags;
        const body = try self.parseAlternation(depth + 1);
        self.flags = saved_flags;
        if (!self.eat(')')) return error.UnbalancedParen;
        if (look_kind) |lk| {
            self.has_look = true;
            return self.addNode(.{ .look = .{ .child = body, .kind = lk } });
        }
        return self.addNode(.{ .group = .{ .child = body, .index = capture_index } });
    }

    /// Inline flags; `self.pos` is at the first flag letter after `(?`.
    ///
    /// `(?ims-ims)` mutates the current flags until the end of the enclosing
    /// group (PCRE semantics: the change crosses `|`). `(?ims-ims:...)` scopes
    /// the change to the parenthesized body.
    fn parseFlagGroup(self: *Self, depth: u32) ParseError!NodeIndex {
        var new_flags = self.flags;
        var clearing = false;
        var seen_letter = false;
        while (self.peek()) |c| {
            switch (c) {
                'i' => new_flags.case_insensitive = !clearing,
                'm' => new_flags.multiline = !clearing,
                's' => new_flags.dot_all = !clearing,
                '-' => {
                    if (clearing) return error.UnsupportedFeature;
                    clearing = true;
                    self.pos += 1;
                    continue;
                },
                ':' => {
                    self.pos += 1;
                    const saved = self.flags;
                    self.flags = new_flags;
                    const body = try self.parseAlternation(depth + 1);
                    self.flags = saved;
                    if (!self.eat(')')) return error.UnbalancedParen;
                    return self.addNode(.{ .group = .{ .child = body, .index = null } });
                },
                ')' => {
                    self.pos += 1;
                    if (!seen_letter) return error.UnsupportedFeature;
                    self.flags = new_flags;
                    // `(?i)*` etc.: nothing tangible to repeat.
                    if (self.peek()) |c2| switch (c2) {
                        '*', '+', '?' => return error.NothingToRepeat,
                        '{' => if (try self.scanBounds() != null) return error.NothingToRepeat,
                        else => {},
                    };
                    return self.addNode(.empty);
                },
                // 'x' (extended) and anything else are unsupported.
                else => return error.UnsupportedFeature,
            }
            seen_letter = true;
            self.pos += 1;
        }
        return error.UnexpectedEnd;
    }

    /// Parses a group name terminated by `term`, registers it, and returns the
    /// newly assigned capture index.
    fn parseGroupName(self: *Self, term: u8) ParseError!u8 {
        const start = self.pos;
        while (self.peek()) |c| {
            if (c == term) break;
            const ok = (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or
                (c >= '0' and c <= '9') or c == '_';
            if (!ok) return error.InvalidGroupName;
            self.pos += 1;
        }
        const name = self.pattern[start..self.pos];
        if (name.len == 0) return error.InvalidGroupName;
        if (name[0] >= '0' and name[0] <= '9') return error.InvalidGroupName;
        if (!self.eat(term)) return error.UnexpectedEnd;
        for (self.names[0..self.names_len]) |ng| {
            if (std.mem.eql(u8, ng.name, name)) return error.DuplicateGroupName;
        }
        if (self.group_count >= max_groups) return error.TooManyGroups;
        const index = self.group_count;
        self.group_count += 1;
        if (self.names_len >= self.names.len) return error.PatternTooComplex;
        self.names[self.names_len] = .{ .name = name, .index = index };
        self.names_len += 1;
        return index;
    }

    fn lookupName(self: *Self, name: []const u8) ?u8 {
        for (self.names[0..self.names_len]) |ng| {
            if (std.mem.eql(u8, ng.name, name)) return ng.index;
        }
        return null;
    }

    const Esc = union(enum) {
        literal: u21,
        class: Class,
        assertion: common.Assertion,
        backref: u8,
    };

    /// Parse an escape sequence; `self.pos` is at the backslash.
    fn parseEscape(self: *Self, in_class: bool) ParseError!Esc {
        self.pos += 1; // '\'
        const c = self.peek() orelse return error.UnexpectedEnd;
        self.pos += 1;
        switch (c) {
            'n' => return .{ .literal = 0x0A },
            'r' => return .{ .literal = 0x0D },
            't' => return .{ .literal = 0x09 },
            'f' => return .{ .literal = 0x0C },
            // In PCRE `\v` is the vertical whitespace class, not the vertical
            // tab -- Python and JavaScript are the ones that read it as a
            // character. `\h` has no other reading anywhere.
            'h' => return .{ .class = try self.shorthand(&hspace_ranges, false) },
            'H' => return .{ .class = try self.shorthand(&hspace_ranges, true) },
            'v' => return .{ .class = try self.shorthand(&vspace_ranges, false) },
            'V' => return .{ .class = try self.shorthand(&vspace_ranges, true) },
            'a' => return .{ .literal = 0x07 },
            'e' => return .{ .literal = 0x1B },
            '0' => return .{ .literal = self.parseOctal(0) },
            'd' => return .{ .class = try self.shorthand(&digit_ranges, false) },
            'D' => return .{ .class = try self.shorthand(&digit_ranges, true) },
            'w' => return .{ .class = try self.shorthand(&word_ranges, false) },
            'W' => return .{ .class = try self.shorthand(&word_ranges, true) },
            's' => return .{ .class = try self.shorthand(&space_ranges, false) },
            'S' => return .{ .class = try self.shorthand(&space_ranges, true) },
            'b' => {
                if (in_class) return .{ .literal = 0x08 };
                return .{ .assertion = .word_boundary };
            },
            'B' => {
                if (in_class) return error.InvalidEscape;
                return .{ .assertion = .not_word_boundary };
            },
            'A' => {
                if (in_class) return error.InvalidEscape;
                return .{ .assertion = .begin_text };
            },
            'z' => {
                if (in_class) return error.InvalidEscape;
                return .{ .assertion = .end_text };
            },
            'Z' => {
                if (in_class) return error.InvalidEscape;
                return .{ .assertion = .end_text_or_final_newline };
            },
            'x' => {
                if (self.peek() == '{') return .{ .literal = try self.parseBracedCodepoint() };
                return .{ .literal = try self.parseHex(2) };
            },
            'u' => {
                if (self.peek() == '{') return .{ .literal = try self.parseBracedCodepoint() };
                return .{ .literal = try self.parseHex(4) };
            },
            '1'...'9' => {
                // A digit escape is a backreference or an octal character,
                // and PCRE decides between them by the number itself. Inside
                // a class there are no backreferences, so it is always octal.
                if (!in_class) {
                    const after_first = self.pos;
                    var n: u32 = c - '0';
                    while (self.peek()) |d| {
                        if (d < '0' or d > '9') break;
                        // Far past any real group count; stop before this
                        // overflows on a long run of digits.
                        if (n > max_group_number) break;
                        n = n * 10 + (d - '0');
                        self.pos += 1;
                    }
                    // Under ten it is always a backreference, so naming a
                    // group that does not exist is an error rather than a
                    // character. At ten and above it is a backreference only
                    // when that many groups have been opened.
                    if (n < 10 or n < self.group_count) {
                        if (n >= self.group_count) return error.InvalidBackref;
                        self.has_backref = true;
                        return .{ .backref = @intCast(n) };
                    }
                    // Not a backreference after all: re-read the digits as an
                    // octal escape, which is what PCRE falls back to.
                    self.pos = after_first;
                }
                // 8 and 9 are not octal, so there is nothing to fall back to.
                if (c > '7') return error.InvalidBackref;
                return .{ .literal = self.parseOctal(@intCast(c - '0')) };
            },
            'k' => {
                if (in_class) return error.InvalidEscape;
                if (!self.eat('<')) return error.InvalidBackref;
                const start = self.pos;
                while (self.peek()) |c2| {
                    if (c2 == '>') break;
                    self.pos += 1;
                }
                const name = self.pattern[start..self.pos];
                if (!self.eat('>')) return error.UnexpectedEnd;
                const index = self.lookupName(name) orelse return error.InvalidBackref;
                self.has_backref = true;
                return .{ .backref = index };
            },
            'Q', 'E', 'c', 'p', 'P', 'G', 'K', 'R' => return error.UnsupportedFeature,
            else => {
                // Identity escape for punctuation; escaping a letter or digit
                // we don't know is an error (it may gain meaning later).
                if ((c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9'))
                    return error.InvalidEscape;
                // Multi-byte pattern character after backslash: decode it whole.
                self.pos -= 1;
                const d = common.decode(self.pattern, self.pos);
                self.pos += d.len;
                return .{ .literal = d.cp };
            },
        }
    }

    fn shorthand(self: *Self, rs: []const common.ClassRange, complement: bool) ParseError!Class {
        const start = self.ranges_len;
        // The complement is taken of a set that is already closed over case
        // -- `\w` holds both cases of every letter, `\d` and `\s` hold no
        // cased character at all -- and the complement of a closed set is
        // closed, so there is nothing to do on that side. Closing it *after*
        // complementing would be wrong: the Kelvin sign is a non-word
        // character, and pulling in its orbit would make `(?i)\W` match `k`.
        if (complement) try self.addComplement(rs) else try self.addRanges(rs);
        if (self.flags.case_insensitive and !complement) try self.caseCloseRanges(start);
        return .{
            .start = start,
            .len = self.ranges_len - start,
            .negated = false,
            .ci = false,
        };
    }

    /// Continue an octal escape whose first digit is already consumed and
    /// has value `first`, taking up to two more. PCRE reads at most three
    /// octal digits in total and leaves any further digits as literals.
    fn parseOctal(self: *Self, first: u21) u21 {
        var v = first;
        var digits: usize = 1;
        while (digits < 3) : (digits += 1) {
            const d = self.peek() orelse break;
            if (d < '0' or d > '7') break;
            v = v * 8 + @as(u21, d - '0');
            self.pos += 1;
        }
        return v;
    }

    fn parseHex(self: *Self, comptime n: usize) ParseError!u21 {
        if (self.pos + n > self.pattern.len) return error.InvalidEscape;
        var v: u32 = 0;
        for (self.pattern[self.pos..][0..n]) |c| {
            const d = std.fmt.charToDigit(c, 16) catch return error.InvalidEscape;
            v = v * 16 + d;
        }
        self.pos += n;
        if (v > max_codepoint) return error.InvalidCodepoint;
        return @intCast(v);
    }

    fn parseBracedCodepoint(self: *Self) ParseError!u21 {
        std.debug.assert(self.eat('{'));
        var v: u32 = 0;
        var digits: usize = 0;
        while (self.peek()) |c| {
            if (c == '}') break;
            const d = std.fmt.charToDigit(c, 16) catch return error.InvalidEscape;
            v = v * 16 + d;
            digits += 1;
            if (digits > 6 or v > max_codepoint) return error.InvalidCodepoint;
            self.pos += 1;
        }
        if (!self.eat('}')) return error.UnexpectedEnd;
        if (digits == 0) return error.InvalidEscape;
        return @intCast(v);
    }

    /// A single class member: either one codepoint or a shorthand set.
    const Member = union(enum) {
        cp: u21,
        set: void,
    };

    fn parseClassMember(self: *Self) ParseError!Member {
        if (self.peek() == '\\') {
            const esc = try self.parseEscape(true);
            switch (esc) {
                .literal => |cp| return .{ .cp = cp },
                .class => return .set, // ranges already appended
                else => unreachable,
            }
        }
        const d = common.decode(self.pattern, self.pos);
        self.pos += d.len;
        return .{ .cp = d.cp };
    }

    /// A POSIX bracket class, `[:name:]` or the negated `[:^name:]`, with
    /// `self.pos` at the opening `[`. Appends its ranges and reports whether
    /// one was there at all; a `[` that does not begin one is left alone, so
    /// `[[]` keeps reading it as the literal bracket PCRE makes it.
    fn parsePosixClass(self: *Self) ParseError!bool {
        if (self.peekAt(1) != ':') return false;
        var i = self.pos + 2;
        const complement = i < self.pattern.len and self.pattern[i] == '^';
        if (complement) i += 1;
        const name_start = i;
        // Anything up to the terminator is the name, rather than only the
        // letters a real one is spelled with, so that a near miss such as
        // `[[:DIGIT:]]` is the error PCRE makes it instead of quietly
        // becoming a set of the characters it is written with.
        while (i < self.pattern.len and self.pattern[i] != ':' and self.pattern[i] != ']') i += 1;
        // Needs the full `:]` terminator; without it this is not one, and
        // `[[:a]` stays the ordinary class PCRE reads it as.
        if (i + 1 >= self.pattern.len or self.pattern[i] != ':' or self.pattern[i + 1] != ']')
            return false;
        const name = self.pattern[name_start..i];
        for (posix_classes) |pc| {
            if (!std.mem.eql(u8, pc.name, name)) continue;
            const at = self.ranges_len;
            if (complement) {
                // Closes over case before complementing, which is the order
                // that makes `(?i)[[:^lower:]]` reject `a` and `A` alike.
                try self.addAsciiComplement(pc.ranges, self.flags.case_insensitive);
            } else {
                try self.addRanges(pc.ranges);
                if (self.flags.case_insensitive) try self.caseCloseRanges(at);
            }
            self.pos = i + 2;
            return true;
        }
        // Well-formed but not a class anyone defines. PCRE rejects it rather
        // than falling back to reading the characters literally.
        return error.InvalidClass;
    }

    fn parseClass(self: *Self) ParseError!NodeIndex {
        self.pos += 1; // '['
        const negated = self.eat('^');
        const start = self.ranges_len;
        // ']' as the very first member is a literal (PCRE behavior) -- and
        // an ordinary member in every other way, so it may open a range:
        // `[]-b]` runs from ']' to 'b', which takes in the letter 'a'.
        // Adding it as a finished member instead read that class as the
        // three characters ']', '-', 'b'.
        if (self.eat(']')) {
            if (self.peek() == '-' and self.peekAt(1) != null and self.peekAt(1) != ']') {
                self.pos += 1; // '-'
                switch (try self.parseClassMember()) {
                    .set => return error.InvalidClass,
                    .cp => |hi| {
                        if (']' > hi) return error.InvalidClass;
                        try self.addRange(']', hi);
                    },
                }
            } else {
                try self.addRange(']', ']');
            }
            if (self.flags.case_insensitive) try self.caseCloseRanges(start);
        }
        while (true) {
            const c = self.peek() orelse return error.InvalidClass;
            if (c == ']') {
                self.pos += 1;
                break;
            }
            // Checked before the member below, which would otherwise take the
            // `[` for a literal and the rest for individual characters.
            if (c == '[' and try self.parsePosixClass()) continue;
            // Each member is closed over case on its own. Closing the class
            // as a whole would also close any complement a member brought in
            // -- `[\W]`, `[[:^lower:]]` -- and the complement of a closed set
            // is already closed, so re-closing it can only add what belongs
            // outside. The union of closed sets is closed, so this is enough,
            // and the `[^...]` negation is then applied to a closed set.
            const member_start = self.ranges_len;
            const m1 = try self.parseClassMember();
            switch (m1) {
                // A shorthand or POSIX class closed itself as it was added.
                .set => continue,
                .cp => |lo| {
                    // Try to form a range: `lo-hi`, where '-' is not final.
                    if (self.peek() == '-' and self.peekAt(1) != null and self.peekAt(1) != ']') {
                        self.pos += 1; // '-'
                        const m2 = try self.parseClassMember();
                        switch (m2) {
                            .set => return error.InvalidClass,
                            .cp => |hi| {
                                if (lo > hi) return error.InvalidClass;
                                try self.addRange(lo, hi);
                            },
                        }
                    } else {
                        try self.addRange(lo, lo);
                    }
                    if (self.flags.case_insensitive) try self.caseCloseRanges(member_start);
                },
            }
        }
        return self.addNode(.{ .class = .{
            .start = start,
            .len = self.ranges_len - start,
            .negated = negated,
            .ci = false,
        } });
    }
};

// ---------------------------------------------------------------------------
// Tests

const TestBufs = struct {
    nodes: [512]Node = undefined,
    ranges: [1024]common.ClassRange = undefined,
    names: [max_groups]NamedGroup = undefined,

    fn parser(self: *TestBufs, pattern: []const u8, flags: common.Flags) Parser {
        return .{
            .pattern = pattern,
            .flags = flags,
            .nodes = &self.nodes,
            .ranges = &self.ranges,
            .names = &self.names,
        };
    }
};

fn expectParses(pattern: []const u8) !void {
    var bufs = TestBufs{};
    var p = bufs.parser(pattern, .{});
    _ = try p.parse();
}

fn expectParseError(expected: ParseError, pattern: []const u8) !void {
    var bufs = TestBufs{};
    var p = bufs.parser(pattern, .{});
    try std.testing.expectError(expected, p.parse());
}

test "parses valid patterns" {
    try expectParses("");
    try expectParses("abc");
    try expectParses("a|b|c");
    try expectParses("a*b+c?d{2,3}e{4}f{5,}");
    try expectParses("a*?b+?c??");
    try expectParses("(a(b(c)))");
    try expectParses("(?:ab)+");
    try expectParses("(?<year>\\d{4})-(?<month>\\d{2})");
    try expectParses("(?P<x>a)\\k<x>");
    try expectParses("[a-z0-9_]");
    try expectParses("[^\\d\\s]");
    try expectParses("[]a]");
    try expectParses("[-a]");
    try expectParses("[a-]");
    try expectParses("\\x41\\x{1F600}\\u0041\\u{41}");
    try expectParses("^ab$\\bx\\B\\Ay\\z\\Z");
    try expectParses("(a)\\1");
    try expectParses("(?=a)(?!b)(?<=c)(?<!d)");
    try expectParses("a{b}");
    try expectParses("héllo•");
    try expectParses("||");
    try expectParses("(?i)abc");
    try expectParses("(?ims-i)abc");
    try expectParses("(?i:a(?-i:b))c");
    try expectParses("(?-i)a");
}

test "inline flags scope to the enclosing group" {
    var bufs = TestBufs{};
    var p = bufs.parser("a(x(?i)b)c", .{});
    _ = try p.parse();
    // Nodes are appended in parse order: 'a' and 'c' outside the group stay
    // case-sensitive, 'b' after (?i) is not; the flag reset at ')'.
    var lits: [8]Literal = undefined;
    var n: usize = 0;
    for (p.nodes[0..p.nodes_len]) |node| {
        if (node == .literal) {
            lits[n] = node.literal;
            n += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 4), n);
    try std.testing.expect(!lits[0].ci); // a
    try std.testing.expect(!lits[1].ci); // x
    try std.testing.expect(lits[2].ci); // b
    try std.testing.expect(!lits[3].ci); // c
}

test "a caseless letter with a non-ASCII case becomes a class" {
    // `b` matches only `B` and `b`, both ASCII, so it stays a literal that
    // folds -- the cheap representation every engine already had. `s` also
    // matches the long s (U+017F) and `k` the Kelvin sign (U+212A), which
    // folding a single byte cannot express, so those become the class of
    // their case-equivalent codepoints instead.
    const cases = [_]struct { pat: []const u8, members: []const u21 }{
        .{ .pat = "(?i)b", .members = &.{} },
        .{ .pat = "(?i)s", .members = &.{ 'S', 's', 0x17F } },
        .{ .pat = "(?i)k", .members = &.{ 'K', 'k', 0x212A } },
    };
    for (cases) |c| {
        var bufs = TestBufs{};
        var p = bufs.parser(c.pat, .{});
        _ = try p.parse();
        var found: ?Class = null;
        for (p.nodes[0..p.nodes_len]) |node| {
            if (node == .class) found = node.class;
        }
        if (c.members.len == 0) {
            try std.testing.expect(found == null);
            continue;
        }
        const cl = found orelse return error.TestUnexpectedResult;
        const ranges = p.ranges[cl.start..][0..cl.len];
        try std.testing.expectEqual(c.members.len, ranges.len);
        for (c.members, ranges) |want, r| {
            try std.testing.expectEqual(want, r.lo);
            try std.testing.expectEqual(want, r.hi);
        }
    }
}

test "rejects invalid patterns" {
    try expectParseError(error.NothingToRepeat, "*a");
    try expectParseError(error.NothingToRepeat, "{2}");
    try expectParseError(error.InvalidRepeat, "a**");
    try expectParseError(error.InvalidRepeat, "a*+");
    try expectParseError(error.InvalidRepeat, "a{3,2}");
    try expectParseError(error.RepeatTooLarge, "a{1001}");
    try expectParseError(error.UnbalancedParen, "(a");
    try expectParseError(error.UnbalancedParen, "a)");
    try expectParseError(error.InvalidClass, "[a");
    try expectParseError(error.InvalidClass, "[z-a]");
    try expectParseError(error.InvalidEscape, "\\q");
    try expectParseError(error.InvalidBackref, "\\1");
    try expectParseError(error.InvalidBackref, "(a)\\2");
    try expectParseError(error.DuplicateGroupName, "(?<x>a)(?<x>b)");
    try expectParseError(error.UnsupportedFeature, "(?x)a");
    try expectParseError(error.UnsupportedFeature, "(?)a");
    try expectParseError(error.UnsupportedFeature, "(?i-m-s)a");
    try expectParseError(error.NothingToRepeat, "a(?i)*");
    try expectParseError(error.UnexpectedEnd, "(?im");
    try expectParseError(error.UnexpectedEnd, "a\\");
    try expectParseError(error.InvalidCodepoint, "\\x{110000}");
}

test "quantifier-shaped braces are quantifiers, others are literal" {
    var bufs = TestBufs{};
    var p = bufs.parser("a{2,3}", .{});
    const root = try p.parse();
    try std.testing.expect(p.nodes[root] == .repeat);
    try std.testing.expectEqual(@as(u32, 2), p.nodes[root].repeat.min);
    try std.testing.expectEqual(@as(?u32, 3), p.nodes[root].repeat.max);

    var bufs2 = TestBufs{};
    var p2 = bufs2.parser("a{x}", .{});
    _ = try p2.parse(); // '{', 'x', '}' become literals
    try std.testing.expect(!p2.has_backref);
}

test "backref and look detection" {
    var bufs = TestBufs{};
    var p = bufs.parser("(a)\\1", .{});
    _ = try p.parse();
    try std.testing.expect(p.has_backref);
    try std.testing.expect(!p.has_look);

    var bufs2 = TestBufs{};
    var p2 = bufs2.parser("(?=a)b", .{});
    _ = try p2.parse();
    try std.testing.expect(p2.has_look);
}
