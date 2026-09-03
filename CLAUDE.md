# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

zregex is a regular expression library for Zig, with PCRE semantics as its
specification. It targets Zig 0.16.0 exactly.

## Environment

The toolchain lives in the Nix dev shell, not on PATH. Prefix build commands
with `nix develop --command`, e.g. `nix develop --command zig build test`. The
shell provides `zig_0_16`, `qemu` (for the aarch64 tests), `reuse`, and
`pinact`.

## Commands

- `zig build test` — the full suite, including thousands of seeded differential
  fuzz cases every run.
- `zig build test -Dfuzz-cases=N -Dfuzz-seed=M` — a longer differential soak;
  walk the seed to reach patterns one stream never produces. `-Dfuzz-alloc-cases=N`
  scales the allocation-failure test, which reruns cases once per allocation.
- `zig build test -fqemu -Dtarget=aarch64-linux` — runs the suite (and any
  `-Dfuzz-cases`) on the aarch64 JIT under emulation. The x86-64 host never
  executes the a64/NEON backend otherwise; do this after any change to
  `src/jit/codegen_a64.zig` or `src/jit/a64.zig`.
- `zig build check -Dtarget=<t>` — compiles everything for a target without
  running it, through the build system so per-target module wiring applies.
  Cross-target coverage: aarch64-linux, x86_64-windows, aarch64-macos.
- `zig build oracle -- [cases] [seed]` — differential test against PCRE2, which
  the library builds from source itself (pinned in `build.zig.zon`). Modes:
  `-- N seed` (generated sweep), `--corpus <pcre2-src>/testdata` (PCRE2's own
  test patterns), `--corpus-mutate <dir> N seed` (seeded edits of those),
  `--case '<pat>' '<hay>' [ims]` and `--engines '<pat>' '<hay>'` (single-case
  reducers for shrinking). The generated sweep compares three ways: leftmost
  match, every match, and searches from an offset; the corpus and
  corpus-mutate modes compare the first two.
- `zig build bench-run -- --builtin` — benchmark against an in-memory corpus.
  `./bench/run.sh` runs the full comparative suite (PCRE2, Python, Perl, POSIX).
- `zig fmt --check build.zig src bench tools` and `reuse lint` — CI gates.

There is no single-test filter wired up; narrow by editing the seed/count of
the fuzz tests, or by running the oracle's single-case modes.

## Architecture

**One compiled program, four engines.** `Regex.compile` (src/regex.zig) parses
to an AST (src/parser.zig), then compiles to a flat bytecode program
(src/compiler.zig). Which engine runs is decided at compile time and reported
by `Regex.engine`:

- **Pike VM** (src/pike.zig) — breadth-first NFA simulation with captures,
  linear time.
- **Lazy DFA** (src/dfa.zig) — a memoized Pike VM that finds the match *span*
  only; the Pike VM is rerun on a small window to extract captures. Sits in
  front of the Pike VM when the byte prefilter is weak.
- **Backtracker** (src/backtrack.zig) — the only engine that runs `backref` and
  `look`, plus a fused `rep` the compiler emits only for it. Backref-aware
  memoization makes classic ReDoS polynomial.
- **JIT** (src/jit.zig, src/jit/) — compiles the program to native code on
  x86-64 (SSE2/AVX2) and aarch64 (NEON); bails to an interpreter when its
  budget runs out. `src/jit/codegen_{x64,a64}.zig` are the two backends;
  `src/jit/{x64,a64}.zig` are the assemblers; `src/jit/runtime.zig` holds
  helpers both backends call; `src/jit/mem.zig` maps executable memory
  (mprotect on Linux, MAP_JIT on Darwin).

`p.has_backref or p.has_look` routes a pattern to the backtracker; everything
else can use the Pike VM or DFA. The JIT competes with whichever fallback the
pattern picked and takes over only when it wins. **A pattern always has a
correct fallback**: the JIT and DFA hand off to an interpreter rather than
producing a wrong or slow answer.

**Parser writes into caller-provided buffers**, so the identical code runs at
runtime (allocator) and comptime (fixed arrays); this is what makes
`Regex.compileComptime` work. `parser.bufferSizes` gives worst-case sizes.

**Semantics follow PCRE, deliberately.** When zregex and PCRE disagree, change
zregex to match PCRE — including behavior PCRE shares with no one and cases
where Python or RE2 side with zregex. The sole exceptions are where PCRE2
contradicts itself (a backreference to the enclosing group) and where following
PCRE would inherit a denial-of-service (the step budget is per whole call, not
per start position as PCRE's match limit is). Unicode simple case folding under
`(?i)`; ASCII-only `\d`/`\w`/`\s`/`\b`. Case folding is resolved at parse time —
a caseless class is closed over its case-equivalents and emitted with `ci` off —
so no engine folds while matching.

**Resource bounds are load-bearing, not incidental.** Adversarial patterns and
haystacks return a clean error, never a hang, crash, or runaway allocation:
compile refuses patterns over `max_pattern_len`, programs over `max_insts`, and
guard tables over `max_visited_keys`; matching bounds the backtracker's steps
and scratch, scales the DFA state cap, and compacts Pike capture chains; the
parser builds balanced concat/alt trees so a long flat pattern cannot overflow
the compiler's recursive walk. When touching these paths, preserve the bound.

## Testing discipline

The differential fuzzers and the PCRE2 oracle are the safety net for every
engine change. After changing an engine or the compiler, run the cross-engine
soak across several seeds and the oracle; after changing a JIT backend, also run
`-fqemu` for aarch64. A found bug gets a regression test in src/tests.zig,
named for how it was found. The known-5 corpus disagreements are the
enclosing-group-backreference family PCRE2 itself is inconsistent about — new
disagreements there are expected, anywhere else is a bug.

## Git

Push only to `origin` (git.ocjtech.us), which mirrors to GitHub
(github.com/jcollie/zregex) on its own — never push to GitHub separately.
Commit messages here are prose explaining why a change was made and how it was
verified, not bullet lists.
