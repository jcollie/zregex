// SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

//! Executable memory for JIT-compiled matchers.
//!
//! Code is assembled into a writable mapping and then made executable before
//! it is ever called, so a page is never simultaneously writable and
//! executable from the CPU's point of view (W^X). Mappings are per compiled
//! pattern and released by `deinit`.
//!
//! Two ways of getting there. Everywhere but Apple platforms, map
//! read+write and `mprotect` to read+execute. Apple enforces W^X in hardware
//! on Apple Silicon and rejects that transition, so there the region is
//! mapped with `MAP_JIT` and write access is toggled per thread with
//! `pthread_jit_write_protect_np` instead. `MAP_JIT` needs the
//! `com.apple.security.cs.allow-jit` entitlement under the hardened runtime,
//! which plain `mprotect` does not, so Darwin tries `MAP_JIT` first and falls
//! back — an unentitled process on an Intel Mac still gets native code, and
//! one that can do neither simply runs on the interpreters.
//!
//! The per-thread toggle covers *every* `MAP_JIT` region the thread can see,
//! so a buffer must be finalized (or freed) before another is created on the
//! same thread. `Jit.compile` is a straight init-write-finalize sequence, so
//! that holds.
const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;

pub const Error = error{ OutOfMemory, MemoryProtectionFailed };

/// Apple platforms enforce W^X in hardware and provide their own contract.
const darwin_jit = switch (builtin.os.tag) {
    .macos, .ios, .tvos, .watchos, .visionos => true,
    else => false,
};

const darwin = struct {
    /// Grants or revokes the calling thread's write access to MAP_JIT memory.
    /// A no-op on Intel Macs, where such regions are simply read+write+exec.
    extern "c" fn pthread_jit_write_protect_np(enabled: c_int) void;
    /// Apple's supported way to make written bytes visible to the fetcher.
    extern "c" fn sys_icache_invalidate(start: *anyopaque, len: usize) void;
};

/// Whether this build can map executable memory at all. Platforms without it
/// simply never JIT; every caller has an interpreter fallback.
pub const supported = switch (builtin.os.tag) {
    .linux, .macos, .freebsd, .netbsd, .openbsd, .dragonfly => true,
    else => false,
};

/// Make newly written instructions visible to the instruction fetcher.
///
/// On x86-64 the caches are coherent with stores and nothing is required. On
/// AArch64 they are not: freshly written bytes can sit in the data cache
/// while the instruction cache serves stale contents, so each line must be
/// cleaned to the point of unification, then invalidated in the instruction
/// cache, with barriers between. The line sizes come from CTR_EL0, which
/// reports them as a log2 count of 4-byte words.
fn syncInstructionCache(code: []const u8) void {
    if (builtin.cpu.arch != .aarch64) return;
    // Apple platforms use sys_icache_invalidate instead; see `finalize`.
    if (darwin_jit) return;
    if (code.len == 0) return;
    const ctr = asm volatile ("mrs %[out], ctr_el0"
        : [out] "=r" (-> u64),
    );
    const dcache_line: usize = @as(usize, 4) << @intCast((ctr >> 16) & 0xF);
    const icache_line: usize = @as(usize, 4) << @intCast(ctr & 0xF);
    const start = @intFromPtr(code.ptr);
    const end = start + code.len;

    var addr = std.mem.alignBackward(usize, start, dcache_line);
    while (addr < end) : (addr += dcache_line) {
        asm volatile ("dc cvau, %[a]"
            :
            : [a] "r" (addr),
            : .{ .memory = true });
    }
    asm volatile ("dsb ish" ::: .{ .memory = true });

    addr = std.mem.alignBackward(usize, start, icache_line);
    while (addr < end) : (addr += icache_line) {
        asm volatile ("ic ivau, %[a]"
            :
            : [a] "r" (addr),
            : .{ .memory = true });
    }
    asm volatile ("dsb ish" ::: .{ .memory = true });
    asm volatile ("isb" ::: .{ .memory = true });
}

pub const Buffer = struct {
    /// The whole mapping; `len` is page-rounded and may exceed the code size.
    mapping: []align(std.heap.page_size_min) u8,
    /// The executable entry point, valid only after `finalize`.
    code: []const u8 = &.{},
    /// How this mapping becomes executable, decided at `init`.
    mode: Mode = .mprotect,
    /// Darwin only: this thread currently holds write access to MAP_JIT memory.
    writable: bool = false,

    const Mode = enum { mprotect, map_jit };

    /// Reserve `size` bytes of writable memory to assemble into.
    pub fn init(size: usize) Error!Buffer {
        if (!supported) return error.MemoryProtectionFailed;
        const page = std.heap.pageSize();
        const len = std.mem.alignForward(usize, @max(size, 1), page);

        if (darwin_jit) {
            // MAP_JIT regions are created executable; the thread toggle, not
            // mprotect, is what makes them writable.
            if (posix.mmap(
                null,
                len,
                .{ .READ = true, .WRITE = true, .EXEC = true },
                .{ .TYPE = .PRIVATE, .ANONYMOUS = true, .JIT = true },
                -1,
                0,
            )) |mapping| {
                darwin.pthread_jit_write_protect_np(0);
                return .{ .mapping = mapping, .mode = .map_jit, .writable = true };
            } else |_| {
                // No entitlement, most likely; mprotect may still be allowed.
            }
        }

        const mapping = posix.mmap(
            null,
            len,
            .{ .READ = true, .WRITE = true },
            .{ .TYPE = .PRIVATE, .ANONYMOUS = true },
            -1,
            0,
        ) catch return error.OutOfMemory;
        return .{ .mapping = mapping, .mode = .mprotect };
    }

    /// Make the first `code_len` bytes executable and no longer writable.
    pub fn finalize(self: *Buffer, code_len: usize) Error!void {
        std.debug.assert(code_len <= self.mapping.len);
        switch (self.mode) {
            .map_jit => {
                if (darwin_jit) {
                    darwin.pthread_jit_write_protect_np(1);
                    self.writable = false;
                    self.code = self.mapping[0..code_len];
                    darwin.sys_icache_invalidate(@ptrCast(self.mapping.ptr), code_len);
                }
            },
            .mprotect => {
                switch (posix.errno(posix.system.mprotect(
                    self.mapping.ptr,
                    self.mapping.len,
                    .{ .READ = true, .EXEC = true },
                ))) {
                    .SUCCESS => {},
                    else => return error.MemoryProtectionFailed,
                }
                self.code = self.mapping[0..code_len];
                if (darwin_jit) {
                    darwin.sys_icache_invalidate(@ptrCast(self.mapping.ptr), code_len);
                } else {
                    syncInstructionCache(self.code);
                }
            },
        }
    }

    pub fn deinit(self: *Buffer) void {
        // Never leave the thread holding write access to JIT memory, however
        // this buffer is being abandoned.
        if (darwin_jit and self.writable) darwin.pthread_jit_write_protect_np(1);
        posix.munmap(self.mapping);
        self.* = undefined;
    }
};

test "assemble, protect, and call native code" {
    if (!supported or builtin.cpu.arch != .x86_64) return error.SkipZigTest;
    var buf = try Buffer.init(64);
    defer buf.deinit();
    // mov eax, 42 ; ret
    const code = [_]u8{ 0xB8, 0x2A, 0x00, 0x00, 0x00, 0xC3 };
    @memcpy(buf.mapping[0..code.len], &code);
    try buf.finalize(code.len);
    const f: *const fn () callconv(.c) u32 = @ptrCast(buf.code.ptr);
    try std.testing.expectEqual(@as(u32, 42), f());
}

test "code can take arguments" {
    if (!supported or builtin.cpu.arch != .x86_64) return error.SkipZigTest;
    var buf = try Buffer.init(64);
    defer buf.deinit();
    // lea eax, [rdi + rsi] ; ret   (System V: args in rdi, rsi)
    const code = [_]u8{ 0x8D, 0x04, 0x37, 0xC3 };
    @memcpy(buf.mapping[0..code.len], &code);
    try buf.finalize(code.len);
    const f: *const fn (u32, u32) callconv(.c) u32 = @ptrCast(buf.code.ptr);
    try std.testing.expectEqual(@as(u32, 30), f(12, 18));
}
