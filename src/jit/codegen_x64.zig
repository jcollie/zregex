// SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

//! x86-64 code generator: turns a compiled program into a native backtracking
//! matcher with the same leftmost-greedy semantics as `backtrack.zig`.
//!
//! State lives in callee-saved registers, so helper calls cannot disturb it:
//!
//!   rbx = input base   r12 = input length   r13 = current position
//!   r14 = capture slots   r15 = backtrack stack top   rbp = context
//!
//! ASCII is handled entirely inline — a literal is a byte compare, a class is
//! a `bt` against a 128-bit table embedded in the code — and the rare
//! non-ASCII paths call back into Zig helpers that reuse the interpreter's
//! own tested logic. Backtracking frames are 32 bytes on a caller-supplied
//! stack; every frame names the code address that resumes it, so failing is a
//! peek and an indirect jump rather than a dispatch loop.
//!
//! Anything the generator does not support (multi-codepoint lookaround) makes
//! `compile` return null and the caller keeps using the interpreter.
const std = @import("std");
const builtin = @import("builtin");
const common = @import("../common.zig");
const compiler = @import("../compiler.zig");
const x64 = @import("x64.zig");
const cpu = @import("cpu.zig");

const Reg = x64.Reg;
const Mem = x64.Mem;

const runtime = @import("runtime.zig");

pub const Ctx = runtime.Ctx;
pub const Status = runtime.Status;
pub const Fn = runtime.Fn;
pub const Support = runtime.Support;
pub const unset = runtime.unset;
const ctx_input = runtime.ctx_input;
const ctx_input_len = runtime.ctx_input_len;
const ctx_start = runtime.ctx_start;
const ctx_slots = runtime.ctx_slots;
const ctx_stack_base = runtime.ctx_stack_base;
const ctx_stack_end = runtime.ctx_stack_end;
const ctx_undo_slots = runtime.ctx_undo_slots;
const ctx_undo_vals = runtime.ctx_undo_vals;
const ctx_undo_len = runtime.ctx_undo_len;
const ctx_undo_cap = runtime.ctx_undo_cap;
const ctx_budget = runtime.ctx_budget;
const ctx_match_start = runtime.ctx_match_start;
const ctx_match_end = runtime.ctx_match_end;
const ctx_touched = runtime.ctx_touched;
const ctx_prog = runtime.ctx_prog;
const ctx_scratch0 = runtime.ctx_scratch0;
const ctx_scratch1 = runtime.ctx_scratch1;
const ctx_scratch2 = runtime.ctx_scratch2;
const frame_size = runtime.frame_size;
const frame_resume = runtime.frame_resume;
const frame_pos = runtime.frame_pos;
const frame_undo = runtime.frame_undo;
const frame_aux = runtime.frame_aux;
const helperCpLen = runtime.helperCpLen;
const helperCpLenBefore = runtime.helperCpLenBefore;
const helperMemchr = runtime.helperMemchr;
const helperTest = runtime.helperTest;
const helperBackref = runtime.helperBackref;
const asciiOnly = runtime.asciiOnly;
const max_simd_ranges = runtime.max_simd_ranges;
const AsciiSet = runtime.AsciiSet;
const retryScanChar = runtime.retryScanChar;
const retryIsFutile = runtime.retryIsFutile;
const leadSkipChild = runtime.leadSkipChild;

// Windows x64 and System V differ in which registers carry arguments, which
// are callee-saved, and whether the caller must leave scratch space above the
// stack pointer for the callee. The generated code is otherwise identical.
const win_abi = builtin.os.tag == .windows;
const arg0: Reg = if (win_abi) .rcx else .rdi;
const arg1: Reg = if (win_abi) .rdx else .rsi;
const arg2: Reg = if (win_abi) .r8 else .rdx;
/// Windows requires 32 bytes of shadow space above the stack pointer at every
/// call; reserving it once in the prologue covers all of them. The extra 8
/// keeps the stack 16-byte aligned given the pushes below.
/// Chosen so that rsp is 16-byte aligned at every call given the pushes
/// above: with eight of them rsp sits 8 past a boundary, and 40 (or 40 plus
/// any multiple of 16) brings it back. The saved vector registers go above
/// the 32-byte shadow space and are written with unaligned stores, so they
/// impose no alignment of their own.
const stack_reserve: i32 = if (win_abi) 40 else 8;
/// xmm0..xmm5 are call-clobbered under both ABIs, so data, the accumulator
/// and the two temporaries live there and a class needing one range touches
/// nothing that must be preserved. Range constants start above them.
const first_const_xmm = 4;
/// Windows, unlike System V, requires xmm6..xmm15 to be preserved across a
/// call, so a scanner wide enough to reach them saves what it uses.
const first_saved_xmm = 6;
/// rsi and rdi are callee-saved on Windows, and the generator uses both as
/// scratch, so there they must be saved and restored.
const saved_regs: []const Reg = if (win_abi)
    &.{ .rbp, .rbx, .r12, .r13, .r14, .r15, .rsi, .rdi }
else
    &.{ .rbp, .rbx, .r12, .r13, .r14, .r15 };

// Registers holding machine state.
const r_input: Reg = .rbx;
const r_len: Reg = .r12;
const r_pos: Reg = .r13;
const r_slots: Reg = .r14;
const r_stack: Reg = .r15;
const r_ctx: Reg = .rbp;

fn ctxMem(off: i32) Mem {
    return .{ .base = r_ctx, .disp = off };
}

/// `[input + pos]`.
fn inputAt(pos: Reg, disp: i32) Mem {
    return .{ .base = r_input, .index = pos, .scale = 0, .disp = disp };
}

// ---------------------------------------------------------------------------
const Blob = struct {
    label: x64.Label,
    bytes: [32]u8,
    len: u8,
};

/// Widest run scanner: two SSE registers hold each range's bounds, leaving
/// four for the data, the accumulator, and two temporaries.
const BitsCache = struct {
    bytes: [32]u8,
    len: u8,
    label: x64.Label,
};

pub const Gen = struct {
    a: x64.Asm,
    prog: compiler.Program,
    gpa: std.mem.Allocator,
    pc_labels: []x64.Label,
    /// Instructions inside lookaround sub-programs: never entered directly.
    dead: []bool,
    blobs: std.ArrayList(Blob) = .empty,
    bits_cache: std.ArrayList(BitsCache) = .empty,
    l_fail: x64.Label = undefined,
    l_bail: x64.Label = undefined,
    l_no_match: x64.Label = undefined,
    l_epilogue: x64.Label = undefined,
    l_attempt: x64.Label = undefined,
    l_attempt_failed: x64.Label = undefined,
    l_word_table: x64.Label = undefined,
    prefilter_label: ?x64.Label = null,
    prefilter: *const compiler.Prefilter,

    const Error = std.mem.Allocator.Error;

    fn emitBlob(self: *Gen, bytes: []const u8) Error!x64.Label {
        std.debug.assert(bytes.len <= 32);
        for (self.bits_cache.items) |c| {
            if (c.len == bytes.len and std.mem.eql(u8, c.bytes[0..c.len], bytes)) return c.label;
        }
        const l = try self.a.label();
        var padded: [32]u8 = @splat(0);
        @memcpy(padded[0..bytes.len], bytes);
        try self.blobs.append(self.gpa, .{ .label = l, .bytes = padded, .len = @intCast(bytes.len) });
        try self.bits_cache.append(self.gpa, .{ .bytes = padded, .len = @intCast(bytes.len), .label = l });
        return l;
    }

    /// Consume a run of accepted ASCII bytes sixteen at a time.
    ///
    /// For each range the vector `(lo > v) | (v > hi)` marks the bytes
    /// outside it; ANDing those across ranges marks bytes outside the whole
    /// set, and the first such byte ends the run. The comparison is signed,
    /// so any byte >= 0x80 reads as negative, falls outside every ASCII
    /// range, and correctly stops the scan — the scalar loop that follows
    /// then handles it. Exact for ASCII-only children, so the scalar loop
    /// only ever finishes the sub-16-byte tail.
    fn emitSimdRun(self: *Gen, set: AsciiSet) Error!void {
        // AVX2 doubles the block and, being three-operand, drops the register
        // copies the SSE2 form needs before each compare.
        if (cpu.hasAvx2()) return self.emitSimdRunAvx2(set);
        return self.emitSimdRunSse2(set);
    }

    fn emitSimdRunAvx2(self: *Gen, set: AsciiSet) Error!void {
        const a = &self.a;
        var lo_regs: [max_simd_ranges]x64.Xmm = undefined;
        var hi_regs: [max_simd_ranges]x64.Xmm = undefined;
        for (set.ranges[0..set.len], 0..) |r, i| {
            lo_regs[i] = @enumFromInt(first_const_xmm + 2 * i);
            hi_regs[i] = @enumFromInt(first_const_xmm + 1 + 2 * i);
            const lo: [32]u8 = @splat(@intCast(r.lo));
            const hi: [32]u8 = @splat(@intCast(r.hi));
            a.vmovdquYmmLabel(lo_regs[i], try self.emitBlob(&lo));
            a.vmovdquYmmLabel(hi_regs[i], try self.emitBlob(&hi));
        }
        const l_loop = try a.here();
        const l_done = try a.label();
        const l_partial = try a.label();
        a.movRegReg(.rax, r_len);
        a.subRegReg(.rax, r_pos);
        a.cmpRegImm(.rax, 32);
        a.jcc(.b, l_done);
        a.vmovdquYmmMem(.xmm0, inputAt(r_pos, 0));
        for (0..set.len) |i| {
            const acc: x64.Xmm = if (i == 0) .xmm1 else .xmm2;
            a.vpcmpgtbYmm(acc, lo_regs[i], .xmm0); // lo > v
            a.vpcmpgtbYmm(.xmm3, .xmm0, hi_regs[i]); // v > hi
            a.vporYmm(acc, acc, .xmm3); // outside this range
            if (i != 0) a.vpandYmm(.xmm1, .xmm1, .xmm2);
        }
        a.vpmovmskbRegYmm(.rax, .xmm1);
        a.testRegReg(.rax, .rax);
        a.jcc(.ne, l_partial);
        a.addRegImm(r_pos, 32);
        a.jmp(l_loop);
        a.place(l_partial);
        a.bsfRegReg(.rax, .rax);
        a.addRegReg(r_pos, .rax);
        a.place(l_done);
        // Leave no dirty upper state for the scalar code and helpers that
        // follow, which would otherwise pay an AVX-to-SSE transition penalty.
        a.vzeroupper();
    }

    fn emitSimdRunSse2(self: *Gen, set: AsciiSet) Error!void {
        const a = &self.a;
        var lo_regs: [max_simd_ranges]x64.Xmm = undefined;
        var hi_regs: [max_simd_ranges]x64.Xmm = undefined;
        for (set.ranges[0..set.len], 0..) |r, i| {
            lo_regs[i] = @enumFromInt(first_const_xmm + 2 * i);
            hi_regs[i] = @enumFromInt(first_const_xmm + 1 + 2 * i);
            const lo: [16]u8 = @splat(@intCast(r.lo));
            const hi: [16]u8 = @splat(@intCast(r.hi));
            a.movdquXmmLabel(lo_regs[i], try self.emitBlob(&lo));
            a.movdquXmmLabel(hi_regs[i], try self.emitBlob(&hi));
        }
        const l_loop = try a.here();
        const l_done = try a.label();
        const l_partial = try a.label();
        // Sixteen bytes left to read?
        a.movRegReg(.rax, r_len);
        a.subRegReg(.rax, r_pos);
        a.cmpRegImm(.rax, 16);
        a.jcc(.b, l_done);
        a.movdquXmmMem(.xmm0, inputAt(r_pos, 0));
        for (0..set.len) |i| {
            a.movdqaXmmXmm(.xmm2, lo_regs[i]);
            a.pcmpgtbXmmXmm(.xmm2, .xmm0); // lo > v
            a.movdqaXmmXmm(.xmm3, .xmm0);
            a.pcmpgtbXmmXmm(.xmm3, hi_regs[i]); // v > hi
            a.porXmmXmm(.xmm2, .xmm3); // outside this range
            if (i == 0) a.movdqaXmmXmm(.xmm1, .xmm2) else a.pandXmmXmm(.xmm1, .xmm2);
        }
        a.pmovmskbRegXmm(.rax, .xmm1);
        a.testRegReg(.rax, .rax);
        a.jcc(.ne, l_partial);
        a.addRegImm(r_pos, 16);
        a.jmp(l_loop);
        a.place(l_partial);
        a.bsfRegReg(.rax, .rax); // first byte outside the set
        a.addRegReg(r_pos, .rax);
        a.place(l_done);
    }

    /// 128-bit acceptance table for codepoints 0..127.
    fn classBits(self: *Gen, cl: compiler.ClassOp) [16]u8 {
        var bits: [16]u8 = @splat(0);
        const ranges = self.prog.ranges[cl.start..][0..cl.len];
        for (0..128) |cp| {
            if (common.classMatches(ranges, cl.negated, cl.ci, @intCast(cp)))
                bits[cp / 8] |= @as(u8, 1) << @intCast(cp % 8);
        }
        return bits;
    }

    fn call(self: *Gen, func: anytype) void {
        self.a.movRegImm64(.r11, @intFromPtr(func));
        self.a.callReg(.r11);
    }

    /// Test the consuming instruction at `pc` against the codepoint at r_pos.
    /// On failure jumps to `on_fail`; on success, if `advance`, r_pos moves
    /// past the codepoint. Clobbers rax/rcx/rsi/rdi/rdx/r11.
    fn emitTest(self: *Gen, pc: u32, on_fail: x64.Label, advance: bool) Error!void {
        const a = &self.a;
        const inst = self.prog.insts[pc];
        a.cmpRegReg(r_pos, r_len);
        a.jcc(.ae, on_fail);

        const l_done = try a.label();
        const ascii_only = asciiOnly(self.prog, inst);

        switch (inst) {
            .char => |c| {
                if (c.cp < 0x80) {
                    const lo: u8 = @intCast(common.foldLower(c.cp));
                    const folds = c.ci and ((c.cp >= 'a' and c.cp <= 'z') or (c.cp >= 'A' and c.cp <= 'Z'));
                    if (!folds) {
                        a.cmpMem8Imm(inputAt(r_pos, 0), @intCast(c.cp));
                        a.jcc(.ne, on_fail);
                    } else {
                        a.movzxRegMem8(.rax, inputAt(r_pos, 0));
                        const l_ok = try a.label();
                        a.cmpReg8Imm(.rax, lo);
                        a.jcc(.e, l_ok);
                        a.cmpReg8Imm(.rax, lo - 32); // upper case
                        a.jcc(.ne, on_fail);
                        a.place(l_ok);
                    }
                    if (advance) a.incReg(r_pos);
                    a.place(l_done);
                    return;
                }
                // Non-ASCII literal: always the helper.
                try self.emitHelperTest(pc, on_fail, advance);
                a.place(l_done);
                return;
            },
            .class => |cl| {
                const l_high = try a.label();
                a.movzxRegMem8(.rax, inputAt(r_pos, 0));
                a.cmpReg8Imm(.rax, 0x80);
                a.jcc(.ae, l_high);
                const bits = try self.emitBlob(&self.classBits(cl));
                a.btLabelReg(bits, .rax);
                a.jcc(.ae, on_fail); // CF clear == bit not set
                if (advance) a.incReg(r_pos);
                a.jmp(l_done);
                a.place(l_high);
                if (ascii_only) {
                    a.jmp(on_fail);
                } else {
                    try self.emitHelperTest(pc, on_fail, advance);
                }
                a.place(l_done);
                return;
            },
            .any, .any_not_nl => {
                const l_high = try a.label();
                a.movzxRegMem8(.rax, inputAt(r_pos, 0));
                a.cmpReg8Imm(.rax, 0x80);
                a.jcc(.ae, l_high);
                if (inst == .any_not_nl) {
                    a.cmpReg8Imm(.rax, '\n');
                    a.jcc(.e, on_fail);
                }
                if (advance) a.incReg(r_pos);
                a.jmp(l_done);
                a.place(l_high);
                // Non-ASCII is never '\n', so both forms just consume it.
                if (advance) {
                    a.movRegReg(arg0, r_ctx);
                    a.movRegReg(arg1, r_pos);
                    self.call(&helperCpLen);
                    a.addRegReg(r_pos, .rax);
                }
                a.place(l_done);
                return;
            },
            else => unreachable,
        }
    }

    /// The generic path: call `helperTest` and advance by what it consumed.
    fn emitHelperTest(self: *Gen, pc: u32, on_fail: x64.Label, advance: bool) Error!void {
        const a = &self.a;
        a.movRegReg(arg0, r_ctx);
        a.movRegImm64(arg1, pc);
        a.movRegReg(arg2, r_pos);
        self.call(&helperTest);
        a.testRegReg(.rax, .rax);
        a.jcc(.e, on_fail);
        if (advance) {
            a.decReg(.rax); // length + 1 -> length
            a.addRegReg(r_pos, .rax);
        }
    }

    /// Push a backtrack frame resuming at `resume_label`; `aux` may be null.
    fn emitPushFrame(self: *Gen, resume_label: x64.Label, pos_reg: Reg, aux: ?Reg) void {
        const a = &self.a;
        // Speculative work is metered here as well as on the failure path:
        // a pattern can push frames indefinitely without ever backtracking,
        // and the budget has to bound that too.
        a.movRegMem(.rax, ctxMem(ctx_budget));
        a.decReg(.rax);
        a.movMemReg(ctxMem(ctx_budget), .rax);
        a.jcc(.s, self.l_bail);
        a.leaRegMem(.rax, .{ .base = r_stack, .disp = frame_size });
        a.cmpRegMem(.rax, ctxMem(ctx_stack_end));
        a.jcc(.a, self.l_bail);
        // `aux` is stored first: callers pass it in rcx, which the resume
        // address and undo length below both use as scratch.
        if (aux) |r| a.movMemReg(.{ .base = r_stack, .disp = frame_aux }, r);
        a.leaLabel(.rcx, resume_label);
        a.movMemReg(.{ .base = r_stack, .disp = frame_resume }, .rcx);
        a.movMemReg(.{ .base = r_stack, .disp = frame_pos }, pos_reg);
        a.movRegMem(.rcx, ctxMem(ctx_undo_len));
        a.movMemReg(.{ .base = r_stack, .disp = frame_undo }, .rcx);
        a.movRegReg(r_stack, .rax);
    }

    /// Record a slot write so backtracking can undo it, then perform it.
    fn emitSlotWrite(self: *Gen, slot: u16) void {
        const a = &self.a;
        a.movRegMem(.rax, ctxMem(ctx_undo_len));
        a.cmpRegMem(.rax, ctxMem(ctx_undo_cap));
        a.jcc(.ae, self.l_bail);
        a.movRegMem(.rcx, ctxMem(ctx_undo_slots));
        a.movMemImm32(.{ .base = .rcx, .index = .rax, .scale = 3 }, slot);
        a.movRegMem(.rdx, .{ .base = r_slots, .disp = @as(i32, slot) * 8 });
        a.movRegMem(.rcx, ctxMem(ctx_undo_vals));
        a.movMemReg(.{ .base = .rcx, .index = .rax, .scale = 3 }, .rdx);
        a.incReg(.rax);
        a.movMemReg(ctxMem(ctx_undo_len), .rax);
        a.movMemReg(.{ .base = r_slots, .disp = @as(i32, slot) * 8 }, r_pos);
    }

    /// prev/next word-character flags for `\b`, in rax and rdx.
    fn emitWordFlags(self: *Gen) Error!void {
        const a = &self.a;
        const l_p_done = try a.label();
        const l_n_done = try a.label();
        a.xorRegReg(.rax, .rax);
        a.testRegReg(r_pos, r_pos);
        a.jcc(.e, l_p_done);
        a.movzxRegMem8(.rcx, inputAt(r_pos, -1));
        a.cmpReg8Imm(.rcx, 0x80);
        a.jcc(.ae, l_p_done); // non-ASCII is never a word char
        a.btLabelReg(self.l_word_table, .rcx);
        a.jcc(.ae, l_p_done);
        a.movRegImm64(.rax, 1);
        a.place(l_p_done);

        a.xorRegReg(.rdx, .rdx);
        a.cmpRegReg(r_pos, r_len);
        a.jcc(.ae, l_n_done);
        a.movzxRegMem8(.rcx, inputAt(r_pos, 0));
        a.cmpReg8Imm(.rcx, 0x80);
        a.jcc(.ae, l_n_done);
        a.btLabelReg(self.l_word_table, .rcx);
        a.jcc(.ae, l_n_done);
        a.movRegImm64(.rdx, 1);
        a.place(l_n_done);
    }

    /// Move r_pos back over the preceding codepoint.
    fn emitStepBack(self: *Gen) Error!void {
        const a = &self.a;
        const l_one = try a.label();
        const l_done = try a.label();
        a.movzxRegMem8(.rax, inputAt(r_pos, -1));
        a.cmpReg8Imm(.rax, 0x80);
        a.jcc(.b, l_one);
        a.movRegReg(arg0, r_ctx);
        a.movRegReg(arg1, r_pos);
        self.call(&helperCpLenBefore);
        a.subRegReg(r_pos, .rax);
        a.jmp(l_done);
        a.place(l_one);
        a.decReg(r_pos);
        a.place(l_done);
    }

    /// Lookaround over a single-codepoint sub-program, inlined.
    fn emitLook(self: *Gen, l: compiler.LookOp) Error!void {
        const a = &self.a;
        const child_pc = l.target;
        switch (l.kind) {
            .ahead_pos => try self.emitTest(child_pc, self.l_fail, false),
            .ahead_neg => {
                const l_ok = try a.label();
                try self.emitTest(child_pc, l_ok, false);
                a.jmp(self.l_fail); // the sub-program matched, so this fails
                a.place(l_ok);
            },
            .behind_pos, .behind_neg => {
                const positive = l.kind == .behind_pos;
                const l_nomatch = try a.label();
                const l_restore_fail = try a.label();
                const l_done = try a.label();
                a.testRegReg(r_pos, r_pos);
                a.jcc(.e, l_nomatch); // nothing precedes the start of input
                a.movMemReg(ctxMem(ctx_scratch2), r_pos);
                try self.emitStepBack();
                try self.emitTest(child_pc, l_restore_fail, false);
                a.movRegMem(r_pos, ctxMem(ctx_scratch2));
                if (positive) a.jmp(l_done) else a.jmp(self.l_fail);
                a.place(l_restore_fail);
                a.movRegMem(r_pos, ctxMem(ctx_scratch2));
                a.place(l_nomatch);
                if (positive) a.jmp(self.l_fail);
                a.place(l_done);
            },
        }
    }

    /// Emit `count` mandatory iterations of a repeat's child, peeling when
    /// there are few and looping on a counter when there are many.
    fn emitMandatory(self: *Gen, child_pc: u32, count: u32, on_fail: x64.Label) Error!void {
        const a = &self.a;
        const max_peel = 8;
        if (count <= max_peel) {
            var i: u32 = 0;
            while (i < count) : (i += 1) try self.emitTest(child_pc, on_fail, true);
            return;
        }
        a.movMemImm32(ctxMem(ctx_scratch1), @intCast(count));
        const l_loop = try a.here();
        const l_done = try a.label();
        a.movRegMem(.rax, ctxMem(ctx_scratch1));
        a.testRegReg(.rax, .rax);
        a.jcc(.e, l_done);
        try self.emitTest(child_pc, on_fail, true);
        a.movRegMem(.rax, ctxMem(ctx_scratch1));
        a.decReg(.rax);
        a.movMemReg(ctxMem(ctx_scratch1), .rax);
        a.jmp(l_loop);
        a.place(l_done);
    }

    /// Fused repeat: consume in a tight loop, then leave one frame that stands
    /// for every retry, exactly as the interpreter's rep frames do.
    fn emitRep(self: *Gen, pc: u32, r: compiler.RepOp) Error!void {
        const a = &self.a;
        const child_pc = pc + 1;
        const cont = self.pc_labels[pc + 2];
        const max_peel = 8;

        try self.emitMandatory(child_pc, r.min, self.l_fail);

        if (!r.greedy) {
            if (r.max <= r.min) {
                a.jmp(cont);
                return;
            }
            const retry = try a.label();
            const remaining: u64 = if (r.max == compiler.RepOp.unbounded)
                std.math.maxInt(u64)
            else
                r.max - r.min;
            a.movRegImm64(.rcx, remaining);
            self.emitPushFrame(retry, r_pos, .rcx);
            a.jmp(cont);

            a.place(retry);
            const l_pop_fail = try a.label();
            const aux: Mem = .{ .base = r_stack, .disp = -frame_size + frame_aux };
            a.movRegMem(.rcx, aux);
            a.testRegReg(.rcx, .rcx);
            a.jcc(.e, l_pop_fail);
            try self.emitTest(child_pc, l_pop_fail, true);
            a.movRegMem(.rcx, aux);
            a.decReg(.rcx);
            a.movMemReg(aux, .rcx);
            a.movMemReg(.{ .base = r_stack, .disp = -frame_size + frame_pos }, r_pos);
            a.jmp(cont);
            a.place(l_pop_fail);
            a.subRegImm(r_stack, frame_size);
            a.jmp(self.l_fail);
            return;
        }

        // Greedy: the position after exactly `min` items is the retry floor.
        a.movMemReg(ctxMem(ctx_scratch0), r_pos);
        const l_loop_done = try a.label();
        if (r.max == compiler.RepOp.unbounded) {
            // No iteration count to maintain here, so the run can be scanned
            // in bulk; the scalar loop then finishes the tail.
            if (runtime.asciiRunSet(self.prog, self.prog.insts[child_pc])) |set| {
                try self.emitSimdRun(set);
            }
            const l_loop = try a.here();
            try self.emitTest(child_pc, l_loop_done, true);
            a.jmp(l_loop);
        } else {
            const remaining = r.max - r.min;
            if (remaining <= max_peel) {
                var i: u32 = 0;
                while (i < remaining) : (i += 1) try self.emitTest(child_pc, l_loop_done, true);
            } else {
                a.movMemImm32(ctxMem(ctx_scratch1), @intCast(remaining));
                const l_loop = try a.here();
                a.movRegMem(.rax, ctxMem(ctx_scratch1));
                a.testRegReg(.rax, .rax);
                a.jcc(.e, l_loop_done);
                try self.emitTest(child_pc, l_loop_done, true);
                a.movRegMem(.rax, ctxMem(ctx_scratch1));
                a.decReg(.rax);
                a.movMemReg(ctxMem(ctx_scratch1), .rax);
                a.jmp(l_loop);
            }
        }
        a.place(l_loop_done);

        if (retryIsFutile(self.prog, pc)) {
            // No shorter run can match, so this repeat leaves no frame at all.
            a.jmp(cont);
            return;
        }

        const l_noframe = try a.label();
        const retry = try a.label();
        a.movRegMem(.rcx, ctxMem(ctx_scratch0));
        a.cmpRegReg(r_pos, .rcx);
        a.jcc(.be, l_noframe);
        self.emitPushFrame(retry, r_pos, .rcx);
        a.place(l_noframe);
        a.jmp(cont);

        // Retry stub: entered from the fail path with r_pos already restored
        // from this frame and the undo log unwound.
        a.place(retry);
        const l_pop_fail = try a.label();
        const floor: Mem = .{ .base = r_stack, .disp = -frame_size + frame_aux };
        const stored_pos: Mem = .{ .base = r_stack, .disp = -frame_size + frame_pos };
        a.movRegMem(.rcx, floor);
        if (retryScanChar(self.prog, pc + 2)) |sc| {
            // Every skipped position would fail at this literal, so jump
            // straight to its occurrences, largest first to keep greedy order.
            const l_scan = try a.here();
            const l_found = try a.label();
            a.cmpRegReg(r_pos, .rcx);
            a.jcc(.be, l_pop_fail);
            a.decReg(r_pos);
            a.cmpMem8Imm(inputAt(r_pos, 0), sc.byte);
            a.jcc(.e, l_found);
            if (sc.ci) {
                const other: u8 = if (sc.byte >= 'a') sc.byte - 32 else sc.byte + 32;
                a.cmpMem8Imm(inputAt(r_pos, 0), other);
                a.jcc(.e, l_found);
            }
            a.jmp(l_scan);
            a.place(l_found);
        } else {
            a.cmpRegReg(r_pos, .rcx);
            a.jcc(.be, l_pop_fail);
            try self.emitStepBack();
        }
        a.movMemReg(stored_pos, r_pos);
        a.jmp(cont);
        a.place(l_pop_fail);
        a.subRegImm(r_stack, frame_size);
        a.jmp(self.l_fail);
    }

    fn emitAssert(self: *Gen, kind: common.Assertion) Error!void {
        const a = &self.a;
        switch (kind) {
            .begin_text => {
                a.testRegReg(r_pos, r_pos);
                a.jcc(.ne, self.l_fail);
            },
            .end_text => {
                a.cmpRegReg(r_pos, r_len);
                a.jcc(.ne, self.l_fail);
            },
            .begin_line => {
                const l_ok = try a.label();
                a.testRegReg(r_pos, r_pos);
                a.jcc(.e, l_ok);
                a.cmpMem8Imm(inputAt(r_pos, -1), '\n');
                a.jcc(.ne, self.l_fail);
                a.place(l_ok);
            },
            .end_line => {
                const l_ok = try a.label();
                a.cmpRegReg(r_pos, r_len);
                a.jcc(.e, l_ok);
                a.cmpMem8Imm(inputAt(r_pos, 0), '\n');
                a.jcc(.ne, self.l_fail);
                a.place(l_ok);
            },
            .word_boundary, .not_word_boundary => {
                try self.emitWordFlags();
                a.cmpRegReg(.rax, .rdx);
                a.jcc(if (kind == .word_boundary) .e else .ne, self.l_fail);
            },
        }
    }
};

/// A literal the continuation of a greedy repeat must match next, letting
/// retries jump between its occurrences (the JIT's form of the interpreter's
/// required-literal scanning).
/// The widest run scanner this program will emit, in ranges: that decides how
/// many vector registers the code touches, and so how many Windows expects it
/// to hand back unchanged.
fn maxSimdRanges(prog: compiler.Program) usize {
    var most: usize = 0;
    for (prog.insts, 0..) |inst, pc| {
        if (inst != .rep) continue;
        const r = inst.rep;
        if (!r.greedy or r.max != compiler.RepOp.unbounded) continue;
        if (runtime.asciiRunSet(prog, prog.insts[pc + 1])) |set| most = @max(most, set.len);
    }
    if (runtime.leadSkipChild(prog)) |child_pc| {
        if (runtime.asciiRunSet(prog, prog.insts[child_pc])) |set| most = @max(most, set.len);
    }
    return most;
}

pub fn compile(
    gpa: std.mem.Allocator,
    prog: compiler.Program,
    prefilter: *const compiler.Prefilter,
    code_buf: []u8,
) std.mem.Allocator.Error!?u32 {
    if (!Support.canCompile(prog)) return null;

    var g = Gen{
        .a = x64.Asm.init(gpa, code_buf),
        .prog = prog,
        .gpa = gpa,
        .pc_labels = try gpa.alloc(x64.Label, prog.insts.len),
        .dead = try gpa.alloc(bool, prog.insts.len),
        .prefilter = prefilter,
    };
    defer gpa.free(g.pc_labels);
    defer gpa.free(g.dead);
    defer g.blobs.deinit(gpa);
    defer g.bits_cache.deinit(gpa);
    defer g.a.deinit();

    const a = &g.a;
    for (g.pc_labels) |*l| l.* = try a.label();
    @memset(g.dead, false);
    // Lookaround sub-programs are reached only through the `look` instruction,
    // which is inlined, so their instructions never need code.
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
    g.l_word_table = try a.label();

    // -- prologue -----------------------------------------------------------
    // Range constants occupy xmm(first_const_xmm) upward; on Windows anything
    // from xmm6 up must come back unchanged, so it is saved here.
    const ranges_used = maxSimdRanges(prog);
    const highest_xmm: usize = if (ranges_used == 0) 0 else first_const_xmm + 2 * ranges_used - 1;
    const xmm_saves: i32 = if (win_abi and highest_xmm >= first_saved_xmm)
        @intCast(highest_xmm - first_saved_xmm + 1)
    else
        0;
    // Saved above the shadow space, and 16-byte aligned because rsp is.
    const reserve: i32 = stack_reserve + 16 * xmm_saves;

    inline for (saved_regs) |r| a.push(r);
    // The pushes leave rsp 8 past a 16-byte boundary; this realigns it, and on
    // Windows also claims the shadow space every call there requires.
    a.subRegImm(.rsp, reserve);
    {
        var i: i32 = 0;
        while (i < xmm_saves) : (i += 1) {
            const reg: x64.Xmm = @enumFromInt(@as(u4, @intCast(first_saved_xmm + @as(usize, @intCast(i)))));
            a.movdquMemXmm(.{ .base = .rsp, .disp = stack_reserve + 16 * i }, reg);
        }
    }
    a.movRegReg(r_ctx, arg0);
    a.movRegMem(r_input, ctxMem(ctx_input));
    a.movRegMem(r_len, ctxMem(ctx_input_len));
    a.movRegMem(r_pos, ctxMem(ctx_start));
    a.movRegMem(r_slots, ctxMem(ctx_slots));

    // -- one match attempt starting at r_pos --------------------------------
    a.place(g.l_attempt);
    if (prefilter.usable) {
        // Skip positions that cannot begin a match. A usable prefilter implies
        // the pattern cannot match empty, so running off the end means failure.
        const pf_table = try a.label();
        if (prefilter.single) |byte| {
            // One candidate byte: hand the scan to a vectorized search.
            a.movRegReg(arg0, r_ctx);
            a.movRegReg(arg1, r_pos);
            a.movRegImm64(arg2, byte);
            g.call(&helperMemchr);
            a.movRegReg(r_pos, .rax);
            a.cmpRegReg(r_pos, r_len);
            a.jcc(.ae, g.l_no_match);
        } else {
            const l_scan = try a.here();
            const l_ok = try a.label();
            a.cmpRegReg(r_pos, r_len);
            a.jcc(.ae, g.l_no_match);
            a.movzxRegMem8(.rax, inputAt(r_pos, 0));
            a.leaLabel(.rsi, pf_table);
            a.cmpMem8Imm(.{ .base = .rsi, .index = .rax, .scale = 0 }, 0);
            a.jcc(.ne, l_ok);
            if (prefilter.ascii_only) {
                // Every candidate byte is ASCII, so stepping bytes cannot land
                // inside a codepoint.
                a.incReg(r_pos);
            } else {
                const l_one = try a.label();
                const l_stepped = try a.label();
                a.cmpReg8Imm(.rax, 0x80);
                a.jcc(.b, l_one);
                a.movRegReg(arg0, r_ctx);
                a.movRegReg(arg1, r_pos);
                g.call(&helperCpLen);
                a.addRegReg(r_pos, .rax);
                a.jmp(l_stepped);
                a.place(l_one);
                a.incReg(r_pos);
                a.place(l_stepped);
            }
            a.jmp(l_scan);
            a.place(l_ok);
            // The table is data; park it with the other blobs at the end.
            const bytes: [32]u8 = @splat(0);
            try g.blobs.append(gpa, .{ .label = pf_table, .bytes = bytes, .len = 0 });
            g.prefilter_label = pf_table;
        }
    }
    a.movRegMem(r_stack, ctxMem(ctx_stack_base));
    a.movMemImm32(ctxMem(ctx_undo_len), 0);
    a.movMemImm32(ctxMem(ctx_touched), 0);
    a.movMemReg(ctxMem(ctx_match_start), r_pos);
    a.jmp(g.pc_labels[0]);

    // -- instruction bodies -------------------------------------------------
    for (prog.insts, 0..) |inst, pci| {
        const pc: u32 = @intCast(pci);
        a.place(g.pc_labels[pc]);
        if (g.dead[pc]) continue;
        switch (inst) {
            .char, .class, .any, .any_not_nl => try g.emitTest(pc, g.l_fail, true),
            .assert => |k| try g.emitAssert(k),
            .jmp => |t| a.jmp(g.pc_labels[t]),
            .split => |t| {
                const stub = try a.label();
                g.emitPushFrame(stub, r_pos, null);
                a.jmp(g.pc_labels[t[0]]);
                a.place(stub);
                a.subRegImm(r_stack, frame_size);
                a.jmp(g.pc_labels[t[1]]);
            },
            .save, .set_pos => |slot| g.emitSlotWrite(slot),
            .exit_if_same => |guard| {
                // An empty iteration leaves the loop; it does not fail.
                a.cmpRegMem(r_pos, .{ .base = r_slots, .disp = @as(i32, guard.slot) * 8 });
                a.jcc(.e, g.pc_labels[guard.target]);
            },
            .backref => {
                a.movMemImm32(ctxMem(ctx_touched), 1);
                a.movRegReg(arg0, r_ctx);
                a.movRegImm64(arg1, pc);
                a.movRegReg(arg2, r_pos);
                g.call(&helperBackref);
                a.testRegReg(.rax, .rax);
                a.jcc(.e, g.l_fail);
                a.decReg(.rax);
                a.addRegReg(r_pos, .rax);
            },
            .match => {
                a.movMemReg(ctxMem(ctx_match_end), r_pos);
                a.movRegImm64(.rax, 1);
                a.jmp(g.l_epilogue);
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
        a.cmpRegMem(r_stack, ctxMem(ctx_stack_base));
        a.jcc(.a, l_have);
        // Stack empty: unwind every slot write and give up on this attempt.
        a.xorRegReg(.rcx, .rcx);
        a.leaLabel(.rax, g.l_attempt_failed);
        a.jmp(l_unwind);

        a.place(l_have);
        a.movRegMem(.rax, ctxMem(ctx_budget));
        a.decReg(.rax);
        a.movMemReg(ctxMem(ctx_budget), .rax);
        a.jcc(.s, g.l_bail);
        // Peek, rather than pop: the resume stub decides whether its frame is
        // exhausted, which is what lets one frame stand for a whole range of
        // repeat retries.
        a.movRegMem(.rax, .{ .base = r_stack, .disp = -frame_size + frame_resume });
        a.movRegMem(r_pos, .{ .base = r_stack, .disp = -frame_size + frame_pos });
        a.movRegMem(.rcx, .{ .base = r_stack, .disp = -frame_size + frame_undo });

        a.place(l_unwind);
        a.movRegMem(.rdx, ctxMem(ctx_undo_len));
        a.cmpRegReg(.rdx, .rcx);
        a.jcc(.be, l_unwound);
        a.decReg(.rdx);
        a.movMemReg(ctxMem(ctx_undo_len), .rdx);
        a.movRegMem(.rsi, ctxMem(ctx_undo_slots));
        a.movRegMem(.rdi, .{ .base = .rsi, .index = .rdx, .scale = 3 });
        a.movRegMem(.rsi, ctxMem(ctx_undo_vals));
        a.movRegMem(.r8, .{ .base = .rsi, .index = .rdx, .scale = 3 });
        a.movMemReg(.{ .base = r_slots, .index = .rdi, .scale = 3 }, .r8);
        a.jmp(l_unwind);
        a.place(l_unwound);
        a.jmpReg(.rax);
    }

    // -- advance to the next start position ---------------------------------
    a.place(g.l_attempt_failed);
    {
        // Backtracking leaves r_pos wherever the last frame or retry loop put
        // it; the next attempt starts one codepoint past where *this* attempt
        // began, which is the value stashed at ctx.match_start.
        a.movRegMem(r_pos, ctxMem(ctx_match_start));
        a.cmpRegReg(r_pos, r_len);
        a.jcc(.ae, g.l_no_match);
        if (leadSkipChild(prog)) |child_pc| {
            // Sound only when the attempt never read a capture: see
            // `backtrack.run`, which makes the same check dynamically.
            const l_no_skip = try a.label();
            const l_skip_done = try a.label();
            a.cmpMemImm32(ctxMem(ctx_touched), 0);
            a.jcc(.ne, l_no_skip);
            if (runtime.asciiRunSet(prog, prog.insts[child_pc])) |set| {
                try g.emitSimdRun(set);
            }
            const l_loop = try a.here();
            try g.emitTest(child_pc, l_skip_done, true);
            a.jmp(l_loop);
            a.place(l_skip_done);
            a.cmpRegReg(r_pos, r_len);
            a.jcc(.ae, g.l_no_match);
            a.place(l_no_skip);
        }
        const l_one = try a.label();
        a.movzxRegMem8(.rax, inputAt(r_pos, 0));
        a.cmpReg8Imm(.rax, 0x80);
        a.jcc(.b, l_one);
        a.movRegReg(arg0, r_ctx);
        a.movRegReg(arg1, r_pos);
        g.call(&helperCpLen);
        a.addRegReg(r_pos, .rax);
        a.jmp(g.l_attempt);
        a.place(l_one);
        a.incReg(r_pos);
        a.jmp(g.l_attempt);
    }

    // -- exits --------------------------------------------------------------
    a.place(g.l_no_match);
    a.xorRegReg(.rax, .rax);
    a.jmp(g.l_epilogue);

    a.place(g.l_bail);
    a.movRegImm64(.rax, @bitCast(@as(i64, -1)));

    a.place(g.l_epilogue);
    {
        var i: i32 = 0;
        while (i < xmm_saves) : (i += 1) {
            const reg: x64.Xmm = @enumFromInt(@as(u4, @intCast(first_saved_xmm + @as(usize, @intCast(i)))));
            a.movdquXmmMem(reg, .{ .base = .rsp, .disp = stack_reserve + 16 * i });
        }
    }
    a.addRegImm(.rsp, reserve);
    comptime var back = saved_regs.len;
    inline while (back > 0) {
        back -= 1;
        a.pop(saved_regs[back]);
    }
    a.ret();

    // -- data ---------------------------------------------------------------
    // Word-character table for `\b`, then every class bitmap and, if used, the
    // prefilter's byte table.
    a.place(g.l_word_table);
    {
        var bits: [16]u8 = @splat(0);
        for (0..128) |cp| {
            if (common.isWordChar(@intCast(cp))) bits[cp / 8] |= @as(u8, 1) << @intCast(cp % 8);
        }
        a.data(&bits);
    }
    for (g.blobs.items) |blob| {
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
