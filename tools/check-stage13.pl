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
    src/apps/ftp.asm src/apps/dlspeed.asm src/apps/dldirect.asm src/lib/http_stream.asm
    src/lib/stage9_cli.asm src/lib/libman13.asm
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
my $dldirect = slurp('src/apps/dldirect.asm', 0);
my $libman = slurp('src/lib/libman13.asm', 0);
my $transport = slurp('src/lib/tcp_transport.asm', 0);
my $tcpinc = slurp('src/include/tcp.inc', 0);
my $el3inc = slurp('src/include/el3.inc', 0);
die "Stage 13 FTP contains an unbounded interrupt wait\n" if $ftp =~ /\b(?:HALT|EI)\b/;
die "Stage 13 DLSPEED contains an unbounded interrupt wait\n" if $dlspeed =~ /\b(?:HALT|EI)\b/;

die "FTP is not polling-only with finite control/data timeouts\n"
    unless $ftp =~ /FTP_REPLY_TIMEOUT_MS\s+EQU\s+\d+/ &&
           $ftp =~ /FTP_DATA_IDLE_MS\s+EQU\s+\d+/;
die "DLDIRECT RTC alignment is not finitely bounded\n"
    unless $dldirect =~ /RTC_ALIGN_TIMEOUT_MS\s+EQU\s+\d+/ &&
           $dldirect =~ /WAIT_RTC_EDGE/;
# The countdown that bounds WAIT_RTC_EDGE must live in memory, not a register
# kept live across @S9APP.SECONDS: that call's own RST DSS returns HL as part
# of DSS_SYSTIME's result, so a live-in-HL countdown is silently clobbered
# every iteration and the loop never reaches zero on a frozen/unavailable
# clock -- exactly the hang this bound exists to prevent.
die "DLDIRECT's WAIT_RTC_EDGE keeps its timeout bound in a register instead of memory\n"
    unless $dldirect =~ /LD\s+\(W12_WORK32\),HL\s*\n\.LOOP/;
die "DLSPEED DLL receive is not a single finite 15-second wait\n"
    unless $dlspeed =~ /HTTP_IDLE_MS\s+EQU\s+15000/ &&
           $dlspeed =~ /LD\s+IY,HTTP_IDLE_MS/ &&
           $dlspeed =~ /JP\s+Z,RECV_IDLE_FAIL/;
for my $fn (qw(SETOPT NETINIT CONNECT SEND RECV CLOSE NETDONE)) {
    die "DLSPEED does not use UNET $fn\n" unless $dlspeed =~ /UNET_FN_$fn/;
}
die "DLSPEED bypasses the public DLL path\n"
    if $dlspeed =~ /tcp_transport\.asm|el3_io\.asm|TCPX[.]/i;
die "DLSPEED does not free its libman handle in common cleanup\n"
    unless $dlspeed =~ /CLEANUP[\s\S]*?CALL\s+LIBMAN\.l_free/;
die "libman l_free still tests stale flags instead of slot occupancy\n"
    unless $libman =~ /lf1:\s*ld\s+a,\(hl\)\s*\n\s*or\s+a[^\n]*\n\s*jr\s+z,lf2/;
die "libman close-failure path does not unload an allocated DLL slot\n"
    unless $libman =~ /llclose0:[\s\S]*?call\s+l_free[\s\S]*?pop\s+de[\s\S]*?pop\s+iy[\s\S]*?pop\s+ix[\s\S]*?jr\s+llerr3/;
die "direct benchmark lost its throughput feature set\n"
    unless $dldirect =~ /DEFINE\s+FAST_DATAPATH/ &&
           $dldirect =~ /DEFINE\s+TCPX_DIRECT_RX/ &&
           $dldirect =~ /DEFINE\s+EL3_SESSION_RX/ &&
           $dldirect =~ /DEFINE\s+TCPX_WIDE_DIRECT_WINDOW/;
die "DLDIRECT no longer keeps its FIFO-qualified window across RECV boundaries\n"
    unless $transport =~ /TCPX_WIDE_DIRECT_WINDOW[\s\S]*?LD\s+HL,\(TCP_DIRECT_WINDOW_VAR\)/;
die "DLDIRECT no longer advances its wide sliding window every two segments\n"
    unless $transport =~ /TCPX_WIDE_DIRECT_WINDOW[\s\S]*?CP\s+TCP_ACK_EVERY[\s\S]*?CALL\s+SEND_OWED_ACK/;
die "DLDIRECT no longer batches eleven segments in its 6 KiB caller buffer\n"
    unless $dldirect =~ /LD\s+BC,STAGE9_FILE_CAPACITY[\s\S]*?CALL\s+\@TCPX\.RECV/;
die "DLDIRECT no longer selects safe/wide windows from RX FIFO capacity\n"
    unless $dldirect =~ /CONFIGURE_DIRECT_WINDOW[\s\S]*?EL3_W3_RX_FREE[\s\S]*?TCP_DIRECT_RECV_WIDE_FIFO_MIN[\s\S]*?TCP_DIRECT_RECV_WIDE_WINDOW/ &&
           $el3inc =~ /^EL3_W3_RX_FREE\s+EQU\s+0x0A\s*$/m &&
           $tcpinc =~ /^TCP_DIRECT_RECV_SAFE_SEGMENTS\s+EQU\s+8\s*$/m &&
           $tcpinc =~ /^TCP_DIRECT_RECV_WIDE_SEGMENTS\s+EQU\s+11\s*$/m &&
           $tcpinc =~ /^TCP_DIRECT_RECV_WIDE_FIFO_MIN\s+EQU\s+TCP_DIRECT_RECV_WIDE_SEGMENTS\s*\*\s*TCP_DIRECT_RECV_FIFO_FRAME\s*$/m;

die "FTP client is not PASV-only (found an active-mode PORT command or a LISTEN call)\n"
    if $ftp =~ /DB\s+"PORT[\s"]|CMD_PORT|\bLISTEN\b/;
die "FTP does not implement REST + RETR\n"
    unless $ftp =~ /CMD_REST\s+DB/ && $ftp =~ /CMD_RETR\s+DB/;
die "FTP no longer treats REST-at-SIZE as an already complete file\n"
    unless $ftp =~ /RESUME_SIZE_COMPARE[\s\S]*?TRANSFER_SUMMARY/;
die "FTP does not use two independent TCP channels\n"
    unless $ftp =~ /FTP_CTRL_CHANNEL\s+EQU\s+0/ && $ftp =~ /FTP_DATA_CHANNEL\s+EQU\s+1/ &&
           $ftp =~ /STAGE13_LAYOUT/;
die "Stage 13 two-channel layout no longer defines both pending regions/contexts\n"
    unless slurp('src/include/memory.inc', 0) =~
           /IFDEF STAGE13_LAYOUT\n; FTP keeps both channels open/;

# TCPX_SINGLE_CONTEXT must stay decoupled from STAGE13_LAYOUT so the FTP data
# channel is reachable at all; the two-channel/deep-window flag refactor is
# the whole reason WGET's own layout stayed byte-for-byte compatible.
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

for my $exe_name (qw(FTP DLDIRECT)) {
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
{
    my $exe = slurp('build/DLSPEED.EXE', 1);
	die "DLSPEED.EXE has invalid standard DSS header\n"
		unless substr($exe, 0, 4) eq "EXE\x01" && unpack('v', substr($exe, 4, 2)) == 128 &&
		       unpack('v', substr($exe, 16, 2)) == 0x8100 &&
		       unpack('v', substr($exe, 20, 2)) == 0x9FF0;
	die "DLSPEED.EXE overlaps its 256-byte ABI stack reserve\n"
		if 0x8080 + length($exe) > 0x9EF0;
    die "DLSPEED.EXE contains zero-filled runtime BSS\n"
        if substr($exe, 128) =~ /\x00{128}/;
}

die "FTP usage string missing\n" unless $ftp =~ /Usage:/;
for my $text ('"anonymous"', '"anonymous@"') {
    die "FTP default login string missing: $text\n" unless $code =~ /\Q$text\E/;
}
for my $text ('Usage:', 'RTC edge', 'UNET509B.DLL') {
    die "DLSPEED user string missing: $text\n" unless $dlspeed =~ /\Q$text\E/;
}
for my $text ('Usage:', 'RTC edge', 'DLDIRECT') {
    die "DLDIRECT user string missing: $text\n" unless $dldirect =~ /\Q$text\E/;
}

my $artifacts = slurp('tools/artifacts.sh', 0);
for my $required ('build/FTP.EXE|FTP.EXE', 'docs/FTP.md|FTP.TXT',
                  'build/DLSPEED.EXE|DLSPEED.EXE', 'docs/DLSPEED.md|DLSPEED.TXT',
                  'build/DLDIRECT.EXE|DLDIRECT.EXE',
                  'docs/STAGE13_TESTING_RU.md|S13TEST.TXT') {
    die "Stage 13 IMG artifact missing: $required\n"
        unless $artifacts =~ /IMG_ARTIFACTS[\s\S]*?\Q$required\E/;
}
my ($zip) = $artifacts =~ /(ZIP_ARTIFACTS[\s\S]*)/;
die "FTP user artifacts are missing from ZIP\n"
    unless $zip && $zip =~ /build\/FTP\.EXE\|FTP\.EXE/ && $zip =~ /docs\/FTP\.md\|FTP\.TXT/;
die "Stage 13 developer/test artifacts leaked into ZIP\n"
    if $zip =~ /DLSPEED|DLDIRECT|S13TEST|STAGE13_TEST/i;

if (-f File::Spec->catfile($root, 'tools/host/stage13_responder.py')) {
    my $responder = slurp('tools/host/stage13_responder.py', 0);
    for my $tag ('PASV', '227', '226') {
        die "Stage 13 responder lacks $tag\n" unless $responder =~ /\Q$tag\E/;
    }
}

print "Stage 13 host contract: PASV-only, two channels, REST/RETR, bounded RTC/waits, golden pin, cleanup and artifacts passed\n";
