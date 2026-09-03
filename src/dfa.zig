// SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

//! Lazy DFA: a memoized Pike VM (RE2-style).
//!
//! A DFA state is the priority-ordered list of NFA pcs a Pike thread list
//! would hold *before* epsilon closure, plus the context bits closures need
//! (was the previous codepoint a word char / newline, are we at the start,
//! are we still seeding new match attempts). Closure is deferred into the
//! transition — it needs both sides of a boundary — so a match is detected at
//! the boundary before consuming, exactly where the Pike VM would report it.
//! Lists are truncated at the first Match pc, which is what preserves
//! leftmost-greedy priority inside a DFA.
//!
//! The DFA finds the match span; it tracks no captures. `search` returns the
//! match end plus a window start: the last boundary where every live thread
//! had died, before which no match can begin. The caller reruns the Pike VM
//! on that (typically tiny) window for capture extraction. States and
//! transitions are built lazily per call and capped; on overflow the caller
//! falls back to the Pike VM.
const std = @import("std");
const common = @import("common.zig");
const compiler = @import("compiler.zig");

pub const Mode = enum { is_match, find };

pub const Result = union(enum) {
    match: struct {
        /// No match starts before this; rerun the Pike VM from here.
        window_start: usize,
        /// Match end (meaningless in is_match mode).
        end: usize,
    },
    no_match,
    /// State cache overflow: fall back to the Pike VM.
    give_up,
};

/// Default ceiling on cached states; see `Machine.init`'s `max_states` and
/// `Regex.dfa_max_states`, which exists so a test can pin it low enough to
/// exercise the give-up path on ordinary patterns.
pub const default_max_states = 512;

const Entry = struct {
    next: u32,
    /// Closure at the boundary before consuming contained Match.
    matched_here: bool,
    /// No thread survived the step — every thread died, this position's
    /// freshly-seeded one included.
    stepped_empty: bool,
};

const State = struct {
    /// Pre-closure pcs, priority ordered, deduped.
    raw: []const u32,
    prev_word: bool,
    prev_nl: bool,
    bof: bool,
    /// Still adding new lowest-priority match attempts each boundary.
    seeding: bool,
    /// Lazily filled, one per alphabet class plus EOF.
    trans: []?Entry,
};

const BoundaryCtx = struct {
    prev_word: bool,
    prev_nl: bool,
    bof: bool,
    next_word: bool,
    next_nl: bool,
    eof: bool,
    /// Whether the codepoint about to be consumed ends the input. Unlike the
    /// other fields this is not a property of that codepoint's class, so a
    /// transition depending on it is computed rather than cached.
    next_final: bool,

    fn holds(ctx: BoundaryCtx, a: common.Assertion) bool {
        return switch (a) {
            .begin_text => ctx.bof,
            .end_text => ctx.eof,
            .end_text_or_final_newline => ctx.eof or (ctx.next_nl and ctx.next_final),
            // A newline that ends the input starts no line after it.
            .begin_line => ctx.bof or (ctx.prev_nl and !ctx.eof),
            .end_line => ctx.eof or ctx.next_nl,
            .word_boundary => ctx.prev_word != ctx.next_word,
            .not_word_boundary => ctx.prev_word == ctx.next_word,
        };
    }
};

/// A lazy DFA with its state cache. Reusable across searches of the same
/// compiled regex (an iterator holds one so repeated `next()` calls hit warm
/// states); memory is bounded by `max_states` and freed by `deinit`.
pub const Machine = struct {
    arena_state: std.heap.ArenaAllocator,
    prog: compiler.Program,
    alphabet: *const compiler.Alphabet,
    n_classes: u16,
    /// See `init`.
    max_states: usize,
    states: std.ArrayList(State) = .empty,
    map: std.StringHashMapUnmanaged(u32) = .empty,
    // Scratch, all insts.len sized.
    seen: []u32,
    gen: u32 = 0,
    stack: []u32,
    list_buf: []u32,
    raw_buf: []u32,
    key_buf: []u8,

    const Error = error{ OutOfMemory, GiveUp };

    /// Scratch and cache for searches of one compiled program; reusable
    /// across calls so repeated searches hit warm states.
    pub fn init(
        gpa: std.mem.Allocator,
        prog: compiler.Program,
        alphabet: *const compiler.Alphabet,
        /// Cache ceiling; reaching it makes the search give up and hand the
        /// subject to the Pike VM. Settable so that a test can pin it low
        /// enough to take that path on ordinary patterns, which at the
        /// default of 512 states almost nothing does.
        max_states: usize,
    ) std.mem.Allocator.Error!Machine {
        const n = prog.insts.len;
        var arena_state = std.heap.ArenaAllocator.init(gpa);
        errdefer arena_state.deinit();
        // Never store the derived Allocator: it points at the ArenaAllocator
        // struct, and the Machine is returned by value (moved). The arena's
        // internal state moves safely; the interface pointer would not.
        const arena = arena_state.allocator();
        // Allocate all scratch before building the struct literal: the
        // literal copies arena_state, so it must already know these buffers.
        // Each cached state's key is up to four bytes per instruction, so a
        // program near the instruction ceiling would put the default cap of
        // 512 states at over a hundred megabytes of keys. Scale the
        // cap down so the key store stays within a few megabytes; giving up
        // earlier just hands the subject to the Pike VM sooner.
        const scaled_max = @min(max_states, @max(8, (4 << 20) / (4 * n + 1)));
        const seen = try arena.alloc(u32, n);
        // One stack entry per split actually processed, plus the seed.
        const stack = try arena.alloc(u32, n + 1);
        const list_buf = try arena.alloc(u32, n);
        const raw_buf = try arena.alloc(u32, n);
        const key_buf = try arena.alloc(u8, 1 + n * 4);
        @memset(seen, 0);
        return .{
            .arena_state = arena_state,
            .prog = prog,
            .alphabet = alphabet,
            .n_classes = alphabet.numClasses(),
            .max_states = scaled_max,
            .seen = seen,
            .stack = stack,
            .list_buf = list_buf,
            .raw_buf = raw_buf,
            .key_buf = key_buf,
        };
    }

    pub fn deinit(m: *Machine) void {
        m.arena_state.deinit();
        m.* = undefined;
    }

    fn internState(
        m: *Machine,
        raw: []const u32,
        prev_word: bool,
        prev_nl: bool,
        bof: bool,
        seeding: bool,
    ) Error!u32 {
        const flags: u8 = @as(u8, @intFromBool(prev_word)) |
            @as(u8, @intFromBool(prev_nl)) << 1 |
            @as(u8, @intFromBool(bof)) << 2 |
            @as(u8, @intFromBool(seeding)) << 3;
        m.key_buf[0] = flags;
        const key_len = 1 + raw.len * 4;
        for (raw, 0..) |pc, i| {
            std.mem.writeInt(u32, m.key_buf[1 + i * 4 ..][0..4], pc, .little);
        }
        const key = m.key_buf[0..key_len];
        if (m.map.get(key)) |id| return id;
        if (m.states.items.len >= m.max_states) return error.GiveUp;
        const id: u32 = @intCast(m.states.items.len);
        const arena = m.arena_state.allocator();
        const trans = try arena.alloc(?Entry, m.n_classes + 1);
        @memset(trans, null);
        try m.states.append(arena, .{
            .raw = try arena.dupe(u32, raw),
            .prev_word = prev_word,
            .prev_nl = prev_nl,
            .bof = bof,
            .seeding = seeding,
            .trans = trans,
        });
        try m.map.put(arena, try arena.dupe(u8, key), id);
        return id;
    }

    const ClosureResult = struct {
        len: usize,
        matched: bool,
    };

    /// Epsilon closure of `raw` (plus the seed at pc 0 if `seeding`) under a
    /// boundary context, into `m.list_buf`. Priority order matches the Pike
    /// VM: raw pcs first, seed last, DFS a-branch-first, shared dedup, and
    /// everything after the first Match is cut.
    fn closure(m: *Machine, raw: []const u32, seeding: bool, ctx: BoundaryCtx) ClosureResult {
        m.gen += 1;
        var out: usize = 0;
        var matched = false;
        var root_i: usize = 0;
        outer: while (root_i < raw.len + @intFromBool(seeding)) : (root_i += 1) {
            const root = if (root_i < raw.len) raw[root_i] else 0;
            if (m.seen[root] == m.gen) continue;
            m.seen[root] = m.gen;
            var sp: usize = 0;
            m.stack[sp] = root;
            sp += 1;
            next_path: while (sp > 0) {
                sp -= 1;
                var pc = m.stack[sp];
                while (true) {
                    switch (m.prog.insts[pc]) {
                        .jmp => |t| {
                            if (m.seen[t] == m.gen) continue :next_path;
                            m.seen[t] = m.gen;
                            pc = t;
                        },
                        .split => |t| {
                            if (m.seen[t[1]] != m.gen) {
                                m.seen[t[1]] = m.gen;
                                m.stack[sp] = t[1];
                                sp += 1;
                            }
                            if (m.seen[t[0]] == m.gen) continue :next_path;
                            m.seen[t[0]] = m.gen;
                            pc = t[0];
                        },
                        // `exit_if_same` cannot be evaluated here: deciding
                        // it needs the position recorded by `set_pos`, which
                        // is per thread and the DFA tracks only pc sets.
                        // Programs containing one stay off the DFA entirely
                        // (see `Regex.dfaEligible`).
                        .save, .set_pos => {
                            if (m.seen[pc + 1] == m.gen) continue :next_path;
                            m.seen[pc + 1] = m.gen;
                            pc += 1;
                        },
                        .assert => |a| {
                            if (!ctx.holds(a)) continue :next_path;
                            if (m.seen[pc + 1] == m.gen) continue :next_path;
                            m.seen[pc + 1] = m.gen;
                            pc += 1;
                        },
                        .char, .any, .any_not_nl, .class => {
                            m.list_buf[out] = pc;
                            out += 1;
                            continue :next_path;
                        },
                        .match => {
                            // Cut every lower-priority thread (Pike VM's
                            // break on match), including unprocessed roots
                            // and the seed.
                            matched = true;
                            break :outer;
                        },
                        .backref, .look, .rep, .exit_if_same => unreachable, // never routed to the DFA
                    }
                }
            }
        }
        return .{ .len = out, .matched = matched };
    }

    fn transition(m: *Machine, sid: u32, k: u16, next_final: bool) Error!Entry {
        // Only the ordinary case is memoized: at the last codepoint the answer
        // can differ for the same state and class, and that happens once per
        // search, so recomputing it costs nothing.
        if (!next_final) {
            if (m.states.items[sid].trans[k]) |e| return e;
        }
        const st = m.states.items[sid];
        const raw = st.raw;
        const seeding = st.seeding;
        const eof = k == m.n_classes;
        const sample: u21 = if (eof) 0 else m.alphabet.sample(k);
        const ctx = BoundaryCtx{
            .prev_word = st.prev_word,
            .prev_nl = st.prev_nl,
            .bof = st.bof,
            .next_word = !eof and common.isWordChar(sample),
            .next_nl = !eof and sample == '\n',
            .eof = eof,
            .next_final = next_final,
        };
        const c = m.closure(raw, seeding, ctx);

        var entry = Entry{ .next = sid, .matched_here = c.matched, .stepped_empty = true };
        if (!eof) {
            var rn: usize = 0;
            for (m.list_buf[0..c.len]) |pc| {
                const accepts = switch (m.prog.insts[pc]) {
                    .char => |ch| common.charEq(ch.cp, sample, ch.ci),
                    .class => |cl| common.classMatches(
                        m.prog.ranges[cl.start..][0..cl.len],
                        cl.negated,
                        cl.ci,
                        sample,
                    ),
                    .any => true,
                    .any_not_nl => sample != '\n',
                    else => unreachable,
                };
                if (accepts) {
                    m.raw_buf[rn] = pc + 1;
                    rn += 1;
                }
            }
            entry.stepped_empty = rn == 0;
            entry.next = try m.internState(
                m.raw_buf[0..rn],
                ctx.next_word,
                ctx.next_nl,
                false,
                seeding and !c.matched,
            );
        }
        if (!next_final) m.states.items[sid].trans[k] = entry;
        return entry;
    }
};

/// Unanchored search from `start`. In `is_match` mode returns at the first
/// match (`end` is not meaningful); in `find` mode returns the leftmost-greedy
/// match end and the window start for capture extraction.
pub fn search(
    m: *Machine,
    input: []const u8,
    start: usize,
    mode: Mode,
) std.mem.Allocator.Error!Result {
    var prev_word = false;
    var prev_nl = false;
    if (start > 0) {
        const before = common.decodeBefore(input, start);
        prev_word = common.isWordChar(before.cp);
        prev_nl = before.cp == '\n';
    }
    var sid = m.internState(&.{}, prev_word, prev_nl, start == 0, true) catch |e| switch (e) {
        error.GiveUp => return .give_up, // cache full from earlier searches
        error.OutOfMemory => return error.OutOfMemory,
    };

    const pf = &m.prog.prefilter;
    var pos = start;
    var window = start;
    var last_end: ?usize = null;

    while (true) {
        const st = m.states.items[sid];
        if (!st.seeding and st.raw.len == 0) break; // post-match threads all died
        if (st.seeding and st.raw.len == 0 and pf.usable and last_end == null) {
            // Idle between attempts: jump to the next candidate first byte.
            const npos = pf.scan(input, pos);
            if (npos >= input.len) break; // a usable prefilter excludes empty matches
            if (npos != pos) {
                pos = npos;
                window = npos;
                const before = common.decodeBefore(input, npos);
                sid = m.internState(
                    &.{},
                    common.isWordChar(before.cp),
                    before.cp == '\n',
                    false,
                    true,
                ) catch |e| switch (e) {
                    error.GiveUp => return .give_up,
                    error.OutOfMemory => return error.OutOfMemory,
                };
                continue;
            }
        }
        var k: u16 = m.n_classes;
        var cplen: usize = 0;
        if (pos < input.len) {
            const d = common.decode(input, pos);
            k = m.alphabet.classOf(d.cp);
            cplen = d.len;
        }
        const at_last = pos < input.len and pos + cplen == input.len;
        const entry = m.transition(sid, k, at_last) catch |e| switch (e) {
            error.GiveUp => return .give_up,
            error.OutOfMemory => return error.OutOfMemory,
        };
        if (entry.matched_here) {
            if (mode == .is_match) return .{ .match = .{ .window_start = window, .end = pos } };
            last_end = pos;
        }
        if (pos >= input.len) break;
        if (entry.stepped_empty and last_end == null) window = pos + cplen;
        sid = entry.next;
        pos += cplen;
    }
    if (last_end) |e| return .{ .match = .{ .window_start = window, .end = e } };
    return .no_match;
}
