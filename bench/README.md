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

Snapshot (2026-08-30, Linux, corpus 4.2 MB, times in ms, best of 5, with the
first-byte prefilter, lazy capture handling, the lazy DFA, and the fused
backtracker):

| benchmark    | zregex    | pcre2   | pcre2-jit | python | perl   | posix   |
|--------------|----------:|--------:|----------:|-------:|-------:|--------:|
| literal      | 5.5       | 4.5     | 0.18      | 1.9    | 1.7    | 6.4     |
| ci_literal   | 6.7       | 1944.5  | 0.18      | 16.6   | 2.7    | 8.3     |
| date         | 7.8       | 2.8     | 0.62      | 41.3   | 5.0    | 251.3   |
| email        | 25.3      | 83.6    | 6.01      | 87.6   | 38.9   | 242.1   |
| alt          | 21.0      | 29.8    | 4.84      | 23.5   | 17.3   | 285.6   |
| ing_suffix   | 39.2      | 203.4   | 6.97      | 64.8   | 54.7   | 1007.5  |
| spanning     | 0.4       | 0.12    | 0.14      | 1.0    | 1.4    | 10.2    |
| groups       | 28.1      | 129.6   | 5.70      | 157.3  | 42.1   | 289.7   |
| lookahead    | 62.5 (bt) | 297.5   | 8.78      | 171.9  | 41.2   | —       |
| backref      | 238.9 (bt)| 134.9   | 17.22     | 133.0  | 181.7  | —       |
| pathological | **0.01**  | ERROR   | 26.3      | 282.8  | 0.01   | 0.01    |

(bt) = zregex backtracking engine; everything else runs on the Pike VM.
"pathological" is `(a+)+$` against `"a"*22 + "!"`: PCRE2's interpreter aborts
with a match-limit error and Python backtracks for ~300ms, while the Pike VM
answers in microseconds regardless of input — the design's core guarantee.

Four layers shape these numbers. The first-byte prefilter (computed at
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
2-3x (`email`: 69 -> 25 ms, `groups`: 73 -> 28 ms). Costs remain flat and
predictable where backtrackers swing wildly in both directions.
