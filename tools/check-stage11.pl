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
    src/include/tcp.inc src/lib/tcp.asm src/lib/tcp_transport.asm
    src/lib/stage11_app.asm src/apps/tcptest.asm
);
my $source = join "\n", map { slurp($_, 0) } @sources;
my $code = $source;
$code =~ s/;[^\n]*//g;

die "Stage 11 added forbidden IRQ routing\n"
    if $source =~ /irq\d*_callback|irq_callback|IRQ_ROUTE/i;
die "Stage 11 added EEPROM writes\n"
    if $source =~ /EEPROM_(?:WRITE|ERASE)|EL3_ID_EEPROM_(?:WRITE|ERASE)/i;
die "Stage 11 uses an unbounded interrupt wait\n" if $code =~ /\bHALT\b|\bEI\b/;

my $codec = slurp('src/lib/tcp.asm', 0);
die "TCP codec is not backend-neutral\n"
    if $codec =~ /\@(?:EL3|ISA|NETDRV)\.|\bRST\s+DSS/i;
die "TCP codec lacks IX/IY preservation\n" unless $codec =~ /PUSH\s+IX,IY/i;
die "TCP codec lacks strict checksum/MSS/options parsing\n"
    unless $codec =~ /^BUILD\s*$/m && $codec =~ /^PARSE\s*$/m
        && $codec =~ /CHECKSUM/ && $codec =~ /^PARSE_OPTIONS\s*$/m
        && $codec =~ /TCP_SYN_HEADER_LENGTH/ && $codec =~ /VALIDATE_REGION/;

my $transport = slurp('src/lib/tcp_transport.asm', 0);
for my $routine (qw(RESET OPEN SEND RECV CLOSE ABORT STATUS)) {
    die "TCP transport routine missing: $routine\n"
        unless $transport =~ /^$routine\s*$/m;
}
die "TCP transport lacks two independent channel contexts\n"
    unless $transport =~ /S11_CONTEXT0/ && $transport =~ /S11_CONTEXT1/
        && $transport =~ /S11_PENDING0/ && $transport =~ /S11_PENDING1/;
die "TCP transport can immediately reuse an ephemeral port\n"
    unless $transport =~ /S11_NEXT_LOCAL_PORT/ && $transport =~ /LD\s+HL,0xC000/;
die "TCP state machine is incomplete\n"
    unless $transport =~ /TCP_STATE_SYN_SENT/ && $transport =~ /TCP_STATE_ESTABLISHED/
        && $transport =~ /TCP_STATE_FIN_WAIT/ && $transport =~ /TCP_STATE_CLOSE_WAIT/
        && $transport =~ /TCP_FLAG_RST/ && $transport =~ /^WAIT_FOR_ALL_EVENTS\s*$/m;
die "TCP bounded retry/window policy is incomplete\n"
    unless $transport =~ /SYN_TIMEOUT_MS\s+EQU\s+1700/
        && $transport =~ /FIN_TIMEOUT_MS\s+EQU\s+5000/
        && $transport =~ /LD\s+BC,1000/ && $transport =~ /LD\s+BC,2000/
        && $transport =~ /LD\s+BC,4000/ && $transport =~ /^WAIT_REMOTE_WINDOW\s*$/m
        && $transport =~ /TCP_ERR_WINDOW/ && $transport =~ /CTX_RETRY_LEFT/
        && $transport =~ /^SEND_WINDOW_PROBE\s*$/m
        && $transport =~ /S11_SEQUENCE_OVERRIDE/ && $transport =~ /^DEC32\s*$/m;
die "TCP receive dispatch can evade its deadline under continuous traffic\n"
    unless $transport =~ /CALL\s+PROCESS_FRAME[\s\S]{0,300}?JP\s+\.WAIT_TICK/;
die "TCP FIN acceptance reuses a stale queued-data event\n"
    unless $transport =~ /S11_SEGMENT_ACCEPTED/
        && $transport !~ /AND\s+EVENT_DATA[\s\S]{0,120}?\.ACCEPT_FIN/;
die "TCP SEND does not expose transparent multi-segment progress\n"
    unless $transport =~ /S11_SEND_REMAINING/ && $transport =~ /S11_SEND_CONFIRMED/
        && $transport =~ /TCP_MSS/;

my $tcp = slurp('src/include/tcp.inc', 0);
die "Stage 11 native MSS must remain sibling-compatible 536\n"
    unless $tcp =~ /TCP_MSS\s+EQU\s+536/;

my $memory = slurp('src/include/memory.inc', 0);
die "Stage 11 mapped page layout/assertions are incomplete\n"
    unless $memory =~ /S11_APP_CAPACITY\s+EQU\s+0x1000/
        && $memory =~ /S11_PENDING_CAPACITY\s+EQU\s+0x0218/
        && $memory =~ /ASSERT\s+S11_APP_BUFFER\s*\+\s*S11_APP_CAPACITY\s*<=\s*S11_PENDING0/
        && $memory =~ /ASSERT\s+S11_PENDING1\s*\+\s*S11_PENDING_CAPACITY\s*<=\s*S11_CONTEXT0/;

my $image = slurp('build/TCPTEST.EXE', 1);
die "TCPTEST header is invalid\n"
    unless substr($image, 0, 4) eq "EXE\x01"
        && unpack('v', substr($image, 4, 2)) == 0x0080
        && unpack('v', substr($image, 16, 2)) == 0x8100
        && unpack('v', substr($image, 20, 2)) == 0xBEF0;
die "TCPTEST overlaps bootstrap stack reserve\n"
    if 0x8080 + length($image) > 0xBEE0;
die "TCPTEST banner/version is missing\n"
    unless index($image, "3C509B TCPTEST v0.0.1\0") >= 128;
my ($longest, $run) = (0, 0);
for my $byte (unpack('C*', substr($image, 128))) {
    $run = $byte ? 0 : $run + 1;
    $longest = $run if $run > $longest;
}
die "TCPTEST contains zero-filled runtime BSS\n" if $longest >= 128;

my $app = slurp('src/apps/tcptest.asm', 0);
die "TCPTEST lacks two-channel, long-buffer and reconnect checks\n"
    unless $app =~ /LD\s+A,0[\s\S]*?\@TCPX\.OPEN/
        && $app =~ /LD\s+A,1[\s\S]*?\@TCPX\.OPEN/
        && $app =~ /TCP_ERR_RESET[\s\S]*?\@TCPX\.RESET/
        && $app =~ /0\.\.4096/ && $app =~ /RESULT OK/ && $app =~ /RESULT FAIL/;
die "TCPTEST lacks stable timeout/device/target diagnostics\n"
    unless $app =~ /\[E2\] NETWORK stage=/ && $app =~ /elapsed_(?:ticks|ms)=/
        && $app =~ /NETDRV_SELECTED_SLOT/ && $app =~ /NETDRV_SELECTED_BASE/
        && $app =~ /status=/ && $app =~ /target=/;

my $artifacts = slurp('tools/artifacts.sh', 0);
for my $required (qw(TCPTEST.EXE TCPTEST.TXT S11TEST.TXT)) {
    die "Stage 11 IMG artifact missing: $required\n"
        unless $artifacts =~ /IMG_ARTIFACTS[\s\S]*?\Q$required\E/;
}
my ($zip) = $artifacts =~ /(ZIP_ARTIFACTS[\s\S]*)/;
die "Stage 11 developer artifacts leaked into ZIP\n"
    if $zip =~ /TCPTEST|S11TEST|stage11/i;

for my $doc (qw(docs/TCPTEST.md docs/STAGE11_TESTING_RU.md
                docs/evidence/STAGE11_TEST_TEMPLATE.md)) {
    slurp($doc, 0);
}
my $responder = slurp('tools/host/stage11_responder.py', 0);
for my $tag (qw(READY SYN ESTABLISHED DATA FIN DROP OUT-OF-ORDER DUPLICATE WINDOW RST)) {
    die "Stage 11 responder lacks $tag logging\n" unless $responder =~ /\Q$tag\E/;
}
die "Stage 11 responder lacks classic pcap/two-channel/MSS checks\n"
    unless $responder =~ /0xA1B2C3D4/ && $responder =~ /captured\s*!=\s*wire/
        && $responder =~ /two client TCP channels/ && $responder =~ /MSS 536/;

print "Stage 11 host contract: TCP codec/state, bounded retries, two channels, long SEND, responder and artifacts passed\n";
