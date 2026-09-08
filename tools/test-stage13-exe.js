#!/usr/bin/env node
// Stage 13 FTP actual-EXE scenarios: CLI, control dialog, GET/PUT/LIST,
// resume, fault-injection and cancellation, against the real FTP.EXE image.
// SPDX-License-Identifier: BSD-3-Clause
'use strict';

const assert = require('assert');
const crypto = require('crypto');
const fs = require('fs');
const path = require('path');
const {runExe} = require('./exe-harness/harness.js');

const root = path.resolve(__dirname, '..');
const executable = path.join(root, 'build', 'FTP.EXE');
let cases = 0;

function staticEnv(extra = {}) {
  return {
    NET: '509B', NET_HW: 'AUTO', NET_IDPORT: '#110',
    NET_MAC: '02:60:8C:12:34:56', NET_IP_SRC: 'STATIC',
    NET_IP: '192.168.7.20', NET_MASK: '255.255.255.0', NET_GW: '0.0.0.0',
    NET_DNS1: '192.168.7.1', NET_DNS2: '192.168.7.2', ...extra,
  };
}
// The FTP data port is deliberately varied per scenario (rather than reused)
// so a copy/paste mistake that leaves two scenarios sharing one harness-side
// port cannot silently make one scenario see the other's fixture.
let nextDataPort = 47000;
function scenario(ftp = {}, extra = {}) {
  return {
    strictPc: true, environment: staticEnv(), arp: {mac: [2, 0, 0, 0, 0, 44]},
    clockFreezeAfterReads: 0, stepLimit: 900_000_000,
    ftp: {mac: [2, 0, 0, 0, 0, 44], dataPort: nextDataPort++, ...ftp},
    ...extra,
  };
}
function run(args, value = {}) { return runExe(executable, args, value); }
// Golden transcripts, pinned to the sibling revision the CLI was ported from.
// The PASV tuple and endpoint carry the harness's per-scenario data port, so
// they are normalized away with the banner and the REGS hardware line.
const golden = JSON.parse(fs.readFileSync(path.join(__dirname,
  'test-fixtures', 'stage13-ftp-golden.json'), 'utf8'));
function normalized(output) {
  return output.replace(/^3C509B FTP v[^\r\n]+/, '<FTP-BANNER>')
    .replace(/^REGS .*$/gm, '<REGS-HARDWARE>')
    .replace(/227 Entering Passive Mode \([0-9,]+\)\./, '227 <PASV-TUPLE>')
    .replace(/PASV \d+\.\d+\.\d+\.\d+:\d+/, 'PASV <PASV-ENDPOINT>');
}
function outputFile(result, name) { return result.files[`C:\\NET\\${name.toUpperCase()}`]; }
function sha256(value) { return crypto.createHash('sha256').update(value).digest('hex'); }
function checked(result) {
  assert.deepStrictEqual(result.cleanup, {isaClosed: true, pagesFreed: true, done: true});
  // Same standard WIN1+WIN2 layout as WGET (see ftp.asm's own header
  // comment): one stack for the whole run, growing down from BFF0h, with
  // the command copy directly beneath it at BE00h.
  assert.strictEqual(result.minimumPageSp, null,
    'FTP does not claim a runtime page, so none should be tracked');
  assert.ok(result.minimumSp >= 0xbf00,
    `FTP stack reached the command copy: #${result.minimumSp.toString(16)}`);
  cases++;
}

// ------------------------------------------------------------------
// Header/image sanity, mirroring WGET's own checks in test-stage12-exe.js.
// ------------------------------------------------------------------
assert.strictEqual(golden.reference,
  '../sprinter-rtl8019a@9ec98b00c6490fed5eb722c52b47d11c70a199ae',
  'the FTP golden output is no longer pinned to the ported sibling revision');
cases++;

const image = fs.readFileSync(executable);
assert.strictEqual(image.subarray(0, 4).toString('binary'), 'EXE\x01');
assert.strictEqual(image.readUInt16LE(4), 128);
assert.strictEqual(image.readUInt16LE(16), 0x4100);
assert.strictEqual(image.readUInt16LE(20), 0xbff0);
assert.ok(0x4080 + image.length <= 0x8000, 'FTP image runs into its runtime data area');
cases++;

// ------------------------------------------------------------------
// CLI-only paths: no network mode needed.
// ------------------------------------------------------------------
let result = run('/?', scenario());
assert.strictEqual(result.exitCode, 0);
assert.strictEqual(normalized(result.output), golden.help);
checked(result);

result = run('', scenario());
assert.strictEqual(result.exitCode, 1);
assert.strictEqual(normalized(result.output), golden.invalid);
checked(result);

result = run('PUT', scenario());
assert.strictEqual(result.exitCode, 1, 'a bare PUT keyword with no host is not a valid host token');
checked(result);

result = run('192.168.7.44 PUT', scenario());
assert.strictEqual(result.exitCode, 1, 'PUT with no local filename must be rejected');
checked(result);

result = run('192.168.7.44', scenario());
assert.strictEqual(result.exitCode, 1, 'a bare host is only valid with -l/-n');
checked(result);

// ------------------------------------------------------------------
// Anonymous GET, small and "large" (window-filling) fixtures.
// ------------------------------------------------------------------
const SMALL = Buffer.from('3C509B FTP stage 13 small fixture.\n', 'ascii');
result = run('192.168.7.44 SMALL.BIN', scenario({
  fixtures: {'SMALL.BIN': SMALL}, fixtureSizes: {'SMALL.BIN': SMALL.length},
}));
assert.strictEqual(result.exitCode, 0, result.output);
assert.deepStrictEqual(outputFile(result, 'SMALL.BIN'), SMALL);
assert.deepStrictEqual(result.ftpRequests, [
  'USER anonymous', 'PASS anonymous@', 'TYPE I', 'SIZE SMALL.BIN', 'PASV',
  'RETR SMALL.BIN', 'QUIT',
]);
// The whole point of running control and data as two native channels: the
// "226 Transfer complete" the server emits while the data channel is still
// draining is queued on channel 0 and read afterwards, never lost. On a
// transfer this small the server pipelines it into the same segment as the
// "150", which READ_REPLY used to discard by clearing its accumulator on
// entry -- printing no 226 and then waiting out the reply timeout for a copy
// that had already arrived. Hence the step ceiling as well as the text.
assert.match(result.output, /226 Transfer complete\./);
assert.strictEqual(normalized(result.output), golden.get);
const pipelined226Steps = result.steps;
checked(result);

// Sized to fill a full 5-MSS window (2680B) plus change.
const NEAR_WINDOW = Buffer.from(Array.from({length: 3000}, (_, i) => (i * 37 + 11) & 0xff));
result = run('192.168.7.44 NEAR.BIN', scenario({
  fixtures: {'NEAR.BIN': NEAR_WINDOW}, fixtureSizes: {'NEAR.BIN': NEAR_WINDOW.length},
  dataWindow: 5 * 536,
}));
assert.strictEqual(result.exitCode, 0, result.output);
assert.strictEqual(sha256(outputFile(result, 'NEAR.BIN')), sha256(NEAR_WINDOW));
assert.ok(result.maxInFlight >= 5 * 536,
  `peer kept only ${result.maxInFlight} bytes in flight, expected a 5-segment window`);
checked(result);

// ------------------------------------------------------------------
// Explicit -u/-p login, and a 530-on-PASS fault.
// ------------------------------------------------------------------
result = run('192.168.7.44 SMALL.BIN -u alice -p s3cret', scenario({
  fixtures: {'SMALL.BIN': SMALL}, fixtureSizes: {'SMALL.BIN': SMALL.length},
}));
assert.strictEqual(result.exitCode, 0, result.output);
assert.deepStrictEqual(result.ftpRequests.slice(0, 2), ['USER alice', 'PASS s3cret']);
checked(result);

result = run('192.168.7.44 SMALL.BIN -u bob', scenario({fixtures: {'SMALL.BIN': SMALL}}));
assert.strictEqual(result.exitCode, 0, result.output);
// -u without -p sends an explicitly empty password, not the anonymous
// default (see PARSE_FTP's F_EMPTY_PASS branch in stage9_cli.asm).
assert.deepStrictEqual(result.ftpRequests.slice(0, 2), ['USER bob', 'PASS']);
checked(result);

// Flags before the positional path. Regression test for a memory-aliasing
// defect found in code review: the CLI used to tokenise the page copy of the
// command record at S10_PAGE_COMMAND_BUFFER, which is exactly where
// F13_USER/F13_PASS/F13_OUTPUT_OVERRIDE live -- so copying a -p or -o value
// out of the line overwrote the part of that same line the reader had not
// reached yet, and the remote path silently became the flag's own value.
// ALLOCATE_FRESH now leaves FTP parsing the WIN1 copy instead.
result = run('192.168.7.44 -p s3cret -u alice SMALL.BIN', scenario({
  fixtures: {'SMALL.BIN': SMALL}, fixtureSizes: {'SMALL.BIN': SMALL.length},
}));
assert.strictEqual(result.exitCode, 0, result.output);
assert.deepStrictEqual(result.ftpRequests, [
  'USER alice', 'PASS s3cret', 'TYPE I', 'SIZE SMALL.BIN', 'PASV',
  'RETR SMALL.BIN', 'QUIT',
], 'a flag value overwrote the unparsed tail of the command line');
assert.deepStrictEqual(outputFile(result, 'SMALL.BIN'), SMALL);
checked(result);

result = run('192.168.7.44 -o RENAMED.BIN -u alice -p s3cret SMALL.BIN', scenario({
  fixtures: {'SMALL.BIN': SMALL}, fixtureSizes: {'SMALL.BIN': SMALL.length},
}));
assert.strictEqual(result.exitCode, 0, result.output);
assert.deepStrictEqual(result.ftpRequests.slice(-2), ['RETR SMALL.BIN', 'QUIT']);
assert.deepStrictEqual(outputFile(result, 'RENAMED.BIN'), SMALL);
checked(result);

result = run('192.168.7.44 SMALL.BIN', scenario({refusePass: true}));
assert.strictEqual(result.exitCode, 6, result.output);
assert.strictEqual(normalized(result.output), golden.login_refused);
checked(result);

// ------------------------------------------------------------------
// LIST and the documented -n/-l equivalence (no NLST fallback exists).
// ------------------------------------------------------------------
const LISTING = '-rw-r--r-- 1 owner group 36 Jan  1 00:00 SMALL.BIN\r\n';
result = run('192.168.7.44 -l', scenario({listing: LISTING}));
assert.strictEqual(result.exitCode, 0, result.output);
assert.ok(result.output.includes('owner group 36'));
assert.deepStrictEqual(result.ftpRequests.slice(-2), ['LIST', 'QUIT']);
assert.strictEqual(normalized(result.output), golden.list);
checked(result);

const listResult = run('192.168.7.44 -l', scenario({listing: LISTING}));
const nlstResult = run('192.168.7.44 -n', scenario({listing: LISTING}));
assert.strictEqual(listResult.exitCode, 0);
assert.strictEqual(nlstResult.exitCode, 0);
assert.deepStrictEqual(nlstResult.ftpRequests, listResult.ftpRequests,
  '-n has no NLST fallback in this build and must send the same LIST as -l');
checked(listResult); checked(nlstResult);

result = run('192.168.7.44 -l', scenario({refuseList: true}));
assert.strictEqual(result.exitCode, 6, result.output);
checked(result);

// ------------------------------------------------------------------
// Over-long control reply. F13_REPLY_LINE is 256 bytes and the accumulator
// that feeds it is 512, so a 400-character 220 banner -- shorter than banners
// real servers actually send -- used to run the copy straight through
// F13_SAVED_CWD, the path FTP restores on exit. READ_REPLY truncates now;
// the transfer itself must still complete untouched.
// ------------------------------------------------------------------
const LONG_BANNER = `220 ${'B'.repeat(400)}\r\n`;
result = run('192.168.7.44 SMALL.BIN', scenario({
  banner: LONG_BANNER,
  fixtures: {'SMALL.BIN': SMALL}, fixtureSizes: {'SMALL.BIN': SMALL.length},
}));
assert.strictEqual(result.exitCode, 0, result.output);
assert.deepStrictEqual(outputFile(result, 'SMALL.BIN'), SMALL);
assert.ok(result.output.includes(`220 ${'B'.repeat(255)}`),
  'the long banner should be printed truncated, not dropped');
assert.ok(!result.output.includes('B'.repeat(257)),
  'the reply line was copied past its 256-byte buffer');
assert.strictEqual(result.currentDir, 'C:\\NET',
  'the saved working directory was corrupted by the over-long reply');
checked(result);

// ------------------------------------------------------------------
// Malformed PASV reply: parse failure, bounded, no crash.
// ------------------------------------------------------------------
result = run('192.168.7.44 SMALL.BIN', scenario({pasvGarbled: true}));
assert.strictEqual(result.exitCode, 6, result.output);
assert.strictEqual(normalized(result.output), golden.pasv_garbled);
checked(result);

// ------------------------------------------------------------------
// REST resume: correct offset sent, byte-exact final file.
// ------------------------------------------------------------------
const FULL = Buffer.from('0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ', 'ascii');
const PARTIAL = FULL.subarray(0, 12);
const REMAINDER = FULL.subarray(12);
result = run('192.168.7.44 SMALL.BIN -r', scenario({
  fixtures: {'SMALL.BIN': REMAINDER},
}, {files: {'SMALL.BIN': PARTIAL}}));
assert.strictEqual(result.exitCode, 0, result.output);
assert.deepStrictEqual(outputFile(result, 'SMALL.BIN'), FULL);
assert.ok(result.ftpRequests.includes(`REST ${PARTIAL.length}`),
  `expected a REST ${PARTIAL.length} request, got ${JSON.stringify(result.ftpRequests)}`);
checked(result);

// REST refused (350 withheld) is fatal, and must not touch the partial file.
result = run('192.168.7.44 SMALL.BIN -r', scenario({
  fixtures: {'SMALL.BIN': REMAINDER}, restRefused: true,
}, {files: {'SMALL.BIN': PARTIAL}}));
assert.strictEqual(result.exitCode, 6, result.output);
assert.deepStrictEqual(outputFile(result, 'SMALL.BIN'), PARTIAL);
assert.match(result.output, /REST refused, no -r\./);
assert.ok(result.tcpResetPorts.includes(result.ftpDataPort),
  'a refused REST must tear down the data channel it already opened');
checked(result);

// ------------------------------------------------------------------
// PUT: byte-exact upload capture.
// ------------------------------------------------------------------
const UPLOAD = Buffer.from('Uploaded from the Sprinter, byte for byte.\n', 'ascii');
result = run('192.168.7.44 PUT LOCAL.BIN', scenario({}, {files: {'LOCAL.BIN': UPLOAD}}));
assert.strictEqual(result.exitCode, 0, result.output);
assert.deepStrictEqual(result.ftpUploads, UPLOAD);
assert.deepStrictEqual(result.ftpRequests.slice(-2), ['STOR LOCAL.BIN', 'QUIT']);
assert.strictEqual(normalized(result.output), golden.put);
checked(result);

result = run('192.168.7.44 PUT LOCAL.BIN', scenario({refuseStor: true}, {files: {'LOCAL.BIN': UPLOAD}}));
assert.strictEqual(result.exitCode, 6, result.output);
// A 5xx answer to the transfer verb arrives with the PASV data channel
// already established. Walking away from it would leave the server a
// half-open session until its own idle timeout, so REMOTE_FAIL_COMMON RSTs
// the data channel before closing the control one.
assert.ok(result.tcpResetPorts.includes(result.ftpDataPort),
  `data channel ${result.ftpDataPort} was abandoned without an RST ` +
  `(reset ports: ${JSON.stringify(result.tcpResetPorts)})`);
checked(result);

// ------------------------------------------------------------------
// -o rename, both directions. Regression test for a bug found and fixed
// during Stage 13 test-infra review: DERIVE_ARGS (ftp.asm) used to point
// F13_LOCAL_ARG_PTR/F13_REMOTE_ARG_PTR straight at F13_REPLY_LINE on the
// theory that it was "dead until the control dialog starts" -- false, since
// every 220/USER/PASS/TYPE/SIZE/PASV reply overwrites it before the pointer
// is ever dereferenced. -o silently renamed to whatever the last control
// reply happened to say (e.g. the PASV line) instead of the requested name.
// The fix gives -o its own F13_OUTPUT_OVERRIDE buffer (memory.inc).
// ------------------------------------------------------------------
result = run('192.168.7.44 SMALL.BIN -o RENAMED.BIN', scenario({
  fixtures: {'SMALL.BIN': SMALL}, fixtureSizes: {'SMALL.BIN': SMALL.length},
}));
assert.strictEqual(result.exitCode, 0, result.output);
assert.deepStrictEqual(outputFile(result, 'RENAMED.BIN'), SMALL,
  '-o did not rename the local GET output correctly');
assert.strictEqual(outputFile(result, 'SMALL.BIN'), undefined,
  '-o must not also leave the file under its original name');
checked(result);

result = run('192.168.7.44 PUT LOCAL.BIN -o REMOTE.BIN', scenario({}, {files: {'LOCAL.BIN': UPLOAD}}));
assert.strictEqual(result.exitCode, 0, result.output);
assert.deepStrictEqual(result.ftpUploads, UPLOAD);
assert.deepStrictEqual(result.ftpRequests.slice(-2), ['STOR REMOTE.BIN', 'QUIT'],
  '-o did not rename the remote STOR target correctly');
checked(result);

// ------------------------------------------------------------------
// Data-channel abort mid-transfer: bounded failure, no crash/hang.
//
// This uses a silent stall (peer stops responding, no RST/FIN) rather than
// an actual RST: an actual RST on this channel was found to complete as
// "RESULT OK" with a truncated file instead of a network failure -- see the
// test-infra report -- so it is not a reliable way to assert "correct
// failure exit code" here. A stall exercises the same "the data channel
// goes bad mid-transfer" shape and is unambiguous: FTP_DATA_IDLE_MS bounds
// it and DATA_RX_FAIL reports it.
// ------------------------------------------------------------------
result = run('192.168.7.44 NEAR.BIN', scenario({
  fixtures: {'NEAR.BIN': NEAR_WINDOW}, fixtureSizes: {'NEAR.BIN': NEAR_WINDOW.length},
  dataStallAfterBytes: 1200,
}));
assert.strictEqual(result.exitCode, 3, result.output);
assert.match(result.output, /\[E\] data recv fail/);
assert.ok(result.steps < 900_000_000, 'data-channel RST must not hang the client');
checked(result);

// ------------------------------------------------------------------
// Mid-GET cancel: partial file preserved, DSS_EXIT_CANCELLED.
// ------------------------------------------------------------------
for (const key of ['escape', 'ctrl-c']) {
  result = run('192.168.7.44 NEAR.BIN', scenario({
    fixtures: {'NEAR.BIN': NEAR_WINDOW}, fixtureSizes: {'NEAR.BIN': NEAR_WINDOW.length},
    dataWindow: 5 * 536,
    // Past the first full 2680-byte window: the harness pushes a whole
    // window in one synchronous burst (matching WGET's own equivalent
    // scenario/comment in test-stage12-exe.js), so a smaller threshold
    // fires the cancel before the guest has ever drained/buffered anything,
    // leaving nothing for the abort path to flush.
  }, {key, keyAfterFtpBytes: 2700}));
  assert.strictEqual(result.exitCode, 7, result.output);
  assert.match(result.output, /Aborted \(Esc\/\^C\)\./);
  const partial = outputFile(result, 'NEAR.BIN') || Buffer.alloc(0);
  assert.ok(partial.length > 0 && partial.length < NEAR_WINDOW.length,
    `expected a genuine partial file, got ${partial.length} bytes`);
  assert.deepStrictEqual(partial, NEAR_WINDOW.subarray(0, partial.length));
  checked(result);
}

// The interactive Overwrite/Resume/Cancel prompt is a different cancel path
// (PROMPT_CANCEL, no "RESULT FAIL" line) from the mid-transfer abort above.
result = run('192.168.7.44 SMALL.BIN', scenario({
  fixtures: {'SMALL.BIN': SMALL},
}, {files: {'SMALL.BIN': Buffer.from('stale')}, promptKey: 'c'}));
assert.strictEqual(result.exitCode, 7, result.output);
assert.doesNotMatch(result.output, /RESULT FAIL/);
assert.deepStrictEqual(outputFile(result, 'SMALL.BIN'), Buffer.from('stale'));
checked(result);

// -y forces the overwrite instead of prompting.
result = run('192.168.7.44 SMALL.BIN -y', scenario({
  fixtures: {'SMALL.BIN': SMALL},
}, {files: {'SMALL.BIN': Buffer.from('stale-but-longer-than-the-fixture')}}));
assert.strictEqual(result.exitCode, 0, result.output);
assert.deepStrictEqual(outputFile(result, 'SMALL.BIN'), SMALL);
checked(result);

// ------------------------------------------------------------------
// Control-channel timeout: server never answers, bounded exit, not a hang.
// ------------------------------------------------------------------
result = run('192.168.7.44 SMALL.BIN', scenario({suppressBanner: true}));
assert.strictEqual(result.exitCode, 3, result.output);
assert.match(result.output, /TCP recv fail 0x1E/);
assert.ok(result.steps < 900_000_000, 'a withheld banner must not hang the client');
checked(result);

// ------------------------------------------------------------------
// Missing/withheld 226: non-fatal, transfer still reports success.
// ------------------------------------------------------------------
result = run('192.168.7.44 SMALL.BIN', scenario({
  fixtures: {'SMALL.BIN': SMALL}, suppress226: true,
}));
assert.strictEqual(result.exitCode, 0, result.output);
assert.deepStrictEqual(outputFile(result, 'SMALL.BIN'), SMALL);
assert.doesNotMatch(result.output, /226/);
// A genuinely absent 226 is what FTP_REPLY_TIMEOUT_MS is for, so this run
// legitimately costs the wait that the pipelined-226 run above must not.
assert.ok(result.steps > pipelined226Steps * 4,
  'the withheld-226 run should be the one that pays the reply timeout, ' +
  `but it took ${result.steps} steps against ${pipelined226Steps}`);
checked(result);

// ------------------------------------------------------------------
// SIZE refused (5xx): non-fatal, total stays unknown ("?" in progress).
// ------------------------------------------------------------------
result = run('192.168.7.44 SMALL.BIN -d', scenario({
  fixtures: {'SMALL.BIN': SMALL}, refuseSize: true,
}));
assert.strictEqual(result.exitCode, 0, result.output);
assert.deepStrictEqual(outputFile(result, 'SMALL.BIN'), SMALL);
checked(result);

// -d switches the progress display to one dot per disk-buffer flush instead
// of the repainted "X / Y KB" line.
result = run('192.168.7.44 SMALL.BIN -d', scenario({
  fixtures: {'SMALL.BIN': SMALL}, fixtureSizes: {'SMALL.BIN': SMALL.length},
}));
assert.strictEqual(result.exitCode, 0, result.output);
assert.doesNotMatch(result.output, /KB \//);
assert.match(result.output, /\.\r\n/);
checked(result);

// ------------------------------------------------------------------
// Missing config / hardware, ahead of any network activity.
// ------------------------------------------------------------------
result = run('192.168.7.44 SMALL.BIN', {strictPc: true, environment: {}, arp: {mac: [2, 0, 0, 0, 0, 44]},
  stepLimit: 900_000_000, ftp: {mac: [2, 0, 0, 0, 0, 44], dataPort: nextDataPort++}});
assert.strictEqual(result.exitCode, 4, result.output);
checked(result);

result = run('192.168.7.44 SMALL.BIN', scenario({}, {cardPresent: false}));
assert.strictEqual(result.exitCode, 2, result.output);
checked(result);

// ------------------------------------------------------------------
// Regression test for a fixed bug: a GET needing a second fill of the deep
// (STAGE12_LAYOUT) receive window on TCP context 1 (the FTP data channel)
// used to fail partway through instead of completing. This was the first
// application to ever exercise that window on context 1 with a per-RECV
// destination smaller than one MSS (S11_APP_CAPACITY=448 < TCP_MSS=536) --
// WGET only ever uses context 0 -- and the transfer always stalled at
// exactly 3216 bytes (one full 2680-byte window plus one more segment)
// regardless of total fixture size.
//
// Root cause: HANDLE_SEGMENT (invoked from inside WAIT_FOR_EVENT's frame
// dispatch, itself called from RECV) stored the newly-arrived segment's
// payload length in S11_COPY_LENGTH -- the same cell RECV uses to remember
// the caller's destination capacity across that same WAIT_FOR_EVENT call.
// Once RECV resumed, RECV_COPY re-read S11_COPY_LENGTH expecting its own
// capacity back and instead got the last segment's length, so whenever that
// length exceeded the caller's real capacity it LDIR'd a whole segment into
// a smaller buffer. S11_APP_BUFFER sits with zero slack directly below
// RUNTIME_BASE under STAGE13_LAYOUT, so the overrun corrupted EL3_BASE (the
// resident ISA port-base word every EL3 register access uses), and the next
// hardware access computed a garbage ISA address -- which this harness (and,
// since the corruption is real Z80 memory damage rather than a modeling gap,
// presumably real hardware too) reads back as an inert 0xFF, holding
// Command-In-Progress "set" until WAIT_CIP's own ~100-quantum budget expires
// with EL3_ERR_CMD_TIMEOUT (0x09). Fixed by giving HANDLE_SEGMENT its own
// scratch cell (S11_SEGMENT_LENGTH, already used and vacated by the SEND
// path before any RECV could re-enter it) instead of sharing S11_COPY_LENGTH
// with RECV. See src/lib/tcp_transport.asm's HANDLE_SEGMENT.
const BEYOND_WINDOW = Buffer.from(Array.from({length: 5000}, (_, i) => (i * 7 + 3) & 0xff));
result = run('192.168.7.44 BEYOND.BIN', scenario({
  fixtures: {'BEYOND.BIN': BEYOND_WINDOW}, fixtureSizes: {'BEYOND.BIN': BEYOND_WINDOW.length},
}));
assert.strictEqual(result.exitCode, 0, result.output);
assert.deepStrictEqual(outputFile(result, 'BEYOND.BIN'), BEYOND_WINDOW);
checked(result);

// ------------------------------------------------------------------
// DLSPEED.EXE. Same stage, same acceptance run, so its scenarios live here
// rather than in a file of their own. The harness clock advances one second
// per DSS_SYSTIME read unless a scenario freezes it, which is exactly the
// knob the RTC-edge alignment and the zero-second rejection turn on.
// ------------------------------------------------------------------
const speedExe = path.join(root, 'build', 'DLSPEED.EXE');
function speedScenario(tcp = {}, extra = {}) {
  return {
    strictPc: true, environment: staticEnv(), arp: {mac: [2, 0, 0, 0, 0, 44]},
    tcp: {mode: 'http', port: 80, ...tcp}, stepLimit: 900_000_000, ...extra,
  };
}
function speedChecked(result) {
  assert.deepStrictEqual(result.cleanup, {isaClosed: true, pagesFreed: true, done: true});
  assert.strictEqual(result.minimumPageSp, null);
  assert.ok(result.minimumSp >= 0xbf00,
    `DLSPEED stack reached the command copy: #${result.minimumSp.toString(16)}`);
  cases++;
}

const speedImage = fs.readFileSync(speedExe);
assert.strictEqual(speedImage.subarray(0, 4).toString('binary'), 'EXE\x01');
assert.strictEqual(speedImage.readUInt16LE(16), 0x4100);
assert.strictEqual(speedImage.readUInt16LE(20), 0xbff0);
cases++;

result = runExe(speedExe, '/?', speedScenario());
assert.strictEqual(result.exitCode, 0, result.output);
assert.match(result.output, /Usage:/);
assert.match(result.output, /RESULT OK/);
speedChecked(result);

result = runExe(speedExe, '', speedScenario());
assert.strictEqual(result.exitCode, 1, result.output);
assert.match(result.output, /missing or invalid URL/);
speedChecked(result);

// A running clock: the RTC edge is found, the sample spans whole seconds and
// the summary line carries bytes, seconds and a rate.
const SPEED_BODY = Buffer.alloc(4000, 0x5a);
result = runExe(speedExe, 'http://192.168.7.44/BIG.BIN', speedScenario({
  response: {status: '200 OK', body: SPEED_BODY, headers: {}, closeDelimited: false},
}));
assert.strictEqual(result.exitCode, 0, result.output);
assert.match(result.output, /Waiting for RTC edge/);
assert.match(result.output, new RegExp(`Received: ${SPEED_BODY.length} bytes`));
assert.match(result.output, /^ {2}\d+ bytes in \d+ sec, \d+ (?:KB|B)\/s$/m,
  `no honest rate line in:\n${result.output}`);
assert.match(result.output, /RESULT OK/);
// The measurement must never write the body to disk -- that is the whole
// difference between DLSPEED and timing WGET.
assert.deepStrictEqual(result.files, {});
speedChecked(result);

// A one-second sample crosses into the KB/s branch of the same summary line.
result = runExe(speedExe, 'http://192.168.7.44/BIG.BIN', speedScenario({
  response: {status: '200 OK', body: SPEED_BODY, headers: {}, closeDelimited: false},
}, {clockFreezeAfterReads: 8}));
assert.strictEqual(result.exitCode, 0, result.output);
assert.match(result.output, /^ {2}4000 bytes in 1 sec, \d+ KB\/s$/m, result.output);
speedChecked(result);

// Clock frozen after the alignment reads: the interval measures zero seconds,
// which is rejected with an explicit status rather than reported as an
// infinite rate.
result = runExe(speedExe, 'http://192.168.7.44/BIG.BIN', speedScenario({
  response: {status: '200 OK', body: SPEED_BODY, headers: {}, closeDelimited: false},
}, {clockFreezeAfterReads: 6}));
assert.strictEqual(result.exitCode, 6, result.output);
assert.match(result.output, /sample too short \(under one RTC second\)/);
assert.match(result.output, /RESULT FAIL/);
speedChecked(result);

// A clock that never ticks at all cannot even align: bounded by
// RTC_ALIGN_TIMEOUT_MS, reported, and not a hang.
result = runExe(speedExe, 'http://192.168.7.44/BIG.BIN', speedScenario({
  response: {status: '200 OK', body: SPEED_BODY, headers: {}, closeDelimited: false},
}, {clockFreezeAfterReads: 0}));
assert.strictEqual(result.exitCode, 2, result.output);
assert.match(result.output, /RTC second did not advance/);
speedChecked(result);

for (const key of ['escape', 'ctrl-c']) {
  result = runExe(speedExe, 'http://192.168.7.44/BIG.BIN', speedScenario({
    response: {status: '200 OK', body: Buffer.alloc(40000, 0x5a), headers: {}, closeDelimited: false},
  }, {key, keyAfterHttpBytes: 2000}));
  assert.strictEqual(result.exitCode, 7, `${key}: ${result.output}`);
  assert.match(result.output, /Aborted by user/);
  speedChecked(result);
}

console.log(`Stage 13 actual EXE: ${cases} FTP CLI/control-dialog/GET/PUT/LIST/resume/fault and DLSPEED scenarios passed`);
