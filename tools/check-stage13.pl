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
my $ftp_cli = slurp('src/lib/stage9_cli.asm', 0);
my $dlspeed = slurp('src/apps/dlspeed.asm', 0);
my $dldirect = slurp('src/apps/dldirect.asm', 0);
my $libman = slurp('src/lib/libman13.asm', 0);
my $transport = slurp('src/lib/tcp_transport.asm', 0);
my $memory = slurp('src/include/memory.inc', 0);
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
die "DLDIRECT no longer paces its receive right edge across RECV boundaries\n"
    unless $transport =~ /TCPX_WIDE_DIRECT_WINDOW[\s\S]*?LD\s+HL,\(TCP_DIRECT_EDGE_VAR\)[\s\S]*?LD\s+BC,TCP_DIRECT_EDGE_STEP[\s\S]*?LD\s+BC,\(TCP_DIRECT_WINDOW_VAR\)[\s\S]*?LD\s+\(TCP_DIRECT_EDGE_VAR\),HL/ &&
           $transport =~ /HANDLE_SYN_ACK[\s\S]*?TCP_STATE_ESTABLISHED\s*\n\s*IFDEF\s+TCPX_WIDE_DIRECT_WINDOW[\s\S]*?TCP_DIRECT_INITIAL_EDGE[\s\S]*?LD\s+\(TCP_DIRECT_EDGE_VAR\),HL[\s\S]*?JP\s+SEND_SEGMENT/ &&
           $tcpinc =~ /^TCP_DIRECT_EDGE_STEP\s+EQU\s+2\s*\*\s*TCP_MSS\s*$/m;
die "DLDIRECT no longer acknowledges each direct segment\n"
    unless $transport =~ /TCPX_WIDE_DIRECT_WINDOW[^\n]*\n(?:\s*;[^\n]*\n)*(?:\s*IFDEF\s+TCPX_OOO_QUEUE\s*\n(?:[^\n]*\n)*?\s*CALL\s+OOO_DRAIN\s*\n\s*ENDIF\s*\n)?\s*LD\s+HL,S11_ACK_OWED\s*\n\s*INC\s+\(HL\)\s*\n\s*CALL\s+SEND_OWED_ACK/;
# Р4: segments past a hole are kept in a DSS page over WIN3 and handed over as
# soon as the hole fills, both on the direct path (before its ACK) and at the
# top of every RECV; the page is released on the common exit.
die "DLDIRECT no longer keeps segments that arrive past a hole\n"
    unless $dldirect =~ /DEFINE\s+TCPX_OOO_QUEUE/ &&
           $dldirect =~ /DEFINE\s+TCPX_SHARED_TX/ &&
           $transport =~ /CALL\s+NZ,DTUNE_COUNT_OUT_OF_ORDER\s*\n\s*ENDIF\s*\n\s*IFDEF\s+TCPX_OOO_QUEUE\s*\n\s*CALL\s+NZ,OOO_STORE[^\n]*\n\s*ENDIF[^\n]*\n\s*JP\s+NZ,\.ACK_CURRENT/ &&
           $transport =~ /JP\s+NZ,\.RECV_COPY\s*\n\s*IFDEF\s+TCPX_OOO_QUEUE\s*\n\s*CALL\s+OOO_DRAIN/ &&
           $transport =~ /OOO_COPY\s*\n\s*PUSH\s+BC\s*\n\s*LD\s+BC,PAGE3\s*\n\s*IN\s+A,\(C\)[\s\S]*?LDIR\s*\n\s*LD\s+A,\(OOO_SAVED_WIN3\)\s*\n\s*LD\s+BC,PAGE3\s*\n\s*OUT\s+\(C\),A/ &&
           $dldirect =~ /EXIT_NO_RESULT[\s\S]*?CALL\s+OOO_FREE[\s\S]*?LD\s+C,DSS_EXIT/ &&
           $dldirect =~ /ASSERT\s+\$\s*<=\s*S12_IMAGE_LIMIT/;
# After a filled hole the idle receive loop reopens the window one MSS per
# window update instead of waiting for data to clock its growth.
die "DLDIRECT no longer reopens its window from the idle loop after a hole\n"
    unless $transport =~ /\.WAIT_IDLE[^\n]*\n(?:[^\n]*\n)*?\s*IFDEF\s+TCPX_OOO_QUEUE\s*\n\s*JR\s+NZ,\.WAIT_IDLE_RETURN\s*\n\s*CALL\s+IDLE_OPEN\s*\n\s*RET\s+C/ &&
           $transport =~ /IDLE_OPEN\n[\s\S]*?LD\s+A,\(OOO_COUNT\)[\s\S]*?LD\s+\(TCP_DIRECT_WINDOW_VAR\),HL[\s\S]*?JP\s+SEND_OWED_ACK/ &&
           $transport =~ /OOO_DRAIN\n[\s\S]*?LD\s+A,TCP_DIRECT_PACE_POLLS\s*\n\s*LD\s+\(TCP_DIRECT_PACE_VAR\),A/ &&
           $tcpinc =~ /^TCP_DIRECT_PACE_POLLS\s+EQU\s+4\s*$/m;
# A hole leaves the peer as many duplicate ACKs as there were segments behind
# it, which under a paced window can be fewer than the three a fast retransmit
# needs. The idle loop repeats the last one, unchanged, a bounded number of
# times.
die "DLDIRECT no longer repeats its duplicate ACK while a hole is open\n"
    unless $transport =~ /IDLE_OPEN\n[\s\S]*?JR\s+NZ,\.IDLE_HOLE[\s\S]*?\.IDLE_HOLE\s*\n(?:\s*;[^\n]*\n)*\s*LD\s+HL,TCP_DIRECT_HOLE_VAR\s*\n\s*LD\s+A,\(HL\)\s*\n\s*OR\s+A\s*\n\s*JR\s+Z,\.IDLE_OFF\s*\n\s*DEC\s+\(HL\)\s*\n\s*JR\s+\.IDLE_ACK/ &&
           $transport =~ /LD\s+A,TCP_DIRECT_HOLE_ACKS\s*\n\s*LD\s+\(TCP_DIRECT_HOLE_VAR\),A/ &&
           $dldirect =~ /^TCP_DIRECT_HOLE_VAR\s+EQU\s+DTUNE_HOLE_ACKS\s*$/m &&
           $tcpinc =~ /^TCP_DIRECT_HOLE_ACKS\s+EQU\s+8\s*$/m;
die "DLDIRECT no longer grows its window one MSS per window of segments\n"
    unless $transport =~ /LD\s+HL,TCP_DIRECT_GROW_VAR[\s\S]*?DEC\s+\(HL\)[\s\S]*?LD\s+A,\(TCP_DIRECT_TARGET_VAR\)[\s\S]*?LD\s+BC,TCP_MSS[\s\S]*?LD\s+\(TCP_DIRECT_WINDOW_VAR\),HL[\s\S]*?LD\s+HL,\(TCP_DIRECT_EDGE_VAR\)/ &&
           $dldirect =~ /CONFIGURE_DIRECT_WINDOW[\s\S]*?TCP_DIRECT_INITIAL_SEGMENTS[\s\S]*?LD\s+\(DTUNE_WINDOW_GROW\),HL/ &&
           $tcpinc =~ /^TCP_DIRECT_WINDOW_SEGMENTS\s+EQU\s+12\b/m &&
           $tcpinc =~ /^TCP_DIRECT_INITIAL_SEGMENTS\s+EQU\s+3\s*$/m;
die "DLDIRECT no longer batches eleven segments in its 6 KiB caller buffer\n"
    unless $dldirect =~ /LD\s+BC,STAGE9_FILE_CAPACITY[\s\S]*?CALL\s+\@TCPX\.RECV/;
die "DLDIRECT no longer reports the idle RX FIFO it runs against\n"
    unless $dldirect =~ /CONFIGURE_DIRECT_WINDOW[\s\S]*?EL3_W3_RX_FREE[\s\S]*?LD\s+\(DTUNE_FIFO_FREE\),HL/ &&
           $el3inc =~ /^EL3_W3_RX_FREE\s+EQU\s+0x0A\s*$/m;

die "FTP's two durable receive queues are the same size again\n"
    unless $ftp =~ /DEFINE\s+TCPX_SPLIT_PENDING/ &&
           $transport =~ /TCPX_SPLIT_PENDING[\s\S]*?S11_PENDING1_CAPACITY/;
# The control queue is the shallow one and the data queue the deep one, which
# only holds because FTP_DATA_CHANNEL is 1. Swapping them assembles and runs
# and simply makes the transfer slower, so pin the pairing here rather than
# leaving it to a benchmark.
die "FTP gave the shallow receive queue to its data channel\n"
    unless $ftp =~ /FTP_DATA_CHANNEL\s+EQU\s+1/ &&
           $memory =~ /S11_PENDING_CAPACITY\s+EQU\s+0x05B4[\s\S]{0,120}?S11_PENDING1_CAPACITY\s+EQU\s+0x0B68/;
# FTP runs the same receive path as DLDIRECT and the DLL, paid for by starting
# its WIN2 data area 2 KiB above PAGE_BASE. Pin all three halves: the defines,
# the layout that makes room for them, and the image bound that uses it.
die "FTP lost the session receive path\n"
    unless $ftp =~ /DEFINE\s+TCPX_DIRECT_RX/ &&
           $ftp =~ /DEFINE\s+EL3_SESSION_RX/ &&
           $ftp =~ /DEFINE\s+FAST_DATAPATH/;
die "FTP's data area no longer starts 2 KiB above PAGE_BASE\n"
    unless $memory =~ /IFDEF TCPX_LARGE_MSS\n[\s\S]*?STAGE9_TX_BUFFER\s+EQU\s+PAGE_BASE \+ 0x0800[\s\S]*?STAGE9_FILE_CAPACITY\s+EQU\s+0x0800[\s\S]*?S13_IMAGE_LIMIT\s+EQU\s+STAGE9_TX_BUFFER/ &&
           $ftp =~ /ASSERT \$ <= S13_IMAGE_LIMIT/ &&
           slurp('src/lib/stage11_app.asm', 0) =~ /LD\s+HL,STAGE9_TX_BUFFER\s*\n\s*LD\s+DE,STAGE9_TX_BUFFER\+1/;
# One whole segment per RECV lands straight in the disk buffer; a partial
# request would route a segment through the pending queue and copy it twice.
# The flush keeps DSS_WRITE sector-aligned by writing whole sectors only.
die "FTP RETR no longer requests exactly one segment per RECV\n"
    unless $ftp =~ /GET_LOOP\n[\s\S]{0,400}?LD\s+BC,TCP_MSS\s*\n[\s\S]{0,80}?CALL\s+\@TCPX\.RECV/;
die "FTP RETR no longer writes whole sectors and slides the remainder\n"
    unless $ftp =~ /FLUSH_SECTORS\n[\s\S]{0,200}?AND\s+0xFE[\s\S]{0,300}?LDIR/;
# The window-closed latch must be settled before RECV decides it has no room
# for another segment, or the reopening update is never sent (see the comment
# in tcp_transport.asm's RECV): pin the order.
die "RECV decides on room before reopening a closed window\n"
    unless $transport =~ /BIT\s+0,\(IX\+CTX_WINDOW_CLOSED\)\s*\n\s*JR\s+Z,\.RECV_ROOM_DECIDED\s*\n\s*PUSH\s+AF[\s\S]{0,120}?POP\s+AF\s*\n\.RECV_ROOM_DECIDED\s*\n\s*JR\s+C,\.RECV_SUCCESS/;
die "the single-slot DLL took the split-queue capacities meant for FTP\n"
    if slurp('src/dll/unet509b.asm', 0) =~ /DEFINE\s+TCPX_SPLIT_PENDING/;

die "FTP client is not PASV-only (found an active-mode PORT command or a LISTEN call)\n"
    if $ftp =~ /DB\s+"PORT[\s"]|CMD_PORT|\bLISTEN\b/;
die "FTP does not implement REST + RETR\n"
    unless $ftp =~ /CMD_REST\s+DB/ && $ftp =~ /CMD_RETR\s+DB/;
die "FTP -n does not select NLST separately from LIST\n"
    unless $memory =~ /F13_FLAG_LIST_MASK\s+EQU\s+0x08/ &&
           $memory =~ /F13_FLAG_NLST_BIT\s+EQU\s+4/ &&
           $memory =~ /F13_FLAG_NLST_MASK\s+EQU\s+0x10/ &&
           $ftp_cli =~ /DB\s+'N',F13_FLAG_LIST_MASK\s*\|\s*F13_FLAG_NLST_MASK/ &&
           $ftp =~ /CMD_NLST\s+DB/;
die "FTP NLST does not retry LIST after exactly one 5xx refusal\n"
    unless $ftp =~ /BIT\s+F13_FLAG_NLST_BIT,A[\s\S]{0,180}?CMD_NLST[\s\S]{0,700}?
                 BIT\s+F13_FLAG_NLST_BIT,A[\s\S]{0,120}?CP\s+'5'[\s\S]{0,180}?
                 RES\s+F13_FLAG_NLST_BIT,\(HL\)[\s\S]{0,240}?MSG_NLST_FALLBACK[\s\S]{0,180}?
                 JP\s+\.SEND_LIST_VERB/x;
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
    # FTP's data area starts at 0x8800 (memory.inc's S13_IMAGE_LIMIT), the
    # direct benchmark's at 0x8400 (S12_IMAGE_LIMIT: its TCP and DNS frames
    # are built in the receive buffer).
    die "$exe_name.EXE runs into its runtime data area\n"
        if 0x4080 + length($exe) > ($exe_name eq 'FTP' ? 0x8800 : 0x8400);
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
    for my $tag ('PASV', '227', '226', 'NLST', 'refuse-nlst') {
        die "Stage 13 responder lacks $tag\n" unless $responder =~ /\Q$tag\E/;
    }
}

print "Stage 13 host contract: PASV-only, two channels, REST/RETR/LIST/NLST, bounded RTC/waits, golden pin, cleanup and artifacts passed\n";
