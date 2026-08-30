// SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

//! Compiles the parser's AST into bytecode shared by both engines.
//!
//! The compiler runs in two modes over identical code paths: a counting pass
//! that only measures (`counting = true`), and an emitting pass that writes
//! into an exactly-sized buffer. Determinism guarantees both passes agree,
//! which is what lets comptime compilation size its arrays without an
//! allocator.
const std = @import("std");
const common = @import("common.zig");
const parser = @import("parser.zig");

/// Hard cap on program length; counted repeats can expand a lot.
pub const max_insts: u32 = 1 << 16;

pub const CharOp = struct {
    cp: u21,
    /// ASCII case-insensitive.
    ci: bool,
};

pub const ClassOp = struct {
    start: u32,
    len: u32,
    negated: bool,
    ci: bool,
};

pub const BackrefOp = struct {
    group: u8,
    ci: bool,
};

pub const LookOp = struct {
    kind: parser.LookKind,
    /// pc of the sub-program, which ends with its own `match`.
    target: u32,
};

pub const Inst = union(enum) {
    /// Consume one codepoint equal to this (mod case folding).
    char: CharOp,
    /// Consume any codepoint.
    any,
    /// Consume any codepoint except '\n'.
    any_not_nl,
    /// Consume one codepoint matching the class.
    class: ClassOp,
    /// Try [0] first (higher priority), then [1].
    split: [2]u32,
    jmp: u32,
    /// slots[n] = current position.
    save: u16,
    assert: common.Assertion,
    match,
    /// Consume text equal to what the capture group matched.
    backref: BackrefOp,
    /// Zero-width lookaround running a sub-program.
    look: LookOp,
    /// Scratch slot write, guards empty-body loops.
    set_pos: u16,
    /// Kill this path if no progress since `set_pos` on the same slot.
    fail_if_same: u16,
};

/// A compiled program plus everything needed to run it.
pub const Program = struct {
    insts: []const Inst,
    ranges: []const common.ClassRange,
    /// 2 per capture group, then scratch slots for loop guards.
    slot_count: u16,
    /// Includes group 0.
    group_count: u8,
};

pub const CompileError = error{ProgramTooLarge};

pub const Counts = struct {
    insts: u32,
    slots: u16,
};

pub const Compiler = struct {
    nodes: []const parser.Node,
    counting: bool,
    insts: []Inst,
    len: u32 = 0,
    next_slot: u16,

    const Self = @This();

    fn emit(self: *Self, inst: Inst) CompileError!u32 {
        if (self.len >= max_insts) return error.ProgramTooLarge;
        if (!self.counting) self.insts[self.len] = inst;
        self.len += 1;
        return self.len - 1;
    }

    fn patchSplit(self: *Self, at: u32, targets: [2]u32) void {
        if (!self.counting) self.insts[at] = .{ .split = targets };
    }

    fn patchJmp(self: *Self, at: u32, target: u32) void {
        if (!self.counting) self.insts[at] = .{ .jmp = target };
    }

    fn compileRoot(self: *Self, root: parser.NodeIndex) CompileError!void {
        _ = try self.emit(.{ .save = 0 });
        try self.emitNode(root);
        _ = try self.emit(.{ .save = 1 });
        _ = try self.emit(.match);
    }

    fn emitNode(self: *Self, idx: parser.NodeIndex) CompileError!void {
        switch (self.nodes[idx]) {
            .empty => {},
            .literal => |l| _ = try self.emit(.{ .char = .{ .cp = l.cp, .ci = l.ci } }),
            .any => |nl| _ = try self.emit(if (nl) .any else .any_not_nl),
            .class => |cl| _ = try self.emit(.{ .class = .{
                .start = cl.start,
                .len = cl.len,
                .negated = cl.negated,
                .ci = cl.ci,
            } }),
            .concat => |ab| {
                try self.emitNode(ab[0]);
                try self.emitNode(ab[1]);
            },
            .alt => |ab| {
                const s = try self.emit(.{ .split = .{ 0, 0 } });
                const a_start = self.len;
                try self.emitNode(ab[0]);
                const j = try self.emit(.{ .jmp = 0 });
                const b_start = self.len;
                try self.emitNode(ab[1]);
                self.patchSplit(s, .{ a_start, b_start });
                self.patchJmp(j, self.len);
            },
            .repeat => |r| {
                var i: u32 = 0;
                while (i < r.min) : (i += 1) try self.emitNode(r.child);
                if (r.max) |m| {
                    try self.emitOptChain(m - r.min, r.child, r.greedy);
                } else {
                    try self.emitStar(r.child, r.greedy);
                }
            },
            .group => |g| {
                if (g.index) |gi| {
                    _ = try self.emit(.{ .save = 2 * @as(u16, gi) });
                    try self.emitNode(g.child);
                    _ = try self.emit(.{ .save = 2 * @as(u16, gi) + 1 });
                } else {
                    try self.emitNode(g.child);
                }
            },
            .assertion => |a| _ = try self.emit(.{ .assert = a }),
            .backref => |b| _ = try self.emit(.{ .backref = .{ .group = b.index, .ci = b.ci } }),
            .look => |l| {
                const j = try self.emit(.{ .jmp = 0 });
                const sub = self.len;
                try self.emitNode(l.child);
                _ = try self.emit(.match);
                self.patchJmp(j, self.len);
                _ = try self.emit(.{ .look = .{ .kind = l.kind, .target = sub } });
            },
        }
    }

    /// `e*` (or the unbounded tail of `e{n,}`). Bodies that can match empty
    /// get a progress guard so backtracking terminates.
    fn emitStar(self: *Self, child: parser.NodeIndex, greedy: bool) CompileError!void {
        const guarded = self.nullable(child);
        var slot: u16 = 0;
        if (guarded) {
            slot = self.next_slot;
            self.next_slot += 1;
        }
        const top = self.len;
        const s = try self.emit(.{ .split = .{ 0, 0 } });
        const body = self.len;
        if (guarded) _ = try self.emit(.{ .set_pos = slot });
        try self.emitNode(child);
        if (guarded) _ = try self.emit(.{ .fail_if_same = slot });
        _ = try self.emit(.{ .jmp = top });
        const exit = self.len;
        self.patchSplit(s, if (greedy) .{ body, exit } else .{ exit, body });
    }

    /// `e{0,n}` as a chain of nested options: skipping one copy skips them all.
    fn emitOptChain(self: *Self, n: u32, child: parser.NodeIndex, greedy: bool) CompileError!void {
        if (n == 0) return;
        const s = try self.emit(.{ .split = .{ 0, 0 } });
        const body = self.len;
        try self.emitNode(child);
        try self.emitOptChain(n - 1, child, greedy);
        const exit = self.len;
        self.patchSplit(s, if (greedy) .{ body, exit } else .{ exit, body });
    }

    /// Can this subtree match the empty string?
    fn nullable(self: *Self, idx: parser.NodeIndex) bool {
        return switch (self.nodes[idx]) {
            .empty, .assertion, .look => true,
            .literal, .class, .any => false,
            .concat => |ab| self.nullable(ab[0]) and self.nullable(ab[1]),
            .alt => |ab| self.nullable(ab[0]) or self.nullable(ab[1]),
            .repeat => |r| r.min == 0 or self.nullable(r.child),
            .group => |g| self.nullable(g.child),
            .backref => true,
        };
    }
};

/// Counting pass: how many instructions and slots `root` compiles to.
pub fn count(
    nodes: []const parser.Node,
    root: parser.NodeIndex,
    group_count: u8,
) CompileError!Counts {
    var c = Compiler{
        .nodes = nodes,
        .counting = true,
        .insts = &.{},
        .next_slot = 2 * @as(u16, group_count),
    };
    try c.compileRoot(root);
    return .{ .insts = c.len, .slots = c.next_slot };
}

/// Emitting pass: writes exactly `count().insts` instructions into `insts`.
pub fn emitInto(
    nodes: []const parser.Node,
    root: parser.NodeIndex,
    group_count: u8,
    insts: []Inst,
) CompileError!void {
    var c = Compiler{
        .nodes = nodes,
        .counting = false,
        .insts = insts,
        .next_slot = 2 * @as(u16, group_count),
    };
    try c.compileRoot(root);
    std.debug.assert(c.len == insts.len);
}

// ---------------------------------------------------------------------------
// Tests

fn compileForTest(
    gpa: std.mem.Allocator,
    pattern: []const u8,
    flags: common.Flags,
) !struct { insts: []Inst, slots: u16, p: u8 } {
    const sizes = parser.bufferSizes(pattern.len);
    const nodes = try gpa.alloc(parser.Node, sizes.nodes);
    defer gpa.free(nodes);
    const ranges = try gpa.alloc(common.ClassRange, sizes.ranges);
    defer gpa.free(ranges);
    var names: [parser.max_groups]parser.NamedGroup = undefined;
    var p = parser.Parser{
        .pattern = pattern,
        .flags = flags,
        .nodes = nodes,
        .ranges = ranges,
        .names = &names,
    };
    const root = try p.parse();
    const counts = try count(p.nodes[0..p.nodes_len], root, p.group_count);
    const insts = try gpa.alloc(Inst, counts.insts);
    errdefer gpa.free(insts);
    try emitInto(p.nodes[0..p.nodes_len], root, p.group_count, insts);
    return .{ .insts = insts, .slots = counts.slots, .p = p.group_count };
}

test "count matches emit and programs are well-formed" {
    const gpa = std.testing.allocator;
    const patterns = [_][]const u8{
        "abc",
        "a|b|c",
        "a*b+?c{2,4}d{3}e{2,}",
        "(a(?<n>b))\\1\\k<n>",
        "[^a-z]\\d\\S.",
        "(?=ab)c(?<!d)",
        "(?:a*)*b",
        "x{0,5}?",
    };
    for (patterns) |pat| {
        const r = try compileForTest(gpa, pat, .{});
        defer gpa.free(r.insts);
        try std.testing.expect(r.insts.len >= 3); // save 0, save 1, match
        try std.testing.expect(r.insts[0].save == 0);
        // All jump targets must be in range.
        for (r.insts) |inst| switch (inst) {
            .split => |t| {
                try std.testing.expect(t[0] < r.insts.len);
                try std.testing.expect(t[1] < r.insts.len);
            },
            .jmp => |t| try std.testing.expect(t < r.insts.len),
            .look => |l| try std.testing.expect(l.target < r.insts.len),
            .save => |s| try std.testing.expect(s < r.slots),
            .set_pos, .fail_if_same => |s| try std.testing.expect(s < r.slots),
            else => {},
        };
    }
}

test "nullable star bodies get progress guards" {
    const gpa = std.testing.allocator;
    const r = try compileForTest(gpa, "(?:a*)*", .{});
    defer gpa.free(r.insts);
    var has_guard = false;
    for (r.insts) |inst| {
        if (inst == .fail_if_same) has_guard = true;
    }
    try std.testing.expect(has_guard);
    // Non-nullable body: no guard.
    const r2 = try compileForTest(gpa, "a*", .{});
    defer gpa.free(r2.insts);
    for (r2.insts) |inst| try std.testing.expect(inst != .fail_if_same);
}

test "program size cap" {
    const gpa = std.testing.allocator;
    try std.testing.expectError(
        error.ProgramTooLarge,
        compileForTest(gpa, "(?:(?:(?:a{1000}){1000}){1000})", .{}),
    );
}
