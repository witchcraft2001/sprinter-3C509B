#!/usr/bin/env perl
use strict;
use warnings;

my ($root) = @ARGV;
die "usage: $0 REPOSITORY_ROOT\n" unless defined $root;

sub read_file {
    my ($path) = @_;
    open my $fh, '<:raw', $path or die "cannot read $path: $!\n";
    local $/;
    return <$fh>;
}

my $telnet = read_file("$root/src/apps/telnet.asm");
my $win0 = read_file("$root/src/apps/telnet_win0.asm");
my $cold = read_file("$root/src/apps/telmodem.asm");
my $resident = read_file("$root/src/lib/telmodem_loader.asm");
my $system_tramp = read_file("$root/src/lib/telnet_system_tramp.asm");
my $preloader = read_file("$root/src/apps/telnet_loader.asm");
my $build = read_file("$root/tools/build.sh");
my $manifest = read_file("$root/tools/artifacts.sh");
my $exe = read_file("$root/build/TELNET.EXE");

die "TELNET did not restore YMODEM download accelerator\n"
    unless $telnet =~ /CALL\s+\@MODEM\.RUN_Y_RECEIVE\b/;
die "TELNET did not restore YMODEM-G accelerator\n"
    unless $telnet =~ /CALL\s+\@MODEM\.RUN_Y_RECEIVE_G\b/;
die "TELNET did not restore YMODEM upload accelerator\n"
    unless $telnet =~ /CALL\s+\@MODEM\.RUN_Y_SEND\b/;
die "TELNET does not dispatch the ZMODEM trigger through the cold page\n"
    unless $telnet =~ /CALL\s+\@MODEM\.RUN_Z_RECEIVE\b/;
die "TELNET does not assemble a preloaded WIN1 payload\n"
    unless $telnet =~ /IFDEF\s+TELNET_MONOBLOCK_HOT/
        && $telnet =~ /ORG\s+0x4000.*?telnet_system_tramp\.asm.*?0x4100/s;
die "TELNET BSS does not assert the cold-page ABI\n"
    unless $telnet =~ /ASSERT\s+CANCELLED\s*==\s*TELMODEM_CANCELLED/
        && $telnet =~ /TRANSFER_BSS_END\s+EQU\s+TELMODEM_BSS_END/;

die "cold modem page lacks its fixed dispatcher at 0x0180\n"
    unless $cold =~ /MODEM_ENTRY\s*\n\s*CP\s+TELMODEM_FN_Z_RECEIVE/;
die "cold modem page lacks DSS/BIOS/IM1 vector wrappers\n"
    unless $cold =~ /JP\s+MODEMAPI\.BIOS/
        && $cold =~ /JP\s+MODEMAPI\.DSS/
        && $cold =~ /JP\s+MODEMAPI\.INT/;
die "cold RST trampoline does not restore private and cold WIN0 pages\n"
    unless $resident =~ /DSS_TRAMP.*?TELMODEM_DSS_PAGE.*?TELMODEM_PHYS_PAGE/s;
die "cold interrupt trampoline is absent\n"
    unless $resident =~ /INT_TRAMP.*?JP \(HL\).*?RETI/s;
die "cold dispatcher does not preserve its function selector\n"
    unless $resident =~ /CALL\s*\n\s*;[^\n]*function selector.*?PUSH AF.*?TELMODEM_READY.*?\.ready.*?DI.*?POP AF\s*\n\s*CALL 0x0180/s;

# Enforce the proven Fido Editor loader contract. In particular, the loader
# must consume DSS's inherited EXE handle; reopening the running executable is
# a different and demonstrably incompatible protocol on the target DSS.
die "stage-1 loader does not use the inherited PSP-3 EXE handle\n"
    unless $preloader =~ /LD\s+A,\(IX-3\)/
        && $preloader =~ /LD\s+DE,5\s*\n\s*CALL\s+READ_FULL/
        && $preloader =~ /OVERLAY_LENGTHS/;
die "stage-1 loader must not reopen or seek its own executable\n"
    if $preloader =~ /APPINFO|OPEN_SELF|SKIP_LOADER|MOVE_FP/;
die "stage-1 loader does not use Fido page allocation/loading\n"
    unless $preloader =~ /GETMEM1.*?DSS_GETMEM.*?BIOS_EMM_FN5/s
        && $preloader =~ /LD\s+HL,0x4180.*?WIN0_LEN/s
        && $preloader =~ /LD\s+HL,0x4000.*?WIN1_LEN/s;
die "stage-1 loader does not write the Fido P0 boot table\n"
    unless $preloader =~ /\(0x4040\).*?\(0x4041\).*?\(0x4042\).*?\(0x4043\).*?0x4044/s;
die "stage-1 loader does not take ownership of WIN0 like Fido Editor\n"
    unless $preloader =~ /OUT\s+\(0x3C\),A.*?OUT\s+\(PAGE0\),A.*?OUT\s+\(PAGE1\),A.*?0x0180/s;
die "WIN0 entry does not install all system vectors and enter MAIN\n"
    unless $win0 =~ /0x0008.*?TELNET_SYS_BIOS_TRAMP/s
        && $win0 =~ /0x0010.*?TELNET_SYS_DSS_TRAMP/s
        && $win0 =~ /0x0030.*?TELNET_SYS_MOUSE_TRAMP/s
        && $win0 =~ /0x0038.*?TELNET_SYS_INT_TRAMP/s
        && $win0 =~ /LD\s+IX,0x0080.*?JP\s+0x4100/s;
die "system trampolines do not map DSS then restore P1/P0\n"
    unless $system_tramp =~ /TELNET_SYS_DSS_PAGE.*?OUT \(PAGE0\),A.*?RST RST_VECTOR.*?TELNET_SYS_P1_PAGE.*?OUT \(PAGE1\),A.*?TELNET_SYS_P0_PAGE.*?OUT \(PAGE0\),A/s;

die "build still produces a TELMOD.BIN companion\n"
    if $build =~ /build_telmodem\b/ || $build =~ /--raw=.*TELMOD\.BIN/;
die "manifest still ships a TELMOD.BIN companion\n"
    if $manifest =~ /\|TELMOD\.BIN"/;

die "TELNET.EXE is shorter than its preloader header\n" if length($exe) < 0x207;
die "TELNET is not a version-1 DSS preloader executable\n"
    unless substr($exe, 0, 4) eq "EXE\x01";
die "TELNET preloader header offset is not 0x200\n"
    unless unpack('V', substr($exe, 4, 4)) == 0x200;
my $loader_len = unpack('v', substr($exe, 8, 2));
die "TELNET preloader length is empty\n" unless $loader_len;
die "TELNET preloader entry changed from 0x8100\n"
    unless unpack('v', substr($exe, 16, 2)) == 0x8100
        && unpack('v', substr($exe, 18, 2)) == 0x8100;
die "TELNET preloader stack changed from safe WIN2 address\n"
    unless unpack('v', substr($exe, 20, 2)) == 0xBFFF;

# Exact Fido table: DW win0, DW win1, DB count, then count DW lengths.
my $table = 0x200 + $loader_len;
die "TELNET size table is outside the EXE\n" if $table + 7 > length($exe);
my ($win0_len, $win1_len, $overlay_count) =
    unpack('vvC', substr($exe, $table, 5));
die "TELNET EXE must contain exactly one modem overlay\n"
    unless $overlay_count == 1;
my $modem_len = unpack('v', substr($exe, $table + 5, 2));
die "TELNET internal WIN0 payload has invalid size: $win0_len\n"
    unless $win0_len && $win0_len <= 0x3e80;
die "TELNET internal WIN1 payload has invalid size: $win1_len\n"
    unless $win1_len && $win1_len <= 0x4000;
die "TELNET internal modem payload has invalid size: $modem_len\n"
    unless $modem_len && $modem_len <= 0x4000;

my $win0_offset = $table + 7;
my $win1_offset = $win0_offset + $win0_len;
my $modem_offset = $win1_offset + $win1_len;
die "TELNET EXE length does not match its Fido section table\n"
    unless $modem_offset + $modem_len == length($exe);
die "TELNET WIN0 blob does not begin with its 0x0180 entry\n"
    unless substr($exe, $win0_offset, 1) eq "\x3a";
die "TELNET WIN1 blob does not begin with the BIOS trampoline\n"
    unless substr($exe, $win1_offset, 2) eq "\xf3\xf5";
die "TELNET internal modem page lacks dispatcher at offset 0x180\n"
    unless substr($exe, $modem_offset + 0x180, 1) eq "\xfe";

print "Stage 15 host contract: exact Fido EXE layout, owned WIN0 vectors, pageable Z/Y ABI, BSS bounds and artifacts passed\n";
