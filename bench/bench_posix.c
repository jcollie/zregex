// SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT
// glibc POSIX ERE benchmark. Same protocol: impl \t name \t best_ms \t count.
// POSIX ERE has no \w/\d shorthands, lookaround, or backrefs; patterns are
// translated where possible and unsupported benchmarks are skipped.
#include <regex.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

typedef struct {
    const char *name;
    const char *pattern;
    int cflags;
    int reps;
    const char *haystack; // NULL = corpus
} Case;

static const char patho[] = "aaaaaaaaaaaaaaaaaaaaaa!";

static const Case cases[] = {
    {"literal", "synchronization", 0, 5, NULL},
    {"ci_literal", "SYNCHRONIZATION", REG_ICASE, 5, NULL},
    {"date", "[0-9]{4}-[0-9]{2}-[0-9]{2}", 0, 5, NULL},
    {"email", "[[:alnum:]_.]+@[[:alnum:]_.]+", 0, 5, NULL},
    {"alt", "error|warning|fatal|panic", 0, 5, NULL},
    {"ing_suffix", "[a-z]+ing", 0, 5, NULL},
    {"spanning", "ERROR.{0,40}failed", 0, 5, NULL},
    {"groups", "([[:alnum:]_]+)@([[:alnum:]_.]+)", 0, 5, NULL},
    {"pathological", "(a+)+$", 0, 1, patho},
};

static double now_ms(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec * 1e3 + ts.tv_nsec / 1e6;
}

int main(int argc, char **argv) {
    if (argc != 2) { fprintf(stderr, "usage: %s <corpus>\n", argv[0]); return 1; }
    FILE *f = fopen(argv[1], "rb");
    if (!f) { perror("open"); return 1; }
    fseek(f, 0, SEEK_END);
    long len = ftell(f);
    fseek(f, 0, SEEK_SET);
    char *corpus = malloc(len + 1);
    if (fread(corpus, 1, len, f) != (size_t)len) { perror("read"); return 1; }
    corpus[len] = 0;
    fclose(f);

    for (size_t i = 0; i < sizeof(cases) / sizeof(cases[0]); i++) {
        const Case *c = &cases[i];
        regex_t re;
        int rc = regcomp(&re, c->pattern, REG_EXTENDED | REG_NEWLINE | c->cflags);
        if (rc) { fprintf(stderr, "regcomp failed: %s\n", c->name); continue; }
        const char *text = c->haystack ? c->haystack : corpus;
        double best = 1e18;
        long count = 0;
        for (int r = 0; r < c->reps; r++) {
            double t0 = now_ms();
            long cnt = 0;
            size_t off = 0;
            int eflags = 0;
            regmatch_t pm[3];
            while (regexec(&re, text + off, 3, pm, eflags) == 0) {
                cnt++;
                size_t adv = pm[0].rm_eo > pm[0].rm_so ? (size_t)pm[0].rm_eo
                                                       : (size_t)pm[0].rm_eo + 1;
                off += adv;
                eflags = REG_NOTBOL;
            }
            double dt = now_ms() - t0;
            if (dt < best) best = dt;
            count = cnt;
        }
        printf("posix\t%s\t%.2f\t%ld\n", c->name, best, count);
        fflush(stdout);
        regfree(&re);
    }
    free(corpus);
    return 0;
}
