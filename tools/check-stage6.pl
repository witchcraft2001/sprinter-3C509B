#!/usr/bin/env perl
use strict;
use warnings;

my ($root) = @ARGV;
die "usage: $0 ROOT\n" unless defined $root;

sub slurp {
    my ($relative, $raw) = @_;
    open my $fh, $raw ? '<:raw' : '<', "$root/$relative"
        or die "cannot read $relative: $!\n";
    my $data = do { local $/; <$fh> };
    close $fh;
    return $data;
}

my $source = join "\n", map { slurp($_, 0) } qw(
    src/apps/el3tx.asm src/apps/el3rx.asm src/lib/cli_stage6.asm
    src/lib/stage6_app.asm src/lib/crc32.asm src/lib/el3_algorithms.asm src/lib/el3_regs.asm
    src/lib/el3_fifo.asm src/lib/el3_io.asm src/include/el3.inc
    src/include/memory.inc tools/exe-harness/harness.js
    tools/test-exe-harness.js tools/stage6_vectors.asm tools/test-stage6-asm.sh
    tools/host/ethernet_helper.py tools/3com.sh
);

die "Stage 6 depends on IRQ routing\n"
    if $source =~ /irq\d*_callback|irq_callback|IRQ_ROUTE/i;
die "EEPROM write/erase API is forbidden\n"
    if $source =~ /^\s*(?:EEPROM_(?:WRITE|ERASE)|EL3_ID_EEPROM_(?:WRITE|ERASE))\b/mi;
die "link timeout status 20 is missing\n"
    unless $source =~ /EL3_ERR_LINK_TIMEOUT\s+EQU\s+20\b/i;
for my $routine (qw(LINK_STATE WAIT_LINK_UP)) {
    die "public Stage 6 routine is missing: $routine\n"
        unless $source =~ /^$routine\s*$/m;
}
die "WAIT_LINK_UP is not bounded by a CYCLES21 quantum count\n"
    unless $source =~ /WAIT_LINK_UP[\s\S]*?WAIT_LINK_LIMIT[\s\S]*?WAIT_QUANTUM/
        && $source =~ /EL3_ERR_LINK_TIMEOUT/;
die "FIFO provider does not preserve the caller's byte count\n"
    unless $source =~ /OPEN_FIFO\s+PUSH\s+BC[\s\S]*?CALL\s+\@ISA\.MAP_POINTER\s+POP\s+BC/i;

my $tx = slurp('src/apps/el3tx.asm', 0);
my $rx = slurp('src/apps/el3rx.asm', 0);
die "EL3TX CLI contract is incomplete\n"
    unless $tx =~ /Usage: EL3TX.*-d MAC/s
        && $tx =~ /#0600\.\.#FFFF/
        && $tx =~ /14\.\.1514/
        && $tx =~ /00\|FF\|55\|AA\|INC/
        && $tx =~ /1\.\.10000/;
die "EL3RX CLI contract is incomplete\n"
    unless $rx =~ /Usage: EL3RX.*\[-x\].*1\.\.10000/s;
die "Stage 6 packet buffers are not in one DSS WIN1 page\n"
    unless $tx =~ /TX_BUFFER\s+EQU\s+0x4000/
        && $rx =~ /RX_BUFFER\s+EQU\s+0x4800/
        && $source =~ /LD\s+B,1[\s\S]*?DSS_GETMEM[\s\S]*?DSS_SETWIN1/;
die "Stage 6 lifecycle does not always attempt DONE and FREEMEM\n"
    unless $source =~ /CLEANUP[\s\S]*?\@EL3\.DONE[\s\S]*?DSS_FREEMEM/;
die "Stage 6 detailed statuses are not mapped to the common DSS exit ABI\n"
    unless $source =~ /TO_DSS_EXIT[\s\S]*?EL3_ERR_LINK_TIMEOUT[\s\S]*?\.EXIT_TIMEOUT[\s\S]*?DSS_EXIT_NETWORK/i
        && $tx =~ /CALL\s+\@EL3ALG\.TO_DSS_EXIT[\s\S]*?DSS_EXIT/i
        && $rx =~ /CALL\s+\@EL3ALG\.TO_DSS_EXIT[\s\S]*?DSS_EXIT/i;
die "EL3TX Ethernet II construction is incomplete\n"
    unless $tx =~ /CLI_DEST_MAC[\s\S]*?EL3_MAC[\s\S]*?CLI_ETHERTYPE/
        && $tx =~ /PATTERN_INDEX/ && $tx =~ /S6_SEQUENCE/;
die "EL3RX does not print summary CRC32 or provide full dump mode\n"
    unless $rx =~ /SOURCE=/ && $rx =~ /DEST=/ && $rx =~ /TYPE=#/
        && $rx =~ /CRC32=#/ && $rx =~ /PRINT_DUMP/;
die "CRC32 polynomial implementation is missing\n"
    unless $source =~ /0x20[\s\S]*?0x83[\s\S]*?0xB8[\s\S]*?0xED/;

my $harness = slurp('tools/exe-harness/harness.js', 0);
for my $contract ('unknown DSS call', 'wrong RX FIFO offset',
                  'EXIT with ISA window open', 'EXIT with unreleased DSS pages') {
    die "harness strict contract missing: $contract\n"
        unless index($harness, $contract) >= 0;
}
die "harness does not derive EXE load address from its header\n"
    unless $harness =~ /loadAddress\s*=\s*entry\s*-\s*headerSize/;
die "Molly Howell Z80 license is missing\n"
    unless -f "$root/tools/exe-harness/LICENSE.Z80core"
        && slurp('tools/exe-harness/LICENSE.Z80core', 0) =~ /Copyright \(c\) Molly Howell/;

for my $name (qw(EL3TX EL3RX)) {
    my $relative = "build/$name.EXE";
    my $image = slurp($relative, 1);
    die "$name header is invalid\n"
        unless substr($image, 0, 4) eq "EXE\x01"
            && unpack('v', substr($image, 4, 2)) == 0x0080
            && unpack('v', substr($image, 16, 2)) == 0x8100
            && unpack('v', substr($image, 20, 2)) == 0xBFF0;
    die "$name crosses 0xC000\n" if 0x8080 + length($image) > 0xC000;
    die "$name banner/version is missing\n"
        unless index($image, "3C509B $name v0.0.1\0") >= 128;
}

my $artifacts = slurp('tools/artifacts.sh', 0);
die "EL3TX/EL3RX are not in IMG\n"
    unless $artifacts =~ /IMG_ARTIFACTS[\s\S]*?EL3TX\.EXE[\s\S]*?EL3RX\.EXE/;
my ($zip) = $artifacts =~ /(ZIP_ARTIFACTS[\s\S]*)/;
die "EL3TX/EL3RX leaked into ZIP\n" if $zip =~ /EL3(?:TX|RX)\./;

print "Stage 6 host contract: API, CLI, lifecycle, CRC32, actual-EXE harness, network helper and artifacts passed\n";
