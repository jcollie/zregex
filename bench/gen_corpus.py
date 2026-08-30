# SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
# SPDX-License-Identifier: MIT
"""Generate a deterministic ~4MB log-like corpus for the regex benchmarks."""
import random
import sys

TARGET = 4 * 1024 * 1024

WORDS = (
    "the quick brown fox jumps over lazy dog server client request response "
    "connection database index query transaction commit rollback buffer cache "
    "thread process socket packet stream channel worker queue task scheduler "
    "running parsing loading writing reading processing connecting handling "
    "distributed consensus replication snapshot compaction checkpoint memory "
    "allocation garbage collector latency throughput bandwidth protocol "
    "handshake timeout retry backoff circuit breaker gateway proxy balancer "
    "kernel module driver interrupt signal descriptor inode filesystem mount "
    "container cluster node region zone shard partition replica leader follower"
).split()

USERS = ["alice", "bob", "carol", "dave", "erin", "frank", "grace", "heidi"]
HOSTS = ["example.org", "test.net", "mail.example.com", "ocjtech.us", "localhost"]
LEVELS = ["info", "debug", "warning", "error", "trace", "notice"]

def main(path):
    rng = random.Random(42)
    out = []
    size = 0
    n = 0
    while size < TARGET:
        n += 1
        parts = []
        # Occasional date-stamped line.
        if rng.random() < 0.3:
            parts.append("2026-%02d-%02d" % (rng.randint(1, 12), rng.randint(1, 28)))
        parts.append(rng.choice(LEVELS))
        for _ in range(rng.randint(6, 14)):
            r = rng.random()
            if r < 0.02:
                parts.append("%s@%s" % (rng.choice(USERS), rng.choice(HOSTS)))
            elif r < 0.03:
                w = rng.choice(WORDS)
                parts.append("%s-%s" % (w, w))  # backref fodder
            else:
                parts.append(rng.choice(WORDS))
        if rng.random() < 0.01:
            parts.append("ERROR operation %s failed" % rng.choice(WORDS))
        if rng.random() < 0.002:
            parts.append("synchronization")
        line = " ".join(parts) + "\n"
        out.append(line)
        size += len(line)
    data = "".join(out)
    with open(path, "w") as f:
        f.write(data)
    print("wrote %s: %d bytes, %d lines" % (path, len(data), n), file=sys.stderr)

if __name__ == "__main__":
    main(sys.argv[1])
