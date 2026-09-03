# SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
# SPDX-License-Identifier: MIT
"""Merge results.tsv into a comparison table (ms, best of N; MB/s for corpus scans)."""
import os
import sys

BENCH_ORDER = ["literal", "ci_literal", "date", "email", "alt", "ing_suffix",
               "spanning", "groups", "lookahead", "backref", "pathological"]

def main(results, corpus):
    size_mb = os.path.getsize(corpus) / 1e6
    rows = {}
    impls = []
    counts = {}
    preferred = ["zregex/pike", "zregex/backtrack", "pcre2", "pcre2-jit",
                 "python", "perl", "posix"]
    for line in open(results):
        # The Zig harness leads with a `# target=...` line for the CI tables.
        if line.startswith("#") or not line.strip():
            continue
        impl, name, ms, count = line.rstrip("\n").split("\t")
        if impl not in impls:
            impls.append(impl)
        rows.setdefault(name, {})[impl] = ms
        counts.setdefault(name, {})[impl] = count

    impls.sort(key=lambda i: preferred.index(i) if i in preferred else 99)
    print("corpus: %.1f MB; times in ms (best of N); lower is better" % size_mb)
    header = ["benchmark"] + impls + ["matches"]
    widths = [max(12, len(h) + 2) for h in header]
    print("".join(h.ljust(w) for h, w in zip(header, widths)))
    print("".join("-" * (w - 1) + " " for w in widths))
    for name in BENCH_ORDER:
        if name not in rows:
            continue
        cells = [name]
        for impl in impls:
            cells.append(rows[name].get(impl, "-"))
        cnts = {c for c in counts[name].values() if c != "-"}
        cells.append("/".join(sorted(cnts)) if len(cnts) > 1 else (cnts.pop() if cnts else "-"))
        print("".join(str(c).ljust(w) for c, w in zip(cells, widths)))

if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2])
