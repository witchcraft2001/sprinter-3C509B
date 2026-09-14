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

my @network_sources = qw(
    src/lib/netdrv.asm src/lib/ethernet.asm src/lib/arp.asm src/lib/dhcp.asm
    src/lib/netparse.asm src/lib/netparse_file.asm src/lib/netcfg_write.asm
    src/lib/netenv.asm src/lib/stage7_app.asm
    src/apps/netcfg.asm src/apps/ifup.asm src/apps/arp.asm
    src/include/netdrv.inc src/include/netcfg.inc src/include/memory.inc
);
my $source = join "\n", map { slurp($_, 0) } @network_sources;
my $code_only = $source;
$code_only =~ s/;[^\n]*//g;

die "Stage 7 added forbidden IRQ routing\n"
    if $source =~ /irq\d*_callback|irq_callback|IRQ_ROUTE/i;
die "Stage 7 added forbidden EEPROM writes\n"
    if $source =~ /EEPROM_(?:WRITE|ERASE)|EL3_ID_EEPROM_(?:WRITE|ERASE)/i;
die "upper Stage 7 layers retain an RTL dependency\n"
    if $code_only =~ /\bRTL(?:\.|_|8019)/i;

my $driver = slurp('src/lib/netdrv.asm', 0);
for my $routine (qw(INIT DONE SEND_FRAME RX_PENDING READ_FRAME DISCARD_FRAME
                    SNAPSHOT LINK_STATE WAIT_LINK_UP)) {
    die "NETDRV public routine missing: $routine\n"
        unless $driver =~ /^$routine\s*$/m;
}
die "NETDRV duplicates direct ISA/register access\n"
    if $driver =~ /\@ISA\.|EL3_(?:READ|WRITE)(?:8|16)|OPEN_FIFO/;
die "NETDRV buffer validation is incomplete\n"
    unless $driver =~ /VALIDATE_BUFFER[\s\S]*?0xC001/
        && $driver =~ /NETDRV_DLL_WIN1[\s\S]*?NETDRV_DLL_WIN2/
        && $driver =~ /LD\s+BC,0x0100[\s\S]*?SBC\s+HL,DE/i;
die "NETDRV does not reject an unbounded link wait\n"
    unless $driver =~ /WAIT_LINK_UP[\s\S]*?LD\s+A,B[\s\S]*?OR\s+C[\s\S]*?NETDRV_ERR_PARAMETER/i;
my $upper = join "\n", map { slurp($_, 0) } qw(
    src/apps/netcfg.asm src/apps/ifup.asm src/apps/arp.asm
    src/lib/arp.asm src/lib/dhcp.asm src/lib/ethernet.asm src/lib/netenv.asm
);
die "upper Stage 7 layer calls EL3 directly\n" if $upper =~ /\@EL3\./;

for my $file (qw(src/lib/netdrv.asm src/lib/arp.asm src/lib/dhcp.asm
                 src/lib/netparse.asm src/lib/netenv.asm src/lib/stage7_app.asm)) {
    my $text = slurp($file, 0);
    die "$file lacks IX/IY preservation\n" unless $text =~ /PUSH\s+IX,IY/i;
}

my $memory = slurp('src/include/memory.inc', 0);
# PAGE_BASE is the window the private page is mapped over: 0x4000 for every
# utility whose image is in WIN2, 0x8000 for a WIN1-resident image (Stage 12).
die "Stage 7 buffers are not the private #0000/#0800 page layout\n"
    unless $memory =~ /STAGE7_TX_BUFFER\s+EQU\s+PAGE_BASE \+ 0x0000/
        && $memory =~ /STAGE7_RX_BUFFER\s+EQU\s+PAGE_BASE \+ 0x0800/
        && $memory =~ /ASSERT\s+STAGE7_TX_BUFFER\s*\+\s*STAGE7_TX_CAPACITY\s*<=\s*STAGE7_RX_BUFFER/
        && $memory =~ /ASSERT\s+STAGE7_RX_BUFFER\s*\+\s*STAGE7_RX_CAPACITY\s*<=\s*PAGE_BASE \+ 0x4000/;

my $dhcp = slurp('src/lib/dhcp.asm', 0);
my $ifup = slurp('src/apps/ifup.asm', 0);
die "DHCP retry schedule is not exactly 4/8/16/16\n"
    unless $ifup =~ /RETRY_SECONDS\s+DB\s+4,8,16,16/;
die "DHCP retry timing is not aligned to a wall-clock boundary\n"
    unless $ifup =~ /DHCP_RETRIES_LEFT\),A[\s\S]*?WAIT_SECOND_EDGE[\s\S]*?\.DISCOVER/
        && $ifup =~ /DHCP_START_SECOND/;
die "DHCP reply validation is incomplete\n"
    unless $dhcp =~ /DHCP_MAGIC_0/ && $dhcp =~ /DHCP_MAGIC_3/
        && $dhcp =~ /DHCP_CLIENT_PORT/
        && $dhcp =~ /DHCP_SERVER_PORT/ && $dhcp =~ /PARSE_OPTIONS/
        && $dhcp =~ /\@ETHERNET\.VERIFY_CHECKSUM/;
die "Stage 10 introduced forbidden NET_STATE\n" if $ifup =~ /NET_STATE/;

my $netcfg = slurp('src/apps/netcfg.asm', 0);
my $writer = slurp('src/lib/netcfg_write.asm', 0);
my $dss = slurp('src/include/dss.inc', 0);
my $netcfg_inc = slurp('src/include/netcfg.inc', 0);
die "NETCFG -W action/keyboard ABI missing\n"
    unless $netcfg_inc =~ /NETCFG_ACTION_WRITE/
        && $dss =~ /DSS_ECHOKEY\s+EQU\s+0x32/i
        && $netcfg =~ /NETCFG_ACTION_WRITE/
        && $writer =~ /DSS_ECHOKEY/;
die "NETCFG -W does not validate before overwrite\n"
    unless $writer =~ /CALL\s+BUILD_AND_VALIDATE[\s\S]*?CALL\s+SAVE/i
        && $writer =~ /^BUILD_AND_VALIDATE[\s\S]*?\@NETPARSE\.PARSE/m
        && $writer =~ /SAVE[\s\S]*?DSS_CREATE_OVERWRITE/i;
die "NETCFG -W bypasses the required discovery lifecycle\n"
    unless $writer =~ /S7APP\.INIT_DRIVER[\s\S]*?S7APP\.RECORD_HW[\s\S]*?NETDRV\.DONE/i;

my $arp = slurp('src/lib/arp.asm', 0);
my $arp_app = slurp('src/apps/arp.asm', 0);
die "ARP retry timing is not aligned before three full two-second waits\n"
    unless $arp_app =~ /ARP_RETRY_LEFT\),A[\s\S]*?WAIT_SECOND_EDGE[\s\S]*?\.ATTEMPT/
        && $arp_app =~ /ARP_START_SECOND/;
die "ARP cache contract is incomplete\n"
    unless $memory =~ /ARP_CACHE_COUNT\s+EQU\s+4/
        && $arp =~ /ARP_CACHE_LIFETIME\s+EQU\s+60/
        && $arp =~ /CACHE_LOOKUP/ && $arp =~ /CACHE_INSERT/
        && $arp =~ /SELECT_NEXT_HOP/;

for my $name (qw(NETCFG IFUP ARP)) {
    my $image = slurp("build/$name.EXE", 1);
    die "$name header is invalid\n"
        unless substr($image, 0, 4) eq "EXE\x01"
            && unpack('v', substr($image, 4, 2)) == 0x0080
            && unpack('v', substr($image, 16, 2)) == 0x8100
            && unpack('v', substr($image, 20, 2)) == ($name eq 'IFUP' ? 0xBEF0 : 0xBFF0);
    die "$name crosses 0xC000\n" if 0x8080 + length($image) > 0xC000;
    die "$name banner/version is missing\n"
        unless index($image, "3C509B $name v0.1.2\0") >= 128;
}

my $local = slurp('src/include/unet.inc', 1);
open my $rtl_fh, '<:raw', "$root/../sprinter-rtl8019a/src/include/unet.inc"
    or die "cannot read peer UNET ABI ../sprinter-rtl8019a/src/include/unet.inc: $!\n";
my $rtl = do { local $/; <$rtl_fh> };
close $rtl_fh;
die "src/include/unet.inc diverges byte-for-byte from ../sprinter-rtl8019a/src/include/unet.inc\n"
    unless $rtl eq $local;

# The WiFi sibling may move ahead with deferred Stage 8 LISTEN/ACCEPT symbols
# while this backend retains RESERVED18/19 at the same numeric slots.
# Compare the shared numeric declarations, while keeping the Stage 7 copy
# byte-identical to the RTL sibling used by this backend.
open my $wifi_fh, '<:raw', "$root/../sprinter_wifi/network/src/include/unet.inc"
    or die "cannot read peer UNET ABI ../sprinter_wifi/network/src/include/unet.inc: $!\n";
my $wifi = do { local $/; <$wifi_fh> };
close $wifi_fh;
sub abi_symbols {
    my ($text) = @_;
    my %symbols;
    while ($text =~ /^\s*(UNET_[A-Z0-9_]+)\s+EQU\s+([^\s;]+)/mg) {
        next if $1 =~ /(?:LISTEN|ACCEPT|RESERVED18|RESERVED19)/;
        $symbols{$1} = $2;
    }
    return \%symbols;
}
my $shared_local = abi_symbols($local);
my $shared_wifi = abi_symbols($wifi);
die "shared UNET ABI declarations diverge from ../sprinter_wifi/network/src/include/unet.inc\n"
    unless join("\n", map { "$_=$shared_local->{$_}" } sort keys %$shared_local)
        eq join("\n", map { "$_=$shared_wifi->{$_}" } sort keys %$shared_wifi);

my $artifacts = slurp('tools/artifacts.sh', 0);
die "Stage 7 user artifacts are missing\n"
    unless $artifacts =~ /NETCFG\.EXE/ && $artifacts =~ /IFUP\.EXE/
        && $artifacts =~ /CONNECT\.BAT/ && $artifacts =~ /USAGE\.TXT/
        && $artifacts =~ /HOWTO\.TXT/;
my ($zip) = $artifacts =~ /(ZIP_ARTIFACTS[\s\S]*)/;
die "developer ARP diagnostic leaked into ZIP\n" if $zip =~ /ARP\.(?:EXE|TXT)/;

print "Stage 7 host contract: NETDRV ABI, memory, protocols, EXEs, UNET sync and artifacts passed\n";
