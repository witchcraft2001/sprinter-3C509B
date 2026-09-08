#!/usr/bin/env node
// Actual DSS EXE vectors for the EL3EEP discovery diagnostics.
// A real 3C509B-TPO answered the ID port with correct product, manufacturer
// and MAC words and was still rejected with a bare "code=5", so the words the
// card returned and the checksum lanes VALIDATE computed have to be printed
// before the error line. These vectors pin that reporting.
// SPDX-License-Identifier: BSD-3-Clause
'use strict';

const assert = require('assert');
const path = require('path');
const {runExe} = require('./exe-harness/harness.js');

const root = path.resolve(__dirname, '..');
const exe = path.join(root, 'build', 'EL3EEP.EXE');
const info = path.join(root, 'build', 'EL3INFO.EXE');
let cases = 0;

// The EEPROM of the project's physical 3C509B-TPO, read by EL3EEP on a real
// Sprinter (slot 0, ID port 0110) and reproduced by a second run. Its words
// 18..1F are non-zero and its MAC is 00:20:AF:5D:69:8B, which is what pins the
// secondary checksum lane and the station-address byte order.
const CARD_WORDS = [
  0x0020, 0xAF5D, 0x698B, 0x9550, 0xB434, 0x0041, 0x4A41, 0x6D50,
  0x0010, 0x3000, 0x0020, 0xAF5D, 0x698B, 0x1310, 0x0000, 0x3223,
  0x2083, 0x0000, 0x0000, 0x0004, 0x0001, 0x0000, 0x0000, 0x0205,
  0x6D50, 0x9550, 0x698B, 0xAF5D, 0x0A5B, 0x1010, 0x1982, 0x3300,
  0x6F43, 0x206D, 0x4333, 0x3035, 0x4239, 0x4520, 0x6874, 0x7265,
  0x694C, 0x6B6E, 0x4920, 0x4949, 0x5015, 0x506D, 0x0295, 0x411C,
  0x80D0, 0x22F7, 0x9EA8, 0x0147, 0x0210, 0x03E0, 0x1010, 0x3779,
];
const CARD_MAC = [0x00, 0x20, 0xAF, 0x5D, 0x69, 0x8B];
const cardScenario = () => ({
  mac: CARD_MAC,
  eepromPatch: Object.fromEntries(CARD_WORDS.map((w, i) => [i, w])),
});

function run(args, scenario = {}, program = exe) {
  const result = runExe(program, args, scenario);
  assert.deepStrictEqual(result.cleanup, {isaClosed: true, pagesFreed: true, done: true},
    `EL3EEP ${args} did not close the ISA window and release its page`);
  cases++;
  return result;
}
function lines(result) { return result.output.replace(/\r/g, '').split('\n'); }
function dumpRows(result) { return lines(result).filter((l) => /^[0-9A-F]{2}: /.test(l)); }

// A valid card: eight rows of eight words, then the validation banner.
{
  const result = run('-s 1 -p #110');
  assert.strictEqual(result.exitCode, 0);
  const rows = dumpRows(result);
  assert.strictEqual(rows.length, 8, 'the dump must be eight rows of eight words');
  assert.strictEqual(rows[0], '00: 0260 8C12 3456 9550 0000 0000 0000 6D50');
  assert.match(result.output, /\[E2\] IDS MAC CHECKSUMS VALID/);
  assert.doesNotMatch(result.output, /\[E3\] FAIL=/, 'no diagnostic line on a good card');
}

// The physical card's own EEPROM. Words 18..1F are non-zero, so this image
// fails unless the vital lane of the secondary checksum covers 18..3F rather
// than 20..3F -- the defect that rejected the real card with a bare "code=5".
{
  const result = run('-s 1 -p #110', cardScenario());
  assert.strictEqual(result.exitCode, 0, 'the physical card must validate');
  const rows = dumpRows(result);
  assert.strictEqual(rows[0], '00: 0020 AF5D 698B 9550 B434 0041 4A41 6D50');
  assert.strictEqual(rows[3], '18: 6D50 9550 698B AF5D 0A5B 1010 1982 3300');
  assert.match(result.output, /\[E2\] IDS MAC CHECKSUMS VALID/);
}

// ...and end to end: the station address published from that EEPROM must be
// the address on the card's label, not the two bytes of each word reversed.
{
  const result = run('-v -s 1 -p #110', cardScenario(), info);
  assert.strictEqual(result.exitCode, 0);
  assert.match(result.output, /\[E1\] PRODUCT=9550 IO=0300/);
  assert.match(result.output, /\[E2\] MAC=00:20:AF:5D:69:8B/);
  assert.match(result.output, /\[E5\] CHECKSUM=3223 SECONDARY=0205/);
  assert.match(result.output, /RESULT OK/);
}

// An empty slot: every word reads FF, and the first rejected check is the
// product ID. This is the signature the physical machine shows for the slot
// the card is not in.
{
  const result = run('-s 0 -p #110');
  assert.strictEqual(result.exitCode, 2);
  const rows = dumpRows(result);
  assert.strictEqual(rows.length, 8);
  assert.strictEqual(rows[0], '00: FFFF FFFF FFFF FFFF FFFF FFFF FFFF FFFF');
  assert.match(result.output, /\[E3\] FAIL=1 PRI=FFFF\/0000 SEC=FFFF\/0000/);
  assert.match(result.output, /RESULT FAIL code=3/);
}

// The physical failure: IDs and MAC are right, one checksum word is not. The
// dump and both lanes must still reach the screen, and the sub-code has to
// name the failing lane rather than leaving "code=5" ambiguous.
{
  const result = run('-s 1 -p #110', {eepromPatch: {15: 0x1234}});
  assert.strictEqual(result.exitCode, 2);
  const rows = dumpRows(result);
  assert.strictEqual(rows[0], '00: 0260 8C12 3456 9550 0000 0000 0000 6D50');
  assert.match(rows[1], /^08: .* 1234$/, 'the patched checksum word must be visible');
  // The secondary lane never ran, so its computed half stays at the zero the
  // application published before discovery -- not stale page content.
  assert.match(result.output, /\[E3\] FAIL=4 PRI=1234\/F821 SEC=A100\/0000/);
  assert.match(result.output, /RESULT FAIL code=5/);
}

// The same for the secondary lane, which shares the single code=5 with the
// primary one and could otherwise not be told apart from it.
{
  const result = run('-s 1 -p #110', {eepromPatch: {23: 0x5678}});
  assert.strictEqual(result.exitCode, 2);
  assert.match(result.output, /\[E3\] FAIL=5 PRI=F821\/F821 SEC=5678\/A100/);
  assert.match(result.output, /RESULT FAIL code=5/);
}

// A MAC that is not unicast is rejected before either checksum runs, so both
// lanes stay at their initialised zero instead of reporting stale page data.
{
  const result = run('-s 1 -p #110', {mac: [0x01, 0x60, 0x8c, 0x12, 0x34, 0x56]});
  assert.strictEqual(result.exitCode, 2);
  assert.match(result.output, /\[E3\] FAIL=3 PRI=[0-9A-F]{4}\/0000 SEC=A100\/0000/);
  assert.match(result.output, /RESULT FAIL code=3/);
}

// NETPROF runs DISCOVER twice in one process: once on its own, to time the
// 64-word EEPROM read, and once inside NETDRV.INIT. That is the same thing
// two utilities run back to back do to a card, and the card model used to
// refuse it -- it treated the 0xD0 tag command as excluding the adapter from
// any later ID sequence, when 0xD0 assigns tag *zero* and leaves it
// selectable. Real hardware runs PING after IFUP without complaint.
const profiler = path.join(root, 'build', 'NETPROF.EXE');
const profilerEnv = {
  NET: '509B', NET_HW: 'AUTO', NET_IDPORT: '#110',
  NET_MAC: '02:60:8C:12:34:56', NET_IP_SRC: 'STATIC',
  NET_IP: '192.168.7.20', NET_MASK: '255.255.255.0', NET_GW: '192.168.7.1',
  NET_DNS1: '192.168.7.1', NET_DNS2: '192.168.7.2',
};

// -n suppresses the ID-port global reset, the diagnostic that asks whether the
// pause in front of every utility's first frame is our own link bounce. The
// card must still be discovered, activated and driven without it, and the
// address after the flag must still be the target rather than the gateway.
{
  const result = runExe(profiler, '-n 192.168.7.44', {
    strictPc: true, stepLimit: 900_000_000, clockFreezeAfterReads: 0,
    arp: {mac: [2, 0, 0, 0, 0, 44]}, environment: profilerEnv,
  });
  assert.strictEqual(result.exitCode, 0, result.output);
  assert.match(result.output, /^\[P2\] GLOBAL RESET=SKIPPED$/m, result.output);
  assert.match(result.output, /^\[P5\] TARGET=192\.168\.7\.44$/m, result.output);
  assert.match(result.output, /^\[P5\] ARP=\d+s TRY=1$/m, result.output);
  assert.match(result.output, /RESULT OK/);
  assert.deepStrictEqual(result.cleanup, {isaClosed: true, pagesFreed: true, done: true});
  cases++;
}

{
  const result = runExe(profiler, '192.168.7.44', {
    strictPc: true, stepLimit: 900_000_000, clockFreezeAfterReads: 0,
    arp: {mac: [2, 0, 0, 0, 0, 44]}, environment: profilerEnv,
  });
  assert.strictEqual(result.exitCode, 0, result.output);
  assert.doesNotMatch(result.output, /GLOBAL RESET=SKIPPED/,
    'the reset is suppressed only by -n');
  for (const stage of [/^\[P1\] CONFIG=\d+s$/m, /^\[P2\] DISCOVER=\d+s$/m,
    /^\[P2\] EEPROM SLOT=1$/m, /^\[P3\] DRIVER=\d+s$/m, /^\[P4\] LINK=\d+s$/m,
    /^\[P4\] LINK QUANTA=\d+$/m, /^\[P5\] TARGET=192\.168\.7\.44$/m,
    /^\[P5\] ARP=\d+s TRY=1$/m, /^\[P6\] ARP2=\d+s TRY=1$/m,
    /^\[P7\] TICKS\/SEC=\d+$/m, /^\[P8\] 10K TICKS=\d+s$/m])
    assert.match(result.output, stage, `missing stage line in:\n${result.output}`);
  // A frozen clock makes every stage honestly zero seconds; a stale register
  // standing in for the delta would not come out zero.
  assert.doesNotMatch(result.output, /=[1-9]\d*s/, result.output);
  assert.match(result.output, /RESULT OK/);
  assert.deepStrictEqual(result.cleanup, {isaClosed: true, pagesFreed: true, done: true});
  cases++;
}

console.log(`Stage 3 EXE vectors: EL3EEP dump and VALIDATE diagnostics passed (${cases} cases)`);
