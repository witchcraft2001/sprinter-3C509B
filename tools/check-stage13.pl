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
    src/apps/ftp.asm src/apps/dlspeed.asm src/lib/stage9_cli.asm
    src/lib/file.asm src/lib/tcp_transport.asm src/lib/netdrv.asm
    src/include/memory.inc src/include/dss.inc tools/exe-harness/harness.js
);
my $code = join "\n", map { slurp($_, 0) } @sources;
die "Stage 13 added forbidden IRQ routing\n"
    if $code =~ /irq\d*_callback|set_input_line|IRQ_(?:ACK|ENABLE)/i;
die "Stage 13 added EEPROM writes\n"
    if $code =~ /EEPROM_(?:WRITE|ERASE)|WRITE_EEPROM/i;

my $ftp = slurp('src/apps/ftp.asm', 0);
my $dlspeed = slurp('src/apps/dlspeed.asm', 0);
die "Stage 13 FTP contains an unbounded interrupt wait\n" if $ftp =~ /\b(?:HALT|EI)\b/;
die "Stage 13 DLSPEED contains an unbounded interrupt wait\n" if $dlspeed =~ /\b(?:HALT|EI)\b/;

die "FTP is not polling-only with finite control/data timeouts\n"
    unless $ftp =~ /FTP_REPLY_TIMEOUT_MS\s+EQU\s+\d+/ &&
           $ftp =~ /FTP_DATA_IDLE_MS\s+EQU\s+\d+/;
die "DLSPEED RTC alignment is not finitely bounded\n"
    unless $dlspeed =~ /RTC_ALIGN_TIMEOUT_MS\s+EQU\s+\d+/ &&
           $dlspeed =~ /WAIT_RTC_EDGE/;
# The countdown that bounds WAIT_RTC_EDGE must live in memory, not a register
# kept live across @S9APP.SECONDS: that call's own RST DSS returns HL as part
# of DSS_SYSTIME's result, so a live-in-HL countdown is silently clobbered
# every iteration and the loop never reaches zero on a frozen/unavailable
# clock -- exactly the hang this bound exists to prevent.
die "DLSPEED's WAIT_RTC_EDGE keeps its timeout bound in a register instead of memory\n"
    unless $dlspeed =~ /LD\s+\(W12_WORK32\),HL\s*\n\.LOOP/;

die "FTP client is not PASV-only (found an active-mode PORT command or a LISTEN call)\n"
    if $ftp =~ /DB\s+"PORT[\s"]|CMD_PORT|\bLISTEN\b/;
die "FTP does not implement REST + RETR\n"
    unless $ftp =~ /CMD_REST\s+DB/ && $ftp =~ /CMD_RETR\s+DB/;
die "FTP does not use two independent TCP channels\n"
    unless $ftp =~ /FTP_CTRL_CHANNEL\s+EQU\s+0/ && $ftp =~ /FTP_DATA_CHANNEL\s+EQU\s+1/ &&
           $ftp =~ /STAGE13_LAYOUT/;
die "Stage 13 two-channel layout no longer defines both pending regions/contexts\n"
    unless slurp('src/include/memory.inc', 0) =~
           /IFDEF STAGE13_LAYOUT\n; FTP keeps both channels open/;

# TCPX_SINGLE_CONTEXT must stay decoupled from STAGE13_LAYOUT so the FTP data
# channel is reachable at all; the two-channel/deep-window flag refactor is
# the whole reason WGET's own layout stayed byte-for-byte compatible.
my $transport = slurp('src/lib/tcp_transport.asm', 0);
die "TCPX_SINGLE_CONTEXT no longer excludes STAGE13_LAYOUT\n"
    unless $transport =~ /IFDEF STAGE12_LAYOUT\n\tIFNDEF STAGE13_LAYOUT\n\tDEFINE TCPX_SINGLE_CONTEXT/;

# F13_USER/F13_PASS/F13_OUTPUT_OVERRIDE share the page's command-record range,
# so the CLI must tokenise the WIN1 copy: parsing the page copy lets a -p/-o
# value overwrite the unparsed tail of the very line being read.
my $bootstrap = slurp('src/lib/stage11_app.asm', 0);
die "FTP would parse the page command copy that its own -u/-p/-o buffers overwrite\n"
    unless $bootstrap =~ /IFDEF STAGE13_LAYOUT\n(?:\t;[^\n]*\n)*\tLD\tIX,S10_COMMAND_BUFFER\n/;

my $golden = slurp('tools/test-fixtures/stage13-ftp-golden.json', 0);
die "FTP golden outputs are not pinned to the sibling revision\n"
    unless $golden =~ /9ec98b00c6490fed5eb722c52b47d11c70a199ae/ &&
           $golden =~ /banner.*PASV tuple\/endpoint/s;
die "FTP golden lost the 226 the two-channel design exists to preserve\n"
    unless $golden =~ /"get":[^\n]*226 Transfer complete/;

for my $exe_name (qw(FTP DLSPEED)) {
    my $exe = slurp("build/$exe_name.EXE", 1);
    die "$exe_name.EXE has invalid DSS header\n"
        unless substr($exe, 0, 4) eq "EXE\x01" && unpack('v', substr($exe, 4, 2)) == 128 &&
               unpack('v', substr($exe, 16, 2)) == 0x4100 &&
               unpack('v', substr($exe, 20, 2)) == 0xBFF0;
    die "$exe_name.EXE runs into its runtime data area\n"
        if 0x4080 + length($exe) > 0x8000;
    my $payload = substr($exe, 128);
    die "$exe_name.EXE contains zero-filled runtime BSS\n" if $payload =~ /\x00{128}/;
}

die "FTP usage string missing\n" unless $ftp =~ /Usage:/;
for my $text ('"anonymous"', '"anonymous@"') {
    die "FTP default login string missing: $text\n" unless $code =~ /\Q$text\E/;
}
for my $text ('Usage:', 'RTC edge') {
    die "DLSPEED user string missing: $text\n" unless $dlspeed =~ /\Q$text\E/;
}

my $artifacts = slurp('tools/artifacts.sh', 0);
for my $required ('build/FTP.EXE|FTP.EXE', 'docs/FTP.md|FTP.TXT',
                  'build/DLSPEED.EXE|DLSPEED.EXE', 'docs/DLSPEED.md|DLSPEED.TXT',
                  'docs/STAGE13_TESTING_RU.md|S13TEST.TXT') {
    die "Stage 13 IMG artifact missing: $required\n"
        unless $artifacts =~ /IMG_ARTIFACTS[\s\S]*?\Q$required\E/;
}
my ($zip) = $artifacts =~ /(ZIP_ARTIFACTS[\s\S]*)/;
die "FTP user artifacts are missing from ZIP\n"
    unless $zip && $zip =~ /build\/FTP\.EXE\|FTP\.EXE/ && $zip =~ /docs\/FTP\.md\|FTP\.TXT/;
die "Stage 13 developer/test artifacts leaked into ZIP\n"
    if $zip =~ /DLSPEED|S13TEST|STAGE13_TEST/i;

if (-f File::Spec->catfile($root, 'tools/host/stage13_responder.py')) {
    my $responder = slurp('tools/host/stage13_responder.py', 0);
    for my $tag ('PASV', '227', '226') {
        die "Stage 13 responder lacks $tag\n" unless $responder =~ /\Q$tag\E/;
    }
}

print "Stage 13 host contract: PASV-only, two channels, REST/RETR, bounded RTC/waits, golden pin, cleanup and artifacts passed\n";
