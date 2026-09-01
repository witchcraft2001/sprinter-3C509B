#!/usr/bin/env node
// Actual UDPTEST DSS EXE scenarios over the strict 3C509B model.
// SPDX-License-Identifier: BSD-3-Clause
'use strict';

const assert = require('assert');
const fs = require('fs');
const path = require('path');
const {runExe} = require('./exe-harness/harness.js');

const root = path.resolve(__dirname, '..');
const executable = path.join(root, 'build', 'UDPTEST.EXE');
let cases = 0;

function staticEnv() {
  return {
    NET: '509B', NET_HW: 'AUTO', NET_IDPORT: '#110', NET_MAC: '02:60:8C:12:34:56',
    NET_IP_SRC: 'STATIC', NET_IP: '192.168.7.20', NET_MASK: '255.255.255.0',
    NET_GW: '192.168.7.1',
  };
}
function scenario(extra = {}) {
  return {environment: staticEnv(), arp: {ip: [192,168,7,44], mac: [2,0,0,0,0,44]},
    udp: {mode: 'echo', port: 7777}, ...extra};
}
function run(args, value) { return runExe(executable, args, value); }
function checked(result) {
  assert.deepStrictEqual(result.cleanup, {isaClosed: true, pagesFreed: true, done: true});
  assert.ok(result.minimumSp >= 0xbf90,
    `resident stack margin exhausted: minimum SP #${result.minimumSp.toString(16)}`);
  cases++;
}

const image = fs.readFileSync(executable);
assert.strictEqual(image.subarray(0, 4).toString('binary'), 'EXE\x01');
assert.strictEqual(image.readUInt16LE(4), 128);
assert.strictEqual(image.readUInt16LE(16), 0x8100);
assert.ok(0x8080 + image.length < 0xb000);
let longest = 0, current = 0;
for (const byte of image.subarray(128)) { current = byte ? 0 : current + 1; longest = Math.max(longest, current); }
assert.ok(longest < 128, 'UDPTEST contains zero-filled runtime BSS');
cases++;

for (const help of ['-h', '/H', '-?']) {
  const result = run(help, {cardPresent: false});
  assert.strictEqual(result.exitCode, 0); assert.match(result.output, /Usage: UDPTEST/); checked(result);
}
for (const bad of ['', 'host.example 7777', '192.168.7.44', '192.168.7.44 0',
  '192.168.7.44 65536', '-n 0 192.168.7.44 7777', '-n 65536 192.168.7.44 7777',
  '-l 1473 192.168.7.44 7777', '-w 0 192.168.7.44 7777',
  '-w 65536 192.168.7.44 7777', '-n 1 /n 2 192.168.7.44 7777']) {
  const result = run(bad, {cardPresent: false});
  assert.strictEqual(result.exitCode, 1, `accepted '${bad}'`);
  assert.strictEqual(result.transmittedFrames.length, 0); checked(result);
}
for (const valid of ['-n 1 -l 0 -w 1 192.168.7.44 1',
  '/N 65535 /L 1472 /W 65535 192.168.7.44 65535']) {
  const result = run(valid, {environment: staticEnv(), cardPresent: false});
  assert.strictEqual(result.exitCode, 2); checked(result);
}

for (const size of [0, 1, 16, 1472]) {
  const result = run(`-n 1 -l ${size} 192.168.7.44 7777`, scenario());
  assert.strictEqual(result.exitCode, 0, result.output);
  const frame = Buffer.from(result.transmittedFrames[1], 'hex');
  assert.strictEqual(frame.readUInt16BE(16), 28 + size);
  assert.strictEqual(frame.readUInt16BE(38), 8 + size);
  assert.notStrictEqual(frame.readUInt16BE(40), 0);
  for (let i = 0; i < size; i++) assert.strictEqual(frame[42 + i], i & 255);
  checked(result);
}

let result = run('-n 3 -l 17 -w 1 192.168.7.44 7777', scenario({
  udp: {mode: 'echo', port: 7777, drop: 2, duplicate: true},
}));
assert.strictEqual(result.exitCode, 0, result.output);
assert.strictEqual((result.output.match(/Reply datagram=/g) || []).length, 3);
checked(result);

result = run('-n 1 -w 1000 192.168.7.44 7777', scenario({
  timeStepSeconds: 0.125,
  udp: {mode: 'echo', port: 7777, unrelatedBeforeReply: true, foreignSourceBeforeReply: true,
    foreignDestinationBeforeReply: true, badIpBeforeReply: true, badUdpBeforeReply: true,
    corruptBeforeReply: true, requestBeforeReply: true, arpBeforeReply: true},
}));
assert.strictEqual(result.exitCode, 0, result.output);
assert.strictEqual(result.rxRemaining, 0); checked(result);

result = run('-n 1 -w 1 192.168.7.44 7777', scenario({udp: {mode: 'drop', port: 7777}}));
assert.strictEqual(result.exitCode, 3); assert.match(result.output, /TIMEOUT stage=UDP.*RESULT FAIL code=14/s); checked(result);

result = run('-n 1 203.0.113.10 7777', {
  environment: staticEnv(), arp: {ip: [192,168,7,1], mac: [2,0,0,0,0,1]},
  udp: {mode: 'unreachable', port: 7777, routerIp: [192,168,7,1]},
});
assert.strictEqual(result.exitCode, 6); assert.match(result.output, /RESULT FAIL code=24/); checked(result);
result = run('-n 1 -l 31 192.168.7.1 7777', {
  environment: staticEnv(), arp: {ip: [192,168,7,1], mac: [2,0,0,0,0,1]},
  udp: {mode: 'echo', port: 7777, ip: [192,168,7,1], mac: [2,0,0,0,0,1]},
});
assert.strictEqual(result.exitCode, 0, result.output); checked(result);

for (const key of ['escape', 'ctrl-c']) {
  result = run('-n 2 192.168.7.44 7777', scenario({key, udp: {mode: 'drop', port: 7777}}));
  assert.strictEqual(result.exitCode, 7); assert.match(result.output, /RESULT FAIL code=23/); checked(result);
}

result = run('-n 1000 -l 0 192.168.7.44 7777', scenario({stepLimit: 500_000_000}));
assert.strictEqual(result.exitCode, 0, result.output);
assert.strictEqual((result.output.match(/Reply datagram=/g) || []).length, 1000);
checked(result);

const tftpExecutable = path.join(root, 'build', 'TFTP.EXE');
function tftpRun(args, value) { return runExe(tftpExecutable, args, value); }
function fixture(size, salt = 0x39) {
  return Buffer.from({length: size}, (_, index) => (index * 29 + (index >>> 8) + salt) & 255);
}
function tftpScenario(name, data, extra = {}) {
  return {environment: staticEnv(), arp: {ip: [192,168,7,44], mac: [2,0,0,0,0,44]},
    tftp: {files: {[name]: data}, ...extra}};
}
function outputFile(result, name) { return result.files[`C:\\NET\\${name.toUpperCase()}`]; }
function tftpOpcodes(result) {
  return result.transmittedFrames.map((value) => Buffer.from(value, 'hex')).filter((frame) =>
    frame.length >= 44 && frame[12] === 8 && frame[13] === 0 && frame[23] === 17).map((frame) => ({
      destinationPort: frame.readUInt16BE(36), opcode: frame.readUInt16BE(42),
      errorCode: frame.length >= 46 ? frame.readUInt16BE(44) : 0,
    }));
}

const tftpImage = fs.readFileSync(tftpExecutable);
assert.strictEqual(tftpImage.subarray(0, 4).toString('binary'), 'EXE\x01');
assert.strictEqual(tftpImage.readUInt16LE(4), 128);
assert.strictEqual(tftpImage.readUInt16LE(16), 0x8100);
assert.ok(0x8080 + tftpImage.length < 0xb9a0);
longest = 0; current = 0;
for (const byte of tftpImage.subarray(128)) { current = byte ? 0 : current + 1; longest = Math.max(longest, current); }
assert.ok(longest < 128, 'TFTP contains zero-filled runtime BSS');
cases++;

for (const help of ['-h', '/H', '-?']) {
  result = tftpRun(help, {cardPresent: false});
  assert.strictEqual(result.exitCode, 0); assert.match(result.output, /Usage: TFTP/); checked(result);
}
const longName = 'R'.repeat(80);
for (const bad of ['', 'host.example GET R', '192.168.7.44', '192.168.7.44: GET R',
  '192.168.7.44:0 GET R', '192.168.7.44:65536 GET R', '192.168.7.44 BAD R',
  `192.168.7.44 GET ${longName}`, '192.168.7.44 GET R -o',
  '192.168.7.44 GET R -o A -o B', '192.168.7.44 GET R -y -f',
  '192.168.7.44 GET /', '192.168.7.44 PUT DIR/',
  '192.168.7.44 PUT A -y', '192.168.7.44 PUT A -f', '192.168.7.44 PUT A EXTRA']) {
  result = tftpRun(bad, {cardPresent: false});
  assert.strictEqual(result.exitCode, 1, `accepted '${bad}'`);
  assert.strictEqual(result.transmittedFrames.length, 0); checked(result);
}
for (const valid of ['192.168.7.44:1 GET R', `192.168.7.44 GET ${'R'.repeat(79)}`,
  '192.168.7.44:65535 PUT LOCAL -o REMOTE']) {
  result = tftpRun(valid, {environment: staticEnv(), cardPresent: false});
  assert.strictEqual(result.exitCode, 2, result.output); checked(result);
}

const getCases = [
  {size: 0}, {size: 1, fallback: true}, {size: 17, blockSize: 8},
  {size: 512, fallback: true},
  {size: 1428, badChecksum: true}, {size: 2856},
  {size: 256 * 1024 + 123, duplicate: true, reorder: true, unknownTid: true,
    dropPackets: 1, dropResponseNumbers: [4, 19], stepLimit: 800_000_000},
];
for (const test of getCases) {
  const data = fixture(test.size);
  const options = {...test}; delete options.size; const stepLimit = options.stepLimit; delete options.stepLimit;
  result = tftpRun('192.168.7.44:6969 GET DIR/REMOTE.BIN -o GET.BIN', {
    ...tftpScenario('DIR/REMOTE.BIN', data, options), ...(stepLimit ? {stepLimit} : {}),
  });
  assert.strictEqual(result.exitCode, 0, `GET ${test.size}: ${result.output}`);
  assert.deepStrictEqual(outputFile(result, 'GET.BIN'), data, `GET ${test.size}`); checked(result);
}

const putCases = [
  {size: 0, fallback: true}, {size: 1}, {size: 512, fallback: true},
  {size: 1428}, {size: 2856},
  {size: 256 * 1024 + 123, duplicate: true, unknownTid: true,
    dropPackets: 1, dropResponseNumbers: [4, 17], stepLimit: 800_000_000},
];
for (const test of putCases) {
  const data = fixture(test.size, 0x71);
  const options = {...test}; delete options.size; const stepLimit = options.stepLimit; delete options.stepLimit;
  result = tftpRun('192.168.7.44 PUT PUT.BIN -o UPLOAD.BIN', {
    ...tftpScenario('unused', Buffer.alloc(0), options), files: {'PUT.BIN': data},
    ...(stepLimit ? {stepLimit} : {}),
  });
  assert.strictEqual(result.exitCode, 0, `PUT ${test.size}: ${result.output}`);
  assert.deepStrictEqual(result.tftpUploads['UPLOAD.BIN'], data, `PUT ${test.size}`); checked(result);
}

const replacement = fixture(33);
for (const promptKey of ['n', 'escape']) {
  result = tftpRun('192.168.7.44 GET OLD.BIN', {
    ...tftpScenario('OLD.BIN', replacement), files: {'OLD.BIN': Buffer.from('keep')}, promptKey,
  });
  assert.strictEqual(result.exitCode, 7); assert.match(result.output, /RESULT FAIL code=23/);
  assert.deepStrictEqual(outputFile(result, 'OLD.BIN'), Buffer.from('keep')); checked(result);
}
for (const force of ['-y', '-f']) {
  result = tftpRun(`192.168.7.44 GET OLD.BIN ${force}`, {
    ...tftpScenario('OLD.BIN', replacement), files: {'OLD.BIN': Buffer.from('old')}, promptKey: 'n',
  });
  assert.strictEqual(result.exitCode, 0, result.output);
  assert.deepStrictEqual(outputFile(result, 'OLD.BIN'), replacement); checked(result);
}
result = tftpRun('192.168.7.44 GET OLD.BIN', {
  ...tftpScenario('OLD.BIN', replacement), files: {'OLD.BIN': Buffer.from('old')}, promptKey: 'y',
});
assert.strictEqual(result.exitCode, 0, result.output);
assert.deepStrictEqual(outputFile(result, 'OLD.BIN'), replacement); checked(result);

result = tftpRun('192.168.7.44 GET DIR/REMOTE.BIN -o SUB/LOCAL.BIN', {
  ...tftpScenario('DIR/REMOTE.BIN', replacement), traceDss: true,
});
assert.strictEqual(result.exitCode, 0, result.output);
assert.deepStrictEqual(result.files['C:\\NET\\SUB\\LOCAL.BIN'], replacement);
assert.ok(result.dssEvents.includes('CREATE C:\\NET\\SUB\\LOCAL.BIN')); checked(result);
assert.strictEqual(result.currentDir, 'C:\\NET');
result = tftpRun('192.168.7.44 PUT SUB/LOCAL.BIN -o DIR/REMOTE.BIN', {
  ...tftpScenario('unused', Buffer.alloc(0)), files: {'SUB/LOCAL.BIN': replacement}, traceDss: true,
});
assert.strictEqual(result.exitCode, 0, result.output);
assert.deepStrictEqual(result.tftpUploads['DIR/REMOTE.BIN'], replacement);
assert.ok(result.dssEvents.includes('OPEN C:\\NET\\SUB\\LOCAL.BIN 33')); checked(result);
assert.strictEqual(result.currentDir, 'C:\\NET');

result = tftpRun('192.168.7.44 GET DIR/REMOTE.BIN -o C:\\ROOT.BIN', {
  ...tftpScenario('DIR/REMOTE.BIN', replacement), traceDss: true,
});
assert.strictEqual(result.exitCode, 0, result.output);
assert.deepStrictEqual(result.files['C:\\ROOT.BIN'], replacement);
assert.ok(result.dssEvents.includes('CHDIR C:\\'));
assert.strictEqual(result.currentDir, 'C:\\NET'); checked(result);

result = tftpRun('192.168.7.44 PUT C:\\ROOT.BIN -o DIR/ROOT.BIN', {
  ...tftpScenario('unused', Buffer.alloc(0)), files: {'C:\\ROOT.BIN': replacement}, traceDss: true,
});
assert.strictEqual(result.exitCode, 0, result.output);
assert.deepStrictEqual(result.tftpUploads['DIR/ROOT.BIN'], replacement);
assert.ok(result.dssEvents.includes('OPEN C:\\ROOT.BIN 33'));
assert.strictEqual(result.currentDir, 'C:\\NET'); checked(result);

const longCurrentDir = `C:\\${'D'.repeat(180)}`;
result = tftpRun('192.168.7.44 GET DIR/REMOTE.BIN -o SUB/LOCAL.BIN', {
  ...tftpScenario('DIR/REMOTE.BIN', replacement), currentDir: longCurrentDir,
});
assert.strictEqual(result.exitCode, 0, result.output);
assert.deepStrictEqual(result.files[`${longCurrentDir}\\SUB\\LOCAL.BIN`], replacement);
assert.strictEqual(result.currentDir, longCurrentDir); checked(result);

result = tftpRun('192.168.7.44 PUT MISSING.BIN', tftpScenario('unused', Buffer.alloc(0)));
assert.strictEqual(result.exitCode, 5); assert.match(result.output, /RESULT FAIL code=26/); checked(result);
result = tftpRun('192.168.7.44 PUT INPUT.BIN', {
  ...tftpScenario('unused', Buffer.alloc(0)), files: {'INPUT.BIN': fixture(100)}, fileReadFailAt: 1,
});
assert.strictEqual(result.exitCode, 5); assert.match(result.output, /RESULT FAIL code=26/); checked(result);
result = tftpRun('192.168.7.44 PUT INPUT.BIN -o SHORT.BIN', {
  ...tftpScenario('unused', Buffer.alloc(0)), files: {'INPUT.BIN': fixture(100)}, fileReadMax: 37,
});
assert.strictEqual(result.exitCode, 0, result.output);
assert.deepStrictEqual(result.tftpUploads['SHORT.BIN'], fixture(100).subarray(0, 37)); checked(result);
result = tftpRun('192.168.7.44 GET WRITE.BIN -o WRITE.BIN', {
  ...tftpScenario('WRITE.BIN', fixture(100)), fileWriteFailAt: 1,
});
assert.strictEqual(result.exitCode, 5); assert.match(result.output, /RESULT FAIL code=26/);
assert.strictEqual(outputFile(result, 'WRITE.BIN').length, 0); checked(result);
result = tftpRun('192.168.7.44 GET LARGE.BIN -o PART.BIN', {
  ...tftpScenario('LARGE.BIN', fixture(20000)), diskFullAfter: 9000,
});
assert.strictEqual(result.exitCode, 5); assert.match(result.output, /RESULT FAIL code=26/);
assert.strictEqual(outputFile(result, 'PART.BIN').length, 7140); checked(result);

result = tftpRun('192.168.7.44 GET REMOTE.BIN', tftpScenario('REMOTE.BIN', fixture(17), {
  oversizedOack: true,
}));
assert.strictEqual(result.exitCode, 6); assert.match(result.output, /RESULT FAIL code=25/);
assert.ok(tftpOpcodes(result).some((packet) => packet.opcode === 5 && packet.errorCode === 8)); checked(result);
result = tftpRun('192.168.7.44 GET REMOTE.BIN', tftpScenario('REMOTE.BIN', fixture(17), {
  error: {code: 2, message: 'X'.repeat(100)},
}));
assert.strictEqual(result.exitCode, 6);
assert.match(result.output, /TFTP ERROR code=2 message=X{79}/);
assert.doesNotMatch(result.output, /X{80}/); assert.match(result.output, /RESULT FAIL code=25/); checked(result);

result = tftpRun('192.168.7.44 GET REMOTE.BIN', tftpScenario('REMOTE.BIN', fixture(17), {
  unknownTidMalformed: true,
}));
assert.strictEqual(result.exitCode, 0, result.output);
assert.ok(tftpOpcodes(result).some((packet) => packet.destinationPort === 0xbef0 &&
  packet.opcode === 5 && packet.errorCode === 5)); checked(result);

result = tftpRun('192.168.7.44 GET REMOTE.BIN', tftpScenario('REMOTE.BIN', fixture(17), {
  unknownTidDally: true,
}));
assert.strictEqual(result.exitCode, 0, result.output);
assert.ok(tftpOpcodes(result).some((packet) => packet.destinationPort === 0xbef0 &&
  packet.opcode === 5 && packet.errorCode === 5));
assert.strictEqual(result.rxRemaining, 0); checked(result);

result = tftpRun('192.168.7.44 GET REMOTE.BIN', tftpScenario('REMOTE.BIN', fixture(17), {
  dropResponses: 100,
}));
assert.strictEqual(result.exitCode, 3); assert.match(result.output, /RESULT FAIL code=14/); checked(result);
result = tftpRun('192.168.7.44 GET REMOTE.BIN', tftpScenario('REMOTE.BIN', fixture(17), {
  fallback: true, serverTid: 0,
}));
assert.strictEqual(result.exitCode, 3, result.output);
assert.match(result.output, /RESULT FAIL code=14/); checked(result);
result = tftpRun('192.168.7.44 GET REMOTE.BIN', {
  environment: staticEnv(), arp: {ip: [192,168,7,44], mac: [2,0,0,0,0,44]},
  udp: {mode: 'unreachable', port: 69},
});
assert.strictEqual(result.exitCode, 6); assert.match(result.output, /RESULT FAIL code=24/); checked(result);

for (const key of ['escape', 'ctrl-c']) {
  result = tftpRun('192.168.7.44 GET REMOTE.BIN', {
    ...tftpScenario('REMOTE.BIN', fixture(17), {dropResponses: 100}), key,
  });
  assert.strictEqual(result.exitCode, 7); assert.match(result.output, /RESULT FAIL code=23/); checked(result);
}

const routedEnv = staticEnv(); routedEnv.NET_IP_SRC = 'DHCP';
result = tftpRun('203.0.113.44:6969 GET ROUTED.BIN -o ROUTED.BIN', {
  environment: routedEnv, arp: {ip: [192,168,7,1], mac: [2,0,0,0,0,1]},
  tftp: {files: {'ROUTED.BIN': fixture(19)}, extraPorts: [6969], ip: [203,0,113,44]},
});
assert.strictEqual(result.exitCode, 0, result.output);
assert.deepStrictEqual(outputFile(result, 'ROUTED.BIN'), fixture(19)); checked(result);

console.log(`Stage 9 actual EXEs: ${cases} UDP/TFTP CLI, codec, retry, filesystem, routing and cleanup checks passed`);
