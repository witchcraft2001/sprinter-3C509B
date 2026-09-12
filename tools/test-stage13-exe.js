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

// The same transfer with the clock left running: the summary line reports a
// rate, the way WGET and DLSPEED already do. Every other scenario here freezes
// the clock on its first read, so the sample is zero seconds long and the rate
// is honestly left off -- which is what the golden transcripts pin.
result = run('192.168.7.44 RATE.BIN', scenario({
  fixtures: {'RATE.BIN': NEAR_WINDOW}, fixtureSizes: {'RATE.BIN': NEAR_WINDOW.length},
}, {clockFreezeAfterReads: 1}));
assert.strictEqual(result.exitCode, 0, result.output);
const summary = /^ {2}(\d+) bytes in (\d+) sec, (\d+) KB\/s$/m.exec(result.output);
assert.ok(summary, `no rate on the summary line in:\n${result.output}`);
{
  const [, bytes, seconds, rate] = summary.map(Number);
  assert.strictEqual(bytes, NEAR_WINDOW.length);
  assert.ok(seconds > 0, 'the running clock must produce a non-zero sample');
  assert.ok(rate > 0, `a 3000-byte second should not round to zero: ${summary[0]}`);
  // Whole KB per whole second, truncated the same way the Z80 divide does.
  assert.strictEqual(rate, Math.floor(Math.floor(bytes / 1024) / seconds));
}
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

// Repeating -r after the local file is already complete is a successful
// no-op. In particular, do not open an empty data transfer at REST == SIZE:
// some otherwise usable FTP servers leave that stream open indefinitely.
result = run('192.168.7.44 SMALL.BIN -r', scenario({
  fixtures: {'SMALL.BIN': FULL}, fixtureSizes: {'SMALL.BIN': FULL.length},
}, {files: {'SMALL.BIN': FULL}}));
assert.strictEqual(result.exitCode, 0, result.output);
assert.deepStrictEqual(outputFile(result, 'SMALL.BIN'), FULL);
assert.deepStrictEqual(result.ftpRequests.slice(-2), ['PASV', 'QUIT']);
assert.ok(!result.ftpRequests.some((request) => /^(?:REST|RETR)\b/.test(request)),
  `complete resume unexpectedly opened a transfer: ${JSON.stringify(result.ftpRequests)}`);
assert.match(result.output, /Done\. 0 bytes recv\./);
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
// STOR send window. TCPX.SEND used to keep exactly one segment outstanding and
// wait for its acknowledgement before touching the next, which is the one
// pattern RFC 1122's "acknowledge at least every second full-sized segment"
// rule cannot rescue: the peer holds its delayed-ACK timer on every segment.
// On real hardware that showed as 12 KB/s uploading against 31 KB/s
// downloading over the same connection, while the harness put the upload's
// cost per byte within 7% of the download's -- the missing time was idle.
// Byte-exactness alone would not catch a silent fall back to one segment, so
// the depth is asserted directly: maxClientInFlight is the peak the model saw
// the client put on the wire before reading an acknowledgement for it.
// ------------------------------------------------------------------
const BULK = Buffer.from(Array.from({length: 9 * 536 + 71}, (_, i) => (i * 7 + (i >> 8)) & 0xff));
result = run('192.168.7.44 PUT BULK.BIN', scenario({}, {files: {'BULK.BIN': BULK}}));
assert.strictEqual(result.exitCode, 0, result.output);
assert.deepStrictEqual(result.ftpUploads, BULK, 'bulk upload is not byte-exact');
assert.strictEqual(result.maxClientInFlight, 2 * 536,
  `STOR kept only ${result.maxClientInFlight} bytes on the wire, expected a two-segment window`);
checked(result);

// A peer window too small for two whole segments must fall back to one, and
// the upload must still arrive byte for byte.
result = run('192.168.7.44 PUT BULK.BIN', scenario({dataWindow: 700}, {files: {'BULK.BIN': BULK}}));
assert.strictEqual(result.exitCode, 0, result.output);
assert.deepStrictEqual(result.ftpUploads, BULK, 'window-limited upload is not byte-exact');
assert.strictEqual(result.maxClientInFlight, 536,
  `a ${700}-byte window must not carry two segments (saw ${result.maxClientInFlight})`);
checked(result);

// Under two full segments of payload there is no pair to form.
const SHORT = BULK.subarray(0, 900);
result = run('192.168.7.44 PUT SHORT.BIN', scenario({}, {files: {'SHORT.BIN': SHORT}}));
assert.strictEqual(result.exitCode, 0, result.output);
assert.deepStrictEqual(result.ftpUploads, SHORT);
assert.strictEqual(result.maxClientInFlight, 536,
  `a ${SHORT.length}-byte upload has no second whole segment to pair (saw ${result.maxClientInFlight})`);
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
// DLDIRECT.EXE. Same stage, same acceptance run, so its scenarios live here
// rather than in a file of their own. The harness clock advances one second
// per DSS_SYSTIME read unless a scenario freezes it, which is exactly the
// knob the RTC-edge alignment and the zero-second rejection turn on.
// ------------------------------------------------------------------
const speedExe = path.join(root, 'build', 'DLDIRECT.EXE');
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
    `DLDIRECT stack reached the command copy: #${result.minimumSp.toString(16)}`);
  cases++;
}

const speedImage = fs.readFileSync(speedExe);
assert.strictEqual(speedImage.subarray(0, 4).toString('binary'), 'EXE\x01');
assert.strictEqual(speedImage.readUInt16LE(16), 0x4100);
assert.strictEqual(speedImage.readUInt16LE(20), 0xbff0);
cases++;

// The public-path client has the standard WIN2 EXE layout and performs its
// APPINFO-near-EXE then cwd loader fallback before any network call. Full DLL
// call semantics are covered by Stage 14 relocated-image vectors; these cases
// verify CLI and loader cleanup in the actual DLSPEED image.
const dllSpeedExe = path.join(root, 'build', 'DLSPEED.EXE');
const dllSpeedImage = fs.readFileSync(dllSpeedExe);
assert.strictEqual(dllSpeedImage.subarray(0, 4).toString('binary'), 'EXE\x01');
assert.strictEqual(dllSpeedImage.readUInt16LE(16), 0x8100);
assert.strictEqual(dllSpeedImage.readUInt16LE(20), 0x9ff0);
cases++;

result = runExe(dllSpeedExe, '/?', {strictPc: true});
assert.strictEqual(result.exitCode, 0, result.output);
assert.match(result.output, /public UNET509B\.DLL download path/);
assert.match(result.output, /RESULT OK/);
assert.deepStrictEqual(result.cleanup, {isaClosed: true, pagesFreed: true, done: true});
cases++;

result = runExe(dllSpeedExe, '', {strictPc: true});
assert.strictEqual(result.exitCode, 1, result.output);
assert.match(result.output, /missing or invalid URL/);
assert.match(result.output, /RESULT FAIL/);
assert.deepStrictEqual(result.cleanup, {isaClosed: true, pagesFreed: true, done: true});
cases++;

for (const url of ['http://192.168.7.44:0/BIG.BIN',
  'http://192.168.7.44:65536/BIG.BIN']) {
  result = runExe(dllSpeedExe, url, {strictPc: true});
  assert.strictEqual(result.exitCode, 1, result.output);
  assert.match(result.output, /missing or invalid URL/);
  assert.match(result.output, /RESULT FAIL/);
  assert.deepStrictEqual(result.cleanup, {isaClosed: true, pagesFreed: true, done: true});
  cases++;
}

result = runExe(dllSpeedExe, 'http://192.168.7.44/BIG.BIN', {strictPc: true});
assert.strictEqual(result.exitCode, 2, result.output);
assert.match(result.output, /could not load UNET509B\.DLL/);
assert.match(result.output, /RESULT FAIL/);
assert.deepStrictEqual(result.cleanup, {isaClosed: true, pagesFreed: true, done: true});
cases++;

const unetDllImage = fs.readFileSync(path.join(root, 'build', 'UNET509B.DLL'));
function assertBalancedDssBlocks(value) {
  const allocated = value.dssEvents.filter((event) => event.startsWith('GETMEM '))
    .map((event) => event.slice(7)).sort();
  const freed = value.dssEvents.filter((event) => event.startsWith('FREEMEM '))
    .map((event) => event.slice(8)).sort();
  assert.deepStrictEqual(freed, allocated, value.dssEvents.join('\n'));
}

// Execute the real libman loader and UNET INIT/GETCAPS/SETOPT/NETINIT path.
// No NET_* environment is supplied deliberately: NETINIT must fail cleanly,
// and l_free must release both the DLL and its temporary cold-overlay page.
result = runExe(dllSpeedExe, 'http://192.168.7.44/BIG.BIN', {
  files: {'UNET509B.DLL': unetDllImage}, traceDss: true,
  pageFill: 'random', pageSeed: 0x1357, dssStackBytes: 64,
  stepLimit: 2_000_000_000,
});
assert.strictEqual(result.exitCode, 4, result.output);
assert.match(result.output, /NETINIT failed/);
assert.match(result.output, /RESULT FAIL/);
assert.deepStrictEqual(result.cleanup, {isaClosed: true, pagesFreed: true, done: true});
assertBalancedDssBlocks(result);
cases++;

// Once INIT has created a lib_table slot, even an error closing the source DLL
// file must unload that slot instead of orphaning its DSS allocation.
result = runExe(dllSpeedExe, 'http://192.168.7.44/BIG.BIN', {
  files: {'UNET509B.DLL': unetDllImage}, traceDss: true,
  fileCloseFailAt: 1, stepLimit: 2_000_000_000,
});
assert.strictEqual(result.exitCode, 2, result.output);
assert.match(result.output, /could not load UNET509B\.DLL/);
assert.deepStrictEqual(result.cleanup, {isaClosed: true, pagesFreed: true, done: true});
assertBalancedDssBlocks(result);
cases++;

// ------------------------------------------------------------------
// DLSPEED through the real relocated UNET509B.DLL.  This is deliberately a
// complete network transfer, not another loader smoke test: it executes the
// hot page and the WIN0 cold page under strict-PC tracking, drains several
// TCP segments per public RECV, and observes the advertised windows/ACKs on
// the wire.  Explicit 1/#300 is the published performance profile.
// ------------------------------------------------------------------
function dllSpeedScenario(dll, tcp = {}, extra = {}) {
  return {
    strictPc: true,
    files: {'UNET509B.DLL': dll},
    environment: staticEnv({NET_HW: '1/#300'}),
    arp: {mac: [2, 0, 0, 0, 0, 44]},
    tcp: {mode: 'http', port: 80, ...tcp},
    stepLimit: 2_000_000_000,
    ...extra,
  };
}
function internetChecksum(bytes) {
  let sum = 0;
  for (let at = 0; at < bytes.length; at += 2) {
    sum += (bytes[at] << 8) | (bytes[at + 1] || 0);
    sum = (sum & 0xffff) + (sum >>> 16);
  }
  return (~sum) & 0xffff;
}
function clientTcpSegments(value) {
  return value.transmittedFrames.map((frame) => Buffer.from(frame, 'hex'))
    .filter((frame) => frame.length >= 54 && frame.readUInt16BE(12) === 0x0800 && frame[23] === 6)
    .map((frame) => {
      const ipLength = frame.readUInt16BE(16), tcpOffset = 34;
      const tcpLength = ipLength - 20, tcp = frame.subarray(tcpOffset, tcpOffset + tcpLength);
      assert.strictEqual(internetChecksum(frame.subarray(14, 34)), 0,
        'UNET509B emitted an invalid IPv4 checksum');
      const pseudo = Buffer.concat([frame.subarray(26, 34), Buffer.from([0, 6,
        tcpLength >> 8, tcpLength & 255]), tcp]);
      assert.strictEqual(internetChecksum(pseudo), 0,
        'UNET509B emitted an invalid TCP checksum');
      return {flags: tcp[13], sequence: tcp.readUInt32BE(4), acknowledgement: tcp.readUInt32BE(8),
        window: tcp.readUInt16BE(14), payloadLength: tcpLength - ((tcp[12] >> 4) * 4)};
    });
}
function assertDllTransfer(value, bodyLength) {
  assert.strictEqual(value.exitCode, 0, value.output);
  assert.match(value.output, new RegExp(`Received: ${bodyLength} bytes`));
  assert.match(value.output, /RESULT OK/);
  assert.deepStrictEqual(value.cleanup, {isaClosed: true, pagesFreed: true, done: true});
  assert.ok(value.mappedExecutableHits > 0, 'strict-PC never observed loaded DLL/cold code');
  assert.ok(value.dllEntryCalls[7] >= 1, 'the public RECV entry was never called');
  assert.ok(value.maxInFlight >= 2 * 536,
    `DLL kept only ${value.maxInFlight} bytes in flight, expected at least two segments`);
  const segments = clientTcpSegments(value);
  const acks = segments.filter((segment) => segment.flags === 0x10 && !segment.payloadLength);
  const windows = acks.map((segment) => segment.window);
  assert.ok(windows.every((window) => window <= 5 * 536),
    `DLL advertised more than five MSS: ${windows.join(',')}`);
  assert.ok(windows.includes(5 * 536), `DLL never opened its five-MSS RECV window: ${windows.join(',')}`);
  assert.ok(windows.filter((window) => window === 0).length <= 1,
    `normal transfer closed the window once per MSS: ${windows.join(',')}`);
  assert.strictEqual(acks[acks.length - 1].window, 536,
    'final cumulative ACK retained transient caller-buffer capacity');
  const advances = acks.slice(1).map((segment, index) =>
    (segment.acknowledgement - acks[index].acknowledgement) >>> 0);
  assert.ok(advances.some((advance) => advance >= 2 * 536),
    `no cumulative ACK covered two segments: ${advances.join(',')}`);
  cases++;
}

const DLL_BODY = Buffer.from(Array.from({length: 6000}, (_, i) => (i * 37 + 11) & 0xff));
result = runExe(dllSpeedExe, 'http://192.168.7.44/BIG.BIN', dllSpeedScenario(unetDllImage, {
  response: {status: '200 OK', body: DLL_BODY, headers: {}, closeDelimited: false},
}));
assertDllTransfer(result, DLL_BODY.length);
assert.ok(result.maxInFlight >= 5 * 536,
  `safe DLL reached only ${result.maxInFlight} bytes in flight`);
assert.ok(result.dllEntryCalls[7] < Math.ceil((DLL_BODY.length + 64) / 536),
  `one public RECV was still paid per segment (${result.dllEntryCalls[7]} calls)`);

// COLD.RUN promises to support an application stack in WIN0 even though it
// maps the overlay over that window. Patch only DLSPEED's declared stack and
// its initial LD SP so the complete loader/network scenario exercises that
// contract. No PUSH/POP may straddle the PAGE0 write.
const win0StackImage = Buffer.from(dllSpeedImage);
win0StackImage.writeUInt16LE(0x3ff0, 20);
const stackInit = Buffer.from([0x31, 0xf0, 0x9f]);
const stackInitAt = win0StackImage.indexOf(stackInit, 128);
assert.ok(stackInitAt >= 0, 'DLSPEED initial LD SP was not found');
assert.strictEqual(win0StackImage.indexOf(stackInit, stackInitAt + 1), -1,
  'DLSPEED has more than one matching LD SP; patch target is ambiguous');
win0StackImage.writeUInt16LE(0x3ff0, stackInitAt + 1);
const WIN0_STACK_BODY = Buffer.alloc(3000, 0x6d);
result = runExe(win0StackImage, 'http://192.168.7.44/WIN0.BIN',
  dllSpeedScenario(unetDllImage, {
    response: {status: '200 OK', body: WIN0_STACK_BODY, headers: {}, closeDelimited: false},
  }, {initialIff: 1}));
assertDllTransfer(result, WIN0_STACK_BODY.length);
assert.ok(result.minimumSp < 0x4000, 'WIN0 caller-stack scenario never used WIN0');
assert.deepStrictEqual(result.exitIff, {iff1: 1, iff2: 1},
  'WIN0 caller-stack scenario did not restore interrupt state');

// The safe image discards the damaged ordinary segment and consumes the good
// retransmission at the same sequence number.  Offset 9 corrupts the first
// status-code digit, so accepting it would make the HTTP parser fail.
const DLL_FAULT_BODY = Buffer.alloc(3000, 0x5a);
result = runExe(dllSpeedExe, 'http://192.168.7.44/FAULT.BIN', dllSpeedScenario(unetDllImage, {
  response: {status: '200 OK', body: DLL_FAULT_BODY, headers: {}, closeDelimited: false},
  corruptDataOnce: 9,
}));
assertDllTransfer(result, DLL_FAULT_BODY.length);

// strictPc must not grant executable permission to the zero-filled DLL BSS.
// Redirect export 0 (INIT) there; the loader relocates #0068 to #4068, and
// the harness must stop before interpreting the data byte as an instruction.
const bssJumpDll = Buffer.from(unetDllImage);
bssJumpDll[33] = 0x68;
bssJumpDll[34] = 0x00;
assert.throws(() => runExe(dllSpeedExe, 'http://192.168.7.44/BIG.BIN',
  dllSpeedScenario(bssJumpDll)), /PC escaped executable ranges: PC=4068/);
cases++;

// Nor may the unfilled upper cold-stack reservation become executable.  The
// PARSE_HW jump-table slot is redirected to its #3F80 boundary; unlike the
// real cold blob [0,length), that address was never read from the DLL file.
const coldDataJumpDll = Buffer.from(unetDllImage);
const l1Size = coldDataJumpDll.readUInt16LE(2);
const parseHwVector = l1Size + 2 + 0x16 + 15 * 2;
coldDataJumpDll[parseHwVector] = 0x80;
coldDataJumpDll[parseHwVector + 1] = 0x3f;
assert.throws(() => runExe(dllSpeedExe, 'http://192.168.7.44/BIG.BIN',
  dllSpeedScenario(coldDataJumpDll)), /PC escaped executable ranges: PC=3f80/);
cases++;

// TX_SESSION fault matrix.  All scenarios start with IFF enabled so the
// cleanup assertion covers both the ISA mapping and interrupt restoration.
const TX_BODY = Buffer.alloc(100, 0x74);
function txScenario(extra = {}) {
  return dllSpeedScenario(unetDllImage, {
    response: {status: '200 OK', body: TX_BODY, headers: {}, closeDelimited: false},
  }, {initialIff: 1, ...extra});
}
function assertTxCleanup(value) {
  assert.deepStrictEqual(value.cleanup, {isaClosed: true, pagesFreed: true, done: true});
  assert.deepStrictEqual(value.exitIff, {iff1: 1, iff2: 1});
}

// Exactly 256 fast zero polls must close ISA before the one final 1-ms wait;
// the 257th read sees completion and every frame still succeeds.
result = runExe(dllSpeedExe, 'http://192.168.7.44/TX.BIN',
  txScenario({txCompletionDelayReads: 256}));
assert.strictEqual(result.exitCode, 0, result.output);
assert.match(result.output, /RESULT OK/);
assert.ok(result.card.txStatusReads >= result.txRecords.length * 257,
  `completion was not polled through the bounded fast phase: ${result.card.txStatusReads}`);
assertTxCleanup(result);
clientTcpSegments(result);
cases++;

// Complete stale entries are popped in the first session before TX_FREE and
// the new FIFO write.  Two injected entries add exactly two status pops.
result = runExe(dllSpeedExe, 'http://192.168.7.44/TX.BIN',
  txScenario({txStaleStatuses: [0xc0, 0xc0]}));
assert.strictEqual(result.exitCode, 0, result.output);
assert.strictEqual(result.card.txStatusPops, result.txRecords.length + 2);
assertTxCleanup(result);
cases++;

// A permanently short TX_FREE times out before a byte enters FIFO.
result = runExe(dllSpeedExe, 'http://192.168.7.44/TX.BIN',
  txScenario({txFreeBlocked: true}));
assert.strictEqual(result.exitCode, 3, result.output);
assert.strictEqual(result.card.txFreeReads, 1000);
assert.strictEqual(result.txRecords.length, 0, 'TX_FREE timeout wrote an uncertain frame');
assert.match(result.output, /CONNECT failed/);
assertTxCleanup(result);
cases++;

// FIFO consumption with no completion has an unknown outcome.  Recovery may
// reset TX, but SEND_FRAME must return timeout without writing the frame twice.
result = runExe(dllSpeedExe, 'http://192.168.7.44/TX.BIN',
  txScenario({txNeverComplete: true}));
assert.strictEqual(result.exitCode, 3, result.output);
assert.strictEqual(result.txRecords.length, 1, 'uncertain TX completion was retried');
assert.strictEqual(result.card.txStatusPops, 0);
assert.ok(result.card.txStatusReads >= 258, 'final post-wait completion poll was skipped');
assertTxCleanup(result);
cases++;

// A completed overflow is a known hardware error, not a timeout and not an
// excuse to repeat the packet.  The public layer maps it to a stable failure.
result = runExe(dllSpeedExe, 'http://192.168.7.44/TX.BIN',
  txScenario({txCompletionStatus: 0xc4}));
assert.strictEqual(result.exitCode, 3, result.output);
assert.strictEqual(result.txRecords.length, 1);
assert.strictEqual(result.card.txStatusPops, 1);
assert.match(result.output, /CONNECT failed/);
assertTxCleanup(result);
cases++;

const fastDllPath = path.join(root, 'build', 'perf-fast', 'UNET509B.DLL');
assert.ok(fs.existsSync(fastDllPath), 'make perf-fast did not create its separate DLL');
const fastDllImage = fs.readFileSync(fastDllPath);
result = runExe(dllSpeedExe, 'http://192.168.7.44/BIG.BIN', dllSpeedScenario(fastDllImage, {
  response: {status: '200 OK', body: DLL_BODY, headers: {}, closeDelimited: false},
}));
assertDllTransfer(result, DLL_BODY.length);

// This is the sole intended semantic difference of perf-fast: the damaged
// established in-order data copy is accepted, so the HTTP header is visibly
// corrupt and the good duplicate cannot repair an already advanced RCV.NXT.
result = runExe(dllSpeedExe, 'http://192.168.7.44/FAULT.BIN', dllSpeedScenario(fastDllImage, {
  response: {status: '200 OK', body: DLL_FAULT_BODY, headers: {}, closeDelimited: false},
  corruptDataOnce: 9,
}));
assert.strictEqual(result.exitCode, 6, result.output);
assert.match(result.output, /invalid status, framing, chunked or compressed response/);
assert.match(result.output, /RESULT FAIL/);
assert.deepStrictEqual(result.cleanup, {isaClosed: true, pagesFreed: true, done: true});
clientTcpSegments(result);
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
// difference between DLDIRECT and timing WGET.
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

// A large multi-segment download exercises the same wire path the round-2
// throughput work targets, and gives the harness-side memoryAccesses/
// isaSessions counters (tools/exe-harness/harness.js) a realistic baseline
// to compare across steps instead of only the small fixed-size scenarios
// above. 256 KiB is 512 MSS segments -- enough that a per-segment regression
// is visible in the accesses-per-byte ratio, not lost in fixed overhead.
const LARGE_BODY = Buffer.alloc(262144, 0x5a);
result = runExe(speedExe, 'http://192.168.7.44/BIG.BIN', speedScenario({
  response: {status: '200 OK', body: LARGE_BODY, headers: {}, closeDelimited: false},
}, {stepLimit: 4_000_000_000}));
assert.strictEqual(result.exitCode, 0, result.output);
assert.match(result.output, new RegExp(`Received: ${LARGE_BODY.length} bytes`));
assert.ok(result.memoryAccesses > 0, 'harness did not report memoryAccesses');
assert.ok(result.isaSessions > 0, 'harness did not report isaSessions');
// The live pcap showed that almost the entire elapsed time was a sequence of
// host-network scheduling gaps after a five-MSS burst drained. The harness
// models MAME's 16 KiB RX partition, so DLDIRECT selects eleven MSS from the
// idle Window 3 Free Receive Bytes value and keeps it across short RECV
// boundaries. It acknowledges each pair before the window empties.
const directAcks = clientTcpSegments(result)
  .filter((segment) => segment.flags === 0x10 && !segment.payloadLength);
const directWindows = directAcks.map((segment) => segment.window);
assert.ok(result.maxInFlight >= 11 * 536,
  `DLDIRECT reached only ${result.maxInFlight} bytes in flight`);
assert.ok(directWindows.every((window) => window === 11 * 536),
  `DLDIRECT did not select its eleven-MSS window: ${directWindows.join(',')}`);
const directAdvances = directAcks.slice(1).map((segment, index) =>
  (segment.acknowledgement - directAcks[index].acknowledgement) >>> 0);
assert.ok(directAdvances.some((advance) => advance === 2 * 536),
  `DLDIRECT never advanced its sliding window by two MSS: ${directAdvances.join(',')}`);
assert.ok(directAdvances.every((advance) => advance <= 2 * 536),
  `DLDIRECT let its sliding-window ACK debt grow too far: ${directAdvances.join(',')}`);
speedChecked(result);

// A physical 8 KiB card may expose only a 5 KiB RX partition. Eleven frames
// would not fit there, so the same executable must fall back to eight MSS
// without relying on a separate hardware build.
const SMALL_FIFO_BODY = Buffer.alloc(32768, 0x6b);
result = runExe(speedExe, 'http://192.168.7.44/BIG.BIN', speedScenario({
  response: {status: '200 OK', body: SMALL_FIFO_BODY, headers: {}, closeDelimited: false},
}, {rxFifoBytes: 5 * 1024}));
assert.strictEqual(result.exitCode, 0, result.output);
assert.match(result.output, new RegExp(`Received: ${SMALL_FIFO_BODY.length} bytes`));
const smallFifoAcks = clientTcpSegments(result)
  .filter((segment) => segment.flags === 0x10 && !segment.payloadLength);
assert.ok(smallFifoAcks.length > 1, 'small-FIFO DLDIRECT emitted no data ACKs');
assert.ok(smallFifoAcks.every((segment) => segment.window === 8 * 536),
  `small-FIFO DLDIRECT exceeded eight MSS: ${smallFifoAcks.map((segment) => segment.window).join(',')}`);
assert.ok(result.maxInFlight >= 8 * 536 && result.maxInFlight < 11 * 536,
  `small-FIFO DLDIRECT reached unsafe in-flight size ${result.maxInFlight}`);
speedChecked(result);

// Round-2's two-phase receive (see the throughput plan) only fast-paths a
// clean, in-order, single-context ACK+PSH segment; everything below must
// keep falling through to the unmodified slow path and still deliver the
// exact bytes requested. These six TCPTEST fault options (originally
// exercised only against TCPTEST/UDPTEST in test-stage11-exe.js) are read
// generically by respondTcp/drainConnectionSendQueue regardless of
// options.mode, so they apply unchanged to an http-mode download.
const FAULT_BODY = Buffer.alloc(5000, 0x5a);
// corruptDataOnce is the negative control for the fused checksum: one
// byte-damaged copy of a segment arrives ahead of the good one, carrying the
// undamaged segment's checksum. FAST_RECEIVE must reject it (commit nothing,
// send no ACK) and accept the good copy behind it, so the body still arrives
// whole. Offset 9 is the first digit of the status code in "HTTP/1.0 200 OK":
// DLDIRECT discards the body, so only a corruption inside the header it does
// parse is observable at all -- accepting the damaged copy makes it print
// "[E] HTTP/1.0 <garbage>00 OK" and fail, which is what makes this control
// bite rather than pass either way.
for (const tcp of [{duplicateData: true}, {outOfOrderBeforeData: true},
  {outOfOrderFinAfterData: true}, {resetOnData: true}, {zeroWindowProbes: 2},
  {corruptDataOnce: 9}]) {
  result = runExe(speedExe, 'http://192.168.7.44/FAULT.BIN', speedScenario({
    response: {status: '200 OK', body: FAULT_BODY, headers: {}, closeDelimited: false}, ...tcp,
  }));
  if (tcp.resetOnData) {
    // A mid-transfer RST is a real transfer failure, not a fault the
    // download recovers from -- DLDIRECT must report it, not hang or
    // silently under-report bytes.
    assert.notStrictEqual(result.exitCode, 0, `${JSON.stringify(tcp)}: ${result.output}`);
  } else {
    assert.strictEqual(result.exitCode, 0, `${JSON.stringify(tcp)}: ${result.output}`);
    assert.match(result.output, new RegExp(`Received: ${FAULT_BODY.length} bytes`),
      `${JSON.stringify(tcp)}: ${result.output}`);
  }
  speedChecked(result);
}

// Response framing. Until this was fixed, the direct benchmark ignored Content-Length
// entirely and treated the peer's FIN as the only end-of-body marker, so any
// server that kept the connection open (HTTP/1.1 keep-alive is the default in
// Python's own http.server, and "Connection: close" is only a request) made a
// byte-perfect transfer sit idle for HTTP_IDLE_MS and then report TCP recv
// 0x1E -- and the ABORT on that error path put an RST on the wire, which is
// what surfaced as a traceback on the server rather than on the client that
// caused it. The harness sends FIN as soon as the body drains unless keepOpen
// says otherwise, which is exactly why the defect was invisible here.
function clientTcpFlags(result) {
  return result.transmittedFrames.map((frame) => Buffer.from(frame, 'hex')).filter((frame) =>
    frame.length >= 34 && frame.readUInt16BE(12) === 0x0800 && frame[23] === 6)
    .map((frame) => frame[14 + (frame[14] & 0x0f) * 4 + 13]);
}
const KEEPALIVE_BODY = Buffer.alloc(4000, 0x5a);
result = runExe(speedExe, 'http://192.168.7.44/KEEP.BIN', speedScenario({
  response: {status: '200 OK', body: KEEPALIVE_BODY, headers: {}, closeDelimited: false},
  keepOpen: true,
}));
assert.strictEqual(result.exitCode, 0, result.output);
assert.match(result.output, new RegExp(`Received: ${KEEPALIVE_BODY.length} bytes`));
assert.doesNotMatch(result.output, /TCP recv failed/, result.output);
assert.match(result.output, /RESULT OK/);
// Ended by the declared length, so the peer gets an orderly FIN and never an
// RST -- the client must not abort a connection it finished with cleanly.
const keepFlags = clientTcpFlags(result);
assert.ok(keepFlags.some((flags) => flags & 0x01), 'DLDIRECT never sent a FIN');
assert.ok(!keepFlags.some((flags) => flags & 0x04),
  `DLDIRECT reset a completed keep-alive connection: ${keepFlags.map((f) => f.toString(16))}`);
speedChecked(result);

// A declared length the server never delivers is a truncated transfer, not a
// measurement: it must be reported, never printed as a rate for a short body.
result = runExe(speedExe, 'http://192.168.7.44/SHORT.BIN', speedScenario({
  response: {raw: `HTTP/1.0 200 OK\r\nContent-Length: 10000\r\n\r\n${'x'.repeat(400)}`},
}));
assert.strictEqual(result.exitCode, 3, result.output);
assert.match(result.output, /TCP recv failed, code 0x/);
assert.match(result.output, /RESULT FAIL/);
speedChecked(result);

// No Content-Length at all is still legal HTTP/1.0 framing: the body then runs
// to the peer's FIN, which stays the only thing that can end it.
const CLOSE_BODY = Buffer.alloc(3000, 0x5a);
result = runExe(speedExe, 'http://192.168.7.44/CLOSE.BIN', speedScenario({
  response: {status: '200 OK', body: CLOSE_BODY, headers: {}, closeDelimited: true},
}));
assert.strictEqual(result.exitCode, 0, result.output);
assert.match(result.output, new RegExp(`Received: ${CLOSE_BODY.length} bytes`));
assert.match(result.output, /RESULT OK/);
speedChecked(result);

// Header field names are case-insensitive (RFC 7230), and the value may be
// padded; a server writing it any other way must not silently fall back to
// FIN-delimited framing and hang against keep-alive.
result = runExe(speedExe, 'http://192.168.7.44/CASE.BIN', speedScenario({
  response: {raw: `HTTP/1.0 200 OK\r\nCONTENT-LENGTH:   400\r\n\r\n${'y'.repeat(400)}`},
  keepOpen: true,
}));
assert.strictEqual(result.exitCode, 0, result.output);
assert.match(result.output, /Received: 400 bytes/);
speedChecked(result);

// Header bytes may arrive in any segmentation, including one byte per TCP
// segment. This exercises parser state across every CR/LF and field boundary.
result = runExe(speedExe, 'http://192.168.7.44/SPLIT.BIN', speedScenario({
  response: {raw: `HTTP/1.0 200 OK\r\nContent-Length: 400\r\n\r\n${'s'.repeat(400)}`},
  responseChunkSize: 1, keepOpen: true,
}));
assert.strictEqual(result.exitCode, 0, result.output);
assert.match(result.output, /Received: 400 bytes/);
speedChecked(result);

for (const response of [
  {raw: 'HTTP/1.0 404 Not Found\r\nContent-Length: 0\r\n\r\n'},
  {raw: 'HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n1\r\nx\r\n0\r\n\r\n'},
  {raw: 'HTTP/1.0 200 OK\r\nContent-Encoding: gzip\r\nContent-Length: 4\r\n\r\ngzip'},
]) {
  result = runExe(speedExe, 'http://192.168.7.44/REJECT.BIN', speedScenario({response}));
  assert.strictEqual(result.exitCode, 6, result.output);
  assert.match(result.output, /invalid or unsupported HTTP response/);
  assert.match(result.output, /RESULT FAIL/);
  speedChecked(result);
}

// remoteFinAfterData attaches FIN to the *next* chunk drainConnectionSendQueue
// sends regardless of queue depth (see harness.js), so it only mirrors
// TCPTEST's "FIN on the one and only reply" case when the whole body fits in
// a single MSS; a multi-segment body would make this a premature-close fault
// instead, which is a different scenario from the one being ported here.
const FIN_BODY = Buffer.alloc(400, 0x5a);
result = runExe(speedExe, 'http://192.168.7.44/FIN.BIN', speedScenario({
  response: {status: '200 OK', body: FIN_BODY, headers: {}, closeDelimited: false},
  remoteFinAfterData: true,
}));
assert.strictEqual(result.exitCode, 0, result.output);
assert.match(result.output, new RegExp(`Received: ${FIN_BODY.length} bytes`));
speedChecked(result);

console.log(`Stage 13 actual EXE: ${cases} FTP/DLDIRECT and DLSPEED loader/cleanup scenarios passed`);
