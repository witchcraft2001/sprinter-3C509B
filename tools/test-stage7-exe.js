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
let result;

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
function canonicalConfig(values = {}) {
  const v = {
    HW: 'AUTO', IDPORT: '#110', MAC: '', IP: 'DHCP', NETMASK: '', GATEWAY: '',
    DNS1: '', DNS2: '', NTP: 'pool.ntp.org', TZ: '+3', ...values,
  };
  return [
    'NET=509B', `HW=${v.HW}`, `IDPORT=${v.IDPORT}`, `MAC=${v.MAC}`, `IP=${v.IP}`,
    `NETMASK=${v.NETMASK}`, `GATEWAY=${v.GATEWAY}`, `DNS1=${v.DNS1}`,
    `DNS2=${v.DNS2}`, `NTP=${v.NTP}`, `TZ=${v.TZ}`, '',
  ].join('\r\n');
}
function assertCanonicalWrite(result, expected) {
  assert.strictEqual(result.files[cfgPath].toString('ascii'), expected);
  assert.ok(!result.files[cfgPath].toString('ascii').replace(/\r\n/g, '').includes('\n'));
  assert.ok(!Object.keys(result.files).some((name) => name !== cfgPath));
}
const sampleEffective = fs.readFileSync(path.join(root, 'config', 'NETSMPL.CFG'), 'utf8')
  .split(/\r?\n/).filter((line) => line && !line.startsWith('#')).join('\r\n') + '\r\n';
assert.strictEqual(canonicalConfig(), sampleEffective, 'editor defaults must match NETSMPL.CFG');

for (const name of ['NETCFG', 'IFUP', 'ARP']) {
  const image = fs.readFileSync(exe(name));
  assert.strictEqual(image.subarray(0, 4).toString('binary'), 'EXE\x01');
  assert.strictEqual(image.readUInt16LE(4), 128);
  assert.strictEqual(image.readUInt16LE(16), 0x8100);
  assert.ok(0x8080 + image.length < 0xc000);
  cases++;
}

// Built-in help follows the multi-line mode table and documents the editor.
result = run('NETCFG', '/?', {appDir});
assert.strictEqual(result.exitCode, 0, result.output);
assert.match(result.output, /Usage:[\s\S]*NETCFG -W\s+interactively create or edit NET\.CFG/i);
assert.match(result.output, /probe of slots 0\/1 at the selected IDPORT/i);
assert.match(result.output, /EEPROM remains read-only/i);
assert.match(result.output, /run NETCFG -i and IFUP to apply/i);
cleanup(result);

// NETCFG -W edits the actual EXE-side file without publishing NET_*.
const untouchedWriteEnv = {NET: 'OLD', KEEP: 'yes'};
result = run('NETCFG', '-w', {
  appDir, files: {}, environment: untouchedWriteEnv, base: 0x320,
  echoKeys: '\r'.repeat(7), traceDss: true,
});
assert.strictEqual(result.exitCode, 0, result.output);
assertCanonicalWrite(result, canonicalConfig({HW: '1/#320'}));
assert.deepStrictEqual(result.probedSlots, [0, 1]);
assert.deepStrictEqual(result.probedIdPorts, [0x110]);
assert.deepStrictEqual(untouchedWriteEnv, {NET: 'OLD', KEEP: 'yes'});
assert.deepStrictEqual(result.dssEvents.filter((event) => event.startsWith('CREATE ')),
  [`CREATE ${cfgPath}`]);
cleanup(result);

// A declined probe is explicit and non-fatal; the static branch asks all four
// address fields, and '-' clears an optional value.
const staticWriteKeys = '\r' + 'n' + '\r' + '\r' +
  '192.168.7.2\r' + '255.255.255.0\r' + '192.168.7.1\r' +
  '1.1.1.1\r' + '-\r' + '\r' + '-4\r';
result = run('NETCFG', '/W', {appDir, files: {}, echoKeys: staticWriteKeys});
assert.strictEqual(result.exitCode, 0, result.output);
assert.match(result.output, /\[W0\] PROBE SKIPPED code=23/);
assert.deepStrictEqual(result.probedSlots, []); assert.deepStrictEqual(result.probedIdPorts, []);
assertCanonicalWrite(result, canonicalConfig({
  IP: '192.168.7.2', NETMASK: '255.255.255.0', GATEWAY: '192.168.7.1',
  DNS1: '1.1.1.1', DNS2: '', TZ: '-4',
}));
cleanup(result);

// A missing adapter also continues with HW=AUTO after exactly slots 0 and 1.
result = run('NETCFG', '-W', {appDir, files: {}, cardPresent: false, echoKeys: '\r'.repeat(7)});
assert.strictEqual(result.exitCode, 0, result.output);
assert.match(result.output, /\[W1\] PROBE FAIL code=3/);
assert.deepStrictEqual(result.probedSlots, [0, 1]);
assert.deepStrictEqual(result.probedIdPorts, [0x110]);
assertCanonicalWrite(result, canonicalConfig()); cleanup(result);

// IDPORT is validated before the probe. Backspace edits instead of truncating,
// and no other ID port in #100..#1F0 is touched.
result = run('NETCFG', '-W', {
  appDir, files: {}, idPort: 0x120, echoKeys: '#120x\b\r' + '\r'.repeat(6),
});
assert.strictEqual(result.exitCode, 0, result.output);
assert.deepStrictEqual(result.probedIdPorts, [0x120]);
assertCanonicalWrite(result, canonicalConfig({IDPORT: '#120', HW: '1/#300'}));
cleanup(result);

// An overflowing replacement is rejected wholesale, then the field is
// re-entered. An invalid ID port is likewise re-prompted through the shared
// parser rather than being accepted or silently rounded.
result = run('NETCFG', '-W', {
  appDir, files: {}, idPort: 0x120,
  echoKeys: '#12345678\r#111\r#120\r' + 'n' + '\r'.repeat(5),
});
assert.strictEqual(result.exitCode, 0, result.output);
assert.match(result.output, /\[E2\] INPUT TOO LONG/);
assert.match(result.output, /\[E1\] INVALID VALUE/);
assert.deepStrictEqual(result.probedIdPorts, []);
assertCanonicalWrite(result, canonicalConfig({IDPORT: '#120'})); cleanup(result);

// Every parsed field rejects a bad replacement in place; final validation is
// still authoritative before CREATE_OVERWRITE.
const invalidFieldKeys = '\r' + 'n' +
  '2/#300\r\r' + '01:00:00:00:00:01\r\r' +
  '999.1.1.1\r192.168.9.2\r' +
  '255.999.0.0\r255.255.255.0\r' +
  '999.1.1.1\r-\r' + 'bad\r-\r' + '300.1.1.1\r-\r' +
  '\r' + '+14:15\r+5\r';
result = run('NETCFG', '-W', {appDir, files: {}, echoKeys: invalidFieldKeys});
assert.strictEqual(result.exitCode, 0, result.output);
assert.ok((result.output.match(/\[E1\] INVALID VALUE/g) || []).length >= 7);
assertCanonicalWrite(result, canonicalConfig({
  IP: '192.168.9.2', NETMASK: '255.255.255.0', TZ: '+5',
}));
cleanup(result);

// A valid existing file is loaded as defaults and never probes hardware.
// Switching it to DHCP clears all static fields and skips their prompts.
const oldStatic = canonicalConfig({
  HW: '0/#300', MAC: '02:11:22:33:44:55', IP: '10.0.0.2',
  NETMASK: '255.255.255.0', GATEWAY: '10.0.0.1', DNS1: '1.1.1.1', DNS2: '8.8.8.8', TZ: '+4',
});
result = run('NETCFG', '-W', cfgScenario(oldStatic, {
  cardPresent: false, echoKeys: '\r\r\rDHCP\r-\r\r', traceDss: true,
}));
assert.strictEqual(result.exitCode, 0, result.output);
assert.deepStrictEqual(result.probedSlots, []); assert.deepStrictEqual(result.probedIdPorts, []);
assertCanonicalWrite(result, canonicalConfig({HW: '0/#300', MAC: '02:11:22:33:44:55', NTP: '', TZ: '+4'}));
cleanup(result);

// Esc, malformed existing content and unreadable existing content all leave
// the old bytes untouched and never reach CREATE_OVERWRITE.
for (const scenario of [
  cfgScenario(oldStatic, {echoKeys: '\x1b', traceDss: true}),
  cfgScenario(oldStatic, {echoKeys: '#111\r\x1b', traceDss: true}),
  cfgScenario('BROKEN\r\n', {echoKeys: '', traceDss: true}),
  cfgScenario('X'.repeat(2048), {echoKeys: '', traceDss: true}),
  cfgScenario(oldStatic, {echoKeys: '', fileOpenError: 8, traceDss: true}),
  cfgScenario(oldStatic, {echoKeys: '', fileReadFailAt: 1, traceDss: true}),
  cfgScenario(oldStatic, {echoKeys: '', fileCloseFailAt: 1, traceDss: true}),
  cfgScenario(oldStatic, {echoKeys: '', fileReadFailAt: 1, fileCloseFailAt: 1, traceDss: true}),
]) {
  const before = Buffer.from(scenario.files[cfgPath]);
  result = run('NETCFG', '-W', scenario);
  assert.ok([4, 7].includes(result.exitCode), result.output);
  assert.deepStrictEqual(result.files[cfgPath], before);
  assert.ok(!result.dssEvents.some((event) => event.startsWith('CREATE ')));
  assert.deepStrictEqual(result.probedSlots, []); cleanup(result);
}

// Invalid new input remains interactive; Esc cancels after the diagnostic and
// no empty/truncated NET.CFG appears.
result = run('NETCFG', '-W', {appDir, files: {}, echoKeys: '#111\r\x1b', traceDss: true});
assert.strictEqual(result.exitCode, 7); assert.match(result.output, /\[E1\] INVALID VALUE/);
assert.strictEqual(result.files[cfgPath], undefined);
assert.ok(!result.dssEvents.some((event) => event.startsWith('CREATE '))); cleanup(result);

// Create/write/close failures return the local-I/O class and still release all
// handles and the page. Validation has already completed before each attempt.
for (const fault of [
  {fileCreateError: 10}, {fileWriteFailAt: 1}, {fileCloseFailAt: 1},
]) {
  result = run('NETCFG', '-W', {
    appDir, files: {}, echoKeys: '\r' + 'n' + '\r'.repeat(5), ...fault,
  });
  assert.strictEqual(result.exitCode, 5, result.output);
  cleanup(result);
}

// NETCFG modes, parser boundaries and persistent environment.
const environment = {NET_IP: 'stale', NET_LEASE_SEC: 'stale'};
result = run('NETCFG', '-i -v', cfgScenario(dhcpConfig, {environment}));
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
for (const args of ['-i -c', '-d -v', '-w -i', '/W -c', '-W -d', '-w -v', '-x']) {
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
