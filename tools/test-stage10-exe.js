#!/usr/bin/env node
// Stage 10 actual DSS EXE scenarios over strict DSS/ISA/3C509B models.
// SPDX-License-Identifier: BSD-3-Clause
'use strict';

const assert = require('assert');
const fs = require('fs');
const path = require('path');
const {runExe} = require('./exe-harness/harness.js');

const root = path.resolve(__dirname, '..');
const exe = (name) => path.join(root, 'build', `${name}.EXE`);
let cases = 0;

function staticEnv(extra = {}) {
  return {
    NET: '509B', NET_HW: 'AUTO', NET_IDPORT: '#110',
    NET_MAC: '02:60:8C:12:34:56', NET_IP_SRC: 'STATIC',
    NET_IP: '192.168.7.20', NET_MASK: '255.255.255.0', NET_GW: '0.0.0.0',
    NET_DNS1: '192.168.7.1', NET_DNS2: '192.168.7.2',
    NET_NTP: 'ntp.test', NET_TZ: '+5:45', ...extra,
  };
}
function leaseEnv(extra = {}) {
  return staticEnv({
    NET_IP_SRC: 'DHCP', NET_IP: '192.168.7.100', NET_MASK: '255.255.255.0',
    NET_GW: '192.168.7.1', NET_DNS1: '1.1.1.1', NET_DNS2: '8.8.8.8',
    NET_DHCP_SRV: '192.168.7.1', NET_LEASE_SEC: '3600', ...extra,
  });
}
function checked(result) {
  assert.deepStrictEqual(result.cleanup, {isaClosed: true, pagesFreed: true, done: true});
  assert.ok(result.minimumSp >= 0xbee0,
    `bootstrap stack guard crossed: #${result.minimumSp.toString(16)}`);
  cases++;
}
function run(name, args, scenario = {}) {
  return runExe(exe(name), args, {strictPc: true, ...scenario});
}

for (const name of ['IFUP', 'PING', 'PINGALT', 'UDPTEST', 'TFTP', 'NSLOOKUP', 'NTP']) {
  const image = fs.readFileSync(exe(name));
  assert.strictEqual(image.subarray(0, 4).toString('binary'), 'EXE\x01');
  assert.strictEqual(image.readUInt16LE(4), 128);
  assert.strictEqual(image.readUInt16LE(16), 0x8100);
  assert.strictEqual(image.readUInt16LE(20), 0xbef0);
  assert.ok(0x8080 + image.length <= 0xbee0, `${name} overlaps bootstrap stack reserve`);
  let longest = 0, current = 0;
  for (const byte of image.subarray(128)) {
    current = byte ? 0 : current + 1; longest = Math.max(longest, current);
  }
  assert.ok(longest < 128, `${name} contains zero-filled runtime BSS`);
  cases++;
}

// CLI errors are decided before any ISA/card access.
for (const [name, args] of [
  ['IFUP', '-r -d'], ['IFUP', '-x'], ['NSLOOKUP', ''],
  ['NSLOOKUP', 'host.test 999.1.1.1'], ['NTP', 'a b'], ['NTP', '-x'],
]) {
  const result = run(name, args, {cardPresent: false});
  assert.strictEqual(result.exitCode, 1, `${name} accepted '${args}'`);
  assert.strictEqual(result.transmittedFrames.length, 0);
  checked(result);
}

// Fresh DHCP acquire remains compatible with Stage 7.
let result = run('IFUP', '', {
  environment: leaseEnv({NET_IP_SRC: 'DHCP', NET_IP: '', NET_MASK: '', NET_GW: '',
    NET_DNS1: '', NET_DNS2: '', NET_DHCP_SRV: '', NET_LEASE_SEC: ''}),
  dhcp: {offeredIp: [192,168,7,100], lease: 3600},
});
assert.strictEqual(result.exitCode, 0, result.output);
assert.strictEqual(result.requestCounts.dhcpDiscover, 1);
assert.strictEqual(result.requestCounts.dhcpRequest, 1);
assert.strictEqual(result.environment.NET_IP, '192.168.7.100');
checked(result);

// Renew uses ciaddr, unicast endpoint, inherits omitted options and atomically
// changes only the lease duration when yiaddr is zero.
const oldLease = leaseEnv();
result = run('IFUP', '-r', {
  environment: {...oldLease}, arp: {ip: [192,168,7,1], mac: [2,0,0,0,0,1]},
  dhcp: {serverIp: [192,168,7,1], zeroYiaddr: true, lease: 7200,
    omitMask: true, omitRouter: true, omitDns: true, unicastReply: true},
});
assert.strictEqual(result.exitCode, 0, result.output);
assert.strictEqual(result.requestCounts.dhcpRequest, 1);
assert.strictEqual(result.environment.NET_IP, oldLease.NET_IP);
assert.strictEqual(result.environment.NET_MASK, oldLease.NET_MASK);
assert.strictEqual(result.environment.NET_GW, oldLease.NET_GW);
assert.strictEqual(result.environment.NET_DNS1, oldLease.NET_DNS1);
assert.strictEqual(result.environment.NET_DNS2, oldLease.NET_DNS2);
assert.strictEqual(result.environment.NET_LEASE_SEC, '7200');
const renew = Buffer.from(result.transmittedFrames[1], 'hex');
assert.deepStrictEqual([...renew.subarray(26, 30)], [192,168,7,100]);
assert.deepStrictEqual([...renew.subarray(54, 58)], [192,168,7,100]);
assert.deepStrictEqual([...renew.subarray(30, 34)], [192,168,7,1]);
checked(result);

for (const [label, extra] of [
  ['timeout', {dhcp: {mode: 'drop'}, timeStepSeconds: 1}],
  ['malformed', {dhcp: {badOptions: true, unicastReply: true,
    serverIp: [192,168,7,1]}, timeStepSeconds: 1}],
  ['cancel', {dhcp: {mode: 'drop'}, key: 'escape', keyAtScan: 1}],
]) {
  result = run('IFUP', '-r', {
    environment: {...oldLease}, arp: {ip: [192,168,7,1], mac: [2,0,0,0,0,1]},
    ...extra,
  });
  assert.deepStrictEqual(result.environment, oldLease, `${label} changed active lease`);
  assert.strictEqual(result.exitCode, label === 'cancel' ? 7 : 3);
  assert.strictEqual(result.requestCounts.dhcpRequest, label === 'cancel' ? 1 : 3);
  checked(result);
}

result = run('IFUP', '-r', {
  environment: {...oldLease}, arp: {ip: [192,168,7,1], mac: [2,0,0,0,0,1]},
  dhcp: {mode: 'nak', serverIp: [192,168,7,1], unicastReply: true},
});
assert.strictEqual(result.exitCode, 3);
for (const key of ['NET_IP', 'NET_MASK', 'NET_GW', 'NET_DNS1', 'NET_DNS2',
  'NET_DHCP_SRV', 'NET_LEASE_SEC']) assert.ok(!(key in result.environment), `NAK retained ${key}`);
assert.strictEqual(result.environment.NET_NTP, oldLease.NET_NTP);
checked(result);

result = run('IFUP', '-d', {
  environment: {...oldLease}, arp: {ip: [192,168,7,1], mac: [2,0,0,0,0,1]}, dhcp: {},
});
assert.strictEqual(result.exitCode, 0, result.output);
assert.strictEqual(result.requestCounts.dhcpRelease, 1);
for (const key of ['NET_IP', 'NET_MASK', 'NET_GW', 'NET_DNS1', 'NET_DNS2',
  'NET_DHCP_SRV', 'NET_LEASE_SEC']) assert.ok(!(key in result.environment), `release retained ${key}`);
checked(result);
const released = {...result.environment};
result = run('IFUP', '-d', {environment: released, cardPresent: false});
assert.strictEqual(result.exitCode, 0);
assert.strictEqual(result.transmittedFrames.length, 0);
checked(result);
result = run('IFUP', '-d', {environment: staticEnv(), cardPresent: false});
assert.strictEqual(result.exitCode, 4);
assert.strictEqual(result.transmittedFrames.length, 0);
checked(result);

const directDns = {environment: staticEnv(), arp: {mac: [2,0,0,0,0,44]},
  dns: {address: [192,168,7,44]}};
result = run('NSLOOKUP', 'host.test', directDns);
assert.strictEqual(result.exitCode, 0, result.output);
assert.match(result.output, /DNS: 192\.168\.7\.1[\s\S]*Address: 192\.168\.7\.44/);
assert.strictEqual(result.requestCounts.dns, 1);
checked(result);

result = run('NSLOOKUP', 'host.test', {
  environment: staticEnv({NET_DNS1: '10.0.0.1', NET_DNS2: '10.0.0.2', NET_GW: '192.168.7.1'}),
  arp: {mac: [2,0,0,0,0,1]},
  dns: {servers: {'10.0.0.1': {mode: 'drop'}, '10.0.0.2': {address: [10,9,8,7]}}},
  timeStepSeconds: 1,
});
assert.strictEqual(result.exitCode, 0, result.output);
assert.match(result.output, /DNS: 10\.0\.0\.2[\s\S]*Address: 10\.9\.8\.7/);
assert.strictEqual(result.requestCounts.dns, 4);
checked(result);

result = run('NSLOOKUP', 'host.test', {
  environment: staticEnv({NET_DNS1: '', NET_DNS2: '192.168.7.2'}),
  arp: {mac: [2,0,0,0,0,44]}, dns: {address: [10,9,8,7]},
});
assert.strictEqual(result.exitCode, 0, result.output);
assert.match(result.output, /DNS: 192\.168\.7\.2[\s\S]*Address: 10\.9\.8\.7/);
assert.strictEqual(result.requestCounts.dns, 1);
checked(result);

result = run('NSLOOKUP', 'host.test', {
  environment: staticEnv({NET_DNS2: ''}), arp: {mac: [2,0,0,0,0,44]},
  dns: {pointerLoop: true},
});
assert.strictEqual(result.exitCode, 3, result.output);
assert.match(result.output, /code=25/);
assert.strictEqual(result.requestCounts.dns, 1);
checked(result);

result = run('NSLOOKUP', 'host.test 192.168.7.9', {
  environment: staticEnv(), arp: {}, dns: {address: [9,8,7,6]},
});
assert.strictEqual(result.exitCode, 0, result.output);
assert.match(result.output, /DNS: 192\.168\.7\.9/);
checked(result);

for (const [label, dns, exit, code] of [
  ['nxdomain', {nxdomain: true}, 6, 27],
  ['malformed', {pointerLoop: true}, 3, 25],
  ['timeout', {mode: 'drop'}, 3, 14],
]) {
  result = run('NSLOOKUP', 'host.test 192.168.7.1', {
    environment: staticEnv(), arp: {}, dns, timeStepSeconds: 1,
  });
  assert.strictEqual(result.exitCode, exit, label);
  assert.match(result.output, new RegExp(`code=${code}`));
  if (label === 'timeout') assert.strictEqual(result.requestCounts.dns, 3);
  checked(result);
}
result = run('NSLOOKUP', 'host.test', {
  ...directDns, environment: staticEnv(),
  dns: {address: [192,168,7,44], staleBeforeReply: true,
    foreignPortBeforeReply: true, badChecksumBeforeReply: true},
});
assert.strictEqual(result.exitCode, 0, result.output);
checked(result);

// Every existing client accepts a hostname, while literal IPv4 bypasses DNS.
result = run('PING', '-n 1 host.test', {...directDns, icmp: {mode: 'echo'}});
assert.strictEqual(result.exitCode, 0, result.output); assert.strictEqual(result.requestCounts.dns, 1); checked(result);
result = run('UDPTEST', '-n 1 host.test 7777', {...directDns, udp: {mode: 'echo', port: 7777}});
assert.strictEqual(result.exitCode, 0, result.output); assert.strictEqual(result.requestCounts.udp, 1); checked(result);
const fixture = Buffer.from(Array.from({length: 2049}, (_, i) => (i * 37 + 11) & 255));
result = run('TFTP', 'host.test:6969 GET remote.bin -o local.bin -y', {
  ...directDns, tftp: {port: 6969, files: {'remote.bin': fixture}},
});
assert.strictEqual(result.exitCode, 0, result.output);
assert.deepStrictEqual(result.files['C:\\NET\\LOCAL.BIN'], fixture);
checked(result);
result = run('TFTP', 'host.test PUT LOCAL.BIN -o REMOTE.BIN', {
  environment: staticEnv({NET_DNS1: '10.0.0.1', NET_GW: '192.168.7.1'}),
  arp: {ip: [192,168,7,1], mac: [2,0,0,0,0,1]},
  dns: {address: [10,0,0,44]}, files: {'LOCAL.BIN': fixture},
  tftp: {ip: [10,0,0,44]},
});
assert.strictEqual(result.exitCode, 0, result.output);
assert.deepStrictEqual(result.tftpUploads['REMOTE.BIN'], fixture);
checked(result);
result = run('PING', '-n 1 192.168.7.44', {
  environment: staticEnv({NET_DNS1: '', NET_DNS2: ''}), arp: {}, icmp: {mode: 'echo'},
});
assert.strictEqual(result.exitCode, 0, result.output); assert.strictEqual(result.requestCounts.dns, 0); checked(result);

const fixedUnix = Date.parse('2025-01-01T11:59:59Z') / 1000;
function ntpScenario(environment, extra = {}) {
  return {environment, arp: {mac: [2,0,0,0,0,44]}, ntp: {unixSeconds: fixedUnix}, ...extra};
}
result = run('NTP', '192.168.7.44', ntpScenario(staticEnv({NET_TZ: '+5:45'})));
assert.strictEqual(result.exitCode, 0, result.output);
assert.deepStrictEqual(result.setTimeCalls, [{day: 1, month: 1, year: 2025, hour: 17, minute: 44, second: 59}]);
assert.match(result.output, /UTC\+05:45/); checked(result);
result = run('NTP', '', ntpScenario(staticEnv({NET_NTP: '192.168.7.44', NET_TZ: '-3:30'})));
assert.strictEqual(result.exitCode, 0, result.output);
assert.deepStrictEqual(result.setTimeCalls[0], {day: 1, month: 1, year: 2025, hour: 8, minute: 29, second: 59});
assert.match(result.output, /UTC-03:30/); checked(result);
result = run('NTP', 'ntp.test', ntpScenario(staticEnv(), {dns: {address: [192,168,7,44]}}));
assert.strictEqual(result.exitCode, 0, result.output);
assert.strictEqual(result.requestCounts.dns, 1); assert.strictEqual(result.requestCounts.ntp, 1); checked(result);

result = run('NTP', '192.168.7.44', ntpScenario(staticEnv({NET_TZ: '+5:45'}), {
  ntp: {unixSeconds: fixedUnix, staleBeforeReply: true, foreignPortBeforeReply: true,
    badChecksumBeforeReply: true},
}));
assert.strictEqual(result.exitCode, 0, result.output); assert.strictEqual(result.requestCounts.ntp, 1); checked(result);
for (const ntp of [
  {modeValue: 3}, {version: 2}, {leap: 3}, {stratum: 0}, {zeroTransmit: true}, {truncated: true},
]) {
  result = run('NTP', '192.168.7.44', ntpScenario(staticEnv(), {ntp}));
  assert.strictEqual(result.exitCode, 3, JSON.stringify(ntp));
  assert.strictEqual(result.setTimeCalls.length, 0);
  checked(result);
}
result = run('NTP', '192.168.7.44', ntpScenario(staticEnv(), {
  ntp: {mode: 'drop'}, timeStepSeconds: 1,
}));
assert.strictEqual(result.exitCode, 3);
assert.strictEqual(result.requestCounts.ntp, 3);
assert.strictEqual(result.setTimeCalls.length, 0);
checked(result);
result = run('NTP', '192.168.7.44', ntpScenario(staticEnv(), {setTimeFail: true}));
assert.strictEqual(result.exitCode, 5);
assert.strictEqual(result.setTimeCalls.length, 1);
assert.match(result.output, /code=29/); checked(result);
for (const tz of ['+5:10', '+5:60', '+14:15', '-12:15', '+5:3', '999999999']) {
  result = run('NTP', '', {environment: staticEnv({NET_TZ: tz}), cardPresent: false});
  assert.strictEqual(result.exitCode, 4, `accepted TZ=${tz}`);
  assert.strictEqual(result.transmittedFrames.length, 0);
  checked(result);
}

console.log(`Stage 10 actual-EXE: ${cases} DHCP/DNS/hostname/NTP/TZ/cleanup scenarios passed`);
