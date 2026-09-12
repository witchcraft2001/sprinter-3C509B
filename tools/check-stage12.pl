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
# WGET announces a 1460-byte MSS, so both staging buffers must hold a whole
# 1,514-byte Ethernet frame. The receive one is load-bearing: READ_FRAME
# rejects a frame larger than the capacity it is handed, so a 1 KiB buffer
# here would drop every full-size data segment instead of merely being slow.
# The disk buffer pays for the extra KiB and is the right thing to spend: it
# only batches DSS writes, while the frame buffers decide whether the fast
# path works at all.
die "WGET frame staging buffers no longer hold a whole 1514-byte frame\n"
    unless $code =~ /IFDEF WGET_LAYOUT\n[\s\S]*?STAGE9_TX_BUFFER\s+EQU\s+PAGE_BASE \+ 0x0800\n[\s\S]*?STAGE9_TX_CAPACITY\s+EQU\s+0x0600[\s\S]*?STAGE9_RX_CAPACITY\s+EQU\s+0x0600[\s\S]*?STAGE9_FILE_CAPACITY\s+EQU\s+0x0C00[\s\S]*?STAGE9_MAX_FRAME\s+EQU\s+14 \+ 20 \+ 20 \+ 1460\nS12_IMAGE_LIMIT\s+EQU\s+STAGE9_TX_BUFFER/;
# WGET runs the session receive path; its image is paid for by the data area
# starting 2 KiB above PAGE_BASE (S12_IMAGE_LIMIT), and the body is received one
# whole segment per RECV straight into the disk buffer, flushed in whole sectors.
die "WGET lost the session receive path or its layout\n"
    unless slurp('src/apps/wget.asm', 0) =~ /DEFINE\s+WGET_LAYOUT\s*\n\s*DEFINE\s+EL3_SESSION_RX/ &&
           slurp('src/apps/wget.asm', 0) =~ /ASSERT \$ <= S12_IMAGE_LIMIT/ &&
           slurp('src/apps/wget.asm', 0) =~ /\.RX_DIRECT\n[\s\S]{0,120}?LD\s+BC,TCP_MSS\s*\n[\s\S]{0,80}?CALL\s+\@TCPX\.RECV/ &&
           slurp('src/apps/wget.asm', 0) =~ /FLUSH_SECTORS\n[\s\S]{0,200}?AND\s+0xFE[\s\S]{0,300}?LDIR/;
# The advertised receive window is the whole point of the Stage 12 transport
# tuning: it must be the room actually left in the pending region, never the
# full-or-nothing value it started as, which closed the window on every accepted
# segment and made the peer stop after each MSS.
my $transport = slurp('src/lib/tcp_transport.asm', 0);
die "Stage 12 advertises a binary receive window instead of real free space\n"
    unless $transport =~ /HL = free = CAPACITY - OFF - LEN/ &&
           $transport !~ /LD\s+HL,TCP_RECV_WINDOW\s*\n\s*JP\s+Z,\.WINDOW_OPEN/ &&
           $transport =~ /silly window syndrome/;
# The receive window must stay several whole segments deep in both arms: that
# is what lets the peer keep more than one segment in flight instead of
# stopping for each acknowledgement.
my $tcp_inc = slurp('src/include/tcp.inc', 0);
die "Stage 12 receive window is no longer several segments deep\n"
    unless $tcp_inc =~
           /IFDEF STAGE12_LAYOUT\n\tIFDEF TCPX_LARGE_MSS\n[\s\S]*?\nTCP_RECV_SEGMENTS\s+EQU\s+[2-9]\n\tELSE\nTCP_RECV_SEGMENTS\s+EQU\s+[2-9]\n/ &&
           $code =~ /IFDEF TCPX_LARGE_MSS\nS11_PENDING_CAPACITY\s+EQU\s+0x0B68/;
# WGET raises its MSS; UNET509B.DLL must not. The DLL's durable queue is one
# MSS-sized slot per channel, and at 1460 that degenerates into a zero-window
# stop/start cycle -- the sibling RTL8019A kit draws the same line for the same
# reason. Pin both halves: the constant itself, and who is allowed to ask.
die "WGET no longer announces the whole-Ethernet MSS\n"
    unless $tcp_inc =~ /IFDEF TCPX_LARGE_MSS\nTCP_MSS\s+EQU\s+1460\n\tELSE\nTCP_MSS\s+EQU\s+536\n/ &&
           slurp('src/apps/wget.asm', 0) =~ /DEFINE\s+TCPX_LARGE_MSS/;
die "UNET509B.DLL must stay at the 536-byte MSS\n"
    if slurp('src/dll/unet509b.asm', 0) =~ /DEFINE\s+TCPX_LARGE_MSS/;
# The body must land in the disk buffer directly. Routing it through
# S11_APP_BUFFER chopped every whole-MSS segment into three RECV calls (that
# buffer is 544 bytes) and copied every byte a second time on the way out --
# about a tenth of WGET's total work on a 200 KiB download. Only the headers,
# which PROCESS_CHUNK scans a byte at a time, still go through the staging
# buffer.
die "WGET no longer receives the body straight into its disk buffer\n"
    unless slurp('src/apps/wget.asm', 0) =~
        /\.RX_DIRECT\n[\s\S]{0,200}?LD\s+HL,STAGE9_FILE_BUFFER[\s\S]{0,200}?CALL\s+\@TCPX\.RECV/;

die "Stage 12 test responders answer one segment per frame\n"
    unless slurp('tools/host/stage12_responder.py', 0) =~ /while connection\["pending"\]:/ &&
           $code =~ /Keep sending while the window the client advertised still has room/;

die "Stage 12 layout assertions are incomplete\n"
    unless $code =~ /W12_STATE_BASE \+ 0x40 <= S11_APP_BUFFER/ &&
           $code =~ /S9_TFTP_ERROR_DESC \+ 10 <= S10_RUNTIME_STACK_TOP - 0x0100/ &&
           $code =~ /ASSERT \$ <= S12_IMAGE_LIMIT/;
die "Stage 12 does not preserve the IX command record before its first DSS call\n"
    unless $code =~ /SAVE_COMMAND[\s\S]*LDIR[\s\S]*ALLOCATE_FRESH[\s\S]*DSS_GETMEM/ &&
           $code =~ /S10_COMMAND_BUFFER\s+EQU\s+0x4000/;
# WGET runs the standard DSS layout: the program owns WIN1+WIN2 as one region,
# so it claims no page, and both stacks live at the top of WIN2. Re-introducing
# a GETMEM/SETWIN2 claim would put the entry stack back inside a window that is
# remapped under it, which is what used to make oversized images fail silently.
die "Stage 12 no longer runs the standard WIN1+WIN2 layout\n"
    unless $code =~ /PAGE_BASE\s+EQU\s+0x8000/ &&
           $code =~ /S10_STACK_TOP\s+EQU\s+0xBFF0/ &&
           $code =~ /No GETMEM: WIN2 is the program's own second window/ &&
           $code =~ /S10_RUNTIME_STACK_TOP\s+EQU\s+PAGE_BASE \+ 0x3FF0/;
die "Stage 12 prints before its runtime page is claimed\n"
    unless $code =~ /ALLOCATE_FRESH\s*\n\s*JP\s+C,BOOT_FAIL\s*\n\s*LD\s+SP,S10_RUNTIME_STACK_TOP/ &&
           $code =~ /BOOT_FAIL\s*\n\s*DSS_RETURN/;
die "WGET cleanup does not close file then driver before exit\n"
    unless $code =~ /EXIT_NO_RESULT[\s\S]*DSS_CLOSE_FILE[\s\S]*NETDRV\.DONE[\s\S]*DSS_EXIT/;
die "WGET may report success after a failed final file close\n"
    unless $code =~ /DOWNLOAD_DONE[\s\S]*CLOSE_OUTPUT[\s\S]*JP\s+C,FILE_FAIL/ &&
           $code =~ /CLOSE_OUTPUT[\s\S]*DSS_CLOSE_FILE[\s\S]*RET\s+C/;

my $exe = slurp('build/WGET.EXE', 1);
die "WGET.EXE has invalid DSS header\n"
    unless substr($exe, 0, 4) eq "EXE\x01" && unpack('v', substr($exe, 4, 2)) == 128 &&
           unpack('v', substr($exe, 16, 2)) == 0x4100 &&
           unpack('v', substr($exe, 20, 2)) == 0xBFF0;
# The image is code and rodata loaded at 4080h; the runtime data area starts
# 2 KiB above PAGE_BASE (8800h, memory.inc's S12_IMAGE_LIMIT), so that bounds
# it. The header stack sits at the top of WIN2, a whole window above, and must
# stay clear of the data area's top.
die "WGET.EXE runs into its runtime data area\n"
    if 0x4080 + length($exe) > 0x8800;
die "WGET.EXE entry stack is not at the top of WIN2\n"
    if unpack('v', substr($exe, 20, 2)) != 0xBFF0;
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

print "Stage 12 host contract: sibling golden UX, HTTP/DNS, 6 KiB files, resume, bounded waits, cleanup and artifacts passed\n";
