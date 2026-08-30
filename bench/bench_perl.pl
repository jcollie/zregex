# SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
# SPDX-License-Identifier: MIT
# Perl benchmark. Same protocol: impl \t name \t best_ms \t count.
use strict;
use warnings;
use Time::HiRes qw(time);

my $path = shift or die "usage: $0 <corpus>\n";
open my $fh, '<', $path or die $!;
my $corpus = do { local $/; <$fh> };
my $patho = ('a' x 22) . '!';

my @cases = (
    ["literal",      qr/synchronization/,          5, undef],
    ["ci_literal",   qr/SYNCHRONIZATION/i,         5, undef],
    ["date",         qr/\d{4}-\d{2}-\d{2}/a,       5, undef],
    ["email",        qr/[\w.]+\@[\w.]+/a,           5, undef],
    ["alt",          qr/error|warning|fatal|panic/, 5, undef],
    ["ing_suffix",   qr/[a-z]+ing/,                5, undef],
    ["spanning",     qr/ERROR.{0,40}failed/,       5, undef],
    ["groups",       qr/(\w+)\@([\w.]+)/a,          5, undef],
    ["lookahead",    qr/\w+(?=\@)/a,                5, undef],
    ["backref",      qr/(\w{3,})-\1/a,             5, undef],
    ["pathological", qr/(a+)+$/,                   1, $patho],
);

for my $case (@cases) {
    my ($name, $rx, $reps, $hay) = @$case;
    my $text = defined $hay ? $hay : $corpus;
    my ($best, $count) = (9e18, 0);
    for (1 .. $reps) {
        my $t0 = time;
        my $c = 0;
        if ($name eq 'pathological') {
            $c = ($text =~ $rx) ? 1 : 0;
        } else {
            $c++ while $text =~ /$rx/g;
        }
        my $dt = (time - $t0) * 1000;
        $best = $dt if $dt < $best;
        $count = $c;
    }
    printf "perl\t%s\t%.2f\t%d\n", $name, $best, $count;
}
