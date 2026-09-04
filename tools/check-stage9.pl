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
    src/include/udp_tftp.inc src/lib/udp.asm src/lib/tftp.asm
    src/lib/udp_transport.asm src/lib/stage9_app.asm src/lib/stage9_cli.asm
    src/lib/file.asm src/apps/udptest.asm src/apps/tftp.asm
);
my $source = join "\n", map { slurp($_, 0) } @sources;
my $code = $source;
$code =~ s/;[^\n]*//g;

die "Stage 9 added forbidden IRQ routing\n"
    if $source =~ /irq\d*_callback|irq_callback|IRQ_ROUTE/i;
die "Stage 9 added EEPROM writes\n"
    if $source =~ /EEPROM_(?:WRITE|ERASE)|EL3_ID_EEPROM_(?:WRITE|ERASE)/i;
die "Stage 9 uses an unbounded interrupt wait\n" if $code =~ /\bHALT\b|\bEI\b/;

for my $codec (qw(src/lib/udp.asm src/lib/tftp.asm)) {
    my $text = slurp($codec, 0);
    die "$codec is not backend-neutral\n" if $text =~ /\@(?:EL3|ISA|NETDRV)\.|\bRST\s+DSS/i;
    die "$codec lacks IX/IY preservation\n" unless $text =~ /PUSH\s+IX,IY/i;
}

my $udp = slurp('src/lib/udp.asm', 0);
die "UDP strict length/checksum/boundary contract is incomplete\n"
    unless $udp =~ /UDP_MAX_PAYLOAD\+1/ && $udp =~ /CHECKSUM_PARSE_DESC/
        && $udp =~ /0xFFFF/ && $udp =~ /UDP_HEADER_LENGTH/
        && $udp =~ /\@IPV4\.VALIDATE_REGION/;
my $tftp = slurp('src/lib/tftp.asm', 0);
for my $routine (qw(BUILD_REQUEST BUILD_DATA BUILD_ACK BUILD_ERROR PARSE)) {
    die "TFTP codec routine missing: $routine\n" unless $tftp =~ /^$routine\s*$/m;
}
die "TFTP blksize/name bounds are incomplete\n"
    unless $tftp =~ /TFTP_MAX_WIRE_NAME\+1/ && $tftp =~ /TFTP_MIN_BLOCK/
        && $tftp =~ /TFTP_MAX_BLOCK\+1/ && $tftp =~ /OPTION_BLKSIZE/;

my $transport = slurp('src/lib/udp_transport.asm', 0);
die "UDP transport lacks bounded polling services\n"
    unless $transport =~ /S9_DRAIN_LEFT/ && $transport =~ /LD\s+A,4/
        && $transport =~ /\@NETTIME\.START/ && $transport =~ /\@NETTIME\.TICK/
        && $transport =~ /WAIT_CONTINUE/ && $transport =~ /ANSWER_ECHO/
        && $transport =~ /PARSE_UDP_UNREACHABLE/ && $transport =~ /\@ARP\.BUILD_REPLY/;

my $app = slurp('src/apps/tftp.asm', 0);
die "TFTP lock-step/retry/TID/final-block contract is incomplete\n"
    unless $app =~ /TFTP_STATE_SENDS\s+EQU\s+6/
        && $app =~ /TFTP_TIMEOUT_MS\s+EQU\s+5000/
        && $app =~ /CHECK_TID/ && $app =~ /SEND_UNKNOWN_TID/
        && $app =~ /DALLY_FINAL/ && $app =~ /FLUSH_FILE_BUFFER/
        && $app =~ /TFTP_DEFAULT_BLOCK/ && $app =~ /TFTP_REQUEST_BLOCK/;
my $file = slurp('src/lib/file.asm', 0);
die "TFTP path/overwrite helpers are incomplete\n"
    unless $file =~ /DSS_CURDIR/ && $file =~ /DSS_CHDIR/
        && $file =~ /DSS_DELETE/ && $file =~ /WAIT_YES_NO/ && $file =~ /RESTORE_CWD/;
my $cleanup = slurp('src/lib/stage9_app.asm', 0);
die "Stage 9 cleanup order is not file, NETDRV, DSS page\n"
    unless $cleanup =~ /S9_TFTP_FILE_OPEN[\s\S]*?DSS_CLOSE_FILE[\s\S]*?\@NETDRV\.DONE[\s\S]*?DSS_FREEMEM/;

my $memory = slurp('src/include/memory.inc', 0);
die "Stage 9 one-page layout/assertions are incomplete\n"
    unless $memory =~ /STAGE9_TX_BUFFER\s+EQU\s+PAGE_BASE \+ 0x0000/
        && $memory =~ /STAGE9_RX_BUFFER\s+EQU\s+PAGE_BASE \+ 0x0800/
        && $memory =~ /STAGE9_FILE_BUFFER\s+EQU\s+PAGE_BASE \+ 0x1000/
        && $memory =~ /STAGE9_FILE_CAPACITY\s+EQU\s+0x2000/
        && $memory =~ /STAGE9_MAX_FRAME\s+EQU\s+14\s*\+\s*20\s*\+\s*8\s*\+\s*1472/
        && $memory =~ /ASSERT\s+STAGE9_MAX_FRAME\s+<=\s+1514/
        && $memory =~ /STAGE9_SCRATCH\s*\+\s*STAGE9_SCRATCH_CAPACITY\s*<=\s*PAGE_BASE \+ 0x4000/;

for my $entry ([UDPTEST => 0xBEE0], [TFTP => 0xBEE0]) {
    my ($name, $limit) = @$entry;
    my $image = slurp("build/$name.EXE", 1);
    die "$name header is invalid\n"
        unless substr($image, 0, 4) eq "EXE\x01"
            && unpack('v', substr($image, 4, 2)) == 0x0080
            && unpack('v', substr($image, 16, 2)) == 0x8100
            && unpack('v', substr($image, 20, 2)) == 0xBEF0;
    die "$name overlaps Stage 10 bootstrap stack reserve\n" if 0x8080 + length($image) > $limit;
    die "$name banner/version is missing\n"
        unless index($image, "3C509B $name v0.0.1\0") >= 128;
    my $longest = 0;
    my $run = 0;
    for my $byte (unpack('C*', substr($image, 128))) {
        $run = $byte ? 0 : $run + 1;
        $longest = $run if $run > $longest;
    }
    die "$name contains zero-filled runtime BSS\n" if $longest >= 128;
}

my $artifacts = slurp('tools/artifacts.sh', 0);
for my $required (qw(UDPTEST.EXE UDPTEST.TXT TFTP.EXE TFTP.TXT S9TEST.TXT)) {
    die "Stage 9 IMG artifact missing: $required\n"
        unless $artifacts =~ /IMG_ARTIFACTS[\s\S]*?\Q$required\E/;
}
my ($zip) = $artifacts =~ /(ZIP_ARTIFACTS[\s\S]*)/;
die "TFTP user artifacts are missing from ZIP\n"
    unless $zip =~ /TFTP\.EXE/ && $zip =~ /TFTP\.TXT/;
die "Stage 9 developer artifacts leaked into ZIP\n"
    if $zip =~ /UDPTEST|S9TEST|stage9|responder/i;

for my $doc (qw(docs/UDPTEST.md docs/TFTP.md docs/STAGE9_TESTING_RU.md
                docs/evidence/STAGE9_TEST_TEMPLATE.md)) {
    slurp($doc, 0);
}
my $responder = slurp('tools/host/stage9_responder.py', 0);
die "Stage 9 responder lacks required services/logs\n"
    unless $responder =~ /ECHO_PORT\s*=\s*7777/ && $responder =~ /TFTP_PORTS\s*=\s*\(69, 6969\)/
        && $responder =~ /SERVER_TID/ && $responder =~ /READY/ && $responder =~ /FRAME/
        && $responder =~ /DROP/ && $responder =~ /RETRY/ && $responder =~ /TFTP/;

print "Stage 9 host contract: UDP/TFTP codecs, transport, files, EXEs, responder and artifacts passed\n";
