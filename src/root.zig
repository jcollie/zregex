// SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

//! zregex — a regular expression library for Zig.
//!
//! Two engines behind one API: patterns without backreferences or lookaround
//! run on a Pike VM with guaranteed linear-time matching; patterns that need
//! them fall back to a backtracker with a configurable step budget. Patterns
//! can also be compiled at comptime (`Regex.compileComptime`), baking the
//! program into the binary.
//!
//! Semantics: UTF-8 codepoint based (`.` is one codepoint), leftmost-greedy
//! matching, ASCII-only case folding and `\d`/`\w`/`\s`.
const regex = @import("regex.zig");

pub const Regex = regex.Regex;
pub const Match = regex.Match;
pub const Span = regex.Span;
pub const Flags = regex.Flags;
pub const Engine = regex.Engine;
pub const ParseError = regex.ParseError;
pub const CompileError = regex.CompileError;
pub const RunError = regex.RunError;

test {
    _ = @import("common.zig");
    _ = @import("parser.zig");
    _ = @import("compiler.zig");
    _ = @import("tests.zig");
}
