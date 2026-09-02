#!/usr/bin/env node
// Actual PING/PINGALT DSS EXE scenarios over the strict 3C509B model.
// SPDX-License-Identifier: BSD-3-Clause
'use strict';

const assert = require('assert');
const fs = require('fs');
const path = require('path');
const {runExe} = require('./exe-harness/harness.js');

const root = path.resolve(__dirname, '..');
const exe = (name) => path.join(root, 'build', `${name}.EXE`);
let cases = 0;

function staticEnv() {
  return {
    NET: '509B', NET_HW: 'AUTO', NET_IDPORT: '#110', NET_MAC: '02:60:8C:12:34:56',
    NET_IP_SRC: 'STATIC', NET_IP: '192.168.7.20', NET_MASK: '255.255.255.0',
    NET_GW: '192.168.7.1', NET_DNS1: '1.1.1.1', NET_DNS2: '8.8.8.8',
    NET_NTP: 'pool.ntp.org', NET_TZ: '+4',
  };
}
function dhcpEnv() { return {...staticEnv(), NET_IP_SRC: 'DHCP'}; }
function direct(extra = {}) {
  return {environment: staticEnv(), arp: {ip: [192,168,7,44], mac: [2,0,0,0,0,44]},
    icmp: {mode: 'echo'}, ...extra};
}
function routed(extra = {}) {
  return {environment: staticEnv(), arp: {ip: [192,168,7,1], mac: [2,0,0,0,0,1]},
    icmp: {mode: 'echo', routerIp: [192,168,7,1]}, ...extra};
}
function run(name, args, scenario) { return runExe(exe(name), args, scenario); }
function checked(result) {
  assert.deepStrictEqual(result.cleanup, {isaClosed: true, pagesFreed: true, done: true});
  cases++;
}
function checksum(bytes) {
  let sum = 0;
  for (let i = 0; i < bytes.length; i += 2) {
    sum += (bytes[i] << 8) | (bytes[i + 1] || 0);
    sum = (sum & 0xffff) + (sum >>> 16);
  }
  return (~sum) & 0xffff;
}

for (const name of ['PING', 'PINGALT']) {
  const image = fs.readFileSync(exe(name));
  assert.strictEqual(image.subarray(0, 4).toString('binary'), 'EXE\x01');
  assert.strictEqual(image.readUInt16LE(4), 128);
  assert.strictEqual(image.readUInt16LE(16), 0x8100);
  assert.ok(0x8080 + image.length < 0xbef0, `${name} overlaps bootstrap state`);
  let longest = 0, current = 0;
  for (const byte of image.subarray(128)) { current = byte ? 0 : current + 1; longest = Math.max(longest, current); }
  assert.ok(longest < 128, `${name} contains a zero-filled runtime allocation`);
  cases++;
}

// Help and the full grammar are handled before any card access.
for (const name of ['PING', 'PINGALT']) {
  for (const help of ['-h', '/H', '-?']) {
    const result = run(name, help, {cardPresent: false});
    assert.strictEqual(result.exitCode, 0); assert.match(result.output, /Usage: PING/); checked(result);
  }
  for (const bad of [
    '', '192.168.7.44 extra', '-n 0 192.168.7.44',
    '-n 65536 192.168.7.44', '-l 1473 192.168.7.44', '-i 0 192.168.7.44',
    '-i 256 192.168.7.44', '-w 0 192.168.7.44', '-w 65536 192.168.7.44',
    '-n 1 /n 2 192.168.7.44', '-t -n 1 192.168.7.44', '-h 192.168.7.44',
  ]) {
    const result = run(name, bad, {cardPresent: false});
    assert.strictEqual(result.exitCode, 1, `${name} accepted '${bad}'`);
    assert.strictEqual(result.transmittedFrames.length, 0);
    assert.strictEqual(result.card.active, false); checked(result);
  }
  for (const valid of [
    '-n 1 -l 0 -i 1 -w 1 192.168.7.44',
    '/N 65535 /L 1472 /I 255 /W 65535 192.168.7.44',
  ]) {
    const result = run(name, valid, {environment: staticEnv(), cardPresent: false});
    assert.strictEqual(result.exitCode, 2, `${name} rejected valid boundaries`); checked(result);
  }
}

// Direct/static and routed/DHCP paths execute both independent EXEs.
for (const name of ['PING', 'PINGALT']) {
  let result = run(name, '-n 1 192.168.7.44', direct());
  assert.strictEqual(result.exitCode, 0); assert.match(result.output, /bytes=32 ttl=63 time~=/);
  assert.strictEqual(result.transmittedFrames.length, 2); checked(result);

  result = run(name, '-n 1 -l 1 -i 255 203.0.113.10',
    {...routed(), environment: dhcpEnv()});
  assert.strictEqual(result.exitCode, 0); assert.match(result.output, /Reply from 203\.0\.113\.10: bytes=1/);
  const request = Buffer.from(result.transmittedFrames[1], 'hex');
  assert.strictEqual(request[22], 255); assert.strictEqual(request.length, 60);
  assert.deepStrictEqual([...request.subarray(0, 6)], [2,0,0,0,0,1]); checked(result);
}

let result = run('PING', '-n 1 192.168.7.1', routed());
assert.strictEqual(result.exitCode, 0); assert.match(result.output, /Reply from 192\.168\.7\.1/);
checked(result);

// Payload/TTL boundaries and exact wire checksums.
for (const size of [0, 1, 32, 1472]) {
  const ttl = size === 0 ? 1 : 255;
  const result = run('PING', `-n 1 -l ${size} -i ${ttl} 192.168.7.44`, direct());
  assert.strictEqual(result.exitCode, 0);
  const frame = Buffer.from(result.transmittedFrames[1], 'hex');
  assert.strictEqual(frame.length, Math.max(60, 42 + size));
  assert.strictEqual(frame.readUInt16BE(16), 28 + size);
  assert.strictEqual(frame[22], ttl);
  assert.strictEqual(checksum(frame.subarray(14, 34)), 0);
  assert.strictEqual(checksum(frame.subarray(34, 42 + size)), 0);
  for (let i = 0; i < size; i++) assert.strictEqual(frame[42 + i], i & 255);
  checked(result);
}

// Foreign, corrupted and bad-checksum traffic is consumed without extending
// the original deadline; a later valid reply still wins.
result = run('PING', '-n 1 192.168.7.44', direct({
  timeStepSeconds: 0.125,
  icmp: {mode: 'echo', unrelatedBeforeReply: true, badIpBeforeReply: true,
    badIcmpBeforeReply: true, corruptBeforeReply: true,
    foreignSourceBeforeReply: true, foreignDestinationBeforeReply: true,
    unrelatedUnreachableBeforeReply: true, rxStatusBeforeReply: true,
    badRequestBeforeReply: true},
}));
assert.strictEqual(result.exitCode, 0); assert.strictEqual(result.generatedFrames.length, 11);
assert.strictEqual(result.rxRemaining, 0);
checked(result);

result = run('PINGALT', '-n 1 -w 1000 192.168.7.44', direct({
  timeStepSeconds: 0.125, icmp: {mode: 'echo', delayPolls: 2},
}));
assert.strictEqual(result.exitCode, 0); assert.match(result.output, /RESULT OK/); checked(result);

// With a one-quantum deadline, main PING reaches the valid second frame inside
// its bounded drain budget; PINGALT consumes only the first frame before time.
result = run('PING', '-n 1 -w 1 192.168.7.44', direct({
  icmp: {mode: 'echo', unrelatedBeforeReply: true},
}));
assert.strictEqual(result.exitCode, 0); checked(result);
result = run('PINGALT', '-n 1 -w 1 192.168.7.44', direct({
  icmp: {mode: 'echo', unrelatedBeforeReply: true},
}));
assert.strictEqual(result.exitCode, 3); checked(result);

// ARP resolution uses the fixed-base monotonic deadline as well as the wall
// watchdog, so a stopped DSS clock cannot leave either executable spinning.
result = run('PING', '-n 1 192.168.7.44', direct({
  arp: {mode: 'drop'}, timeStepSeconds: 0.25, clockFreezeAfterReads: 9,
}));
assert.strictEqual(result.exitCode, 3);
assert.match(result.output, /\[E1\] TIMEOUT stage=ARP.*RESULT FAIL code=14/s);
checked(result);

// A forged future-sequence unreachable arriving between requests is consumed
// outside the request deadline and must not turn an all-timeout run into exit 6.
result = run('PING', '-n 2 -w 1 192.168.7.44', direct({
  icmp: {mode: 'echo', onlyUnrelatedUnreachable: true, delayPolls: 2},
}));
assert.strictEqual(result.exitCode, 3);
assert.doesNotMatch(result.output, /\[E3\] UNREACHABLE/);
checked(result);

// Partial loss succeeds; complete loss, remote unreachable and cancellation
// use stable statuses and distinct DSS exit classes.
result = run('PING', '-n 3 -w 1 192.168.7.44', direct({icmp: {mode: 'echo', drop: 1}}));
assert.strictEqual(result.exitCode, 0); assert.strictEqual(result.transmittedFrames.length, 4); checked(result);

for (const name of ['PING', 'PINGALT']) {
  result = run(name, '-n 1 -w 1 192.168.7.44', direct({icmp: {mode: 'drop'}}));
  assert.strictEqual(result.exitCode, 3); assert.match(result.output, /\[E2\] TIMEOUT.*RESULT FAIL code=14/s); checked(result);

  result = run(name, '-n 1 203.0.113.10', routed({icmp: {mode: 'unreachable'}}));
  assert.strictEqual(result.exitCode, 6); assert.match(result.output, /\[E3\] UNREACHABLE code=24.*RESULT FAIL code=24/s); checked(result);

  for (const key of ['escape', 'ctrl-c']) {
    result = run(name, '-t 192.168.7.44', direct({key, icmp: {mode: 'echo'}}));
    assert.strictEqual(result.exitCode, 7); assert.match(result.output, /RESULT FAIL code=23/); checked(result);
  }
}

// ARP and incoming Echo Requests are answered while the awaited reply remains
// matched by the original source/id/sequence/payload tuple.
result = run('PING', '-n 1 192.168.7.44', {
  environment: staticEnv(),
  arp: {ip: [192,168,7,44], mac: [2,0,0,0,0,44], requestBeforeReply: true},
  icmp: {mode: 'echo', requestBeforeReply: true},
});
assert.strictEqual(result.exitCode, 0); assert.strictEqual(result.transmittedFrames.length, 4);
assert.ok(result.transmittedFrames.some((hex) => Buffer.from(hex, 'hex')[34] === 0)); checked(result);

// Long-run gate: one ARP plus 1000 byte-exact Echo Requests/Replies, with one
// allocation freed only after the final request.
result = run('PING', '-n 1000 -l 0 192.168.7.44',
  direct({stepLimit: 500_000_000}));
assert.strictEqual(result.exitCode, 0);
assert.strictEqual(result.transmittedFrames.length, 1001);
assert.strictEqual((result.output.match(/Reply from/g) || []).length, 1000);
checked(result);

console.log(`Stage 8 actual EXE: ${cases} CLI, IPv4/ICMP, routing, loss, cancel and cleanup checks passed`);
