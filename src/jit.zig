// SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

//! Just-in-time compilation of a program to native code.
//!
//! The JIT implements the same leftmost-greedy backtracking semantics as
//! `backtrack.zig`, so it can run any pattern the interpreter can — but it has
//! no memoization, so it carries a step budget proportional to the input. When
//! the budget, the frame stack, or the undo log runs out it reports `.bail`
//! and the caller re-runs on an interpreter, which is what keeps the library's
//! guarantees intact: a pattern that would blow up here still gets a linear
//! (Pike VM) or polynomial (memoizing backtracker) answer, having spent only a
//! bounded amount of time trying the fast path first.
//!
//! Only x86-64 is implemented. Everywhere else `compile` returns null and the
//! interpreters run as before.
const std = @import("std");
const builtin = @import("builtin");
const compiler = @import("compiler.zig");
const mem = @import("jit/mem.zig");
const codegen = @import("jit/codegen.zig");

pub const available = mem.supported and builtin.cpu.arch == .x86_64;

pub const Result = enum { match, no_match, bail };

/// How much backtracking work the generated code may do per input byte before
/// handing the problem to an interpreter.
pub const budget_per_byte: isize = 64;
pub const budget_floor: isize = 1 << 16;

/// Frames, undo entries, and capture slots the generated code may use. These
/// live on the machine stack so that a search costs no allocation at all;
/// overflowing any of them bails rather than growing, since the interpreters
/// handle those cases with better complexity anyway.
const max_frames = 256;
const max_undo = 256;
const max_slots = 256;

/// Does the program contain a loop the compiler could not fuse into a single
/// repeat instruction?
///
/// This is the property that decides whether native code is worth running.
/// A fused repeat consumes in a straight line and leaves one frame however
/// long the run is, so a program without unfused loops can only push a number
/// of frames bounded by the *pattern*, never by the input — its backtracking
/// is structurally bounded. An unfused loop (`(?:ab|cd)+`, `(\w+|\d+)+x`)
/// pushes a frame per iteration and, when its body is ambiguous, explores
/// exponentially many splits. Those belong on the lazy DFA, which is linear
/// by construction.
///
/// Unfused loops are exactly the backward jumps: `emitStar` is the only thing
/// that emits one, and fusion replaces it.
pub fn backtrackingIsBounded(prog: compiler.Program) bool {
    for (prog.insts, 0..) |inst, pc| {
        switch (inst) {
            .jmp => |t| if (t <= pc) return false,
            .split => |t| if (t[0] <= pc or t[1] <= pc) return false,
            else => {},
        }
    }
    return true;
}

pub const Jit = struct {
    buf: mem.Buffer,
    func: codegen.Fn,
    /// A stable copy of the program: the generated code hands this pointer to
    /// its helpers, so it must not live in a struct the caller might move.
    prog: *compiler.Program,
    gpa: std.mem.Allocator,

    /// Returns null when this build cannot JIT, the program uses something the
    /// generator does not implement, or the code does not fit.
    pub fn compile(
        gpa: std.mem.Allocator,
        prog: compiler.Program,
        prefilter: *const compiler.Prefilter,
    ) std.mem.Allocator.Error!?Jit {
        if (!available) return null;
        if (!codegen.Support.canCompile(prog)) return null;

        const estimate = 8192 + prog.insts.len * 768;
        var buf = mem.Buffer.init(estimate) catch return null;
        errdefer buf.deinit();

        const len = (try codegen.compile(gpa, prog, prefilter, buf.mapping)) orelse {
            buf.deinit();
            return null;
        };
        buf.finalize(len) catch {
            buf.deinit();
            return null;
        };

        const prog_copy = try gpa.create(compiler.Program);
        prog_copy.* = prog;
        return .{
            .buf = buf,
            .func = @ptrCast(buf.code.ptr),
            .prog = prog_copy,
            .gpa = gpa,
        };
    }

    /// Debug aid: the generated machine code.
    pub fn codeBytes(self: *const Jit) []const u8 {
        return self.buf.code;
    }

    pub fn deinit(self: *Jit) void {
        self.gpa.destroy(self.prog);
        self.buf.deinit();
        self.* = undefined;
    }

    /// Unanchored search from `start`. On `.match`, `slots_out` holds the
    /// capture spans (group 0 included) exactly as the interpreters report
    /// them. On `.bail` nothing is written and the caller must fall back.
    pub fn run(
        self: *const Jit,
        input: []const u8,
        start: usize,
        slots_out: []?usize,
    ) Result {
        if (slots_out.len > max_slots) return .bail;
        var slots: [max_slots]usize = undefined;
        for (0..slots_out.len) |i| slots[i] = codegen.unset;
        var undo_slots: [max_undo]usize = undefined;
        var undo_vals: [max_undo]usize = undefined;
        var stack: [max_frames * 32]u8 align(@alignOf(usize)) = undefined;
        const stack_base: [*]u8 = &stack;

        var ctx = codegen.Ctx{
            .input = input.ptr,
            .input_len = input.len,
            .start = start,
            .slots = &slots,
            .stack_base = stack_base,
            .stack_end = @intFromPtr(stack_base) + stack.len,
            .undo_slots = &undo_slots,
            .undo_vals = &undo_vals,
            .undo_len = 0,
            .undo_cap = max_undo,
            .budget = @max(budget_floor, budget_per_byte * @as(isize, @intCast(input.len + 1))),
            .match_start = 0,
            .match_end = 0,
            .touched_backref = 0,
            .prog = self.prog,
            .scratch0 = 0,
            .scratch1 = 0,
            .scratch2 = 0,
        };

        const status = self.func(&ctx);
        return switch (status) {
            1 => blk: {
                for (slots_out, 0..) |*s, i| {
                    s.* = if (slots[i] == codegen.unset) null else slots[i];
                }
                // Group 0 has no save instructions; the code reports it here.
                slots_out[0] = ctx.match_start;
                slots_out[1] = ctx.match_end;
                break :blk .match;
            },
            0 => .no_match,
            else => .bail,
        };
    }
};
