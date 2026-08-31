// SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

//! A small AArch64 instruction encoder: only what the regex code generator
//! emits, AAPCS64 calling convention, 64-bit operands unless a helper says
//! otherwise.
//!
//! Same shape as the x86-64 encoder — labels may be referenced before they
//! are placed and `finish` resolves the fixups — but every instruction is
//! exactly four bytes, and the branch forms have different reaches, so a
//! fixup records which field it patches and `finish` reports a target that
//! does not fit rather than emitting a wrong displacement.
const std = @import("std");

pub const Reg = enum(u5) {
    x0 = 0,
    x1 = 1,
    x2 = 2,
    x3 = 3,
    x4 = 4,
    x5 = 5,
    x6 = 6,
    x7 = 7,
    x8 = 8,
    x9 = 9,
    x10 = 10,
    x11 = 11,
    x12 = 12,
    x13 = 13,
    x14 = 14,
    x15 = 15,
    x16 = 16,
    x17 = 17,
    x18 = 18,
    x19 = 19,
    x20 = 20,
    x21 = 21,
    x22 = 22,
    x23 = 23,
    x24 = 24,
    x25 = 25,
    x26 = 26,
    x27 = 27,
    x28 = 28,
    x29 = 29,
    x30 = 30,
    /// Register 31 reads as zero in data-processing instructions and as the
    /// stack pointer in loads, stores, and add/sub immediate.
    zr = 31,

    fn n(self: Reg) u32 {
        return @intFromEnum(self);
    }
};

pub const sp: Reg = .zr;

/// Vector registers, used only as 16-byte lanes.
pub const Vec = enum(u5) {
    v0 = 0,
    v1 = 1,
    v2 = 2,
    v3 = 3,
    v4 = 4,
    v5 = 5,
    v6 = 6,
    v7 = 7,
    v8 = 8,
    v9 = 9,
    v10 = 10,
    v11 = 11,
    v12 = 12,
    v13 = 13,
    v14 = 14,
    v15 = 15,

    fn n(self: Vec) u32 {
        return @intFromEnum(self);
    }
};

pub const Cond = enum(u4) {
    eq = 0,
    ne = 1,
    hs = 2, // unsigned >=
    lo = 3, // unsigned <
    mi = 4,
    pl = 5,
    vs = 6,
    vc = 7,
    hi = 8, // unsigned >
    ls = 9, // unsigned <=
    ge = 10,
    lt = 11,
    gt = 12,
    le = 13,
};

pub const Label = u32;

const FixupKind = enum {
    /// b: 26-bit word displacement.
    branch26,
    /// b.cond, cbz, cbnz: 19-bit word displacement.
    branch19,
    /// tbz, tbnz: 14-bit word displacement.
    branch14,
    /// adr: 21-bit byte displacement, split across two fields.
    adr21,
};

const Fixup = struct {
    at: u32,
    label: Label,
    kind: FixupKind,
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

    fn word(self: *Asm, w: u32) void {
        if (self.len + 4 > self.buf.len) {
            self.overflow = true;
            return;
        }
        std.mem.writeInt(u32, self.buf[self.len..][0..4], w, .little);
        self.len += 4;
    }

    pub fn offset(self: *const Asm) u32 {
        return self.len;
    }

    // -- labels -------------------------------------------------------------

    pub fn label(self: *Asm) std.mem.Allocator.Error!Label {
        try self.labels.append(self.gpa, null);
        return @intCast(self.labels.items.len - 1);
    }

    pub fn place(self: *Asm, l: Label) void {
        self.labels.items[l] = self.len;
    }

    pub fn here(self: *Asm) std.mem.Allocator.Error!Label {
        const l = try self.label();
        self.place(l);
        return l;
    }

    fn fixup(self: *Asm, l: Label, kind: FixupKind) void {
        self.fixups.append(self.gpa, .{ .at = self.len, .label = l, .kind = kind }) catch {
            self.overflow = true;
        };
    }

    /// Resolve every branch; returns the code length. `error.OutOfRange` means
    /// a target is too far for its branch form, which the caller turns into
    /// "do not JIT this pattern" rather than emitting something wrong.
    pub fn finish(self: *Asm) error{ Overflow, UnplacedLabel, OutOfRange }!u32 {
        if (self.overflow) return error.Overflow;
        for (self.fixups.items) |f| {
            const target = self.labels.items[f.label] orelse return error.UnplacedLabel;
            var w = std.mem.readInt(u32, self.buf[f.at..][0..4], .little);
            const byte_delta: i64 = @as(i64, target) - @as(i64, f.at);
            switch (f.kind) {
                .adr21 => {
                    if (byte_delta < -(1 << 20) or byte_delta >= (1 << 20)) return error.OutOfRange;
                    const imm: u32 = @bitCast(@as(i32, @intCast(byte_delta)));
                    const lo = imm & 0x3;
                    const hi = (imm >> 2) & 0x7FFFF;
                    w |= (lo << 29) | (hi << 5);
                },
                else => {
                    std.debug.assert(@rem(byte_delta, 4) == 0);
                    const words = @divExact(byte_delta, 4);
                    switch (f.kind) {
                        .branch26 => {
                            if (words < -(1 << 25) or words >= (1 << 25)) return error.OutOfRange;
                            w |= @as(u32, @bitCast(@as(i32, @intCast(words)))) & 0x03FFFFFF;
                        },
                        .branch19 => {
                            if (words < -(1 << 18) or words >= (1 << 18)) return error.OutOfRange;
                            w |= (@as(u32, @bitCast(@as(i32, @intCast(words)))) & 0x7FFFF) << 5;
                        },
                        .branch14 => {
                            if (words < -(1 << 13) or words >= (1 << 13)) return error.OutOfRange;
                            w |= (@as(u32, @bitCast(@as(i32, @intCast(words)))) & 0x3FFF) << 5;
                        },
                        .adr21 => unreachable,
                    }
                },
            }
            std.mem.writeInt(u32, self.buf[f.at..][0..4], w, .little);
        }
        return self.len;
    }

    // -- moves and arithmetic ------------------------------------------------

    /// `movz Rd, #imm16, lsl #(16*shift)`.
    pub fn movz(self: *Asm, rd: Reg, imm: u16, shift: u2) void {
        self.word(0xD2800000 | (@as(u32, shift) << 21) | (@as(u32, imm) << 5) | rd.n());
    }

    /// `movk Rd, #imm16, lsl #(16*shift)` — keeps the other bits.
    pub fn movk(self: *Asm, rd: Reg, imm: u16, shift: u2) void {
        self.word(0xF2800000 | (@as(u32, shift) << 21) | (@as(u32, imm) << 5) | rd.n());
    }

    /// Materialize any 64-bit constant, shortest form first.
    pub fn movImm(self: *Asm, rd: Reg, value: u64) void {
        self.movz(rd, @truncate(value), 0);
        if (value >> 16 != 0) self.movk(rd, @truncate(value >> 16), 1);
        if (value >> 32 != 0) self.movk(rd, @truncate(value >> 32), 2);
        if (value >> 48 != 0) self.movk(rd, @truncate(value >> 48), 3);
    }

    /// `mov Rd, Rn` (an alias of `orr Rd, xzr, Rn`).
    pub fn movReg(self: *Asm, rd: Reg, rn: Reg) void {
        self.word(0xAA0003E0 | (rn.n() << 16) | rd.n());
    }

    pub fn addImm(self: *Asm, rd: Reg, rn: Reg, imm: u12) void {
        self.word(0x91000000 | (@as(u32, imm) << 10) | (rn.n() << 5) | rd.n());
    }

    pub fn subImm(self: *Asm, rd: Reg, rn: Reg, imm: u12) void {
        self.word(0xD1000000 | (@as(u32, imm) << 10) | (rn.n() << 5) | rd.n());
    }

    pub fn addReg(self: *Asm, rd: Reg, rn: Reg, rm: Reg) void {
        self.word(0x8B000000 | (rm.n() << 16) | (rn.n() << 5) | rd.n());
    }

    pub fn subReg(self: *Asm, rd: Reg, rn: Reg, rm: Reg) void {
        self.word(0xCB000000 | (rm.n() << 16) | (rn.n() << 5) | rd.n());
    }

    /// `subs Rd, Rn, Rm` — the flag-setting form; `cmp` passes zr as `rd`.
    pub fn subsReg(self: *Asm, rd: Reg, rn: Reg, rm: Reg) void {
        self.word(0xEB000000 | (rm.n() << 16) | (rn.n() << 5) | rd.n());
    }

    pub fn cmpReg(self: *Asm, rn: Reg, rm: Reg) void {
        self.subsReg(.zr, rn, rm);
    }

    pub fn cmpImm(self: *Asm, rn: Reg, imm: u12) void {
        self.word(0xF1000000 | (@as(u32, imm) << 10) | (rn.n() << 5) | 31);
    }

    /// `lsr Rd, Rn, #shift` (an alias of `ubfm`).
    pub fn lsrImm(self: *Asm, rd: Reg, rn: Reg, shift: u6) void {
        self.word(0xD340FC00 | (@as(u32, shift) << 16) | (rn.n() << 5) | rd.n());
    }

    /// `lsr Rd, Rn, Rm` — the shift amount is taken modulo 64, which is what
    /// lets a codepoint be used directly as a bit index into a 64-bit word.
    pub fn lsrReg(self: *Asm, rd: Reg, rn: Reg, rm: Reg) void {
        self.word(0x9AC02400 | (rm.n() << 16) | (rn.n() << 5) | rd.n());
    }

    pub fn rbit(self: *Asm, rd: Reg, rn: Reg) void {
        self.word(0xDAC00000 | (rn.n() << 5) | rd.n());
    }

    pub fn clz(self: *Asm, rd: Reg, rn: Reg) void {
        self.word(0xDAC01000 | (rn.n() << 5) | rd.n());
    }

    // -- loads and stores ----------------------------------------------------

    /// `ldr Rt, [Rn, #offset]`; offset must be a multiple of 8.
    pub fn ldr(self: *Asm, rt: Reg, rn: Reg, off: u32) void {
        std.debug.assert(off % 8 == 0 and off / 8 < 4096);
        self.word(0xF9400000 | ((off / 8) << 10) | (rn.n() << 5) | rt.n());
    }

    /// `str Rt, [Rn, #offset]`; offset must be a multiple of 8.
    pub fn str(self: *Asm, rt: Reg, rn: Reg, off: u32) void {
        std.debug.assert(off % 8 == 0 and off / 8 < 4096);
        self.word(0xF9000000 | ((off / 8) << 10) | (rn.n() << 5) | rt.n());
    }

    /// `ldur Rt, [Rn, #offset]` — unscaled, and the only form that reaches a
    /// negative offset, which the backtrack frame fields need.
    pub fn ldur(self: *Asm, rt: Reg, rn: Reg, off: i32) void {
        std.debug.assert(off >= -256 and off < 256);
        const imm: u32 = @as(u32, @bitCast(off)) & 0x1FF;
        self.word(0xF8400000 | (imm << 12) | (rn.n() << 5) | rt.n());
    }

    /// `stur Rt, [Rn, #offset]` — unscaled, may be negative.
    pub fn stur(self: *Asm, rt: Reg, rn: Reg, off: i32) void {
        std.debug.assert(off >= -256 and off < 256);
        const imm: u32 = @as(u32, @bitCast(off)) & 0x1FF;
        self.word(0xF8000000 | (imm << 12) | (rn.n() << 5) | rt.n());
    }

    /// `ldr Rt, [Rn, Rm, lsl #3]` — indexing an array of 64-bit words.
    pub fn ldrRegScaled(self: *Asm, rt: Reg, rn: Reg, rm: Reg) void {
        self.word(0xF8607800 | (rm.n() << 16) | (rn.n() << 5) | rt.n());
    }

    /// `str Rt, [Rn, Rm, lsl #3]`.
    pub fn strRegScaled(self: *Asm, rt: Reg, rn: Reg, rm: Reg) void {
        self.word(0xF8207800 | (rm.n() << 16) | (rn.n() << 5) | rt.n());
    }

    /// `ldrb Wt, [Rn, Rm]`.
    pub fn ldrbReg(self: *Asm, rt: Reg, rn: Reg, rm: Reg) void {
        self.word(0x38606800 | (rm.n() << 16) | (rn.n() << 5) | rt.n());
    }

    /// `ldrb Wt, [Rn, #offset]`.
    pub fn ldrbImm(self: *Asm, rt: Reg, rn: Reg, off: u12) void {
        self.word(0x39400000 | (@as(u32, off) << 10) | (rn.n() << 5) | rt.n());
    }

    // -- branches ------------------------------------------------------------

    pub fn b(self: *Asm, l: Label) void {
        self.fixup(l, .branch26);
        self.word(0x14000000);
    }

    pub fn bcond(self: *Asm, c: Cond, l: Label) void {
        self.fixup(l, .branch19);
        self.word(0x54000000 | @as(u32, @intFromEnum(c)));
    }

    pub fn cbz(self: *Asm, rt: Reg, l: Label) void {
        self.fixup(l, .branch19);
        self.word(0xB4000000 | rt.n());
    }

    pub fn cbnz(self: *Asm, rt: Reg, l: Label) void {
        self.fixup(l, .branch19);
        self.word(0xB5000000 | rt.n());
    }

    /// `tbz Rt, #bit, label` — branch if the bit is clear.
    pub fn tbz(self: *Asm, rt: Reg, bit: u6, l: Label) void {
        const hi: u32 = if (bit >= 32) 0xB6000000 else 0x36000000;
        self.fixup(l, .branch14);
        self.word(hi | ((@as(u32, bit) & 31) << 19) | rt.n());
    }

    /// `tbnz Rt, #bit, label` — branch if the bit is set.
    pub fn tbnz(self: *Asm, rt: Reg, bit: u6, l: Label) void {
        const hi: u32 = if (bit >= 32) 0xB7000000 else 0x37000000;
        self.fixup(l, .branch14);
        self.word(hi | ((@as(u32, bit) & 31) << 19) | rt.n());
    }

    pub fn br(self: *Asm, rn: Reg) void {
        self.word(0xD61F0000 | (rn.n() << 5));
    }

    pub fn blr(self: *Asm, rn: Reg) void {
        self.word(0xD63F0000 | (rn.n() << 5));
    }

    pub fn ret(self: *Asm) void {
        self.word(0xD65F03C0);
    }

    /// `adr Rd, label` — the address of a label, within ±1 MB.
    pub fn adr(self: *Asm, rd: Reg, l: Label) void {
        self.fixup(l, .adr21);
        self.word(0x10000000 | rd.n());
    }

    // -- NEON ----------------------------------------------------------------

    /// `ldr Qt, [Rn, Rm]` — 16 bytes from a computed address.
    pub fn ldrqReg(self: *Asm, vt: Vec, rn: Reg, rm: Reg) void {
        self.word(0x3CE06800 | (rm.n() << 16) | (rn.n() << 5) | vt.n());
    }

    /// `ldr Qt, [Rn, #offset]`; offset must be a multiple of 16.
    pub fn ldrqImm(self: *Asm, vt: Vec, rn: Reg, off: u32) void {
        std.debug.assert(off % 16 == 0 and off / 16 < 4096);
        self.word(0x3DC00000 | ((off / 16) << 10) | (rn.n() << 5) | vt.n());
    }

    /// `cmgt Vd.16b, Vn.16b, Vm.16b` — signed, so bytes >= 0x80 read as
    /// negative and fall outside every ASCII range.
    pub fn cmgt16b(self: *Asm, vd: Vec, vn: Vec, vm: Vec) void {
        self.word(0x4E203400 | (vm.n() << 16) | (vn.n() << 5) | vd.n());
    }

    pub fn orr16b(self: *Asm, vd: Vec, vn: Vec, vm: Vec) void {
        self.word(0x4EA01C00 | (vm.n() << 16) | (vn.n() << 5) | vd.n());
    }

    pub fn and16b(self: *Asm, vd: Vec, vn: Vec, vm: Vec) void {
        self.word(0x4E201C00 | (vm.n() << 16) | (vn.n() << 5) | vd.n());
    }

    /// `shrn Vd.8b, Vn.8h, #4` — narrows sixteen 0x00/0xFF lanes to sixteen
    /// nibbles in eight bytes, which is how AArch64 stands in for a byte
    /// mask move: NEON has no equivalent of x86's `pmovmskb`.
    pub fn shrn8b4(self: *Asm, vd: Vec, vn: Vec) void {
        self.word(0x0F0C8400 | (vn.n() << 5) | vd.n());
    }

    /// `fmov Rd, Dn` — the low 64 bits of a vector into a general register.
    pub fn fmovToReg(self: *Asm, rd: Reg, vn: Vec) void {
        self.word(0x9E660000 | (vn.n() << 5) | rd.n());
    }

    /// Emit raw data.
    pub fn data(self: *Asm, bytes: []const u8) void {
        for (bytes) |x| {
            if (self.len >= self.buf.len) {
                self.overflow = true;
                return;
            }
            self.buf[self.len] = x;
            self.len += 1;
        }
    }

    /// Pad to a 16-byte boundary, which vector constants need.
    pub fn align16(self: *Asm) void {
        while (self.len % 16 != 0) self.data(&.{0});
    }
};
