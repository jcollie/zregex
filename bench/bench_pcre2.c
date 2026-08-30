// SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT
// PCRE2 benchmark (interpreted and JIT). Protocol: impl \t name \t best_ms \t count.
#define PCRE2_CODE_UNIT_WIDTH 8
#include <pcre2.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

typedef struct {
    const char *name;
    const char *pattern;
    uint32_t options;
    int reps;
    const char *haystack;
} Case;

static const char patho[] = "aaaaaaaaaaaaaaaaaaaaaa!";

static const Case cases[] = {
    {"literal", "synchronization", 0, 5, NULL},
    {"ci_literal", "SYNCHRONIZATION", PCRE2_CASELESS, 5, NULL},
    {"date", "\\d{4}-\\d{2}-\\d{2}", 0, 5, NULL},
    {"email", "[\\w.]+@[\\w.]+", 0, 5, NULL},
    {"alt", "error|warning|fatal|panic", 0, 5, NULL},
    {"ing_suffix", "[a-z]+ing", 0, 5, NULL},
    {"spanning", "ERROR.{0,40}failed", 0, 5, NULL},
    {"groups", "(\\w+)@([\\w.]+)", 0, 5, NULL},
    {"lookahead", "\\w+(?=@)", 0, 5, NULL},
    {"backref", "(\\w{3,})-\\1", 0, 5, NULL},
    {"pathological", "(a+)+$", 0, 1, patho},
};

static double now_ms(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec * 1e3 + ts.tv_nsec / 1e6;
}

static void run(const char *impl, int jit, const char *corpus, size_t len) {
    for (size_t i = 0; i < sizeof(cases) / sizeof(cases[0]); i++) {
        const Case *c = &cases[i];
        int errcode;
        PCRE2_SIZE erroff;
        pcre2_code *re = pcre2_compile((PCRE2_SPTR)c->pattern, PCRE2_ZERO_TERMINATED,
                                       c->options, &errcode, &erroff, NULL);
        if (!re) { fprintf(stderr, "compile failed: %s\n", c->name); continue; }
        if (jit && pcre2_jit_compile(re, PCRE2_JIT_COMPLETE) != 0) {
            fprintf(stderr, "jit failed: %s\n", c->name);
            pcre2_code_free(re);
            continue;
        }
        pcre2_match_data *md = pcre2_match_data_create_from_pattern(re, NULL);
        const char *text = c->haystack ? c->haystack : corpus;
        size_t tlen = c->haystack ? strlen(c->haystack) : len;
        double best = 1e18;
        long count = 0;
        int errored = 0;
        for (int r = 0; r < c->reps && !errored; r++) {
            double t0 = now_ms();
            long cnt = 0;
            PCRE2_SIZE off = 0;
            for (;;) {
                int rc = pcre2_match(re, (PCRE2_SPTR)text, tlen, off, 0, md, NULL);
                if (rc == PCRE2_ERROR_NOMATCH) break;
                if (rc < 0) { errored = rc; break; }
                cnt++;
                PCRE2_SIZE *ov = pcre2_get_ovector_pointer(md);
                off = ov[1] > ov[0] ? ov[1] : ov[1] + 1;
                if (off > tlen) break;
            }
            double dt = now_ms() - t0;
            if (dt < best) best = dt;
            count = cnt;
        }
        if (errored)
            printf("%s\t%s\tERR(%d)\t-\n", impl, c->name, errored);
        else
            printf("%s\t%s\t%.2f\t%ld\n", impl, c->name, best, count);
        fflush(stdout);
        pcre2_match_data_free(md);
        pcre2_code_free(re);
    }
}

int main(int argc, char **argv) {
    if (argc != 2) { fprintf(stderr, "usage: %s <corpus>\n", argv[0]); return 1; }
    FILE *f = fopen(argv[1], "rb");
    fseek(f, 0, SEEK_END);
    long len = ftell(f);
    fseek(f, 0, SEEK_SET);
    char *corpus = malloc(len);
    if (fread(corpus, 1, len, f) != (size_t)len) { perror("read"); return 1; }
    fclose(f);
    run("pcre2", 0, corpus, len);
    run("pcre2-jit", 1, corpus, len);
    free(corpus);
    return 0;
}
