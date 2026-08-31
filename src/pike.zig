// SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

//! Pike VM: breadth-first NFA simulation with capture slots.
//!
//! Guaranteed O(input * program) time regardless of the pattern. Handles every
//! instruction except `backref` and `look` — patterns using those are routed
//! to the backtracker by `Regex.compile`.
const std = @import("std");
const common = @import("common.zig");
const compiler = @import("compiler.zig");

const Thread = struct {
    pc: u32,
    slots: []?usize,
};

const ThreadList = struct {
    items: []Thread,
    len: usize = 0,

    fn append(self: *ThreadList, t: Thread) void {
        // Capacity is insts.len and pcs are deduped, so this cannot overflow.
        self.items[self.len] = t;
        self.len += 1;
    }
};

const Ctx = struct {
    prog: compiler.Program,
    input: []const u8,
    arena: std.mem.Allocator,
    /// Generation marks per pc; a pc is in a list iff seen[pc] == that list's gen.
    seen: []u32,
    /// DFS stack for epsilon closure.
    stack: []Thread,

    fn tryEnter(self: *Ctx, gen: u32, pc: u32) bool {
        if (self.seen[pc] == gen) return false;
        self.seen[pc] = gen;
        return true;
    }

    /// Add `pc0` and its epsilon closure to `list` in priority (DFS) order.
    fn addThread(self: *Ctx, list: *ThreadList, gen: u32, pc0: u32, pos: usize, slots0: []?usize) !void {
        if (!self.tryEnter(gen, pc0)) return;
        var sp: usize = 0;
        self.stack[sp] = .{ .pc = pc0, .slots = slots0 };
        sp += 1;
        next_path: while (sp > 0) {
            sp -= 1;
            var pc = self.stack[sp].pc;
            var slots = self.stack[sp].slots;
            while (true) {
                switch (self.prog.insts[pc]) {
                    .jmp => |t| {
                        if (!self.tryEnter(gen, t)) continue :next_path;
                        pc = t;
                    },
                    .split => |t| {
                        if (self.tryEnter(gen, t[1])) {
                            self.stack[sp] = .{ .pc = t[1], .slots = slots };
                            sp += 1;
                        }
                        if (!self.tryEnter(gen, t[0])) continue :next_path;
                        pc = t[0];
                    },
                    .save => |s| {
                        const copy = try self.arena.dupe(?usize, slots);
                        copy[s] = pos;
                        slots = copy;
                        if (!self.tryEnter(gen, pc + 1)) continue :next_path;
                        pc += 1;
                    },
                    .set_pos => |s| {
                        const copy = try self.arena.dupe(?usize, slots);
                        copy[s] = pos;
                        slots = copy;
                        if (!self.tryEnter(gen, pc + 1)) continue :next_path;
                        pc += 1;
                    },
                    .fail_if_same => |s| {
                        if (slots[s] == pos) continue :next_path;
                        if (!self.tryEnter(gen, pc + 1)) continue :next_path;
                        pc += 1;
                    },
                    .assert => |a| {
                        if (!common.assertHolds(a, self.input, pos)) continue :next_path;
                        if (!self.tryEnter(gen, pc + 1)) continue :next_path;
                        pc += 1;
                    },
                    // Consuming instructions and `match` land in the list.
                    .char, .any, .any_not_nl, .class, .match => {
                        list.append(.{ .pc = pc, .slots = slots });
                        continue :next_path;
                    },
                    .backref, .look => unreachable, // never routed to the Pike VM
                }
            }
        }
    }
};

/// Unanchored search from byte offset `start`. On success fills `slots_out`
/// (length `prog.slot_count`) and returns true. Leftmost-greedy semantics.
pub fn run(
    gpa: std.mem.Allocator,
    prog: compiler.Program,
    input: []const u8,
    start: usize,
    slots_out: []?usize,
) std.mem.Allocator.Error!bool {
    const n = prog.insts.len;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var ctx = Ctx{
        .prog = prog,
        .input = input,
        .arena = arena,
        .seen = try arena.alloc(u32, n),
        .stack = try arena.alloc(Thread, n),
    };
    @memset(ctx.seen, 0);

    var clist = ThreadList{ .items = try arena.alloc(Thread, n) };
    var nlist = ThreadList{ .items = try arena.alloc(Thread, n) };

    const base_slots = try arena.alloc(?usize, prog.slot_count);
    @memset(base_slots, null);

    const pf = &prog.prefilter;
    var gen: u32 = 1;
    var pos = start;
    var matched = false;

    while (true) {
        // With no live threads and no match yet, only candidate first bytes
        // matter: skip straight to the next one.
        if (!matched and clist.len == 0 and pf.usable) {
            pos = pf.scan(input, pos);
            if (pos >= input.len) break;
        }
        const d: ?common.DecodeResult = if (pos < input.len) common.decode(input, pos) else null;

        // Seed a new lowest-priority thread at this position until we have a
        // match; this is what makes the search unanchored and leftmost.
        if (!matched and (!pf.usable or (pos < input.len and pf.bytes[input[pos]]))) {
            try ctx.addThread(&clist, gen, 0, pos, base_slots);
        }

        var i: usize = 0;
        while (i < clist.len) : (i += 1) {
            const th = clist.items[i];
            switch (prog.insts[th.pc]) {
                .char => |c| if (d) |dd| {
                    if (common.charEq(c.cp, dd.cp, c.ci))
                        try ctx.addThread(&nlist, gen + 1, th.pc + 1, pos + dd.len, th.slots);
                },
                .any => if (d) |dd| {
                    try ctx.addThread(&nlist, gen + 1, th.pc + 1, pos + dd.len, th.slots);
                },
                .any_not_nl => if (d) |dd| {
                    if (dd.cp != '\n')
                        try ctx.addThread(&nlist, gen + 1, th.pc + 1, pos + dd.len, th.slots);
                },
                .class => |cl| if (d) |dd| {
                    const ranges = prog.ranges[cl.start..][0..cl.len];
                    if (common.classMatches(ranges, cl.negated, cl.ci, dd.cp))
                        try ctx.addThread(&nlist, gen + 1, th.pc + 1, pos + dd.len, th.slots);
                },
                .match => {
                    // Every thread after i is lower priority: discard them.
                    // Threads already in nlist are higher priority and may
                    // still improve (lengthen) the match on later steps.
                    @memcpy(slots_out, th.slots);
                    matched = true;
                    break;
                },
                else => unreachable, // epsilon closure resolved everything else
            }
        }

        if (d == null) break;
        pos += d.?.len;
        std.mem.swap(ThreadList, &clist, &nlist);
        nlist.len = 0;
        gen += 1;
        if (clist.len == 0 and matched) break;
    }
    return matched;
}
