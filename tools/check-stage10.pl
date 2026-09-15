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
    src/include/dns_ntp.inc src/lib/dns.asm src/lib/ntp.asm
    src/lib/stage10_app.asm src/lib/netparse.asm src/lib/dhcp.asm
    src/apps/ifup.asm src/apps/nslookup.asm src/apps/ntp.asm
    src/apps/ping.asm src/apps/udptest.asm src/apps/tftp.asm
);
my $source = join "\n", map { slurp($_, 0) } @sources;
my $code = $source;
$code =~ s/;[^\n]*//g;

die "Stage 10 added forbidden IRQ routing\n"
    if $source =~ /irq\d*_callback|irq_callback|IRQ_ROUTE/i;
die "Stage 10 added EEPROM writes\n"
    if $source =~ /EEPROM_(?:WRITE|ERASE)|EL3_ID_EEPROM_(?:WRITE|ERASE)/i;
die "Stage 10 uses an unbounded interrupt wait\n" if $code =~ /\bHALT\b|\bEI\b/;
die "Stage 10 introduced forbidden NET_STATE\n" if $source =~ /\bNET_STATE\b/;

for my $codec (qw(src/lib/dns.asm src/lib/ntp.asm src/lib/netparse.asm)) {
    my $text = slurp($codec, 0);
    die "$codec lacks IX/IY preservation\n" unless $text =~ /PUSH\s+IX,IY/i;
}
for my $codec (qw(src/lib/dns.asm src/lib/ntp.asm)) {
    my $text = slurp($codec, 0);
    die "$codec is not backend-neutral\n"
        if $text =~ /\@(?:EL3|ISA|NETDRV)\.|\bRST\s+DSS/i;
}

my $dhcp = slurp('src/lib/dhcp.asm', 0);
die "DHCP renewal/release codec is incomplete\n"
    unless $dhcp =~ /^BUILD_RENEW\s*$/m && $dhcp =~ /^BUILD_RELEASE\s*$/m
        && $dhcp =~ /^PARSE_RENEW_REPLY\s*$/m && $dhcp =~ /DHCP_RELEASE\s+EQU\s+7/
        && $dhcp =~ /ciaddr/i;
my $ifup = slurp('src/apps/ifup.asm', 0);
die "IFUP renewal/release transaction is incomplete\n"
    unless $ifup =~ /IFUP_MODE_RENEW/ && $ifup =~ /IFUP_MODE_RELEASE/
        && $ifup =~ /RENEW_SECONDS\s+DB\s+5/ && $ifup =~ /LD\s+A,3[\s\S]*?NTP|LD\s+A,3/
        && $ifup =~ /INHERIT_RENEW_FIELDS/ && $ifup =~ /CLEAR_DYNAMIC_LEASE/
        && $ifup =~ /best effort/i;

my $dns = slurp('src/lib/dns.asm', 0);
die "DNS A/IN codec or bounded compression parser is incomplete\n"
    unless $dns =~ /^VALIDATE_NAME\s*$/m && $dns =~ /^BUILD_QUERY\s*$/m
        && $dns =~ /^PARSE_REPLY\s*$/m && $dns =~ /^SKIP_NAME\s*$/m
        && $dns =~ /DNS_MAX_POINTERS/ && $dns =~ /DNS_TYPE_A/ && $dns =~ /DNS_CLASS_IN/
        && $dns =~ /NETDRV_ERR_DNS_NXDOMAIN/ && $dns =~ /NETDRV_ERR_DNS_NO_ANSWER/;
my $resolver = slurp('src/lib/stage10_app.asm', 0);
die "DNS resolver lacks bounded retries/fallback/private source port\n"
    unless $resolver =~ /LD\s+A,3/ && $resolver =~ /LD\s+BC,5000/
        && $resolver =~ /NET_DNS1/ && $resolver =~ /NET_DNS2/
        && $resolver =~ /DNS_EXPLICIT_FLAG/ && $resolver =~ /WAIT_CONTINUE/
        && $resolver =~ /DNS_TRANSACTION_ID/;

my $ntp = slurp('src/lib/ntp.asm', 0);
die "NTP framing/calendar/timezone support is incomplete\n"
    unless $ntp =~ /^BUILD_REQUEST\s*$/m && $ntp =~ /^PARSE_REPLY\s*$/m
        && $ntp =~ /^TO_CALENDAR\s*$/m && $ntp =~ /^APPLY_TZ\s*$/m
        && $ntp =~ /NTP_PACKET_LENGTH/ && $ntp =~ /LI=3/
        && $ntp =~ /server mode/ && $ntp =~ /PR_COOKIE/ && $ntp =~ /IS_LEAP/;
my $ntp_app = slurp('src/apps/ntp.asm', 0);
die "NTP app lacks bounded polling or close-before-DSS_SETTIME\n"
    unless $ntp_app =~ /LD\s+A,3/ && $ntp_app =~ /LD\s+BC,5000/
        && $ntp_app =~ /CALL\s+\@NETDRV\.DONE[\s\S]*?DSS_SETTIME/
        && $ntp_app =~ /\@NETPARSE\.PARSE_TZ/;
my $tz = slurp('src/lib/netparse.asm', 0);
die "common quarter-hour timezone parser is incomplete\n"
    unless $tz =~ /^PARSE_TZ\s*$/m && $tz =~ /CP\s+15/ && $tz =~ /CP\s+30/
        && $tz =~ /CP\s+45/ && $tz =~ /CP\s+14/ && $tz =~ /CP\s+12/;

my $memory = slurp('src/include/memory.inc', 0);
die "Stage 10 mapped-page layout/assertions are incomplete\n"
    unless $memory =~ /STAGE9_TX_BUFFER\s+EQU\s+PAGE_BASE \+ 0x0000/
        && $memory =~ /STAGE9_RX_BUFFER\s+EQU\s+PAGE_BASE \+ 0x0800/
        && $memory =~ /STAGE9_FILE_BUFFER\s+EQU\s+PAGE_BASE \+ 0x1000/
        && $memory =~ /STAGE9_SCRATCH\s+EQU\s+PAGE_BASE \+ 0x3800/
        && $memory =~ /S10_PAGE_COMMAND_BUFFER EQU PAGE_BASE \+ 0x3E00/
        && $memory =~ /S10_STACK_TOP\s+EQU\s+0xBEF0/
        && $memory =~ /S10_BOOTSTRAP_STACK_RESERVE EQU 0x0010/
        && $memory =~ /ASSERT\s+STAGE9_MAX_FRAME\s+<=\s+1514/
        && $memory =~ /ASSERT\s+STAGE9_SCRATCH\s*\+\s*STAGE9_SCRATCH_CAPACITY\s*<=\s*S10_PAGE_COMMAND_BUFFER/;

for my $name (qw(IFUP PING PINGALT UDPTEST TFTP NSLOOKUP NTP)) {
    my $image = slurp("build/$name.EXE", 1);
    die "$name header is invalid\n"
        unless substr($image, 0, 4) eq "EXE\x01"
            && unpack('v', substr($image, 4, 2)) == 0x0080
            && unpack('v', substr($image, 16, 2)) == 0x8100
            && unpack('v', substr($image, 20, 2)) == 0xBEF0;
    die "$name overlaps Stage 10 bootstrap stack reserve\n"
        if 0x8080 + length($image) > 0xBEE0;
    die "$name banner/version is missing\n"
        unless index($image, "3C509B $name v0.1.3\0") >= 128;
    my ($longest, $run) = (0, 0);
    for my $byte (unpack('C*', substr($image, 128))) {
        $run = $byte ? 0 : $run + 1;
        $longest = $run if $run > $longest;
    }
    die "$name contains zero-filled runtime BSS\n" if $longest >= 128;
}

my $harness = slurp('tools/exe-harness/harness.js', 0);
die "actual-EXE harness lacks transactional SETTIME/ISA/page/stack tracking\n"
    unless $harness =~ /setTimeCalls/ && $harness =~ /setTimeFail/
        && $harness =~ /isaOpen/ && $harness =~ /allocations/
        && $harness =~ /minimumSp/ && $harness =~ /environment/;

my $artifacts = slurp('tools/artifacts.sh', 0);
for my $required (qw(NSLOOKUP.EXE NSLOOKUP.TXT NTP.EXE NTP.TXT S10TEST.TXT)) {
    die "Stage 10 IMG artifact missing: $required\n"
        unless $artifacts =~ /IMG_ARTIFACTS[\s\S]*?\Q$required\E/;
}
my ($zip) = $artifacts =~ /(ZIP_ARTIFACTS[\s\S]*)/;
die "Stage 10 user artifacts are missing from ZIP\n"
    unless $zip =~ /NSLOOKUP\.EXE/ && $zip =~ /NSLOOKUP\.TXT/
        && $zip =~ /NTP\.EXE/ && $zip =~ /NTP\.TXT/;
die "Stage 10 developer test leaked into ZIP\n" if $zip =~ /S10TEST|stage10/i;

for my $doc (qw(docs/NSLOOKUP.md docs/NTP.md docs/STAGE10_TESTING_RU.md
                docs/evidence/STAGE10_TEST_TEMPLATE.md)) {
    slurp($doc, 0);
}
my $responder = slurp('tools/host/stage10_responder.py', 0);
for my $tag (qw(READY FRAME DROP RETRY DHCP DNS NTP RELEASE PROXY)) {
    die "Stage 10 responder lacks $tag logging\n" unless $responder =~ /\Q$tag\E/;
}
die "Stage 10 responder lacks classic pcap or public UDP proxies\n"
    unless $responder =~ /0xA1B2C3D4/ && $responder =~ /captured\s*!=\s*wire/
        && $responder =~ /SOCK_DGRAM/
        && $responder =~ /destination_port.*53/ && $responder =~ /destination_port.*123/;

print "Stage 10 host contract: DHCP/DNS/NTP/TZ, mapped clients, EXEs, responder and artifacts passed\n";
