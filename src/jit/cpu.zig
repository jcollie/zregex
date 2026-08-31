// SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

//! Runtime CPU feature detection for the JIT.
//!
//! SSE2 needs no check — it is part of the x86-64 baseline — but AVX2 does,
//! and checking the CPUID bit alone is not enough: the operating system must
//! also have enabled saving of the YMM register state, or code using those
//! registers corrupts them across context switches. Both conditions are
//! tested here, once, and cached.
const std = @import("std");
const builtin = @import("builtin");

fn cpuid(leaf: u32, subleaf: u32) [4]u32 {
    var eax: u32 = undefined;
    var ebx: u32 = undefined;
    var ecx: u32 = undefined;
    var edx: u32 = undefined;
    asm volatile ("cpuid"
        : [_eax] "={eax}" (eax),
          [_ebx] "={ebx}" (ebx),
          [_ecx] "={ecx}" (ecx),
          [_edx] "={edx}" (edx),
        : [leaf] "{eax}" (leaf),
          [sub] "{ecx}" (subleaf),
    );
    return .{ eax, ebx, ecx, edx };
}

/// Extended control register 0: which register state the OS saves.
fn xgetbv0() u64 {
    var eax: u32 = undefined;
    var edx: u32 = undefined;
    asm volatile ("xgetbv"
        : [_eax] "={eax}" (eax),
          [_edx] "={edx}" (edx),
        : [c] "{ecx}" (@as(u32, 0)),
    );
    return (@as(u64, edx) << 32) | eax;
}

fn detectAvx2() bool {
    if (builtin.cpu.arch != .x86_64) return false;
    const leaf1 = cpuid(1, 0);
    // Without OSXSAVE the XCR0 query below would itself fault.
    if ((leaf1[2] >> 27) & 1 == 0) return false;
    // Bits 1 and 2 are the XMM and YMM state; both must be saved by the OS.
    if (xgetbv0() & 0x6 != 0x6) return false;
    if (cpuid(0, 0)[0] < 7) return false;
    return (cpuid(7, 0)[1] >> 5) & 1 == 1;
}

var avx2_state: std.atomic.Value(u8) = .init(0); // 0 unknown, 1 no, 2 yes

/// Forces the answer `hasAvx2` gives, so tests can exercise both code paths
/// on one machine. Pass null to go back to what the CPU actually reports.
/// Affects only patterns compiled after the call.
pub fn overrideAvx2(value: ?bool) void {
    avx2_state.store(if (value) |v| (if (v) 2 else 1) else 0, .monotonic);
}

/// Whether generated code may use 256-bit AVX2 instructions.
pub fn hasAvx2() bool {
    switch (avx2_state.load(.monotonic)) {
        1 => return false,
        2 => return true,
        else => {},
    }
    const yes = detectAvx2();
    avx2_state.store(if (yes) 2 else 1, .monotonic);
    return yes;
}

test hasAvx2 {
    // Cannot assert a result — it depends on the host — but it must be stable
    // and must never report AVX2 on a non-x86-64 build.
    const a = hasAvx2();
    try std.testing.expectEqual(a, hasAvx2());
    if (builtin.cpu.arch != .x86_64) try std.testing.expect(!a);
}
