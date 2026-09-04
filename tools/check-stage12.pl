#!/usr/bin/env perl
use strict;
use warnings;
use File::Spec;

my $root = shift // '.';
sub slurp {
    my ($name, $binary) = @_;
    open my $fh, '<' . ($binary ? ':raw' : ''), File::Spec->catfile($root, $name)
        or die "cannot read $name: $!\n";
    local $/;
    return <$fh>;
}

my @sources = qw(
    src/apps/wget.asm src/lib/stage12_dns.asm src/lib/stage9_cli.asm
    src/lib/file.asm src/lib/tcp_transport.asm src/lib/netdrv.asm src/lib/stage11_app.asm
    src/include/memory.inc src/include/dss.inc tools/exe-harness/harness.js
);
my $code = join "\n", map { slurp($_, 0) } @sources;
die "Stage 12 added forbidden IRQ routing\n"
    if $code =~ /irq\d*_callback|set_input_line|IRQ_(?:ACK|ENABLE)/i;
die "Stage 12 added EEPROM writes\n"
    if $code =~ /EEPROM_(?:WRITE|ERASE)|WRITE_EEPROM/i;
die "Stage 12 contains an unbounded interrupt wait\n" if $code =~ /\b(?:HALT|EI)\b/;
die "WGET is not polling-only with finite DNS/HTTP deadlines\n"
    unless $code =~ /DNS_TIMEOUT_MS\s+EQU\s+5000/ &&
           $code =~ /HTTP_IDLE_MS\s+EQU\s+15000/ &&
           $code =~ /DNS_ATTEMPTS/;
die "WGET DNS does not validate UDP length/checksum\n"
    unless $code =~ /UDP length must match the parsed IPv4 payload/ &&
           $code =~ /ETHERNET\.UDP_IPV4_CHECKSUM/;
die "Stage 12 may call DSS with the ISA window open\n"
    unless $code =~ /DSS call while ISA window is open/ &&
           $code =~ /NETDRV maps it only for individual hardware transactions/;
die "WGET resume does not use DSS MOVE_FP/206 gating\n"
    unless $code =~ /DSS_MOVE_FP/ && $code =~ /SEEK_END/ &&
           $code =~ /LD\s+DE,206/ && $code =~ /Range: bytes=/;
die "WGET 8 KiB buffer or shared 2 KiB work area changed\n"
    unless $code =~ /STAGE9_FILE_CAPACITY\s+EQU\s+0x2000/ &&
           $code =~ /STAGE9_TX_CAPACITY\s+EQU\s+0x0400/ &&
           $code =~ /STAGE9_RX_CAPACITY\s+EQU\s+0x0400/;
die "Stage 12 layout assertions are incomplete\n"
    unless $code =~ /W12_STATE_BASE \+ 0x40 <= S11_APP_BUFFER/ &&
           $code =~ /S9_TFTP_ERROR_DESC \+ 10 <= S10_RUNTIME_STACK_TOP - 0x0100/ &&
           $code =~ /S10_BOOTSTRAP_STACK_RESERVE <= S10_STACK_TOP/;
die "Stage 12 does not preserve the IX command record before its first DSS call\n"
    unless $code =~ /SAVE_COMMAND[\s\S]*LDIR[\s\S]*ALLOCATE_FRESH[\s\S]*DSS_GETMEM/ &&
           $code =~ /S10_COMMAND_BUFFER\s+EQU\s+0x4000/;
# WGET's image fills a whole window, so it loads into WIN1 and claims WIN2. Its
# stack must end up in the claimed page, and nothing may print before it does.
die "Stage 12 does not claim WIN2 for its runtime page\n"
    unless $code =~ /PAGE_BASE\s+EQU\s+0x8000/ &&
           $code =~ /DSS_SETWIN2/ &&
           $code =~ /S10_RUNTIME_STACK_TOP\s+EQU\s+PAGE_BASE \+ 0x3FF0/;
die "Stage 12 prints before its runtime page is claimed\n"
    unless $code =~ /ALLOCATE_FRESH\s*\n\s*JP\s+C,BOOT_FAIL\s*\n\s*LD\s+SP,S10_RUNTIME_STACK_TOP/ &&
           $code =~ /BOOT_FAIL\s*\n\s*DSS_RETURN/;
die "WGET cleanup does not close file/driver/page in order\n"
    unless $code =~ /EXIT_NO_RESULT[\s\S]*DSS_CLOSE_FILE[\s\S]*NETDRV\.DONE[\s\S]*DSS_FREEMEM[\s\S]*DSS_EXIT/;
die "WGET may report success after a failed final file close\n"
    unless $code =~ /DOWNLOAD_DONE[\s\S]*CLOSE_OUTPUT[\s\S]*JP\s+C,FILE_FAIL/ &&
           $code =~ /CLOSE_OUTPUT[\s\S]*DSS_CLOSE_FILE[\s\S]*RET\s+C/;

my $exe = slurp('build/WGET.EXE', 1);
die "WGET.EXE has invalid DSS header\n"
    unless substr($exe, 0, 4) eq "EXE\x01" && unpack('v', substr($exe, 4, 2)) == 128 &&
           unpack('v', substr($exe, 16, 2)) == 0x4100 &&
           unpack('v', substr($exe, 20, 2)) == 0x8000;
# DSS installs the header stack before the entry point runs and spends it on the
# loader and on interrupt frames, so it must already be clear of the image.
die "WGET.EXE entry stack is not clear of its own code\n"
    if unpack('v', substr($exe, 20, 2)) < 0x4080 + length($exe) + 0xC0;
die "WGET.EXE overlaps bootstrap stack reserve\n" if 0x8080 + length($exe) > 0xBFE0;
my $payload = substr($exe, 128);
die "WGET.EXE contains zero-filled runtime BSS\n" if $payload =~ /\x00{128}/;

my $golden = slurp('tools/test-fixtures/stage12-wget-golden.json', 0);
die "WGET golden outputs are not pinned to the sibling revision\n"
    unless $golden =~ /9ec98b00c6490fed5eb722c52b47d11c70a199ae/ &&
           $golden =~ /banner.*REGS hardware line/s;
for my $text ('Usage:', 'Local file', 'Overwrite\/Resume\/Cancel',
              'server ignored Range', 'too many redirects', 'Done. ', 'RESULT OK', 'RESULT FAIL') {
    die "WGET user string missing: $text\n" unless $code =~ /$text/;
}

my $artifacts = slurp('tools/artifacts.sh', 0);
for my $required ('build/WGET.EXE|WGET.EXE', 'docs/WGET.md|WGET.TXT',
                  'docs/STAGE12_TESTING_RU.md|S12TEST.TXT') {
    die "Stage 12 IMG artifact missing: $required\n"
        unless $artifacts =~ /IMG_ARTIFACTS[\s\S]*?\Q$required\E/;
}
my ($zip) = $artifacts =~ /(ZIP_ARTIFACTS[\s\S]*)/;
die "WGET user artifacts are missing from ZIP\n"
    unless $zip && $zip =~ /build\/WGET\.EXE\|WGET\.EXE/ &&
           $zip =~ /docs\/WGET\.md\|WGET\.TXT/;
die "Stage 12 developer documents leaked into ZIP\n" if $zip =~ /S12TEST|STAGE12_TEST/i;

my $responder = slurp('tools/host/stage12_responder.py', 0);
for my $tag ('ZERO.BIN', 'SMALL.BIN', 'LARGE.BIN', 'RANGE.BIN',
             'Content-Range', '302 Found', '404 Not Found', '500 Internal Server Error') {
    die "Stage 12 responder lacks $tag\n" unless $responder =~ /\Q$tag\E/;
}

print "Stage 12 host contract: sibling golden UX, HTTP/DNS, 8 KiB files, resume, bounded waits, cleanup and artifacts passed\n";
