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
backtracker, and the x86-64 JIT with SSE2 run scanning):

| benchmark    | zregex          | pcre2   | pcre2-jit | python | perl   | posix   |
|--------------|----------------:|--------:|----------:|-------:|-------:|--------:|
| literal      | 1.8 (jit)       | 4.5     | 0.17      | 1.9    | 1.7    | 6.5     |
| ci_literal   | 2.9 (jit)       | 1921.8  | 0.19      | 16.8   | 2.7    | 8.3     |
| date         | 2.2 (jit)       | 2.7     | 0.61      | 41.7   | 5.1    | 245.5   |
| email        | 26.4 (dfa)      | 83.0    | 5.96      | 88.7   | 39.5   | 240.5   |
| alt          | 12.1 (jit)      | 29.6    | 4.81      | 22.9   | 17.4   | 285.7   |
| ing_suffix   | 39.9 (dfa)      | 201.8   | 6.93      | 64.3   | 55.1   | 1006.0  |
| spanning     | **0.09** (jit)  | 0.12    | 0.14      | 1.0    | 1.4    | 10.2    |
| groups       | 29.2 (dfa)      | 130.3   | 5.66      | 149.0  | 41.8   | 290.2   |
| lookahead    | **5.5** (jit)   | 295.8   | 8.70      | 167.7  | 40.7   | —       |
| backref      | **7.5** (jit)   | 133.3   | 17.06     | 124.7  | 180.2  | —       |
| pathological | 0.26 (jit→pike) | ERROR   | 26.5      | 279.8  | 0.01   | 0.01    |

The parenthesised engine is the one `Regex.engine` selected. zregex is
fastest of the interpreted engines on eight of eleven rows, and beats PCRE2's
JIT outright on `spanning`, `lookahead`, and `backref`.
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
Together those took `lookahead` to 5.5 ms and `backref` to 7.5, both now
faster than PCRE2's JIT. Finally the JIT compiles patterns to
native code, taking over wherever few start positions get tried — literals,
digits, alternations, and everything behind a backreference or lookaround
(`backref`: 49 -> 16 ms, `lookahead`: 63 -> 15). Dense scans stay on the lazy
DFA, which reads each byte once where a backtracker re-reads it. The JIT
budget is what `pathological` shows: `(a+)+$` spends a bounded number of
native steps, bails, and the Pike VM answers — 0.26 ms instead of PCRE2's
hard error or Python's 283 ms. Costs remain flat and predictable where
backtrackers swing wildly in both directions.
