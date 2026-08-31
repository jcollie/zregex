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

/// One capture-slot write. Threads share history: a save prepends a node
/// instead of cloning an array, so branching costs nothing and a save is one
/// small arena allocation. The latest write for a slot is the first hit
/// walking from the head.
const SlotNode = struct {
    slot: u16,
    pos: usize,
    prev: ?*const SlotNode,
};

fn slotLookup(chain: ?*const SlotNode, slot: u16) ?usize {
    var node = chain;
    while (node) |n| : (node = n.prev) {
        if (n.slot == slot) return n.pos;
    }
    return null;
}

const Thread = struct {
    pc: u32,
    /// Where this thread's match attempt began (group 0 start).
    start: usize,
    slots: ?*const SlotNode,
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

    fn prepend(self: *Ctx, chain: ?*const SlotNode, slot: u16, pos: usize) !*const SlotNode {
        const node = try self.arena.create(SlotNode);
        node.* = .{ .slot = slot, .pos = pos, .prev = chain };
        return node;
    }

    /// Add `pc0` and its epsilon closure to `list` in priority (DFS) order.
    ///
    /// An instruction is marked visited when its path is actually *taken*,
    /// never when a path to it is merely queued. Marking at queue time lets a
    /// deferred low-priority branch pre-empt a higher-priority one that
    /// reaches the same instruction later, which silently drops that path —
    /// and with it the captures it had recorded.
    ///
    /// Force-inlined: when the Pike VM lost single-call-site inlining (the
    /// lazy DFA added callers), the outlined closure cost ~2x on scan-heavy
    /// patterns.
    inline fn addThread(self: *Ctx, list: *ThreadList, gen: u32, pc0: u32, pos: usize, start: usize, slots0: ?*const SlotNode) !void {
        var sp: usize = 0;
        self.stack[sp] = .{ .pc = pc0, .start = start, .slots = slots0 };
        sp += 1;
        next_path: while (sp > 0) {
            sp -= 1;
            var pc = self.stack[sp].pc;
            var slots = self.stack[sp].slots;
            if (!self.tryEnter(gen, pc)) continue :next_path;
            while (true) {
                switch (self.prog.insts[pc]) {
                    .jmp => |t| {
                        if (!self.tryEnter(gen, t)) continue :next_path;
                        pc = t;
                    },
                    .split => |t| {
                        // Queued unmarked; whichever path reaches it first
                        // when actually taken is the one that wins.
                        self.stack[sp] = .{ .pc = t[1], .start = start, .slots = slots };
                        sp += 1;
                        if (!self.tryEnter(gen, t[0])) continue :next_path;
                        pc = t[0];
                    },
                    .save, .set_pos => |s| {
                        slots = try self.prepend(slots, s, pos);
                        if (!self.tryEnter(gen, pc + 1)) continue :next_path;
                        pc += 1;
                    },
                    .exit_if_same => |g| {
                        // An empty iteration ends the loop, keeping whatever
                        // it captured, rather than failing the path.
                        const next = if (slotLookup(slots, g.slot) == pos) g.target else pc + 1;
                        if (!self.tryEnter(gen, next)) continue :next_path;
                        pc = next;
                    },
                    .assert => |a| {
                        if (!common.assertHolds(a, self.input, pos)) continue :next_path;
                        if (!self.tryEnter(gen, pc + 1)) continue :next_path;
                        pc += 1;
                    },
                    // Consuming instructions and `match` land in the list.
                    .char, .any, .any_not_nl, .class, .match => {
                        list.append(.{ .pc = pc, .start = start, .slots = slots });
                        continue :next_path;
                    },
                    .backref, .look, .rep => unreachable, // never routed to the Pike VM
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
        // One stack entry per split actually processed, plus the seed.
        .stack = try arena.alloc(Thread, n + 1),
    };
    @memset(ctx.seen, 0);

    var clist = ThreadList{ .items = try arena.alloc(Thread, n) };
    var nlist = ThreadList{ .items = try arena.alloc(Thread, n) };

    const pf = &prog.prefilter;
    var gen: u32 = 1;
    var pos = start;
    var matched = false;

    while (true) {
        // With no live threads and no match yet, only candidate first bytes
        // matter: skip straight to the next one.
        if (!matched and clist.len == 0 and pf.usable) {
            const next = pf.scan(input, pos);
            if (next >= input.len) break;
            if (next != pos) {
                pos = next;
                // The visited marks belong to the position just left behind —
                // they were written by the (empty) next-list closure — so a
                // fresh generation is needed before seeding somewhere else.
                // Reusing the old one silently blocks instructions the seed
                // closure needs to enter.
                gen += 1;
            }
        }
        const d: ?common.DecodeResult = if (pos < input.len) common.decode(input, pos) else null;

        // Seed a new lowest-priority thread at this position until we have a
        // match; this is what makes the search unanchored and leftmost.
        if (!matched and (!pf.usable or (pos < input.len and pf.bytes[input[pos]]))) {
            try ctx.addThread(&clist, gen, 0, pos, pos, null);
        }

        var i: usize = 0;
        while (i < clist.len) : (i += 1) {
            const th = clist.items[i];
            switch (prog.insts[th.pc]) {
                .char => |c| if (d) |dd| {
                    if (common.charEq(c.cp, dd.cp, c.ci))
                        try ctx.addThread(&nlist, gen + 1, th.pc + 1, pos + dd.len, th.start, th.slots);
                },
                .any => if (d) |dd| {
                    try ctx.addThread(&nlist, gen + 1, th.pc + 1, pos + dd.len, th.start, th.slots);
                },
                .any_not_nl => if (d) |dd| {
                    if (dd.cp != '\n')
                        try ctx.addThread(&nlist, gen + 1, th.pc + 1, pos + dd.len, th.start, th.slots);
                },
                .class => |cl| if (d) |dd| {
                    const ranges = prog.ranges[cl.start..][0..cl.len];
                    if (common.classMatches(ranges, cl.negated, cl.ci, dd.cp))
                        try ctx.addThread(&nlist, gen + 1, th.pc + 1, pos + dd.len, th.start, th.slots);
                },
                .match => {
                    // Every thread after i is lower priority: discard them.
                    // Threads already in nlist are higher priority and may
                    // still improve (lengthen) the match on later steps.
                    @memset(slots_out, null);
                    var node = th.slots;
                    while (node) |sn| : (node = sn.prev) {
                        // First hit walking from the head is the latest write.
                        if (slots_out[sn.slot] == null) slots_out[sn.slot] = sn.pos;
                    }
                    slots_out[0] = th.start;
                    slots_out[1] = pos;
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
