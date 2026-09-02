// SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

//! zregex — a regular expression library for Zig.
//!
//! Four engines behind one API, chosen per pattern at compile time. Patterns
//! without backreferences or lookaround run on a lazy DFA or a Pike VM, both
//! with guaranteed linear-time matching; patterns that need them fall back
//! to a memoizing backtracker whose step budget covers the whole search --
//! `error.StepLimitExceeded` rather than a hang, however the input is
//! crafted. On x86-64 and aarch64 a JIT compiles the pattern to native code
//! and bails to the interpreters when its own budget runs out. Patterns can
//! also be compiled at comptime (`Regex.compileComptime`), baking the
//! program into the binary.
//!
//! Semantics follow PCRE: UTF-8 codepoint based (`.` is one codepoint),
//! leftmost-greedy matching, Unicode simple case folding under `(?i)`, and
//! ASCII-only `\d`/`\w`/`\s`/`\b`.
const regex = @import("regex.zig");

pub const Regex = regex.Regex;
pub const Match = regex.Match;
pub const Span = regex.Span;
pub const Flags = regex.Flags;
pub const Engine = regex.Engine;
pub const ParseError = regex.ParseError;
pub const CompileError = regex.CompileError;
pub const RunError = regex.RunError;

/// Whether this build can compile patterns to native code. When false every
/// pattern runs on an interpreter and `Regex.engine` is never `.jit`.
pub const jit_available = @import("jit.zig").available;

/// Forces the JIT's choice of vector width, so both the SSE2 and AVX2 code
/// paths can be exercised on one machine. Pass null to restore detection.
/// Only affects patterns compiled after the call.
pub const overrideAvx2 = @import("jit/cpu.zig").overrideAvx2;

test {
    _ = @import("common.zig");
    _ = @import("jit.zig");
    _ = @import("jit/mem.zig");
    _ = @import("jit/x64.zig");
    _ = @import("jit/a64.zig");
    _ = @import("jit/runtime.zig");
    _ = @import("jit/cpu.zig");
    _ = @import("parser.zig");
    _ = @import("compiler.zig");
    _ = @import("tests.zig");
    _ = @import("fuzz.zig");
}
