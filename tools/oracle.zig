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
//!   * Patterns PCRE2 will not compile are skipped; it rejects some that
//!     zregex accepts, such as a quantified anchor.
//!   * Two constructs PCRE2 10.47 gets wrong are not generated — a caseless
//!     class holding a wide non-ASCII range, and a `{0}` repeat over certain
//!     bodies — since otherwise the tool mostly reports the reference's own
//!     bugs. Python agrees with zregex on both; see the tests in src/tests.zig.
//!   * A backreference to the group that encloses it is not generated.
//!     PCRE2 is not self-consistent there — `1(\1*)` matches but
//!     `1(2|\1*)` does not, though the only difference is which alternative
//!     comes first — and Python rejects the construct outright as a
//!     reference to an open group. zregex matches empty for the zero-width
//!     repeat in both, which is PCRE2's own answer whenever the ordering
//!     does not trip its quirk.
//!   * Only the leftmost match is compared, so the two harnesses' differing
//!     rules for advancing past an empty match never come into it.
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

const Result = struct {
    matched: bool,
    /// Start/end pairs, group 0 first; unset groups are `null`.
    groups: [20]?zregex.Span = @splat(null),
    count: usize = 0,
};

fn runPcre2(pattern: [:0]const u8, hay: []const u8, out: *Result) !bool {
    var errcode: c_int = 0;
    var erroffset: usize = 0;
    const re = c.pcre2_compile_8(
        pattern.ptr,
        pcre2_zero_terminated,
        c.PCRE2_UTF,
        &errcode,
        &erroffset,
        null,
    ) orelse return false; // rejected by PCRE2; nothing to compare
    defer c.pcre2_code_free_8(re);

    const md = c.pcre2_match_data_create_from_pattern_8(re, null);
    defer c.pcre2_match_data_free_8(md);

    const rc = c.pcre2_match_8(re, hay.ptr, hay.len, 0, 0, md, null);
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
fn oneCase(gpa: std.mem.Allocator, pattern: [:0]const u8, subject: []const u8, verbose: bool) !u8 {
    var expected: Result = .{ .matched = false };
    if (!try runPcre2(pattern, subject, &expected)) {
        if (verbose) std.debug.print("pcre2 rejected the pattern\n", .{});
        return 2;
    }
    if (verbose) {
        std.debug.print("  pcre2:    ", .{});
        if (expected.matched) {
            for (0..expected.count) |i| {
                if (expected.groups[i]) |sp| std.debug.print(" {d}..{d}", .{ sp.start, sp.end }) else std.debug.print(" -", .{});
            }
        } else std.debug.print(" no match", .{});
        std.debug.print("\n", .{});
    }

    var bad = false;
    for ([_][]const u8{ "pike", "backtrack", "jit" }) |which| {
        var re = zregex.Regex.compile(gpa, pattern) catch {
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
                if (i >= expected.count) break;
                const e = expected.groups[i];
                if ((g == null) != (e == null)) bad = true;
                if (g != null and e != null and
                    (g.?.start != e.?.start or g.?.end != e.?.end)) bad = true;
            }
        }
    }
    return if (bad) 1 else 0;
}

pub fn main(init: std.process.Init) !void {
    const gpa = std.heap.smp_allocator;
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);

    if (args.len > 1 and std.mem.eql(u8, args[1], "--case")) {
        if (args.len < 4) {
            std.debug.print("usage: --case <pattern> <haystack>\n", .{});
            std.process.exit(2);
        }
        const pat = try arena.dupeZ(u8, args[2]);
        // `-q` shrinks quietly: only the exit status matters then.
        const verbose = args.len < 5 or !std.mem.eql(u8, args[4], "-q");
        std.process.exit(try oneCase(gpa, pat, args[3], verbose));
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
    // Why cases are dropped, so that coverage can be aimed at the biggest
    // bucket rather than guessed at.
    var skip_zregex: usize = 0;
    var skip_pcre2: usize = 0;
    var skip_budget: usize = 0;

    for (0..cases) |_| {
        var b = gen.Builder{ .src = src, .gpa = gpa, .avoid_pcre2_quirks = true };
        defer b.buf.deinit(gpa);
        try b.sequence(0);
        if (b.buf.items.len == 0) continue;
        const pattern = try gpa.dupeZ(u8, b.buf.items);
        defer gpa.free(pattern);

        var hay: std.ArrayList(u8) = .empty;
        defer hay.deinit(gpa);
        const n = src.intRange(u8, 0, 20);
        for (0..n) |_| {
            const piece = gen.chunks[src.index(gen.chunks.len)];
            // UTF mode will not accept the deliberately invalid pieces.
            if (std.unicode.utf8ValidateSlice(piece)) try hay.appendSlice(gpa, piece);
        }

        // An empty ArrayList's pointer is undefined; PCRE2 dereferences it.
        const subject: []const u8 = if (hay.items.len == 0) "" else hay.items;

        var re = zregex.Regex.compile(gpa, pattern) catch {
            skipped += 1;
            skip_zregex += 1;
            continue;
        };
        defer re.deinit();
        re.max_steps = 200_000;

        var expected: Result = .{ .matched = false };
        if (!try runPcre2(pattern, subject, &expected)) {
            skipped += 1;
            skip_pcre2 += 1;
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
                    if (i >= expected.count) break;
                    const e = expected.groups[i];
                    if ((g == null) != (e == null)) bad = true;
                    if (g != null and e != null and
                        (g.?.start != e.?.start or g.?.end != e.?.end)) bad = true;
                }
            }
            if (bad) {
                disagreements += 1;
                std.debug.print("DISAGREE pattern={s} engine={s}\n  haystack={f}\n", .{
                    pattern, view.label, std.zig.fmtString(subject),
                });
                std.debug.print("  zregex:", .{});
                if (got) |m| {
                    for (m.groups) |g| {
                        if (g) |sp| std.debug.print(" {d}..{d}", .{ sp.start, sp.end }) else std.debug.print(" -", .{});
                    }
                } else std.debug.print(" no match", .{});
                std.debug.print("\n  pcre2: ", .{});
                if (expected.matched) {
                    for (0..expected.count) |i| {
                        if (expected.groups[i]) |sp| std.debug.print(" {d}..{d}", .{ sp.start, sp.end }) else std.debug.print(" -", .{});
                    }
                } else std.debug.print(" no match", .{});
                std.debug.print("\n", .{});
            }
        }
        if (disagreements >= 10) break;
    }
    std.debug.print(
        "compared {d}, skipped {d} (zregex rejected {d}, pcre2 rejected {d}, " ++
            "budget {d}), disagreements {d}\n",
        .{ compared, skipped, skip_zregex, skip_pcre2, skip_budget, disagreements },
    );
    if (disagreements != 0) std.process.exit(1);
}
