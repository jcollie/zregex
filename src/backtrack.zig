// SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

//! Backtracking engine: runs the same bytecode as the Pike VM but supports
//! `backref` and `look`. Worst case is exponential, so every run carries a
//! step budget; exceeding it returns `error.StepLimitExceeded`.
//!
//! Backtracking state lives on an explicit heap stack (frames) plus an undo
//! log for slot writes, so deep backtracking cannot overflow the call stack.
//! Lookarounds are atomic (no backtracking into them once matched), matching
//! PCRE semantics.
const std = @import("std");
const common = @import("common.zig");
const compiler = @import("compiler.zig");

pub const Error = error{ OutOfMemory, StepLimitExceeded };

const Frame = struct {
    pc: u32,
    pos: usize,
    undo_len: usize,
};

const Undo = struct {
    slot: u16,
    old: ?usize,
};

/// ASCII-case-insensitive byte equality; multi-byte UTF-8 units fold to
/// themselves, so byte-wise folding is exact for our ASCII-only `ci`.
fn bytesEqFold(a: []const u8, b: []const u8, ci: bool) bool {
    if (a.len != b.len) return false;
    if (!ci) return std.mem.eql(u8, a, b);
    for (a, b) |x, y| {
        if (common.foldLower(x) != common.foldLower(y)) return false;
    }
    return true;
}

const Bt = struct {
    gpa: std.mem.Allocator,
    prog: compiler.Program,
    input: []const u8,
    slots: []?usize,
    stack: std.ArrayList(Frame) = .empty,
    undo: std.ArrayList(Undo) = .empty,
    steps: usize = 0,
    max_steps: usize,

    fn setSlot(self: *Bt, slot: u16, value: ?usize) Error!void {
        try self.undo.append(self.gpa, .{ .slot = slot, .old = self.slots[slot] });
        self.slots[slot] = value;
    }

    fn rewindUndo(self: *Bt, to: usize) void {
        while (self.undo.items.len > to) {
            const u = self.undo.pop().?;
            self.slots[u.slot] = u.old;
        }
    }

    /// Anchored attempt from (`pc0`, `pos0`); returns the end position on
    /// success, null on failure. If `required_end` is set, `match` only
    /// succeeds at exactly that position (used for lookbehind).
    ///
    /// On success, frames pushed by this attempt are discarded (lookarounds are
    /// atomic) and slot writes are kept. On failure, slots are rewound.
    fn matchFrom(self: *Bt, pc0: u32, pos0: usize, required_end: ?usize) Error!?usize {
        const stack_base = self.stack.items.len;
        const undo_base = self.undo.items.len;
        const insts = self.prog.insts;
        const input = self.input;
        var pc = pc0;
        var pos = pos0;

        step: while (true) {
            self.steps += 1;
            if (self.steps > self.max_steps) return error.StepLimitExceeded;

            // Arms that succeed `continue :step`; falling out of the switch
            // means this path failed and we backtrack.
            switch (insts[pc]) {
                .char => |c| if (pos < input.len) {
                    const d = common.decode(input, pos);
                    if (common.charEq(c.cp, d.cp, c.ci)) {
                        pos += d.len;
                        pc += 1;
                        continue :step;
                    }
                },
                .any => if (pos < input.len) {
                    pos += common.decode(input, pos).len;
                    pc += 1;
                    continue :step;
                },
                .any_not_nl => if (pos < input.len) {
                    const d = common.decode(input, pos);
                    if (d.cp != '\n') {
                        pos += d.len;
                        pc += 1;
                        continue :step;
                    }
                },
                .class => |cl| if (pos < input.len) {
                    const d = common.decode(input, pos);
                    const ranges = self.prog.ranges[cl.start..][0..cl.len];
                    if (common.classMatches(ranges, cl.negated, cl.ci, d.cp)) {
                        pos += d.len;
                        pc += 1;
                        continue :step;
                    }
                },
                .assert => |a| if (common.assertHolds(a, input, pos)) {
                    pc += 1;
                    continue :step;
                },
                .jmp => |t| {
                    pc = t;
                    continue :step;
                },
                .split => |t| {
                    try self.stack.append(self.gpa, .{
                        .pc = t[1],
                        .pos = pos,
                        .undo_len = self.undo.items.len,
                    });
                    pc = t[0];
                    continue :step;
                },
                .save => |s| {
                    try self.setSlot(s, pos);
                    pc += 1;
                    continue :step;
                },
                .set_pos => |s| {
                    try self.setSlot(s, pos);
                    pc += 1;
                    continue :step;
                },
                .fail_if_same => |s| if (self.slots[s] != pos) {
                    pc += 1;
                    continue :step;
                },
                .backref => |br| {
                    const a = self.slots[2 * @as(u16, br.group)];
                    const b = self.slots[2 * @as(u16, br.group) + 1];
                    if (a == null or b == null) {
                        // Unset group: matches empty (JS semantics).
                        pc += 1;
                        continue :step;
                    }
                    const text = input[a.?..b.?];
                    if (pos + text.len <= input.len and
                        bytesEqFold(text, input[pos..][0..text.len], br.ci))
                    {
                        pos += text.len;
                        pc += 1;
                        continue :step;
                    }
                },
                .look => |l| {
                    const undo_mark = self.undo.items.len;
                    switch (l.kind) {
                        .ahead_pos => {
                            if (try self.matchFrom(l.target, pos, null) != null) {
                                pc += 1;
                                continue :step;
                            }
                        },
                        .ahead_neg => {
                            if (try self.matchFrom(l.target, pos, null) == null) {
                                pc += 1;
                                continue :step;
                            }
                            // Sub matched: discard its captures and fail.
                            self.rewindUndo(undo_mark);
                        },
                        .behind_pos, .behind_neg => {
                            // Try every start whose sub-match ends exactly at
                            // `pos`, shortest lookbehind text first. Variable-
                            // length lookbehind is supported.
                            var s = pos;
                            const hit = while (true) {
                                if (try self.matchFrom(l.target, s, pos) != null) break true;
                                if (s == 0) break false;
                                s -= common.decodeBefore(input, s).len;
                            };
                            if (hit == (l.kind == .behind_pos)) {
                                if (l.kind == .behind_neg) self.rewindUndo(undo_mark);
                                pc += 1;
                                continue :step;
                            }
                            if (l.kind == .behind_neg) self.rewindUndo(undo_mark);
                        },
                    }
                },
                .match => {
                    if (required_end == null or pos == required_end.?) {
                        self.stack.shrinkRetainingCapacity(stack_base);
                        return pos;
                    }
                },
            }

            // Failed: backtrack to the most recent alternative of this attempt.
            if (self.stack.items.len > stack_base) {
                const f = self.stack.pop().?;
                self.rewindUndo(f.undo_len);
                pc = f.pc;
                pos = f.pos;
                continue :step;
            }
            self.rewindUndo(undo_base);
            return null;
        }
    }
};

/// Unanchored search from byte offset `start`. On success fills `slots_out`
/// and returns true. Leftmost-greedy semantics.
pub fn run(
    gpa: std.mem.Allocator,
    prog: compiler.Program,
    input: []const u8,
    start: usize,
    slots_out: []?usize,
    max_steps: usize,
) Error!bool {
    var bt = Bt{
        .gpa = gpa,
        .prog = prog,
        .input = input,
        .slots = slots_out,
        .max_steps = max_steps,
    };
    defer bt.stack.deinit(gpa);
    defer bt.undo.deinit(gpa);
    @memset(slots_out, null);

    const pf = &prog.prefilter;
    var s = start;
    while (true) {
        if (pf.usable) {
            // A usable prefilter implies the pattern cannot match empty, so
            // skipping non-candidate positions (including end of input) is
            // sound.
            s = pf.scan(input, s);
            if (s >= input.len) return false;
        }
        // The budget is per match attempt (like PCRE's match limit): each
        // start position gets a fresh allowance, so scanning a large haystack
        // is not itself budget-limited while any single attempt stays bounded.
        bt.steps = 0;
        if (try bt.matchFrom(0, s, null)) |end| {
            // Group 0 has no save instructions; fill it here.
            slots_out[0] = s;
            slots_out[1] = end;
            return true;
        }
        if (s >= input.len) return false;
        s += common.decode(input, s).len;
    }
}
