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

pub const max_codepoint: u21 = 0x10FFFF;
/// Upper bound for `{n,m}` repeat counts (mirrors RE2's limit).
pub const max_repeat: u32 = 1000;
/// Maximum capture groups including group 0 (the whole match).
pub const max_groups: u8 = 100;
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
pub fn bufferSizes(pattern_len: usize) BufferSizes {
    return .{
        .nodes = 2 * pattern_len + 16,
        .ranges = 4 * pattern_len + 16,
        .names = max_groups,
    };
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

    fn addRange(self: *Self, lo: u21, hi: u21) ParseError!void {
        if (self.ranges_len >= self.ranges.len) return error.PatternTooComplex;
        self.ranges[self.ranges_len] = .{ .lo = lo, .hi = hi };
        self.ranges_len += 1;
    }

    fn addRanges(self: *Self, rs: []const common.ClassRange) ParseError!void {
        for (rs) |r| try self.addRange(r.lo, r.hi);
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

    fn parseAlternation(self: *Self, depth: u32) ParseError!NodeIndex {
        if (depth > max_depth) return error.NestingTooDeep;
        var node = try self.parseConcat(depth);
        while (self.eat('|')) {
            const rhs = try self.parseConcat(depth);
            node = try self.addNode(.{ .alt = .{ node, rhs } });
        }
        return node;
    }

    fn parseConcat(self: *Self, depth: u32) ParseError!NodeIndex {
        var seq: ?NodeIndex = null;
        while (self.peek()) |c| {
            if (c == '|' or c == ')') break;
            switch (c) {
                '*', '+', '?' => return error.NothingToRepeat,
                '{' => if (try self.scanBounds() != null) return error.NothingToRepeat,
                else => {},
            }
            var atom = try self.parseAtom(depth);
            atom = try self.parseQuantifier(atom);
            seq = if (seq) |s| try self.addNode(.{ .concat = .{ s, atom } }) else atom;
        }
        return seq orelse try self.addNode(.empty);
    }

    const Bounds = struct { min: u32, max: ?u32, next: usize };

    /// Pure lookahead at `self.pos` (which must be '{'). Returns null when the
    /// text is not quantifier-shaped (then '{' is a literal, PCRE-style).
    fn scanBounds(self: *Self) ParseError!?Bounds {
        var i = self.pos + 1;
        const pat = self.pattern;
        var min: u32 = 0;
        var digits: usize = 0;
        while (i < pat.len and pat[i] >= '0' and pat[i] <= '9') : (i += 1) {
            min = min * 10 + (pat[i] - '0');
            digits += 1;
            if (min > max_repeat) return error.RepeatTooLarge;
        }
        if (digits == 0) return null;
        var max: ?u32 = min;
        if (i < pat.len and pat[i] == ',') {
            i += 1;
            if (i < pat.len and pat[i] == '}') {
                max = null;
            } else {
                var m: u32 = 0;
                digits = 0;
                while (i < pat.len and pat[i] >= '0' and pat[i] <= '9') : (i += 1) {
                    m = m * 10 + (pat[i] - '0');
                    digits += 1;
                    if (m > max_repeat) return error.RepeatTooLarge;
                }
                if (digits == 0) return null;
                max = m;
            }
        }
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
                    .literal => |cp| self.addNode(.{ .literal = .{
                        .cp = cp,
                        .ci = self.flags.case_insensitive,
                    } }),
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
                return self.addNode(.{ .literal = .{
                    .cp = d.cp,
                    .ci = self.flags.case_insensitive,
                } });
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
            'v' => return .{ .literal = 0x0B },
            'a' => return .{ .literal = 0x07 },
            'e' => return .{ .literal = 0x1B },
            '0' => return .{ .literal = 0x00 },
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
                if (in_class) return error.InvalidEscape;
                var n: u32 = c - '0';
                if (self.peek()) |c2| {
                    if (c2 >= '0' and c2 <= '9') {
                        n = n * 10 + (c2 - '0');
                        self.pos += 1;
                    }
                }
                if (n >= self.group_count) return error.InvalidBackref;
                self.has_backref = true;
                return .{ .backref = @intCast(n) };
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
        if (complement) try self.addComplement(rs) else try self.addRanges(rs);
        return .{
            .start = start,
            .len = self.ranges_len - start,
            .negated = false,
            .ci = self.flags.case_insensitive,
        };
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

    fn parseClass(self: *Self) ParseError!NodeIndex {
        self.pos += 1; // '['
        const negated = self.eat('^');
        const start = self.ranges_len;
        // ']' as the very first member is a literal (PCRE behavior).
        if (self.eat(']')) try self.addRange(']', ']');
        while (true) {
            const c = self.peek() orelse return error.InvalidClass;
            if (c == ']') {
                self.pos += 1;
                break;
            }
            const m1 = try self.parseClassMember();
            switch (m1) {
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
                },
            }
        }
        return self.addNode(.{ .class = .{
            .start = start,
            .len = self.ranges_len - start,
            .negated = negated,
            .ci = self.flags.case_insensitive,
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
