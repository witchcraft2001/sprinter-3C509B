#!/usr/bin/env perl
use strict;
use warnings;

my ($path, $tag, $index) = @ARGV;
die "usage: $0 sprinter.cfg device-tag interface-index\n"
    unless defined $index && $index =~ /^\d+$/ && $tag =~ /^:isa[01]:3c509b$/;
open my $in, '<', $path or die "cannot read $path: $!\n";
my $xml = do { local $/; <$in> };
close $in;
die "network section already present in template\n" if $xml =~ /<network>/;
my $node = qq{        <network>\n            <device tag="$tag" interface="$index" />\n        </network>\n};
die "cannot find system close in $path\n" unless $xml =~ s{(\s*</system>)}{\n$node$1};
open my $out, '>', $path or die "cannot write $path: $!\n";
print {$out} $xml;
close $out or die "cannot close $path: $!\n";
