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
my $shim_code = $shim; $shim_code =~ s/;[^\n]*//g;
my $cold_code = $cold; $cold_code =~ s/;[^\n]*//g;

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

# Shared error-return exit contract: RET_A stores LASTERR and always clears
# carry via OR A immediately before RET (Pascal LibCall propagates carry, and
# every UNET function except INIT/window-3-refusal must return CF=0).
die "RET_A does not clear carry (OR A) immediately before RET\n"
    unless $shim_code =~ /^RET_A\b[^\n]*\n\s*LD\s+\([^)]*\),A\s*\n\s*OR\s+A\s*\n\s*RET\b/ms;

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
    my %filled = map { $_ => 1 }
        ($fill =~ /LD\s+\(UNET_COLD_CTX\s*\+\s*(CCTX_[A-Z0-9_]+)\)\s*,\s*HL/g);
    my %used;
    $used{$1} = 1 while $cold_code =~ /\(\s*IX\s*\+\s*(CCTX_[A-Z0-9_]+?)(?:\+1)?\s*\)/g;
    die "no COLD_CTX dereferences found in unet509b_cold.asm\n" unless %used;
    my @missing = sort grep { !$filled{$_} } keys %used;
    die "unet509b_cold.asm reads @missing but FILL_COLD_CTX never fills it\n"
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

print "Stage 14 static: 24-entry JP table, 0x023F caps, image ceiling, window-3 refusal, ",
      "clean RET_A/cold isolation and mkdll verify/inspect passed\n";
