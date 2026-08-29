#!/usr/bin/env perl
use strict;
use warnings;

my $path = shift or die "usage: $0 FILE\n";
open my $fh, '<:raw', $path or die "cannot read $path: $!\n";
local $/;
my $data = <$fh>;
close $fh;

die "$path contains LF without CR\n" if $data =~ /(?<!\r)\n/;
die "$path contains CR without LF\n" if $data =~ /\r(?!\n)/;
die "$path is empty\n" unless length $data;

print "$path: CRLF check passed\n";
