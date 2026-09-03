// SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

//! Behavior tests exercising the full pipeline through all four engines.
const std = @import("std");
const zregex = @import("root.zig");
const Regex = zregex.Regex;

const gpa = std.testing.allocator;

/// Compile, find, and check the text of the whole match (null = no match).
fn expectFind(pattern: []const u8, haystack: []const u8, expected: ?[]const u8) !void {
    var re = try Regex.compile(gpa, pattern);
    defer re.deinit();
    var m = (try re.find(gpa, haystack)) orelse {
        try std.testing.expectEqual(@as(?[]const u8, null), expected);
        return;
    };
    defer m.deinit(gpa);
    try std.testing.expect(expected != null);
    try std.testing.expectEqualStrings(expected.?, m.span().slice(haystack));
}

/// Compile, find, and check each capture group's text (index 0 first).
fn expectGroups(pattern: []const u8, haystack: []const u8, expected: []const ?[]const u8) !void {
    var re = try Regex.compile(gpa, pattern);
    defer re.deinit();
    var m = (try re.find(gpa, haystack)).?;
    defer m.deinit(gpa);
    try std.testing.expectEqual(expected.len, m.groups.len);
    for (expected, 0..) |e, i| {
        if (e) |text| {
            try std.testing.expect(m.groups[i] != null);
            try std.testing.expectEqualStrings(text, m.groups[i].?.slice(haystack));
        } else {
            try std.testing.expectEqual(@as(?zregex.Span, null), m.groups[i]);
        }
    }
}

test "literals and alternation" {
    try expectFind("abc", "xxabcxx", "abc");
    try expectFind("abc", "xxabxx", null);
    try expectFind("cat|dog", "hotdog", "dog");
    try expectFind("cat|dog", "catalog", "cat");
    try expectFind("", "anything", "");
}

test "leftmost-greedy semantics" {
    try expectFind("a+", "caaat", "aaa");
    try expectFind("a|ab", "ab", "a"); // alternation prefers the left branch
    try expectFind("<.+>", "<a><b>", "<a><b>");
    try expectFind("<.+?>", "<a><b>", "<a>");
}

test "quantifiers" {
    try expectFind("ab*c", "ac", "ac");
    try expectFind("ab*c", "abbbc", "abbbc");
    try expectFind("ab+c", "ac", null);
    try expectFind("ab?c", "abc", "abc");
    try expectFind("a{3}", "aaaa", "aaa");
    try expectFind("a{2,3}", "aaaa", "aaa");
    try expectFind("a{2,3}?", "aaaa", "aa");
    try expectFind("a{2,}", "aaaa", "aaaa");
    try expectFind("a{4,}", "aaa", null);
}

test "character classes" {
    try expectFind("[abc]+", "xcabz", "cab");
    try expectFind("[^abc]+", "abxyzca", "xyz");
    try expectFind("[a-fA-F0-9]+", "xDEADbeef9!", "DEADbeef9");
    try expectFind("[]x]+", "ax]x", "x]x"); // leading ] is literal
    try expectFind("[a-]+", "b-a-", "-a-");
    try expectFind("\\d+", "abc123def", "123");
    try expectFind("\\D+", "12abc34", "abc");
    try expectFind("\\w+", "!hi_there2!", "hi_there2");
    try expectFind("\\s+", "a \t\nb", " \t\n");
    try expectFind("[\\d\\s]+", "a1 2b", "1 2");
    try expectFind("[^\\S]+", "ab cd", " ");
}

test "anchors and boundaries" {
    try expectFind("^abc", "abcdef", "abc");
    try expectFind("^bcd", "abcdef", null);
    try expectFind("def$", "abcdef", "def");
    try expectFind("cde$", "abcdef", null);
    try expectFind("^$", "", "");
    try expectFind("\\bcat\\b", "a cat sat", "cat");
    try expectFind("\\bcat\\b", "concatenate", null);
    try expectFind("\\Bcat\\B", "concatenate", "cat");
    try expectFind("\\Aab", "abc", "ab");
    try expectFind("bc\\z", "abc", "bc");
    // `$` also matches before a newline ending the text; `\z` never does,
    // and `\Z` always does. One trailing newline only.
    try expectFind("bc$", "abc\n", "bc");
    try expectFind("bc$", "abc\n\n", null);
    try expectFind("bc\\z", "abc\n", null);
    try expectFind("bc\\Z", "abc\n", "bc");
    try expectFind("bc\\Z", "abc", "bc");
    try expectFind("^$", "\n", "");
    try expectFind("c$", "abc", "c");
}

test "captures" {
    try expectGroups("(\\w+)@(\\w+)", "mail me: jeff@example now", &.{ "jeff@example", "jeff", "example" });
    try expectGroups("(a(b)c)d", "abcd", &.{ "abcd", "abc", "b" });
    try expectGroups("(a)|(b)", "b", &.{ "b", null, "b" });
    try expectGroups("(a)?b", "b", &.{ "b", null });
    try expectGroups("(?:ab)+(c)", "ababc", &.{ "ababc", "c" });
    // Captures persist across repeat iterations (PCRE semantics, not JS):
    // group 1 keeps "a" from the first iteration.
    try expectGroups("(?:(a)|(b))+", "ab", &.{ "ab", "a", "b" });
}

test "named groups" {
    var re = try Regex.compile(gpa, "(?<year>\\d{4})-(?<month>\\d{2})");
    defer re.deinit();
    try std.testing.expectEqual(@as(?u8, 1), re.groupIndex("year"));
    try std.testing.expectEqual(@as(?u8, 2), re.groupIndex("month"));
    try std.testing.expectEqual(@as(?u8, null), re.groupIndex("day"));
    var m = (try re.find(gpa, "on 2026-08-30 we")).?;
    defer m.deinit(gpa);
    try std.testing.expectEqualStrings("2026", m.group(re.groupIndex("year").?).?.slice("on 2026-08-30 we"));
}

test "utf-8 semantics" {
    try expectFind("h.llo", "xhéllo", "héllo"); // . is one codepoint
    try expectFind("é+", "aééb", "éé");
    try expectFind("[à-ö]+", "xàéöy", "àéö");
    try expectFind("héllo", "say héllo!", "héllo");
    try expectFind("\\x{1F600}+", "hi😀😀!", "😀😀");
    try expectGroups("(.)(.)", "é€x", &.{ "é€", "é", "€" });
}

test "flags" {
    var re = try Regex.compileWithFlags(gpa, "hello", .{ .case_insensitive = true });
    defer re.deinit();
    try std.testing.expect(try re.isMatch(gpa, "say HeLLo"));

    var re2 = try Regex.compileWithFlags(gpa, "^b$", .{ .multiline = true });
    defer re2.deinit();
    try std.testing.expect(try re2.isMatch(gpa, "a\nb\nc"));
    var re3 = try Regex.compile(gpa, "^b$");
    defer re3.deinit();
    try std.testing.expect(!try re3.isMatch(gpa, "a\nb\nc"));

    var re4 = try Regex.compileWithFlags(gpa, "a.b", .{ .dot_all = true });
    defer re4.deinit();
    try std.testing.expect(try re4.isMatch(gpa, "a\nb"));
    var re5 = try Regex.compile(gpa, "a.b");
    defer re5.deinit();
    try std.testing.expect(!try re5.isMatch(gpa, "a\nb"));

    var re6 = try Regex.compileWithFlags(gpa, "[a-z]+", .{ .case_insensitive = true });
    defer re6.deinit();
    try std.testing.expect(try re6.isMatch(gpa, "ABC"));
}

test "inline flags" {
    try expectFind("(?i)hello", "say HeLLo", "HeLLo");
    try expectFind("(?i)[a-z]+", "ABC", "ABC");
    // Takes effect mid-pattern...
    try expectFind("a(?i)b", "aB", "aB");
    try expectFind("a(?i)b", "Ab", null);
    // ...and is scoped to the enclosing group.
    try expectFind("(a(?i)b)c", "aBc", "aBc");
    try expectFind("(a(?i)b)c", "aBC", null);
    try expectFind("(?i:ab)c", "ABc", "ABc");
    try expectFind("(?i:a(?-i:b))", "Ab", "Ab");
    try expectFind("(?i:a(?-i:b))", "AB", null);
    // Persists across | until the group ends (PCRE semantics).
    try expectFind("(?:x(?i)a|b)", "B", "B");
    // m and s.
    try expectFind("(?m)^b$", "a\nb\nc", "b");
    try expectFind("(?s)a.b", "a\nb", "a\nb");
    try expectFind("(?s:a.)b", "a\nb", "a\nb");
    try expectFind("a.(?s)b", "a\nb", null); // too late for the earlier dot

    // Clearing a flag set via compileWithFlags.
    var re = try Regex.compileWithFlags(gpa, "a(?-i)b", .{ .case_insensitive = true });
    defer re.deinit();
    try std.testing.expect(try re.isMatch(gpa, "Ab"));
    try std.testing.expect(!try re.isMatch(gpa, "aB"));

    // Case-insensitive backreference comparison.
    try expectFind("(?i)(abc)-\\1", "xABc-abCx", "ABc-abC");
    var re2 = try Regex.compile(gpa, "(abc)-(?i)\\1");
    defer re2.deinit();
    try std.testing.expect(try re2.isMatch(gpa, "abc-ABC"));
}

test "inline flags at comptime" {
    const re = comptime Regex.compileComptime("(?i)h(?-i:ell)o");
    try std.testing.expect(try re.isMatch(gpa, "HellO"));
    try std.testing.expect(!try re.isMatch(gpa, "hELLo"));
}

test "engine selection" {
    var re = try Regex.compile(gpa, "a+b");
    defer re.deinit();
    try std.testing.expectEqual(zregex.Engine.pike, re.fallback_engine);
    var re2 = try Regex.compile(gpa, "(a)\\1");
    defer re2.deinit();
    try std.testing.expectEqual(zregex.Engine.backtrack, re2.fallback_engine);
    var re3 = try Regex.compile(gpa, "(?=a)b");
    defer re3.deinit();
    try std.testing.expectEqual(zregex.Engine.backtrack, re3.fallback_engine);
}

test "backreferences" {
    try expectFind("(a+)\\1", "aaaa", "aaaa");
    try expectFind("(a+)\\1", "aba", null);
    try expectGroups("(\\w+) \\1", "say ho ho!", &.{ "ho ho", "ho" });
    try expectFind("(?<q>['\"]).*?\\k<q>", "say \"hi' there\" ok", "\"hi' there\"");
    // A backreference to a group that never participated fails, as in PCRE.
    try expectFind("(?:(a)|b)\\1c", "bc", null);
    try expectFind("(a)?\\1b", "b", null);
    try expectFind("(a)\\1b", "aab", "aab"); // it does participate here
}

test "lookaround" {
    try expectFind("\\w+(?=!)", "hey you! there", "you");
    try expectFind("\\w+(?=!)", "hey you there", null);
    try expectFind("a(?!b)", "ab ac", "a");
    try expectGroups("(?<=\\$)(\\d+)", "cost: $42 now", &.{ "42", "42" });
    try expectFind("(?<!\\$)\\b\\d+", "$42 43", "43");
    // Variable-length lookbehind.
    try expectFind("(?<=ab+)c", "abbbc", "c");
    try expectFind("(?<=ab+)c", "ac", null);
}

test "no catastrophic backtracking without backrefs" {
    // Classic blowup pattern; on the Pike VM this is linear and just fails.
    var re = try Regex.compile(gpa, "(a+)+$");
    defer re.deinit();
    try std.testing.expectEqual(zregex.Engine.pike, re.fallback_engine);
    const haystack = "a" ** 60 ++ "b";
    try std.testing.expect(!try re.isMatch(gpa, haystack));
}

test "empty-body loops terminate" {
    try expectFind("(?:a*)*b", "aaab", "aaab");
    try expectFind("(?:a*)*b", "ccc", null);
    try expectFind("(a*)*b", "aab", "aab");
    try expectFind("(|a)*b", "aab", "aab");
    // Same shapes through the backtracker (lookahead forces it).
    try expectFind("(?=a)(?:a*)*b", "aaab", "aaab");
    try expectFind("(?=x)(x*)*y", "xxy", "xxy");
}

test "step limit" {
    var re = try Regex.compile(gpa, "(a+)+\\1$");
    defer re.deinit();
    try std.testing.expectEqual(zregex.Engine.backtrack, re.fallback_engine);
    re.max_steps = 1000;
    const haystack = "a" ** 40 ++ "b";
    try std.testing.expectError(error.StepLimitExceeded, re.isMatch(gpa, haystack));
}

test "iterator" {
    var re = try Regex.compile(gpa, "\\d+");
    defer re.deinit();
    const haystack = "a1b22c333";
    var it = re.iterator(gpa, haystack);
    defer it.deinit();
    const expected = [_][]const u8{ "1", "22", "333" };
    for (expected) |e| {
        var m = (try it.next()).?;
        defer m.deinit(gpa);
        try std.testing.expectEqualStrings(e, m.span().slice(haystack));
    }
    try std.testing.expectEqual(@as(?zregex.Match, null), try it.next());
    try std.testing.expectEqual(@as(?zregex.Match, null), try it.next());
}

test "iterator with empty matches" {
    var re = try Regex.compile(gpa, "a*");
    defer re.deinit();
    const haystack = "baa";
    var it = re.iterator(gpa, haystack);
    defer it.deinit();
    var spans: std.ArrayList(zregex.Span) = .empty;
    defer spans.deinit(gpa);
    while (try it.next()) |m| {
        var mm = m;
        defer mm.deinit(gpa);
        try spans.append(gpa, mm.span());
    }
    // Empty at 0, "aa" at 1, empty at end.
    try std.testing.expectEqualSlices(zregex.Span, &.{
        .{ .start = 0, .end = 0 },
        .{ .start = 1, .end = 3 },
        .{ .start = 3, .end = 3 },
    }, spans.items);
}

test "comptime compilation" {
    const re = comptime Regex.compileComptime("(\\d{3})-(\\d{4})");
    try std.testing.expectEqual(zregex.Engine.pike, re.fallback_engine);
    var m = (try re.find(gpa, "call 555-0199 now")).?;
    defer m.deinit(gpa);
    try std.testing.expectEqualStrings("555-0199", m.span().slice("call 555-0199 now"));
    try std.testing.expectEqualStrings("555", m.groups[1].?.slice("call 555-0199 now"));
    // deinit on a comptime-compiled regex is a safe no-op.
    var copy = re;
    copy.deinit();
}

test "comptime compilation with flags, names, and backtracking features" {
    const re = comptime Regex.compileComptimeWithFlags(
        "(?<word>\\w+) \\k<word>",
        .{ .case_insensitive = true },
    );
    try std.testing.expectEqual(zregex.Engine.backtrack, re.fallback_engine);
    try std.testing.expectEqual(@as(?u8, 1), re.groupIndex("word"));
    try std.testing.expect(try re.isMatch(gpa, "Hey HEY!"));
    try std.testing.expect(!try re.isMatch(gpa, "hey ho"));
}

test "findAt and spans" {
    var re = try Regex.compile(gpa, "ab");
    defer re.deinit();
    var m = (try re.findAt(gpa, "abab", 1)).?;
    defer m.deinit(gpa);
    try std.testing.expectEqual(zregex.Span{ .start = 2, .end = 4 }, m.span());
}

test "compile errors surface" {
    try std.testing.expectError(error.UnbalancedParen, Regex.compile(gpa, "(a"));
    try std.testing.expectError(error.NothingToRepeat, Regex.compile(gpa, "+"));
    try std.testing.expectError(error.ProgramTooLarge, Regex.compile(gpa, "(?:(?:a{1000}){1000}){1000}"));
}

test "prefilter analysis" {
    const cases = [_]struct {
        pattern: []const u8,
        flags: zregex.Flags = .{},
        usable: bool,
        single: ?u8 = null,
    }{
        .{ .pattern = "abc", .usable = true, .single = 'a' },
        .{ .pattern = "^abc$", .usable = true, .single = 'a' },
        .{ .pattern = "(?i)q", .usable = true }, // {q, Q}
        .{ .pattern = "cat|dog", .usable = true },
        .{ .pattern = "a*bc", .usable = true }, // {a, b}
        .{ .pattern = "(?=x)yz", .usable = true, .single = 'y' },
        .{ .pattern = "(a)\\1", .usable = true, .single = 'a' },
        .{ .pattern = ".x", .usable = false },
        .{ .pattern = "[^a]x", .usable = false },
        .{ .pattern = "a?b?", .usable = false }, // can match empty
    };
    inline for (cases) |c| {
        var re = try Regex.compileWithFlags(gpa, c.pattern, c.flags);
        defer re.deinit();
        try std.testing.expectEqual(c.usable, re.prefilter.usable);
        if (c.single) |b| try std.testing.expectEqual(@as(?u8, b), re.prefilter.single);
    }
    // Set contents: a*bc can start with 'a' or 'b' but not 'c'.
    var re = try Regex.compile(gpa, "a*bc");
    defer re.deinit();
    try std.testing.expect(re.prefilter.bytes['a']);
    try std.testing.expect(re.prefilter.bytes['b']);
    try std.testing.expect(!re.prefilter.bytes['c']);
    // (?i) folds.
    var re2 = try Regex.compile(gpa, "(?i)q");
    defer re2.deinit();
    try std.testing.expect(re2.prefilter.bytes['q']);
    try std.testing.expect(re2.prefilter.bytes['Q']);
}

test "prefilter never stops mid-codepoint" {
    // U+00A9 (©) is 0xC2 0xA9 in UTF-8; 'é' is 0xC3 0xA9. A lone invalid
    // 0xA9 byte decodes to U+00A9 via the fallback, but the 0xA9 inside a
    // valid 'é' must not: matches may only start at decode boundaries.
    //
    // 0xA9 is therefore a candidate byte *and* a continuation byte, which is
    // exactly the shape that stops the scan from stepping a byte at a time.
    var re = try Regex.compile(gpa, "\u{A9}");
    defer re.deinit();
    try std.testing.expect(!re.prefilter.byte_steppable);
    try std.testing.expect(!try re.isMatch(gpa, "é")); // C3 A9: no boundary at the A9
    try std.testing.expect(try re.isMatch(gpa, "x\xA9y")); // lone invalid byte: matches
    try std.testing.expect(try re.isMatch(gpa, "x\u{A9}y")); // real ©
}

test "prefilter honors utf-8 lead bytes and raw fallback" {
    var re = try Regex.compile(gpa, "é+");
    defer re.deinit();
    try std.testing.expect(re.prefilter.usable);
    try std.testing.expect(re.prefilter.bytes[0xC3]); // é lead byte
    try std.testing.expect(re.prefilter.bytes[0xE9]); // raw fallback for U+E9
    try std.testing.expect(!re.prefilter.bytes['e']);
    try std.testing.expect(try re.isMatch(gpa, "abcé"));
    try std.testing.expect(try re.isMatch(gpa, "ab\xE9cd")); // invalid byte fallback
}

test "dfa and pike agree on every match and capture" {
    const patterns = [_][]const u8{
        "abc",           "a+",      "a+?",         "a*b",
        "(a|ab)(c|bcd)", "<.+>",    "<.+?>",       "(\\w+)@([\\w.]+)",
        "^\\w+",         "\\w+$",   "\\bcat\\b",   "\\Babc",
        "x{2,4}",        "(a*)*b",  "(|a)*b",      "[^x]y",
        ".at",           "a$",      "^",           "a?",
        "é+",
        "(.)(.)",        "\\d{2,}", "colou?r",     "(?:ab|cd)+",
        "(a)(b)?c?",     "^$",      "\\x{1F600}+",
    };
    const haystacks = [_][]const u8{
        "",
        "a",
        "abc abc",
        "aaabbb",
        "the cat sat on a mat",
        "x@y.z mail alice@example.org!",
        "line one\nline two\ncat\n",
        "xxxxx",
        "abcbcd",
        "aébé\xFFcé",
        "color colour",
        "ababcdab",
        "hi 😀😀 there",
        "wordcat catword cat",
        "12 345 6789",
    };
    for (patterns) |pat| {
        var re = try Regex.compile(gpa, pat);
        defer re.deinit();
        if (re.engine != .pike) continue;
        for (haystacks) |hay| {
            re.dfa_mode = .on;
            var it_dfa = re.iterator(gpa, hay);
            defer it_dfa.deinit();
            re.dfa_mode = .off;
            var it_pike = re.iterator(gpa, hay);
            defer it_pike.deinit();
            while (true) {
                re.dfa_mode = .on;
                const a = try it_dfa.next();
                re.dfa_mode = .off;
                const b = try it_pike.next();
                if (a == null or b == null) {
                    try std.testing.expectEqual(a == null, b == null);
                    break;
                }
                var ma = a.?;
                defer ma.deinit(gpa);
                var mb = b.?;
                defer mb.deinit(gpa);
                std.testing.expectEqualSlices(?zregex.Span, mb.groups, ma.groups) catch |err| {
                    std.debug.print("pattern={s} haystack={f}\n", .{ pat, std.zig.fmtString(hay) });
                    return err;
                };
            }
        }
    }
}

test "dfa handles findAt context correctly" {
    // \b at a findAt start must see the previous character.
    var re = try Regex.compile(gpa, "\\bcat");
    defer re.deinit();
    var m = try re.findAt(gpa, "concat cat", 3);
    try std.testing.expect(m != null); // finds " cat", not "cat" inside concat
    try std.testing.expectEqual(@as(usize, 7), m.?.span().start);
    m.?.deinit(gpa);
    // ^ must not hold at a mid-string start position.
    var re2 = try Regex.compile(gpa, "^x");
    defer re2.deinit();
    try std.testing.expectEqual(@as(?zregex.Match, null), try re2.findAt(gpa, "yx", 1));
}

test "fused repeats in the backtracker" {
    // Greedy gives back one codepoint at a time down to min: a{2,} must
    // shrink from 4 to 2 so the backref can match the rest.
    try expectGroups("(a{2,})\\1", "aaaa", &.{ "aaaa", "aa" });
    // Bounded {n,m}.
    try expectFind("(?=\\d)\\d{2,4}", "12345 1", "1234");
    try expectFind("(?=\\d)\\d{2,4}x", "12345x", "2345x");
    try expectFind("(?=\\d)\\d{2,4}", "9!", null);
    // Lazy fused repeat grows one at a time.
    try expectGroups("(a+?)a\\1", "aaaa", &.{ "aaa", "a" });
    try expectFind("(?<=x).*?y", "xaay", "aay");
    // UTF-8 child codepoints step correctly in both directions.
    try expectFind("(?=é)é+x", "ééx", "ééx");
    try expectFind("(é{2,})\\1", "éééé", "éééé");
    // A capturing group inside a repeat must not fuse (captures per iteration).
    try expectGroups("(?=a)(a)+b", "aab", &.{ "aab", "a" });
    // Non-capturing wrapper does fuse and stays correct.
    try expectFind("(?=a)(?:a)+b", "aab", "aab");
    // Fused rep at the start feeds the prefilter.
    var re = try Regex.compile(gpa, "\\d+(?=%)");
    defer re.deinit();
    try std.testing.expect(re.prefilter.usable);
    try std.testing.expect(re.prefilter.bytes['5']);
    try std.testing.expect(!re.prefilter.bytes['x']);
    var m = (try re.find(gpa, "at 15% now")).?;
    defer m.deinit(gpa);
    try std.testing.expectEqualStrings("15", m.span().slice("at 15% now"));
}

test "memoization tames exponential backtracking" {
    // 2^30-ish unmemoized; the memo makes it polynomial and it just fails.
    var re = try Regex.compile(gpa, "(a+)+\\1$");
    defer re.deinit();
    try std.testing.expectEqual(zregex.Engine.backtrack, re.fallback_engine);
    const haystack = "a" ** 30 ++ "b";
    try std.testing.expect(!try re.isMatch(gpa, haystack));
    // Without the memo the same search must blow the step budget.
    re.memo = false;
    re.max_steps = 100_000;
    try std.testing.expectError(error.StepLimitExceeded, re.isMatch(gpa, haystack));

    // Alternation-driven blowup, forced onto the backtracker by a lookahead.
    var re2 = try Regex.compile(gpa, "(?=a)(a|a)*c$");
    defer re2.deinit();
    const haystack2 = "a" ** 26 ++ "b";
    try std.testing.expect(!try re2.isMatch(gpa, haystack2));
    re2.memo = false;
    re2.max_steps = 100_000;
    try std.testing.expectError(error.StepLimitExceeded, re2.isMatch(gpa, haystack2));
}

test "memoization preserves semantics" {
    const cases = [_]struct { p: []const u8, h: []const u8 }{
        .{ .p = "(a+)+\\1", .h = "aaaaaa" },
        .{ .p = "(a|ab)+(c|bc)\\1", .h = "ababcab" },
        .{ .p = "(\\w+) \\1", .h = "hey hey ho ho" },
        .{ .p = "(?=(a+))(a|aa)+b", .h = "aaaab" },
        .{ .p = "(?:(x)|(y))*\\1\\2", .h = "xyxy" },
        .{ .p = "((a*)b\\2)+", .h = "aabaab ab" },
        .{ .p = "(a{2,})\\1", .h = "aaaaa" },
        .{ .p = "(?<=(b))a\\1", .h = "bab" },
    };
    for (cases) |c| {
        var re = try Regex.compile(gpa, c.p);
        defer re.deinit();
        try std.testing.expectEqual(zregex.Engine.backtrack, re.fallback_engine);
        re.memo = true;
        const with = try re.find(gpa, c.h);
        re.memo = false;
        const without = try re.find(gpa, c.h);
        if (with == null or without == null) {
            try std.testing.expectEqual(with == null, without == null);
            continue;
        }
        var a = with.?;
        defer a.deinit(gpa);
        var b = without.?;
        defer b.deinit(gpa);
        try std.testing.expectEqualSlices(?zregex.Span, b.groups, a.groups);
    }
}

test "lookahead sub-runs are re-evaluated correctly under memoization" {
    // The lookahead runs at several positions across attempts; sub-run
    // states must not be poisoned by earlier (successful) runs.
    try expectGroups("(?=(a+))\\1b", "aaab", &.{ "aaab", "aaa" });
    try expectGroups("(?=(\\w+))(\\w)x", "ab cx", &.{ "cx", "cx", "c" });
    // Atomic lookaround: the captured \\w+ cannot be retried shorter, so the
    // backref can never fit (PCRE agrees: no match).
    try expectFind("(?=(\\w+))x\\1", "axaa", null);
}

test "literal retry scanning preserves greedy semantics" {
    // The scan jumps between '-' occurrences largest-first: same result as
    // stepping back one position at a time.
    try expectGroups("(?=.)(\\S+)-(\\S+)", "a-b-c", &.{ "a-b-c", "a-b", "c" });
    try expectFind("(\\w+)-\\1", "aaa-bbb ab-ab x", "ab-ab");
    // Case-insensitive continuation char uses the folded reverse scan.
    try expectFind("(?i)(\\d+)A\\1", "x12a12y", "12a12");
    // Lookahead continuation: scan for the looked-at char.
    try expectGroups("(\\w+)(?=@)", "mail jeff@x", &.{ "jeff", "jeff" });
    // No occurrence in range: the frame dies without a match.
    try expectFind("(\\w{2,})=\\1", "aaaa bbbb", null);
}

test "dynamic lead-run skipping with backrefs" {
    // Failing words never execute the backref, so whole runs are skipped;
    // the word that does match must still be found with correct captures.
    try expectGroups("(\\w{3,})-\\1", "aaaa bbbb ccc-ccc dd", &.{ "ccc-ccc", "ccc" });
    try expectFind("(\\w+) \\1", "aaaa bbbb cc cc", "cc cc");
    // Backref executed but failed: no skip, later start in same run matches.
    try expectFind("(\\w+)\\1", "xabab", "abab");
}

test "jit agrees with the interpreters on every match and capture" {
    if (!zregex.jit_available) return error.SkipZigTest;
    // On x86-64 the two vector widths generate different code for the same
    // repeats, so each is checked against the interpreters in turn.
    if (@import("builtin").cpu.arch == .x86_64) {
        defer zregex.overrideAvx2(null);
        for ([_]bool{ false, true }) |avx2| {
            zregex.overrideAvx2(avx2);
            try jitDifferential();
        }
    } else {
        try jitDifferential();
    }
}

fn jitDifferential() !void {
    // Deliberately mixes the constructs the generator inlines (fused repeats,
    // classes, assertions, single-codepoint lookaround) with the ones it hands
    // to helpers (non-ASCII literals and classes, backreferences).
    const patterns = [_][]const u8{
        "abc",           "a+",              "a+?",           "a*b",
        "(a|ab)(c|bcd)", "<.+>",            "<.+?>",         "(\\w+)@([\\w.]+)",
        "^\\w+",         "\\w+$",           "\\bcat\\b",     "\\Babc",
        "x{2,4}",        "(a*)*b",          "(|a)*b",        "[^x]y",
        ".at",           "a$",              "^",             "a?",
        "é+",
        "(.)(.)",        "\\d{2,}",         "colou?r",       "(?:ab|cd)+",
        "(a)(b)?c?",     "^$",              "\\x{1F600}+",   "(\\w+) \\1",
        "(a+)\\1",       "(\\w{2,})-\\1",   "(?i)(abc)\\1",  "\\w+(?=@)",
        "a(?!b)",        "(?<=\\$)\\d+",    "(?<!x)y",       "(?i)HeLLo",
        "(?m)^b$",       "(?s)a.b",
        "[à-ö]+",
        "(a{2,})\\1",    "(?=\\d)\\d{2,4}", "(\\S+)-(\\S+)", "\\d{3,5}x",
    };
    const haystacks = [_][]const u8{
        "",
        "a",
        "abc abc",
        "aaabbb",
        "the cat sat on a mat",
        "x@y.z mail alice@example.org!",
        "line one\nline two\ncat\n",
        "xxxxx",
        "abcbcd",
        "aébé\xFFcé",
        "color colour",
        "ababcdab",
        "hi 😀😀 there",
        "wordcat catword cat",
        "12 345 6789",
        "say ho ho and hey hey!",
        "cost: $42, was $7",
        "aa-aa bb-bb cc-dd",
        "ABC abc AbC abcabc",
        "aaaaaaaaaaaaaaaaaaaab",
    };
    for (patterns) |pat| {
        var re = try Regex.compile(gpa, pat);
        defer re.deinit();
        if (re.jit_code == null) continue;
        for (haystacks) |hay| {
            re.jit_mode = .on;
            var it_jit = re.iterator(gpa, hay);
            defer it_jit.deinit();
            re.jit_mode = .off;
            var it_ref = re.iterator(gpa, hay);
            defer it_ref.deinit();
            while (true) {
                re.jit_mode = .on;
                const a = try it_jit.next();
                re.jit_mode = .off;
                const b = try it_ref.next();
                if (a == null or b == null) {
                    std.testing.expectEqual(b == null, a == null) catch |err| {
                        std.debug.print("pattern={s} haystack={f}\n", .{ pat, std.zig.fmtString(hay) });
                        return err;
                    };
                    break;
                }
                var ma = a.?;
                defer ma.deinit(gpa);
                var mb = b.?;
                defer mb.deinit(gpa);
                std.testing.expectEqualSlices(?zregex.Span, mb.groups, ma.groups) catch |err| {
                    std.debug.print("pattern={s} haystack={f}\n", .{ pat, std.zig.fmtString(hay) });
                    return err;
                };
            }
        }
    }
}

test "jit bails instead of blowing up, and the answer still comes back" {
    if (!zregex.jit_available) return error.SkipZigTest;
    // The generated code has no memoization, so this exhausts its budget; the
    // memoizing interpreter behind it still produces the right answer.
    var re = try Regex.compile(gpa, "(a+)+\\1$");
    defer re.deinit();
    try std.testing.expectEqual(zregex.Engine.jit, re.engine);
    try std.testing.expect(!try re.isMatch(gpa, "a" ** 30 ++ "b"));
}

test "greedy give-back happens exactly where a shorter run could help" {
    // '-' is not a word character, so no shorter \w+ run can be followed by
    // one: both engines skip the retry entirely. Matches must be unaffected.
    try expectGroups("(\\w+)-(\\w+)", "ab-cd", &.{ "ab-cd", "ab", "cd" });
    try expectFind("\\w+-\\w+", "xx yy-zz", "yy-zz");
    try expectGroups("(\\w{3,})-\\1", "aaaa bbbb ccc-ccc dd", &.{ "ccc-ccc", "ccc" });
    // Here the continuation *is* a member of the repeated class, so the
    // give-back is real and the shorter run is what matches.
    try expectGroups("(\\S+)-(\\S+)", "a-b-c", &.{ "a-b-c", "a-b", "c" });
    try expectFind("[a-z]+ing", "singing", "singing");
    try expectFind("[a-z]+ab", "xabab", "xabab");
    try expectFind("\\w+_\\w+", "a_b", "a_b"); // '_' is a word char
    // Case-insensitive: the fold partner counts as a member too.
    try expectFind("(?i)[a-z]+X", "fooxbar", "foox");
}

test "regressions found by differential fuzzing" {
    // A deferred low-priority branch used to be marked visited as soon as it
    // was queued, so a higher-priority path reaching the same instruction
    // later was dropped along with its captures. Group 1 must be the empty
    // match the `\b` branch makes, not unset.
    try expectGroups("(?:(\\b)|\\d){0,1}[ab1]", " ba1", &.{ "b", "" });

    // Re-entering a group overwrites its start before its end, so a
    // backreference reached while the group is open saw start > end and
    // sliced backwards. It must behave as an unset group and match empty.
    var re = try Regex.compile(gpa, "((a)|b)+\\2");
    defer re.deinit();
    // Group 2 never participates on the path that reaches the
    // backreference, so this cannot match — what matters is that it does
    // not slice backwards while deciding so.
    try std.testing.expect(!try re.isMatch(gpa, "ab"));

    // A loop iteration that consumes nothing ends the loop; it does not fail
    // and force the body to consume. `(a*?)*` must therefore match empty,
    // which is what PCRE and Python do.
    try expectGroups("(a*?)*", "aa", &.{ "", "" });
    try expectFind("(a*)*", "aa", "aa");
    try expectFind("(?:a*?)*b", "aab", "aab");
    try expectFind("(?:a*)*b", "aab", "aab");
}

test "prefilter skipping does not strand the Pike VM" {
    // Skipping to the next candidate byte leaves visited marks behind from
    // the position just abandoned. Reusing that generation blocked the
    // assertion here, so no match was found at all.
    try expectFind("@?\\Bb", "@ab", "b");
    try expectFind("(?:@)?\\Bb", "@ab", "b");
    try expectFind("a?\\Bb", "@ab", "ab"); // leftmost: the optional 'a' is taken
    try expectGroups("(@)?\\Bb", "@ab", &.{ "b", null });
}

test "POSIX bracket classes" {
    // `[[:name:]]` is only meaningful inside a class, and ASCII-only, which
    // is what `\d`, `\w` and `\s` already are here and what PCRE gives these
    // without PCRE2_UCP. Every span below was checked against PCRE2.
    //
    // Before these were implemented the inner brackets were read as ordinary
    // members, so `[[:digit:]]` quietly meant "one of `[:digt]`" and matched
    // the wrong thing rather than failing.
    const hay = "ab12:] _-A~ ";
    try expectFind("[[:digit:]]+", hay, "12");
    try expectFind("[[:alpha:]]+", hay, "ab");
    try expectFind("[[:alnum:]]+", hay, "ab12");
    try expectFind("[[:upper:]]+", hay, "A");
    try expectFind("[[:lower:]]+", hay, "ab");
    try expectFind("[[:space:]]+", hay, " ");
    try expectFind("[[:blank:]]+", hay, " ");
    try expectFind("[[:punct:]]+", hay, ":]");
    try expectFind("[[:xdigit:]]+", hay, "ab12");
    try expectFind("[[:word:]]+", hay, "ab12");
    try expectFind("[[:graph:]]+", hay, "ab12:]");
    try expectFind("[[:print:]]+", hay, hay);
    try expectFind("[[:ascii:]]+", hay, hay);
    try expectFind("[[:cntrl:]]+", hay, null);
    // Mixed with ordinary members, and both ways of negating.
    try expectFind("[[:alpha:]0-9]+", hay, "ab12");
    try expectFind("[[:^digit:]]+", hay, "ab");
    try expectFind("[^[:digit:]]+", hay, "ab");
    // A `[` that does not open one stays the literal PCRE makes it, so a
    // class missing the `:]` terminator still reads as ordinary members.
    try expectFind("[[]", "x[y", "[");
    try expectFind("[[:a]+", "ab12", "a");
    // Anything terminated by `:]` is meant as one of these, so a name nobody
    // defines is an error -- as in PCRE, and rather than falling back to
    // reading the characters one at a time. The names are case-sensitive.
    try std.testing.expectError(error.InvalidClass, Regex.compile(gpa, "[[:bogus:]]"));
    try std.testing.expectError(error.InvalidClass, Regex.compile(gpa, "[[:^bogus:]]"));
    try std.testing.expectError(error.InvalidClass, Regex.compile(gpa, "[[:DIGIT:]]"));
    try std.testing.expectError(error.InvalidClass, Regex.compile(gpa, "[[:a-z:]]"));
    try std.testing.expectError(error.InvalidClass, Regex.compile(gpa, "[[::]]"));
    try std.testing.expectError(error.InvalidClass, Regex.compile(gpa, "[[:^:]]"));
}

test "a caseless POSIX complement closes over case before complementing" {
    // Found by tools/oracle.zig. `[:^lower:]` is complemented while the
    // pattern is parsed, but `(?i)` is not applied until match time, so
    // without closing the set over case first the two happen in the wrong
    // order: `a` folded to `A`, found it in the complement of `a-z`, and
    // matched. PCRE reads the class as "not a letter of either case".
    //
    // `lower` and `upper` are the only names this can be seen through --
    // every other set, and `\D`, `\W` and `\S` too, already holds both cases
    // of everything in it or neither.
    try expectFind("(?i:[[:^lower:]])", "a", null);
    try expectFind("(?i:[[:^lower:]])", "A", null);
    try expectFind("(?i:[[:^upper:]])", "A", null);
    try expectFind("(?i:[[:^upper:]])", "z", null);
    // Characters with no case are unaffected, and so is the whole thing
    // without the flag.
    try expectFind("(?i:[[:^lower:]])", "0", "0");
    try expectFind("(?i:[[:^lower:]])", "_", "_");
    try expectFind("[[:^lower:]]", "A", "A");
    try expectFind("[[:^lower:]]", "a", null);
    try expectFind("(?i:[[:^alpha:]])", "Q", null);
    try expectFind("(?i:[[:^xdigit:]])", "F", null);
    try expectFind("(?i:[[:^digit:]])", "a", "a");
    try expectFind("(?i:[[:^word:]])", "-", "-");
}

test "case folding is Unicode, not ASCII" {
    // Found by running PCRE2's own test corpus through tools/oracle.zig,
    // where caseless matching of non-ASCII was by far the largest source of
    // difference. The tables come from CaseFolding.txt, via the uucode
    // package, and hold simple case folding only -- the `C` and `S` entries.
    try expectFind("(?i)\u{c1}", "\u{e1}", "\u{e1}"); // Á ~ á
    try expectFind("(?i)\u{391}+", "\u{3b1}", "\u{3b1}"); // Α ~ α
    try expectFind("(?i)\u{23a}", "\u{2c65}", "\u{2c65}"); // Ⱥ ~ ⱥ
    try expectFind("(?i)\u{1e9e}", "\u{df}", "\u{df}"); // ẞ ~ ß

    // Three-member classes: `s` also matches the long s, `k` the Kelvin sign.
    try expectFind("(?i)s", "\u{17f}", "\u{17f}");
    try expectFind("(?i)\u{17f}", "S", "S");
    try expectFind("(?i)k", "\u{212a}", "\u{212a}");
    try expectFind("(?i)\u{212a}", "k", "k");

    // Classes are closed over case where they are built, so nothing folds
    // while matching and every engine sees an ordinary class.
    try expectFind("(?i)[z\u{df}]+", "\u{1e9e}", "\u{1e9e}");
    try expectFind("(?i)[\u{105}-\u{109}]", "\u{104}", "\u{104}");

    // A complement is taken of the closed set, never closed afterwards. The
    // Kelvin sign is a non-word character, so closing `\W` after the fact
    // would drag `k` and `K` into it.
    try expectFind("(?i)\\W", "k", null);
    try expectFind("(?i)[\\W]", "k", null);
    try expectFind("(?i)[^k]", "k", null);
    try expectFind("(?i)[^k]", "\u{212a}", null);
    try expectFind("(?i)[[:^lower:]]", "a", null);
    try expectFind("(?i)[[:^lower:]]", "0", "0");

    // Simple case folding is the `C` and `S` entries of CaseFolding.txt and
    // nothing else. `İ` (U+0130) has only a full mapping and a Turkic one, so
    // it folds to itself; PCRE matches it against neither `i` nor `I`.
    try expectFind("(?i)i", "\u{130}", null);
    try expectFind("(?i)\u{130}", "i", null);
    try expectFind("(?i)\u{130}", "I", null);
    try expectFind("(?i)[i]", "\u{130}", null);
}

test "a caseless backreference may match a different number of bytes" {
    // `Ⱥ` (U+023A) is two bytes and the `ⱥ` (U+2C65) it folds together with
    // is three, so the text a backreference matches can be longer or shorter
    // than the text it captured. Comparing byte by byte -- which is what this
    // did while folding was ASCII-only, where the two cases of a character
    // always have the same length -- got both the comparison and how far to
    // advance wrong.
    try expectFind(
        "(?i)(\u{23a}\u{23a}\u{23a})\\1",
        "\u{23a}\u{23a}\u{23a}\u{2c65}\u{2c65}\u{2c65}",
        "\u{23a}\u{23a}\u{23a}\u{2c65}\u{2c65}\u{2c65}",
    );
    try expectFind(
        "(?i)(\u{2c65}\u{2c65})\\1",
        "\u{2c65}\u{2c65}\u{23a}\u{23a}",
        "\u{2c65}\u{2c65}\u{23a}\u{23a}",
    );
    try expectFind("(?i)(\u{de})\\1", "\u{de}\u{fe}", "\u{de}\u{fe}");
    try expectFind("(?i)(.) \\1", "A a", "A a");
}

test "relaxed brace quantifiers" {
    // PCRE ignores space and horizontal tab after `{`, before `}`, and on
    // either side of the comma, and reads a missing minimum as zero. A brace
    // pair holding no number at all is not a quantifier and stays literal.
    // Found by running PCRE2's own test corpus.
    try expectFind("a{,3}B", "aaaB", "aaaB");
    try expectFind("x{,2}(x|b)", "xxb", "xxb");
    try expectFind("a{ 1,2 }", "aa", "aa");
    try expectFind("a{ 1 , 2 }", "aa", "aa");
    try expectFind("A{ ,3}", "AAAAAA", "AAA");
    try expectFind("A{ 3, }", "AAAA", "AAAA");
    // Not quantifiers: no number between the braces.
    try expectFind("A{,}B", "A{,}B", "A{,}B");
    try expectFind("A{ , }B", "A{ , }B", "A{ , }B");
    try expectFind("X{}", "ZZX{}YZ", "X{}");
    // Still not a quantifier: holding something that is not a bound.
    try expectFind("X{12ABC}", "ZZX{12ABC}Y", "X{12ABC}");
}

test "horizontal and vertical whitespace classes" {
    // In PCRE `\v` is the vertical whitespace class, not the vertical tab --
    // Python and JavaScript are the ones that read it as a character, and
    // zregex used to follow them. Both lists reach past ASCII even without
    // PCRE2_UCP, because both are fixed sets rather than Unicode properties.
    try expectFind("\\v", "a\nb", "\n");
    try expectFind("\\v", "a\tb", null);
    try expectFind("a\\vb", "a\nb", "a\nb");
    try expectFind("\\v", "a\u{2028}", "\u{2028}");
    try expectFind("\\h", "a\tb", "\t");
    try expectFind("\\h", "a b", " ");
    try expectFind("\\h", "\u{3000}x", "\u{3000}");
    try expectFind("\\H", "\tab", "a");
    try expectFind("\\V", "\nab", "a");
    try expectFind("[\\v]", "a\nb", "\n");
    try expectFind("[^\\v]+", "\nab", "ab");
}

test "a variable-length lookbehind takes the longest match" {
    // PCRE tries the longest lookbehind text first, so the group captures all
    // four digits rather than the last one. zregex searched from the shortest
    // and reported the other end of the range.
    try expectGroups("(?<=(\\d{1,4}))X", "1234X", &.{ "X", "1234" });
    try expectGroups("(?<=(a{1,3}))X", "aaaX", &.{ "X", "aaa" });
    try expectGroups("(?<=(ab|b))X", "abX", &.{ "X", "ab" });
    // Unbounded lookbehind has no maximum to start from, so it begins at the
    // start of the haystack; the answer is still the longest.
    try expectGroups("(?<=(a+))X", "aaaX", &.{ "X", "aaa" });
}

test "iteration retries for a longer match where it found an empty one" {
    // After an empty match, the next thing to try is a longer match in the
    // same place -- not the next position. `.*?` reports empty at 0 and then
    // `a` and `b` in turn; advancing straight away reported empty at 0, 1 and 2
    // and never the text between them. PCRE does this (it is the loop pcre2demo.c
    // documents) and so does Python; zregex was the odd one out, which only
    // showed once the oracle started comparing every match rather than the
    // leftmost one.
    const cases = [_]struct {
        pat: []const u8,
        hay: []const u8,
        want: []const zregex.Span,
    }{
        .{ .pat = ".*?", .hay = "ab", .want = &.{
            .{ .start = 0, .end = 0 }, .{ .start = 0, .end = 1 },
            .{ .start = 1, .end = 1 }, .{ .start = 1, .end = 2 },
            .{ .start = 2, .end = 2 },
        } },
        // The retry fails here -- nothing longer starts at 0 -- so the search
        // carries on from the next codepoint, as it always did.
        .{ .pat = "a*", .hay = "bab", .want = &.{
            .{ .start = 0, .end = 0 }, .{ .start = 1, .end = 2 },
            .{ .start = 2, .end = 2 }, .{ .start = 3, .end = 3 },
        } },
        .{ .pat = "(?:)", .hay = "ab", .want = &.{
            .{ .start = 0, .end = 0 }, .{ .start = 1, .end = 1 },
            .{ .start = 2, .end = 2 },
        } },
        // Stepping past an empty match moves a whole codepoint, not a byte.
        .{ .pat = "b*", .hay = "\u{20ac}b", .want = &.{
            .{ .start = 0, .end = 0 }, .{ .start = 3, .end = 4 },
            .{ .start = 4, .end = 4 },
        } },
    };
    for (cases) |c| {
        var re = try Regex.compile(gpa, c.pat);
        defer re.deinit();
        var got: std.ArrayList(zregex.Span) = .empty;
        defer got.deinit(gpa);
        var it = re.iterator(gpa, c.hay);
        defer it.deinit();
        while (try it.next()) |m| {
            var mm = m;
            defer mm.deinit(gpa);
            try got.append(gpa, mm.span());
        }
        std.testing.expectEqualSlices(zregex.Span, c.want, got.items) catch |err| {
            std.debug.print("pattern={s} haystack={s}\n", .{ c.pat, c.hay });
            return err;
        };
    }
}

test "NUL is an ordinary character" {
    // Nothing here takes a subject as a C string, so a NUL byte is a
    // character like any other and must not end anything early. It is in both
    // of the fuzzer's alphabets for that reason; this pins down the answers
    // it is checked against, all of which PCRE2 agrees with.
    try expectFind("\\x00", "a\x00b", "\x00");
    try expectFind("a\\x00b", "a\x00b", "a\x00b");
    try expectFind("\\x00+", "a\x00\x00b", "\x00\x00");
    try expectFind("[\\x00-\\x08]", "a\x00b", "\x00");
    try expectFind("[^\\x00]+", "a\x00b", "a");
    try expectFind(".", "\x00", "\x00");
    try expectFind("\\w\\x00", "a\x00", "a\x00");
    // A NUL in the middle of a haystack does not stop the search reaching
    // what is after it.
    try expectFind("b", "a\x00b", "b");
    try expectFind("$", "a\x00", "");
    // Group 0 spans the NUL, and a capture may hold one.
    try expectGroups("(a\\x00)(b)", "a\x00b", &.{ "a\x00b", "a\x00", "b" });
}

test "adversarial patterns cannot demand absurd memory" {
    // Two memory bombs, measured with a byte-counting allocator before the
    // limits below existed.
    //
    // Six nested nullable loops wrapped around a program near the
    // instruction ceiling made the Pike VM's visited table four million
    // keys -- instructions times two per guard level -- and one 381-byte
    // pattern allocated half a gigabyte. The compiler now refuses a program
    // whose table would pass a million keys; every pattern up to sixteen
    // thousand instructions keeps all six guard levels, so nothing short of
    // a deliberately built monster notices.
    var pat: std.ArrayList(u8) = .empty;
    defer pat.deinit(gpa);
    try pat.appendSlice(gpa, "((((((a?)*)*)*)*)*)*");
    for (0..60) |_| try pat.appendSlice(gpa, "b{900}");
    try std.testing.expectError(error.ProgramTooLarge, Regex.compile(gpa, pat.items));

    // The nesting alone is fine: it is the combination with a huge program
    // that is refused.
    var re = try Regex.compile(gpa, "((((((a?)*)*)*)*)*)*b");
    defer re.deinit();
    try expectFind("((((((a?)*)*)*)*)*)*b", "aab", "aab");

    // The parse buffers are sized for the worst case at dozens of bytes per
    // pattern byte, and a pattern of no-ops compiles to almost nothing while
    // costing all of it: eight megabytes of `(?:)` allocated six hundred.
    // Patterns are refused past a megabyte, before anything is allocated;
    // real content runs into the program ceiling two orders of magnitude
    // sooner, so only no-op spam can ever reach this.
    pat.clearRetainingCapacity();
    for (0..(1 << 18) + 1) |_| try pat.appendSlice(gpa, "(?:)");
    try std.testing.expectError(error.PatternTooLong, Regex.compile(gpa, pat.items));
}

test "adversarial patterns fail cleanly instead of crashing" {
    // Compile-time hardening. A pattern is attacker-sized input too: each of
    // these once either crashed or would have run away, and each must now
    // come back as an ordinary error in time proportional to its size.
    //
    // A long flat pattern used to build a left-leaning concat spine one node
    // per character, and the compiler's recursive walk overran the stack on
    // it -- a segfault from a pattern of plain letters -- before the
    // program-size limit could reject it. The parser now builds balanced
    // trees, so the walk is log-deep and the limit gets its say. Emission
    // order is leaf order either way, so the program is unchanged.
    var big: std.ArrayList(u8) = .empty;
    defer big.deinit(gpa);
    for (0..300_000) |_| try big.append(gpa, 'a');
    try std.testing.expectError(error.ProgramTooLarge, Regex.compile(gpa, big.items));

    // The same spine, made of alternation branches.
    big.clearRetainingCapacity();
    for (0..60_000) |_| try big.appendSlice(gpa, "a|");
    try std.testing.expectError(error.ProgramTooLarge, Regex.compile(gpa, big.items));

    // Multiplicative counted repeats: a billion-instruction expansion must
    // be cut off by the counting pass, not walked.
    try std.testing.expectError(error.ProgramTooLarge, Regex.compile(gpa, "((a{1000}){1000}){1000}"));

    // Group nesting past the depth limit.
    big.clearRetainingCapacity();
    for (0..5000) |_| try big.appendSlice(gpa, "(?:");
    try big.append(gpa, 'a');
    for (0..5000) |_| try big.appendSlice(gpa, ")");
    try std.testing.expectError(error.NestingTooDeep, Regex.compile(gpa, big.items));
}

test "the step budget bounds a whole scan, not each start position" {
    // `(a+)\1$` against a run of `a` is quadratic per attempt and runs at
    // every start position. With the budget granted anew at each start --
    // which is what PCRE does with its match limit, and what this library
    // used to do -- no single attempt ever tripped it, and the scan took
    // seconds at 24K of input and grew cubically from there; the same input
    // hangs `grep -P` outright. The budget now covers the whole call, plus
    // an allowance per input byte so that honest scans of large haystacks
    // still get work proportional to their size.
    var hay: std.ArrayList(u8) = .empty;
    defer hay.deinit(gpa);
    for (0..2000) |_| try hay.append(gpa, 'a');
    try hay.append(gpa, 'b');

    var re = try Regex.compile(gpa, "(a+)\\1$");
    defer re.deinit();
    re.max_steps = 10_000;
    re.jit_mode = .off; // the JIT bails on its own budget; hold the interpreter to it
    try std.testing.expectError(error.StepLimitExceeded, re.find(gpa, hay.items));

    // The per-byte allowance is what keeps an honest scan alive: the same
    // pattern over the same haystack with the match present finds it, and a
    // benign pattern crosses a large haystack without touching the limit.
    try expectFind("(a+)\\1", "xxaaaax", "aaaa");
    var big: std.ArrayList(u8) = .empty;
    defer big.deinit(gpa);
    for (0..100_000) |_| try big.append(gpa, 'a');
    try big.append(gpa, 'b');
    var re2 = try Regex.compile(gpa, "(a?)b\\1");
    defer re2.deinit();
    const m = (try re2.find(gpa, big.items)) orelse return error.TestUnexpectedResult;
    var mm = m;
    defer mm.deinit(gpa);
    // `a?` must match empty here: taking the `a` at 99,999 leaves the
    // backreference wanting another one past the end of the input.
    try std.testing.expectEqual(@as(usize, 100_000), mm.span().start);
}

test "a leading class bracket may open a range" {
    // `]` first in a class is a literal, and an ordinary member in every
    // other way, so it may be the low end of a range: `[]-b]` runs from `]`
    // to `b` and takes in the letter `a`. It used to be added as a finished
    // member, which quietly read that class as the three characters `]`,
    // `-`, `b`. Found by mutating PCRE2's own test patterns -- the seed was
    // `a[]-b]e` from testinput1, one deletion away.
    try expectFind("a[]-b]", "aab", "aa");
    try expectFind("[]-b]+", "]^_`ab.", "]^_`ab");
    try expectFind("[^]-b]", "a", null);
    try expectFind("[^]-b]", "x", "x");
    try expectFind("(?i)[]-b]", "A", "A");
    // Still a literal when no range follows: alone, or with `-` last.
    try expectFind("[]]", "x]y", "]");
    try expectFind("[]-]", "-", "-");
    try expectFind("[]-]", "a", null);
    // A backwards range is an error here as anywhere in a class.
    try std.testing.expectError(error.InvalidClass, Regex.compile(gpa, "[]-\x20]"));
}

test "a bare assertion cannot be quantified" {
    // `^*`, `\b+` and the rest are errors in PCRE -- a quantifier must
    // follow a repeatable item -- and repeating something zero-width never
    // meant more than writing it once. zregex used to compile them, which
    // was most of what the oracle generated and threw away before the
    // generator stopped emitting them; now both libraries turn them down.
    try std.testing.expectError(error.NothingToRepeat, Regex.compile(gpa, "^*"));
    try std.testing.expectError(error.NothingToRepeat, Regex.compile(gpa, "$+"));
    try std.testing.expectError(error.NothingToRepeat, Regex.compile(gpa, "\\b?"));
    try std.testing.expectError(error.NothingToRepeat, Regex.compile(gpa, "\\B*"));
    try std.testing.expectError(error.NothingToRepeat, Regex.compile(gpa, "\\A+"));
    try std.testing.expectError(error.NothingToRepeat, Regex.compile(gpa, "\\z?"));
    try std.testing.expectError(error.NothingToRepeat, Regex.compile(gpa, "\\Z{1,2}"));
    try std.testing.expectError(error.NothingToRepeat, Regex.compile(gpa, "a^{2}"));
    // Wrapped in a group it is a repeatable item again, as in PCRE, and so
    // are lookarounds.
    try expectFind("(?m:^)*a", "a", "a");
    try expectFind("(?:\\b)+a", "a", "a");
    try expectFind("(?=a)+a", "aa", "a");
}

test "a shorthand set cannot open a class range" {
    // `[\d-z]` is an error in PCRE, not a class holding a literal dash; the
    // dash is literal only where no range could start -- last, or first.
    try std.testing.expectError(error.InvalidClass, Regex.compile(gpa, "[\\d-z]"));
    try std.testing.expectError(error.InvalidClass, Regex.compile(gpa, "[[:digit:]-z]"));
    try std.testing.expectError(error.InvalidClass, Regex.compile(gpa, "[\\s-x]"));
    try std.testing.expectError(error.InvalidClass, Regex.compile(gpa, "[\\w-\\d]"));
    try expectFind("[\\d-]", "-", "-");
    try expectFind("[[:digit:]-]", "-", "-");
    try expectFind("[-\\d]", "-", "-");
    try expectFind("[\\h-]", "\t", "\t");
}

test "an iteration spends one budget, not one per match" {
    // Each `next` scans a region disjoint from the last, so the per-byte
    // allowance is naturally spent once across an iteration -- but the
    // `max_steps` headroom used to be granted anew at every call, and a
    // haystack alternating cheap matches with expensive stretches could
    // claim it once per match. The iterator now holds every `next` to one
    // pool. Interleave sixty `x` matches with runs of `a` that `(a+)\1$`
    // grinds against: under the old accounting each run fit its own fresh
    // budget and the iteration completed; under one pool it must run dry
    // partway, after real matches have been returned.
    var hay: std.ArrayList(u8) = .empty;
    defer hay.deinit(gpa);
    for (0..60) |_| {
        try hay.append(gpa, 'x');
        for (0..200) |_| try hay.append(gpa, 'a');
    }
    var re = try Regex.compile(gpa, "x|(a+)\\1$");
    defer re.deinit();
    re.max_steps = 5000;
    re.jit_mode = .off;

    var it = re.iterator(gpa, hay.items);
    defer it.deinit();
    var matches: usize = 0;
    var ran_dry = false;
    while (true) {
        const step = it.next() catch |e| {
            try std.testing.expectEqual(error.StepLimitExceeded, e);
            ran_dry = true;
            break;
        };
        var m = step orelse break;
        m.deinit(gpa);
        matches += 1;
    }
    try std.testing.expect(ran_dry);
    try std.testing.expect(matches > 0);
    try std.testing.expect(matches < 60);

    // A haystack dense with matches and nothing expensive between them
    // iterates to the end on the same pool.
    var re2 = try Regex.compile(gpa, "(a)\\1?");
    defer re2.deinit();
    re2.jit_mode = .off;
    hay.clearRetainingCapacity();
    for (0..10_000) |_| try hay.append(gpa, 'a');
    var it2 = re2.iterator(gpa, hay.items);
    defer it2.deinit();
    var n: usize = 0;
    while (try it2.next()) |m| {
        var mm = m;
        mm.deinit(gpa);
        n += 1;
    }
    try std.testing.expectEqual(@as(usize, 5000), n);
}

test "findAt past the end of the haystack finds nothing" {
    // Every engine takes the start as a position to read context around:
    // `\b` and multiline `^` look at the byte before it. Without the bounds
    // check in `findAt`, a start beyond the end was an out-of-bounds read --
    // in a release build `\b` at 105 of a 5-byte haystack read garbage,
    // called it a word character, and returned the span 105..105, outside
    // the haystack; in a debug build this test would have panicked. Found by
    // probing the public API with arguments no fuzzer generates.
    const hay = "aab\u{e9}";
    const patterns = [_][]const u8{ "a+", "\\b", "\\B", "(?m)^a", "(?m)a$", "(?<=a)b", "(a)\\1" };
    for (patterns) |p| {
        var re = try Regex.compile(gpa, p);
        defer re.deinit();
        for ([_]usize{ hay.len + 1, hay.len + 100, std.math.maxInt(usize) }) |start| {
            try std.testing.expectEqual(@as(?zregex.Span, null), blk: {
                const m = try re.findAt(gpa, hay, start);
                if (m) |found| {
                    var mm = found;
                    defer mm.deinit(gpa);
                    break :blk mm.span();
                }
                break :blk null;
            });
        }
    }
    // The end itself is a real position: an empty match and a trailing
    // assertion still hold there.
    var re = try Regex.compile(gpa, "\\b");
    defer re.deinit();
    const m = (try re.findAt(gpa, "ab", 2)) orelse return error.TestUnexpectedResult;
    var mm = m;
    defer mm.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 2), mm.span().start);
}

test "pike capture chains are compacted, and compaction changes nothing" {
    // A run of `(a?)` groups against a long haystack once grew five
    // kilobytes of dead capture chain per input byte -- three hundred
    // megabytes for sixty kilobytes of `a` -- because chain nodes lived in
    // one arena for the whole scan and nearly all of them belonged to
    // threads that died a step later. The Pike VM now compacts: chains still
    // reachable from live threads are copied to a fresh arena and the rest
    // freed. This input is long enough to force the compactor to run about
    // a hundred and fifty times; the captures must come out exactly as the
    // backtracker computes them without any of that machinery.
    var pat: std.ArrayList(u8) = .empty;
    defer pat.deinit(gpa);
    for (0..90) |_| try pat.appendSlice(gpa, "(a?)");
    try pat.appendSlice(gpa, "b");
    var hay: std.ArrayList(u8) = .empty;
    defer hay.deinit(gpa);
    for (0..60_000) |_| try hay.append(gpa, 'a');
    try hay.append(gpa, 'b');

    var re = try Regex.compile(gpa, pat.items);
    defer re.deinit();
    re.jit_mode = .off;
    re.dfa_mode = .off;

    // The equality check runs at a size the backtracker can afford; five
    // hundred positions of ninety optional groups still put ~90,000 nodes
    // through the arena, past the compaction threshold.
    var probe_bt = re;
    probe_bt.fallback_engine = .backtrack;
    var short_hay: std.ArrayList(u8) = .empty;
    defer short_hay.deinit(gpa);
    for (0..500) |_| try short_hay.append(gpa, 'a');
    try short_hay.append(gpa, 'b');
    const short = short_hay.items;
    const mp = (try re.find(gpa, short)) orelse return error.TestUnexpectedResult;
    var pike_m = mp;
    defer pike_m.deinit(gpa);
    const mb = (try probe_bt.find(gpa, short)) orelse return error.TestUnexpectedResult;
    var bt_m = mb;
    defer bt_m.deinit(gpa);
    try std.testing.expectEqualSlices(?zregex.Span, bt_m.groups, pike_m.groups);

    // The full sixty kilobytes -- some hundred and fifty compactions -- on
    // the Pike VM alone: must complete, must find the match at the end.
    const ml = (try re.find(gpa, hay.items)) orelse return error.TestUnexpectedResult;
    var long_m = ml;
    defer long_m.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 60_001), long_m.span().end);
}

test "the backtracker's scratch is bounded like its time" {
    // Slot writes nearly every step of a long budget-legal scan once built
    // fifty megabytes of undo log; the frame stack and undo log are now held
    // to a cap in PCRE2-heap-limit territory, and exceeding it is the same
    // error as exceeding the step budget -- it is the same thing, a bound on
    // what one search may spend. Memoization has carried its own entry cap
    // all along, so it is turned off here to expose the logs themselves.
    var hay: std.ArrayList(u8) = .empty;
    defer hay.deinit(gpa);
    for (0..400_000) |_| try hay.append(gpa, 'a');
    var re = try Regex.compile(gpa, "(?:(a)(a)(a)(a))+\\1z");
    defer re.deinit();
    re.jit_mode = .off;
    re.memo = false;
    try std.testing.expectError(error.StepLimitExceeded, re.find(gpa, hay.items));

    // With memoization on -- the default -- the same scan completes: the
    // memo prunes the re-visits, its table has carried its own entry cap all
    // along, and the logs stay far under the new one.
    var re2 = try Regex.compile(gpa, "(?:(a)(a)(a)(a))+\\1z");
    defer re2.deinit();
    re2.jit_mode = .off;
    const m = try re2.find(gpa, hay.items);
    try std.testing.expect(m == null);
}

test "deep lookaround nesting is bounded, not a stack overflow" {
    // Matching recurses on the native stack once per lookaround: the
    // backtracker's lookaround handling calls back into `matchFrom`, and a
    // lookaround body can hold another. Nesting is capped at compile time
    // (the same `max_depth` that bounds the parser and the compiler's own
    // recursion), so that recursion is bounded too -- this is the same crash
    // class as the concat spine that once segfaulted, checked at the cap
    // rather than left to luck. Two hundred deep compiles and matches; one
    // past it is a clean error, never a crash.
    inline for (.{ "(?=", "(?<=", "(?:" }) |open| {
        const close = ")";
        var at_cap: std.ArrayList(u8) = .empty;
        defer at_cap.deinit(gpa);
        for (0..200) |_| try at_cap.appendSlice(gpa, open);
        try at_cap.append(gpa, 'a');
        for (0..200) |_| try at_cap.appendSlice(gpa, close);
        var re = try Regex.compile(gpa, at_cap.items);
        defer re.deinit();
        const m = try re.find(gpa, "aaaa");
        if (m) |found| {
            var mm = found;
            mm.deinit(gpa);
        }

        var past: std.ArrayList(u8) = .empty;
        defer past.deinit(gpa);
        for (0..201) |_| try past.appendSlice(gpa, open);
        try past.append(gpa, 'a');
        for (0..201) |_| try past.appendSlice(gpa, close);
        try std.testing.expectError(error.NestingTooDeep, Regex.compile(gpa, past.items));
    }
}

test "cases where PCRE2 is the one that is wrong" {
    // Found by tools/oracle.zig. All were checked against Python, which
    // agrees with zregex; the reference is pinned in build.zig.zon, and the
    // generator steers around what that version still gets wrong so the
    // tool reports real differences.

    // Adding `(?i)` can only ever add matches. PCRE2 10.47 lost the match
    // when a caseless class held a wide non-ASCII range; 10.48 fixed it and
    // agrees with these, which stay as plain behavior tests.
    try expectFind("(?i)[\u{a0}-\u{2fff}]+", "Aa\u{20ac}-x", "\u{20ac}");
    try expectFind("[\u{a0}-\u{2fff}]+", "Aa\u{20ac}-x", "\u{20ac}");

    // `X{0}` matches empty, so what follows decides the match. PCRE2 fails
    // the whole pattern for some nullable bodies -- still, as of 10.48, for
    // the last two below; 10.48 fixed the lookaround-bodied ones.
    try expectFind("(?:(?= ){8}){0}A", "A", "A");
    try expectFind("(?:a){0,0}A", "A", "A");
    try expectFind("(?:(?=x)+){0}A", "A", "A");
    // A body that is itself nullable reaches the same PCRE2 failure, and a
    // group wrapped round the repeat still captures the empty span where it
    // stood. Python reports exactly these spans.
    try expectGroups("((|(.*)){0})b", "ab", &.{ "b", "", null, null });
    try expectGroups("((.*){0})b", "ab", &.{ "b", "", null });
}

test "lookbehind at a position inside a multi-byte sequence" {
    // Found by differential fuzzing. The JIT used to step back by the length
    // `decodeBefore` reports and then decode *forward* from there, which is a
    // different operation: starting inside a multi-byte sequence,
    // `decodeBefore` falls back to the single byte before the position, while
    // decoding forward finds the whole sequence, which ends elsewhere.
    var re = try Regex.compile(gpa, "(?<=\u{20ac})");
    defer re.deinit();
    const hay = "ab\u{20ac}"; // '€' occupies bytes 2, 3 and 4
    // Only the position just past the euro qualifies.
    for ([_]usize{ 0, 1, 2, 3, 4 }) |start| {
        var m = (try re.findAt(gpa, hay, start)).?;
        defer m.deinit(gpa);
        try std.testing.expectEqual(@as(usize, 5), m.span().start);
    }
    // And the position itself still qualifies when searched from directly.
    var last = (try re.findAt(gpa, hay, 5)).?;
    defer last.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 5), last.span().start);
    // A negative lookbehind must agree with it position for position.
    var neg = try Regex.compile(gpa, "(?<!\u{20ac})b");
    defer neg.deinit();
    try std.testing.expect(try neg.isMatch(gpa, "ab"));
    try std.testing.expect(!try neg.isMatch(gpa, "\u{20ac}b"));
}

test "searching from inside a multi-byte codepoint" {
    // `findAt` takes any byte offset, including one inside a codepoint. A
    // greedy repeat retrying from there used to step back over the whole
    // codepoint and land before the position the search started at, which
    // reported a match ending before its own start.
    const hay = "ab@aab A\u{20ac}"; // 'A' at 7, euro at 8, 9 and 10
    for ([_][]const u8{ "[\u{a0}-\u{2fff}]*(?<=A)", ".*(?<=A)", "[\u{a0}-\u{2fff}]*(?<=\u{20ac})" }) |pat| {
        var re = try Regex.compile(gpa, pat);
        defer re.deinit();
        for (0..hay.len + 1) |start| {
            const m = try re.findAt(gpa, hay, start);
            if (m) |found| {
                var mm = found;
                defer mm.deinit(gpa);
                const sp = mm.span();
                try std.testing.expect(sp.start >= start);
                try std.testing.expect(sp.start <= sp.end);
                try std.testing.expect(sp.end <= hay.len);
            }
        }
    }
}

test "an empty loop iteration keeps its captures, on every engine" {
    // PCRE and Python run a final iteration that consumes nothing, so the
    // group ends up holding the empty span where the loop stopped rather than
    // the last one that consumed something. The Pike VM used to report the
    // latter: two threads sharing an instruction can disagree about whether
    // the current iteration began at this position, and deduplicating on the
    // instruction alone dropped the higher-priority path that ran the empty
    // iteration. `\s(b|.??)*` also had the wrong *span* for the same reason.
    const cases = [_]struct {
        pat: []const u8,
        hay: []const u8,
        want: []const ?zregex.Span,
    }{
        .{ .pat = "(a*)*", .hay = "aa", .want = &.{ .{ .start = 0, .end = 2 }, .{ .start = 2, .end = 2 } } },
        .{ .pat = "(a|)*", .hay = "aa", .want = &.{ .{ .start = 0, .end = 2 }, .{ .start = 2, .end = 2 } } },
        .{ .pat = "(a*)*b", .hay = "aab", .want = &.{ .{ .start = 0, .end = 3 }, .{ .start = 2, .end = 2 } } },
        .{ .pat = "(a*)+", .hay = "aa", .want = &.{ .{ .start = 0, .end = 2 }, .{ .start = 2, .end = 2 } } },
        .{
            .pat = "(a*)*(b*)*",
            .hay = "aab",
            .want = &.{ .{ .start = 0, .end = 3 }, .{ .start = 2, .end = 2 }, .{ .start = 3, .end = 3 } },
        },
        .{ .pat = "\\s(b|.??)*", .hay = " ba", .want = &.{ .{ .start = 0, .end = 2 }, .{ .start = 2, .end = 2 } } },
        .{ .pat = "(|a)*", .hay = "aa", .want = &.{ .{ .start = 0, .end = 0 }, .{ .start = 0, .end = 0 } } },
        .{ .pat = "(a?)*", .hay = "b", .want = &.{ .{ .start = 0, .end = 0 }, .{ .start = 0, .end = 0 } } },
    };
    for (cases) |c| {
        for ([_]enum { pike, backtrack, jit }{ .pike, .backtrack, .jit }) |which| {
            var re = try Regex.compile(gpa, c.pat);
            defer re.deinit();
            re.dfa_mode = .off;
            switch (which) {
                .jit => {
                    re.jit_mode = .on;
                    if (re.jit_code == null) continue;
                },
                .pike => {
                    re.jit_mode = .off;
                    re.fallback_engine = .pike;
                },
                .backtrack => {
                    re.jit_mode = .off;
                    re.fallback_engine = .backtrack;
                },
            }
            const m = (try re.find(gpa, c.hay)) orelse {
                std.debug.print("pattern={s} on {s}: no match\n", .{ c.pat, c.hay });
                return error.TestUnexpectedResult;
            };
            var mm = m;
            defer mm.deinit(gpa);
            std.testing.expectEqualSlices(?zregex.Span, c.want, mm.groups) catch |err| {
                std.debug.print("pattern={s} haystack={s} engine={t}\n", .{ c.pat, c.hay, which });
                return err;
            };
        }
    }
}

test "many nullable loops still tell empty iterations apart" {
    // The Pike VM keeps threads that disagree about whether the current loop
    // iteration began here from being merged, by putting a bit per empty-loop
    // guard in the visited key. Those bits used to be handed out in the order
    // the guards appeared, and only four of them existed.
    //
    // `x{n}` over a nullable body emits n copies of the loop and so n guards,
    // which ran the four out at n = 5. The guards past the ceiling shared a
    // coarser key, the thread that had run the empty final iteration was
    // merged away, and group 2 came back as 0..1 -- the last iteration that
    // consumed something -- instead of the empty 1..1 that PCRE and Python
    // both report. Bits are handed out per nesting level now, so the copies,
    // which sit side by side rather than inside one another, share one.
    const want = [_]?zregex.Span{
        .{ .start = 0, .end = 2 },
        .{ .start = 0, .end = 1 },
        .{ .start = 1, .end = 1 },
    };
    for ([_]usize{ 1, 2, 4, 5, 6, 9, 17, 40 }) |n| {
        var buf: [32]u8 = undefined;
        const pat = try std.fmt.bufPrint(&buf, "((a{{0,}}?){{0,}}){{{d}}}b", .{n});
        for ([_]enum { pike, dfa, backtrack, jit }{ .pike, .dfa, .backtrack, .jit }) |which| {
            var re = try Regex.compile(gpa, pat);
            defer re.deinit();
            re.dfa_mode = .off;
            re.jit_mode = .off;
            switch (which) {
                .jit => {
                    re.jit_mode = .on;
                    if (re.jit_code == null) continue;
                },
                .dfa => re.dfa_mode = .on,
                .pike => re.fallback_engine = .pike,
                .backtrack => re.fallback_engine = .backtrack,
            }
            const m = (try re.find(gpa, "ab")) orelse {
                std.debug.print("pattern={s} engine={t}: no match\n", .{ pat, which });
                return error.TestUnexpectedResult;
            };
            var mm = m;
            defer mm.deinit(gpa);
            std.testing.expectEqualSlices(?zregex.Span, &want, mm.groups) catch |err| {
                std.debug.print("pattern={s} engine={t}\n", .{ pat, which });
                return err;
            };
        }
    }
}

test "an empty iteration ends the loop only once the minimum is met" {
    // PCRE stops repeating as soon as an iteration consumes nothing, so the
    // mandatory iteration of `e+` ends the loop just as a later one does, and
    // no further iteration can read what it captured. Below the minimum the
    // repeat has to keep going regardless, which is why `{2,}` still reaches
    // a second iteration and matches from 0. Python allows the `+` case;
    // zregex follows PCRE.
    try expectFind("(?:()|[a]\\1)+1", "a1", "1");
    try expectFind("(?:()|[a]\\1)*1", "a1", "1");
    try expectFind("(?:()|[a]\\1){1,}1", "a1", "1");
    try expectFind("(?:()|[a]\\1){2,}1", "a1", "a1");
    // Repeats whose body can match empty but that do consume are unaffected.
    try expectFind("(a*)+", "aa", "aa");
    try expectFind("(a?)+b", "ab", "ab");
}

test "a backreference to the group enclosing it" {
    // PCRE treats a group as unavailable while it is open, so `\1` inside
    // group 1 fails there; zregex reads the value that group captured on its
    // last completed iteration. All but one of these agree with PCRE anyway.
    // The exception is `1(2|\1*)`, left as zregex answers it because PCRE
    // has no single answer to follow: it matches `1(\1*)` but fails
    // `1(2|\1*)`, which differ only in which alternative comes first, and
    // Python rejects the construct outright as a reference to an open group.
    try expectFind("(a\\1)", "a", null);
    try expectFind("1(\\1*)", "1", "1");
    try expectFind("1(2|\\1*)", "1", "1");
    try expectFind("(|[a]\\1)+1", "a1", "1");
}

test "octal escapes, and telling them from backreferences" {
    // PCRE reads `\ddd` as a backreference when the number is under ten or
    // names a group that exists, and as an octal character otherwise. Under
    // ten it is always a backreference, so `\8` is an error rather than a
    // character; inside a class there are no backreferences at all.
    try expectFind("\\101", "A", "A");
    try expectFind("\\11", "\t", "\t");
    try expectFind("\\012a", "\na", "\na");
    try expectFind("[\\1]", "\x01", "\x01");
    // Three digits at most: the fourth is a literal of its own.
    try expectFind("\\1011", "A1", "A1");
    // `\18` is octal 1 followed by a literal 8, since 8 is not an octal digit.
    try expectFind("\\18", "\x018", "\x018");
    // A group that exists still wins.
    try expectFind("(a)\\1", "aa", "aa");
    try std.testing.expectError(error.InvalidBackref, Regex.compile(gpa, "\\1"));
    try std.testing.expectError(error.InvalidBackref, Regex.compile(gpa, "\\8"));
}

test "comptime and runtime compilation agree" {
    // The comptime path builds its program with a separate code path that
    // bakes the result into the binary, so it can drift from the runtime one
    // without any single pattern's test noticing. Run both over a spread of
    // constructs and require identical matches.
    const patterns = .{
        "(\\d{3})-(\\d{4})",
        "(?i)h(?-i:ell)o",
        "(a*)*",
        "\\s(b|.??)*",
        "(?:()|[a]\\1)+1",
        "\\101\\x41",
        "(\\w+)@([\\w.]+)",
        "(?<year>\\d{4})-(?<mon>\\d{2})",
        "a{2,4}?b",
        "(?<=x)y+",
        "(a)(b)?\\1",
        "[^\\d\\s]+",
        "\\bfoo\\b",
        "(?:ab|a)*c",
    };
    const haystacks = [_][]const u8{
        "",            "555-1234", "hello HELLO", "aaa",
        " ba",         "a1",       "AA",          "mail jeff@x.org",
        "2026-08-31",  "aaab",     "xyyy",        "abab",
        "foo bar foo", "ababac",   "\t\n z",
    };
    inline for (patterns) |pat| {
        const ct = comptime Regex.compileComptime(pat);
        var rt = try Regex.compile(gpa, pat);
        defer rt.deinit();
        for (haystacks) |hay| {
            const a = try ct.find(gpa, hay);
            defer if (a) |m| {
                var mm = m;
                mm.deinit(gpa);
            };
            const b = try rt.find(gpa, hay);
            defer if (b) |m| {
                var mm = m;
                mm.deinit(gpa);
            };
            if ((a == null) != (b == null)) {
                std.debug.print("pattern={s} haystack={f}: comptime {} runtime {}\n", .{
                    pat, std.zig.fmtString(hay), a != null, b != null,
                });
                return error.TestUnexpectedResult;
            }
            if (a) |ma| {
                std.testing.expectEqualSlices(?zregex.Span, b.?.groups, ma.groups) catch |err| {
                    std.debug.print("pattern={s} haystack={f}\n", .{ pat, std.zig.fmtString(hay) });
                    return err;
                };
            }
        }
    }
}

test "multiline ^ does not start a line after a trailing newline" {
    // PCRE starts a line after an *internal* newline only. A newline that
    // ends the subject leaves no line after it, so `(?m:^)` has no match at
    // the very end of "a\n" and `(?m:^(?!\n))` does not match "\n" at all.
    try expectFind("(?m:^(?!\\n))", "\n", null);
    try expectFind("(?m:^)x", "\nx", "x");
    try expectFind("(?m:^b)", "a\nb", "b");
    // Line starts in "a\nb" are 0 and 2; in "a\n" and "\n" only 0, since the
    // newline ends the subject.
    try expectStarts("(?m:^)", "a\nb", &.{ 0, 2 });
    try expectStarts("(?m:^)", "a\n", &.{0});
    try expectStarts("(?m:^)", "\n", &.{0});
    // `$` is unaffected: before a final newline and at the end both count.
    try expectStarts("(?m:$)", "a\n", &.{ 1, 2 });
}

/// Every match's start offset, for assertions about zero-width assertions
/// where the matched text says nothing.
fn expectStarts(pattern: []const u8, haystack: []const u8, expected: []const usize) !void {
    var re = try Regex.compile(gpa, pattern);
    defer re.deinit();
    var starts: std.ArrayList(usize) = .empty;
    defer starts.deinit(gpa);
    var it = re.iterator(gpa, haystack);
    defer it.deinit();
    while (try it.next()) |m| {
        var mm = m;
        defer mm.deinit(gpa);
        try starts.append(gpa, mm.span().start);
    }
    try std.testing.expectEqualSlices(usize, expected, starts.items);
}

test "retrying a repeat that started inside a codepoint" {
    // Decoding forward from inside a multi-byte sequence degrades to a single
    // byte, so a run built from such a position advances a byte at a time.
    // Decoding *backwards* from its end finds the whole sequence instead, so
    // a retry that stepped back by that much would land before the position
    // the search started from. The JIT used to give up there and report no
    // match where every interpreter found one.
    const emoji = "\u{1F600}"; // four bytes, so offsets 1..3 are inside it
    for ([_][]const u8{ ".?.", ".?([^b])", ".?(?:-|[^ab]1)", ".{0,2}." }) |pat| {
        var re = try Regex.compile(gpa, pat);
        defer re.deinit();
        for ([_]bool{ false, true }) |use_jit| {
            re.jit_mode = if (use_jit) .on else .off;
            if (use_jit and re.jit_code == null) continue;
            for (0..emoji.len + 1) |start| {
                const m = try re.findAt(gpa, emoji, start);
                if (m) |found| {
                    var mm = found;
                    defer mm.deinit(gpa);
                    const sp = mm.span();
                    try std.testing.expect(sp.start >= start);
                    try std.testing.expect(sp.start <= sp.end);
                }
            }
        }
    }
    // The last byte of the sequence still matches on its own, as a degraded
    // one-byte codepoint, whichever engine runs it.
    var re = try Regex.compile(gpa, ".?.");
    defer re.deinit();
    re.jit_mode = .on;
    const m = try re.findAt(gpa, emoji, 3);
    try std.testing.expect(m != null);
    var mm = m.?;
    defer mm.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 3), mm.span().start);
    try std.testing.expectEqual(@as(usize, 4), mm.span().end);
}
