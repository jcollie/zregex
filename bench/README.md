<!--
SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
SPDX-License-Identifier: MIT
-->

# Benchmarks

`./bench/run.sh` generates a deterministic ~4MB log-like corpus, builds every
harness it can (zregex ReleaseFast, glibc POSIX ERE and PCRE2 via `zig cc`,
plus Python `re` and Perl), runs the same benchmark set through each, and
prints a merged table. Each harness emits `impl \t bench \t best_ms \t count`;
match counts are cross-checked in the "matches" column (a single value means
all implementations agree).

Snapshot (2026-08-31, Linux, corpus 4.2 MB, times in ms, best of 5, with the
first-byte prefilter, lazy capture handling, the lazy DFA, the fused
backtracker, and the x86-64 JIT with SSE2/AVX2 run scanning):

| benchmark    | zregex          | pcre2   | pcre2-jit | python | perl   | posix   |
|--------------|----------------:|--------:|----------:|-------:|-------:|--------:|
| literal      | 1.8 (jit)       | 4.5     | 0.17      | 1.9    | 1.7    | 6.4     |
| ci_literal   | 2.9 (jit)       | 1940.6  | 0.19      | 16.5   | 2.6    | 8.3     |
| date         | 2.2 (jit)       | 2.7     | 0.63      | 40.7   | 4.9    | 251.1   |
| email        | **5.2** (jit)   | 82.2    | 6.11      | 128.6  | 39.2   | 240.3   |
| alt          | 12.4 (jit)      | 29.3    | 4.77      | 24.0   | 17.2   | 283.2   |
| ing_suffix   | 11.0 (jit)      | 201.6   | 6.92      | 65.2   | 54.2   | 1013.2  |
| spanning     | **0.08** (jit)  | 0.12    | 0.14      | 1.0    | 1.4    | 10.2    |
| groups       | 6.3 (jit)       | 127.8   | 5.67      | 157.7  | 41.5   | 288.4   |
| lookahead    | **5.1** (jit)   | 294.7   | 8.66      | 175.0  | 40.5   | —       |
| backref      | **7.4** (jit)   | 130.9   | 16.98     | 118.7  | 177.5  | —       |
| pathological | **0.00** (pike) | ERROR   | 26.47     | 281.7  | 0.01   | 0.01    |

The parenthesised engine is the one `Regex.engine` selected. zregex is
fastest of the interpreted engines on nine of eleven rows (Perl edges it out
on the two plain-literal searches), and beats PCRE2's JIT outright on five:
`email`, `spanning`, `lookahead`, `backref`, and `pathological`.
"pathological" is `(a+)+$` against `"a"*22 + "!"`: PCRE2's interpreter aborts
with a match-limit error and Python backtracks for ~280ms. The JIT spends a
bounded number of native steps on it, bails, and the Pike VM answers — the
design's core guarantee, kept even with a backtracking JIT in front.

Six layers shape these numbers. The first-byte prefilter (computed at
compile time from the program) skips start positions that cannot begin a
match: it took the sparse-match rows from a flat ~165 ms down to single-digit
ms (`spanning`: 165 -> 0.5). Lazy capture handling removed group 0's save
instructions and replaced the Pike VM's cloned capture arrays with immutable
prepend-only chains. The lazy DFA (an RE2-style memoized Pike VM over a
compressed codepoint alphabet) handles the dense-candidate patterns the
prefilter cannot help: it finds the match span at one table transition per
codepoint, and the Pike VM extracts captures from just the tiny window where
the match can start. `email` and `groups` now beat interpreted PCRE2 and
Python (`groups`: 615 ms at baseline -> 72). A selectivity gate keeps 1-2
byte prefilters on the pure memchr+Pike path, where no automaton can compete.
The backtracker fuses single-element repeats (`\w+` is one instruction, one
range-retry frame instead of a frame per character), evaluates
single-codepoint lookarounds without recursion, and — when a pattern leads
with a greedy unbounded repeat and has no backrefs — skips the whole consumed
run after a failed attempt, turning the classic quadratic leading-`\w+` scan
linear (`lookahead`: 512 -> 63 ms). An ASCII fast path in the UTF-8 decoder,
found while profiling the backtracker, cut every engine's inner loop by
2-3x (`email`: 69 -> 25 ms, `groups`: 73 -> 28 ms). Backref-aware
memoization prunes proven-failing backtracker states, taming classic ReDoS
patterns (`(a+)+\1$` on 40 chars: step-budget error -> 0.5 ms correct
answer) at zero cost to split-free programs. Required-literal scanning makes
greedy-repeat retries jump straight to occurrences of the literal the
continuation must match next (a char or single-char lookahead), and lead-run
skipping applies dynamically to backref patterns whenever a failed attempt
never executed a backref — together taking `backref` from 232 to 49 ms and
`lookahead` from 63 to 43.

Finally the JIT compiles patterns to native code, taking over wherever few
start positions get tried — literals, digits, alternations, and everything
behind a backreference or lookaround. Dense scans stay on the lazy DFA, which
reads each byte once where a backtracker re-reads it. Two things carry the
JIT's repeat-heavy rows: consume loops scan sixteen bytes per iteration with
SSE2, and greedy repeats no longer leave a retry frame when the continuation
must match a literal the repeat itself never matches (retries only ever
resume *inside* the consumed run, so `\w+@` can never find an `@` there).
Together those took `lookahead` to 5.5 ms and `backref` to 7.5.

The JIT gets its own copy of the program, compiled with repeats fused. That
sounds like a detail and was worth 5-12x: fusion had been enabled only for
patterns using a backreference or lookaround, so everything else reached the
JIT as split-loops — a backtrack frame per character, no repeat instruction
for the vector scanner to accelerate, and a bail to the interpreter on any
run longer than the 256-frame stack. With a fused program `email` went from
62 to 5.2 ms, `groups` from 75 to 6.3, and `ing_suffix` from 58 to 11.

Which engine runs is now decided by whether the JIT's backtracking is
*structurally bounded*: a fused repeat leaves one frame however long the run
is, so a program whose loops are all fused can only push frames in proportion
to the pattern, never the input. Programs with an unfused loop — `(?:ab|cd)+`,
and especially an ambiguous one like `(\w+|\d+)+x`, where the JIT explores
exponentially many ways to split a run — go to the lazy DFA, which is linear
by construction. That single rule routes every benchmark correctly and is
what keeps `pathological` at 0.00 ms.

The generator has two backends, x86-64 and aarch64, sharing the runtime
layout, the helpers, and every analysis that decides what to compile; only
instruction selection differs. AArch64 needs two things x86-64 does not:
freshly written code must be pushed out of the data cache and the stale lines
invalidated in the instruction cache before it can be executed, and NEON has
no equivalent of `pmovmskb`, so the run scanner narrows its sixteen
comparison lanes to sixteen nibbles with `shrn` and finds the first set one
with `rbit`+`clz`. The suite runs for both architectures — the aarch64 one
under QEMU, in CI as well — and the two agree match for match.

AVX2 is used when the CPU and OS support it (checked with CPUID and XGETBV,
since the OS must also be saving YMM state), which doubles the block and,
being three-operand, drops the register copies the SSE2 form needs. On this
corpus that is worth 2-8% — its tokens are short words, so a run usually ends
inside the first block either way. It earns much more when runs are long: on
synthetic input with 512-byte runs, 7.7 GB/s with SSE2 against 12.1 GB/s with
AVX2. Finally the JIT compiles patterns to
native code, taking over wherever few start positions get tried — literals,
digits, alternations, and everything behind a backreference or lookaround
(`backref`: 49 -> 16 ms, `lookahead`: 63 -> 15). Dense scans stay on the lazy
DFA, which reads each byte once where a backtracker re-reads it. The JIT
budget is what `pathological` shows: `(a+)+$` spends a bounded number of
native steps, bails, and the Pike VM answers — 0.26 ms instead of PCRE2's
hard error or Python's 283 ms. Costs remain flat and predictable where
backtrackers swing wildly in both directions.

## Across platforms

`.github/workflows/ci.yaml` runs this harness on every platform the JIT has a
distinct path for, with `--builtin` so each measures a corpus generated from
the same seed. Times in ms, best of 5, on GitHub-hosted runners — shared and
noisy, so read the columns against each other rather than against the tuned
numbers above:

| benchmark    | x86-64 linux | aarch64 linux | aarch64 macOS | x86-64 Windows |
|--------------|-------------:|--------------:|--------------:|---------------:|
| literal      | 2.8          | 3.1           | 4.1           | 8.7            |
| ci_literal   | 5.1          | 3.2           | 4.2           | 10.3           |
| date         | 4.4          | 2.7           | 2.7           | 12.7           |
| email        | 8.4          | 9.2           | 8.6           | 48.6           |
| alt          | 19.5         | 15.5          | 17.9          | 38.6           |
| ing_suffix   | 18.1         | 17.4          | 16.9          | 82.4           |
| spanning     | 0.15         | 0.33          | 0.12          | 0.60           |
| groups       | 10.1         | 10.1          | 8.2           | 46.4           |
| lookahead    | 8.1          | 8.8           | 8.1           | 69.4           |
| backref      | 12.0         | 11.0          | 13.9          | 77.8           |
| pathological | 0.01         | 0.01          | 0.01          | 0.01           |
| **engine**   | jit          | jit           | jit           | pike/backtrack |

Match counts are identical in all four columns, across two architectures,
three operating systems, and both the native-code and interpreter paths.

The Windows column above predates the Windows JIT backend, which makes it a
clean measure of what native code is worth: the identical library with the
interpreters doing all the work ran `ing_suffix` at 82 ms against 18,
`email` at 49 against 8, and `backref` at 78 against 12 — 4-6x — while
`pathological` was unchanged, the lazy DFA having always been the one
answering there. Windows now JITs too, and lands with the others.

The aarch64 macOS column is the first execution of the `MAP_JIT` path
anywhere: `jit_available=true`, and every row selected the JIT, so Apple's
contract is being satisfied. Note that GitHub's runners execute unsigned
processes; a shipping app under the hardened runtime still needs the
`com.apple.security.cs.allow-jit` entitlement, and without it these rows
would look like the Windows column rather than fail.
