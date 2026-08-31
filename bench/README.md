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
first-byte prefilter, lazy capture handling, and the lazy DFA):

| benchmark    | zregex     | pcre2   | pcre2-jit | python | perl   | posix   |
|--------------|-----------:|--------:|----------:|-------:|-------:|--------:|
| literal      | 7.2        | 4.7     | 0.18      | 1.9    | 1.7    | 6.5     |
| ci_literal   | 8.4        | 2047.0  | 0.19      | 17.0   | 2.7    | 8.4     |
| date         | 9.9        | 2.8     | 0.63      | 41.5   | 5.1    | 252.2   |
| email        | 69.5       | 83.9    | 6.03      | 89.4   | 40.0   | 251.6   |
| alt          | 37.3       | 29.9    | 4.89      | 23.3   | 17.4   | 288.9   |
| ing_suffix   | 85.0       | 204.6   | 7.08      | 65.7   | 55.2   | 1039.5  |
| spanning     | 0.5        | 0.12    | 0.14      | 1.0    | 1.4    | 10.3    |
| groups       | 72.5       | 129.9   | 5.70      | 157.7  | 42.3   | 305.9   |
| lookahead    | 519.8 (bt) | 298.5   | 8.90      | 180.2  | 41.4   | —       |
| backref      | 443.0 (bt) | 134.5   | 17.39     | 121.2  | 181.5  | —       |
| pathological | **0.01**   | ERROR   | 27.3      | 295.2  | 0.01   | 0.01    |

(bt) = zregex backtracking engine; everything else runs on the Pike VM.
"pathological" is `(a+)+$` against `"a"*22 + "!"`: PCRE2's interpreter aborts
with a match-limit error and Python backtracks for ~300ms, while the Pike VM
answers in microseconds regardless of input — the design's core guarantee.

Three layers shape these numbers. The first-byte prefilter (computed at
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
Costs remain flat and predictable where backtrackers swing wildly in both
directions.
