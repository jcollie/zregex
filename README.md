<!--
SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
SPDX-License-Identifier: MIT
-->

# zregex

A regular expression library for Zig 0.16.

Three engines behind one API:

- **JIT** — on x86-64 and aarch64, patterns are compiled to native machine
  code: literals become byte compares, classes become bit-test tables, and
  repeats become consume loops that scan sixteen bytes at a time with SSE2 or
  NEON, or thirty-two with AVX2 where the CPU and OS provide it. It backtracks, so it is used
  only where that backtracking is structurally bounded — every loop fused
  into a single repeat instruction, so frames are bounded by the pattern and
  not the input — and it carries a step budget besides; exhausting the budget
  hands the search to one of the interpreters below, which is what keeps
  every guarantee below intact.
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
  backstop for the rare shapes memoization cannot key. The budget covers a
  whole search — `max_steps` plus 64 steps per input byte, spent across every
  start position together — so it is a real bound on one `find`; a limit
  granted anew at each position, which is how PCRE's match limit works, can
  be multiplied by the length of the haystack by input crafted to stay just
  under it. That construction takes `grep -P` from milliseconds to hours;
  here it is `error.StepLimitExceeded` after work proportional to the input.

Memory is bounded the same way time is: adversarial patterns get a clean
error, not an allocation. Patterns longer than a megabyte are refused before
the parse buffers — which are sized for the worst case — are allocated for
them, and a program whose empty-loop guards would blow up the Pike VM's
visited table (near the instruction ceiling *and* five-plus levels deep in
nullable loops at once) is refused as too large. Both limits sit far past
anything not built to hit them; one 381-byte pattern used to allocate half a
gigabyte through the second.

Engine selection is automatic at compile time: `regex.engine` reports what
will run and `regex.fallback_engine` what finishes anything the JIT bails on.
A pattern whose loops cannot all be fused — `(?:ab|cd)+`, and above all an
ambiguous one like `(\w+|\d+)+x` — goes to the DFA instead, where the answer
is linear by construction rather than exponential.
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
| `\0`, `\ddd` | codepoint from up to three octal digits | `\101` matches `A` | `"\\101"` |
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
| `\h` / `\H` | horizontal whitespace / complement (not ASCII-only) | `\h+` matches a tab, space, or U+3000 | `"\\h+"` |
| `\v` / `\V` | vertical whitespace / complement (not ASCII-only) | `\v` matches `\n`, `\r`, U+2028 | `"\\v"` |
| `[\d\s]` | shorthands compose inside classes | `[^\d\s]+` matches `abc` | `"[^\\d\\s]+"` |
| `[\b]` | backspace (U+0008) — only inside a class | | `"[\\b]"` |
| `[[:alpha:]]` | POSIX class — only inside a class, ASCII like `\d`/`\w`/`\s` | `[[:alpha:]_]+` matches `hi_there` | `"[[:alpha:]_]+"` |
| `[[:^alpha:]]` | its complement | `[[:^digit:]]+` matches `abc` | `"[[:^digit:]]+"` |

The POSIX class names are `alnum`, `alpha`, `ascii`, `blank`, `cntrl`,
`digit`, `graph`, `lower`, `print`, `punct`, `space`, `upper`, `word` and
`xdigit`. A name outside that set is an error; a `[` that does not open one
stays the literal it is elsewhere, so `[[]` still matches a bracket.

### Anchors and boundaries

All of these are zero-width: they match a position, not text.

| Syntax | Matches at | Example | As a Zig `"..."` literal |
|---|---|---|---|
| `^` | start of text (start of line under the `m` flag) | `^abc` | `"^abc"` |
| `$` | end of text, or just before a newline ending it (end of line under the `m` flag) | `bc$` matches in both `abc` and `abc\n` | `"bc$"` |
| `\A` / `\z` | start / end of text, regardless of `m`; `\z` allows no trailing newline | `\Aabc\z` | `"\\Aabc\\z"` |
| `\Z` | end of text, or just before a newline ending it — what `$` means outside `m` | `bc\Z` | `"bc\\Z"` |
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

Space and horizontal tab are ignored just inside the braces of a quantifier
and on either side of its comma, and an omitted minimum means zero, both
following PCRE: `a{ 1 , 2 }` is `a{1,2}` and `a{,3}` is `a{0,3}`. A `{` that
does not form a valid quantifier is a literal (PCRE behavior):
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

Comparison honors `(?i)`. A backreference to a group that has not
participated fails to match, following PCRE; referring to a group that appears
later in the pattern is a compile error.

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

Lookbehind may be variable-length. PCRE allows that too since 10.43, but only
where each branch has a known maximum; `(?<=ab+)c` is unbounded and works here.
Where several lengths could match, the longest wins, as in PCRE: the group in
`(?<=(\d{1,4}))X` captures all of `1234`, not just the `4`.

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
classes (`\p{...}`), extended/whitespace mode (`(?x)`), the braced octal escape
(`\o{101}` — the bare `\101` form *is* supported), `\Q...\E` quoting,
conditionals, and recursion. All reject at compile time with a clear error
rather than misbehaving.

## Platform support

The library itself is pure Zig and runs anywhere Zig does. The JIT is the
only part that cares where it is:

| Platform | JIT |
|---|---|
| Linux / BSD, x86-64 and aarch64 | yes |
| Windows, x86-64 and aarch64 | yes |
| macOS, Apple Silicon | yes, with the entitlement below |
| macOS, Intel | yes |
| anything else | no — the interpreters run instead |

Each platform gets executable memory its own way: `mmap` plus `mprotect` on
Linux and the BSDs, `VirtualAlloc` plus `VirtualProtect` on Windows, and
`MAP_JIT` with a per-thread write toggle on Apple platforms. The generated
code differs too — Windows x64 passes arguments in different registers than
System V, reserves shadow space at every call, and expects `rsi`, `rdi` and
`xmm6`-`xmm15` to come back unchanged.

### If you ship a macOS app that uses this library

**Add the `com.apple.security.cs.allow-jit` entitlement.** Any application
built with the **hardened runtime** — which is required for notarization, so
in practice any app you distribute — is denied the `MAP_JIT` mapping without
it, and on Apple Silicon there is no second way to get executable memory. Put
it in the app's `.entitlements` file before signing:

```xml
<key>com.apple.security.cs.allow-jit</key>
<true/>
```

```sh
codesign --sign "Developer ID Application: …" \
         --options runtime \
         --entitlements MyApp.entitlements MyApp.app
```

Without the entitlement nothing breaks and nothing needs handling: zregex
notices the refusal, leaves `Regex.engine` reporting an interpreter, and
returns exactly the same matches — just several times slower on
repeat-heavy patterns. Command-line tools and unsigned or ad-hoc-signed
builds are unaffected, since they do not use the hardened runtime.

The mechanism, for the curious: Apple Silicon enforces W^X in hardware and
rejects the `mmap`-then-`mprotect` transition used on other platforms, so the
code region is mapped with `MAP_JIT` and made writable per thread with
`pthread_jit_write_protect_np` instead. zregex tries that first and falls back
to `mprotect`, which is usually enough on Intel but never on Apple Silicon.

Every one of those failures is graceful. If a mapping is refused, the pattern
simply has no native code: `Regex.engine` reports `.pike` or `.backtrack`
instead of `.jit`, and matches and captures are identical either way. Check
`Regex.engine` if you want to know which one you got.

## Semantics

- **UTF-8 codepoint based**: `.` and `[^x]` consume one codepoint; invalid
  bytes degrade to single-byte codepoints rather than erroring.
- **Leftmost-greedy** (PCRE/Perl-style) matching; alternation prefers the left
  branch. Captures persist across repeat iterations (PCRE, not JS, semantics).
- Iterating matches follows PCRE and Python: where a match is empty, the next
  attempt looks for a longer one starting in the same place before moving on,
  so `.*?` over `ab` yields the empty match at 0, then `a`, then the empty
  match at 1, then `b`, then the empty match at 2.
- `\d \w \s`, `[[:alpha:]]` and the other POSIX classes, and `\b` are
  **ASCII-only** — which is what PCRE gives them without `PCRE2_UCP`. Case
  folding is **Unicode**: `(?i)s` matches `ſ`, `(?i)k` matches `K`, and
  `(?i)ⱥ` matches `Ⱥ`. It is *simple* folding, the `C` and `S` entries of
  Unicode's `CaseFolding.txt`, so `ß` does not match `ss` and `İ` matches
  neither `i` nor `I` — the same as PCRE.
- Lookarounds are atomic. A backreference to a group that has not captured
  fails, as in PCRE; JavaScript is the odd one out in matching empty.
- A backreference to the group that *encloses* it, as in `(a|b\1)`, reads that
  group's value from its last completed iteration, and fails before there has
  been one. PCRE instead treats the enclosing group as unavailable while it is
  open — though not consistently, since it matches `1(\1*)` and fails
  `1(2|\1*)`, which differ only in the order of the alternatives. Python
  rejects the construct outright. This is the one construct where zregex does
  not follow PCRE, because PCRE has no single answer to follow.
- A loop iteration that consumes nothing ends the loop rather than failing, so
  `(a*?)*` matches empty and `(a*)*` against `aa` reports group 1 as the empty
  span at 2 — as PCRE and Python do. This takes effect only once the repeat's
  minimum is met: `e{2,}` still runs a second iteration after an empty first
  one, while `e+` stops at it. Every engine agrees; patterns with an
  empty-bodied loop are simply kept off the lazy DFA, whose states cannot
  carry the position an iteration began at.
- Backreferences to a group require the group to appear earlier in the pattern.

## Building

```sh
zig build test   # run the test suite
zig build run -- '(\w+)@([\w.]+)' 'mail jeff@example.org'   # demo CLI
```

## Differential testing

The engines are independent implementations of one specification, so they can
be checked against each other, and all of them against PCRE2. Patterns and
haystacks come from a grammar (`src/pattern_gen.zig`) rather than from raw
bytes, so the time goes on the engines instead of on the parser rejecting
noise.

Each generated case is run through every engine that can take it — the JIT, the
lazy DFA, the Pike VM, and the backtracker with memoization on and off — and
they must report the same matches and the same captures. On x86-64 the JIT is
compiled twice, once with AVX2 forced off, because the two vector code
generators are chosen while compiling and the host CPU would otherwise only
ever select one of them. `isMatch` is checked against `find` as well, since it
has a path of its own that never materialises captures.

`zig build test` runs a few thousand seeded cross-engine cases every time. A
longer soak raises the count and walks the seed, which is how patterns a single
stream never produces get reached:

```sh
zig build test -Dfuzz-cases=50000 -Dfuzz-seed=7
```

A separate test reruns generated cases once per allocation they make, failing a
different one each time, so that the paths taken when memory runs out partway
are executed too — what was allocated by then still has to be released. It is
quadratic in what one case allocates, hence its own much smaller count:

```sh
zig build test -Dfuzz-alloc-cases=500
```

The cross-engine comparison cannot find a mistake every engine makes together.
For that, `tools/oracle.zig` runs the same generated patterns through PCRE2 and
compares. It needs that library to link, so it is opt-in:

```sh
zig build oracle -Dpcre2-include=<dir> -Dpcre2-lib=<dir> -- [cases] [seed]
```

The dev shell exports the two directories, so from inside `nix develop` that is:

```sh
zig build oracle -Dpcre2-include=$PCRE2_INCLUDE -Dpcre2-lib=$PCRE2_LIB -- 25000 1
```

Both the generated patterns and the corpus below are compared three ways: on
the leftmost match; on every match in the subject, which is what holds
`Regex.Iterator` to PCRE's rule for getting past an empty match; and from
random offsets, holding `findAt` to PCRE2's `startoffset` — where the match
may not begin before the offset but `\b`, `^` and lookbehind still see the
text in front of it.

It also runs PCRE2's own test files, which are nine thousand patterns written
by hand over decades, mostly because something once went wrong with them —
shapes no grammar of ours would think to generate. Point it at a PCRE2 source
tree; nothing is copied into this repository:

```sh
zig build oracle ... -- --corpus <pcre2-source>/testdata
```

A second mode mutates those patterns — an edit or three, or two patterns
spliced — and compares the results the same way. The corpus tests what its
authors wrote; the mutations visit everything nearby that they almost wrote,
which is where an off-by-one in the parser lives. Its first run caught the
class `[]-b]` being read as three characters instead of the range `]`–`b`:

```sh
zig build oracle ... -- --corpus-mutate <pcre2-source>/testdata [cases] [seed]
```

It reports how many cases it compared and why any were dropped, so coverage can
be aimed at the biggest bucket rather than guessed at. Two flags reduce a single
case: `--case '<pattern>' '<haystack>'` shows every engine beside PCRE2, and
`--engines '<pattern>' '<haystack>'` compares the engines with no reference
involved — which is the only way to judge a haystack holding invalid UTF-8,
since PCRE2 runs in UTF mode and rejects one outright. Both exit non-zero on a
disagreement, so a shrinker can drive them.
