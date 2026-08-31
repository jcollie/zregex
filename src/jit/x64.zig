// SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

//! A small x86-64 instruction encoder: only what the regex code generator
//! emits, System V calling convention, 64-bit operands unless a helper says
//! otherwise.
//!
//! Jump targets are `Label`s, which may be referenced before they are placed;
//! `finish` resolves the recorded fixups. Every emit is bounds-checked against
//! the output buffer and sets `overflow` rather than trapping, so a
//! mis-estimated code size degrades to "do not JIT this pattern".
const std = @import("std");

pub const Reg = enum(u4) {
    rax = 0,
    rcx = 1,
    rdx = 2,
    rbx = 3,
    rsp = 4,
    rbp = 5,
    rsi = 6,
    rdi = 7,
    r8 = 8,
    r9 = 9,
    r10 = 10,
    r11 = 11,
    r12 = 12,
    r13 = 13,
    r14 = 14,
    r15 = 15,

    fn low(self: Reg) u3 {
        return @truncate(@intFromEnum(self));
    }
    fn ext(self: Reg) u1 {
        return @truncate(@intFromEnum(self) >> 3);
    }
};

/// `[base + index*scale + disp]`; `scale` is the shift amount (0, 1, 2, 3).
pub const Mem = struct {
    base: Reg,
    index: ?Reg = null,
    scale: u2 = 0,
    disp: i32 = 0,
};

pub const Cond = enum(u4) {
    o = 0x0,
    no = 0x1,
    b = 0x2, // unsigned <
    ae = 0x3, // unsigned >=
    e = 0x4,
    ne = 0x5,
    be = 0x6, // unsigned <=
    a = 0x7, // unsigned >
    s = 0x8,
    ns = 0x9,
    l = 0xC, // signed <
    ge = 0xD,
    le = 0xE,
    g = 0xF,
};

/// SSE registers. Only the 128-bit integer subset of SSE2 is used, which is
/// baseline on x86-64 — no runtime feature detection is needed.
pub const Xmm = enum(u4) {
    xmm0 = 0,
    xmm1 = 1,
    xmm2 = 2,
    xmm3 = 3,
    xmm4 = 4,
    xmm5 = 5,
    xmm6 = 6,
    xmm7 = 7,
    xmm8 = 8,
    xmm9 = 9,
    xmm10 = 10,
    xmm11 = 11,
    xmm12 = 12,
    xmm13 = 13,
    xmm14 = 14,
    xmm15 = 15,

    fn low(self: Xmm) u3 {
        return @truncate(@intFromEnum(self));
    }
    fn ext(self: Xmm) u1 {
        return @truncate(@intFromEnum(self) >> 3);
    }
};

pub const Label = u32;

const Fixup = struct {
    /// Offset of the rel32 field.
    at: u32,
    label: Label,
};

pub const Asm = struct {
    buf: []u8,
    len: u32 = 0,
    overflow: bool = false,
    labels: std.ArrayList(?u32) = .empty,
    fixups: std.ArrayList(Fixup) = .empty,
    gpa: std.mem.Allocator,

    pub fn init(gpa: std.mem.Allocator, buf: []u8) Asm {
        return .{ .buf = buf, .gpa = gpa };
    }

    pub fn deinit(self: *Asm) void {
        self.labels.deinit(self.gpa);
        self.fixups.deinit(self.gpa);
        self.* = undefined;
    }

    // -- raw output ---------------------------------------------------------

    fn b(self: *Asm, x: u8) void {
        if (self.len >= self.buf.len) {
            self.overflow = true;
            return;
        }
        self.buf[self.len] = x;
        self.len += 1;
    }

    fn d32(self: *Asm, x: u32) void {
        self.b(@truncate(x));
        self.b(@truncate(x >> 8));
        self.b(@truncate(x >> 16));
        self.b(@truncate(x >> 24));
    }

    fn q64(self: *Asm, x: u64) void {
        self.d32(@truncate(x));
        self.d32(@truncate(x >> 32));
    }

    /// REX prefix; emitted whenever any bit is needed (W for 64-bit operands).
    fn rex(self: *Asm, w: u1, r: u1, x: u1, bb: u1) void {
        if (w == 0 and r == 0 and x == 0 and bb == 0) return;
        self.b(0x40 | (@as(u8, w) << 3) | (@as(u8, r) << 2) | (@as(u8, x) << 1) | bb);
    }

    fn modrm(self: *Asm, mod: u2, reg: u3, rm: u3) void {
        self.b((@as(u8, mod) << 6) | (@as(u8, reg) << 3) | rm);
    }

    fn sib(self: *Asm, scale: u2, index: u3, base: u3) void {
        self.b((@as(u8, scale) << 6) | (@as(u8, index) << 3) | base);
    }

    /// REX bits implied by a memory operand.
    fn memRexBits(m: Mem) struct { x: u1, b: u1 } {
        return .{ .x = if (m.index) |i| i.ext() else 0, .b = m.base.ext() };
    }

    /// ModRM (+SIB, +displacement) for `reg, [mem]`.
    fn emitMem(self: *Asm, reg: u3, m: Mem) void {
        const base_low = m.base.low();
        // rsp/r12 as base always needs SIB; rbp/r13 as base always needs a
        // displacement (mod 00 with rm 101 means rip-relative).
        const need_sib = m.index != null or base_low == 4;
        const force_disp = base_low == 5 and m.disp == 0;
        const mod: u2 = if (m.disp == 0 and !force_disp)
            0
        else if (m.disp >= -128 and m.disp <= 127)
            1
        else
            2;
        if (need_sib) {
            self.modrm(mod, reg, 4);
            const idx: u3 = if (m.index) |i| i.low() else 4; // 4 == no index
            self.sib(m.scale, idx, base_low);
        } else {
            self.modrm(mod, reg, base_low);
        }
        switch (mod) {
            0 => {},
            1 => self.b(@bitCast(@as(i8, @intCast(m.disp)))),
            2 => self.d32(@bitCast(m.disp)),
            else => unreachable,
        }
    }

    // -- labels -------------------------------------------------------------

    pub fn label(self: *Asm) std.mem.Allocator.Error!Label {
        try self.labels.append(self.gpa, null);
        return @intCast(self.labels.items.len - 1);
    }

    pub fn place(self: *Asm, l: Label) void {
        self.labels.items[l] = self.len;
    }

    /// Define a label at the current position in one step.
    pub fn here(self: *Asm) std.mem.Allocator.Error!Label {
        const l = try self.label();
        self.place(l);
        return l;
    }

    fn fixup(self: *Asm, l: Label) void {
        self.fixups.append(self.gpa, .{ .at = self.len, .label = l }) catch {
            self.overflow = true;
        };
        self.d32(0);
    }

    /// Resolve every jump; returns the code length.
    pub fn finish(self: *Asm) error{ Overflow, UnplacedLabel }!u32 {
        if (self.overflow) return error.Overflow;
        for (self.fixups.items) |f| {
            const target = self.labels.items[f.label] orelse return error.UnplacedLabel;
            const next: i64 = @as(i64, f.at) + 4;
            const rel: i64 = @as(i64, target) - next;
            std.mem.writeInt(i32, self.buf[f.at..][0..4], @intCast(rel), .little);
        }
        return self.len;
    }

    /// Current offset, for computing sizes.
    pub fn offset(self: *const Asm) u32 {
        return self.len;
    }

    // -- instructions -------------------------------------------------------

    pub fn movRegImm64(self: *Asm, dst: Reg, imm: u64) void {
        if (imm <= std.math.maxInt(u32)) {
            // 32-bit moves zero-extend, so this is both shorter and equivalent.
            self.rex(0, 0, 0, dst.ext());
            self.b(0xB8 + @as(u8, dst.low()));
            self.d32(@truncate(imm));
            return;
        }
        self.rex(1, 0, 0, dst.ext());
        self.b(0xB8 + @as(u8, dst.low()));
        self.q64(imm);
    }

    pub fn movRegReg(self: *Asm, dst: Reg, src: Reg) void {
        self.rex(1, src.ext(), 0, dst.ext());
        self.b(0x89);
        self.modrm(3, src.low(), dst.low());
    }

    /// `mov dst, [mem]` (64-bit).
    pub fn movRegMem(self: *Asm, dst: Reg, m: Mem) void {
        const rb = memRexBits(m);
        self.rex(1, dst.ext(), rb.x, rb.b);
        self.b(0x8B);
        self.emitMem(dst.low(), m);
    }

    /// `mov [mem], src` (64-bit).
    pub fn movMemReg(self: *Asm, m: Mem, src: Reg) void {
        const rb = memRexBits(m);
        self.rex(1, src.ext(), rb.x, rb.b);
        self.b(0x89);
        self.emitMem(src.low(), m);
    }

    /// `cmp qword [mem], imm32` (sign-extended).
    pub fn cmpMemImm32(self: *Asm, m: Mem, imm: i32) void {
        const rb = memRexBits(m);
        self.rex(1, 0, rb.x, rb.b);
        if (imm >= -128 and imm <= 127) {
            self.b(0x83);
            self.emitMem(7, m);
            self.b(@bitCast(@as(i8, @intCast(imm))));
        } else {
            self.b(0x81);
            self.emitMem(7, m);
            self.d32(@bitCast(imm));
        }
    }

    /// `mov qword [mem], imm32` (sign-extended).
    pub fn movMemImm32(self: *Asm, m: Mem, imm: i32) void {
        const rb = memRexBits(m);
        self.rex(1, 0, rb.x, rb.b);
        self.b(0xC7);
        self.emitMem(0, m);
        self.d32(@bitCast(imm));
    }

    /// `movzx dst, byte [mem]` (zero-extend to 64-bit).
    pub fn movzxRegMem8(self: *Asm, dst: Reg, m: Mem) void {
        const rb = memRexBits(m);
        self.rex(1, dst.ext(), rb.x, rb.b);
        self.b(0x0F);
        self.b(0xB6);
        self.emitMem(dst.low(), m);
    }

    /// `mov byte [mem], imm8`.
    pub fn movMem8Imm(self: *Asm, m: Mem, imm: u8) void {
        const rb = memRexBits(m);
        self.rex(0, 0, rb.x, rb.b);
        self.b(0xC6);
        self.emitMem(0, m);
        self.b(imm);
    }

    pub fn leaRegMem(self: *Asm, dst: Reg, m: Mem) void {
        const rb = memRexBits(m);
        self.rex(1, dst.ext(), rb.x, rb.b);
        self.b(0x8D);
        self.emitMem(dst.low(), m);
    }

    fn aluRegImm(self: *Asm, op: u3, dst: Reg, imm: i32) void {
        self.rex(1, 0, 0, dst.ext());
        if (imm >= -128 and imm <= 127) {
            self.b(0x83);
            self.modrm(3, op, dst.low());
            self.b(@bitCast(@as(i8, @intCast(imm))));
        } else {
            self.b(0x81);
            self.modrm(3, op, dst.low());
            self.d32(@bitCast(imm));
        }
    }

    pub fn addRegImm(self: *Asm, dst: Reg, imm: i32) void {
        self.aluRegImm(0, dst, imm);
    }
    pub fn subRegImm(self: *Asm, dst: Reg, imm: i32) void {
        self.aluRegImm(5, dst, imm);
    }
    pub fn cmpRegImm(self: *Asm, dst: Reg, imm: i32) void {
        self.aluRegImm(7, dst, imm);
    }
    pub fn andRegImm(self: *Asm, dst: Reg, imm: i32) void {
        self.aluRegImm(4, dst, imm);
    }

    fn aluRegReg(self: *Asm, opcode: u8, dst: Reg, src: Reg) void {
        self.rex(1, src.ext(), 0, dst.ext());
        self.b(opcode);
        self.modrm(3, src.low(), dst.low());
    }

    pub fn addRegReg(self: *Asm, dst: Reg, src: Reg) void {
        self.aluRegReg(0x01, dst, src);
    }
    pub fn subRegReg(self: *Asm, dst: Reg, src: Reg) void {
        self.aluRegReg(0x29, dst, src);
    }
    pub fn cmpRegReg(self: *Asm, a: Reg, bb: Reg) void {
        self.aluRegReg(0x39, a, bb);
    }
    pub fn testRegReg(self: *Asm, a: Reg, bb: Reg) void {
        self.aluRegReg(0x85, a, bb);
    }
    pub fn xorRegReg(self: *Asm, dst: Reg, src: Reg) void {
        self.aluRegReg(0x31, dst, src);
    }

    /// `cmp dst, [mem]` (64-bit).
    pub fn cmpRegMem(self: *Asm, dst: Reg, m: Mem) void {
        const rb = memRexBits(m);
        self.rex(1, dst.ext(), rb.x, rb.b);
        self.b(0x3B);
        self.emitMem(dst.low(), m);
    }

    /// `cmp byte [mem], imm8`.
    pub fn cmpMem8Imm(self: *Asm, m: Mem, imm: u8) void {
        const rb = memRexBits(m);
        self.rex(0, 0, rb.x, rb.b);
        self.b(0x80);
        self.emitMem(7, m);
        self.b(imm);
    }

    /// `cmp dst_low_byte, imm8`.
    pub fn cmpReg8Imm(self: *Asm, dst: Reg, imm: u8) void {
        // REX needed for sil/dil/spl/bpl and r8b-r15b.
        if (dst.ext() == 1 or @intFromEnum(dst) >= 4) self.rex(0, 0, 0, dst.ext());
        self.b(0x80);
        self.modrm(3, 7, dst.low());
        self.b(imm);
    }

    pub fn incReg(self: *Asm, dst: Reg) void {
        self.rex(1, 0, 0, dst.ext());
        self.b(0xFF);
        self.modrm(3, 0, dst.low());
    }

    pub fn decReg(self: *Asm, dst: Reg) void {
        self.rex(1, 0, 0, dst.ext());
        self.b(0xFF);
        self.modrm(3, 1, dst.low());
    }

    /// `bt [mem], bit_reg` — bit test with a register bit index.
    pub fn btMemReg(self: *Asm, m: Mem, bit: Reg) void {
        const rb = memRexBits(m);
        self.rex(1, bit.ext(), rb.x, rb.b);
        self.b(0x0F);
        self.b(0xA3);
        self.emitMem(bit.low(), m);
    }

    pub fn jmp(self: *Asm, l: Label) void {
        self.b(0xE9);
        self.fixup(l);
    }

    pub fn jcc(self: *Asm, c: Cond, l: Label) void {
        self.b(0x0F);
        self.b(0x80 + @as(u8, @intFromEnum(c)));
        self.fixup(l);
    }

    /// `jmp reg` (indirect).
    pub fn jmpReg(self: *Asm, r: Reg) void {
        self.rex(0, 0, 0, r.ext());
        self.b(0xFF);
        self.modrm(3, 4, r.low());
    }

    pub fn callReg(self: *Asm, r: Reg) void {
        self.rex(0, 0, 0, r.ext());
        self.b(0xFF);
        self.modrm(3, 2, r.low());
    }

    pub fn push(self: *Asm, r: Reg) void {
        self.rex(0, 0, 0, r.ext());
        self.b(0x50 + @as(u8, r.low()));
    }

    pub fn pop(self: *Asm, r: Reg) void {
        self.rex(0, 0, 0, r.ext());
        self.b(0x58 + @as(u8, r.low()));
    }

    pub fn ret(self: *Asm) void {
        self.b(0xC3);
    }

    /// `bt [rip+label], bit` — bit test against an embedded table.
    pub fn btLabelReg(self: *Asm, l: Label, bit: Reg) void {
        self.rex(1, bit.ext(), 0, 0);
        self.b(0x0F);
        self.b(0xA3);
        self.modrm(0, bit.low(), 5); // rip-relative
        self.fixup(l);
    }

    /// Load the address of a label into a register (rip-relative lea).
    pub fn leaLabel(self: *Asm, dst: Reg, l: Label) void {
        self.rex(1, dst.ext(), 0, 0);
        self.b(0x8D);
        self.modrm(0, dst.low(), 5); // rip-relative
        self.fixup(l);
    }

    // -- SSE2 ---------------------------------------------------------------
    //
    // The mandatory prefix (66/F3) comes first, then REX, then the escape
    // byte, which is the order the manual requires and objdump confirms.

    /// `movdqu dst, [mem]`.
    pub fn movdquXmmMem(self: *Asm, dst: Xmm, m: Mem) void {
        const rb = memRexBits(m);
        self.b(0xF3);
        self.rex(0, dst.ext(), rb.x, rb.b);
        self.b(0x0F);
        self.b(0x6F);
        self.emitMem(dst.low(), m);
    }

    /// `movdqu dst, [rip+label]`.
    pub fn movdquXmmLabel(self: *Asm, dst: Xmm, l: Label) void {
        self.b(0xF3);
        self.rex(0, dst.ext(), 0, 0);
        self.b(0x0F);
        self.b(0x6F);
        self.modrm(0, dst.low(), 5); // rip-relative
        self.fixup(l);
    }

    fn sse2RegReg(self: *Asm, opcode: u8, dst: Xmm, src: Xmm) void {
        self.b(0x66);
        self.rex(0, dst.ext(), 0, src.ext());
        self.b(0x0F);
        self.b(opcode);
        self.modrm(3, dst.low(), src.low());
    }

    /// `movdqa dst, src` (register to register).
    pub fn movdqaXmmXmm(self: *Asm, dst: Xmm, src: Xmm) void {
        self.sse2RegReg(0x6F, dst, src);
    }

    /// `pcmpgtb dst, src` — signed byte compare, so any byte >= 0x80 reads as
    /// negative and falls outside every ASCII range.
    pub fn pcmpgtbXmmXmm(self: *Asm, dst: Xmm, src: Xmm) void {
        self.sse2RegReg(0x64, dst, src);
    }

    pub fn porXmmXmm(self: *Asm, dst: Xmm, src: Xmm) void {
        self.sse2RegReg(0xEB, dst, src);
    }

    pub fn pandXmmXmm(self: *Asm, dst: Xmm, src: Xmm) void {
        self.sse2RegReg(0xDB, dst, src);
    }

    /// `pmovmskb dst, src` — one bit per byte lane into a general register.
    pub fn pmovmskbRegXmm(self: *Asm, dst: Reg, src: Xmm) void {
        self.b(0x66);
        self.rex(0, dst.ext(), 0, src.ext());
        self.b(0x0F);
        self.b(0xD7);
        self.modrm(3, dst.low(), src.low());
    }

    /// `bsf dst, src` (32-bit): index of the lowest set bit.
    pub fn bsfRegReg(self: *Asm, dst: Reg, src: Reg) void {
        self.rex(0, dst.ext(), 0, src.ext());
        self.b(0x0F);
        self.b(0xBC);
        self.modrm(3, dst.low(), src.low());
    }

    // -- AVX2 (VEX-encoded, 256-bit) ----------------------------------------
    //
    // Always the three-byte VEX form: one byte longer than the compact form
    // but uniform, and the only one that can reach the upper registers.

    /// byte1 carries inverted R/X/B and the opcode map; byte2 carries W, the
    /// inverted second source register, the 256-bit flag, and the prefix.
    /// `vvvv` is the logical register number, so instructions without a
    /// second source pass 0 and the encoded field becomes all ones.
    fn vex3(self: *Asm, r: u1, x: u1, bb: u1, map: u5, w: u1, vvvv: u4, l: u1, pp: u2) void {
        self.b(0xC4);
        self.b((@as(u8, ~r & 1) << 7) | (@as(u8, ~x & 1) << 6) | (@as(u8, ~bb & 1) << 5) | @as(u8, map));
        self.b((@as(u8, w) << 7) | (@as(u8, ~vvvv) << 3) | (@as(u8, l) << 2) | @as(u8, pp));
    }

    /// `vmovdqu dst, [mem]` (256-bit).
    pub fn vmovdquYmmMem(self: *Asm, dst: Xmm, m: Mem) void {
        const rb = memRexBits(m);
        self.vex3(dst.ext(), rb.x, rb.b, 1, 0, 0, 1, 0b10); // F3 0F
        self.b(0x6F);
        self.emitMem(dst.low(), m);
    }

    /// `vmovdqu dst, [rip+label]` (256-bit).
    pub fn vmovdquYmmLabel(self: *Asm, dst: Xmm, l: Label) void {
        self.vex3(dst.ext(), 0, 0, 1, 0, 0, 1, 0b10);
        self.b(0x6F);
        self.modrm(0, dst.low(), 5); // rip-relative
        self.fixup(l);
    }

    fn vexRegRegReg(self: *Asm, opcode: u8, dst: Xmm, src1: Xmm, src2: Xmm) void {
        self.vex3(dst.ext(), 0, src2.ext(), 1, 0, @intFromEnum(src1), 1, 0b01); // 66 0F
        self.b(opcode);
        self.modrm(3, dst.low(), src2.low());
    }

    /// `vpcmpgtb dst, src1, src2` — three-operand, so no copy is needed first.
    pub fn vpcmpgtbYmm(self: *Asm, dst: Xmm, src1: Xmm, src2: Xmm) void {
        self.vexRegRegReg(0x64, dst, src1, src2);
    }

    pub fn vporYmm(self: *Asm, dst: Xmm, src1: Xmm, src2: Xmm) void {
        self.vexRegRegReg(0xEB, dst, src1, src2);
    }

    pub fn vpandYmm(self: *Asm, dst: Xmm, src1: Xmm, src2: Xmm) void {
        self.vexRegRegReg(0xDB, dst, src1, src2);
    }

    /// `vpmovmskb dst, src` — 32 lane bits into a general register.
    pub fn vpmovmskbRegYmm(self: *Asm, dst: Reg, src: Xmm) void {
        self.vex3(dst.ext(), 0, src.ext(), 1, 0, 0, 1, 0b01);
        self.b(0xD7);
        self.modrm(3, dst.low(), src.low());
    }

    /// Clears the upper halves so following legacy SSE code pays no
    /// AVX-to-SSE transition penalty.
    pub fn vzeroupper(self: *Asm) void {
        self.b(0xC5);
        self.b(0xF8);
        self.b(0x77);
    }

    /// Emit raw data (alignment is the caller's business).
    pub fn data(self: *Asm, bytes: []const u8) void {
        for (bytes) |x| self.b(x);
    }
};

// ---------------------------------------------------------------------------
// Tests
//
// Expected bytes were produced by this encoder and verified by disassembling
// them with `objdump -D -b binary -m i386:x86-64`; the comment on each line is
// what objdump printed.

fn expectEncoding(expected: []const u8, emit: fn (*Asm) void) !void {
    var buf: [64]u8 = undefined;
    var a = Asm.init(std.testing.allocator, &buf);
    defer a.deinit();
    emit(&a);
    const n = try a.finish();
    try std.testing.expectEqualSlices(u8, expected, buf[0..n]);
}

test "register and immediate forms" {
    try expectEncoding(&.{ 0xB8, 0x2A, 0x00, 0x00, 0x00 }, struct { // mov eax,0x2a
        fn f(a: *Asm) void {
            a.movRegImm64(.rax, 42);
        }
    }.f);
    try expectEncoding(&.{ 0x49, 0xBD, 0x88, 0x77, 0x66, 0x55, 0x44, 0x33, 0x22, 0x11 }, struct {
        fn f(a: *Asm) void { // movabs r13,0x1122334455667788
            a.movRegImm64(.r13, 0x1122334455667788);
        }
    }.f);
    try expectEncoding(&.{ 0x4C, 0x89, 0xE3 }, struct { // mov rbx,r12
        fn f(a: *Asm) void {
            a.movRegReg(.rbx, .r12);
        }
    }.f);
    try expectEncoding(&.{ 0x49, 0x83, 0xC7, 0x20 }, struct { // add r15,0x20
        fn f(a: *Asm) void {
            a.addRegImm(.r15, 32);
        }
    }.f);
    try expectEncoding(&.{ 0x49, 0x81, 0xFD, 0xE8, 0x03, 0x00, 0x00 }, struct {
        fn f(a: *Asm) void { // cmp r13,0x3e8
            a.cmpRegImm(.r13, 1000);
        }
    }.f);
}

test "memory operand corner cases" {
    // rbp as base needs an explicit zero displacement.
    try expectEncoding(&.{ 0x4C, 0x8B, 0x45, 0x00 }, struct { // mov r8,[rbp+0x0]
        fn f(a: *Asm) void {
            a.movRegMem(.r8, .{ .base = .rbp, .disp = 0 });
        }
    }.f);
    // r12 as base always needs a SIB byte.
    try expectEncoding(&.{ 0x49, 0x8B, 0x0C, 0x24 }, struct { // mov rcx,[r12]
        fn f(a: *Asm) void {
            a.movRegMem(.rcx, .{ .base = .r12, .disp = 0 });
        }
    }.f);
    // Extended index register sets REX.X.
    try expectEncoding(&.{ 0x4A, 0x8B, 0x14, 0x2B }, struct { // mov rdx,[rbx+r13*1]
        fn f(a: *Asm) void {
            a.movRegMem(.rdx, .{ .base = .rbx, .index = .r13, .scale = 0 });
        }
    }.f);
    try expectEncoding(&.{ 0x49, 0x8B, 0x94, 0xC6, 0x00, 0x01, 0x00, 0x00 }, struct {
        fn f(a: *Asm) void { // mov rdx,[r14+rax*8+0x100]
            a.movRegMem(.rdx, .{ .base = .r14, .index = .rax, .scale = 3, .disp = 256 });
        }
    }.f);
    try expectEncoding(&.{ 0x4A, 0x0F, 0xB6, 0x04, 0x2B }, struct {
        fn f(a: *Asm) void { // movzx rax,BYTE PTR [rbx+r13*1]
            a.movzxRegMem8(.rax, .{ .base = .rbx, .index = .r13, .scale = 0 });
        }
    }.f);
    try expectEncoding(&.{ 0x42, 0x80, 0x3C, 0x2B, 0x0A }, struct {
        fn f(a: *Asm) void { // cmp BYTE PTR [rbx+r13*1],0xa
            a.cmpMem8Imm(.{ .base = .rbx, .index = .r13, .scale = 0 }, '\n');
        }
    }.f);
    // Byte compares against the extended registers need a REX prefix.
    try expectEncoding(&.{ 0x80, 0xF8, 0x80 }, struct { // cmp al,0x80
        fn f(a: *Asm) void {
            a.cmpReg8Imm(.rax, 0x80);
        }
    }.f);
    try expectEncoding(&.{ 0x41, 0x80, 0xF9, 0x41 }, struct { // cmp r9b,0x41
        fn f(a: *Asm) void {
            a.cmpReg8Imm(.r9, 'A');
        }
    }.f);
}

test "jumps and labels resolve" {
    var buf: [64]u8 = undefined;
    var a = Asm.init(std.testing.allocator, &buf);
    defer a.deinit();
    const target = try a.label();
    a.jmp(target); // 5 bytes
    a.jcc(.ne, target); // 6 bytes
    a.leaLabel(.rdx, target); // 7 bytes
    a.place(target);
    a.ret();
    const n = try a.finish();
    try std.testing.expectEqual(@as(u32, 19), n);
    // Each displacement is measured from the end of its own instruction.
    try std.testing.expectEqual(@as(i32, 13), std.mem.readInt(i32, buf[1..5], .little));
    try std.testing.expectEqual(@as(i32, 7), std.mem.readInt(i32, buf[7..11], .little));
    try std.testing.expectEqual(@as(i32, 0), std.mem.readInt(i32, buf[14..18], .little));
}

test "overflow is reported, not trapped" {
    var buf: [4]u8 = undefined;
    var a = Asm.init(std.testing.allocator, &buf);
    defer a.deinit();
    a.movRegImm64(.rax, 0x1122334455667788); // 10 bytes into a 4-byte buffer
    try std.testing.expectError(error.Overflow, a.finish());
}

test "unplaced labels are caught" {
    var buf: [16]u8 = undefined;
    var a = Asm.init(std.testing.allocator, &buf);
    defer a.deinit();
    const l = try a.label();
    a.jmp(l);
    try std.testing.expectError(error.UnplacedLabel, a.finish());
}
