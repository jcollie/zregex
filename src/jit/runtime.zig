// SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

//! Everything the JIT backends share: the layout generated code reads its
//! state from, the helpers it calls for paths not worth inlining, and the
//! static analyses that decide what can be compiled and how.
//!
//! Nothing here is architecture-specific — `codegen_x64.zig` and
//! `codegen_a64.zig` both build on it.
const std = @import("std");
const common = @import("../common.zig");
const compiler = @import("../compiler.zig");

pub const Ctx = extern struct {
    input: [*]const u8,
    input_len: usize,
    start: usize,
    slots: [*]usize,
    stack_base: [*]u8,
    stack_end: usize,
    undo_slots: [*]usize,
    undo_vals: [*]usize,
    undo_len: usize,
    undo_cap: usize,
    /// Decremented on every backtrack; going negative bails to the caller.
    budget: isize,
    match_start: usize,
    match_end: usize,
    touched_backref: usize,
    prog: *const compiler.Program,
    scratch0: usize,
    scratch1: usize,
    scratch2: usize,
};

pub const ctx_input = 0;
pub const ctx_input_len = 8;
pub const ctx_start = 16;
pub const ctx_slots = 24;
pub const ctx_stack_base = 32;
pub const ctx_stack_end = 40;
pub const ctx_undo_slots = 48;
pub const ctx_undo_vals = 56;
pub const ctx_undo_len = 64;
pub const ctx_undo_cap = 72;
pub const ctx_budget = 80;
pub const ctx_match_start = 88;
pub const ctx_match_end = 96;
pub const ctx_touched = 104;
pub const ctx_prog = 112;
pub const ctx_scratch0 = 120;
pub const ctx_scratch1 = 128;
pub const ctx_scratch2 = 136;

comptime {
    std.debug.assert(@offsetOf(Ctx, "input") == ctx_input);
    std.debug.assert(@offsetOf(Ctx, "input_len") == ctx_input_len);
    std.debug.assert(@offsetOf(Ctx, "start") == ctx_start);
    std.debug.assert(@offsetOf(Ctx, "slots") == ctx_slots);
    std.debug.assert(@offsetOf(Ctx, "stack_base") == ctx_stack_base);
    std.debug.assert(@offsetOf(Ctx, "stack_end") == ctx_stack_end);
    std.debug.assert(@offsetOf(Ctx, "undo_slots") == ctx_undo_slots);
    std.debug.assert(@offsetOf(Ctx, "undo_vals") == ctx_undo_vals);
    std.debug.assert(@offsetOf(Ctx, "undo_len") == ctx_undo_len);
    std.debug.assert(@offsetOf(Ctx, "undo_cap") == ctx_undo_cap);
    std.debug.assert(@offsetOf(Ctx, "budget") == ctx_budget);
    std.debug.assert(@offsetOf(Ctx, "match_start") == ctx_match_start);
    std.debug.assert(@offsetOf(Ctx, "match_end") == ctx_match_end);
    std.debug.assert(@offsetOf(Ctx, "touched_backref") == ctx_touched);
    std.debug.assert(@offsetOf(Ctx, "prog") == ctx_prog);
    std.debug.assert(@offsetOf(Ctx, "scratch0") == ctx_scratch0);
    std.debug.assert(@offsetOf(Ctx, "scratch1") == ctx_scratch1);
    std.debug.assert(@offsetOf(Ctx, "scratch2") == ctx_scratch2);
}

/// Backtrack frame: resume address, position, undo length, and an auxiliary
/// word (a repeat's retry floor).
pub const frame_size = 32;
pub const frame_resume = 0;
pub const frame_pos = 8;
pub const frame_undo = 16;
pub const frame_aux = 24;

/// `run` returns one of these.
pub const Status = enum(i64) {
    no_match = 0,
    match = 1,
    /// Budget, stack, or undo-log exhausted: the caller must fall back.
    bail = -1,
};

pub const Fn = *const fn (ctx: *Ctx) callconv(.c) i64;

// Helpers called from generated code for the paths not worth inlining.

/// Length in bytes of the codepoint at `pos`, matching `common.decode`.
pub fn helperCpLen(ctx: *Ctx, pos: usize) callconv(.c) usize {
    return common.decode(ctx.input[0..ctx.input_len], pos).len;
}

/// Length in bytes of the codepoint ending at `pos`.
pub fn helperCpLenBefore(ctx: *Ctx, pos: usize) callconv(.c) usize {
    return common.decodeBefore(ctx.input[0..ctx.input_len], pos).len;
}

/// Next position at or after `pos` holding `byte`, or the input length. Uses
/// the standard library's vectorized scan, which beats any byte loop the
/// generator could emit.
pub fn helperMemchr(ctx: *Ctx, pos: usize, byte: usize) callconv(.c) usize {
    const input = ctx.input[0..ctx.input_len];
    if (pos >= input.len) return input.len;
    return std.mem.indexOfScalarPos(u8, input, pos, @intCast(byte)) orelse input.len;
}

/// Consumed length + 1 if the consuming instruction at `pc` matches at `pos`,
/// else 0. Reuses the interpreter's semantics for the non-ASCII cases.
pub fn helperTest(ctx: *Ctx, pc: usize, pos: usize) callconv(.c) usize {
    const prog = ctx.prog;
    const input = ctx.input[0..ctx.input_len];
    if (pos >= input.len) return 0;
    const d = common.decode(input, pos);
    const ok = switch (prog.insts[pc]) {
        .char => |c| common.charEq(c.cp, d.cp, c.ci),
        .class => |cl| common.classMatches(
            prog.ranges[cl.start..][0..cl.len],
            cl.negated,
            cl.ci,
            d.cp,
        ),
        .any => true,
        .any_not_nl => d.cp != '\n',
        else => unreachable,
    };
    return if (ok) d.len + 1 else 0;
}

/// Whether the single-codepoint sub-program at `pc` accepts the codepoint
/// that *ends* at `pos`.
///
/// Generated code cannot get this by stepping back and decoding forward.
/// Where the text is not valid UTF-8 the two disagree: at a position inside a
/// multi-byte sequence, `decodeBefore` falls back to the single byte before
/// it, while decoding forward from there finds the whole sequence — which
/// ends somewhere else entirely.
pub fn helperLookBehind(ctx: *Ctx, pc: usize, pos: usize) callconv(.c) usize {
    if (pos == 0) return 0;
    const input = ctx.input[0..ctx.input_len];
    const cp = common.decodeBefore(input, pos).cp;
    const ok = switch (ctx.prog.insts[pc]) {
        .char => |ch| common.charEq(ch.cp, cp, ch.ci),
        .class => |cl| common.classMatches(
            ctx.prog.ranges[cl.start..][0..cl.len],
            cl.negated,
            cl.ci,
            cp,
        ),
        .any => true,
        .any_not_nl => cp != '\n',
        else => false,
    };
    return @intFromBool(ok);
}

/// Consumed length + 1 if the backreference at `pc` matches at `pos`.
pub fn helperBackref(ctx: *Ctx, pc: usize, pos: usize) callconv(.c) usize {
    const br = ctx.prog.insts[pc].backref;
    const input = ctx.input[0..ctx.input_len];
    const a = ctx.slots[2 * @as(usize, br.group)];
    const b = ctx.slots[2 * @as(usize, br.group) + 1];
    // A backreference to a group that never participated fails, as it does in
    // PCRE; JavaScript is the odd one out in matching empty. The same goes for
    // a group caught mid-flight: re-entering one overwrites its start before
    // its end, so a backreference reached while it is open sees a start past
    // the end of the previous iteration's capture.
    if (a == unset or b == unset or a > b) return 0;
    const text = input[a..b];
    // Biased by one so that zero can mean "no match": a backreference to an
    // empty group matches and consumes nothing.
    const n = common.backrefLen(input, pos, text, br.ci) orelse return 0;
    return n + 1;
}

/// Slot sentinel for "did not participate"; the interpreter uses `null`.
pub const unset: usize = std.math.maxInt(usize);

// ---------------------------------------------------------------------------

pub const Support = struct {
    /// Instructions this generator can emit.
    pub fn canCompile(prog: compiler.Program) bool {
        for (prog.insts, 0..) |inst, pc| {
            switch (inst) {
                .char, .any, .any_not_nl, .class, .split, .jmp, .save, .assert, .match, .backref, .set_pos, .exit_if_same, .rep => {},
                .look => |l| {
                    // Only single-codepoint sub-programs are inlined; anything
                    // longer needs the interpreter's recursive matcher.
                    if (l.target + 1 >= prog.insts.len) return false;
                    if (prog.insts[l.target + 1] != .match) return false;
                    switch (prog.insts[l.target]) {
                        .char, .class, .any, .any_not_nl => {},
                        else => return false,
                    }
                    _ = pc;
                },
            }
        }
        return true;
    }
};

/// Is every codepoint this instruction accepts below 0x80? When true a byte
/// >= 0x80 can be rejected without decoding.
pub fn asciiOnly(prog: compiler.Program, inst: compiler.Inst) bool {
    return switch (inst) {
        .char => |c| c.cp < 0x80,
        .class => |cl| blk: {
            if (cl.negated) break :blk false;
            for (prog.ranges[cl.start..][0..cl.len]) |r| {
                if (r.hi >= 0x80) break :blk false;
            }
            break :blk true;
        },
        else => false,
    };
}

pub const max_simd_ranges = 6;

/// The ASCII bytes a single-codepoint test accepts, as merged ranges.
pub const AsciiSet = struct {
    ranges: [max_simd_ranges]common.ClassRange,
    len: usize,
};

/// Identical classes appear once per emit site (a repeat emits its child
/// several times); one table each is enough.
/// The ASCII acceptance set of a repeat's child, as ranges, when it is
/// narrow enough to drive the vector scanner. Null when the instruction
/// can match a non-ASCII codepoint (the scanner would have to stop and
/// re-enter around every helper call) or needs too many ranges.
pub fn asciiRunSet(prog: compiler.Program, inst: compiler.Inst) ?AsciiSet {
    if (!asciiOnly(prog, inst)) return null;
    var accept: [128]bool = @splat(false);
    switch (inst) {
        .char => |c| {
            accept[c.cp] = true;
            if (c.ci) {
                if (c.cp >= 'a' and c.cp <= 'z') accept[c.cp - 32] = true;
                if (c.cp >= 'A' and c.cp <= 'Z') accept[c.cp + 32] = true;
            }
        },
        .class => |cl| {
            const ranges = prog.ranges[cl.start..][0..cl.len];
            for (0..128) |cp| {
                accept[cp] = common.classMatches(ranges, cl.negated, cl.ci, @intCast(cp));
            }
        },
        else => return null,
    }
    var set = AsciiSet{ .ranges = undefined, .len = 0 };
    var cp: u21 = 0;
    while (cp < 128) {
        if (!accept[cp]) {
            cp += 1;
            continue;
        }
        const lo = cp;
        while (cp < 128 and accept[cp]) cp += 1;
        if (set.len == max_simd_ranges) return null;
        set.ranges[set.len] = .{ .lo = lo, .hi = cp - 1 };
        set.len += 1;
    }
    return if (set.len == 0) null else set;
}

pub const ScanChar = struct { byte: u8, ci: bool };

pub fn retryScanChar(prog: compiler.Program, cont_pc: u32) ?ScanChar {
    var pc = cont_pc;
    var hops: u8 = 0;
    while (hops < 16) : (hops += 1) {
        if (pc >= prog.insts.len) return null;
        switch (prog.insts[pc]) {
            .save => pc += 1,
            .jmp => |t| pc = t,
            else => break,
        }
    }
    if (pc >= prog.insts.len) return null;
    const c: compiler.CharOp = switch (prog.insts[pc]) {
        .char => |c| c,
        .look => |l| blk: {
            if (l.kind != .ahead_pos) return null;
            switch (prog.insts[l.target]) {
                .char => |c| break :blk c,
                else => return null,
            }
        },
        else => return null,
    };
    if (c.cp >= 0x80) return null;
    const folds = c.ci and ((c.cp >= 'a' and c.cp <= 'z') or (c.cp >= 'A' and c.cp <= 'Z'));
    return .{ .byte = @intCast(c.cp), .ci = folds };
}

/// Whether a byte is accepted by a repeat's child instruction.
pub fn childAcceptsByte(prog: compiler.Program, child: compiler.Inst, byte: u8) bool {
    const cp: u21 = byte;
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
        else => false,
    };
}

/// Can a shorter run ever help? Greedy retries resume strictly inside the run
/// the repeat consumed, so the byte at any retry position is one the child
/// matched. If the continuation must match a literal the child never matches
/// -- `\w+@`, `[a-z]+-` -- no retry can succeed and no frame is needed.
pub fn retryIsFutile(prog: compiler.Program, pc: u32) bool {
    const sc = retryScanChar(prog, pc + 2) orelse return false;
    const child = prog.insts[pc + 1];
    if (childAcceptsByte(prog, child, sc.byte)) return false;
    if (sc.ci) {
        const other: u8 = if (sc.byte >= 'a') sc.byte - 32 else sc.byte + 32;
        if (childAcceptsByte(prog, child, other)) return false;
    }
    return true;
}

/// Detects the leading greedy unbounded repeat that lets a failed attempt skip
/// the whole run it consumed (see `backtrack.run`).
pub fn leadSkipChild(prog: compiler.Program) ?u32 {
    var pc: u32 = 0;
    while (pc < prog.insts.len and prog.insts[pc] == .save) pc += 1;
    if (pc >= prog.insts.len or prog.insts[pc] != .rep) return null;
    const r = prog.insts[pc].rep;
    if (!r.greedy or r.max != compiler.RepOp.unbounded) return null;
    return pc + 1;
}
