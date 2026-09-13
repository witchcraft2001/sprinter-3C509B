#!/usr/bin/env perl
use strict;
use warnings;

my ($exe_path, $source_path) = @ARGV;
die "usage: $0 HELLO.EXE hello.asm\n" unless defined $source_path;

open my $exe, '<:raw', $exe_path or die "cannot read $exe_path: $!\n";
local $/;
my $data = <$exe>;
close $exe;

my $size = length $data;
die "HELLO.EXE is shorter than its 128-byte DSS header\n" if $size <= 128;
die "HELLO.EXE crosses the 0xC000 boundary\n"
    if 0x8080 + $size > 0xC000;
die "bad DSS signature\n" unless substr($data, 0, 3) eq 'EXE';
die "unexpected DSS EXE header version\n" unless ord(substr($data, 3, 1)) == 1;
die "unexpected DSS size/header word\n"
    unless unpack('v', substr($data, 4, 2)) == 0x0080;
die "reserved DSS header words are not zero\n"
    unless substr($data, 6, 10) eq "\0" x 10;
die "primary entry point is not 0x8100\n"
    unless unpack('v', substr($data, 16, 2)) == 0x8100;
die "secondary entry point is not 0x8100\n"
    unless unpack('v', substr($data, 18, 2)) == 0x8100;
die "initial stack is not 0x8100\n"
    unless unpack('v', substr($data, 20, 2)) == 0x8100;
die "DSS header is not exactly 128 bytes\n"
    unless substr($data, 22, 106) eq "\0" x 106;
die "banner is missing from HELLO.EXE\n"
    unless index($data, "3C509B DEV HELLO v0.1.2\0") >= 128;
die "success marker is missing from HELLO.EXE\n"
    unless index($data, "RESULT OK\0") >= 128;
die "DSS exit sequence does not return status 0\n"
    unless index($data, "\x06\x00\x0e\x41\xd7") >= 128;

my $body = substr($data, 128);
my $longest_zero_run = 0;
while ($body =~ /(\0+)/g) {
    my $run = length $1;
    $longest_zero_run = $run if $run > $longest_zero_run;
}
die "HELLO.EXE appears to contain zero-filled runtime BSS\n"
    if $longest_zero_run > 32;

open my $source, '<', $source_path or die "cannot read $source_path: $!\n";
my $source_text = '';
while (my $line = <$source>) {
    $source_text .= $line;
    $line =~ s/;.*\z//;
    die "NIC/port I/O instruction found in HELLO source: $line"
        if $line =~ /^\s*(?:IN|INI|INIR|IND|INDR|OUT|OUTI|OTIR|OUTD|OTDR)\b/i;
}
close $source;
die "HELLO source does not place its DSS header at 0x8080\n"
    unless $source_text =~ /^\s*ORG\s+0x8080\s*$/mi;
die "HELLO source does not place code at 0x8100\n"
    unless $source_text =~ /^\s*ORG\s+0x8100\s*$/mi;

print "HELLO.EXE: DSS header, entry, boundary, size ($size bytes), BSS, and no-I/O checks passed\n";
