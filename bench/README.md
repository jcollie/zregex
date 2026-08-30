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

Snapshot (2026-08-30, Linux, corpus 4.2 MB, times in ms, best of 5):

| benchmark    | zregex     | pcre2   | pcre2-jit | python | perl   | posix   |
|--------------|-----------:|--------:|----------:|-------:|-------:|--------:|
| literal      | 171.9      | 4.5     | 0.20      | 1.9    | 1.7    | 6.5     |
| ci_literal   | 168.2      | 2034.4  | 0.24      | 17.0   | 2.8    | 8.5     |
| date         | 126.1      | 2.8     | 0.78      | 41.8   | 5.2    | 249.0   |
| email        | 182.7      | 84.9    | 6.16      | 88.8   | 40.6   | 246.8   |
| alt          | 209.3      | 30.5    | 5.02      | 23.5   | 17.7   | 287.0   |
| ing_suffix   | 185.1      | 207.0   | 7.18      | 66.1   | 56.5   | 1057.1  |
| spanning     | 165.0      | 0.12    | 0.14      | 1.0    | 1.4    | 11.0    |
| groups       | 615.1      | 132.7   | 5.83      | 152.3  | 42.9   | 303.6   |
| lookahead    | 556.6 (bt) | 299.3   | 8.99      | 170.2  | 42.1   | —       |
| backref      | 491.1 (bt) | 137.2   | 17.46     | 121.5  | 181.7  | —       |
| pathological | **0.01**   | ERROR   | 27.5      | 291.5  | 0.01   | 0.01    |

(bt) = zregex backtracking engine; everything else runs on the Pike VM.
"pathological" is `(a+)+$` against `"a"*22 + "!"`: PCRE2's interpreter aborts
with a match-limit error and Python backtracks for ~300ms, while the Pike VM
answers in microseconds regardless of input — the design's core guarantee.

Honest reading of the rest: zregex v1 has a flat ~165 ms floor (~25 MB/s) on
this corpus because the Pike VM seeds a thread at every input position and has
no literal prefilter (the memchr-style skip every other engine here uses), and
per-match capture allocation makes `groups` expensive. Costs are flat and
predictable — near-identical times across easy and hard patterns — where
backtrackers swing wildly in both directions.
