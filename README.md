<!--
SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
SPDX-License-Identifier: MIT
-->

# zregex

A regular expression library for Zig 0.16.

Two engines behind one API:

- **Pike VM** — patterns without backreferences or lookaround run in
  guaranteed linear time (no catastrophic backtracking, ever).
- **Backtracker** — patterns using backreferences or lookaround fall back to a
  backtracking engine with a configurable step budget
  (`error.StepLimitExceeded` instead of hanging).

Engine selection is automatic at compile time; check `regex.engine` if you
care which one you got.

## Usage

```zig
const zregex = @import("zregex");

var re = try zregex.Regex.compile(gpa, "(?<user>\\w+)@(?<host>[\\w.]+)");
defer re.deinit();

if (try re.find(gpa, "mail jeff@example.org")) |match| {
    var m = match;
    defer m.deinit(gpa);
    m.span().slice(haystack);                          // "jeff@example.org"
    m.group(re.groupIndex("user").?).?.slice(haystack); // "jeff"
}

// Iterate all matches:
var it = re.iterator(gpa, haystack);
while (try it.next()) |m| { ... }
```

Patterns can also be compiled at comptime — invalid patterns become compile
errors and the program is baked into the binary (matching still takes an
allocator for engine scratch space):

```zig
const re = comptime zregex.Regex.compileComptime("\\d{3}-\\d{4}");
if (try re.isMatch(gpa, input)) { ... }
```

Flags: `compileWithFlags(gpa, pattern, .{ .case_insensitive = true, .multiline = true, .dot_all = true })`.

## Supported syntax

- Literals, `.`, alternation `|`, groups `(...)`, `(?:...)`, named groups
  `(?<name>...)` / `(?P<name>...)` / `(?'name'...)`
- Quantifiers `*` `+` `?` `{n}` `{n,}` `{n,m}` (max count 1000), lazy variants (`*?` …)
- Classes `[a-z]`, `[^...]`, shorthands `\d \D \w \W \s \S` (also inside classes)
- Anchors `^` `$` `\A` `\z`, boundaries `\b` `\B`
- Escapes `\n \r \t \f \v \a \e \0`, `\xHH`, `\x{...}`, `\uHHHH`, `\u{...}`,
  identity escapes for punctuation
- Backreferences `\1`…`\99`, `\k<name>` *(backtracking engine)*
- Lookaround `(?=)` `(?!)` `(?<=)` `(?<!)` — lookbehind may be
  variable-length *(backtracking engine)*

## Semantics

- **UTF-8 codepoint based**: `.` and `[^x]` consume one codepoint; invalid
  bytes degrade to single-byte codepoints rather than erroring.
- **Leftmost-greedy** (PCRE/Perl-style) matching; alternation prefers the left
  branch. Captures persist across repeat iterations (PCRE, not JS, semantics).
- `\d \w \s`, case folding, and `\b` are **ASCII-only**.
- Lookarounds are atomic; a backreference to an unset group matches empty.
- Backreferences to a group require the group to appear earlier in the pattern.

## Building

```sh
zig build test   # run the test suite
zig build run -- '(\w+)@([\w.]+)' 'mail jeff@example.org'   # demo CLI
```
