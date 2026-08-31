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
first-byte prefilter):

| benchmark    | zregex     | pcre2   | pcre2-jit | python | perl   | posix   |
|--------------|-----------:|--------:|----------:|-------:|-------:|--------:|
| literal      | 9.8        | 4.5     | 0.17      | 1.8    | 1.7    | 6.5     |
| ci_literal   | 11.1       | 1944.1  | 0.19      | 16.7   | 2.7    | 8.4     |
| date         | 8.6        | 2.7     | 0.63      | 41.4   | 5.1    | 256.8   |
| email        | 171.5      | 83.3    | 5.97      | 87.8   | 39.8   | 256.3   |
| alt          | 48.6       | 29.8    | 4.82      | 23.6   | 17.4   | 303.5   |
| ing_suffix   | 171.4      | 203.0   | 6.94      | 65.7   | 55.3   | 1030.6  |
| spanning     | 0.5        | 0.12    | 0.14      | 1.0    | 1.4    | 10.3    |
| groups       | 547.4      | 129.2   | 5.67      | 157.8  | 42.0   | 292.1   |
| lookahead    | 563.6 (bt) | 297.6   | 8.75      | 168.8  | 41.0   | —       |
| backref      | 475.9 (bt) | 131.3   | 17.06     | 133.7  | 179.5  | —       |
| pathological | **0.01**   | ERROR   | 26.9      | 288.2  | 0.01   | 0.01    |

(bt) = zregex backtracking engine; everything else runs on the Pike VM.
"pathological" is `(a+)+$` against `"a"*22 + "!"`: PCRE2's interpreter aborts
with a match-limit error and Python backtracks for ~300ms, while the Pike VM
answers in microseconds regardless of input — the design's core guarantee.

The first-byte prefilter (computed at compile time from the program) skips
start positions that cannot begin a match; it took the sparse-match rows from
a flat ~165 ms (thread seeding at every position) down to the times above —
`spanning` went from 165 ms to 0.5 ms. The rows still near ~170 ms (`email`,
`ing_suffix`, `groups`, and the backtracking rows) start with `\w`-like
classes, so nearly every byte is a candidate and the cost is per-position
seeding and capture-slot cloning rather than scanning — flat and predictable,
where backtrackers swing wildly in both directions.
