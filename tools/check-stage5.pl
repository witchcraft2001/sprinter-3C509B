#!/usr/bin/env perl
use strict;
use warnings;

my ($root) = @ARGV;
die "usage: $0 ROOT\n" unless defined $root;

my @relative = qw(
    src/apps/el3lb.asm src/apps/el3reg.asm src/lib/el3_fifo.asm src/lib/el3_regs.asm
    src/lib/el3_io.asm src/lib/isa.asm src/lib/cli.asm
    src/include/el3.inc src/include/memory.inc
    tools/stage5_vectors.asm tools/test-stage5-asm.sh
);
my $source = '';
for my $relative (@relative) {
    open my $fh, '<', "$root/$relative" or die "cannot read $relative: $!\n";
    $source .= do { local $/; <$fh> };
    close $fh;
}

die "Stage 5 depends on CTC, FRAMES, RTC or SysTime\n"
    if $source =~ /CTC|FRAMES|RTC|SysTime/i;
die "EEPROM write/erase API is forbidden\n"
    if $source =~ /^\s*(?:EEPROM_(?:WRITE|ERASE)|EL3_ID_EEPROM_(?:WRITE|ERASE))\b/mi;
die "IRQ callback/routing is forbidden\n"
    if $source =~ /irq\d*_callback|irq_callback|IRQ_ROUTE/i;

for my $pair (
    [TX_TIMEOUT => 12], [TX_ERROR => 13], [RX_TIMEOUT => 14],
    [RX_ERROR => 15], [FRAME_SIZE => 16], [NO_FRAME => 17],
    [NO_MEMORY => 18], [LOOPBACK_VERIFY => 19],
) {
    my ($name, $value) = @$pair;
    die "stable Stage 5 error $name=$value is missing\n"
        unless $source =~ /EL3_ERR_\Q$name\E\s+EQU\s+\Q$value\E\b/i;
}
die "FIFO timing contract is missing\n"
    unless $source =~ /EL3_WAIT_QUANTA\s+EQU\s+100\b/i
        && $source =~ /EL3_FIFO_WAIT_QUANTA\s+EQU\s+1000\b/i
        && $source =~ /EL3_CYCLE_COUNT\s+EQU\s+808\b/i;
for my $routine (qw(SEND_FRAME RX_PENDING READ_FRAME DISCARD_FRAME
                    LOOPBACK_ENABLE LOOPBACK_DISABLE)) {
    die "public Stage 5 routine is missing: $routine\n"
        unless $source =~ /^$routine\s*$/m;
}

open my $core_fh, '<', "$root/src/lib/el3_fifo.asm" or die $!;
my $core = do { local $/; <$core_fh> };
close $core_fh;
die "FIFO core bypasses provider with direct ISA access\n" if $core =~ /\@ISA\./;
die "DSS/console call is reachable from FIFO core\n"
    if $core =~ /RST\s+DSS|\@CONSOLE\./i;
die "TX preamble/required-byte formula is incomplete\n"
    unless $core =~ /TX_EFFECTIVE_LENGTH/
        && $core =~ /TX_REQUIRED_BYTES/
        && $core =~ /OR\s+0x80/i
        && $core =~ /LD\s+BC,4/i
        && $core =~ /CALL\s+\@EL3IO\.FIFO_WRITE/i
        && $core =~ /CALL\s+\@EL3IO\.FIFO_ZERO/i;
die "TX status is not read-peek/write-pop\n"
    unless $core =~ /TX_CLEAR_STALE[\s\S]*?READ8[\s\S]*?EL3_TX_COMPLETE[\s\S]*?WRITE8/
        && $core =~ /TX_WAIT_COMPLETE[\s\S]*?READ8[\s\S]*?TX_COMPLETE_POP[\s\S]*?WRITE8/;
die "bounded TX recovery is incomplete\n"
    unless $core =~ /TX_ATTEMPTS_LEFT/
        && $core =~ /EL3_TX_JABBER\s*\|\s*EL3_TX_UNDERRUN/
        && $core =~ /EL3_TX_MAX_COLLISION/
        && $core =~ /EL3_TX_OVERFLOW/
        && $core =~ /TX_TIMEOUT_TICKS/;
die "TX retransmit is reachable after failed recovery\n"
    unless $core =~ /\.SEND_RESET_RETRY[\s\S]*?CALL\s+TX_RECOVER_RESET\s+JR\s+C,\.SEND_RETURN/
        && $core =~ /\.SEND_ENABLE_RETRY[\s\S]*?CALL\s+TX_RECOVER_ENABLE\s+JR\s+C,\.SEND_RETURN/
        && $core =~ /\.SEND_OVERFLOW[\s\S]*?CALL\s+TX_RECOVER_ENABLE\s+JR\s+C,\.SEND_RETURN/;
die "RX consume contract is incomplete\n"
    unless $core =~ /EL3_RX_INCOMPLETE/
        && $core =~ /BIT\s+6,H/
        && $core =~ /EL3_RX_REQUIRED/
        && $core =~ /FIFO_READ/
        && $core =~ /FIFO_SKIP/
        && $core =~ /RX_DISCARD_CURRENT[\s\S]*?EL3_CMD_RX_DISCARD/;

open my $provider_fh, '<', "$root/src/lib/el3_io.asm" or die $!;
my $provider = do { local $/; <$provider_fh> };
close $provider_fh;
for my $routine (qw(FIFO_WRITE FIFO_ZERO FIFO_READ FIFO_SKIP)) {
    die "production FIFO provider routine is missing: $routine\n"
        unless $provider =~ /^$routine\s*$/m;
}
my ($fifo_provider) = $provider =~ /(FIFO_WRITE[\s\S]*?)(?=; OPEN_REGISTER)/;
die "cannot isolate FIFO provider\n" unless defined $fifo_provider;
die "FIFO provider advances to forbidden high-byte FIFO offset\n"
    if $fifo_provider =~ /INC\s+HL|DEC\s+HL|ADD\s+HL/i;
die "FIFO provider is not fixed at EL3_BASE/+00\n"
    unless $fifo_provider =~ /LD\s+BC,\(EL3_BASE\)[\s\S]*?CALL\s+\@ISA\.MAP_POINTER/i;

open my $regs_fh, '<', "$root/src/lib/el3_regs.asm" or die $!;
my $regs = do { local $/; <$regs_fh> };
close $regs_fh;
die "INIT/DONE do not clear stale controller loopback\n"
    unless $regs =~ /INIT[\s\S]*?CALL\s+LOOPBACK_DISABLE/
        && $regs =~ /DONE[\s\S]*?CALL\s+LOOPBACK_DISABLE/;
die "snapshot ABI/reserved-zero contract changed\n"
    unless $source =~ /EL3_SNAPSHOT_VERSION\s+EQU\s+1/i
        && $source =~ /EL3_SNAPSHOT_LENGTH\s+EQU\s+60/i
        && $regs =~ /EL3_SNAP_RESERVED[\s\S]*?LD\s+HL,0/i;

open my $reg_app_fh, '<', "$root/src/apps/el3reg.asm" or die $!;
my $reg_app = do { local $/; <$reg_app_fh> };
close $reg_app_fh;
die "EL3REG does not initialize the Stage 5 RX context\n"
    unless $reg_app =~ /CLEAR_RUNTIME[\s\S]*?LD\s+\(EL3_LAST_RX_STATUS\),HL[\s\S]*?LD\s+\(EL3_RX_REQUIRED\),HL/;
die "EL3REG restores RX context from the saved command\n"
    if $reg_app =~ /SAVED_COMMAND[\s\S]{0,160}EL3_LAST_RX_STATUS/;

open my $app_fh, '<', "$root/src/apps/el3lb.asm" or die $!;
my $app = do { local $/; <$app_fh> };
close $app_fh;
die "EL3LB CLI contract is missing\n"
    unless $app =~ /Usage: EL3LB \[-v\] \[-s 0\|1\].*\[-n 1\.\.100\]/;
die "EL3LB matrix/burst contract is incomplete\n"
    unless $app =~ /LENGTH_TABLE\s+DW\s+14,42,59,60,61,62,63,1514/
        && $app =~ /CP\s+5/
        && $app =~ /LD\s+B,2[\s\S]*?LD\s+B,10/
        && $app =~ /BURST_SEQUENCE/
        && $app =~ /\.BURST_EXTRA[\s\S]*?EL3_ERR_LOOPBACK_VERIFY/
        && $app =~ /TX_BUFFER\s+EQU\s+0x4000/
        && $app =~ /RX_BUFFER\s+EQU\s+0x4800/;
die "EL3LB matrix failure loses the original error code\n"
    unless $app =~ /\.MATRIX_FAIL\s+LD\s+\(MATRIX_SAVED_ERROR\),A[\s\S]*?LD\s+A,\(MATRIX_SAVED_ERROR\)\s+SCF/;
die "EL3LB RX wait reuses the CIP diagnostic counter as its deadline\n"
    unless $source =~ /EL3LB_WAIT_TICKS/
        && $app =~ /WAIT_RX[\s\S]*?LD\s+\(EL3LB_WAIT_TICKS\),HL[\s\S]*?EL3_FIFO_WAIT_QUANTA/
        && $app =~ /\.WAIT_RX_TIMEOUT[\s\S]*?LD\s+HL,\(EL3LB_WAIT_TICKS\)[\s\S]*?EL3_ERR_RX_TIMEOUT/;
die "EL3LB DSS page lifecycle is incomplete\n"
    unless $app =~ /DSS_GETMEM/
        && $app =~ /DSS_SETWIN1/
        && $app =~ /DSS_FREEMEM/
        && $app =~ /CLEANUP_FAIL[\s\S]*?SAVE_DIAGNOSTICS/
        && $app =~ /LOOPBACK_DISABLE[\s\S]*?\@EL3\.DONE/;
die "EL3LB masks a DSS page release failure\n"
    unless $app =~ /\.SUCCESS_FREE[\s\S]*?CALL\s+FREE_BUFFERS\s+JR\s+NC,\.SUCCESS_CHECK/
        && $app =~ /FREE_BUFFERS[\s\S]*?RST\s+DSS\s+JR\s+C,\.FREE_FAILED[\s\S]*?EL3_ERR_NO_MEMORY/;
die "EL3LB loses the first DONE cleanup error\n"
    unless $app =~ /CALL\s+\@EL3\.DONE\s+JR\s+NC,\.SUCCESS_FREE\s+LD\s+\(CLEANUP_STEP_ERROR\),A/
        && $app =~ /LD\s+A,\(CLEANUP_STEP_ERROR\)\s+CALL\s+SAVE_CLEANUP_ERROR/;
for my $stage (0..6) {
    die "EL3LB output stage L$stage is missing\n"
        unless $app =~ /\[L$stage\]/;
}
die "EL3LB result contract is missing\n"
    unless $app =~ /RESULT OK/ && $app =~ /RESULT FAIL code=/;

my $path = "$root/build/EL3LB.EXE";
open my $bin, '<:raw', $path or die "cannot read $path: $!\n";
my $data = do { local $/; <$bin> };
close $bin;
my $size = length $data;
die "EL3LB has no executable body\n" if $size <= 128;
die "EL3LB crosses 0xC000\n" if 0x8080 + $size > 0xC000;
die "EL3LB header is invalid\n"
    unless substr($data, 0, 4) eq "EXE\x01"
        && unpack('v', substr($data, 4, 2)) == 0x0080
        && unpack('v', substr($data, 16, 2)) == 0x8100
        && unpack('v', substr($data, 20, 2)) == 0xBFF0;
my $body = substr($data, 128);
my $longest = 0;
while ($body =~ /(\0+)/g) {
    $longest = length($1) if length($1) > $longest;
}
die "EL3LB appears to contain packet BSS ($longest bytes)\n" if $longest > 32;

print "Stage 5 host contract: FIFO provider/core, bounded polling/recovery, loopback, EL3LB and memory/artifacts passed ($size bytes)\n";
