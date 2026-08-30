#!/usr/bin/env bash
# SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
# SPDX-License-Identifier: MIT
# Runs every available benchmark harness and prints a merged comparison table.
set -euo pipefail
cd "$(dirname "$0")/.."

OUT=bench/out
CORPUS=$OUT/corpus.txt
mkdir -p "$OUT"

[ -f "$CORPUS" ] || python3 bench/gen_corpus.py "$CORPUS"

echo "building harnesses..." >&2
zig build bench
zig cc -O2 -o "$OUT/bench-posix" bench/bench_posix.c

PCRE2_DEV="${PCRE2_DEV:-}"
PCRE2_LIB="${PCRE2_LIB:-}"
if [ -z "$PCRE2_DEV" ] && command -v nix >/dev/null; then
    if paths=$(nix build --no-link --print-out-paths nixpkgs#pcre2.dev nixpkgs#pcre2.out 2>/dev/null); then
        PCRE2_DEV=$(echo "$paths" | sed -n 1p)
        PCRE2_LIB=$(echo "$paths" | sed -n 2p)/lib
    fi
fi
have_pcre2=0
if [ -n "$PCRE2_DEV" ]; then
    zig cc -O2 -I"$PCRE2_DEV/include" -L"$PCRE2_LIB" -lpcre2-8 \
        -Wl,-rpath,"$PCRE2_LIB" -o "$OUT/bench-pcre2" bench/bench_pcre2.c
    have_pcre2=1
fi

echo "running (each row = best of N reps)..." >&2
# Each harness writes its own file: the Zig harness uses positional writes,
# which do not mix with other processes sharing one redirected fd.
./zig-out/bin/bench-zregex "$CORPUS" > "$OUT/r-zregex.tsv"
"$OUT/bench-posix" "$CORPUS" > "$OUT/r-posix.tsv"
python3 bench/bench_python.py "$CORPUS" > "$OUT/r-python.tsv"
perl bench/bench_perl.pl "$CORPUS" > "$OUT/r-perl.tsv"
if [ "$have_pcre2" = 1 ]; then
    "$OUT/bench-pcre2" "$CORPUS" > "$OUT/r-pcre2.tsv"
else
    : > "$OUT/r-pcre2.tsv"
fi
cat "$OUT"/r-*.tsv > "$OUT/results.tsv"

python3 bench/report.py "$OUT/results.tsv" "$CORPUS"
