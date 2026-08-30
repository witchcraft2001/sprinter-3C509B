#!/usr/bin/env perl
use strict;
use warnings;

my ($root, @apps) = @ARGV;
die "usage: $0 ROOT NAME...\n" unless defined $root && @apps;

for my $name (@apps) {
    my $path = "$root/build/$name.EXE";
    open my $fh, '<:raw', $path or die "cannot read $path: $!\n";
    local $/;
    my $data = <$fh>;
    close $fh;
    my $size = length $data;
    die "$name has no executable body\n" if $size <= 128;
    die "$name crosses 0xC000\n" if 0x8080 + $size > 0xC000;
    die "$name has a bad DSS signature/version\n"
        unless substr($data, 0, 4) eq "EXE\x01";
    die "$name has a bad header size word\n"
        unless unpack('v', substr($data, 4, 2)) == 0x0080;
    die "$name has nonzero reserved header words\n"
        unless substr($data, 6, 10) eq "\0" x 10;
    die "$name has a bad primary entry\n"
        unless unpack('v', substr($data, 16, 2)) == 0x8100;
    die "$name has a bad secondary entry\n"
        unless unpack('v', substr($data, 18, 2)) == 0x8100;
    die "$name has a bad stack pointer\n"
        unless unpack('v', substr($data, 20, 2)) == 0xBFF0;
    die "$name header is not exactly 128 bytes\n"
        unless substr($data, 22, 106) eq "\0" x 106;
    die "$name lacks RESULT OK\n" unless index($data, "RESULT OK\0") >= 128;
    die "$name lacks RESULT FAIL\n" unless index($data, "RESULT FAIL code=\0") >= 128;
    my $body = substr($data, 128);
    my $longest = 0;
    while ($body =~ /(\0+)/g) {
        $longest = length($1) if length($1) > $longest;
    }
    die "$name appears to contain zero-filled runtime BSS ($longest bytes)\n"
        if $longest > 32;
    print "$name.EXE: DSS header, boundary, runtime-BSS and result markers passed ($size bytes)\n";
}

my @sources = qw(
    src/apps/el3info.asm src/apps/el3eep.asm src/apps/isaprobe.asm
    src/lib/el3.asm src/lib/isa.asm src/include/el3.inc
    src/include/sprinter.inc
);
my $source = '';
for my $relative (@sources) {
    open my $fh, '<', "$root/$relative" or die "cannot read $relative: $!\n";
    $source .= do { local $/; <$fh> };
    close $fh;
}
die "EEPROM erase/write API is forbidden\n"
    if $source =~ /^\s*(?:EEPROM_(?:WRITE|ERASE)|EL3_ID_EEPROM_(?:WRITE|ERASE))\b/mi;
die "IRQ callback/routing is forbidden\n"
    if $source =~ /irq\d*_callback|irq_callback|IRQ_ROUTE/i;
die "ID EEPROM READ command is missing\n"
    unless $source =~ /EL3_ID_EEPROM_READ\s+EQU\s+0x80/i;
die "finite timer error is missing\n"
    unless $source =~ /EL3_ERR_TIMER/ && $source =~ /WAIT_FRAME_TRANSITIONS/;
die "Stage 3 must not use the Spectrum FRAMES variable as a DSS clock\n"
    if $source =~ /\(\s*FRAMES\s*\)/i;
die "read-only DSS CTC timer is missing\n"
    unless $source =~ /CTC_CHANNEL0\s+EQU\s+0x10/i
        && $source =~ /IN\s+A,\(CTC_CHANNEL0\)/i;
die "Stage 3 must not reprogram DSS CTC channel 0\n"
    if $source =~ /OUT\s+\(CTC_CHANNEL0\)/i;

open my $el3, '<', "$root/src/lib/el3.asm" or die $!;
my $el3_text = do { local $/; <$el3> };
close $el3;
die "READ16 is not low-byte then immediately high-byte\n"
    unless $el3_text =~ /LD\s+E,\(HL\)\s*\n\s*INC\s+HL\s*\n\s*LD\s+D,\(HL\)/i;
die "WRITE16 is not low-byte then immediately high-byte\n"
    unless $el3_text =~ /LD\s+\(HL\),E\s*\n\s*INC\s+HL\s*\n\s*LD\s+\(HL\),D/i;

open my $isa, '<', "$root/src/lib/isa.asm" or die $!;
my $isa_text = do { local $/; <$isa> };
close $isa;
my $open_state = index($isa_text, "LD\tA,(IS_OPEN)");
my $open_iff = index($isa_text, "LD\tA,I");
die "ISA.OPEN must reject nesting before replacing the saved IFF state\n"
    if $open_state < 0 || $open_iff < 0 || $open_state > $open_iff;

open my $probe, '<', "$root/src/apps/isaprobe.asm" or die $!;
my $probe_text = do { local $/; <$probe> };
close $probe;
die "ISAPROBE help-only guard is missing\n"
    unless $probe_text =~ /PARSE_PROBE/ && $probe_text =~ /PRINT_HELP/;
die "ISAPROBE contains an ISA-window write\n"
    if $probe_text =~ /LD\s+\(HL\),/i;

print "Stage 3 source contract: read-only EEPROM, polling timeout, ISA8 ordering, no IRQ passed\n";
