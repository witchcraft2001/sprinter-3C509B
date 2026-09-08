#!/usr/bin/env node
// Actual TCPTEST DSS EXE scenarios over the strict 3C509B model.
// SPDX-License-Identifier: BSD-3-Clause
'use strict';

const assert = require('assert');
const fs = require('fs');
const path = require('path');
const {runExe} = require('./exe-harness/harness.js');

const root = path.resolve(__dirname, '..');
const executable = path.join(root, 'build', 'TCPTEST.EXE');
let cases = 0;

function staticEnv() {
  return {
    NET: '509B', NET_HW: 'AUTO', NET_IDPORT: '#110', NET_MAC: '02:60:8C:12:34:56',
    NET_IP_SRC: 'STATIC', NET_IP: '192.168.7.20', NET_MASK: '255.255.255.0',
    NET_GW: '192.168.7.1',
  };
}
function scenario(tcp = {}) {
  return {environment: staticEnv(),
    arp: {ip: [192,168,7,44], mac: [2,0,0,0,0,44]},
    tcp: {mode: 'echo', port: 7777, ...tcp}, stepLimit: 500_000_000};
}
function run(args, value) { return runExe(executable, args, value); }
function checked(result) {
  assert.deepStrictEqual(result.cleanup, {isaClosed: true, pagesFreed: true, done: true});
  assert.ok(result.minimumSp >= 0xbee0,
    `bootstrap stack margin exhausted: #${result.minimumSp.toString(16)}`);
  cases++;
}
function tcpFrames(result) {
  return result.transmittedFrames.map((value) => Buffer.from(value, 'hex')).filter((frame) =>
    frame.length >= 54 && frame[12] === 8 && frame[13] === 0 && frame[23] === 6).map((frame) => {
      const at = 34, header = (frame[at + 12] >> 4) * 4;
      return {sourcePort: frame.readUInt16BE(at), destinationPort: frame.readUInt16BE(at + 2),
        sequence: frame.readUInt32BE(at + 4), acknowledgement: frame.readUInt32BE(at + 8),
        flags: frame[at + 13], window: frame.readUInt16BE(at + 14),
        payload: frame.subarray(at + header, 14 + frame.readUInt16BE(16))};
    });
}

const image = fs.readFileSync(executable);
assert.strictEqual(image.subarray(0, 4).toString('binary'), 'EXE\x01');
assert.strictEqual(image.readUInt16LE(4), 128);
assert.strictEqual(image.readUInt16LE(16), 0x8100);
assert.ok(0x8080 + image.length < 0xbef0);
let longest = 0, current = 0;
for (const byte of image.subarray(128)) { current = byte ? 0 : current + 1; longest = Math.max(longest, current); }
assert.ok(longest < 128, 'TCPTEST contains zero-filled runtime BSS');
cases++;

for (const help of ['-h', '/H', '-?']) {
  const result = run(help, {cardPresent: false});
  assert.strictEqual(result.exitCode, 0); assert.match(result.output, /Usage: TCPTEST/); checked(result);
}
for (const bad of ['', '192.168.7.44', 'name.example 7777', '192.168.7.44 0',
  '-l 4097 192.168.7.44 7777', '-n 0 192.168.7.44 7777',
  '-w 0 192.168.7.44 7777', '-n 1 /n 2 192.168.7.44 7777']) {
  const result = run(bad, {cardPresent: false});
  assert.strictEqual(result.exitCode, 1, `accepted '${bad}'`);
  assert.strictEqual(result.transmittedFrames.length, 0); checked(result);
}
let result = run('-n 1 -l 1 192.168.7.44 7777', {environment: staticEnv(), cardPresent: false});
assert.strictEqual(result.exitCode, 2); checked(result);

for (const size of [0, 1, 535, 536, 537, 1072, 2048, 4096]) {
  result = run(`-n 1 -l ${size} -w 1000 192.168.7.44 7777`, scenario());
  assert.strictEqual(result.exitCode, 0, `size ${size}: ${result.output}`);
  assert.strictEqual((result.output.match(/channel=/g) || []).length, 2);
  const frames = tcpFrames(result), syns = frames.filter((packet) => packet.flags === 2);
  assert.strictEqual(syns.length, 2);
  // TCP_RECV_WINDOW (tcp.inc) is TCP_MSS here: only STAGE12_LAYOUT (WGET)
  // reserves enough page space to buffer more than one segment per channel.
  assert.ok(syns.every((packet) => packet.window === 536));
  assert.notStrictEqual(syns[0].sourcePort, syns[1].sourcePort);
  assert.ok(frames.filter((packet) => packet.payload.length).every((packet) => packet.payload.length <= 536));
  checked(result);
}

result = run('-n 1 -l 537 -w 100 192.168.7.44 7777', scenario({mss: 128}));
assert.strictEqual(result.exitCode, 0, result.output);
assert.ok(tcpFrames(result).filter((packet) => packet.payload.length)
  .every((packet) => packet.payload.length <= 128)); checked(result);

result = run('-n 2 -l 537 -w 100 192.168.7.44 7777', scenario());
assert.strictEqual(result.exitCode, 0, result.output);
assert.strictEqual((result.output.match(/channel=/g) || []).length, 4); checked(result);

// MAME/DSS may clobber IX/IY in SYSTIME; TCP context must survive tuple
// generation and route-cache timestamping across that system call.
result = run('-n 1 -l 1 -w 100 192.168.7.44 7777',
  {...scenario(), clobberIndexOnSystime: true});
assert.strictEqual(result.exitCode, 0, result.output); checked(result);

result = run('-n 100 -l 0 -w 100 192.168.7.44 7777', scenario());
assert.strictEqual(result.exitCode, 0, result.output);
let frames = tcpFrames(result).filter((packet) => packet.flags === 2);
assert.strictEqual(frames.length, 200);
assert.strictEqual(new Set(frames.map((packet) => packet.sourcePort)).size, 200,
  'ephemeral TCP source port reused during a 100-cycle run');
checked(result);

result = run('-n 1 -l 537 -w 100 192.168.7.44 7777', scenario({dropSyn: 1}));
assert.strictEqual(result.exitCode, 0, result.output);
frames = tcpFrames(result);
let syns = frames.filter((packet) => packet.flags === 2);
assert.ok(syns.length >= 3);
assert.strictEqual(syns[0].sourcePort, syns[1].sourcePort);
assert.strictEqual(syns[0].sequence, syns[1].sequence); checked(result);

result = run('-n 1 -l 537 -w 100 192.168.7.44 7777', scenario({dropDataResponses: 1}));
assert.strictEqual(result.exitCode, 0, result.output);
frames = tcpFrames(result).filter((packet) => packet.payload.length);
assert.ok(frames.some((packet, index) => index && packet.sequence === frames[index - 1].sequence));
checked(result);

for (const tcp of [{duplicateData: true}, {outOfOrderBeforeData: true},
  {outOfOrderFinAfterData: true}, {resetOnSyn: true}, {resetOnData: true}]) {
  result = run('-n 1 -l 537 -w 100 192.168.7.44 7777', scenario(tcp));
  assert.strictEqual(result.exitCode, 0, `${JSON.stringify(tcp)}: ${result.output}`); checked(result);
}

result = run('-n 1 -l 537 -w 100 192.168.7.44 7777', scenario({zeroWindowProbes: 2}));
assert.strictEqual(result.exitCode, 0, result.output);
assert.ok(tcpFrames(result).some((packet) => packet.flags === 0x10 &&
  packet.payload.length === 1), 'zero-window persist probe is not a one-byte duplicate');
checked(result);

result = run('-n 1 -l 536 -w 100 192.168.7.44 7777', scenario({remoteFinAfterData: true}));
assert.strictEqual(result.exitCode, 0, result.output);
checked(result);

result = run('-n 1 -l 0 -w 100 192.168.7.44 7777', scenario({splitClose: true}));
assert.strictEqual(result.exitCode, 0, result.output);
frames = tcpFrames(result);
for (const sourcePort of new Set(frames.filter((packet) => packet.flags === 2)
  .map((packet) => packet.sourcePort))) {
  const fin = frames.findIndex((packet) => packet.sourcePort === sourcePort && packet.flags & 1);
  assert.ok(fin >= 0 && frames.slice(fin + 1).some((packet) =>
    packet.sourcePort === sourcePort && packet.flags === 0x10 && !packet.payload.length),
  `channel ${sourcePort} did not ACK the peer FIN after a split close`);
}
checked(result);

result = run('-n 1 -l 537 -w 100 192.168.7.44 7777',
  scenario({outOfSequenceRstBeforeData: true}));
assert.strictEqual(result.exitCode, 0, result.output);
assert.strictEqual(tcpFrames(result).filter((packet) => packet.flags === 2).length, 2,
  'out-of-sequence RST incorrectly forced a reconnect');
checked(result);

result = run('-n 1 -l 1 -w 1 192.168.7.44 7777', scenario({mode: 'drop'}));
assert.strictEqual(result.exitCode, 3);
assert.match(result.output, /\[E2\] NETWORK stage=2 elapsed_ms=\d+ slot=1 base=#0300 status=30 target=192\.168\.7\.44:7777/);
assert.match(result.output, /RESULT FAIL code=30/); checked(result);
result = run('-n 1 -l 1 -w 1 192.168.7.44 7777', scenario({zeroWindowProbes: 99}));
assert.strictEqual(result.exitCode, 3);
assert.match(result.output, /\[E2\] NETWORK stage=3 elapsed_ms=\d+ .* status=33 target=192\.168\.7\.44:7777/);
assert.match(result.output, /RESULT FAIL code=33/); checked(result);
result = run('-n 1 -l 0 -w 1 192.168.7.44 7777', scenario({ackOnlyClose: true}));
assert.strictEqual(result.exitCode, 3);
assert.match(result.output, /\[E2\] NETWORK stage=6 elapsed_ms=\d+ .* status=30 target=192\.168\.7\.44:7777/);
assert.match(result.output, /RESULT FAIL code=30/); checked(result);
result = run('-n 1 -l 1 -w 1 192.168.7.44 7777', scenario({resetOnSyn: true, resetAlways: true}));
assert.strictEqual(result.exitCode, 3); assert.match(result.output, /RESULT FAIL code=31/); checked(result);
for (const key of ['escape', 'ctrl-c']) {
  result = run('-n 1 -l 1 -w 1000 192.168.7.44 7777',
    {...scenario({mode: 'drop'}), key});
  assert.strictEqual(result.exitCode, 7); assert.match(result.output, /RESULT FAIL code=23/); checked(result);
}

console.log(`Stage 11 actual EXE: ${cases} TCP codec/state/MSS/multichannel/fault scenarios passed`);
