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
first-byte prefilter and lazy capture handling):

| benchmark    | zregex     | pcre2   | pcre2-jit | python | perl   | posix   |
|--------------|-----------:|--------:|----------:|-------:|-------:|--------:|
| literal      | 6.6        | 4.5     | 0.17      | 1.9    | 1.7    | 6.4     |
| ci_literal   | 7.8        | 1937.9  | 0.18      | 16.5   | 2.7    | 8.2     |
| date         | 6.6        | 2.7     | 0.62      | 40.6   | 5.0    | 245.8   |
| email        | 124.2      | 82.4    | 5.95      | 86.1   | 39.2   | 240.3   |
| alt          | 45.5       | 29.4    | 4.80      | 23.3   | 17.1   | 291.5   |
| ing_suffix   | 118.3      | 201.4   | 6.94      | 64.3   | 54.5   | 997.5   |
| spanning     | 0.5        | 0.12    | 0.14      | 1.0    | 1.4    | 10.3    |
| groups       | 190.6      | 127.9   | 5.67      | 146.7  | 41.5   | 287.9   |
| lookahead    | 504.2 (bt) | 294.3   | 8.73      | 165.2  | 40.8   | —       |
| backref      | 433.8 (bt) | 135.3   | 17.59     | 118.6  | 177.1  | —       |
| pathological | **0.01**   | ERROR   | 27.1      | 277.3  | 0.01   | 0.01    |

(bt) = zregex backtracking engine; everything else runs on the Pike VM.
"pathological" is `(a+)+$` against `"a"*22 + "!"`: PCRE2's interpreter aborts
with a match-limit error and Python backtracks for ~300ms, while the Pike VM
answers in microseconds regardless of input — the design's core guarantee.

Two optimizations shape these numbers. The first-byte prefilter (computed at
compile time from the program) skips start positions that cannot begin a
match: it took the sparse-match rows from a flat ~165 ms down to single-digit
ms (`spanning`: 165 -> 0.5). Lazy capture handling removed group 0's save
instructions entirely (the engines track the match span directly) and
replaced the Pike VM's cloned capture arrays with immutable prepend-only
chains, cutting `groups` from 615 ms at baseline to 191 ms. The remaining
~120 ms rows start with `\w`-like classes — nearly every byte is a candidate,
so the cost is per-position thread seeding, flat and predictable where
backtrackers swing wildly in both directions.
