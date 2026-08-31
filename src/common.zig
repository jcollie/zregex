// SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

//! Shared types and helpers used by the parser, compiler, and both engines.
const std = @import("std");
const expect = std.testing.expect;

/// Compile-time flags affecting pattern semantics.
pub const Flags = struct {
    /// ASCII case-insensitive matching.
    case_insensitive: bool = false,
    /// `^`/`$` match at line boundaries in addition to text boundaries.
    multiline: bool = false,
    /// `.` also matches `\n`.
    dot_all: bool = false,
};

/// An inclusive codepoint range, the building block of character classes.
pub const ClassRange = struct {
    lo: u21,
    hi: u21,
};

/// Zero-width assertions.
pub const Assertion = enum {
    begin_text,
    end_text,
    /// End of text, or just before a newline that ends it: what `$` means
    /// outside multiline mode, and what `\Z` always means.
    end_text_or_final_newline,
    begin_line,
    end_line,
    word_boundary,
    not_word_boundary,
};

pub const DecodeResult = struct {
    cp: u21,
    len: u3,
};

/// Decode the codepoint starting at `pos`. Invalid UTF-8 degrades to a
/// single-byte codepoint (latin-1 style) so matching never fails mid-haystack.
pub fn decode(input: []const u8, pos: usize) DecodeResult {
    const b = input[pos];
    if (b < 0x80) return .{ .cp = b, .len = 1 }; // ASCII fast path
    const len = std.unicode.utf8ByteSequenceLength(b) catch return .{ .cp = b, .len = 1 };
    if (pos + len > input.len) return .{ .cp = b, .len = 1 };
    const cp = std.unicode.utf8Decode(input[pos..][0..len]) catch return .{ .cp = b, .len = 1 };
    return .{ .cp = cp, .len = @intCast(len) };
}

/// Decode the codepoint that ends exactly at `pos` (i.e. the one before it).
/// Uses the same single-byte fallback as `decode`.
pub fn decodeBefore(input: []const u8, pos: usize) DecodeResult {
    std.debug.assert(pos > 0);
    const last = input[pos - 1];
    if (last < 0x80) return .{ .cp = last, .len = 1 }; // ASCII fast path
    var n: usize = 1;
    while (n <= 4 and n <= pos) : (n += 1) {
        const start = pos - n;
        const b = input[start];
        // Look for a lead byte whose sequence length is exactly n.
        const len = std.unicode.utf8ByteSequenceLength(b) catch continue;
        if (len != n) continue;
        const cp = std.unicode.utf8Decode(input[start..pos]) catch break;
        return .{ .cp = cp, .len = @intCast(n) };
    }
    return .{ .cp = input[pos - 1], .len = 1 };
}

/// `\w` semantics: ASCII word character.
pub fn isWordChar(cp: u21) bool {
    return switch (cp) {
        'a'...'z', 'A'...'Z', '0'...'9', '_' => true,
        else => false,
    };
}

/// ASCII-only lowercase fold.
pub fn foldLower(cp: u21) u21 {
    return if (cp >= 'A' and cp <= 'Z') cp + 32 else cp;
}

/// Codepoint equality, optionally ASCII case-insensitive.
pub fn charEq(a: u21, b: u21, ci: bool) bool {
    if (a == b) return true;
    return ci and foldLower(a) == foldLower(b);
}

fn inRanges(ranges: []const ClassRange, cp: u21) bool {
    for (ranges) |r| {
        if (cp >= r.lo and cp <= r.hi) return true;
    }
    return false;
}

/// Class membership test, honoring negation and ASCII case folding.
pub fn classMatches(ranges: []const ClassRange, negated: bool, ci: bool, cp: u21) bool {
    var hit = inRanges(ranges, cp);
    if (!hit and ci) {
        // Try the other ASCII case of `cp`.
        if (cp >= 'A' and cp <= 'Z') {
            hit = inRanges(ranges, cp + 32);
        } else if (cp >= 'a' and cp <= 'z') {
            hit = inRanges(ranges, cp - 32);
        }
    }
    return hit != negated;
}

/// Evaluate a zero-width assertion at byte offset `pos` of `input`.
pub fn assertHolds(a: Assertion, input: []const u8, pos: usize) bool {
    switch (a) {
        .begin_text => return pos == 0,
        .end_text => return pos == input.len,
        .end_text_or_final_newline => {
            if (pos == input.len) return true;
            return pos + 1 == input.len and input[pos] == '\n';
        },
        .begin_line => {
            if (pos == 0) return true;
            return input[pos - 1] == '\n';
        },
        .end_line => {
            if (pos == input.len) return true;
            return input[pos] == '\n';
        },
        .word_boundary, .not_word_boundary => {
            const before = pos > 0 and isWordChar(decodeBefore(input, pos).cp);
            const after = pos < input.len and isWordChar(decode(input, pos).cp);
            const boundary = before != after;
            return if (a == .word_boundary) boundary else !boundary;
        },
    }
}

test decode {
    const s = "aé€x";
    try std.testing.expectEqual(DecodeResult{ .cp = 'a', .len = 1 }, decode(s, 0));
    try std.testing.expectEqual(DecodeResult{ .cp = 'é', .len = 2 }, decode(s, 1));
    try std.testing.expectEqual(DecodeResult{ .cp = '€', .len = 3 }, decode(s, 3));
    // Invalid byte falls back to a 1-byte codepoint.
    try std.testing.expectEqual(DecodeResult{ .cp = 0xff, .len = 1 }, decode("\xff\xfe", 0));
}

test decodeBefore {
    const s = "aé€x";
    try std.testing.expectEqual(DecodeResult{ .cp = 'a', .len = 1 }, decodeBefore(s, 1));
    try std.testing.expectEqual(DecodeResult{ .cp = 'é', .len = 2 }, decodeBefore(s, 3));
    try std.testing.expectEqual(DecodeResult{ .cp = '€', .len = 3 }, decodeBefore(s, 6));
    try std.testing.expectEqual(DecodeResult{ .cp = 'x', .len = 1 }, decodeBefore(s, 7));
}

test "end of text, with and without a final newline" {
    try expect(assertHolds(.end_text, "ab", 2));
    try expect(!assertHolds(.end_text, "ab\n", 2));
    // `$` also matches before a newline that ends the text, but only there.
    try expect(assertHolds(.end_text_or_final_newline, "ab", 2));
    try expect(assertHolds(.end_text_or_final_newline, "ab\n", 2));
    try expect(assertHolds(.end_text_or_final_newline, "ab\n", 3));
    try expect(!assertHolds(.end_text_or_final_newline, "a\nb", 1));
    try expect(!assertHolds(.end_text_or_final_newline, "ab\n\n", 2));
}

test assertHolds {
    try std.testing.expect(assertHolds(.begin_text, "ab", 0));
    try std.testing.expect(!assertHolds(.begin_text, "ab", 1));
    try std.testing.expect(assertHolds(.end_text, "ab", 2));
    try std.testing.expect(assertHolds(.begin_line, "a\nb", 2));
    try std.testing.expect(assertHolds(.end_line, "a\nb", 1));
    try std.testing.expect(assertHolds(.word_boundary, "ab cd", 2));
    try std.testing.expect(assertHolds(.word_boundary, "ab", 0));
    try std.testing.expect(assertHolds(.not_word_boundary, "ab", 1));
}
