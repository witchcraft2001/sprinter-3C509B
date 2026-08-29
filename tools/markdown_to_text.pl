#!/usr/bin/env perl
use strict;
use warnings;

my $in_fence = 0;
while (my $line = <>) {
    $line =~ s/\r?\n\z//;
    if ($line =~ /^\s*```/) {
        $in_fence = !$in_fence;
        next;
    }
    if (!$in_fence) {
        $line =~ s/^#{1,6}\s+//;
        $line =~ s/!\[([^]]*)\]\([^)]+\)/$1/g;
        $line =~ s/\[([^]]+)\]\(([^)]+)\)/$1 ($2)/g;
        $line =~ s/`([^`]*)`/$1/g;
        $line =~ s/\*\*([^*]+)\*\*/$1/g;
        $line =~ s/__([^_]+)__/$1/g;
    }
    print "$line\n";
}
