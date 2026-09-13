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

my @sources = qw(
    src/lib/ipv4.asm src/lib/icmp.asm src/lib/nettime.asm
    src/lib/cmdline_lib.asm src/apps/ping.asm src/apps/pingalt.asm
    src/include/ip_icmp.inc
);
my $source = join "\n", map { slurp($_, 0) } @sources;
my $code = $source;
$code =~ s/;[^\n]*//g;

die "Stage 8 added forbidden IRQ routing\n"
    if $source =~ /irq\d*_callback|irq_callback|IRQ_ROUTE/i;
die "Stage 8 added EEPROM writes\n"
    if $source =~ /EEPROM_(?:WRITE|ERASE)|EL3_ID_EEPROM_(?:WRITE|ERASE)/i;
die "Stage 8 upper layers retain an RTL dependency\n"
    if $code =~ /\bRTL(?:\.|_|8019)/i;
die "backend-neutral codecs access EL3/ISA directly\n"
    if join("\n", map { slurp($_, 0) } qw(src/lib/ipv4.asm src/lib/icmp.asm))
        =~ /\@(?:EL3|ISA)\.|0xC000/;

for my $file (qw(src/lib/ipv4.asm src/lib/icmp.asm src/lib/nettime.asm
                 src/lib/cmdline_lib.asm)) {
    my $text = slurp($file, 0);
    die "$file lacks IX/IY preservation\n" unless $text =~ /PUSH\s+IX,IY/i;
}

my $ipv4 = slurp('src/lib/ipv4.asm', 0);
die "IPv4 strict v4/IHL/checksum/fragment contract is incomplete\n"
    unless $ipv4 =~ /CP\s+0x45/ && $ipv4 =~ /VERIFY_CHECKSUM/
		&& $ipv4 =~ /reject reserved\/MF\/offset/
		&& $ipv4 =~ /IPV4_MAX_PACKET\s+EQU\s+IPV4_MAX_PACKET_LENGTH/
		&& slurp('src/include/ip_icmp.inc', 0) =~ /IPV4_MAX_PACKET_LENGTH\s+EQU\s+1500/;
my $icmp = slurp('src/lib/icmp.asm', 0);
die "ICMP Echo/unreachable matching contract is incomplete\n"
    unless $icmp =~ /^BUILD_ECHO\s*$/m && $icmp =~ /^PARSE_ECHO_REPLY\s*$/m
        && $icmp =~ /^PARSE_UNREACHABLE\s*$/m
        && $icmp =~ /ICMPR_IDENTIFIER/ && $icmp =~ /ICMPR_SEQUENCE/
        && $icmp =~ /VERIFY_PATTERN/;

my $memory = slurp('src/include/memory.inc', 0);
die "Stage 8 one-page TX/RX layout or max-frame assertion is missing\n"
    unless $memory =~ /STAGE8_TX_BUFFER\s+EQU\s+STAGE7_TX_BUFFER/
        && $memory =~ /STAGE8_RX_BUFFER\s+EQU\s+STAGE7_RX_BUFFER/
        && $memory =~ /STAGE8_MAX_FRAME\s+EQU\s+14\s*\+\s*20\s*\+\s*8\s*\+\s*1472/
        && $memory =~ /ASSERT\s+STAGE8_MAX_FRAME\s+<=\s+1514/;

my $time = slurp('src/lib/nettime.asm', 0);
die "NETTIME lacks fixed 21 MHz timebase or wall watchdog\n"
    unless $time =~ /NETTIME_FIXED_QPS\s+EQU\s+1000/
        && $time =~ /NETTIME_FIXED_MS\s+EQU\s+1/
        && $time =~ /^INIT\s*$/m
        && $time =~ /NETTIME_QUANTA_LEFT/ && $time =~ /NETTIME_WALL_LIMIT/;
die "Stage 8 uses a forbidden unbounded CPU wait primitive\n"
    if $code =~ /\bHALT\b|\bEI\b/;

my $ping = slurp('src/apps/ping.asm', 0);
die "PING does not use NETDRV/ARP or fail-safe cleanup\n"
    unless $ping =~ /\@NETDRV\.SEND_FRAME/ && $ping =~ /\@NETDRV\.READ_FRAME/
        && $ping =~ /\@ARP\.SELECT_NEXT_HOP/ && $ping =~ /\@S9APP\.CLEANUP/;
die "PING dispatcher is not bounded or PINGALT conditional is missing\n"
    unless $ping =~ /PING_DRAIN_LEFT/ && $ping =~ /IFNDEF PING_ALT_BUILD/
        && slurp('src/apps/pingalt.asm', 0) =~ /DEFINE PING_ALT_BUILD/;
die "PING ARP wait is not protected by NETTIME or RX failures are masked\n"
    unless $ping =~ /^WAIT_ARP\s*\n[\s\S]*?\@NETTIME\.START/m
        && $ping =~ /preserve a real NETDRV\/ISA failure/
        && $ping =~ /ASSERT\s+\$\s*\+\s*S10_BOOTSTRAP_STACK_RESERVE\s*<=\s*S10_STACK_TOP/;

for my $name (qw(PING PINGALT)) {
    my $image = slurp("build/$name.EXE", 1);
    die "$name header is invalid\n"
        unless substr($image, 0, 4) eq "EXE\x01"
            && unpack('v', substr($image, 4, 2)) == 0x0080
            && unpack('v', substr($image, 16, 2)) == 0x8100
            && unpack('v', substr($image, 20, 2)) == 0xBEF0;
    die "$name overlaps Stage 10 bootstrap stack reserve\n"
        if 0x8080 + length($image) > 0xBEE0;
    die "$name banner/version is missing\n"
        unless index($image, "3C509B $name v0.1.2\0") >= 128;
}
die "PING and PINGALT unexpectedly have identical executables\n"
    if slurp('build/PING.EXE', 1) eq slurp('build/PINGALT.EXE', 1);

my $artifacts = slurp('tools/artifacts.sh', 0);
for my $required (qw(PING.EXE PING.TXT PINGALT.EXE TESTING.TXT)) {
    die "Stage 8 IMG artifact missing: $required\n"
        unless $artifacts =~ /IMG_ARTIFACTS[\s\S]*?\Q$required\E/;
}
my ($zip) = $artifacts =~ /(ZIP_ARTIFACTS[\s\S]*)/;
die "PING missing from ZIP\n" unless $zip =~ /PING\.EXE/ && $zip =~ /PING\.TXT/;
die "PINGALT or host testing leaked into ZIP\n"
    if $zip =~ /PINGALT|TESTING|stage8/i;

for my $doc (qw(docs/PING.md docs/STAGE8_TESTING_RU.md
                docs/evidence/STAGE8_TEST_TEMPLATE.md)) {
    slurp($doc, 0);
}

print "Stage 8 host contract: codecs, timebase, EXEs, cleanup and artifacts passed\n";
