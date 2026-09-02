// SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

//! Differential testing against PCRE2, the reference this library's semantics
//! are written against.
//!
//! The in-tree fuzzer checks zregex's engines against each other, which cannot
//! find anything they get wrong together — the empty-loop guard was wrong in
//! every engine at once and only turned up by hand. This runs the same
//! generated patterns through PCRE2 and compares.
//!
//! Needs PCRE2 to link, so it is a separate tool rather than part of
//! `zig build test`:
//!
//!     zig build oracle -Dpcre2-include=<dir> -Dpcre2-lib=<dir> -- [cases] [seed]
//!
//! Comparisons are deliberately narrowed to where both engines claim the same
//! semantics:
//!
//!   * PCRE2 runs in UTF mode, so that `.` and classes count codepoints as
//!     zregex does, and haystacks are restricted to valid UTF-8 — zregex
//!     decodes invalid bytes as one-byte codepoints, which UTF mode rejects
//!     outright rather than defining differently.
//!   * A quantified anchor -- `^*`, `\b+` -- is not generated. zregex
//!     compiles one; PCRE2 turns it down as a quantifier on an unrepeatable
//!     item, and left in it was most of what this tool generated and threw
//!     away. Anything else PCRE2 will not compile is skipped when it comes up.
//!   * Two constructs PCRE2 10.47 gets wrong are not generated — a caseless
//!     class holding a wide non-ASCII range, and a repeat that may run no
//!     iterations at all (`{0}`, and the `{0,0}` that means the same) over
//!     certain bodies — since otherwise the tool mostly reports the
//!     reference's own bugs. Only the *maximum* is held above zero for that
//!     second one: `{0,}` and `{0,m}` are generated, and have to be, since a
//!     nullable loop with a zero minimum is where the Pike VM's guard-bit
//!     ceiling was found to produce a wrong capture. Python agrees with
//!     zregex on both; see the tests in src/tests.zig.
//!   * A backreference to the group that encloses it is not generated.
//!     PCRE2 is not self-consistent there — `1(\1*)` matches but
//!     `1(2|\1*)` does not, though the only difference is which alternative
//!     comes first — and Python rejects the construct outright as a
//!     reference to an open group. zregex matches empty for the zero-width
//!     repeat in both, which is PCRE2's own answer whenever the ordering
//!     does not trip its quirk.
//!
//! Every match is compared, not only the leftmost: `pcre2AllMatches` runs the
//! loop `pcre2demo.c` documents and holds `Regex.Iterator` to it. This used to
//! be left out on the grounds that the two harnesses simply advanced past an
//! empty match differently, which turned out to be the wrong reading -- the
//! rule is PCRE's, Python implements the same one, and zregex did not.
const std = @import("std");
const zregex = @import("zregex");
const gen = @import("pattern_gen");

const c = @cImport({
    @cDefine("PCRE2_CODE_UNIT_WIDTH", "8");
    @cInclude("pcre2.h");
});

/// Both are `~(PCRE2_SIZE)0` in the header, which translate-c cannot render.
const pcre2_zero_terminated: usize = std.math.maxInt(usize);
const pcre2_unset: usize = std.math.maxInt(usize);

/// Capture groups zregex will compile, group 0 included; mirrors
/// `parser.max_groups`, which is not public. A pattern with more than this
/// many is one zregex rejects, so nothing is lost by sizing to it.
const max_groups = 100;

const Result = struct {
    matched: bool,
    /// Start/end pairs, group 0 first; unset groups are `null`. Sized to hold
    /// every group zregex can compile, so a comparison never has to stop
    /// short of what the pattern actually captured.
    groups: [max_groups]?zregex.Span = @splat(null),
    /// Pairs PCRE2 filled. May exceed `groups.len` for a pattern with more
    /// captures than zregex would accept, so every read of `groups` is
    /// clamped to `usable()` rather than to this.
    count: usize = 0,

    /// How many of `groups` actually hold a value.
    fn usable(self: Result) usize {
        return @min(self.count, self.groups.len);
    }
};

/// Set by `runPcre2` when PCRE2 turns a pattern down, so the caller can bucket
/// the reasons rather than just counting them.
var last_pcre2_error: c_int = 0;

fn runPcre2(
    pattern: [:0]const u8,
    hay: []const u8,
    start: usize,
    out: *Result,
    options: u32,
) !bool {
    var errcode: c_int = 0;
    var erroffset: usize = 0;
    const re = c.pcre2_compile_8(
        pattern.ptr,
        pcre2_zero_terminated,
        c.PCRE2_UTF | options,
        &errcode,
        &erroffset,
        null,
    ) orelse {
        last_pcre2_error = errcode;
        return false; // rejected by PCRE2; nothing to compare
    };
    defer c.pcre2_code_free_8(re);

    const md = c.pcre2_match_data_create_from_pattern_8(re, null);
    defer c.pcre2_match_data_free_8(md);

    const rc = c.pcre2_match_8(re, hay.ptr, hay.len, start, 0, md, null);
    if (rc == c.PCRE2_ERROR_NOMATCH) {
        out.* = .{ .matched = false };
        return true;
    }
    if (rc < 0) return false; // budget or UTF error: not a comparison
    const ov = c.pcre2_get_ovector_pointer_8(md);
    out.* = .{ .matched = true, .count = @intCast(rc) };
    for (0..@intCast(rc)) |i| {
        if (i >= out.groups.len) break;
        const a = ov[2 * i];
        const b = ov[2 * i + 1];
        out.groups[i] = if (a == pcre2_unset or b == pcre2_unset)
            null
        else
            .{ .start = a, .end = b };
    }
    return true;
}

/// Run one pattern/haystack on each engine and against PCRE2, reporting all
/// four. Exits non-zero if any engine that can be held to PCRE's captures
/// disagrees, so that a shrinker can drive it. Invoked as:
///
///     zig build oracle ... -- --case '<pattern>' '<haystack>'
fn oneCase(
    gpa: std.mem.Allocator,
    pattern: [:0]const u8,
    subject: []const u8,
    verbose: bool,
    flags: zregex.Flags,
) !u8 {
    var pcre2_options: u32 = 0;
    if (flags.case_insensitive) pcre2_options |= c.PCRE2_CASELESS;
    if (flags.multiline) pcre2_options |= c.PCRE2_MULTILINE;
    if (flags.dot_all) pcre2_options |= c.PCRE2_DOTALL;

    var expected: Result = .{ .matched = false };
    if (!try runPcre2(pattern, subject, 0, &expected, pcre2_options)) {
        if (verbose) std.debug.print("pcre2 rejected the pattern\n", .{});
        return 2;
    }
    if (verbose) {
        std.debug.print("  pcre2:    ", .{});
        if (expected.matched) {
            for (0..expected.usable()) |i| {
                if (expected.groups[i]) |sp| std.debug.print(" {d}..{d}", .{ sp.start, sp.end }) else std.debug.print(" -", .{});
            }
        } else std.debug.print(" no match", .{});
        std.debug.print("\n", .{});
    }

    var bad = false;
    for ([_][]const u8{ "pike", "backtrack", "jit" }) |which| {
        var re = zregex.Regex.compileWithFlags(gpa, pattern, flags) catch {
            if (verbose) std.debug.print("  zregex rejected the pattern\n", .{});
            return 2;
        };
        defer re.deinit();
        re.max_steps = 200_000;
        re.dfa_mode = .off;
        if (std.mem.eql(u8, which, "jit")) {
            re.jit_mode = .on;
            if (re.jit_code == null) continue;
        } else {
            re.jit_mode = .off;
            // A backreference or lookaround has no Pike VM implementation --
            // the compiler routes such patterns to the backtracker and the
            // Pike VM's `unreachable` would be reached. Only override the
            // engine towards the backtracker, never away from it.
            if (std.mem.eql(u8, which, "pike")) {
                if (re.fallback_engine != .pike) continue;
            } else re.fallback_engine = .backtrack;
        }
        const got = re.find(gpa, subject) catch |e| {
            if (verbose) std.debug.print("  {s}: {t}\n", .{ which, e });
            continue;
        };
        defer if (got) |m| {
            var mm = m;
            mm.deinit(gpa);
        };
        if (verbose) {
            std.debug.print("  {s:<9}:", .{which});
            if (got) |m| {
                for (m.groups) |g| {
                    if (g) |sp| std.debug.print(" {d}..{d}", .{ sp.start, sp.end }) else std.debug.print(" -", .{});
                }
            } else std.debug.print(" no match", .{});
            std.debug.print("\n", .{});
        }

        if ((got != null) != expected.matched) {
            bad = true;
        } else if (got) |m| {
            for (m.groups, 0..) |g, i| {
                if (i >= expected.usable()) break;
                const e = expected.groups[i];
                if ((g == null) != (e == null)) bad = true;
                if (g != null and e != null and
                    (g.?.start != e.?.start or g.?.end != e.?.end)) bad = true;
            }
        }
    }
    return if (bad) 1 else 0;
}

/// Cap on matches collected from one subject, on both sides. A pathological
/// pattern should not turn one case into a hang, and agreement over the first
/// several dozen matches is as strong a signal as agreement over all of them.
const max_global_matches = 64;

/// Every match PCRE2 finds in `subject`, by the loop `pcre2demo.c` documents
/// as the way to do it.
///
/// This is the part of matching the oracle used to leave alone: comparing only
/// the leftmost match meant the rule for getting past an empty one -- retry at
/// the same place refusing to match empty, and only then step forward a whole
/// character -- was never held to PCRE at all, though it is where an
/// off-by-one shows up as a duplicated or a missing match rather than as a
/// wrong span.
fn pcre2AllMatches(
    gpa: std.mem.Allocator,
    pattern: [:0]const u8,
    subject: []const u8,
    options: u32,
    out: *std.ArrayList(Result),
) !bool {
    out.clearRetainingCapacity();

    var errcode: c_int = 0;
    var erroffset: usize = 0;
    const re = c.pcre2_compile_8(
        pattern.ptr,
        pcre2_zero_terminated,
        c.PCRE2_UTF | options,
        &errcode,
        &erroffset,
        null,
    ) orelse return false;
    defer c.pcre2_code_free_8(re);

    const md = c.pcre2_match_data_create_from_pattern_8(re, null);
    defer c.pcre2_match_data_free_8(md);

    // `subject.ptr` of an empty slice is not a pointer PCRE2 may read.
    const ptr: [*]const u8 = if (subject.len == 0) "" else subject.ptr;

    var start: usize = 0;
    var match_options: u32 = 0;
    while (out.items.len < max_global_matches) {
        const rc = c.pcre2_match_8(re, ptr, subject.len, start, match_options, md, null);
        if (rc == c.PCRE2_ERROR_NOMATCH) {
            // Nothing at all here, or nothing that is not empty. In the second
            // case the search resumes one character further on.
            if (match_options == 0) break;
            start += 1;
            while (start < subject.len and (subject[start] & 0xC0) == 0x80) start += 1;
            match_options = 0;
            if (start > subject.len) break;
            continue;
        }
        if (rc < 0) return false; // budget or UTF error: not a comparison

        const ov = c.pcre2_get_ovector_pointer_8(md);
        var found: Result = .{ .matched = true, .count = @intCast(rc) };
        for (0..found.usable()) |i| {
            const a = ov[2 * i];
            const b = ov[2 * i + 1];
            found.groups[i] = if (a == pcre2_unset or b == pcre2_unset)
                null
            else
                .{ .start = a, .end = b };
        }
        try out.append(gpa, found);

        // An empty match is retried at the same place, forbidden from being
        // empty again; anything else simply continues from its end.
        if (ov[0] == ov[1]) {
            if (ov[1] >= subject.len) break;
            start = ov[1];
            match_options = c.PCRE2_NOTEMPTY_ATSTART | c.PCRE2_ANCHORED;
        } else {
            start = ov[1];
            match_options = 0;
        }
    }
    return true;
}

/// Compare every match zregex finds against every match PCRE2 finds. Returns
/// null when the case cannot be judged, otherwise whether they agree.
fn compareAllMatches(
    gpa: std.mem.Allocator,
    re: *const zregex.Regex,
    pattern: [:0]const u8,
    subject: []const u8,
    options: u32,
    expected: *std.ArrayList(Result),
) !?bool {
    if (!try pcre2AllMatches(gpa, pattern, subject, options, expected)) return null;

    var it = re.iterator(gpa, subject);
    defer it.deinit();
    var n: usize = 0;
    while (n < max_global_matches) {
        const step = it.next() catch return null; // out of budget: not a comparison
        var m = step orelse break;
        defer m.deinit(gpa);
        if (n >= expected.items.len) return false;
        const want = expected.items[n];
        for (m.groups, 0..) |g, gi| {
            if (gi >= want.usable()) break;
            const e = want.groups[gi];
            if ((g == null) != (e == null)) return false;
            if (g != null and e != null and
                (g.?.start != e.?.start or g.?.end != e.?.end)) return false;
        }
        n += 1;
    }
    // Fewer than the cap on both sides means both ran out; at the cap neither
    // side is finished and only the prefix they share can be judged.
    if (n < max_global_matches and n != expected.items.len) return false;
    return true;
}

/// Print both sides of an all-match disagreement.
fn printAllMatches(
    gpa: std.mem.Allocator,
    re: *const zregex.Regex,
    subject: []const u8,
    expected: *const std.ArrayList(Result),
) !void {
    std.debug.print("  zregex:", .{});
    var it = re.iterator(gpa, subject);
    defer it.deinit();
    var shown: usize = 0;
    while (shown < max_global_matches) : (shown += 1) {
        const step = it.next() catch break;
        var m = step orelse break;
        defer m.deinit(gpa);
        std.debug.print(" {d}..{d}", .{ m.span().start, m.span().end });
    }
    std.debug.print("\n  pcre2: ", .{});
    for (expected.items) |r| {
        if (r.groups[0]) |sp| std.debug.print(" {d}..{d}", .{ sp.start, sp.end });
    }
    std.debug.print("\n", .{});
}

fn spansEqual(a: []const ?zregex.Span, b: []const ?zregex.Span) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if ((x == null) != (y == null)) return false;
        if (x) |xs| {
            if (xs.start != y.?.start or xs.end != y.?.end) return false;
        }
    }
    return true;
}

/// Run one pattern/haystack on every engine and report where they differ,
/// with no reference involved. PCRE2 runs in UTF mode and so cannot judge a
/// haystack holding invalid UTF-8, which is exactly where the engines have
/// disagreed before. Invoked as:
///
///     zig build oracle ... -- --engines '<pattern>' '<haystack>'
fn engineCase(
    gpa: std.mem.Allocator,
    pattern: [:0]const u8,
    subject: []const u8,
    verbose: bool,
    flags: zregex.Flags,
) !u8 {
    const Setting = struct { name: []const u8, apply: *const fn (*zregex.Regex) void };
    const settings = [_]Setting{
        .{ .name = "pike", .apply = struct {
            fn f(re: *zregex.Regex) void {
                re.jit_mode = .off;
                re.dfa_mode = .off;
            }
        }.f },
        .{ .name = "dfa", .apply = struct {
            fn f(re: *zregex.Regex) void {
                re.jit_mode = .off;
                re.dfa_mode = .on;
            }
        }.f },
        .{ .name = "backtrack", .apply = struct {
            fn f(re: *zregex.Regex) void {
                re.jit_mode = .off;
                re.dfa_mode = .off;
                if (re.fallback_engine == .pike) re.fallback_engine = .backtrack;
            }
        }.f },
        .{ .name = "jit", .apply = struct {
            fn f(re: *zregex.Regex) void {
                re.jit_mode = .on;
            }
        }.f },
    };

    var reference: std.ArrayList(?zregex.Span) = .empty;
    defer reference.deinit(gpa);
    var reference_name: []const u8 = "";
    var spans: std.ArrayList(?zregex.Span) = .empty;
    defer spans.deinit(gpa);
    var differ = false;

    for (settings) |setting| {
        var re = zregex.Regex.compileWithFlags(gpa, pattern, flags) catch return 2;
        defer re.deinit();
        re.max_steps = 1_000_000;
        setting.apply(&re);
        if (std.mem.eql(u8, setting.name, "jit") and re.jit_code == null) continue;

        spans.clearRetainingCapacity();
        // Every match, then a search from every offset. Searching from an
        // offset is its own path -- and where the fuzzer last caught these
        // two engines apart -- so a reduction has to keep checking it.
        var it = re.iterator(gpa, subject);
        defer it.deinit();
        var overran = false;
        while (true) {
            const step = it.next() catch |e| {
                if (verbose) std.debug.print("  {s:<10}: {t}\n", .{ setting.name, e });
                overran = true;
                break;
            };
            var mm = step orelse break;
            defer mm.deinit(gpa);
            try spans.appendSlice(gpa, mm.groups);
            if (spans.items.len > 256) break;
        }
        if (overran) continue;
        for (0..subject.len + 1) |start| {
            const m = re.findAt(gpa, subject, start) catch {
                overran = true;
                break;
            };
            if (m) |found| {
                var mm = found;
                defer mm.deinit(gpa);
                try spans.append(gpa, mm.span());
            } else try spans.append(gpa, null);
        }
        if (overran) continue;

        if (verbose) {
            std.debug.print("  {s:<10}:", .{setting.name});
            for (spans.items) |g| {
                if (g) |sp| std.debug.print(" {d}..{d}", .{ sp.start, sp.end }) else std.debug.print(" -", .{});
            }
            std.debug.print("\n", .{});
        }
        if (reference_name.len == 0) {
            reference.clearRetainingCapacity();
            try reference.appendSlice(gpa, spans.items);
            reference_name = setting.name;
        } else if (!spansEqual(reference.items, spans.items)) {
            differ = true;
        }
    }
    return if (differ) 1 else 0;
}

// ---------------------------------------------------------------------------
// PCRE2's own test corpus
//
// The generator writes patterns from a grammar, which means it only ever
// produces what that grammar describes. PCRE2's test files are the opposite
// kind of input: nine thousand patterns written by hand, over decades, mostly
// *because* something once went wrong with them. Running them costs nothing to
// maintain -- they are read from a PCRE2 source tree at the path given, never
// copied in here -- and reaches shapes no grammar of ours would think to make.
//
//     zig build oracle ... -- --corpus <pcre2-source>/testdata
//
// The files are pcre2test scripts. Only the parts that survive translation are
// used: a pattern between `/` delimiters, and the subject lines under it. The
// trailing modifiers are read for `i`, `m` and `s` and otherwise ignored --
// deliberately, since anything not passed to PCRE2 either leaves both
// libraries reading the same pattern the same way, which is all a differential
// comparison needs. A pattern written for `/x` compared as though it were not
// is still a valid comparison; it is simply a different pattern than its
// author meant.

/// One pattern from a test file, with the subjects that followed it.
const CorpusCase = struct {
    pattern: []const u8,
    flags: zregex.Flags,
    subjects: std.ArrayList([]const u8),
};

/// Decode the backslash escapes pcre2test understands in a subject line.
/// Returns false if it meets one this does not know, in which case the caller
/// keeps the line as written -- both libraries still receive the same bytes,
/// so the comparison stays sound either way and only the subject is less
/// interesting than its author intended.
fn decodeSubject(gpa: std.mem.Allocator, line: []const u8, out: *std.ArrayList(u8)) !bool {
    out.clearRetainingCapacity();
    var i: usize = 0;
    while (i < line.len) {
        if (line[i] != '\\') {
            try out.append(gpa, line[i]);
            i += 1;
            continue;
        }
        i += 1;
        if (i >= line.len) return false;
        const esc = line[i];
        i += 1;
        switch (esc) {
            '\\' => try out.append(gpa, '\\'),
            'a' => try out.append(gpa, 0x07),
            'e' => try out.append(gpa, 0x1B),
            'f' => try out.append(gpa, 0x0C),
            'n' => try out.append(gpa, 0x0A),
            'r' => try out.append(gpa, 0x0D),
            't' => try out.append(gpa, 0x09),
            'x' => {
                if (i < line.len and line[i] == '{') {
                    i += 1;
                    const start = i;
                    while (i < line.len and line[i] != '}') i += 1;
                    if (i >= line.len) return false;
                    const cp = std.fmt.parseInt(u21, line[start..i], 16) catch return false;
                    i += 1; // '}'
                    var buf: [4]u8 = undefined;
                    const n = std.unicode.utf8Encode(cp, &buf) catch return false;
                    try out.appendSlice(gpa, buf[0..n]);
                } else {
                    if (i + 2 > line.len) return false;
                    const v = std.fmt.parseInt(u8, line[i..][0..2], 16) catch return false;
                    i += 2;
                    try out.append(gpa, v);
                }
            },
            '0'...'7' => {
                var v: u16 = esc - '0';
                var digits: usize = 1;
                while (digits < 3 and i < line.len and line[i] >= '0' and line[i] <= '7') {
                    v = v * 8 + (line[i] - '0');
                    i += 1;
                    digits += 1;
                }
                if (v > 255) return false;
                try out.append(gpa, @intCast(v));
            },
            else => return false,
        }
    }
    return true;
}

/// Read one pcre2test file into cases. `text` must outlive the result: the
/// patterns and subjects point into it, except where an escape was decoded.
fn parseCorpusFile(
    gpa: std.mem.Allocator,
    text: []const u8,
    cases: *std.ArrayList(CorpusCase),
    owned: *std.ArrayList([]const u8),
) !void {
    var lines: std.ArrayList([]const u8) = .empty;
    defer lines.deinit(gpa);
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |l| try lines.append(gpa, l);

    var i: usize = 0;
    while (i < lines.items.len) {
        const line = lines.items[i];
        // Directives and blank lines carry no pattern.
        if (line.len == 0 or line[0] == '#' or line[0] != '/') {
            i += 1;
            continue;
        }

        // The pattern runs to the next unescaped delimiter, which may be on a
        // later line -- pcre2test allows one to span several.
        var pat: std.ArrayList(u8) = .empty;
        errdefer pat.deinit(gpa);
        var body = line[1..];
        var mods: []const u8 = "";
        var closed = false;
        while (true) {
            var j: usize = 0;
            var esc = false;
            while (j < body.len) : (j += 1) {
                if (esc) {
                    esc = false;
                } else if (body[j] == '\\') {
                    esc = true;
                } else if (body[j] == '/') {
                    try pat.appendSlice(gpa, body[0..j]);
                    mods = body[j + 1 ..];
                    closed = true;
                    break;
                }
            }
            if (closed) break;
            try pat.appendSlice(gpa, body);
            try pat.append(gpa, '\n');
            i += 1;
            if (i >= lines.items.len) break;
            body = lines.items[i];
        }
        i += 1;
        if (!closed) {
            pat.deinit(gpa);
            continue;
        }

        // Only the three flags both libraries spell the same way are read.
        // Everything else is left off both sides; see the note above.
        var flags: zregex.Flags = .{};
        var m: usize = 0;
        while (m < mods.len) : (m += 1) switch (mods[m]) {
            'i' => flags.case_insensitive = true,
            'm' => flags.multiline = true,
            's' => flags.dot_all = true,
            // A modifier word such as `mark` or `dupnames` must not be read
            // one letter at a time, so skip to the next comma.
            'a'...'h', 'j'...'l', 'n'...'r', 't'...'z' => {
                while (m < mods.len and mods[m] != ',') m += 1;
            },
            else => {},
        };

        var subjects: std.ArrayList([]const u8) = .empty;
        errdefer subjects.deinit(gpa);
        while (i < lines.items.len) {
            const raw = lines.items[i];
            if (raw.len == 0 or raw[0] == '#' or raw[0] == '/') break;
            i += 1;
            const t = std.mem.trimStart(u8, raw, " \t");
            // `\=` introduces per-subject directives rather than content.
            if (std.mem.startsWith(u8, t, "\\=")) continue;
            const cut = if (std.mem.indexOf(u8, t, "\\=")) |k| t[0..k] else t;
            if (cut.len == 0) continue;

            var dec: std.ArrayList(u8) = .empty;
            defer dec.deinit(gpa);
            const ok = decodeSubject(gpa, cut, &dec) catch false;
            if (ok) {
                const copy = try gpa.dupe(u8, dec.items);
                try owned.append(gpa, copy);
                try subjects.append(gpa, copy);
            } else {
                try subjects.append(gpa, cut);
            }
        }

        const owned_pat = try pat.toOwnedSlice(gpa);
        try owned.append(gpa, owned_pat);
        try cases.append(gpa, .{
            .pattern = owned_pat,
            .flags = flags,
            .subjects = subjects,
        });
    }
}

/// Compare zregex against PCRE2 over every pattern in a PCRE2 test directory.
fn runCorpus(gpa: std.mem.Allocator, io: std.Io, dir_path: []const u8, verbose: bool) !u8 {
    var dir = std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch |err| {
        std.debug.print("cannot open {s}: {t}\n", .{ dir_path, err });
        return 2;
    };
    defer dir.close(io);

    var files: std.ArrayList([]const u8) = .empty;
    defer {
        for (files.items) |f| gpa.free(f);
        files.deinit(gpa);
    }
    var walker = dir.iterate();
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.startsWith(u8, entry.name, "testinput")) continue;
        try files.append(gpa, try gpa.dupe(u8, entry.name));
    }
    // Iteration order is whatever the filesystem gives; sort so that two runs
    // report the same thing.
    std.mem.sort([]const u8, files.items, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lt);
    if (files.items.len == 0) {
        std.debug.print("no testinput* files in {s}\n", .{dir_path});
        return 2;
    }

    var patterns: usize = 0;
    var compared: usize = 0;
    var skip_zregex: usize = 0;
    var skip_pcre2: usize = 0;
    var skip_budget: usize = 0;
    var disagreements: usize = 0;
    var reject_reasons: std.StringHashMapUnmanaged(usize) = .empty;
    defer reject_reasons.deinit(gpa);
    // A pattern that differs usually differs on every subject under it, and
    // the same pattern often appears in several files. Report each one once.
    // Comparing every match, not just the leftmost, is a separate question
    // with a separate answer: the rule for stepping past an empty match.
    var global_compared: usize = 0;
    var global_bad: usize = 0;
    var global_expected: std.ArrayList(Result) = .empty;
    defer global_expected.deinit(gpa);
    var reported: std.StringHashMapUnmanaged(void) = .empty;
    defer {
        var it3 = reported.keyIterator();
        while (it3.next()) |k| gpa.free(k.*);
        reported.deinit(gpa);
    }

    for (files.items) |name| {
        const text = dir.readFileAlloc(io, name, gpa, .limited(64 << 20)) catch continue;
        defer gpa.free(text);

        var cases: std.ArrayList(CorpusCase) = .empty;
        var owned: std.ArrayList([]const u8) = .empty;
        defer {
            for (cases.items) |*cse| cse.subjects.deinit(gpa);
            cases.deinit(gpa);
            for (owned.items) |o| gpa.free(o);
            owned.deinit(gpa);
        }
        try parseCorpusFile(gpa, text, &cases, &owned);

        for (cases.items) |cse| {
            patterns += 1;
            const pattern = gpa.dupeZ(u8, cse.pattern) catch continue;
            defer gpa.free(pattern);
            // A pattern holding a NUL cannot reach PCRE2 through a C string.
            if (std.mem.indexOfScalar(u8, cse.pattern, 0) != null) continue;

            var re = zregex.Regex.compileWithFlags(gpa, pattern, cse.flags) catch |err| {
                skip_zregex += 1;
                const slot = try reject_reasons.getOrPut(gpa, @errorName(err));
                if (!slot.found_existing) slot.value_ptr.* = 0;
                slot.value_ptr.* += 1;
                continue;
            };
            defer re.deinit();
            re.max_steps = 200_000;

            var pcre2_options: u32 = 0;
            if (cse.flags.case_insensitive) pcre2_options |= c.PCRE2_CASELESS;
            if (cse.flags.multiline) pcre2_options |= c.PCRE2_MULTILINE;
            if (cse.flags.dot_all) pcre2_options |= c.PCRE2_DOTALL;

            for (cse.subjects.items) |subject| {
                // UTF mode is what makes the two agree about what a character
                // is, and it will not accept a subject that is not valid.
                if (!std.unicode.utf8ValidateSlice(subject)) continue;

                var expected: Result = .{ .matched = false };
                if (!(runPcre2(pattern, subject, 0, &expected, pcre2_options) catch false)) {
                    skip_pcre2 += 1;
                    continue;
                }

                if (try compareAllMatches(gpa, &re, pattern, subject, pcre2_options, &global_expected)) |agreed| {
                    global_compared += 1;
                    if (!agreed) {
                        global_bad += 1;
                        const seen_g = try reported.getOrPut(gpa, pattern);
                        if (!seen_g.found_existing) {
                            seen_g.key_ptr.* = try gpa.dupe(u8, pattern);
                            std.debug.print("DISAGREE (all matches) [{s}] pattern={s}\n  haystack={f}\n", .{
                                name, pattern, std.zig.fmtString(subject),
                            });
                            try printAllMatches(gpa, &re, subject, &global_expected);
                        }
                    }
                }

                const got = re.find(gpa, subject) catch {
                    skip_budget += 1;
                    continue;
                };
                defer if (got) |m| {
                    var mm = m;
                    mm.deinit(gpa);
                };
                compared += 1;

                var bad = false;
                if ((got != null) != expected.matched) {
                    bad = true;
                } else if (got) |m| {
                    for (m.groups, 0..) |g, gi| {
                        if (gi >= expected.usable()) break;
                        const e = expected.groups[gi];
                        if ((g == null) != (e == null)) bad = true;
                        if (g != null and e != null and
                            (g.?.start != e.?.start or g.?.end != e.?.end)) bad = true;
                    }
                }
                if (!bad) continue;

                disagreements += 1;
                const seen = try reported.getOrPut(gpa, pattern);
                if (seen.found_existing) continue;
                seen.key_ptr.* = try gpa.dupe(u8, pattern);
                std.debug.print("DISAGREE [{s}] pattern={s} flags={s}{s}{s}\n  haystack={f}\n", .{
                    name,
                    pattern,
                    if (cse.flags.case_insensitive) "i" else "",
                    if (cse.flags.multiline) "m" else "",
                    if (cse.flags.dot_all) "s" else "",
                    std.zig.fmtString(subject),
                });
                std.debug.print("  zregex:", .{});
                if (got) |m| {
                    for (m.groups) |g| {
                        if (g) |sp| std.debug.print(" {d}..{d}", .{ sp.start, sp.end }) else std.debug.print(" -", .{});
                    }
                } else std.debug.print(" no match", .{});
                std.debug.print("\n  pcre2: ", .{});
                if (expected.matched) {
                    for (0..expected.usable()) |gi| {
                        if (expected.groups[gi]) |sp| std.debug.print(" {d}..{d}", .{ sp.start, sp.end }) else std.debug.print(" -", .{});
                    }
                } else std.debug.print(" no match", .{});
                std.debug.print("\n", .{});
            }
        }
        if (verbose) std.debug.print("  {s}: {d} patterns so far\n", .{ name, patterns });
    }

    std.debug.print(
        "corpus: {d} files, {d} patterns, {d} comparisons, skipped (zregex {d}, " ++
            "pcre2 {d}, budget {d}), disagreements {d} over {d} distinct patterns\n" ++
            "corpus all-match comparisons {d}, disagreements {d}\n",
        .{
            files.items.len, patterns,    compared,      skip_zregex,
            skip_pcre2,      skip_budget, disagreements, reported.count(),
            global_compared, global_bad,
        },
    );
    if (reject_reasons.count() != 0) {
        std.debug.print("zregex parse errors:", .{});
        var it2 = reject_reasons.iterator();
        while (it2.next()) |e| std.debug.print(" {s}={d}", .{ e.key_ptr.*, e.value_ptr.* });
        std.debug.print("\n", .{});
    }
    return if (disagreements != 0) 1 else 0;
}

/// Differential testing over mutations of PCRE2's own test patterns.
///
/// The corpus run compares the patterns as written; the generator writes
/// patterns from a grammar of its own. Between the two sits everything a
/// hand-written pattern *almost* says: one quantifier lazier, one bound
/// nudged, two branches spliced from different files. Those neighborhoods
/// are where an off-by-one in the parser or compiler lives, and neither
/// source visits them. This mode does: it loads every corpus pattern, applies
/// a few seeded mutations, and holds the result to PCRE2 the same three ways
/// as the sweep -- leftmost match, every match, and from an offset.
///
///     zig build oracle ... -- --corpus-mutate <pcre2>/testdata [cases] [seed]
fn runCorpusMutate(
    gpa: std.mem.Allocator,
    io: std.Io,
    dir_path: []const u8,
    cases_n: usize,
    seed: u64,
) !u8 {
    var dir = std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch |err| {
        std.debug.print("cannot open {s}: {t}\n", .{ dir_path, err });
        return 2;
    };
    defer dir.close(io);

    // Load every pattern and subject the corpus files hold. The file text
    // must outlive the cases, which point into it.
    var texts: std.ArrayList([]u8) = .empty;
    var cases: std.ArrayList(CorpusCase) = .empty;
    var owned: std.ArrayList([]const u8) = .empty;
    defer {
        for (cases.items) |*cse| cse.subjects.deinit(gpa);
        cases.deinit(gpa);
        for (owned.items) |o| gpa.free(o);
        owned.deinit(gpa);
        for (texts.items) |t| gpa.free(t);
        texts.deinit(gpa);
    }
    var walker = dir.iterate();
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.startsWith(u8, entry.name, "testinput")) continue;
        const text = dir.readFileAlloc(io, entry.name, gpa, .limited(64 << 20)) catch continue;
        try texts.append(gpa, text);
        try parseCorpusFile(gpa, text, &cases, &owned);
    }
    if (cases.items.len == 0) {
        std.debug.print("no corpus patterns under {s}\n", .{dir_path});
        return 2;
    }

    var prng = std.Random.DefaultPrng.init(seed);
    const rand = prng.random();
    // Characters a mutation may write in. Mostly syntax, so an edit has a
    // real chance of still parsing rather than always breaking the pattern.
    const soup = "ab01(){}[]|*+?.^$\\-,:<>=!{}xdswbAZkhv";

    var pat: std.ArrayList(u8) = .empty;
    defer pat.deinit(gpa);
    var compared: usize = 0;
    var skip_zregex: usize = 0;
    var rejected_but_valid: usize = 0;
    var skip_pcre2: usize = 0;
    var skip_budget: usize = 0;
    var disagreements: usize = 0;
    var global_compared: usize = 0;
    var global_bad: usize = 0;
    var global_expected: std.ArrayList(Result) = .empty;
    defer global_expected.deinit(gpa);

    for (0..cases_n) |_| {
        const base = cases.items[rand.uintLessThan(usize, cases.items.len)];
        // Oversized inputs cost time without adding shapes.
        if (base.pattern.len == 0 or base.pattern.len > 200) continue;

        pat.clearRetainingCapacity();
        try pat.appendSlice(gpa, base.pattern);
        const edits = rand.intRangeAtMost(u8, 1, 3);
        for (0..edits) |_| {
            if (pat.items.len == 0) break;
            switch (rand.uintLessThan(u8, 6)) {
                // One character becomes another.
                0 => pat.items[rand.uintLessThan(usize, pat.items.len)] =
                    soup[rand.uintLessThan(usize, soup.len)],
                // One character appears...
                1 => try pat.insert(gpa, rand.uintLessThan(usize, pat.items.len + 1), soup[rand.uintLessThan(usize, soup.len)]),
                // ...or disappears.
                2 => _ = pat.orderedRemove(rand.uintLessThan(usize, pat.items.len)),
                // A quantifier turns lazy, or a literal gains one.
                3 => try pat.insert(gpa, rand.uintLessThan(usize, pat.items.len + 1), '?'),
                // Two adjacent characters swap.
                4 => {
                    if (pat.items.len < 2) continue;
                    const i = rand.uintLessThan(usize, pat.items.len - 1);
                    std.mem.swap(u8, &pat.items[i], &pat.items[i + 1]);
                },
                // Crossover: this pattern's head, another's tail.
                5 => {
                    const other = cases.items[rand.uintLessThan(usize, cases.items.len)].pattern;
                    if (other.len == 0 or other.len > 200) continue;
                    const cut = rand.uintLessThan(usize, pat.items.len);
                    pat.shrinkRetainingCapacity(cut);
                    try pat.appendSlice(gpa, other[rand.uintLessThan(usize, other.len)..]);
                },
                else => unreachable,
            }
        }
        // The pattern reaches PCRE2 as a C string; a NUL would truncate it
        // there and the two libraries would be compared on different input.
        if (std.mem.indexOfScalar(u8, pat.items, 0) != null) continue;
        const pattern = try gpa.dupeZ(u8, pat.items);
        defer gpa.free(pattern);

        // A subject from the base case when it has one, or any other's.
        const donor = if (base.subjects.items.len != 0)
            base
        else
            cases.items[rand.uintLessThan(usize, cases.items.len)];
        if (donor.subjects.items.len == 0) continue;
        const subject = donor.subjects.items[rand.uintLessThan(usize, donor.subjects.items.len)];
        if (!std.unicode.utf8ValidateSlice(subject)) continue;
        if (subject.len > 4096) continue;

        var re = zregex.Regex.compileWithFlags(gpa, pattern, base.flags) catch {
            skip_zregex += 1;
            var probe: Result = .{ .matched = false };
            var opts: u32 = 0;
            if (base.flags.case_insensitive) opts |= c.PCRE2_CASELESS;
            if (base.flags.multiline) opts |= c.PCRE2_MULTILINE;
            if (base.flags.dot_all) opts |= c.PCRE2_DOTALL;
            if (runPcre2(pattern, subject, 0, &probe, opts) catch false) {
                rejected_but_valid += 1;
                if (rejected_but_valid <= 8)
                    std.debug.print("ZREGEX REJECTS (PCRE2 accepts): pattern={s}\n", .{pattern});
            }
            continue;
        };
        defer re.deinit();
        re.max_steps = 200_000;

        var pcre2_options: u32 = 0;
        if (base.flags.case_insensitive) pcre2_options |= c.PCRE2_CASELESS;
        if (base.flags.multiline) pcre2_options |= c.PCRE2_MULTILINE;
        if (base.flags.dot_all) pcre2_options |= c.PCRE2_DOTALL;

        var expected: Result = .{ .matched = false };
        if (!(runPcre2(pattern, subject, 0, &expected, pcre2_options) catch false)) {
            skip_pcre2 += 1;
            continue;
        }
        const got = re.find(gpa, subject) catch {
            skip_budget += 1;
            continue;
        };
        defer if (got) |m| {
            var mm = m;
            mm.deinit(gpa);
        };
        compared += 1;

        var bad = false;
        if ((got != null) != expected.matched) {
            bad = true;
        } else if (got) |m| {
            for (m.groups, 0..) |g, gi| {
                if (gi >= expected.usable()) break;
                const e = expected.groups[gi];
                if ((g == null) != (e == null)) bad = true;
                if (g != null and e != null and
                    (g.?.start != e.?.start or g.?.end != e.?.end)) bad = true;
            }
        }
        if (bad) {
            disagreements += 1;
            if (disagreements <= 15) {
                std.debug.print("DISAGREE (mutated) pattern={s} flags={s}{s}{s}\n  haystack={f}\n", .{
                    pattern,
                    if (base.flags.case_insensitive) "i" else "",
                    if (base.flags.multiline) "m" else "",
                    if (base.flags.dot_all) "s" else "",
                    std.zig.fmtString(subject),
                });
            }
        }

        if (try compareAllMatches(gpa, &re, pattern, subject, pcre2_options, &global_expected)) |agreed| {
            global_compared += 1;
            if (!agreed) {
                global_bad += 1;
                if (global_bad <= 15) {
                    std.debug.print("DISAGREE (mutated, all matches) pattern={s}\n  haystack={f}\n", .{
                        pattern, std.zig.fmtString(subject),
                    });
                    try printAllMatches(gpa, &re, subject, &global_expected);
                }
            }
        }
    }
    std.debug.print(
        "mutated: {d} compared, skipped (zregex {d} — of which {d} PCRE2 accepts, " ++
            "pcre2 {d}, budget {d}), disagreements {d}; all-match {d}, disagreements {d}\n",
        .{
            compared,    skip_zregex,   rejected_but_valid, skip_pcre2,
            skip_budget, disagreements, global_compared,    global_bad,
        },
    );
    return if (disagreements != 0 or global_bad != 0) 1 else 0;
}

pub fn main(init: std.process.Init) !void {
    const gpa = std.heap.smp_allocator;
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);

    if (args.len > 1 and std.mem.eql(u8, args[1], "--corpus-mutate")) {
        if (args.len < 3) {
            std.debug.print("usage: --corpus-mutate <pcre2-source>/testdata [cases] [seed]\n", .{});
            std.process.exit(2);
        }
        const n: usize = if (args.len > 3) try std.fmt.parseInt(usize, args[3], 10) else 20000;
        const sd: u64 = if (args.len > 4) try std.fmt.parseInt(u64, args[4], 10) else 0x5eed;
        std.process.exit(try runCorpusMutate(gpa, init.io, args[2], n, sd));
    }

    if (args.len > 1 and std.mem.eql(u8, args[1], "--corpus")) {
        if (args.len < 3) {
            std.debug.print("usage: --corpus <pcre2-source>/testdata\n", .{});
            std.process.exit(2);
        }
        std.process.exit(try runCorpus(gpa, init.io, args[2], args.len > 3 and
            std.mem.eql(u8, args[3], "-v")));
    }

    // Trailing options for the two single-case modes: `-q` shrinks quietly,
    // since only the exit status matters then, and a run of `i`/`m`/`s` sets
    // the same top-level flags the sweep reports beside a disagreement --
    // without which one found under flags could not be reproduced here.
    var verbose = true;
    var cli_flags: zregex.Flags = .{};
    if (args.len > 4) {
        for (args[4..]) |opt| {
            if (std.mem.eql(u8, opt, "-q")) {
                verbose = false;
                continue;
            }
            for (opt) |ch| switch (ch) {
                'i' => cli_flags.case_insensitive = true,
                'm' => cli_flags.multiline = true,
                's' => cli_flags.dot_all = true,
                else => {
                    std.debug.print("unknown option: {s}\n", .{opt});
                    std.process.exit(2);
                },
            };
        }
    }

    if (args.len > 1 and std.mem.eql(u8, args[1], "--engines")) {
        if (args.len < 4) {
            std.debug.print("usage: --engines <pattern> <haystack> [ims] [-q]\n", .{});
            std.process.exit(2);
        }
        const pat = try arena.dupeZ(u8, args[2]);
        std.process.exit(try engineCase(gpa, pat, args[3], verbose, cli_flags));
    }

    if (args.len > 1 and std.mem.eql(u8, args[1], "--case")) {
        if (args.len < 4) {
            std.debug.print("usage: --case <pattern> <haystack> [ims] [-q]\n", .{});
            std.process.exit(2);
        }
        std.process.exit(try oneCase(gpa, try arena.dupeZ(u8, args[2]), args[3], verbose, cli_flags));
    }

    const cases: usize = if (args.len > 1) try std.fmt.parseInt(usize, args[1], 10) else 20000;
    const seed: u64 = if (args.len > 2) try std.fmt.parseInt(u64, args[2], 10) else 0x0_c1e_5eed;

    var prng = std.Random.DefaultPrng.init(seed);
    const src = gen.Source{ .random = prng.random() };

    // One evaluation of a pattern: which engine to pin it to, and whether
    // that engine's captures can be held to PCRE's.
    const View = struct {
        label: []const u8,
        force: enum { none, backtrack, jit } = .none,
    };

    var compared: usize = 0;
    var skipped: usize = 0;
    var disagreements: usize = 0;
    // Comparing every match, not just the leftmost, is a separate question
    // with a separate answer: the rule for stepping past an empty match.
    var global_compared: usize = 0;
    var global_bad: usize = 0;
    var offset_compared: usize = 0;
    var offset_bad: usize = 0;
    var global_expected: std.ArrayList(Result) = .empty;
    defer global_expected.deinit(gpa);
    // Why cases are dropped, so that coverage can be aimed at the biggest
    // bucket rather than guessed at.
    var skip_zregex: usize = 0;
    var rejected_but_valid: usize = 0;
    var skip_pcre2: usize = 0;
    var skip_budget: usize = 0;
    // Which parse errors the generator runs into, so that a production
    // emitting mostly-invalid patterns shows up as a bucket rather than as a
    // quietly reduced comparison count.
    var reject_reasons: std.StringHashMapUnmanaged(usize) = .empty;
    defer reject_reasons.deinit(gpa);
    var pcre2_reasons: std.StringHashMapUnmanaged(usize) = .empty;
    defer {
        var it = pcre2_reasons.keyIterator();
        while (it.next()) |k| gpa.free(k.*);
        pcre2_reasons.deinit(gpa);
    }

    for (0..cases) |_| {
        var b = gen.Builder{ .src = src, .gpa = gpa, .avoid_pcre2_quirks = true };
        // As in the in-tree fuzzer, a minority of cases are much larger, so
        // that deep nesting and many capture groups get compared too.
        if (src.index(8) == 0) {
            b.depth_limit = 7;
            b.length_limit = 400;
            b.group_limit = 40;
        }
        defer b.buf.deinit(gpa);
        try b.sequence(0);
        if (b.buf.items.len == 0) continue;
        const pattern = try gpa.dupeZ(u8, b.buf.items);
        defer gpa.free(pattern);

        var hay: std.ArrayList(u8) = .empty;
        defer hay.deinit(gpa);
        // Most haystacks stay short, where a difference is easiest to read
        // back. A minority are long, with long runs of one piece: the SIMD
        // scanners, the lead-byte run skip and the prefilter only engage past
        // a vector block, and a mistake shared by every zregex engine there
        // is invisible to the in-tree fuzzer, which has no reference.
        if (src.intRange(u8, 0, 5) == 0) {
            const runs = src.intRange(u8, 1, 6);
            for (0..runs) |_| {
                const piece = gen.chunks[src.index(gen.chunks.len)];
                if (!std.unicode.utf8ValidateSlice(piece)) continue;
                const reps = src.intRange(u16, 1, 150);
                for (0..reps) |_| try hay.appendSlice(gpa, piece);
                const sep = gen.chunks[src.index(gen.chunks.len)];
                if (std.unicode.utf8ValidateSlice(sep)) try hay.appendSlice(gpa, sep);
            }
        } else {
            const n = src.intRange(u8, 0, 20);
            for (0..n) |_| {
                const piece = gen.chunks[src.index(gen.chunks.len)];
                // UTF mode will not accept the deliberately invalid pieces.
                if (std.unicode.utf8ValidateSlice(piece)) try hay.appendSlice(gpa, piece);
            }
        }

        // An empty ArrayList's pointer is undefined; PCRE2 dereferences it.
        const subject: []const u8 = if (hay.items.len == 0) "" else hay.items;

        // Usually the defaults, but now and then a flag is set for the whole
        // pattern rather than written into it. Both libraries take the same
        // three, so this is a real comparison rather than a skipped case --
        // and setting them from outside starts the parser somewhere an
        // inline `(?i:...)` never does.
        var flags: zregex.Flags = .{};
        var pcre2_options: u32 = 0;
        if (src.index(4) == 0) {
            flags = .{
                .case_insensitive = src.boolean(),
                .multiline = src.boolean(),
                .dot_all = src.boolean(),
            };
            if (flags.case_insensitive) pcre2_options |= c.PCRE2_CASELESS;
            if (flags.multiline) pcre2_options |= c.PCRE2_MULTILINE;
            if (flags.dot_all) pcre2_options |= c.PCRE2_DOTALL;
        }

        var re = zregex.Regex.compileWithFlags(gpa, pattern, flags) catch |err| {
            skipped += 1;
            skip_zregex += 1;
            const slot = try reject_reasons.getOrPut(gpa, @errorName(err));
            if (!slot.found_existing) slot.value_ptr.* = 0;
            slot.value_ptr.* += 1;
            // A pattern zregex turns down that PCRE2 compiles is a gap in
            // this library, not a case to skip quietly. Report a few.
            var probe: Result = .{ .matched = false };
            if (runPcre2(pattern, subject, 0, &probe, pcre2_options) catch false) {
                rejected_but_valid += 1;
                if (rejected_but_valid <= 12) {
                    std.debug.print("ZREGEX REJECTS (PCRE2 accepts): {t}  pattern={s}\n", .{ err, pattern });
                }
            }
            continue;
        };
        defer re.deinit();
        re.max_steps = 200_000;

        var expected: Result = .{ .matched = false };
        if (!try runPcre2(pattern, subject, 0, &expected, pcre2_options)) {
            skipped += 1;
            skip_pcre2 += 1;
            var msg: [128]u8 = undefined;
            const len = c.pcre2_get_error_message_8(last_pcre2_error, &msg, msg.len);
            if (len > 0) {
                const slot = try pcre2_reasons.getOrPut(gpa, msg[0..@intCast(len)]);
                if (!slot.found_existing) {
                    slot.key_ptr.* = try gpa.dupe(u8, msg[0..@intCast(len)]);
                    slot.value_ptr.* = 0;
                }
                slot.value_ptr.* += 1;
            }
            continue;
        }

        // Each engine is compared against PCRE2 separately, not just the one
        // `Regex` would have picked. They are meant to agree, and the in-tree
        // fuzzer checks that they do, but a bug reaching only one of them is
        // otherwise invisible here whenever the engine policy routes around
        // it -- which is how the empty-loop guard stayed wrong for so long.
        var views: [3]View = undefined;
        var view_count: usize = 0;
        views[view_count] = .{ .label = "default" };
        view_count += 1;
        if (re.fallback_engine == .pike) {
            views[view_count] = .{ .label = "backtrack", .force = .backtrack };
            view_count += 1;
        }
        if (re.jit_code != null) {
            views[view_count] = .{ .label = "jit", .force = .jit };
            view_count += 1;
        }

        // Searching from an offset against PCRE2's startoffset. Both define
        // the same thing: the match may not begin before `start`, but `\b`,
        // `^` and lookbehind still see the text in front of it -- searching
        // a slice would be a different question with different answers. The
        // engines were long compared against each other here; this is the
        // reference finally judging them too.
        offsets: for (0..2) |_| {
            if (subject.len == 0) break;
            var off = src.index(subject.len + 1);
            // PCRE2 refuses an offset inside a UTF-8 sequence outright
            // rather than defining it; step back to the boundary.
            while (off > 0 and off < subject.len and subject[off] & 0xC0 == 0x80) off -= 1;

            var at_expected: Result = .{ .matched = false };
            if (!(runPcre2(pattern, subject, off, &at_expected, pcre2_options) catch false)) continue;
            const got_at = re.findAt(gpa, subject, off) catch continue;
            defer if (got_at) |m| {
                var mm = m;
                mm.deinit(gpa);
            };
            offset_compared += 1;

            var bad_at = false;
            if ((got_at != null) != at_expected.matched) {
                bad_at = true;
            } else if (got_at) |m| {
                for (m.groups, 0..) |g, gi| {
                    if (gi >= at_expected.usable()) break;
                    const e = at_expected.groups[gi];
                    if ((g == null) != (e == null)) bad_at = true;
                    if (g != null and e != null and
                        (g.?.start != e.?.start or g.?.end != e.?.end)) bad_at = true;
                }
            }
            if (!bad_at) continue :offsets;
            offset_bad += 1;
            if (offset_bad <= 10) {
                std.debug.print("DISAGREE (findAt {d}) pattern={s} flags={s}{s}{s}\n  haystack={f}\n", .{
                    off,
                    pattern,
                    if (flags.case_insensitive) "i" else "",
                    if (flags.multiline) "m" else "",
                    if (flags.dot_all) "s" else "",
                    std.zig.fmtString(subject),
                });
                std.debug.print("  zregex:", .{});
                if (got_at) |m| {
                    for (m.groups) |g| {
                        if (g) |sp| std.debug.print(" {d}..{d}", .{ sp.start, sp.end }) else std.debug.print(" -", .{});
                    }
                } else std.debug.print(" no match", .{});
                std.debug.print("\n  pcre2: ", .{});
                if (at_expected.matched) {
                    for (0..at_expected.usable()) |gi| {
                        if (at_expected.groups[gi]) |sp| std.debug.print(" {d}..{d}", .{ sp.start, sp.end }) else std.debug.print(" -", .{});
                    }
                } else std.debug.print(" no match", .{});
                std.debug.print("\n", .{});
            }
        }

        // The iterator runs whichever engine the pattern selected, so this is
        // asked once per case rather than once per view.
        if (try compareAllMatches(gpa, &re, pattern, subject, pcre2_options, &global_expected)) |agreed| {
            global_compared += 1;
            if (!agreed) {
                global_bad += 1;
                if (global_bad <= 10) {
                    std.debug.print("DISAGREE (all matches) pattern={s} flags={s}{s}{s}\n  haystack={f}\n", .{
                        pattern,
                        if (flags.case_insensitive) "i" else "",
                        if (flags.multiline) "m" else "",
                        if (flags.dot_all) "s" else "",
                        std.zig.fmtString(subject),
                    });
                    try printAllMatches(gpa, &re, subject, &global_expected);
                }
            }
        }

        var counted = false;
        for (views[0..view_count]) |view| {
            switch (view.force) {
                .none => {},
                .backtrack => {
                    re.fallback_engine = .backtrack;
                    re.jit_mode = .off;
                    re.dfa_mode = .off;
                },
                .jit => re.jit_mode = .on,
            }

            const got = re.find(gpa, subject) catch {
                if (!counted) {
                    skipped += 1;
                    skip_budget += 1;
                }
                continue;
            };
            defer if (got) |m| {
                var mm = m;
                mm.deinit(gpa);
            };

            if (!counted) {
                compared += 1;
                counted = true;
            }

            var bad = false;
            if ((got != null) != expected.matched) {
                bad = true;
            } else if (got) |m| {
                for (m.groups, 0..) |g, i| {
                    if (i >= expected.usable()) break;
                    const e = expected.groups[i];
                    if ((g == null) != (e == null)) bad = true;
                    if (g != null and e != null and
                        (g.?.start != e.?.start or g.?.end != e.?.end)) bad = true;
                }
            }
            if (bad) {
                disagreements += 1;
                std.debug.print("DISAGREE pattern={s} engine={s} flags={s}{s}{s}\n  haystack={f}\n", .{
                    pattern,
                    view.label,
                    if (flags.case_insensitive) "i" else "",
                    if (flags.multiline) "m" else "",
                    if (flags.dot_all) "s" else "",
                    std.zig.fmtString(subject),
                });
                std.debug.print("  zregex:", .{});
                if (got) |m| {
                    for (m.groups) |g| {
                        if (g) |sp| std.debug.print(" {d}..{d}", .{ sp.start, sp.end }) else std.debug.print(" -", .{});
                    }
                } else std.debug.print(" no match", .{});
                std.debug.print("\n  pcre2: ", .{});
                if (expected.matched) {
                    for (0..expected.usable()) |i| {
                        if (expected.groups[i]) |sp| std.debug.print(" {d}..{d}", .{ sp.start, sp.end }) else std.debug.print(" -", .{});
                    }
                } else std.debug.print(" no match", .{});
                std.debug.print("\n", .{});
            }
        }
        if (disagreements >= 10) break;
    }
    std.debug.print(
        "compared {d}, skipped {d} (zregex rejected {d} — of which {d} PCRE2 " ++
            "accepts, pcre2 rejected {d}, budget {d}), disagreements {d}\n",
        .{ compared, skipped, skip_zregex, rejected_but_valid, skip_pcre2, skip_budget, disagreements },
    );
    std.debug.print("all-match comparisons {d}, disagreements {d}\n", .{ global_compared, global_bad });
    std.debug.print("findAt comparisons {d}, disagreements {d}\n", .{ offset_compared, offset_bad });
    if (reject_reasons.count() != 0) {
        std.debug.print("zregex parse errors:", .{});
        var it = reject_reasons.iterator();
        while (it.next()) |e| std.debug.print(" {s}={d}", .{ e.key_ptr.*, e.value_ptr.* });
        std.debug.print("\n", .{});
    }
    if (pcre2_reasons.count() != 0) {
        std.debug.print("pcre2 parse errors:\n", .{});
        var it = pcre2_reasons.iterator();
        while (it.next()) |e| std.debug.print("  {d:>6}  {s}\n", .{ e.value_ptr.*, e.key_ptr.* });
    }
    if (disagreements != 0) std.process.exit(1);
}
