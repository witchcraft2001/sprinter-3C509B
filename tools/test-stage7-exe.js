#!/usr/bin/env node
// Actual DSS EXE integration vectors for NETCFG, IFUP/DHCP and ARP.
// SPDX-License-Identifier: BSD-3-Clause
'use strict';

const assert = require('assert');
const path = require('path');
const fs = require('fs');
const {runExe} = require('./exe-harness/harness.js');

const root = path.resolve(__dirname, '..');
const exe = (name) => path.join(root, 'build', `${name}.EXE`);
const appDir = 'C:\\NET';
const cfgPath = `${appDir}\\NET.CFG`;
let cases = 0;

const dhcpConfig = [
  '# Stage 7 sample', 'NET=509B', 'HW=AUTO', 'IDPORT=#110', 'MAC=',
  'IP=DHCP', 'NETMASK=', 'GATEWAY=', 'DNS1=', 'DNS2=',
  'NTP=pool.ntp.org', 'TZ=+4', '',
].join('\r\n');
const staticConfig = [
  'NET=509B', 'HW=1/#320', 'IDPORT=#110', 'MAC=02:11:22:33:44:55',
  'IP=192.168.7.2', 'NETMASK=255.255.255.0', 'GATEWAY=192.168.7.1',
  'DNS1=1.1.1.1', 'DNS2=8.8.8.8', 'NTP=pool.ntp.org', 'TZ=-4', '',
].join('\n');

function run(name, args = '', scenario = {}) { return runExe(exe(name), args, scenario); }
function cfgScenario(config, extra = {}) { return {appDir, files: {[cfgPath]: config}, ...extra}; }
function cleanup(result) {
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
function udpChecksum(frame) {
  const ip = frame.subarray(14), udpLength = ip.readUInt16BE(24);
  return checksum(Buffer.concat([
    ip.subarray(12, 20), Buffer.from([0, 17, udpLength >> 8, udpLength & 255]),
    ip.subarray(20, 20 + udpLength),
  ]));
}
function baseStaticEnv() {
  return {
    NET: '509B', NET_HW: 'AUTO', NET_IDPORT: '#110', NET_MAC: '02:60:8C:12:34:56',
    NET_IP_SRC: 'STATIC', NET_IP: '192.168.7.2', NET_MASK: '255.255.255.0',
    NET_GW: '192.168.7.1', NET_DNS1: '1.1.1.1', NET_DNS2: '8.8.8.8',
    NET_NTP: 'pool.ntp.org', NET_TZ: '+4',
  };
}
function baseDhcpEnv() {
  return {
    NET: '509B', NET_HW: 'AUTO', NET_IDPORT: '#110', NET_MAC: '02:60:8C:12:34:56',
    NET_IP_SRC: 'DHCP', NET_NTP: 'pool.ntp.org', NET_TZ: '+4',
  };
}

for (const name of ['NETCFG', 'IFUP', 'ARP']) {
  const image = fs.readFileSync(exe(name));
  assert.strictEqual(image.subarray(0, 4).toString('binary'), 'EXE\x01');
  assert.strictEqual(image.readUInt16LE(4), 128);
  assert.strictEqual(image.readUInt16LE(16), 0x8100);
  assert.ok(0x8080 + image.length < 0xc000);
  cases++;
}

// NETCFG modes, parser boundaries and persistent environment.
const environment = {NET_IP: 'stale', NET_LEASE_SEC: 'stale'};
let result = run('NETCFG', '-i -v', cfgScenario(dhcpConfig, {environment}));
assert.strictEqual(result.exitCode, 0); assert.match(result.output, /warnings=0/);
assert.deepStrictEqual(environment, {
  NET: '509B', NET_HW: '1/#300', NET_IDPORT: '#110', NET_MAC: '02:60:8C:12:34:56',
  NET_IP_SRC: 'DHCP', NET_NTP: 'pool.ntp.org', NET_TZ: '+4',
}); cleanup(result);

result = run('NETCFG', '', {environment});
assert.strictEqual(result.exitCode, 0); assert.match(result.output, /NET_IP=<not set>/); cleanup(result);
const beforeVerify = {...environment};
result = run('NETCFG', '-v', cfgScenario(dhcpConfig, {environment}));
assert.strictEqual(result.exitCode, 0); assert.deepStrictEqual(environment, beforeVerify); cleanup(result);
result = run('NETCFG', '-c', cfgScenario(dhcpConfig, {environment, cardPresent: false}));
assert.strictEqual(result.exitCode, 0); cleanup(result);
const longAppDir = `C:\\${'A'.repeat(240)}`;
result = run('NETCFG', '-c', {appDir: longAppDir,
  files: {[`${longAppDir}\\NET.CFG`]: dhcpConfig}});
assert.strictEqual(result.exitCode, 0); cleanup(result);
result = run('NETCFG', '-c -v', cfgScenario(dhcpConfig, {environment, cardPresent: false}));
assert.strictEqual(result.exitCode, 2); assert.deepStrictEqual(environment, beforeVerify); cleanup(result);

const staticEnv = {};
result = run('NETCFG', '-i', cfgScenario(staticConfig, {environment: staticEnv, slot: 1}));
assert.strictEqual(result.exitCode, 0);
assert.strictEqual(result.card.base, 0x320); assert.strictEqual(result.card.station, '021122334455');
assert.deepStrictEqual(result.probedSlots, [1], 'a matching pin must not scan the other slot');
assert.deepStrictEqual(staticEnv, {
  NET: '509B', NET_HW: '1/#320', NET_IDPORT: '#110', NET_MAC: '02:11:22:33:44:55',
  NET_IP_SRC: 'STATIC', NET_IP: '192.168.7.2', NET_MASK: '255.255.255.0',
  NET_GW: '192.168.7.1', NET_DNS1: '1.1.1.1', NET_DNS2: '8.8.8.8',
  NET_NTP: 'pool.ntp.org', NET_TZ: '-4',
}); cleanup(result);

const slot0Env = {};
const slot0Config = staticConfig.replace('HW=1/#320', 'HW=0/#200').replace('MAC=02:11:22:33:44:55', 'MAC=');
result = run('NETCFG', '-i -v', cfgScenario(slot0Config, {environment: slot0Env, slot: 0}));
assert.strictEqual(result.exitCode, 0); assert.strictEqual(result.card.base, 0x200);
assert.deepStrictEqual(result.probedSlots, [0], 'a matching pin must not scan the other slot');
assert.strictEqual(slot0Env.NET_HW, '0/#200'); assert.strictEqual(slot0Env.NET_MAC, '02:60:8C:12:34:56');
cleanup(result);

// A pin naming a slot the card is not in falls back to auto-probing (the
// other slot first) and republishes the card's true location with a warning,
// instead of failing outright.
const staleEnv = {};
const staleConfig = staticConfig.replace('HW=1/#320', 'HW=0/#300').replace('MAC=02:11:22:33:44:55', 'MAC=');
result = run('NETCFG', '-i', cfgScenario(staleConfig, {environment: staleEnv, slot: 1}));
assert.strictEqual(result.exitCode, 0, result.output);
assert.deepStrictEqual(result.probedSlots, [0, 1]);
assert.match(result.output, /\[W\] HW=0\/#300 not usable, probed 1\/#300/);
assert.strictEqual(staleEnv.NET_HW, '1/#300');
cleanup(result);

const duplicate = staticConfig.replace('IP=192.168.7.2', 'IP=10.0.0.1\nUNKNOWN=x\nIP=192.168.7.2');
result = run('NETCFG', '-c -v', cfgScenario(duplicate, {slot: 1}));
assert.strictEqual(result.exitCode, 0); assert.match(result.output, /warnings=2/); cleanup(result);

for (const bad of [
  null, 'NET=RTL\nHW=AUTO\nIDPORT=#110\nIP=DHCP\n',
  'NET=509B\nHW=AUTO\nIDPORT=#111\nIP=DHCP\n',
  'NET=509B\nHW=AUTO\nIDPORT=#110\nMAC=00:00:00:00:00:00\nIP=DHCP\n',
  'NET=509B\nHW=AUTO\nIDPORT=#110\nMAC=01:00:00:00:00:01\nIP=DHCP\n',
  'NET=509B\nHW=AUTO\nIDPORT=#110\nIP=999.1.1.1\nNETMASK=255.255.255.0\n',
  'NET=509B\nHW=2/#300\nIDPORT=#110\nIP=DHCP\n', 'X'.repeat(2048),
]) {
  const scenario = bad === null ? {appDir, files: {}} : cfgScenario(bad);
  result = run('NETCFG', '-c', scenario);
  assert.strictEqual(result.exitCode, 4); assert.match(result.output, /RESULT FAIL code=22/); cleanup(result);
}
for (const args of ['-i -c', '-d -v', '-x']) {
  result = run('NETCFG', args); assert.strictEqual(result.exitCode, 1); cleanup(result);
}

// ENV failure rolls every already-written value back to its byte-identical map.
const rollbackEnv = {NET: 'OLD', NET_IP: '10.1.2.3', NET_TZ: '-9'};
const rollbackBefore = {...rollbackEnv};
result = run('NETCFG', '-i', cfgScenario(dhcpConfig, {environment: rollbackEnv, envFailAt: 5}));
assert.strictEqual(result.exitCode, 5); assert.deepStrictEqual(rollbackEnv, rollbackBefore); cleanup(result);
result = run('NETCFG', '-i', cfgScenario(dhcpConfig, {environment: rollbackEnv, cardPresent: false}));
assert.strictEqual(result.exitCode, 2); assert.deepStrictEqual(rollbackEnv, rollbackBefore); cleanup(result);
result = run('NETCFG', '-d', {environment: rollbackEnv});
assert.strictEqual(result.exitCode, 0); assert.deepStrictEqual(rollbackEnv, {}); cleanup(result);

// Static IFUP and hardware/link/config failures.
result = run('IFUP', '', {environment: baseStaticEnv()});
assert.strictEqual(result.exitCode, 0); assert.match(result.output, /STATIC IP=192\.168\.7\.2/); cleanup(result);

// A pin matching the card's actual slot skips the other slot entirely, and a
// stale pin falls back to auto-probing and republishes the true location --
// the same self-healing NETCFG -i gets from RECORD_HW.
result = run('IFUP', '', {environment: {...baseStaticEnv(), NET_HW: '1/#300'}});
assert.strictEqual(result.exitCode, 0);
assert.deepStrictEqual(result.probedSlots, [1], 'a matching pin must not scan the other slot');
cleanup(result);

const ifupStaleEnv = {...baseStaticEnv(), NET_HW: '0/#300'};
result = run('IFUP', '', {environment: ifupStaleEnv});
assert.strictEqual(result.exitCode, 0, result.output);
assert.deepStrictEqual(result.probedSlots, [0, 1]);
assert.match(result.output, /\[W\] HW=0\/#300 not usable, probed 1\/#300/);
assert.strictEqual(ifupStaleEnv.NET_HW, '1/#300');
cleanup(result);

// A pin still fails when no card answers either slot: the fallback is bounded
// by the same two probes AUTO makes and reports EL3_ERR_NOT_FOUND, not a hang.
result = run('IFUP', '', {environment: {...baseStaticEnv(), NET_HW: '0/#300'},
  cardPresent: false});
assert.strictEqual(result.exitCode, 2);
assert.match(result.output, /RESULT FAIL code=3/);
assert.deepStrictEqual(result.probedSlots, [0, 1]);
cleanup(result);

// The static republish touches nothing but NET_HW, except that it drops a
// lease left over from an earlier DHCP run -- inert once NET_IP_SRC=STATIC,
// and exactly what NETCFG -i does. Absent optionals stay absent.
const ifupStaticEnv = {...baseStaticEnv(), NET_DHCP_SRV: '192.168.7.1', NET_LEASE_SEC: '86400'};
result = run('IFUP', '', {environment: ifupStaticEnv});
assert.strictEqual(result.exitCode, 0, result.output);
assert.deepStrictEqual(ifupStaticEnv, {...baseStaticEnv(), NET_HW: '1/#300'});
cleanup(result);

const ifupBareEnv = {
  NET: '509B', NET_HW: 'AUTO', NET_IDPORT: '#110', NET_MAC: '02:60:8C:12:34:56',
  NET_IP_SRC: 'STATIC', NET_IP: '192.168.7.2', NET_MASK: '255.255.255.0',
};
result = run('IFUP', '', {environment: ifupBareEnv});
assert.strictEqual(result.exitCode, 0, result.output);
assert.deepStrictEqual(Object.keys(ifupBareEnv).sort(), [
  'NET', 'NET_HW', 'NET_IDPORT', 'NET_IP', 'NET_IP_SRC', 'NET_MAC', 'NET_MASK',
]);
cleanup(result);

// Refreshing NET_HW is best effort: a static interface that is genuinely up
// must not start failing because the environment cannot be written, and
// PUBLISH's rollback must leave the old values byte for byte.
const ifupEnvFail = baseStaticEnv();
const ifupEnvBefore = {...ifupEnvFail};
result = run('IFUP', '', {environment: ifupEnvFail, envFailAt: 3});
assert.strictEqual(result.exitCode, 0, result.output);
assert.match(result.output, /STATIC IP=192\.168\.7\.2/);
assert.deepStrictEqual(ifupEnvFail, ifupEnvBefore);
cleanup(result);

result = run('IFUP', '', {environment: baseStaticEnv(), link: false});
assert.strictEqual(result.exitCode, 3);
assert.match(result.output, /TIMEOUT stage=LINK elapsed_waitq=#[0-9A-F]{4} slot=1 base=#0300 status=#[0-9A-F]{4}/);
cleanup(result);
result = run('IFUP', '-r', {environment: baseStaticEnv()});
assert.strictEqual(result.exitCode, 4); cleanup(result);
result = run('IFUP', '', {environment: {...baseStaticEnv(), NET_MASK: ''}});
assert.strictEqual(result.exitCode, 4); cleanup(result);
result = run('IFUP', '', {environment: {...baseStaticEnv(), NET_IP_SRC: 'BOGUS'}});
assert.strictEqual(result.exitCode, 4); cleanup(result);
for (const environment of [
  {...baseStaticEnv(), NET: '509B-TOO-LONG'},
  {...baseStaticEnv(), NET_IP: '192.168.7.2-TOO-LONG'},
  {...baseStaticEnv(), NET_NTP: 'x'.repeat(40)},
]) {
  result = run('IFUP', '', {environment});
  assert.strictEqual(result.exitCode, 4); assert.match(result.output, /RESULT FAIL code=22/); cleanup(result);
}
result = run('IFUP', '-h trailing', {environment: baseStaticEnv()});
assert.strictEqual(result.exitCode, 1); cleanup(result);

// DHCP acquire, checksums, retry, NAK and timeout with stale-value clearing.
let dhcpEnv = {...baseDhcpEnv(), NET_IP: 'old', NET_DNS1: 'old', NET_DHCP_SRV: 'old', NET_LEASE_SEC: 'old'};
result = run('IFUP', '', {environment: dhcpEnv, dhcp: {mode: 'ack', lease: 86400}});
assert.strictEqual(result.exitCode, 0); assert.strictEqual(result.transmittedFrames.length, 2);
const discover = Buffer.from(result.transmittedFrames[0], 'hex');
const request = Buffer.from(result.transmittedFrames[1], 'hex');
assert.strictEqual(checksum(discover.subarray(14, 34)), 0);
assert.strictEqual(udpChecksum(discover), 0); assert.strictEqual(udpChecksum(request), 0);
assert.strictEqual(discover.readUInt16BE(34), 68); assert.strictEqual(discover.readUInt16BE(36), 67);
assert.ok(discover.includes(Buffer.from([53, 1, 1]))); assert.ok(request.includes(Buffer.from([53, 1, 3])));
assert.ok(request.includes(Buffer.from([50, 4, 192, 168, 7, 100])));
assert.deepStrictEqual(dhcpEnv, {
  ...baseDhcpEnv(), NET_HW: '1/#300', NET_IP: '192.168.7.100', NET_MASK: '255.255.255.0',
  NET_GW: '192.168.7.1', NET_DNS1: '1.1.1.1', NET_DNS2: '8.8.8.8',
  NET_DHCP_SRV: '192.168.7.1', NET_LEASE_SEC: '86400',
}); cleanup(result);

for (const dhcp of [{mode: 'ack', dropDiscover: 2}, {mode: 'ack', dropRequest: 1}]) {
  dhcpEnv = baseDhcpEnv(); result = run('IFUP', '', {environment: dhcpEnv, dhcp});
  assert.strictEqual(result.exitCode, 0); assert.ok(result.transmittedFrames.length >= 3); cleanup(result);
}
for (const dhcp of [{mode: 'nak'}, {mode: 'drop'}]) {
  dhcpEnv = {...baseDhcpEnv(), NET_IP: 'stale', NET_MASK: 'stale', NET_LEASE_SEC: 'stale'};
  result = run('IFUP', '', {environment: dhcpEnv, dhcp});
  assert.strictEqual(result.exitCode, 3); assert.strictEqual(dhcpEnv.NET_IP, undefined);
  assert.strictEqual(dhcpEnv.NET_MASK, undefined); assert.strictEqual(dhcpEnv.NET_LEASE_SEC, undefined); cleanup(result);
  if (dhcp.mode === 'drop') assert.match(result.output,
    /TIMEOUT stage=DHCP_OFFER elapsed_sec=16 slot=1 base=#0300 status=#[0-9A-F]{4} target=255\.255\.255\.255:67/);
}
for (const malformed of [
  {badXid: true}, {badChaddr: true}, {badCookie: true},
  {badOptions: true}, {badUdpChecksum: true}, {foreignDestination: true},
  {missingServer: true}, {missingLease: true}, {zeroYiaddr: true},
  {badMaskLength: true}, {badRouterLength: true}, {badDnsLength: true},
  {badLeaseLength: true},
]) {
  dhcpEnv = {...baseDhcpEnv(), NET_IP: 'stale', NET_LEASE_SEC: 'stale'};
  result = run('IFUP', '', {environment: dhcpEnv, dhcp: {mode: 'ack', ...malformed}});
  assert.strictEqual(result.exitCode, 3);
  assert.strictEqual(dhcpEnv.NET_IP, undefined); assert.strictEqual(dhcpEnv.NET_LEASE_SEC, undefined);
  cleanup(result);
}
for (const key of ['escape', 'ctrl-c']) {
  dhcpEnv = {...baseDhcpEnv(), NET_IP: 'stale', NET_LEASE_SEC: 'stale'};
  result = run('IFUP', '', {environment: dhcpEnv, dhcp: {mode: 'drop'}, key});
  assert.strictEqual(result.exitCode, 7); assert.match(result.output, /RESULT FAIL code=23/);
  assert.strictEqual(dhcpEnv.NET_IP, undefined); assert.strictEqual(result.transmittedFrames.length, 1);
  cleanup(result);
}

// ARP same-subnet, gateway, broadcasts, request answering, malformed traffic and timeout.
result = run('ARP', '192.168.7.44', {environment: baseStaticEnv(), arp: {ip: [192,168,7,44], mac: [2,0,0,0,0,44]}});
assert.strictEqual(result.exitCode, 0); assert.match(result.output, /via=192\.168\.7\.44.*00:2C/); cleanup(result);
result = run('ARP', '-v 8.8.8.8', {environment: baseStaticEnv(), arp: {ip: [192,168,7,1], mac: [2,0,0,0,0,1]}});
assert.strictEqual(result.exitCode, 0); assert.match(result.output, /target=8\.8\.8\.8 via=192\.168\.7\.1/); cleanup(result);
for (const target of ['255.255.255.255', '192.168.7.255']) {
  result = run('ARP', target, {environment: baseStaticEnv()});
  assert.strictEqual(result.exitCode, 0); assert.strictEqual(result.transmittedFrames.length, 0); cleanup(result);
}
result = run('ARP', '192.168.7.44', {
  environment: baseStaticEnv(), rxFrames: [[0xff, 1, 2, 3, 4, 5, 6].concat(Array(53).fill(0))],
  arp: {ip: [192,168,7,44], mac: [2,0,0,0,0,44], requestBeforeReply: true},
});
assert.strictEqual(result.exitCode, 0); assert.strictEqual(result.transmittedFrames.length, 2);
assert.strictEqual(Buffer.from(result.transmittedFrames[1], 'hex').readUInt16BE(20), 2); cleanup(result);
result = run('ARP', '192.168.7.99', {environment: baseStaticEnv(), arp: {mode: 'drop'}});
assert.strictEqual(result.exitCode, 3); assert.strictEqual(result.transmittedFrames.length, 3);
assert.match(result.output,
  /TIMEOUT stage=ARP elapsed_sec=2 slot=1 base=#0300 status=#[0-9A-F]{4} target=192\.168\.7\.99/);
cleanup(result);
const hostMaskEnv = {...baseStaticEnv(), NET_MASK: '255.255.255.255'};
result = run('ARP', '192.168.7.2', {environment: hostMaskEnv,
  arp: {ip: [192,168,7,2], mac: [2,0,0,0,0,2]}});
assert.strictEqual(result.exitCode, 0); assert.strictEqual(result.transmittedFrames.length, 1); cleanup(result);
for (const malformed of [{badEtherSource: true}, {foreignDestination: true}, {badOpcodeHigh: true}]) {
  result = run('ARP', '192.168.7.44', {environment: baseStaticEnv(),
    arp: {ip: [192,168,7,44], mac: [2,0,0,0,0,44], ...malformed}});
  assert.strictEqual(result.exitCode, 3); assert.strictEqual(result.transmittedFrames.length, 3); cleanup(result);
}
for (const key of ['escape', 'ctrl-c']) {
  result = run('ARP', '192.168.7.99', {environment: baseStaticEnv(), arp: {mode: 'drop'}, key});
  assert.strictEqual(result.exitCode, 7); assert.match(result.output, /RESULT FAIL code=23/);
  assert.strictEqual(result.transmittedFrames.length, 1); cleanup(result);
}

console.log(`Stage 7 actual EXE: ${cases} NETCFG/IFUP/DHCP/ARP, rollback, ABI boundary and cleanup checks passed`);
