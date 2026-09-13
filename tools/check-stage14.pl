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

my $shim = slurp('src/dll/unet509b.asm', 0);
my $cold = slurp('src/dll/unet509b_cold.asm', 0);
my $coldctx = slurp('src/include/coldctx.inc', 0);
my $tcpinc = slurp('src/include/tcp.inc', 0);
my $transport = slurp('src/lib/tcp_transport.asm', 0);
my $el3io = slurp('src/lib/el3_io.asm', 0);
my $fifo = slurp('src/lib/el3_fifo.asm', 0);
my $win0cold = slurp('src/lib/win0cold.asm', 0);
my $build = slurp('tools/build.sh', 0);
my $makefile = slurp('Makefile', 0);
my $perf_fast = slurp('tools/perf-fast.sh', 0);
my $artifacts = slurp('tools/artifacts.sh', 0);
my $shim_code = $shim; $shim_code =~ s/;[^\n]*//g;
my $cold_code = $cold; $cold_code =~ s/;[^\n]*//g;
my $coldctx_code = $coldctx; $coldctx_code =~ s/;[^\n]*//g;
my $transport_code = $transport; $transport_code =~ s/;[^\n]*//g;
my $el3io_code = $el3io; $el3io_code =~ s/;[^\n]*//g;
my $fifo_code = $fifo; $fifo_code =~ s/;[^\n]*//g;
my $win0cold_code = $win0cold; $win0cold_code =~ s/;[^\n]*//g;

die "Stage 14 added forbidden IRQ routing\n"
    if $shim_code =~ /irq\d*_callback|IRQ_(?:ACK|ENABLE)/i
    || $cold_code =~ /irq\d*_callback|IRQ_(?:ACK|ENABLE)/i;
die "Stage 14 added EEPROM writes\n"
    if $shim_code =~ /EEPROM_(?:WRITE|ERASE)|WRITE_EEPROM/i
    || $cold_code =~ /EEPROM_(?:WRITE|ERASE)|WRITE_EEPROM/i;

# The libman export table: exactly 24 JP entries right after MODULE UNET,
# dispatch at image_base + 0x20 + 3*function (sprinter-mkdll's own contract).
# Scanned line-by-line (not a single backtracking regex over the whole file --
# a nested "{24}" quantifier over a near-miss count can blow up the engine).
{
    my @lines = split /\n/, $shim_code;
    my ($start) = grep { $lines[$_] =~ /^\s*MODULE\s+UNET\s*$/ } 0 .. $#lines;
    die "UNET509B.DLL has no 'MODULE UNET' line\n" unless defined $start;
    my $jp_count = 0;
    my $i = $start + 1;
    $i++ while $i <= $#lines && $lines[$i] =~ /^\s*$/;
    while ($i <= $#lines && $lines[$i] =~ /^\s*JP\s+\S+\s*$/) { $jp_count++; $i++; }
    $i++ while $i <= $#lines && $lines[$i] =~ /^\s*$/;
    die "UNET509B.DLL export table is not exactly 24 JP entries after MODULE UNET " .
        "(found $jp_count)\n" unless $jp_count == 24;
    die "UNET509B.DLL export table is not immediately followed by ENDMODULE\n"
        unless $i <= $#lines && $lines[$i] =~ /^\s*ENDMODULE\s*$/;
}

# Capability mask: full parity with UNETRTL (user decision) -- TCP, UDP,
# RESOLVE, PING, MULTICHAN, ASYNCSEND, LISTEN == 0x023F. RAWETH stays
# unclaimed (no backend entry point).
die "UNET509B_CAPS does not assert the full-parity 0x023F mask\n"
    unless $shim_code =~ /UNET509B_CAPS\s+EQU\s+[^\n]*UNET_CAP_TCP[^\n]*UNET_CAP_UDP[^\n]*UNET_CAP_RESOLVE[^\n]*UNET_CAP_PING[^\n]*UNET_CAP_MULTICHAN[^\n]*UNET_CAP_ASYNCSEND[^\n]*UNET_CAP_LISTEN/
    && $shim_code =~ /ASSERT\s+UNET509B_CAPS\s*==\s*0x023F/;

# Image ceiling: 14535 bytes (0x38C7) for hot code + in-image BSS.
die "UNET509B.DLL image ceiling assertion is missing or changed\n"
    unless $shim_code =~ /ASSERT\s+\$\s*<=\s*DLL_IMAGE_ORIGIN\s*\+\s*0x38C7/;
die "UNET509B.DLL no longer reserves the mandatory 16 hot-image bytes\n"
    unless $shim_code =~ /ASSERT\s+\$\s*<=\s*DLL_IMAGE_ORIGIN\s*\+\s*0x38B7/;

# INIT refuses to load into window 3 (the ISA aperture): CALL .here/POP HL to
# find its own window, AND 0xC0 to isolate the window bits, CP 0xC0 to detect
# window 3 specifically.
die "INIT does not detect and refuse its own window 3 placement\n"
    unless $shim_code =~ /^INIT\b.*?AND\s+0xC0.*?CP\s+0xC0/ms;

# NETINIT loads the cold overlay BEFORE it reads the environment: this build's
# NET_HW/NET_IDPORT/NET_IP/NET_MASK parsers are COLD.RUN trampolines, and
# COLD.RUN refuses (CF=1) until COLD.INIT has succeeded, so the reverse order
# turns every correctly configured machine into a permanent NERR_NONET.
{
    my ($netinit) = $shim_code =~ /^F_NETINIT\b(.*?)^F_NETDONE\b/ms;
    die "F_NETINIT not found in unet509b.asm\n" unless defined $netinit;
    my $cold_at = $netinit =~ /\@COLD\.INIT/ ? $-[0] : -1;
    my $cfg_at  = $netinit =~ /\@S9APP\.LOAD_ACTIVE_CONFIG/ ? $-[0] : -1;
    die "F_NETINIT no longer calls \@COLD.INIT and \@S9APP.LOAD_ACTIVE_CONFIG\n"
        if $cold_at < 0 || $cfg_at < 0;
    die "F_NETINIT calls LOAD_ACTIVE_CONFIG before COLD.INIT (the config parsers are cold trampolines)\n"
        if $cold_at > $cfg_at;
}

# Shared error-return exit contract: success returns immediately without
# disturbing a frozen LASTERR. Every non-zero status is stored and formatted
# before return, with DE preserved for SEND/RECV and CF restored clear from
# the entry OR A / saved AF pair.
die "RET_A does not freeze failures while preserving successful calls and DE\n"
    unless $shim_code =~ /^RET_A\b.*?OR\s+A\s*\n\s*RET\s+Z\s*\n\s*LD\s+\(UNET_LAST_NERR\),A.*?PUSH\s+AF\s*\n\s*PUSH\s+DE\s*\n\s*CALL\s+BUILD_LASTERR\s*\n\s*POP\s+DE\s*\n\s*POP\s+AF\s*\n\s*RET\b/ms;
die "F_LASTERR does not keep the frozen snapshot after a failure\n"
    unless $shim_code =~ /^F_LASTERR\b.*?LD\s+A,\(UNET_LAST_NERR\).*?CALL\s+Z,BUILD_LASTERR.*?LD\s+HL,LASTERR_BUF/ms;

# SEND must wake on FIN as well as ACK/RST. The DLL-only completion classifier
# returns a partial confirmed prefix and its CF path bypasses FAIL_CONTEXT, so
# a response queued with the FIN remains available to RECV.
die "TCP SEND wait does not include EVENT_FIN\n"
    unless $transport_code =~ /LD\s+A,EVENT_ACK\|EVENT_FIN\|EVENT_RST\s*\n\s*CALL\s+WAIT_FOR_EVENT/;
die "TCP SEND FIN classifier or queue-preserving return is missing\n"
    unless $transport_code =~ /CFN_TCP_SEND_EVENT.*?CALL\s+\@COLD\.RUN\s*\n\s*JP\s+C,\.SEND_PEER_FIN.*?\.SEND_PEER_FIN\b.*?JP\s+\.SEND_RETURN/ms;
die "cold SEND completion classifier is missing from the dispatch table\n"
    unless $cold_code =~ /DW\s+TCP_SEND_EVENT.*?^TCP_SEND_EVENT\b.*?LD\s+A,TCP_ERR_CLOSED\s*\n\s*SCF/ms;

# The cold overlay (WIN0) never touches ISA, DSS, or a raw RST -- it can only
# reach the outside world via the COLD_CTX pointers and registers it was
# handed, since it is assembled and relocated independently of the hot image
# and physically cannot address hot-image labels directly.
die "unet509b_cold.asm references a forbidden hot-only primitive (RST/\@ISA./DSS_)\n"
    if $cold_code =~ /\bRST\b|\@ISA\.|\bDSS_[A-Z_]+\b/;
# No port I/O either: the ISA window and the MMU ports are hot-side business
# (COLD.RUN itself remaps PAGE0 around the call), and an EI from cold code
# would re-enable interrupts under a remapped window 0.
die "unet509b_cold.asm contains port I/O or EI (IN/OUT/INI/OUTI/INIR/OTIR/IND/OUTD/INDR/OTDR/EI)\n"
    if $cold_code =~ /^\s*(?:IN|OUT|INI|OUTI|INIR|OTIR|IND|OUTD|INDR|OTDR|EI)\b/m;

# Stage 13/14 RX supplement: only the DLL enables the two-phase session path,
# and the transient receive promise is capped at five whole 536-byte MSSes.
die "UNET509B.DLL does not enable the session/direct RX implementation\n"
    unless $shim_code =~ /^\s*DEFINE\s+TCPX_DIRECT_RX\s*$/m
    && $shim_code =~ /^\s*DEFINE\s+EL3_SESSION_RX\s*$/m;
die "DLL receive window is not capped at five 536-byte segments\n"
    unless $tcpinc =~ /^TCP_MSS\s+EQU\s+536\s*$/m
    && $tcpinc =~ /^TCP_RECV_MAX_SEGMENTS\s+EQU\s+5\s*$/m
    && $tcpinc =~ /^TCP_RECV_MAX_WINDOW\s+EQU\s+TCP_RECV_MAX_SEGMENTS\s*\*\s*TCP_MSS\s*$/m;
die "cold fast RX does not retain the mandatory IPv4 checksum/filter path\n"
    unless $cold_code =~ /^TCP_FAST_RECEIVE\b.*?CALL\s+\@ETHERNET\.VERIFY_CHECKSUM.*?TCP_FLAG_ACK/ms;
die "safe/fast cold RX policy is not confined to the payload callback\n"
    unless $cold_code =~ /IFNDEF\s+TCPX_UNCHECKED_DATA_RX.*?CCTX_CB_RX_PAYLOAD_SUM.*?ELSE.*?CCTX_CB_RX_PAYLOAD.*?ENDIF/ms;
die "cold fast RX bypasses the two hot callback boundary\n"
    unless $coldctx_code =~ /^CCTX_CB_RX_PAYLOAD\s+EQU\s+/m
    && $coldctx_code =~ /^CCTX_CB_RX_PAYLOAD_SUM\s+EQU\s+/m
    && $shim_code =~ /\@EL3IO\.RX_PAYLOAD\s*,\s*\@EL3IO\.RX_PAYLOAD_SUM/;

# One RECV owns a direct-delivery scope, drains repeatedly, ACKs the first
# segment and then pairs, and closes the transient window before its final
# durable-only ACK. These anchors deliberately cover both ends of the
# hot/cold contract instead of merely checking that FAST_RECEIVE exists.
die "RECV does not keep a caller direct-delivery scope\n"
    unless $transport_code =~ /^RECV\b.*?S11_RX_DEST.*?S11_RX_FREE.*?S11_RX_DELIVERED.*?CALL\s+WAIT_FOR_EVENT/ms;
die "direct RX no longer sends the first ACK and cumulative pair ACKs\n"
    unless $transport_code =~ /^\.SESSION_FAST\b.*?CP\s+1.*?CALL\s+SEND_OWED_ACK.*?CP\s+TCP_ACK_EVERY.*?CALL\s+SEND_OWED_ACK/ms;
die "RECV does not close direct scope before its final durable-window ACK\n"
    unless $transport_code =~ /^\.RECV_RETURN\b.*?LD\s+\(S11_RX_FREE\),HL.*?CALL\s+SEND_OWED_ACK/ms;
die "DLL ACK construction is not a single combined cold call\n"
    unless $transport_code =~ /^SEND_SEGMENT_COMMON\b.*?CFN_TCP_IP_BUILD.*?CALL\s+\@COLD\.RUN.*?JP\s+\@NETDRV\.SEND_FRAME/ms
    && $cold_code =~ /^TCP_IP_BUILD\b.*?CALL\s+\@TCP\.BUILD.*?CALL\s+\@IPV4\.BUILD/ms;

# TX normal path: one session through stale statuses, free-space check, FIFO
# write and exactly 256 fast completion reads. The only later wait happens
# after CLOSE, and timeout recovery must not branch back to SEND_ATTEMPT.
{
    my ($session) = $el3io_code =~ /^TX_SESSION\b(.*?)^TXB_WRITE_BARE\b/ms;
    die "EL3IO.TX_SESSION is missing\n" unless defined $session;
    my @need = ('EL3_W1_TX_STATUS', '.TXB_STALE', 'EL3_W1_TX_FREE',
                'TXB_WRITE_BARE', 'LD\s+B\s*,\s*0',
                'DJNZ\s+\.TXB_COMPLETE_FAST', '\@ISA\.CLOSE',
                '\@EL3\.WAIT_QUANTUM');
    my $at = 0;
    for my $needle (@need) {
        pos($session) = $at;
        die "EL3IO.TX_SESSION ordering lost at $needle\n"
            unless $session =~ /$needle/g;
        $at = pos($session);
    }
    die "SEND_FRAME no longer uses the shared TX session\n"
        unless $fifo_code =~ /^SEND_FRAME\b.*?CALL\s+\@EL3IO\.TX_SESSION/ms;
    my ($timeout) = $fifo_code =~ /^\.SEND_TIMEOUT_OR_IO\b(.*?)^\.SEND_RETURN\b/ms;
    die "SEND_FRAME TX timeout handler is missing\n" unless defined $timeout;
    die "unknown TX completion is retransmitted\n" if $timeout =~ /SEND_ATTEMPT/;
    die "TX timeout no longer recovers the transmitter with a stable timeout result\n"
        unless $timeout =~ /CALL\s+TX_RECOVER_RESET.*?LD\s+A\s*,\s*EL3_ERR_TX_TIMEOUT.*?SCF/ms;
}

# The cold blob may consume the lower page only. Its private stack is the
# exact upper 128 bytes and therefore does not inflate the hot L1 image.
die "cold overlay no longer reserves 0x3F80..0x3FFF for its private stack\n"
    unless $cold_code =~ /ASSERT\s+\$\s*<=\s*0x3F80/
    && $win0cold_code =~ /LD\s+SP\s*,\s*0x4000/;

# The checksum-skipping variant is a separate, non-release image. The define
# is passed only to the cold assembly; the public L1 hot image remains common.
die "Makefile has no perf-fast target\n"
    unless $makefile =~ /^perf-fast:\s*\n\s*tools\/perf-fast\.sh\s*$/m;
die "perf-fast does not isolate its build and enable the cold policy define\n"
    unless $perf_fast =~ /build\/perf-fast/
    && $perf_fast =~ /BUILD_DIR="\$fast_dir"\s+TCPX_UNCHECKED_DATA_RX=1\s+"\$script_dir\/build\.sh"/;
die "build.sh does not confine TCPX_UNCHECKED_DATA_RX to cold_defines\n"
    unless $build =~ /TCPX_UNCHECKED_DATA_RX.*?cold_defines\+=\(-DTCPX_UNCHECKED_DATA_RX\).*?unet509b_cold\.asm/ms;
die "non-release perf-fast path leaked into the artifact manifest\n"
    if $artifacts =~ /build\/perf-fast|sprinter-3c509b-fast/i;

# Every COLD_CTX field the blob dereferences must be filled in by
# FILL_COLD_CTX. An unfilled pointer is not a null that faults: inside a cold
# call window 0 holds the blob itself, so a routine that WRITES through it
# (BUILD_FRAME and PING_BUILD_ECHO both store the incremented IPv4
# identifier) overwrites the dispatch entry point the next COLD.RUN jumps to,
# with interrupts off and window 0 still remapped -- a dead machine, three
# calls away from the mistake. Only this direction is enforced: coldctx.inc
# may declare an offset the blob has no use for yet.
{
    my ($fill) = $shim_code =~ /^FILL_COLD_CTX\b(.*?)^\s*RET\b/ms;
    die "FILL_COLD_CTX not found in unet509b.asm\n" unless defined $fill;
    die "FILL_COLD_CTX no longer copies one complete CCTX_SIZE table\n"
        unless $fill =~ /LD\s+HL\s*,\s*COLD_CTX_INIT_TABLE.*?
                         LD\s+DE\s*,\s*UNET_COLD_CTX.*?
                         LD\s+BC\s*,\s*CCTX_SIZE.*?\bLDIR\b/msx;
    my ($table) = $shim_code =~ /^COLD_CTX_INIT_TABLE\b(.*?)
        ^\s*ASSERT\s+\$\s*-\s*COLD_CTX_INIT_TABLE\s*==\s*CCTX_SIZE/msx;
    die "COLD_CTX_INIT_TABLE or its exact-size assertion is missing\n"
        unless defined $table;
    my @table_words;
    while ($table =~ /^\s*DW\s+([^\n]+)$/gmi) {
        push @table_words, grep { length } map { s/^\s+|\s+$//gr } split /,/, $1;
    }
    my ($ctx_size) = $coldctx_code =~ /^CCTX_SIZE\s+EQU\s+(\d+)\s*$/m;
    die "CCTX_SIZE must be an even literal\n"
        unless defined $ctx_size && !($ctx_size & 1);
    die "COLD_CTX_INIT_TABLE has " . scalar(@table_words) .
        " words, expected " . ($ctx_size / 2) . "\n"
        unless @table_words == $ctx_size / 2;
    my %used;
    $used{$1} = 1 while $cold_code =~ /\(\s*IX\s*\+\s*(CCTX_[A-Z0-9_]+?)(?:\+1)?\s*\)/g;
    die "no COLD_CTX dereferences found in unet509b_cold.asm\n" unless %used;
    my @missing = sort grep { $coldctx_code !~ /^\Q$_\E\s+EQU\s+/m } keys %used;
    die "unet509b_cold.asm reads undeclared CCTX fields: @missing\n"
        if @missing;
}

# UDP_CTX_PTR hands the channel's slot back in HL, and F_UDPOPEN's job is to
# COPY INTO that slot, so the slot must be the LDIR destination. Left as the
# source, the copy runs backwards: the channel's address and MAC are never
# stored, SELECT_UDP_CONTEXT later loads a zeroed slot, and every datagram
# leaves for 0.0.0.0 at MAC 00:00:00:00:00:00 while SEND still reports
# success. Require the EX DE,HL that turns the returned pointer into a
# destination before the first block copy.
{
    my ($udpopen) = $shim_code =~ /^F_UDPOPEN\b(.*?)^F_RESOLVE\b/ms;
    die "F_UDPOPEN not found in unet509b.asm\n" unless defined $udpopen;
    my ($tail) = $udpopen =~ /CALL\s+UDP_CTX_PTR(.*)$/s;
    die "F_UDPOPEN no longer calls UDP_CTX_PTR\n" unless defined $tail;
    my ($before_copy) = $tail =~ /^(.*?)\bLDIR\b/s;
    die "F_UDPOPEN calls UDP_CTX_PTR but never copies into the slot\n"
        unless defined $before_copy;
    die "F_UDPOPEN copies with the context slot still in HL (the copy runs backwards)\n"
        unless $before_copy =~ /\bEX\s+DE,HL\b/;
}

# S9_ENV_BUFFER is an alias of STAGE9_RX_BUFFER, safe only while nothing is
# receiving (NETINIT). A resolve receives constantly: RESOLVE_ROUTE's ARP
# exchange, then the DNS wait loop, and every retry re-reads the name. A
# caller hostname copied there is destroyed before BUILD_QUERY sees it and
# the query goes out asking for whatever frame landed last, so RESOLVE_HOST
# must work from the caller's own pointer instead.
{
    my ($resolve) = $shim_code =~ /^RESOLVE_HOST\b(.*?)^\s*RET\b/ms;
    die "RESOLVE_HOST not found in unet509b.asm\n" unless defined $resolve;
    die "RESOLVE_HOST reads the host out of S9_ENV_BUFFER (the RX buffer): a received frame destroys it\n"
        if $resolve =~ /S9_ENV_BUFFER/;
}

# src/include/unet.inc stays a frozen, byte-identical mirror of the shared
# UNET ABI; Stage 7's own gate (check-stage7.pl) already fails the build on
# divergence, so this is a presence check only -- Stage 14 must not add a
# second, diverging copy.
die "src/include/unet.inc is missing\n" unless -f "$root/src/include/unet.inc";

# Build and structural verification via the actual tool, not a re-implemented
# parser: the DLL must already be built (tools/build.sh's build_dll) before
# this check runs.
my $dll = "$root/build/UNET509B.DLL";
die "build/UNET509B.DLL is missing -- run tools/build.sh first\n" unless -f $dll;
system('sprinter-mkdll', 'verify', $dll, '--target', '1.3') == 0
    or die "sprinter-mkdll verify failed for UNET509B.DLL\n";
my $inspect = `sprinter-mkdll inspect '$dll' --json`;
die "sprinter-mkdll inspect failed for UNET509B.DLL\n" if $?;
die "UNET509B.DLL is not an L1 image\n" unless $inspect =~ /"format":\s*"L1"/;
die "UNET509B.DLL name field is missing the UNET509B prefix\n"
    unless $inspect =~ /"name":\s*"UNET509B[^"]*"/;

print "Stage 14 static: 24-entry JP table, 0x023F caps, 16-byte hot reserve, window-3 refusal, ",
      "complete cold context, clean RET_A/cold isolation and mkdll verify/inspect passed\n";
