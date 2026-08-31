// SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

//! Public API: `Regex`, `Match`, `Span`.
const std = @import("std");
const common = @import("common.zig");
const parser = @import("parser.zig");
const compiler = @import("compiler.zig");
const pike = @import("pike.zig");
const backtrack = @import("backtrack.zig");

pub const Flags = common.Flags;
pub const ParseError = parser.ParseError;
pub const CompileError = ParseError || compiler.CompileError || std.mem.Allocator.Error;
pub const RunError = error{ OutOfMemory, StepLimitExceeded };

/// Byte offsets into the haystack: `[start, end)`.
pub const Span = struct {
    start: usize,
    end: usize,

    pub fn slice(self: Span, haystack: []const u8) []const u8 {
        return haystack[self.start..self.end];
    }
};

pub const Match = struct {
    /// One entry per capture group; index 0 is the whole match and is always
    /// set. A group that did not participate is null.
    groups: []?Span,

    pub fn deinit(self: *Match, gpa: std.mem.Allocator) void {
        gpa.free(self.groups);
        self.* = undefined;
    }

    /// The whole match.
    pub fn span(self: Match) Span {
        return self.groups[0].?;
    }

    pub fn group(self: Match, i: usize) ?Span {
        return if (i < self.groups.len) self.groups[i] else null;
    }
};

/// Which engine executes the compiled program.
pub const Engine = enum {
    /// Pike VM: guaranteed linear time.
    pike,
    /// Budgeted backtracker: needed for backrefs and lookaround.
    backtrack,
};

pub const Regex = struct {
    program: []const compiler.Inst,
    ranges: []const common.ClassRange,
    names: []const parser.NamedGroup,
    group_count: u8,
    slot_count: u16,
    flags: Flags,
    engine: Engine,
    /// Which bytes a match can start with; lets the engines skip ahead.
    prefilter: compiler.Prefilter,
    /// Step budget for the backtracking engine, applied per match attempt
    /// (per start position, like PCRE's match limit); tune per regex if
    /// needed.
    max_steps: usize = default_max_steps,
    /// Backing allocator for owned memory; null for comptime-compiled regexes.
    gpa: ?std.mem.Allocator,
    /// Owned storage for group-name strings (runtime compiles only).
    names_buf: []const u8 = &.{},

    pub const default_max_steps: usize = 1_000_000;

    /// Compile `pattern` at runtime. Free with `deinit`.
    pub fn compile(gpa: std.mem.Allocator, pattern: []const u8) CompileError!Regex {
        return compileWithFlags(gpa, pattern, .{});
    }

    pub fn compileWithFlags(
        gpa: std.mem.Allocator,
        pattern: []const u8,
        flags: Flags,
    ) CompileError!Regex {
        const sizes = parser.bufferSizes(pattern.len);
        const nodes = try gpa.alloc(parser.Node, sizes.nodes);
        defer gpa.free(nodes);
        const ranges_tmp = try gpa.alloc(common.ClassRange, sizes.ranges);
        defer gpa.free(ranges_tmp);
        const names_tmp = try gpa.alloc(parser.NamedGroup, sizes.names);
        defer gpa.free(names_tmp);

        var p = parser.Parser{
            .pattern = pattern,
            .flags = flags,
            .nodes = nodes,
            .ranges = ranges_tmp,
            .names = names_tmp,
        };
        const root = try p.parse();

        const counts = try compiler.count(nodes[0..p.nodes_len], root, p.group_count);
        const insts = try gpa.alloc(compiler.Inst, counts.insts);
        errdefer gpa.free(insts);
        try compiler.emitInto(nodes[0..p.nodes_len], root, p.group_count, insts);

        const ranges = try gpa.dupe(common.ClassRange, ranges_tmp[0..p.ranges_len]);
        errdefer gpa.free(ranges);

        const visited = try gpa.alloc(bool, counts.insts);
        defer gpa.free(visited);
        const pf_stack = try gpa.alloc(u32, counts.insts);
        defer gpa.free(pf_stack);
        const prefilter = compiler.computeFirstBytes(insts, ranges, visited, pf_stack);

        // Group names point into `pattern`, which the caller may free; copy
        // them into one owned buffer.
        var name_bytes: usize = 0;
        for (names_tmp[0..p.names_len]) |ng| name_bytes += ng.name.len;
        const names_buf = try gpa.alloc(u8, name_bytes);
        errdefer gpa.free(names_buf);
        const names = try gpa.alloc(parser.NamedGroup, p.names_len);
        errdefer gpa.free(names);
        var off: usize = 0;
        for (names_tmp[0..p.names_len], 0..) |ng, i| {
            @memcpy(names_buf[off..][0..ng.name.len], ng.name);
            names[i] = .{ .name = names_buf[off..][0..ng.name.len], .index = ng.index };
            off += ng.name.len;
        }

        return .{
            .program = insts,
            .ranges = ranges,
            .names = names,
            .names_buf = names_buf,
            .group_count = p.group_count,
            .slot_count = counts.slots,
            .flags = flags,
            .engine = if (p.has_backref or p.has_look) .backtrack else .pike,
            .prefilter = prefilter,
            .gpa = gpa,
        };
    }

    /// Compile `pattern` at comptime; the program is baked into the binary and
    /// `deinit` is a no-op. Invalid patterns are compile errors. Matching
    /// still takes an allocator (for engine scratch space).
    pub fn compileComptime(comptime pattern: []const u8) Regex {
        return compileComptimeWithFlags(pattern, .{});
    }

    pub fn compileComptimeWithFlags(comptime pattern: []const u8, comptime flags: Flags) Regex {
        comptime {
            @setEvalBranchQuota(10_000_000);
            const sizes = parser.bufferSizes(pattern.len);
            var nodes: [sizes.nodes]parser.Node = undefined;
            var ranges: [sizes.ranges]common.ClassRange = undefined;
            var names: [sizes.names]parser.NamedGroup = undefined;
            var p = parser.Parser{
                .pattern = pattern,
                .flags = flags,
                .nodes = &nodes,
                .ranges = &ranges,
                .names = &names,
            };
            const root = p.parse() catch |e|
                @compileError("zregex: invalid pattern \"" ++ pattern ++ "\": " ++ @errorName(e));
            const counts = compiler.count(nodes[0..p.nodes_len], root, p.group_count) catch |e|
                @compileError("zregex: cannot compile \"" ++ pattern ++ "\": " ++ @errorName(e));
            var insts: [counts.insts]compiler.Inst = undefined;
            compiler.emitInto(nodes[0..p.nodes_len], root, p.group_count, &insts) catch unreachable;

            // Copy into consts so the returned slices refer to static memory.
            const final_insts: [counts.insts]compiler.Inst = insts;
            const final_ranges: [p.ranges_len]common.ClassRange = ranges[0..p.ranges_len].*;
            const final_names: [p.names_len]parser.NamedGroup = names[0..p.names_len].*;

            var visited: [counts.insts]bool = undefined;
            var pf_stack: [counts.insts]u32 = undefined;
            const prefilter = compiler.computeFirstBytes(
                &final_insts,
                &final_ranges,
                &visited,
                &pf_stack,
            );

            return .{
                .program = &final_insts,
                .ranges = &final_ranges,
                .names = &final_names,
                .group_count = p.group_count,
                .slot_count = counts.slots,
                .flags = flags,
                .engine = if (p.has_backref or p.has_look) .backtrack else .pike,
                .prefilter = prefilter,
                .gpa = null,
            };
        }
    }

    pub fn deinit(self: *Regex) void {
        if (self.gpa) |gpa| {
            gpa.free(self.program);
            gpa.free(self.ranges);
            gpa.free(self.names);
            gpa.free(self.names_buf);
        }
        self.* = undefined;
    }

    fn prog(self: *const Regex) compiler.Program {
        return .{
            .insts = self.program,
            .ranges = self.ranges,
            .slot_count = self.slot_count,
            .group_count = self.group_count,
            .prefilter = self.prefilter,
        };
    }

    fn runEngine(
        self: *const Regex,
        gpa: std.mem.Allocator,
        haystack: []const u8,
        start: usize,
        slots: []?usize,
    ) RunError!bool {
        return switch (self.engine) {
            .pike => pike.run(gpa, self.prog(), haystack, start, slots),
            .backtrack => backtrack.run(gpa, self.prog(), haystack, start, slots, self.max_steps),
        };
    }

    /// Does the pattern match anywhere in `haystack`? The allocator is only
    /// used for engine scratch space and is fully released before returning.
    pub fn isMatch(self: *const Regex, gpa: std.mem.Allocator, haystack: []const u8) RunError!bool {
        const slots = try gpa.alloc(?usize, self.slot_count);
        defer gpa.free(slots);
        return self.runEngine(gpa, haystack, 0, slots);
    }

    /// Leftmost match, or null. Free the result with `Match.deinit`.
    pub fn find(self: *const Regex, gpa: std.mem.Allocator, haystack: []const u8) RunError!?Match {
        return self.findAt(gpa, haystack, 0);
    }

    /// Leftmost match at or after byte offset `start`.
    pub fn findAt(
        self: *const Regex,
        gpa: std.mem.Allocator,
        haystack: []const u8,
        start: usize,
    ) RunError!?Match {
        const slots = try gpa.alloc(?usize, self.slot_count);
        defer gpa.free(slots);
        if (!try self.runEngine(gpa, haystack, start, slots)) return null;

        const groups = try gpa.alloc(?Span, self.group_count);
        for (groups, 0..) |*g, i| {
            const a = slots[2 * i];
            const b = slots[2 * i + 1];
            g.* = if (a != null and b != null) .{ .start = a.?, .end = b.? } else null;
        }
        return .{ .groups = groups };
    }

    /// Capture index for a named group, or null.
    pub fn groupIndex(self: *const Regex, name: []const u8) ?u8 {
        for (self.names) |ng| {
            if (std.mem.eql(u8, ng.name, name)) return ng.index;
        }
        return null;
    }

    /// Iterate non-overlapping matches left to right.
    pub fn iterator(self: *const Regex, gpa: std.mem.Allocator, haystack: []const u8) Iterator {
        return .{ .re = self, .gpa = gpa, .haystack = haystack };
    }

    pub const Iterator = struct {
        re: *const Regex,
        gpa: std.mem.Allocator,
        haystack: []const u8,
        pos: usize = 0,
        done: bool = false,

        /// Caller owns the returned Match (free with `Match.deinit`).
        pub fn next(self: *Iterator) RunError!?Match {
            if (self.done) return null;
            const m = (try self.re.findAt(self.gpa, self.haystack, self.pos)) orelse {
                self.done = true;
                return null;
            };
            const sp = m.span();
            if (sp.end > sp.start) {
                self.pos = sp.end;
            } else if (sp.end >= self.haystack.len) {
                self.done = true;
            } else {
                // Empty match: advance one codepoint to avoid looping forever.
                self.pos = sp.end + common.decode(self.haystack, sp.end).len;
            }
            return m;
        }
    };
};
