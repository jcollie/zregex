// SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

//! Public API: `Regex`, `Match`, `Span`.
const std = @import("std");
const common = @import("common.zig");
const parser = @import("parser.zig");
const compiler = @import("compiler.zig");
const pike = @import("pike.zig");
const backtrack = @import("backtrack.zig");
const dfa = @import("dfa.zig");
const jitmod = @import("jit.zig");

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
    /// Pike VM (with the lazy DFA in front of it): guaranteed linear time.
    pike,
    /// Budgeted, memoizing backtracker: needed for backrefs and lookaround.
    backtrack,
    /// Native code compiled for this pattern, with `fallback_engine` behind
    /// it for the inputs that exhaust its budget.
    jit,
};

pub const Regex = struct {
    program: []const compiler.Inst,
    ranges: []const common.ClassRange,
    names: []const parser.NamedGroup,
    group_count: u8,
    slot_count: u16,
    flags: Flags,
    /// The engine that runs searches. `.jit` means native code runs first and
    /// `fallback_engine` finishes anything it bails on.
    engine: Engine,
    /// The interpreter behind the JIT, and the engine used when the JIT is
    /// unavailable or turned off.
    fallback_engine: Engine,
    /// Native code for this pattern, when one could be generated.
    jit_code: ?jitmod.Jit = null,
    /// Which bytes a match can start with; lets the engines skip ahead.
    prefilter: compiler.Prefilter,
    /// Codepoint partition for the lazy DFA; `alphabet.ok == false` disables it.
    alphabet: compiler.Alphabet,
    /// Whether the program guards an empty-bodied loop.
    ///
    /// Every engine agrees on these patterns, but not every engine can run
    /// them. Deciding the guard needs the position the current iteration
    /// began at, which the lazy DFA does not carry through its states, so
    /// such patterns stay off it. They also stay off the JIT by default:
    /// `(a*)*b` is the textbook exponential case for a backtracker, and the
    /// Pike VM answers it in linear time.
    has_loop_guard: bool = false,
    /// Lazy DFA policy. `.auto` uses the DFA only when the byte prefilter is
    /// weak (a broad or unusable candidate set) — when the prefilter is
    /// highly selective, memchr-style skipping with the Pike VM alone is
    /// faster than any per-codepoint automaton. `.on`/`.off` force it.
    dfa_mode: enum { auto, on, off } = .auto,
    /// JIT policy. `.auto` follows `engine`: native code runs when the
    /// pattern is one it beats the interpreters on. `.on` forces it whenever
    /// code was generated and `.off` never uses it; both are safe, since
    /// every path produces identical matches.
    jit_mode: enum { auto, on, off } = .auto,
    /// Backref-aware memoization in the backtracking engine: prunes states
    /// whose failure was already proven, bounding pathological backtracking
    /// polynomially. Keys include everything the remaining program can read
    /// (referenced capture spans, loop guards), so semantics are unchanged.
    memo: bool = true,
    /// Step budget for the backtracking engine. One search -- a `find`, an
    /// `isMatch`, one `Iterator.next` -- may spend this many steps plus 64
    /// per input byte across all of its start positions together; running
    /// out is `error.StepLimitExceeded`. The per-byte allowance keeps honest
    /// scans of large haystacks inside the budget; the total being one
    /// budget, rather than one per start position the way PCRE's match
    /// limit works, is what makes it a bound at all -- input crafted to
    /// stay just under a per-attempt limit multiplies it by the length of
    /// the haystack, and takes `grep -P` from milliseconds to hours.
    max_steps: usize = default_max_steps,
    /// How many states the lazy DFA may cache before giving up and handing
    /// the subject to the Pike VM. Lowering it is how the fallback gets
    /// exercised; at the default almost no pattern reaches it.
    dfa_max_states: usize = dfa.default_max_states,
    /// Backing allocator for owned memory; null for comptime-compiled regexes.
    gpa: ?std.mem.Allocator,
    /// Owned storage for group-name strings (runtime compiles only).
    names_buf: []const u8 = &.{},
    /// A second, fused program for the JIT, when the interpreters need the
    /// expanded one. Empty means the JIT shares `program`.
    jit_program: []const compiler.Inst = &.{},

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
        // Before the buffers: they are sized from the pattern's length.
        if (pattern.len > parser.max_pattern_len) return error.PatternTooLong;
        const sizes = parser.bufferSizes(pattern.len, parser.mayBeCaseless(pattern, flags));
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

        // Fused repeats are for backtracking only; the Pike VM and DFA need
        // the expanded form. When both are in play the JIT gets its own
        // fused program, built from the same AST.
        const bt = p.has_backref or p.has_look;
        const counts = try compiler.count(nodes[0..p.nodes_len], root, p.group_count, bt);
        const insts = try gpa.alloc(compiler.Inst, counts.insts);
        errdefer gpa.free(insts);
        try compiler.emitInto(nodes[0..p.nodes_len], root, p.group_count, bt, insts);

        var jit_insts: []compiler.Inst = &.{};
        var slot_count = counts.slots;
        if (!bt) {
            const jc = try compiler.count(nodes[0..p.nodes_len], root, p.group_count, true);
            jit_insts = try gpa.alloc(compiler.Inst, jc.insts);
            try compiler.emitInto(nodes[0..p.nodes_len], root, p.group_count, true, jit_insts);
            // Engines only ever read their own scratch slots, and the capture
            // slots below them are identical, so one shared size works.
            slot_count = @max(slot_count, jc.slots);
        }
        errdefer if (jit_insts.len != 0) gpa.free(jit_insts);

        const ranges = try gpa.dupe(common.ClassRange, ranges_tmp[0..p.ranges_len]);
        errdefer gpa.free(ranges);

        const visited = try gpa.alloc(bool, counts.insts);
        defer gpa.free(visited);
        const pf_stack = try gpa.alloc(u32, counts.insts);
        defer gpa.free(pf_stack);
        const prefilter = compiler.computeFirstBytes(insts, ranges, visited, pf_stack);

        const abuf = try gpa.alloc(u21, compiler.alphabetBufferSize(counts.insts));
        defer gpa.free(abuf);
        var alphabet = compiler.computeAlphabet(insts, ranges, abuf);
        if (alphabet.ok) {
            alphabet.starts = try gpa.dupe(u21, alphabet.starts);
        } else {
            alphabet.starts = &.{};
        }
        // Every other buffer this function keeps has one of these. Without it
        // an allocation failure anywhere below -- the group names, or the JIT
        // -- returns the error with this one still held.
        errdefer gpa.free(alphabet.starts);

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

        var re: Regex = .{
            .program = insts,
            .ranges = ranges,
            .names = names,
            .names_buf = names_buf,
            .group_count = p.group_count,
            .slot_count = slot_count,
            .jit_program = jit_insts,
            .flags = flags,
            .engine = .pike, // replaced below, once the JIT has had its turn
            .fallback_engine = .pike,
            .prefilter = prefilter,
            .alphabet = alphabet,
            .gpa = gpa,
        };
        for (insts) |inst| {
            if (inst == .exit_if_same) re.has_loop_guard = true;
        }
        re.fallback_engine = if (bt) .backtrack else .pike;
        re.jit_code = try jitmod.Jit.compile(gpa, re.jitProg(), &re.prefilter);
        re.engine = if (re.jitIsDefault()) .jit else re.fallback_engine;
        return re;
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
            if (pattern.len > parser.max_pattern_len) @compileError("pattern too long");
            const sizes = parser.bufferSizes(pattern.len, parser.mayBeCaseless(pattern, flags));
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
            const bt = p.has_backref or p.has_look;
            const counts = compiler.count(nodes[0..p.nodes_len], root, p.group_count, bt) catch |e|
                @compileError("zregex: cannot compile \"" ++ pattern ++ "\": " ++ @errorName(e));
            var insts: [counts.insts]compiler.Inst = undefined;
            compiler.emitInto(nodes[0..p.nodes_len], root, p.group_count, bt, &insts) catch unreachable;

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

            var abuf: [compiler.alphabetBufferSize(counts.insts)]u21 = undefined;
            var alphabet = compiler.computeAlphabet(&final_insts, &final_ranges, &abuf);
            const final_starts: [alphabet.starts.len]u21 = abuf[0..alphabet.starts.len].*;
            alphabet.starts = &final_starts;

            return .{
                .program = &final_insts,
                .ranges = &final_ranges,
                .names = &final_names,
                .group_count = p.group_count,
                .slot_count = counts.slots,
                .flags = flags,
                // Comptime compilation cannot map executable memory, so a
                // comptime pattern always runs on an interpreter.
                .engine = if (p.has_backref or p.has_look) .backtrack else .pike,
                .fallback_engine = if (p.has_backref or p.has_look) .backtrack else .pike,
                .prefilter = prefilter,
                .alphabet = alphabet,
                .has_loop_guard = blk: {
                    for (&final_insts) |inst| {
                        if (inst == .exit_if_same) break :blk true;
                    }
                    break :blk false;
                },
                .gpa = null,
            };
        }
    }

    pub fn deinit(self: *Regex) void {
        if (self.jit_code) |*j| j.deinit();
        if (self.gpa) |gpa| {
            gpa.free(self.program);
            gpa.free(self.ranges);
            gpa.free(self.names);
            gpa.free(self.names_buf);
            gpa.free(self.alphabet.starts);
            if (self.jit_program.len != 0) gpa.free(self.jit_program);
        }
        self.* = undefined;
    }

    /// The program the JIT runs: the fused one when it exists.
    fn jitProg(self: *const Regex) compiler.Program {
        var p = self.prog();
        if (self.jit_program.len != 0) p.insts = self.jit_program;
        return p;
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
        reject_empty_at: ?usize,
    ) RunError!bool {
        return switch (self.fallback_engine) {
            .backtrack => backtrack.run(
                gpa,
                self.prog(),
                haystack,
                start,
                slots,
                self.max_steps,
                self.memo,
                reject_empty_at,
            ),
            .pike, .jit => pike.run(gpa, self.prog(), haystack, start, slots, reject_empty_at),
        };
    }

    /// Should native code run this pattern by default?
    ///
    /// Behind a backreference or lookaround the JIT competes with the
    /// backtracking interpreter and wins outright. For everything else it
    /// competes with the lazy DFA, which scans dense input in one pass where
    /// a backtracker re-reads it — so the JIT only takes over when the
    /// prefilter is selective enough that few start positions are ever tried.
    fn jitIsDefault(self: *const Regex) bool {
        if (self.jit_code == null) return false;
        // A loop whose body can match empty is the textbook exponential case
        // for a backtracker — `(a*)*b` against a run of a's — so it goes to
        // the Pike VM whenever that engine can run it at all. Behind a
        // backreference or lookaround it cannot, and native code is then the
        // best available.
        if (self.has_loop_guard and self.fallback_engine == .pike) return false;
        // Native code runs when its backtracking is structurally bounded (see
        // `jit.backtrackingIsBounded`). Behind a backreference or lookaround
        // there is no linear engine to fall back to anyway, so the JIT is
        // always the better bet there.
        if (self.fallback_engine == .backtrack) return true;
        return jitmod.backtrackingIsBounded(self.jitProg());
    }

    /// Native code, when it is compiled and the policy allows it.
    fn jitFn(self: *const Regex) ?*const jitmod.Jit {
        switch (self.jit_mode) {
            .off => return null,
            .auto => if (self.engine != .jit) return null,
            .on => {},
        }
        return if (self.jit_code) |*j| j else null;
    }

    fn dfaEligible(self: *const Regex) bool {
        if (self.fallback_engine != .pike or !self.alphabet.ok) return false;
        if (self.has_loop_guard) return false;
        return switch (self.dfa_mode) {
            .off => false,
            .on => true,
            // A 1-2 byte prefilter is a memchr-class skip nothing beats;
            // anything broader profits from the DFA.
            .auto => !self.prefilter.usable or self.prefilter.count > 2,
        };
    }

    /// Does the pattern match anywhere in `haystack`? The allocator is only
    /// used for engine scratch space and is fully released before returning.
    pub fn isMatch(self: *const Regex, gpa: std.mem.Allocator, haystack: []const u8) RunError!bool {
        if (self.jitFn()) |j| {
            const slots = try gpa.alloc(?usize, self.slot_count);
            defer gpa.free(slots);
            switch (j.run(haystack, 0, slots)) {
                .match => return true,
                .no_match => return false,
                .bail => {}, // budget spent; the interpreters finish the job
            }
        }
        if (self.dfaEligible()) {
            var machine = try dfa.Machine.init(gpa, self.prog(), &self.alphabet, self.dfa_max_states);
            defer machine.deinit();
            switch (try dfa.search(&machine, haystack, 0, .is_match)) {
                .match => return true,
                .no_match => return false,
                .give_up => {}, // cache blew up; fall through to the Pike VM
            }
        }
        const slots = try gpa.alloc(?usize, self.slot_count);
        defer gpa.free(slots);
        return self.runEngine(gpa, haystack, 0, slots, null);
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
        if (self.dfaEligible()) {
            var machine = try dfa.Machine.init(gpa, self.prog(), &self.alphabet, self.dfa_max_states);
            defer machine.deinit();
            return self.findAtWith(gpa, haystack, start, &machine);
        }
        return self.findAtWith(gpa, haystack, start, null);
    }

    /// Search core; `machine` is a warm DFA cache (the iterator keeps one
    /// across calls) or null to use the fallback engine directly.
    fn findAtWith(
        self: *const Regex,
        gpa: std.mem.Allocator,
        haystack: []const u8,
        start: usize,
        machine: ?*dfa.Machine,
    ) RunError!?Match {
        return self.findAtInner(gpa, haystack, start, machine, null);
    }

    /// Leftmost match at or after `start`, except that a zero-length match
    /// beginning at `reject_empty_at` is not one.
    ///
    /// Only the interpreters know how to refuse a match, so the JIT and the
    /// lazy DFA sit this one out; it is asked for only after an empty match
    /// has already been reported, which is rare enough for that to cost
    /// nothing on patterns that cannot match empty at all.
    fn findAtInner(
        self: *const Regex,
        gpa: std.mem.Allocator,
        haystack: []const u8,
        start: usize,
        machine: ?*dfa.Machine,
        reject_empty_at: ?usize,
    ) RunError!?Match {
        const slots = try gpa.alloc(?usize, self.slot_count);
        defer gpa.free(slots);
        if (reject_empty_at != null) {
            if (!try self.runEngine(gpa, haystack, start, slots, reject_empty_at)) return null;
            return try self.buildMatch(gpa, slots);
        }
        if (self.jitFn()) |j| {
            switch (j.run(haystack, start, slots)) {
                .match => return try self.buildMatch(gpa, slots),
                .no_match => return null,
                .bail => {},
            }
        }
        if (machine) |m| {
            // The DFA finds the span; the Pike VM reruns only the window
            // where the match can start, to extract captures.
            switch (try dfa.search(m, haystack, start, .find)) {
                .no_match => return null,
                .match => |sp| {
                    const ok = try pike.run(gpa, self.prog(), haystack, sp.window_start, slots, null);
                    std.debug.assert(ok); // the DFA is a memoized Pike VM
                },
                .give_up => {
                    if (!try self.runEngine(gpa, haystack, start, slots, null)) return null;
                },
            }
        } else {
            if (!try self.runEngine(gpa, haystack, start, slots, null)) return null;
        }

        return try self.buildMatch(gpa, slots);
    }

    fn buildMatch(self: *const Regex, gpa: std.mem.Allocator, slots: []const ?usize) RunError!Match {
        const groups = try gpa.alloc(?Span, self.group_count);
        for (groups, 0..) |*g, i| {
            const a = slots[2 * i];
            const b = slots[2 * i + 1];
            // A half-open group can leave start past end; report that as not
            // having participated rather than as a backwards span.
            g.* = if (a != null and b != null and a.? <= b.?)
                .{ .start = a.?, .end = b.? }
            else
                null;
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
        /// Set when the last match was empty: the next search must look for a
        /// longer match beginning right there before moving on.
        retry_nonempty_at: ?usize = null,
        /// Warm DFA cache shared across `next()` calls; created lazily.
        machine: ?dfa.Machine = null,

        /// Frees the iterator's DFA cache. Safe to call whether or not any
        /// `next()` call was made.
        pub fn deinit(self: *Iterator) void {
            if (self.machine) |*m| m.deinit();
            self.* = undefined;
        }

        /// Caller owns the returned Match (free with `Match.deinit`).
        pub fn next(self: *Iterator) RunError!?Match {
            if (self.done) return null;
            if (self.machine == null and self.re.dfaEligible()) {
                self.machine = try dfa.Machine.init(self.gpa, self.re.prog(), &self.re.alphabet, self.re.dfa_max_states);
            }
            const mach: ?*dfa.Machine = if (self.machine) |*m| m else null;
            // After an empty match, the next thing to try is a longer match
            // in the same place -- not the next position. `.*?` reports empty
            // at 0 and then all of `ab`, where advancing straight away would
            // report empty at 0, 1 and 2 and never the text between them.
            // PCRE and Python both do it this way.
            const m = (try self.re.findAtInner(
                self.gpa,
                self.haystack,
                self.pos,
                if (self.retry_nonempty_at == null) mach else null,
                self.retry_nonempty_at,
            )) orelse {
                // No longer match here after all, so carry on from the next
                // codepoint, which is where the empty one left off.
                if (self.retry_nonempty_at) |at| {
                    self.retry_nonempty_at = null;
                    if (at >= self.haystack.len) {
                        self.done = true;
                        return null;
                    }
                    self.pos = at + common.decode(self.haystack, at).len;
                    return self.next();
                }
                self.done = true;
                return null;
            };
            const sp = m.span();
            self.retry_nonempty_at = null;
            if (sp.end > sp.start) {
                self.pos = sp.end;
            } else if (sp.end >= self.haystack.len) {
                self.done = true;
            } else {
                self.pos = sp.end;
                self.retry_nonempty_at = sp.end;
            }
            return m;
        }
    };
};
