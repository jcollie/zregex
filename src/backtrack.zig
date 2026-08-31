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
    /// Continuation pc to resume at when this frame fires.
    pc: u32,
    undo_len: u32,
    pos: usize,
    /// rep_greedy: minimum position (retry floor). rep_lazy: iterations left.
    aux: usize = 0,
    /// rep_lazy: pc of the rep instruction (to re-test its child).
    rep_pc: u32 = 0,
    kind: Kind = .alt,

    const Kind = enum(u8) {
        /// Plain alternative: jump to pc at pos.
        alt,
        /// Greedy fused repeat: retry with one fewer iteration until aux.
        rep_greedy,
        /// Lazy fused repeat: retry with one more iteration while aux > 0.
        rep_lazy,
    };
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

/// Does a fused rep's child instruction accept `cp`?
inline fn repAccepts(prog: compiler.Program, child: compiler.Inst, cp: u21) bool {
    return switch (child) {
        .char => |c| common.charEq(c.cp, cp, c.ci),
        .class => |cl| common.classMatches(
            prog.ranges[cl.start..][0..cl.len],
            cl.negated,
            cl.ci,
            cp,
        ),
        .any => true,
        .any_not_nl => cp != '\n',
        else => unreachable, // the compiler only fuses codepoint tests
    };
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

    inline fn setSlot(self: *Bt, slot: u16, value: ?usize) Error!void {
        try self.undo.append(self.gpa, .{ .slot = slot, .old = self.slots[slot] });
        self.slots[slot] = value;
    }

    fn rewindUndo(self: *Bt, to: usize) void {
        while (self.undo.items.len > to) {
            const u = self.undo.pop().?;
            self.slots[u.slot] = u.old;
        }
    }

    /// Execute a fused repeat at `pos`: consume, push the (single) retry
    /// frame, and return the new position — or null when `min` cannot be met.
    /// Kept out of matchFrom so the dispatch loop stays small.
    fn execRep(self: *Bt, r: compiler.RepOp, pc: u32, pos: usize) Error!?usize {
        const input = self.input;
        const child = self.prog.insts[pc + 1];
        const limit: u32 = if (r.greedy) r.max else r.min;
        var count: u32 = 0;
        var p = pos;
        var min_pos = pos; // position after exactly `min` items
        while (count < limit and p < input.len) {
            const d = common.decode(input, p);
            if (!repAccepts(self.prog, child, d.cp)) break;
            p += d.len;
            count += 1;
            if (count == r.min) min_pos = p;
            self.steps += 1;
            if (self.steps > self.max_steps) return error.StepLimitExceeded;
        }
        if (count < r.min) return null;
        if (r.greedy) {
            if (p > min_pos) {
                // One frame covers every shorter retry.
                try self.stack.append(self.gpa, .{
                    .pc = pc + 2,
                    .pos = p,
                    .undo_len = @intCast(self.undo.items.len),
                    .kind = .rep_greedy,
                    .aux = min_pos,
                });
            }
        } else if (r.max > r.min) {
            try self.stack.append(self.gpa, .{
                .pc = pc + 2,
                .pos = p,
                .undo_len = @intCast(self.undo.items.len),
                .kind = .rep_lazy,
                .aux = r.max - r.min,
                .rep_pc = pc,
            });
        }
        return p;
    }

    /// If the lookaround's sub-program is a single consuming instruction,
    /// evaluate it directly: returns whether the sub-program matches, or null
    /// when the general path is needed.
    fn singleCpLook(self: *Bt, l: compiler.LookOp, pos: usize) ?bool {
        if (self.prog.insts[l.target + 1] != .match) return null;
        const child = self.prog.insts[l.target];
        switch (child) {
            .char, .class, .any, .any_not_nl => {},
            else => return null,
        }
        switch (l.kind) {
            .ahead_pos, .ahead_neg => {
                if (pos >= self.input.len) return false;
                return repAccepts(self.prog, child, common.decode(self.input, pos).cp);
            },
            .behind_pos, .behind_neg => {
                if (pos == 0) return false;
                return repAccepts(self.prog, child, common.decodeBefore(self.input, pos).cp);
            },
        }
    }

    /// General lookaround: run the sub-program. Returns whether the
    /// lookaround (including its polarity) succeeds.
    fn lookGeneral(self: *Bt, l: compiler.LookOp, pos: usize) Error!bool {
        const undo_mark = self.undo.items.len;
        switch (l.kind) {
            .ahead_pos => return try self.matchFrom(l.target, pos, null) != null,
            .ahead_neg => {
                if (try self.matchFrom(l.target, pos, null) == null) return true;
                // Sub matched: discard its captures and fail.
                self.rewindUndo(undo_mark);
                return false;
            },
            .behind_pos, .behind_neg => {
                // Try every start whose sub-match ends exactly at `pos`,
                // shortest lookbehind text first. Variable-length lookbehind
                // is supported.
                var s = pos;
                const hit = while (true) {
                    if (try self.matchFrom(l.target, s, pos) != null) break true;
                    if (s == 0) break false;
                    s -= common.decodeBefore(self.input, s).len;
                };
                if (l.kind == .behind_neg) self.rewindUndo(undo_mark);
                return hit == (l.kind == .behind_pos);
            },
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
                        .undo_len = @intCast(self.undo.items.len),
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
                .rep => |r| {
                    if (try self.execRep(r, pc, pos)) |np| {
                        pos = np;
                        pc += 2; // skip the child instruction
                        continue :step;
                    }
                    // min unmet: fall through to backtracking
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
                    // Fast path: a sub-program of one consuming instruction
                    // plus `match` ((?=@), (?<!x), ...) is a direct codepoint
                    // test — no recursion, no frames, no capture effects.
                    if (self.singleCpLook(l, pos)) |hit| {
                        const want = l.kind == .ahead_pos or l.kind == .behind_pos;
                        if (hit == want) {
                            pc += 1;
                            continue :step;
                        }
                        // fall through to backtracking
                    } else if (try self.lookGeneral(l, pos)) {
                        pc += 1;
                        continue :step;
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
            while (self.stack.items.len > stack_base) {
                const top = &self.stack.items[self.stack.items.len - 1];
                self.rewindUndo(top.undo_len);
                switch (top.kind) {
                    .alt => {
                        pc = top.pc;
                        pos = top.pos;
                        _ = self.stack.pop();
                        continue :step;
                    },
                    .rep_greedy => {
                        // Retry the continuation with one fewer iteration.
                        if (top.pos <= top.aux) {
                            _ = self.stack.pop();
                            continue;
                        }
                        top.pos -= common.decodeBefore(input, top.pos).len;
                        pc = top.pc;
                        pos = top.pos;
                        continue :step;
                    },
                    .rep_lazy => {
                        // Retry the continuation with one more iteration.
                        if (top.aux == 0 or top.pos >= input.len) {
                            _ = self.stack.pop();
                            continue;
                        }
                        const child = self.prog.insts[top.rep_pc + 1];
                        const d = common.decode(input, top.pos);
                        if (!repAccepts(self.prog, child, d.cp)) {
                            _ = self.stack.pop();
                            continue;
                        }
                        top.pos += d.len;
                        top.aux -= 1;
                        pc = top.pc;
                        pos = top.pos;
                        continue :step;
                    },
                }
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
    // When the program leads with a greedy unbounded fused rep and there are
    // no backrefs, a failed attempt at s covers every later start inside the
    // run of codepoints the rep consumed (its retry set is a strict subset of
    // ours), so the whole run can be skipped. This turns the classic
    // quadratic leading-\w+ scan linear.
    const lead_skip: ?compiler.Inst = blk: {
        if (prog.insts[0] != .rep) break :blk null;
        const r = prog.insts[0].rep;
        if (!r.greedy or r.max != compiler.RepOp.unbounded) break :blk null;
        for (prog.insts) |inst| {
            // A backref makes the continuation depend on where the match
            // started, invalidating the subsumption argument.
            if (inst == .backref) break :blk null;
        }
        break :blk prog.insts[1];
    };
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
        if (lead_skip) |child| {
            // Skip to the end of the accepting run; the position at the run's
            // end was already tested as a retry of this attempt.
            while (s < input.len) {
                const d = common.decode(input, s);
                if (!repAccepts(prog, child, d.cp)) break;
                s += d.len;
            }
            if (s >= input.len) return false;
        }
        s += common.decode(input, s).len;
    }
}
