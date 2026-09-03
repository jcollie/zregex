// SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

//! Pike VM: breadth-first NFA simulation with capture slots.
//!
//! Guaranteed linear in the input regardless of the pattern: O(input * keys),
//! where keys is the program's length times one visited mask per empty-loop
//! guard level -- at most 2^6, and the compiler refuses any program whose
//! keys would pass `compiler.max_visited_keys`. Handles every instruction
//! except `backref`, `look`, and the backtracker's fused `rep` — patterns
//! needing the first two are routed to the backtracker by `Regex.compile`,
//! and the compiler only emits the third into backtracker programs.
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

/// How many *nesting levels* of empty-loop guard can be tracked separately in
/// the visited key. Each one doubles the table, so this bounds it at 64 marks
/// per instruction -- and only for a pattern that actually nests nullable
/// loops that deep; one with none gets a single mark per instruction as
/// before. See `assignGuardBits` for why levels are the right unit.
const max_guard_bits = 6;

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
        // Capacity is one entry per visited key and keys are deduped, so
        // this cannot overflow.
        self.items[self.len] = t;
        self.len += 1;
    }
};

const Ctx = struct {
    prog: compiler.Program,
    input: []const u8,
    /// Where `prepend` allocates: the chain arena, swapped out whole by the
    /// compaction in `run` -- never the arena the structural buffers live in.
    arena: std.mem.Allocator,
    /// Chain nodes created since the arena was last compacted; the trigger.
    nodes_allocated: usize = 0,
    /// Generation marks per visited key; a key is in a list iff its mark
    /// equals that list's gen. Indexed by `(pc << key_shift) | mask`.
    seen: []u32,
    /// DFS stack for epsilon closure.
    stack: []Thread,
    /// Guard mask per DFS stack entry, kept alongside `stack` rather than in
    /// `Thread` so that the lists' element type stays as small as it was.
    /// Meaningless once a thread lands in a list: every guard's bit is clear
    /// again at the next position. See `tryEnter`.
    stack_mask: []u8,
    /// Guard slot -> its bit in a thread's mask, plus one; 0 for slots that
    /// are not empty-loop guards.
    guard_bit: []const u8,
    /// How many bits of guard state the visited key carries.
    key_shift: u5,

    /// Mark `pc` visited for this closure, or report that it already was.
    ///
    /// The key is the pc *and* the guard mask, not the pc alone. A thread's
    /// future is otherwise not determined by its pc: `exit_if_same` branches
    /// on whether the innermost iteration began at this position, which two
    /// threads sharing a pc can disagree about. Deduplicating on pc alone
    /// merges them and keeps whichever arrived first, which is the one that
    /// has been round the loop -- so the empty iteration that PCRE runs (and
    /// that ends the loop) is dropped, and a longer, lower-priority path
    /// wins instead. Splitting on the bit costs a factor of two in visited
    /// keys per guard and nothing at all for the patterns that have none.
    fn tryEnter(self: *Ctx, gen: u32, pc: u32, mask: u8) bool {
        const key = (@as(usize, pc) << self.key_shift) | mask;
        if (self.seen[key] == gen) return false;
        self.seen[key] = gen;
        return true;
    }

    fn prepend(self: *Ctx, chain: ?*const SlotNode, slot: u16, pos: usize) !*const SlotNode {
        const node = try self.arena.create(SlotNode);
        node.* = .{ .slot = slot, .pos = pos, .prev = chain };
        self.nodes_allocated += 1;
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
        // Every guard bit is clear here. A guard slot holds the position an
        // iteration began at, which is always one already passed, so none of
        // them can equal `pos` until a `set_pos` in this very closure writes
        // one -- no lookup needed to seed the mask.
        self.stack[sp] = .{ .pc = pc0, .start = start, .slots = slots0 };
        self.stack_mask[sp] = 0;
        sp += 1;
        next_path: while (sp > 0) {
            sp -= 1;
            var pc = self.stack[sp].pc;
            var slots = self.stack[sp].slots;
            var mask = self.stack_mask[sp];
            if (!self.tryEnter(gen, pc, mask)) continue :next_path;
            while (true) {
                switch (self.prog.insts[pc]) {
                    .jmp => |t| {
                        if (!self.tryEnter(gen, t, mask)) continue :next_path;
                        pc = t;
                    },
                    .split => |t| {
                        // Queued unmarked; whichever path reaches it first
                        // when actually taken is the one that wins.
                        self.stack[sp] = .{ .pc = t[1], .start = start, .slots = slots };
                        self.stack_mask[sp] = mask;
                        sp += 1;
                        if (!self.tryEnter(gen, t[0], mask)) continue :next_path;
                        pc = t[0];
                    },
                    .save => |s| {
                        slots = try self.prepend(slots, s, pos);
                        if (!self.tryEnter(gen, pc + 1, mask)) continue :next_path;
                        pc += 1;
                    },
                    .set_pos => |s| {
                        slots = try self.prepend(slots, s, pos);
                        // This loop's iteration now starts here, which is
                        // just what the guard below tests. Setting the bit
                        // keeps the rest of this path distinct from one that
                        // reached the same instructions mid-iteration.
                        const b = self.guard_bit[s];
                        if (b != 0) mask |= @as(u8, 1) << @intCast(b - 1);
                        if (!self.tryEnter(gen, pc + 1, mask)) continue :next_path;
                        pc += 1;
                    },
                    .exit_if_same => |g| {
                        // An empty iteration ends the loop, keeping whatever
                        // it captured, rather than failing the path.
                        const next = if (slotLookup(slots, g.slot) == pos) g.target else pc + 1;
                        if (!self.tryEnter(gen, next, mask)) continue :next_path;
                        pc = next;
                    },
                    .assert => |a| {
                        if (!common.assertHolds(a, self.input, pos)) continue :next_path;
                        if (!self.tryEnter(gen, pc + 1, mask)) continue :next_path;
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

/// Give every empty-loop guard slot a bit in the visited key's mask, and
/// return how many bits that took. A slot with no bit gets 0.
///
/// Guards are bucketed by how deeply they nest, and every guard at one depth
/// shares that depth's bit. What the bit has to answer, at an instruction
/// inside loop L, is "did L's current iteration begin at this position" -- and
/// a thread can only be inside L's body having run L's own `set_pos`, because
/// that is the only way in. So one bit per level distinguishes exactly the
/// threads that `exit_if_same` would send different ways, and two loops that
/// merely sit side by side never need to be told apart.
///
/// Numbering the guards in the order they appear instead, which is what this
/// used to do, spends a bit on each of them. `x{n}` over a nullable body emits
/// `n` copies of the loop, so `((a*?)*){5}` alone ran the ceiling out and the
/// extra guards fell back to a coarser key: threads that disagreed about an
/// empty iteration were merged, the empty iteration PCRE runs was dropped, and
/// the capture came back one position wide. Bucketing by depth costs those
/// copies one bit between them.
///
/// A guard's body runs from its `set_pos` to its `exit_if_same`, and those
/// pairs are emitted properly nested, so one pass over the instructions with a
/// running depth is enough -- no comparing of guards against each other, which
/// would be quadratic in a program that unrolls a nullable loop many times.
fn assignGuardBits(
    arena: std.mem.Allocator,
    prog: compiler.Program,
    guard_bit: []u8,
) std.mem.Allocator.Error!u8 {
    @memset(guard_bit, 0);

    // Which slots are guards at all. `set_pos` is only ever emitted for one,
    // but reading it from the `exit_if_same` side means the scan below can
    // trust the pairing rather than assume it.
    const is_guard = try arena.alloc(bool, prog.slot_count);
    @memset(is_guard, false);
    var any = false;
    for (prog.insts) |inst| {
        if (inst == .exit_if_same) {
            is_guard[inst.exit_if_same.slot] = true;
            any = true;
        }
    }
    if (!any) return 0;

    var depth: u8 = 0;
    var levels: u8 = 0;
    for (prog.insts) |inst| switch (inst) {
        .set_pos => |slot| {
            if (!is_guard[slot]) continue;
            // Past the ceiling a guard shares the coarser key. Reaching it
            // takes that many nullable loops nested inside one another, which
            // nothing short of a deliberately built pattern does.
            if (depth < max_guard_bits) {
                guard_bit[slot] = depth + 1;
                levels = @max(levels, depth + 1);
            }
            depth += 1;
        },
        .exit_if_same => depth -|= 1,
        else => {},
    };
    return levels;
}

/// Copy one chain into `dst`, sharing what was already copied: `map` carries
/// old node -> new node, so common suffixes stay common and the copy is no
/// larger than what is live. Iterative, because a chain can be as long as
/// every save the scan has executed on one path.
fn copyChain(
    gpa: std.mem.Allocator,
    map: *std.AutoHashMapUnmanaged(*const SlotNode, *const SlotNode),
    scratch: *std.ArrayList(*const SlotNode),
    dst: std.mem.Allocator,
    head: ?*const SlotNode,
) !?*const SlotNode {
    scratch.clearRetainingCapacity();
    // Walk down to the first node already copied (or the end), remembering
    // the stretch that still needs copying.
    var node = head;
    var tail: ?*const SlotNode = null;
    while (node) |n| {
        if (map.get(n)) |copied| {
            tail = copied;
            break;
        }
        try scratch.append(gpa, n);
        node = n.prev;
    }
    // Rebuild that stretch back-to-front on top of the shared tail.
    var i = scratch.items.len;
    while (i > 0) {
        i -= 1;
        const old_node = scratch.items[i];
        const copy = try dst.create(SlotNode);
        copy.* = .{ .slot = old_node.slot, .pos = old_node.pos, .prev = tail };
        try map.put(gpa, old_node, copy);
        tail = copy;
    }
    return tail;
}

/// Unanchored search from byte offset `start`. On success fills `slots_out`
/// (length `prog.slot_count`) and returns true. Leftmost-greedy semantics.
pub fn run(
    gpa: std.mem.Allocator,
    prog: compiler.Program,
    input: []const u8,
    start: usize,
    slots_out: []?usize,
    reject_empty_at: ?usize,
) std.mem.Allocator.Error!bool {
    const n = prog.insts.len;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // Capture chains get an arena of their own, because it gets thrown away:
    // most nodes belong to threads that die within a step or two, an arena
    // frees nothing until it is destroyed, and one scan writes chains at
    // every position -- a run of `(a?)` groups against sixty kilobytes of
    // `a` grew three hundred megabytes of dead chain before this existed.
    // When enough nodes have been created, the chains still reachable from
    // the live threads are copied into a fresh arena -- sharing preserved,
    // so the copy is no bigger than what is genuinely alive -- and the old
    // arena, garbage and all, is freed. The structural buffers above stay in
    // `arena_state`, which is why the two must not be one.
    var chains_state = std.heap.ArenaAllocator.init(gpa);
    defer chains_state.deinit();

    // One mask bit per empty-loop guard, so that threads which disagree
    // about whether the current iteration started here stay distinct; see
    // `Ctx.tryEnter`. Programs without such a loop get `key_shift == 0` and
    // the same single mark per instruction as before.
    const guard_bit = try arena.alloc(u8, prog.slot_count);
    var guard_count = try assignGuardBits(arena, prog, guard_bit);
    // The compiler refuses any program whose keys would exceed the ceiling
    // (see `compiler.count`), so this shedding is a safety net for a program
    // that arrived some other way; every compiled pattern keeps every bit.
    while (guard_count > 0 and (n << @as(u5, @intCast(guard_count))) > compiler.max_visited_keys) {
        guard_count -= 1;
    }
    for (guard_bit) |*b| {
        if (b.* > guard_count) b.* = 0;
    }
    const key_shift: u5 = @intCast(guard_count);
    // Instructions times guard masks: how many distinct threads a single
    // position can hold. Without a guard this is just the instruction count.
    const keys = n << key_shift;

    var ctx = Ctx{
        .prog = prog,
        .input = input,
        .arena = chains_state.allocator(),
        .seen = try arena.alloc(u32, keys),
        // One stack entry per split actually processed, plus the seed. A
        // split can be processed once per guard mask, not just once per
        // instruction, so this is sized in keys too.
        .stack = try arena.alloc(Thread, keys + 1),
        .stack_mask = try arena.alloc(u8, keys + 1),
        .guard_bit = guard_bit,
        .key_shift = key_shift,
    };
    @memset(ctx.seen, 0);

    var clist = ThreadList{ .items = try arena.alloc(Thread, keys) };
    var nlist = ThreadList{ .items = try arena.alloc(Thread, keys) };

    const pf = &prog.prefilter;
    var gen: u32 = 1;
    var pos = start;
    var matched = false;

    // Compaction bookkeeping; see the note in the loop.
    const min_compact: usize = 1 << 16;
    var next_compact: usize = min_compact;
    var copy_map: std.AutoHashMapUnmanaged(*const SlotNode, *const SlotNode) = .empty;
    defer copy_map.deinit(gpa);
    var copy_scratch: std.ArrayList(*const SlotNode) = .empty;
    defer copy_scratch.deinit(gpa);

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
        // Compact the chain arena once enough nodes have piled up: copy what
        // the live threads still reach into a fresh arena and free the rest.
        // This is the one point in the loop where `clist` holds every live
        // reference -- `nlist` is empty, and a match's slots were copied out
        // the moment it was seen. The threshold doubles with the surviving
        // set, so the work is amortized against the allocation that forced
        // it, and a scan whose chains are all live compacts ever more rarely
        // rather than thrashing.
        if (ctx.nodes_allocated >= next_compact) {
            var fresh = std.heap.ArenaAllocator.init(gpa);
            errdefer fresh.deinit();
            copy_map.clearRetainingCapacity();
            var live: usize = 0;
            for (clist.items[0..clist.len]) |*th| {
                th.slots = try copyChain(gpa, &copy_map, &copy_scratch, fresh.allocator(), th.slots);
            }
            live = copy_map.count();
            chains_state.deinit();
            chains_state = fresh;
            ctx.arena = chains_state.allocator();
            ctx.nodes_allocated = live;
            next_compact = @max(min_compact, live * 2);
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
                    // The caller is looking for a match at this position that
                    // is not the empty one it already reported, so this thread
                    // does not count -- but a lower-priority one may still
                    // reach `match` further along.
                    if (reject_empty_at) |r| {
                        if (th.start == r and pos == r) continue;
                    }
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
