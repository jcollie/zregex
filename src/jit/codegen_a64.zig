// SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

//! AArch64 code generator: the same backtracking matcher as the x86-64
//! backend, built on the shared `runtime.zig` layout and helpers, so both
//! produce identical matches.
//!
//! State lives in callee-saved registers, which survive the helper calls:
//!
//!   x19 = input base   x20 = input length   x21 = current position
//!   x22 = capture slots   x23 = backtrack stack top   x24 = context
//!
//! Two things differ from x86-64 beyond the instruction set. AArch64 has no
//! ALU-on-memory, so context fields are loaded, modified, and stored back.
//! And NEON has no `pmovmskb`, so the run scanner narrows its 16 comparison
//! lanes to 16 nibbles with `shrn` and finds the first set one with
//! `rbit`+`clz` — the standard stand-in.
const std = @import("std");
const common = @import("../common.zig");
const compiler = @import("../compiler.zig");
const a64 = @import("a64.zig");
const runtime = @import("runtime.zig");

pub const Ctx = runtime.Ctx;
pub const Status = runtime.Status;
pub const Fn = runtime.Fn;
pub const Support = runtime.Support;
pub const unset = runtime.unset;

const Reg = a64.Reg;
const Label = a64.Label;

const r_input: Reg = .x19;
const r_len: Reg = .x20;
const r_pos: Reg = .x21;
const r_slots: Reg = .x22;
const r_stack: Reg = .x23;
const r_ctx: Reg = .x24;

/// Bytes of stack the prologue claims for the six state registers plus the
/// link register, rounded to keep the stack 16-byte aligned.
const frame_save = 64;

const Blob = struct {
    label: Label,
    bytes: [32]u8,
    len: u8,
    /// Vector constants must be 16-byte aligned to be loaded with `ldr q`.
    aligned: bool,
};

const Gen = struct {
    a: a64.Asm,
    prog: compiler.Program,
    gpa: std.mem.Allocator,
    pc_labels: []Label,
    dead: []bool,
    blobs: std.ArrayList(Blob) = .empty,
    l_fail: Label = undefined,
    l_bail: Label = undefined,
    l_no_match: Label = undefined,
    l_epilogue: Label = undefined,
    l_attempt: Label = undefined,
    l_attempt_failed: Label = undefined,
    prefilter: *const compiler.Prefilter,
    prefilter_label: ?Label = null,

    const Error = std.mem.Allocator.Error;

    fn emitBlob(self: *Gen, bytes: []const u8, aligned: bool) Error!Label {
        for (self.blobs.items) |blob| {
            if (blob.aligned == aligned and blob.len == bytes.len and
                std.mem.eql(u8, blob.bytes[0..blob.len], bytes)) return blob.label;
        }
        const l = try self.a.label();
        var padded: [32]u8 = @splat(0);
        @memcpy(padded[0..bytes.len], bytes);
        try self.blobs.append(self.gpa, .{
            .label = l,
            .bytes = padded,
            .len = @intCast(bytes.len),
            .aligned = aligned,
        });
        return l;
    }

    fn classBits(self: *Gen, cl: compiler.ClassOp) [16]u8 {
        var bits: [16]u8 = @splat(0);
        const ranges = self.prog.ranges[cl.start..][0..cl.len];
        for (0..128) |cp| {
            if (common.classMatches(ranges, cl.negated, cl.ci, @intCast(cp)))
                bits[cp / 8] |= @as(u8, 1) << @intCast(cp % 8);
        }
        return bits;
    }

    /// Call a Zig helper; arguments must already be in x0.. and the result
    /// comes back in x0. x16 is the ABI's own scratch register for exactly
    /// this.
    fn call(self: *Gen, func: anytype) void {
        self.a.movImm(.x16, @intFromPtr(func));
        self.a.blr(.x16);
    }

    fn loadCtx(self: *Gen, dst: Reg, off: u32) void {
        self.a.ldr(dst, r_ctx, off);
    }

    fn storeCtx(self: *Gen, src: Reg, off: u32) void {
        self.a.str(src, r_ctx, off);
    }

    fn storeCtxImm(self: *Gen, value: u64, off: u32) void {
        self.a.movImm(.x9, value);
        self.a.str(.x9, r_ctx, off);
    }

    /// Test the consuming instruction at `pc` against the codepoint at r_pos,
    /// branching to `on_fail` when it does not match and otherwise advancing
    /// r_pos past it when `advance` is set.
    fn emitTest(self: *Gen, pc: u32, on_fail: Label, advance: bool) Error!void {
        const a = &self.a;
        const inst = self.prog.insts[pc];
        a.cmpReg(r_pos, r_len);
        a.bcond(.hs, on_fail);

        const l_done = try a.label();
        switch (inst) {
            .char => |c| {
                if (c.cp < 0x80) {
                    a.ldrbReg(.x9, r_input, r_pos);
                    const lo: u12 = @intCast(common.foldLower(c.cp));
                    const folds = c.ci and ((c.cp >= 'a' and c.cp <= 'z') or (c.cp >= 'A' and c.cp <= 'Z'));
                    if (!folds) {
                        a.cmpImm(.x9, @intCast(c.cp));
                        a.bcond(.ne, on_fail);
                    } else {
                        const l_ok = try a.label();
                        a.cmpImm(.x9, lo);
                        a.bcond(.eq, l_ok);
                        a.cmpImm(.x9, lo - 32);
                        a.bcond(.ne, on_fail);
                        a.place(l_ok);
                    }
                    if (advance) a.addImm(r_pos, r_pos, 1);
                    a.place(l_done);
                    return;
                }
                try self.emitHelperTest(pc, on_fail, advance);
                a.place(l_done);
                return;
            },
            .class => |cl| {
                const ranges = self.prog.ranges[cl.start..][0..cl.len];
                if (compiler.asciiPairOf(ranges, cl.negated, cl.ci)) |pair| {
                    // See `compiler.AsciiPair`: compares beat the bit table
                    // for the classes caseless letters compile to.
                    const l_ok = try a.label();
                    a.ldrbReg(.x9, r_input, r_pos);
                    a.cmpImm(.x9, pair.cps[0]);
                    a.bcond(.eq, l_ok);
                    if (pair.n == 2) {
                        a.cmpImm(.x9, pair.cps[1]);
                        a.bcond(.eq, l_ok);
                    }
                    if (pair.has_high) {
                        a.cmpImm(.x9, 0x80);
                        a.bcond(.lo, on_fail);
                        try self.emitHelperTest(pc, on_fail, advance);
                        a.b(l_done);
                    } else {
                        a.b(on_fail);
                    }
                    a.place(l_ok);
                    if (advance) a.addImm(r_pos, r_pos, 1);
                    a.place(l_done);
                    return;
                }
                const l_high = try a.label();
                a.ldrbReg(.x9, r_input, r_pos);
                a.cmpImm(.x9, 0x80);
                a.bcond(.hs, l_high);
                // Bit `cp` of a 128-bit table: pick the half, then shift it
                // down. A register shift is taken modulo 64, so the codepoint
                // doubles as the bit index with no masking.
                const bits = try self.emitBlob(&self.classBits(cl), false);
                a.adr(.x10, bits);
                a.lsrImm(.x11, .x9, 6);
                a.ldrRegScaled(.x10, .x10, .x11);
                a.lsrReg(.x10, .x10, .x9);
                a.tbz(.x10, 0, on_fail);
                if (advance) a.addImm(r_pos, r_pos, 1);
                a.b(l_done);
                a.place(l_high);
                if (runtime.asciiOnly(self.prog, inst)) {
                    a.b(on_fail);
                } else {
                    try self.emitHelperTest(pc, on_fail, advance);
                }
                a.place(l_done);
                return;
            },
            .any, .any_not_nl => {
                const l_high = try a.label();
                a.ldrbReg(.x9, r_input, r_pos);
                a.cmpImm(.x9, 0x80);
                a.bcond(.hs, l_high);
                if (inst == .any_not_nl) {
                    a.cmpImm(.x9, '\n');
                    a.bcond(.eq, on_fail);
                }
                if (advance) a.addImm(r_pos, r_pos, 1);
                a.b(l_done);
                a.place(l_high);
                if (advance) {
                    a.movReg(.x0, r_ctx);
                    a.movReg(.x1, r_pos);
                    self.call(&runtime.helperCpLen);
                    a.addReg(r_pos, r_pos, .x0);
                }
                a.place(l_done);
                return;
            },
            else => unreachable,
        }
    }

    fn emitHelperTest(self: *Gen, pc: u32, on_fail: Label, advance: bool) Error!void {
        const a = &self.a;
        a.movReg(.x0, r_ctx);
        a.movImm(.x1, pc);
        a.movReg(.x2, r_pos);
        self.call(&runtime.helperTest);
        a.cbz(.x0, on_fail);
        if (advance) {
            a.subImm(.x0, .x0, 1); // length + 1 -> length
            a.addReg(r_pos, r_pos, .x0);
        }
    }

    /// Push a backtrack frame resuming at `resume_label`. `aux` must not be
    /// x9 or x10, which this uses as scratch.
    fn emitPushFrame(self: *Gen, resume_label: Label, pos_reg: Reg, aux: ?Reg) void {
        const a = &self.a;
        std.debug.assert(aux == null or (aux.? != .x9 and aux.? != .x10));
        // Speculative work is metered here as well as on the failure path.
        self.loadCtx(.x9, runtime.ctx_budget);
        a.subImm(.x9, .x9, 1);
        self.storeCtx(.x9, runtime.ctx_budget);
        a.cmpImm(.x9, 0);
        a.bcond(.lt, self.l_bail);
        a.addImm(.x9, r_stack, runtime.frame_size);
        self.loadCtx(.x10, runtime.ctx_stack_end);
        a.cmpReg(.x9, .x10);
        a.bcond(.hi, self.l_bail);
        if (aux) |r| a.str(r, r_stack, runtime.frame_aux);
        a.adr(.x10, resume_label);
        a.str(.x10, r_stack, runtime.frame_resume);
        a.str(pos_reg, r_stack, runtime.frame_pos);
        self.loadCtx(.x10, runtime.ctx_undo_len);
        a.str(.x10, r_stack, runtime.frame_undo);
        a.movReg(r_stack, .x9);
    }

    fn emitSlotWrite(self: *Gen, slot: u16) void {
        const a = &self.a;
        self.loadCtx(.x9, runtime.ctx_undo_len);
        self.loadCtx(.x10, runtime.ctx_undo_cap);
        a.cmpReg(.x9, .x10);
        a.bcond(.hs, self.l_bail);
        self.loadCtx(.x10, runtime.ctx_undo_slots);
        a.movImm(.x11, slot);
        a.strRegScaled(.x11, .x10, .x9);
        a.ldr(.x11, r_slots, @as(u32, slot) * 8);
        self.loadCtx(.x10, runtime.ctx_undo_vals);
        a.strRegScaled(.x11, .x10, .x9);
        a.addImm(.x9, .x9, 1);
        self.storeCtx(.x9, runtime.ctx_undo_len);
        a.str(r_pos, r_slots, @as(u32, slot) * 8);
    }

    /// prev/next word-character flags for `\b`, in x9 and x10.
    fn emitWordFlags(self: *Gen) Error!void {
        const a = &self.a;
        const word_table = try self.emitBlob(&wordBits(), false);
        const l_p_done = try a.label();
        const l_n_done = try a.label();
        a.movImm(.x9, 0);
        a.cbz(r_pos, l_p_done);
        a.subImm(.x11, r_pos, 1);
        a.ldrbReg(.x11, r_input, .x11);
        a.cmpImm(.x11, 0x80);
        a.bcond(.hs, l_p_done); // non-ASCII is never a word char
        a.adr(.x12, word_table);
        a.lsrImm(.x13, .x11, 6);
        a.ldrRegScaled(.x12, .x12, .x13);
        a.lsrReg(.x12, .x12, .x11);
        a.tbz(.x12, 0, l_p_done);
        a.movImm(.x9, 1);
        a.place(l_p_done);

        a.movImm(.x10, 0);
        a.cmpReg(r_pos, r_len);
        a.bcond(.hs, l_n_done);
        a.ldrbReg(.x11, r_input, r_pos);
        a.cmpImm(.x11, 0x80);
        a.bcond(.hs, l_n_done);
        a.adr(.x12, word_table);
        a.lsrImm(.x13, .x11, 6);
        a.ldrRegScaled(.x12, .x12, .x13);
        a.lsrReg(.x12, .x12, .x11);
        a.tbz(.x12, 0, l_n_done);
        a.movImm(.x10, 1);
        a.place(l_n_done);
    }

    fn emitAssert(self: *Gen, kind: common.Assertion) Error!void {
        const a = &self.a;
        switch (kind) {
            .begin_text => a.cbnz(r_pos, self.l_fail),
            .end_text => {
                a.cmpReg(r_pos, r_len);
                a.bcond(.ne, self.l_fail);
            },
            .end_text_or_final_newline => {
                const l_ok = try a.label();
                a.cmpReg(r_pos, r_len);
                a.bcond(.eq, l_ok);
                // Otherwise only a newline in the final position will do.
                a.addImm(.x9, r_pos, 1);
                a.cmpReg(.x9, r_len);
                a.bcond(.ne, self.l_fail);
                a.ldrbReg(.x9, r_input, r_pos);
                a.cmpImm(.x9, '\n');
                a.bcond(.ne, self.l_fail);
                a.place(l_ok);
            },
            .begin_line => {
                const l_ok = try a.label();
                a.cbz(r_pos, l_ok);
                // Past the start it takes a newline just behind, and one that
                // ends the input starts no line after it.
                a.cmpReg(r_pos, r_len);
                a.bcond(.eq, self.l_fail);
                a.subImm(.x9, r_pos, 1);
                a.ldrbReg(.x9, r_input, .x9);
                a.cmpImm(.x9, '\n');
                a.bcond(.ne, self.l_fail);
                a.place(l_ok);
            },
            .end_line => {
                const l_ok = try a.label();
                a.cmpReg(r_pos, r_len);
                a.bcond(.eq, l_ok);
                a.ldrbReg(.x9, r_input, r_pos);
                a.cmpImm(.x9, '\n');
                a.bcond(.ne, self.l_fail);
                a.place(l_ok);
            },
            .word_boundary, .not_word_boundary => {
                try self.emitWordFlags();
                a.cmpReg(.x9, .x10);
                a.bcond(if (kind == .word_boundary) .eq else .ne, self.l_fail);
            },
        }
    }

    fn emitStepBack(self: *Gen) Error!void {
        const a = &self.a;
        const l_one = try a.label();
        const l_done = try a.label();
        a.subImm(.x9, r_pos, 1);
        a.ldrbReg(.x9, r_input, .x9);
        a.cmpImm(.x9, 0x80);
        a.bcond(.lo, l_one);
        a.movReg(.x0, r_ctx);
        a.movReg(.x1, r_pos);
        self.call(&runtime.helperCpLenBefore);
        a.subReg(r_pos, r_pos, .x0);
        a.b(l_done);
        a.place(l_one);
        a.subImm(r_pos, r_pos, 1);
        a.place(l_done);
    }

    fn emitLook(self: *Gen, l: compiler.LookOp) Error!void {
        const a = &self.a;
        const child_pc = l.target;
        switch (l.kind) {
            .ahead_pos => try self.emitTest(child_pc, self.l_fail, false),
            .ahead_neg => {
                const l_ok = try a.label();
                try self.emitTest(child_pc, l_ok, false);
                a.b(self.l_fail);
                a.place(l_ok);
            },
            .behind_pos, .behind_neg => {
                // Asking the helper, rather than stepping back and decoding
                // forward: those differ wherever the text is not valid UTF-8.
                const positive = l.kind == .behind_pos;
                a.movReg(.x0, r_ctx);
                a.movImm(.x1, child_pc);
                a.movReg(.x2, r_pos);
                self.call(&runtime.helperLookBehind);
                if (positive) a.cbz(.x0, self.l_fail) else a.cbnz(.x0, self.l_fail);
            },
        }
    }

    /// Consume a run of accepted ASCII bytes sixteen at a time with NEON.
    fn emitSimdRun(self: *Gen, set: runtime.AsciiSet) Error!void {
        const a = &self.a;
        var lo_regs: [runtime.max_simd_ranges]a64.Vec = undefined;
        var hi_regs: [runtime.max_simd_ranges]a64.Vec = undefined;
        for (set.ranges[0..set.len], 0..) |r, i| {
            lo_regs[i] = @enumFromInt(2 + 2 * i);
            hi_regs[i] = @enumFromInt(3 + 2 * i);
            const lo: [16]u8 = @splat(@intCast(r.lo));
            const hi: [16]u8 = @splat(@intCast(r.hi));
            a.adr(.x9, try self.emitBlob(&lo, true));
            a.ldrqImm(lo_regs[i], .x9, 0);
            a.adr(.x9, try self.emitBlob(&hi, true));
            a.ldrqImm(hi_regs[i], .x9, 0);
        }
        const l_loop = try a.here();
        const l_done = try a.label();
        const l_next = try a.label();
        a.subReg(.x9, r_len, r_pos);
        a.cmpImm(.x9, 16);
        a.bcond(.lo, l_done);
        a.ldrqReg(.v0, r_input, r_pos);
        for (0..set.len) |i| {
            a.cmgt16b(.v14, lo_regs[i], .v0); // lo > v
            a.cmgt16b(.v15, .v0, hi_regs[i]); // v > hi
            a.orr16b(.v14, .v14, .v15); // outside this range
            if (i == 0) a.orr16b(.v1, .v14, .v14) else a.and16b(.v1, .v1, .v14);
        }
        // No byte-mask move on NEON: narrow the sixteen 0x00/0xFF lanes to
        // sixteen nibbles, then the first set nibble is the first byte
        // outside the set.
        a.shrn8b4(.v1, .v1);
        a.fmovToReg(.x9, .v1);
        a.cbz(.x9, l_next);
        a.rbit(.x10, .x9);
        a.clz(.x10, .x10);
        a.lsrImm(.x10, .x10, 2); // nibble index -> byte index
        a.addReg(r_pos, r_pos, .x10);
        a.b(l_done);
        a.place(l_next);
        a.addImm(r_pos, r_pos, 16);
        a.b(l_loop);
        a.place(l_done);
    }

    fn emitMandatory(self: *Gen, child_pc: u32, count: u32, on_fail: Label) Error!void {
        const a = &self.a;
        const max_peel = 8;
        if (count <= max_peel) {
            var i: u32 = 0;
            while (i < count) : (i += 1) try self.emitTest(child_pc, on_fail, true);
            return;
        }
        self.storeCtxImm(count, runtime.ctx_scratch1);
        const l_loop = try a.here();
        const l_done = try a.label();
        self.loadCtx(.x9, runtime.ctx_scratch1);
        a.cbz(.x9, l_done);
        try self.emitTest(child_pc, on_fail, true);
        self.loadCtx(.x9, runtime.ctx_scratch1);
        a.subImm(.x9, .x9, 1);
        self.storeCtx(.x9, runtime.ctx_scratch1);
        a.b(l_loop);
        a.place(l_done);
    }

    fn emitRep(self: *Gen, pc: u32, r: compiler.RepOp) Error!void {
        const a = &self.a;
        const child_pc = pc + 1;
        const cont = self.pc_labels[pc + 2];
        const max_peel = 8;

        try self.emitMandatory(child_pc, r.min, self.l_fail);

        if (!r.greedy) {
            if (r.max <= r.min) {
                a.b(cont);
                return;
            }
            const retry = try a.label();
            const remaining: u64 = if (r.max == compiler.RepOp.unbounded)
                std.math.maxInt(u64)
            else
                r.max - r.min;
            a.movImm(.x11, remaining);
            self.emitPushFrame(retry, r_pos, .x11);
            a.b(cont);

            a.place(retry);
            const l_pop_fail = try a.label();
            a.ldur(.x9, r_stack, @as(i32, runtime.frame_aux) - runtime.frame_size);
            a.cbz(.x9, l_pop_fail);
            try self.emitTest(child_pc, l_pop_fail, true);
            a.ldur(.x9, r_stack, @as(i32, runtime.frame_aux) - runtime.frame_size);
            a.subImm(.x9, .x9, 1);
            a.stur(.x9, r_stack, @as(i32, runtime.frame_aux) - runtime.frame_size);
            a.stur(r_pos, r_stack, @as(i32, runtime.frame_pos) - runtime.frame_size);
            a.b(cont);
            a.place(l_pop_fail);
            a.subImm(r_stack, r_stack, runtime.frame_size);
            a.b(self.l_fail);
            return;
        }

        self.storeCtx(r_pos, runtime.ctx_scratch0);
        const l_loop_done = try a.label();
        if (r.max == compiler.RepOp.unbounded) {
            if (runtime.asciiRunSet(self.prog, self.prog.insts[child_pc])) |set| {
                try self.emitSimdRun(set);
            }
            const l_loop = try a.here();
            try self.emitTest(child_pc, l_loop_done, true);
            a.b(l_loop);
        } else {
            const remaining = r.max - r.min;
            if (remaining <= max_peel) {
                var i: u32 = 0;
                while (i < remaining) : (i += 1) try self.emitTest(child_pc, l_loop_done, true);
            } else {
                self.storeCtxImm(remaining, runtime.ctx_scratch1);
                const l_loop = try a.here();
                self.loadCtx(.x9, runtime.ctx_scratch1);
                a.cbz(.x9, l_loop_done);
                try self.emitTest(child_pc, l_loop_done, true);
                self.loadCtx(.x9, runtime.ctx_scratch1);
                a.subImm(.x9, .x9, 1);
                self.storeCtx(.x9, runtime.ctx_scratch1);
                a.b(l_loop);
            }
        }
        a.place(l_loop_done);

        if (runtime.retryIsFutile(self.prog, pc)) {
            a.b(cont);
            return;
        }

        const l_noframe = try a.label();
        const retry = try a.label();
        self.loadCtx(.x11, runtime.ctx_scratch0);
        a.cmpReg(r_pos, .x11);
        a.bcond(.ls, l_noframe);
        self.emitPushFrame(retry, r_pos, .x11);
        a.place(l_noframe);
        a.b(cont);

        a.place(retry);
        const l_pop_fail = try a.label();
        a.ldur(.x9, r_stack, @as(i32, runtime.frame_aux) - runtime.frame_size);
        if (runtime.retryScanChar(self.prog, pc + 2)) |sc| {
            const l_scan = try a.here();
            const l_found = try a.label();
            a.cmpReg(r_pos, .x9);
            a.bcond(.ls, l_pop_fail);
            a.subImm(r_pos, r_pos, 1);
            a.ldrbReg(.x10, r_input, r_pos);
            a.cmpImm(.x10, sc.byte);
            a.bcond(.eq, l_found);
            if (sc.ci) {
                const other: u8 = if (sc.byte >= 'a') sc.byte - 32 else sc.byte + 32;
                a.cmpImm(.x10, other);
                a.bcond(.eq, l_found);
            }
            a.b(l_scan);
            a.place(l_found);
        } else {
            const l_kept = try a.label();
            a.cmpReg(r_pos, .x9);
            a.bcond(.ls, l_pop_fail);
            // Remember where the retry started; the frame's own position is
            // rewritten below, and on the failure path the frame is dropped.
            a.stur(r_pos, r_stack, @as(i32, runtime.frame_pos) - runtime.frame_size);
            try self.emitStepBack();
            // A codepoint can straddle the floor when the search started
            // inside one; the helper may have clobbered x9, so reload it.
            a.ldur(.x9, r_stack, @as(i32, runtime.frame_aux) - runtime.frame_size);
            a.cmpReg(r_pos, .x9);
            a.bcond(.hs, l_kept);
            // Stepping over the whole sequence went back past the floor. The
            // run was built one byte at a time through it, since decoding
            // forward from inside a sequence degrades to a single byte, so
            // walk back that way instead.
            a.ldur(r_pos, r_stack, @as(i32, runtime.frame_pos) - runtime.frame_size);
            a.subImm(r_pos, r_pos, 1);
            a.place(l_kept);
        }
        a.stur(r_pos, r_stack, @as(i32, runtime.frame_pos) - runtime.frame_size);
        a.b(cont);
        a.place(l_pop_fail);
        a.subImm(r_stack, r_stack, runtime.frame_size);
        a.b(self.l_fail);
    }
};

fn wordBits() [16]u8 {
    var bits: [16]u8 = @splat(0);
    for (0..128) |cp| {
        if (common.isWordChar(@intCast(cp))) bits[cp / 8] |= @as(u8, 1) << @intCast(cp % 8);
    }
    return bits;
}

/// Generate a matcher for `prog` into `code_buf`. Returns the code length, or
/// null when the program uses something the generator does not implement, the
/// code does not fit, or a branch target ends up out of reach.
pub fn compile(
    gpa: std.mem.Allocator,
    prog: compiler.Program,
    prefilter: *const compiler.Prefilter,
    code_buf: []u8,
) std.mem.Allocator.Error!?u32 {
    if (!Support.canCompile(prog)) return null;

    // Allocated ahead of the struct rather than inside it, each with its
    // cleanup registered before the next is attempted. A `try` inside a
    // struct literal abandons the expression on failure, so `g` is never
    // assigned and a `defer` written after the literal never runs -- which
    // leaked `pc_labels` whenever the allocation right after it failed.
    const pc_labels = try gpa.alloc(Label, prog.insts.len);
    defer gpa.free(pc_labels);
    const dead = try gpa.alloc(bool, prog.insts.len);
    defer gpa.free(dead);

    var g = Gen{
        .a = a64.Asm.init(gpa, code_buf),
        .prog = prog,
        .gpa = gpa,
        .pc_labels = pc_labels,
        .dead = dead,
        .prefilter = prefilter,
    };
    defer g.blobs.deinit(gpa);
    defer g.a.deinit();

    const a = &g.a;
    for (g.pc_labels) |*l| l.* = try a.label();
    @memset(g.dead, false);
    for (prog.insts) |inst| {
        if (inst == .look) {
            g.dead[inst.look.target] = true;
            g.dead[inst.look.target + 1] = true;
        }
    }

    g.l_fail = try a.label();
    g.l_bail = try a.label();
    g.l_no_match = try a.label();
    g.l_epilogue = try a.label();
    g.l_attempt = try a.label();
    g.l_attempt_failed = try a.label();

    // -- prologue -----------------------------------------------------------
    a.subImm(a64.sp, a64.sp, frame_save);
    a.str(.x19, a64.sp, 0);
    a.str(.x20, a64.sp, 8);
    a.str(.x21, a64.sp, 16);
    a.str(.x22, a64.sp, 24);
    a.str(.x23, a64.sp, 32);
    a.str(.x24, a64.sp, 40);
    a.str(.x30, a64.sp, 48);
    a.movReg(r_ctx, .x0);
    g.loadCtx(r_input, runtime.ctx_input);
    g.loadCtx(r_len, runtime.ctx_input_len);
    g.loadCtx(r_pos, runtime.ctx_start);
    g.loadCtx(r_slots, runtime.ctx_slots);

    // -- one match attempt starting at r_pos --------------------------------
    a.place(g.l_attempt);
    if (prefilter.usable) {
        const pf_table = try a.label();
        if (prefilter.single) |byte| {
            a.movReg(.x0, r_ctx);
            a.movReg(.x1, r_pos);
            a.movImm(.x2, byte);
            g.call(&runtime.helperMemchr);
            a.movReg(r_pos, .x0);
            a.cmpReg(r_pos, r_len);
            a.bcond(.hs, g.l_no_match);
        } else {
            const l_scan = try a.here();
            const l_ok = try a.label();
            a.cmpReg(r_pos, r_len);
            a.bcond(.hs, g.l_no_match);
            a.ldrbReg(.x9, r_input, r_pos);
            a.adr(.x10, pf_table);
            a.ldrbReg(.x10, .x10, .x9);
            a.cbnz(.x10, l_ok);
            if (prefilter.byte_steppable) {
                a.addImm(r_pos, r_pos, 1);
            } else {
                const l_one = try a.label();
                const l_stepped = try a.label();
                a.cmpImm(.x9, 0x80);
                a.bcond(.lo, l_one);
                a.movReg(.x0, r_ctx);
                a.movReg(.x1, r_pos);
                g.call(&runtime.helperCpLen);
                a.addReg(r_pos, r_pos, .x0);
                a.b(l_stepped);
                a.place(l_one);
                a.addImm(r_pos, r_pos, 1);
                a.place(l_stepped);
            }
            a.b(l_scan);
            a.place(l_ok);
            const empty: [32]u8 = @splat(0);
            try g.blobs.append(gpa, .{ .label = pf_table, .bytes = empty, .len = 0, .aligned = false });
            g.prefilter_label = pf_table;
        }
    }
    g.loadCtx(r_stack, runtime.ctx_stack_base);
    g.storeCtxImm(0, runtime.ctx_undo_len);
    g.storeCtxImm(0, runtime.ctx_touched);
    g.storeCtx(r_pos, runtime.ctx_match_start);
    a.b(g.pc_labels[0]);

    // -- instruction bodies -------------------------------------------------
    for (prog.insts, 0..) |inst, pci| {
        const pc: u32 = @intCast(pci);
        a.place(g.pc_labels[pc]);
        if (g.dead[pc]) continue;
        switch (inst) {
            .char, .class, .any, .any_not_nl => try g.emitTest(pc, g.l_fail, true),
            .assert => |k| try g.emitAssert(k),
            .jmp => |t| a.b(g.pc_labels[t]),
            .split => |t| {
                const stub = try a.label();
                g.emitPushFrame(stub, r_pos, null);
                a.b(g.pc_labels[t[0]]);
                a.place(stub);
                a.subImm(r_stack, r_stack, runtime.frame_size);
                a.b(g.pc_labels[t[1]]);
            },
            .save, .set_pos => |slot| g.emitSlotWrite(slot),
            .exit_if_same => |guard| {
                // An empty iteration leaves the loop; it does not fail.
                a.ldr(.x9, r_slots, @as(u32, guard.slot) * 8);
                a.cmpReg(r_pos, .x9);
                a.bcond(.eq, g.pc_labels[guard.target]);
            },
            .backref => {
                g.storeCtxImm(1, runtime.ctx_touched);
                a.movReg(.x0, r_ctx);
                a.movImm(.x1, pc);
                a.movReg(.x2, r_pos);
                g.call(&runtime.helperBackref);
                a.cbz(.x0, g.l_fail);
                a.subImm(.x0, .x0, 1);
                a.addReg(r_pos, r_pos, .x0);
            },
            .match => {
                g.storeCtx(r_pos, runtime.ctx_match_end);
                a.movImm(.x0, 1);
                a.b(g.l_epilogue);
            },
            .look => |l| try g.emitLook(l),
            .rep => |r| try g.emitRep(pc, r),
        }
    }

    // -- backtracking -------------------------------------------------------
    a.place(g.l_fail);
    {
        const l_have = try a.label();
        const l_unwind = try a.label();
        const l_unwound = try a.label();
        g.loadCtx(.x9, runtime.ctx_stack_base);
        a.cmpReg(r_stack, .x9);
        a.bcond(.hi, l_have);
        // Stack empty: unwind every slot write and give up on this attempt.
        a.movImm(.x11, 0);
        a.adr(.x12, g.l_attempt_failed);
        a.b(l_unwind);

        a.place(l_have);
        g.loadCtx(.x9, runtime.ctx_budget);
        a.subImm(.x9, .x9, 1);
        g.storeCtx(.x9, runtime.ctx_budget);
        a.cmpImm(.x9, 0);
        a.bcond(.lt, g.l_bail);
        // Peek rather than pop: the resume stub decides whether its frame is
        // exhausted, which is what lets one frame stand for a whole range of
        // repeat retries.
        a.ldur(.x12, r_stack, @as(i32, runtime.frame_resume) - runtime.frame_size);
        a.ldur(r_pos, r_stack, @as(i32, runtime.frame_pos) - runtime.frame_size);
        a.ldur(.x11, r_stack, @as(i32, runtime.frame_undo) - runtime.frame_size);

        a.place(l_unwind);
        g.loadCtx(.x9, runtime.ctx_undo_len);
        a.cmpReg(.x9, .x11);
        a.bcond(.ls, l_unwound);
        a.subImm(.x9, .x9, 1);
        g.storeCtx(.x9, runtime.ctx_undo_len);
        g.loadCtx(.x10, runtime.ctx_undo_slots);
        a.ldrRegScaled(.x13, .x10, .x9);
        g.loadCtx(.x10, runtime.ctx_undo_vals);
        a.ldrRegScaled(.x14, .x10, .x9);
        a.strRegScaled(.x14, r_slots, .x13);
        a.b(l_unwind);
        a.place(l_unwound);
        a.br(.x12);
    }

    // -- advance to the next start position ---------------------------------
    a.place(g.l_attempt_failed);
    {
        // Backtracking leaves r_pos wherever the last frame or retry loop put
        // it; the next attempt starts one codepoint past where *this* attempt
        // began.
        g.loadCtx(r_pos, runtime.ctx_match_start);
        a.cmpReg(r_pos, r_len);
        a.bcond(.hs, g.l_no_match);
        if (runtime.leadSkipChild(prog)) |child_pc| {
            const l_no_skip = try a.label();
            const l_skip_done = try a.label();
            g.loadCtx(.x9, runtime.ctx_touched);
            a.cbnz(.x9, l_no_skip);
            if (runtime.asciiRunSet(prog, prog.insts[child_pc])) |set| {
                try g.emitSimdRun(set);
            }
            const l_loop = try a.here();
            try g.emitTest(child_pc, l_skip_done, true);
            a.b(l_loop);
            a.place(l_skip_done);
            a.cmpReg(r_pos, r_len);
            a.bcond(.hs, g.l_no_match);
            a.place(l_no_skip);
        }
        const l_one = try a.label();
        a.ldrbReg(.x9, r_input, r_pos);
        a.cmpImm(.x9, 0x80);
        a.bcond(.lo, l_one);
        a.movReg(.x0, r_ctx);
        a.movReg(.x1, r_pos);
        g.call(&runtime.helperCpLen);
        a.addReg(r_pos, r_pos, .x0);
        a.b(g.l_attempt);
        a.place(l_one);
        a.addImm(r_pos, r_pos, 1);
        a.b(g.l_attempt);
    }

    // -- exits --------------------------------------------------------------
    a.place(g.l_no_match);
    a.movImm(.x0, 0);
    a.b(g.l_epilogue);

    a.place(g.l_bail);
    a.movImm(.x0, std.math.maxInt(u64)); // -1

    a.place(g.l_epilogue);
    a.ldr(.x19, a64.sp, 0);
    a.ldr(.x20, a64.sp, 8);
    a.ldr(.x21, a64.sp, 16);
    a.ldr(.x22, a64.sp, 24);
    a.ldr(.x23, a64.sp, 32);
    a.ldr(.x24, a64.sp, 40);
    a.ldr(.x30, a64.sp, 48);
    a.addImm(a64.sp, a64.sp, frame_save);
    a.ret();

    // -- data ---------------------------------------------------------------
    // Vector constants first, since they are the ones needing alignment.
    a.align16();
    for (g.blobs.items) |blob| {
        if (!blob.aligned) continue;
        a.place(blob.label);
        a.data(blob.bytes[0..blob.len]);
    }
    for (g.blobs.items) |blob| {
        if (blob.aligned) continue;
        if (g.prefilter_label != null and blob.label == g.prefilter_label.?) continue;
        a.place(blob.label);
        a.data(blob.bytes[0..blob.len]);
    }
    if (g.prefilter_label) |l| {
        a.place(l);
        var table: [256]u8 = @splat(0);
        for (prefilter.bytes, 0..) |set, i| table[i] = @intFromBool(set);
        a.data(&table);
    }

    const len = a.finish() catch return null;
    return len;
}
