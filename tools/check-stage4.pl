#!/usr/bin/env perl
use strict;
use warnings;

my ($root) = @ARGV;
die "usage: $0 ROOT\n" unless defined $root;

my @relative = qw(
    src/apps/el3reg.asm src/lib/el3.asm src/lib/el3_regs.asm
    src/lib/el3_io.asm src/lib/isa.asm src/include/el3.inc
    src/include/memory.inc src/include/sprinter.inc
);
my $source = '';
for my $relative (@relative) {
    open my $fh, '<', "$root/$relative" or die "cannot read $relative: $!\n";
    $source .= do { local $/; <$fh> };
    close $fh;
}

die "Stage 4 executable/core depends on CTC, FRAMES, RTC or SysTime\n"
    if $source =~ /CTC|FRAMES|RTC|SysTime/i;
die "EEPROM write/erase API is forbidden\n"
    if $source =~ /^\s*(?:EEPROM_(?:WRITE|ERASE)|EL3_ID_EEPROM_(?:WRITE|ERASE))\b/mi;
die "IRQ callback/routing is forbidden\n"
    if $source =~ /irq\d*_callback|irq_callback|IRQ_ROUTE/i;
die "CYCLES21 quantum contract is incomplete\n"
    unless $source =~ /EL3_CYCLE_COUNT\s+EQU\s+808/i
        && $source =~ /EL3_WAIT_QUANTA\s+EQU\s+100/i
        && $source =~ /DEC\s+BC\s*\n\s*LD\s+A,B\s*\n\s*OR\s+C\s*\n\s*JR\s+NZ,/i;
die "EL3_LAST_TICKS is not a 16-bit waitq field\n"
    unless $source =~ /EL3_LAST_TICKS\s+EQU[^\n]*; word, CYCLES21 wait quanta/i;
die "Stage 4 stable error codes are missing\n"
    unless $source =~ /EL3_ERR_CMD_TIMEOUT\s+EQU\s+9/i
        && $source =~ /EL3_ERR_INIT_VERIFY\s+EQU\s+10/i
        && $source =~ /EL3_ERR_BAD_WINDOW\s+EQU\s+11/i;
for my $routine (qw(READ8 WRITE8 READ16 WRITE16 CMD WAIT_CIP SELECT_WINDOW
                    RESET_GLOBAL RESET_RX RESET_TX INIT DONE SNAPSHOT)) {
    die "public EL3 routine is missing: $routine\n"
        unless $source =~ /^$routine\s*$/m;
}
die "snapshot v1/60 contract is missing\n"
    unless $source =~ /EL3_SNAPSHOT_VERSION\s+EQU\s+1/i
        && $source =~ /EL3_SNAPSHOT_LENGTH\s+EQU\s+60/i
        && $source =~ /EL3_SNAP_COUNT_FRAME\s+EQU\s+54/i;
die "EL3REG CLI/timer/result contract is missing\n"
    unless $source =~ /Usage: EL3REG .*\[-n 1\.\.100\]/
        && $source =~ /TIMER=CYCLES21/
        && $source =~ /waitq=/
        && $source =~ /RESULT OK\0|RESULT OK"/;
die "EL3REG failure diagnostics are incomplete\n"
    unless $source =~ /target=CYCLES21/
        && $source =~ /MSG_ERROR_SLOT/
        && $source =~ /MSG_ERROR_IDPORT/
        && $source =~ /MSG_ERROR_BASE/
        && $source =~ /MSG_ERROR_COMMAND/
        && $source =~ /MSG_VERIFY_FIELD/
        && $source =~ /MSG_VERIFY_ACTUAL/
        && $source =~ /MSG_VERIFY_EXPECTED/
        && $source =~ /SAVE_DIAGNOSTICS/
        && $source =~ /RESTORE_DIAGNOSTICS/;
die "INIT_VERIFY field/actual/expected diagnostics are missing\n"
    unless $source =~ /EL3_VERIFY_READ_ZERO\s+EQU\s+5/i
        && $source =~ /EL3_VERIFY_EXPECTED/
        && $source =~ /EL3_VERIFY_ACTUAL/
        && $source =~ /CLEAR_VERIFY_DIAGNOSTICS/;

open my $provider, '<', "$root/src/lib/el3_io.asm" or die $!;
my $provider_text = do { local $/; <$provider> };
close $provider;
die "provider READ16 is not exact low/high ISA8 order\n"
    unless $provider_text =~ /LD\s+E,\(HL\)\s*\n\s*INC\s+HL\s*\n\s*LD\s+D,\(HL\)/i;
die "provider WRITE16 is not exact low/high ISA8 order\n"
    unless $provider_text =~ /LD\s+\(HL\),E\s*\n\s*INC\s+HL\s*\n\s*LD\s+\(HL\),D/i;

open my $core, '<', "$root/src/lib/el3_regs.asm" or die $!;
my $core_text = do { local $/; <$core> };
close $core;
die "register core bypasses the EL3IO provider\n" if $core_text =~ /\@ISA\./;
die "DSS call is reachable from EL3 register/provider code\n"
    if ($core_text . $provider_text) =~ /RST\s+DSS|\@CONSOLE\./i;
open my $discovery, '<', "$root/src/lib/el3.asm" or die $!;
my $discovery_text = do { local $/; <$discovery> };
close $discovery;
open my $isa, '<', "$root/src/lib/isa.asm" or die $!;
my $isa_text = do { local $/; <$isa> };
close $isa;
die "DSS/console call is reachable while low-level ISA code may own the window\n"
    if ($core_text . $provider_text . $discovery_text . $isa_text)
        =~ /RST\s+DSS|\@CONSOLE\./i;
die "INIT does not program the polling masks/filter/threshold contract\n"
    unless $core_text =~ /EL3_CMD_SET_INTR_MASK/
        && $core_text =~ /EL3_CMD_SET_READ_ZERO\s*\|\s*EL3_MASK_READ_ZERO/
        && $core_text =~ /EL3_CMD_SET_RX_FILTER\s*\|\s*EL3_RX_FILTER_POLLING/
        && $core_text =~ /EL3_CMD_SET_RX_EARLY\s*\|\s*EL3_THRESHOLD_DISABLED/
        && $core_text =~ /EL3_CMD_SET_TX_START\s*\|\s*EL3_TX_START_VALUE/
        && $core_text =~ /EL3_W5_RX_EARLY[\s\S]*?LD\s+BC,EL3_THRESHOLD_READBACK/
        && $core_text =~ /EL3_W5_TX_AVAILABLE[\s\S]*?LD\s+BC,EL3_THRESHOLD_READBACK/;

my $path = "$root/build/EL3REG.EXE";
open my $bin, '<:raw', $path or die "cannot read $path: $!\n";
my $data = do { local $/; <$bin> };
close $bin;
my $size = length $data;
die "EL3REG has no executable body\n" if $size <= 128;
die "EL3REG crosses 0xC000\n" if 0x8080 + $size > 0xC000;
die "EL3REG header is invalid\n"
    unless substr($data, 0, 4) eq "EXE\x01"
        && unpack('v', substr($data, 4, 2)) == 0x0080
        && unpack('v', substr($data, 16, 2)) == 0x8100
        && unpack('v', substr($data, 20, 2)) == 0xBFF0;
my $body = substr($data, 128);
my $longest = 0;
while ($body =~ /(\0+)/g) {
    $longest = length($1) if length($1) > $longest;
}
die "EL3REG appears to contain zero-filled runtime BSS ($longest bytes)\n"
    if $longest > 32;

print "Stage 4 host contract: provider split, cycle timeout, polling INIT/DONE, snapshot and EL3REG passed ($size bytes)\n";
