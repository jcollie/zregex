// SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

//! Behavior tests exercising the full pipeline through both engines.
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
    // Unset group backref matches empty (JS semantics).
    try expectFind("(?:(a)|b)\\1c", "bc", "bc");
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
    var re = try Regex.compile(gpa, "\u{A9}");
    defer re.deinit();
    try std.testing.expect(!re.prefilter.ascii_only);
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
                // For an empty-bodied loop the engines legitimately differ on
                // whether the final empty iteration's captures are kept (see
                // src/fuzz.zig); their match spans still agree.
                const n = if (re.has_loop_guard) 1 else mb.groups.len;
                std.testing.expectEqualSlices(?zregex.Span, mb.groups[0..n], ma.groups[0..n]) catch |err| {
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
                // For an empty-bodied loop the engines legitimately differ on
                // whether the final empty iteration's captures are kept (see
                // src/fuzz.zig); their match spans still agree.
                const n = if (re.has_loop_guard) 1 else mb.groups.len;
                std.testing.expectEqualSlices(?zregex.Span, mb.groups[0..n], ma.groups[0..n]) catch |err| {
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
    try std.testing.expect(try re.isMatch(gpa, "ab"));

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
