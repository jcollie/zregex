<!--
SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
SPDX-License-Identifier: MIT
-->

# zregex

A regular expression library for Zig 0.16.

Three engines behind one API:

- **JIT** — on x86-64, patterns are compiled to native machine code: literals
  become byte compares, classes become bit-test tables, and repeats become
  tight consume loops. It backtracks, so it carries a step budget
  proportional to the input; exhausting it hands the search to one of the
  interpreters below, which is what keeps every guarantee below intact.
- **Pike VM + lazy DFA** — patterns without backreferences or lookaround run
  in guaranteed linear time (no catastrophic backtracking, ever). An RE2-style
  lazy DFA finds match spans at one table transition per codepoint; the Pike
  VM extracts captures from a small window.
- **Backtracker** — patterns using backreferences or lookaround fall back to
  a backtracking engine with backref-aware memoization: states whose failure
  was already proven (keyed by position, program point, and every capture the
  remaining program can read) are pruned, so classic ReDoS patterns like
  `(a+)+\1$` complete in polynomial time instead of exploding. A configurable
  step budget (`error.StepLimitExceeded` instead of hanging) remains as the
  backstop for the rare shapes memoization cannot key.

Engine selection is automatic at compile time: `regex.engine` reports what
will run and `regex.fallback_engine` what finishes anything the JIT bails on.
Set `regex.jit_mode` to `.off` to keep searches on the interpreters, or `.on`
to force native code. Every engine skips ahead using a first-byte prefilter
computed from the pattern (see `bench/` for numbers against PCRE2, Python,
Perl, and POSIX).

All three produce identical matches and captures; which one runs is a
performance decision only, and the test suite checks them against each other
pattern by pattern.

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

Flags: `compileWithFlags(gpa, pattern, .{ .case_insensitive = true, .multiline = true, .dot_all = true })`,
or inline: `(?i)`, `(?m)`, `(?s)` — see below.

## Supported syntax

### Writing patterns in Zig source

Zig's normal `"..."` string literals process escapes, so every regex
backslash must be doubled: the pattern `\d+\.\d+` is written
`"\\d+\\.\\d+"`. Zig's multiline string literals do **no** escape
processing, which makes them the nicest way to write non-trivial patterns —
what you see is exactly the pattern:

```zig
var re = try Regex.compile(gpa,
    \\(?<user>\w+)@(?<host>[\w.]+)
);
```

The tables below show each pattern both ways. To match one literal backslash
the regex is `\\`, which becomes `"\\\\"` in a quoted literal (four
backslashes) — or a `\\\\` multiline line (the first two introduce the line).

### Literals and escapes

| Syntax | Matches | Example | As a Zig `"..."` literal |
|---|---|---|---|
| `a`, `é`, `😀` | that codepoint (patterns are UTF-8) | `héllo` matches `héllo` | `"héllo"` |
| `\n` `\r` `\t` `\f` `\v` `\a` `\e` `\0` | newline, CR, tab, FF, VT, bell, ESC, NUL | `foo\tbar` | `"foo\\tbar"` |
| `\xHH` | codepoint from two hex digits | `\x41` matches `A` | `"\\x41"` |
| `\x{...}`, `\u{...}` | codepoint from hex, up to `10FFFF` | `\x{1F600}+` matches `😀😀` | `"\\x{1F600}+"` |
| `\uHHHH` | codepoint from four hex digits | `\u0041` matches `A` | `"\\u0041"` |
| `\.` `\*` `\(` `\\` … | that punctuation character, literally | `3\.14` matches `3.14` | `"3\\.14"` |

Escaping a letter or digit that has no defined meaning (say `\q`) is a
compile error rather than silently matching `q`.

### Character classes

| Syntax | Matches | Example | As a Zig `"..."` literal |
|---|---|---|---|
| `.` | any codepoint except `\n` (including `\n` under the `s` flag) | `a.c` matches `aéc` | `"a.c"` |
| `[abc]` | any listed codepoint | `[nd]ope` matches `dope` | `"[nd]ope"` |
| `[a-z0-9]` | codepoint ranges | `[a-fA-F0-9]+` matches `DEADbeef` | `"[a-fA-F0-9]+"` |
| `[^...]` | anything *not* in the class | `"[^"]*"` matches `"hi"` | `"\"[^\"]*\""` |
| `[]x]`, `[-x]`, `[x-]` | `]` first in a class and `-` at either edge are literal | `[]x]+` matches `]x]` | `"[]x]+"` |
| `\d` / `\D` | ASCII digit / non-digit | `\d{4}` matches `2026` | `"\\d{4}"` |
| `\w` / `\W` | ASCII word char `[A-Za-z0-9_]` / complement | `\w+` matches `hi_there2` | `"\\w+"` |
| `\s` / `\S` | ASCII whitespace / complement | `\S+` matches `x9!` | `"\\S+"` |
| `[\d\s]` | shorthands compose inside classes | `[^\d\s]+` matches `abc` | `"[^\\d\\s]+"` |
| `[\b]` | backspace (U+0008) — only inside a class | | `"[\\b]"` |

### Anchors and boundaries

All of these are zero-width: they match a position, not text.

| Syntax | Matches at | Example | As a Zig `"..."` literal |
|---|---|---|---|
| `^` | start of text (start of line under the `m` flag) | `^abc` | `"^abc"` |
| `$` | end of text (end of line under the `m` flag) | `abc$` | `"abc$"` |
| `\A` / `\z` | start / end of text, regardless of `m` | `\Aabc\z` | `"\\Aabc\\z"` |
| `\b` / `\B` | word boundary / non-boundary | `\bcat\b` matches `cat` in `the cat.` but not in `concat` | `"\\bcat\\b"` |

### Quantifiers

Greedy by default; append `?` for the lazy (shortest-first) variant.
Counted repeats are capped at 1000.

| Syntax | Matches | Example on `aaaa` | As a Zig `"..."` literal |
|---|---|---|---|
| `x*` / `x*?` | zero or more | `a*` matches `aaaa` | `"a*"` |
| `x+` / `x+?` | one or more | `a+?` matches `a` | `"a+?"` |
| `x?` / `x??` | zero or one | `colou?r` matches both spellings | `"colou?r"` |
| `x{3}` | exactly n | `a{3}` matches `aaa` | `"a{3}"` |
| `x{2,5}` / `x{2,5}?` | n through m | `a{2,3}` matches `aaa` | `"a{2,3}"` |
| `x{2,}` | n or more | `a{2,}` matches `aaaa` | `"a{2,}"` |

A `{` that does not form a valid quantifier is a literal (PCRE behavior):
`a{x}` matches the four characters `a{x}`. Double quantifiers (`a**`) and
possessive quantifiers (`a*+`) are errors.

### Alternation and groups

| Syntax | Meaning | Example | As a Zig `"..."` literal |
|---|---|---|---|
| `x\|y` | `x` or `y`, preferring `x` | `cat\|dog` finds `cat` in `catalog` | `"cat\|dog"` |
| `(...)` | capture group, numbered from 1 by `(` order (0 is the whole match) | `(a\|b)+c` on `abac` captures `a` | `"(a\|b)+c"` |
| `(?:...)` | group without capturing | `(?:ab)+` | `"(?:ab)+"` |
| `(?<name>...)` | named capture (also `(?P<name>...)`, `(?'name'...)`) | `(?<year>\d{4})-(?<month>\d{2})` | `"(?<year>\\d{4})-(?<month>\\d{2})"` |

Look up a named group's index with `re.groupIndex("year")`.

### Backreferences *(backtracking engine)*

| Syntax | Matches | Example | As a Zig `"..."` literal |
|---|---|---|---|
| `\1` … `\99` | the same text group n captured | `(\w+) \1` matches `go go` | `"(\\w+) \\1"` |
| `\k<name>` | same, by name | `(?<q>['"]).*?\k<q>` matches a quoted span | `"(?<q>['\"]).*?\\k<q>"` |

Comparison honors `(?i)`. A backref to a group that has not participated
matches the empty string (JavaScript semantics); referring to a group that
appears later in the pattern is a compile error.

### Lookaround *(backtracking engine)*

Zero-width; matched (or rejected) without consuming input. Lookarounds are
atomic: once one succeeds, backtracking cannot re-enter it to try a
different sub-match.

| Syntax | Succeeds when | Example | As a Zig `"..."` literal |
|---|---|---|---|
| `(?=x)` | `x` matches next | `\w+(?=@)` matches `jeff` in `jeff@host` | `"\\w+(?=@)"` |
| `(?!x)` | `x` does not match next | `a(?!b)` matches the `a` in `ac` | `"a(?!b)"` |
| `(?<=x)` | `x` ends here | `(?<=\$)\d+` matches `42` in `$42` | `"(?<=\\$)\\d+"` |
| `(?<!x)` | `x` does not end here | `(?<!\$)\b\d+` | `"(?<!\\$)\\b\\d+"` |

Lookbehind may be variable-length (`(?<=ab+)c` works), which PCRE does not
allow.

### Inline flags

| Syntax | Meaning | Example | As a Zig `"..."` literal |
|---|---|---|---|
| `(?i)` `(?m)` `(?s)` | set case-insensitive / multiline / dot-matches-newline from here to the end of the enclosing group | `(?i)hello` matches `HeLLo` | `"(?i)hello"` |
| `(?-ims)` | clear flags | `a(?-i)b` under `case_insensitive` requires exact-case `b` | `"a(?-i)b"` |
| `(?ims-ims:...)` | flags scoped to the group | `(?i:zig) rocks` matches `ZIG rocks` | `"(?i:zig) rocks"` |

Flag changes persist across `\|` until the enclosing group closes (PCRE
semantics). The same three flags can be set for the whole pattern via
`compileWithFlags`.

### Not supported

Possessive quantifiers (`a*+`), atomic groups (`(?>...)`), Unicode property
classes (`\p{...}`), extended/whitespace mode (`(?x)`), octal escapes,
`\Q...\E` quoting, conditionals, and recursion. All reject at compile time
with a clear error rather than misbehaving.

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
