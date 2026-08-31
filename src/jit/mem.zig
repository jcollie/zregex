// SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

//! Executable memory for JIT-compiled matchers.
//!
//! Code is assembled into a writable mapping and then flipped to read+execute
//! before it is ever called, so a page is never simultaneously writable and
//! executable (W^X). Mappings are per compiled pattern and released by
//! `deinit`.
const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;

pub const Error = error{ OutOfMemory, MemoryProtectionFailed };

/// Whether this build can map executable memory at all. Platforms without it
/// simply never JIT; every caller has an interpreter fallback.
pub const supported = switch (builtin.os.tag) {
    .linux, .macos, .freebsd, .netbsd, .openbsd, .dragonfly => true,
    else => false,
};

pub const Buffer = struct {
    /// The whole mapping; `len` is page-rounded and may exceed the code size.
    mapping: []align(std.heap.page_size_min) u8,
    /// The executable entry point, valid only after `finalize`.
    code: []const u8 = &.{},

    /// Reserve `size` bytes of writable memory to assemble into.
    pub fn init(size: usize) Error!Buffer {
        if (!supported) return error.MemoryProtectionFailed;
        const page = std.heap.pageSize();
        const len = std.mem.alignForward(usize, @max(size, 1), page);
        const mapping = posix.mmap(
            null,
            len,
            .{ .READ = true, .WRITE = true },
            .{ .TYPE = .PRIVATE, .ANONYMOUS = true },
            -1,
            0,
        ) catch return error.OutOfMemory;
        return .{ .mapping = mapping };
    }

    /// Make the first `code_len` bytes executable and no longer writable.
    pub fn finalize(self: *Buffer, code_len: usize) Error!void {
        std.debug.assert(code_len <= self.mapping.len);
        switch (posix.errno(posix.system.mprotect(
            self.mapping.ptr,
            self.mapping.len,
            .{ .READ = true, .EXEC = true },
        ))) {
            .SUCCESS => {},
            else => return error.MemoryProtectionFailed,
        }
        // Writes went through a different mapping permission than the one the
        // CPU will fetch from; on x86-64 the icache is coherent, but other
        // targets need an explicit flush and this is where it would go.
        self.code = self.mapping[0..code_len];
    }

    pub fn deinit(self: *Buffer) void {
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
