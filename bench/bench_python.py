# SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
# SPDX-License-Identifier: MIT
"""Python `re` benchmark. Same protocol: impl \t name \t best_ms \t count."""
import re
import sys
import time

PATHO = "a" * 22 + "!"

CASES = [
    ("literal", r"synchronization", 0, 5, None),
    ("ci_literal", r"SYNCHRONIZATION", re.I, 5, None),
    ("date", r"\d{4}-\d{2}-\d{2}", 0, 5, None),
    ("email", r"[\w.]+@[\w.]+", 0, 5, None),
    ("alt", r"error|warning|fatal|panic", 0, 5, None),
    ("ing_suffix", r"[a-z]+ing", 0, 5, None),
    ("spanning", r"ERROR.{0,40}failed", 0, 5, None),
    ("groups", r"(\w+)@([\w.]+)", 0, 5, None),
    ("lookahead", r"\w+(?=@)", 0, 5, None),
    ("backref", r"(\w{3,})-\1", 0, 5, None),
    ("pathological", r"(a+)+$", 0, 1, PATHO),
]

def main(path):
    with open(path) as f:
        corpus = f.read()
    for name, pat, flags, reps, hay in CASES:
        rx = re.compile(pat, flags | re.ASCII)
        text = hay if hay is not None else corpus
        best = float("inf")
        count = 0
        for _ in range(reps):
            t0 = time.perf_counter()
            if name == "pathological":
                count = 1 if rx.search(text) else 0
            else:
                count = sum(1 for _ in rx.finditer(text))
            dt = (time.perf_counter() - t0) * 1000
            best = min(best, dt)
        print("python\t%s\t%.2f\t%d" % (name, best, count), flush=True)

if __name__ == "__main__":
    main(sys.argv[1])
