#!/usr/bin/env perl
use strict;
use warnings;
use utf8;

my $path = shift or die "usage: $0 docs/STAGE1_AUDIT.md\n";
open my $fh, '<:encoding(UTF-8)', $path or die "cannot read $path: $!\n";
local $/;
my $text = <$fh>;
close $fh;

my @required = (
    '09-0398-002B',
    '20384c78615159b9c5162fb1b71d4a55940efbcc',
    '0239c2b025597e2e54b18ee4e682ac63038a06b6',
    '7f05d1245f58aaae575a32b7df63c8f3f978a396ac74bbed1cbb8b1270758681',
    '1186b53ab7f128a5caa13381e710c9271546b9db1064d06d3da5c1c931ce64fd',
    '17eb08a50adf8c32cd465d041b7d6f8a72f0c25df02687fbff6cfc9a795eebc1',
    '## 3. Clean-room граница',
    '### 4.4. Register windows',
    '### 4.5. Commands and status',
    '## 5. Сравнительная таблица поведения',
    '## 6. Независимый псевдокод Sprinter',
    '## 7. MAME findings for Stage 2',
    '## 8. Карта реального оборудования: частично заполненное evidence',
    'IRQ-код Nestor/Linux не переносится',
    'EEPROM остаётся read-only',
    'RX_DISCARD exactly once',
);

for my $needle (@required) {
    die "$path is missing required audit marker: $needle\n"
        if index($text, $needle) < 0;
}

my $matrix_rows = () = $text =~ /^\| [^\n]+ \|/mg;
die "$path has too few comparison/register table rows\n" if $matrix_rows < 45;

die "$path must leave physical EEPROM evidence open\n"
    unless $text =~ /^- \[ \] Сняты product ID и EEPROM/m;
die "$path must leave physical resource evidence open\n"
    unless $text =~ /^- \[ \] Записаны исходные I\/O, PnP, MAC/m;

print "Stage 1 audit: provenance, clean-room boundary, hardware contract, matrix, pseudocode, and open hardware evidence checks passed\n";
