#!/usr/bin/env node
// Stage 12 WGET golden-output and actual DSS EXE HTTP scenarios.
// SPDX-License-Identifier: BSD-3-Clause
'use strict';

const assert = require('assert');
const crypto = require('crypto');
const fs = require('fs');
const path = require('path');
const {runExe} = require('./exe-harness/harness.js');

const root = path.resolve(__dirname, '..');
const executable = path.join(root, 'build', 'WGET.EXE');
const golden = JSON.parse(fs.readFileSync(path.join(__dirname,
  'test-fixtures', 'stage12-wget-golden.json'), 'utf8'));
let cases = 0;

function staticEnv(extra = {}) {
  return {
    NET: '509B', NET_HW: 'AUTO', NET_IDPORT: '#110',
    NET_MAC: '02:60:8C:12:34:56', NET_IP_SRC: 'STATIC',
    NET_IP: '192.168.7.20', NET_MASK: '255.255.255.0', NET_GW: '0.0.0.0',
    NET_DNS1: '192.168.7.1', NET_DNS2: '192.168.7.2', ...extra,
  };
}
function scenario(tcp = {}, extra = {}) {
  return {strictPc: true, environment: staticEnv(),
    arp: {mac: [2,0,0,0,0,44]}, tcp: {mode: 'http', port: 80, ...tcp},
    clockFreezeAfterReads: 0, stepLimit: 900_000_000, ...extra};
}
function run(args, value = {}) { return runExe(executable, args, value); }
function normalized(output) {
  return output.replace(/^3C509B WGET v[^\r\n]+/, '<WGET-BANNER>')
    .replace(/^REGS .*$/gm, '<REGS-HARDWARE>');
}
function checked(result) {
  assert.deepStrictEqual(result.cleanup, {isaClosed: true, pagesFreed: true, done: true});
  // The standard layout claims no page, so there is one stack for the whole
  // run: it grows down from BFF0h, and BE00h is the command copy directly
  // beneath it. Crossing that is what would corrupt the parsed command line.
  assert.strictEqual(result.minimumPageSp, null,
    'Stage 12 no longer claims a runtime page, so none should be tracked');
  assert.ok(result.minimumSp >= 0xbf00,
    `Stage 12 stack reached the command copy: #${result.minimumSp.toString(16)}`);
  cases++;
}
function response(status, body = Buffer.alloc(0), headers = {}, closeDelimited = false) {
  return {status, body, headers, closeDelimited};
}
function outputFile(result, name) { return result.files[`C:\\NET\\${name.toUpperCase()}`]; }
// The MSS option off the client's own SYN. WGET announces a whole Ethernet
// payload, and that only pays off if the option is really on the wire.
function clientSyn(result) {
  for (const hex of result.transmittedFrames) {
    const frame = Buffer.from(hex, 'hex');
    if (frame.length < 54 || frame.readUInt16BE(12) !== 0x0800 || frame[23] !== 6) continue;
    const tcp = frame.subarray(34, 34 + frame.readUInt16BE(16) - 20);
    if (!(tcp[13] & 0x02)) continue;
    const headerLength = (tcp[12] >> 4) * 4;
    let mss = 0;
    for (let at = 20; at < headerLength;) {
      const kind = tcp[at];
      if (!kind) break;
      if (kind === 1) { at++; continue; }
      if (kind === 2 && tcp[at + 1] === 4) mss = tcp.readUInt16BE(at + 2);
      at += tcp[at + 1];
    }
    return {mss};
  }
  throw new Error('client sent no SYN');
}
function sha256(value) { return crypto.createHash('sha256').update(value).digest('hex'); }

assert.strictEqual(golden.reference,
  '../sprinter-rtl8019a@9ec98b00c6490fed5eb722c52b47d11c70a199ae');
const image = fs.readFileSync(executable);
assert.strictEqual(image.subarray(0, 4).toString('binary'), 'EXE\x01');
assert.strictEqual(image.readUInt16LE(4), 128);
// WGET loads into WIN1 and claims WIN2: its image fills a whole window, so it
// cannot host a stack above itself in the window it runs from.
assert.strictEqual(image.readUInt16LE(16), 0x4100);
// DSS installs the header stack before the entry point runs, and spends it on
// the loader and on interrupt frames, so it must be clear of the image
// already. The standard layout hands the program WIN1+WIN2 as one region, so
// the stack sits at the top of WIN2 -- a whole window clear of the image.
assert.strictEqual(image.readUInt16LE(20), 0xbff0);
// The image holds code and rodata only; the runtime data area begins 2 KiB
// above PAGE_BASE (0x8800, memory.inc's S12_IMAGE_LIMIT), so that is what
// bounds it. Keep this strict: an image crossing it silently overwrites
// buffers instead of failing to load.
assert.ok(0x4080 + image.length <= 0x8800,
  'WGET image runs into its runtime data area');
let longest = 0, zeroRun = 0;
for (const byte of image.subarray(128)) {
  zeroRun = byte ? 0 : zeroRun + 1; longest = Math.max(longest, zeroRun);
}
assert.ok(longest < 128, 'WGET contains zero-filled runtime BSS');
cases++;

let result = run('/?');
assert.strictEqual(result.exitCode, 0);
assert.strictEqual(normalized(result.output), golden.help); checked(result);
for (const bad of ['', 'ftp://host/a', 'host/a', 'http://host:0/a',
  'http://host:abc/a', 'http://host:65537/a', 'http://host/a -o',
  'http://a/x http://b/y', '/? -d']) {
  result = run(bad);
  assert.strictEqual(result.exitCode, 1, `accepted '${bad}'`);
  assert.strictEqual(result.transmittedFrames.length, 0);
  if (!bad) assert.strictEqual(normalized(result.output), golden.invalid);
  checked(result);
}

result = run('HTTP://192.168.7.44/a.bin -y', scenario({response: response('200 OK', 'hello')}));
assert.strictEqual(result.exitCode, 0, result.output);
assert.strictEqual(normalized(result.output), golden.small);
assert.deepStrictEqual(outputFile(result, 'a.bin'), Buffer.from('hello'));
assert.strictEqual(result.httpRequests[0],
  'GET /a.bin HTTP/1.0\r\nHost: 192.168.7.44\r\nConnection: close\r\n\r\n');
checked(result);

result = run('/D http://192.168.7.44:8080/ -O root.out /Y', scenario({port: 8080,
  response: response('200 OK', 'dot-data')}));
assert.strictEqual(result.exitCode, 0, result.output);
assert.ok(!result.output.includes('KB /'));
assert.ok(result.output.includes('.\r\nDone. 8 bytes received.'));
assert.strictEqual(result.httpRequests[0],
  'GET / HTTP/1.0\r\nHost: 192.168.7.44\r\nConnection: close\r\n\r\n');
assert.deepStrictEqual(outputFile(result, 'root.out'), Buffer.from('dot-data')); checked(result);

result = run('http://192.168.7.44:65535/max.bin -y', scenario({port: 65535,
  response: response('200 OK', 'max-port')}));
assert.strictEqual(result.exitCode, 0, result.output);
assert.match(result.output, /port 65535/);
assert.deepStrictEqual(outputFile(result, 'max.bin'), Buffer.from('max-port')); checked(result);

result = run('http://192.168.7.44/ -y', scenario({response: response('200 OK')}));
assert.ok(outputFile(result, 'output.bin'));
assert.match(result.httpRequests[0], /^GET \/ HTTP\/1\.0/); checked(result);

for (const [key, selected] of [['c', 'cancel'], ['o', 'overwrite'], ['r', 'resume']]) {
  const old = Buffer.from('OLD');
  const tcp = selected === 'resume' ? {response: response('206 Partial Content', 'NEW')} :
    {response: response('200 OK', 'NEW')};
  result = run('http://192.168.7.44/KEEP.BIN', scenario(tcp,
    {files: {'KEEP.BIN': old}, promptKey: key}));
  if (selected === 'cancel') {
    assert.strictEqual(result.exitCode, 7);
    assert.strictEqual(normalized(result.output), golden.prompt_cancel);
    assert.deepStrictEqual(outputFile(result, 'keep.bin'), old);
  } else {
    assert.strictEqual(result.exitCode, 0, result.output);
    assert.deepStrictEqual(outputFile(result, 'keep.bin'),
      Buffer.from(selected === 'resume' ? 'OLDNEW' : 'NEW'));
    if (selected === 'resume') assert.match(result.httpRequests[0], /Range: bytes=3-/);
  }
  checked(result);
}

const prior = Buffer.from(Array.from({length: 70003}, (_, i) => (i * 17 + 3) & 255));
const remainder = Buffer.from(Array.from({length: 9017}, (_, i) => (i * 29 + 7) & 255));
result = run('-f -r -o resumed.bin http://192.168.7.44/blob', scenario({
  response: response('206 Partial Content', remainder), responseChunkSize: 137,
}, {files: {'resumed.bin': prior}, traceDss: true}));
assert.strictEqual(result.exitCode, 0, result.output);
assert.match(result.httpRequests[0], /Range: bytes=70003-/);
assert.strictEqual(sha256(outputFile(result, 'resumed.bin')),
  sha256(Buffer.concat([prior, remainder])));
// 137-byte segments: each RECV delivers one, the buffer is flushed in whole
// sectors as soon as a full MSS no longer fits, and only the final flush is
// allowed to be partial.
assert.deepStrictEqual(
  result.dssEvents.filter((event) => event.startsWith('WRITE C:\\NET\\RESUMED.BIN '))
    .map((event) => Number(event.split(' ').pop())),
  [1536, 1536, 1536, 1536, 1536, 1337]);
checked(result);

result = run('http://192.168.7.44/keep.bin -r', scenario({
  response: response('200 OK', 'replacement')}, {files: {'keep.bin': 'OLD'}}));
assert.strictEqual(result.exitCode, 6);
assert.strictEqual(normalized(result.output), golden.range_ignored);
assert.deepStrictEqual(outputFile(result, 'keep.bin'), Buffer.from('OLD')); checked(result);

result = run('http://192.168.7.44/complete.bin -r', scenario({
  response: response('416 Range Not Satisfiable')}, {files: {'complete.bin': 'COMPLETE'}}));
assert.strictEqual(result.exitCode, 6); assert.match(result.output, /HTTP\/1\.0 416 Range Not Satisfiable/);
assert.deepStrictEqual(outputFile(result, 'complete.bin'), Buffer.from('COMPLETE')); checked(result);

result = run('http://192.168.7.44/new.bin -r', scenario({
  response: response('404 Not Found', 'error')}));
assert.strictEqual(result.exitCode, 6); assert.ok(!outputFile(result, 'new.bin')); checked(result);

for (const status of ['404 Not Found', '500 Internal Server Error']) {
  result = run(`http://192.168.7.44/${status[0]}.bin -y`, scenario({
    response: response(status, '<error>')}));
  assert.strictEqual(result.exitCode, 6);
  assert.ok(!outputFile(result, `${status[0]}.bin`));
  if (status.startsWith('404')) assert.strictEqual(normalized(result.output), golden.not_found);
  else assert.match(result.output, /\[E\] HTTP\/1\.0 500 Internal Server Error/);
  checked(result);
}

result = run('http://192.168.7.44/start -y -o redirected.bin', scenario({responses: {
  '/start': response('302 Found', 'ignored', {Location: '/final'}),
  '/final': response('200 OK', 'arrived'),
}}));
assert.strictEqual(result.exitCode, 0, result.output);
assert.match(result.output, /Redirect: HTTP\/1\.0 302 Found/);
assert.deepStrictEqual(outputFile(result, 'redirected.bin'), Buffer.from('arrived'));
assert.strictEqual(result.httpRequests.length, 2); checked(result);

// Response framing against a server that does NOT close the connection.
// "Connection: close" is only a request, and HTTP/1.1 keep-alive is the
// default for common servers (Python's http.server among them). Until this
// was fixed, WGET treated the peer's FIN as the sole end-of-body marker, so a
// download that arrived complete and byte-exact still sat idle for
// HTTP_IDLE_MS and then reported "TCP recv failed, code 0x1E" with a failing
// exit code -- while the fully correct file sat on disk. The harness only
// withholds its FIN when keepOpen says so, which is why every scenario above
// missed this.
const KEEPALIVE_BODY = Buffer.alloc(4000, 0x5a);
result = run('http://192.168.7.44/keep.bin -y', scenario({
  response: response('200 OK', KEEPALIVE_BODY), keepOpen: true}));
assert.strictEqual(result.exitCode, 0, result.output);
assert.deepStrictEqual(outputFile(result, 'keep.bin'), KEEPALIVE_BODY);
assert.doesNotMatch(result.output, /TCP recv failed/, result.output);
assert.match(result.output, /RESULT OK/); checked(result);

// The same framing rule has to end a discarded hop, or a redirect from a
// keep-alive server stalls before the request that actually matters is sent.
result = run('http://192.168.7.44/hop -y -o hopped.bin', scenario({responses: {
  '/hop': response('302 Found', 'discarded', {Location: '/landing'}),
  '/landing': response('200 OK', 'arrived'),
}, keepOpen: true}));
assert.strictEqual(result.exitCode, 0, result.output);
assert.deepStrictEqual(outputFile(result, 'hopped.bin'), Buffer.from('arrived'));
assert.strictEqual(result.httpRequests.length, 2); checked(result);

result = run('http://192.168.7.44/original.bin -y', scenario({responses: {
  '/original.bin': response('302 Found', '', {Location: '/failed.bin'}),
  '/failed.bin': response('404 Not Found', 'not written'),
}}));
assert.strictEqual(result.exitCode, 6, result.output);
assert.ok(!outputFile(result, 'original.bin'));
assert.ok(!outputFile(result, 'failed.bin')); checked(result);

for (const [headers, line] of [[{}, 'redirect with no Location header'],
  [{Location: 'relative'}, 'cannot parse redirect Location'],
  [{Location: 'https://secure.test/a'}, 'redirect to https:// is not supported']]) {
  result = run('http://192.168.7.44/redir -y', scenario({
    response: response('302 Found', '', headers)}));
  assert.strictEqual(result.exitCode, 6, result.output); assert.ok(result.output.includes(line));
  checked(result);
}

const redirectResponses = {};
for (let i = 0; i <= 5; i++) redirectResponses[`/r${i}`] =
  response('302 Found', '', {Location: `/r${i + 1}`});
result = run('http://192.168.7.44/r0 -y', scenario({responses: redirectResponses}));
assert.strictEqual(result.exitCode, 6); assert.match(result.output, /too many redirects \(cap = 5\)/);
assert.strictEqual(result.httpRequests.length, 6); checked(result);

const fiveResponses = {};
for (let i = 0; i < 5; i++) fiveResponses[`/ok${i}`] =
  response('302 Found', '', {Location: `/ok${i + 1}`});
fiveResponses['/ok5'] = response('200 OK', 'five');
result = run('http://192.168.7.44/ok0 -y -o five.bin', scenario({responses: fiveResponses}));
assert.strictEqual(result.exitCode, 0, result.output);
assert.strictEqual(result.httpRequests.length, 6);
assert.deepStrictEqual(outputFile(result, 'five.bin'), Buffer.from('five')); checked(result);

result = run('http://192.168.7.44/abs -y -o abs.bin', scenario({responses: {
  '/abs': response('301 Moved', '', {Location: 'http://192.168.7.44/final'}),
  '/final': response('200 OK', 'absolute'),
}}));
assert.strictEqual(result.exitCode, 0, result.output);
assert.deepStrictEqual(outputFile(result, 'abs.bin'), Buffer.from('absolute')); checked(result);

for (const [name, body, tcp] of [
  ['ZERO.BIN', Buffer.alloc(0), {}],
  ['BOUND.BIN', Buffer.from('segment-boundary-body'), {responseChunkSize: 1}],
  ['CLOSE.BIN', Buffer.from('close-delimited'), {}],
]) {
  result = run(`http://192.168.7.44/${name} -y`, scenario({
    ...tcp, response: response('200 OK', body, {}, name === 'CLOSE.BIN')}));
  assert.strictEqual(result.exitCode, 0, result.output);
  assert.deepStrictEqual(outputFile(result, name), body); checked(result);
}

const large = Buffer.from(Array.from({length: 70001}, (_, i) => (i * 37 + 11) & 255));
result = run('http://192.168.7.44/LARGE.BIN -y', scenario({
  response: response('200 OK', large)}, {traceDss: true}));
assert.strictEqual(result.exitCode, 0, result.output);
assert.strictEqual(sha256(outputFile(result, 'large.bin')), sha256(large));
const writes = result.dssEvents.filter((event) => event.startsWith('WRITE '))
  .map((event) => Number(event.split(' ').pop()));
// The disk buffer is 3 KiB: it gave 2 KiB to the image for the session
// receive path, after live FTP runs showed DSS_WRITE costs per byte, not per
// call. Each RECV takes one whole 1460-byte segment straight from the FIFO,
// and as soon as another would not fit the whole sectors staged are written
// and the sub-sector remainder slides down -- so every body write but the
// last is 1536 or 2560 (the 2560 lands whenever the carry-over is small
// enough for two segments to have fitted), and none straddles a sector.
assert.strictEqual(writes.length, 40);
assert.ok(writes.slice(0, -1).every((size) => size === 1536 || size === 2560),
  `body writes are not whole sectors: ${writes}`);
assert.strictEqual(writes.at(-1), 1905);
assert.strictEqual(writes.reduce((sum, size) => sum + size, 0), large.length);
// Sixteen flushes per repaint plus the forced final one: 40 flushes -> 3.
assert.strictEqual((result.output.match(/KB \/ /g) || []).length, 3,
  `expected three repaints of the counter, got:\n${result.output}`);
checked(result);

result = run('http://192.168.7.44/FULL.BIN -y', scenario({
  response: response('200 OK', Buffer.alloc(9000, 0x5a))},
  {diskFullAfter: 8192, traceDss: true}));
assert.strictEqual(result.exitCode, 5); assert.match(result.output, /file create\/write failed/);
// Four whole-sector writes (2560+1536+1536+1536) land before the fifth would
// cross the 8192-byte limit.
assert.strictEqual(outputFile(result, 'full.bin').length, 7168); checked(result);

result = run('http://192.168.7.44/CLOSEERR.BIN -y', scenario({
  response: response('200 OK', 'complete')}, {fileCloseFailAt: 1}));
assert.strictEqual(result.exitCode, 5); assert.match(result.output, /file create\/write failed/);
assert.deepStrictEqual(outputFile(result, 'closeerr.bin'), Buffer.from('complete')); checked(result);

result = run('http://192.168.7.44/SHORT.BIN -y', scenario({
  response: {raw: 'HTTP/1.0 200 OK\r\nContent-Length: 10\r\n\r\nabc'}}));
assert.strictEqual(result.exitCode, 3); assert.deepStrictEqual(outputFile(result, 'short.bin'), Buffer.from('abc'));
assert.match(result.output, /TCP recv failed, code 0x19/); checked(result);

result = run('http://host.test/name.bin -y', scenario({}, {
  dns: {address: [192,168,7,44]}, tcp: {mode: 'http', port: 80,
    response: response('200 OK', 'dns')}, arp: {mac: [2,0,0,0,0,44]},
}));
assert.strictEqual(result.exitCode, 0, result.output);
assert.strictEqual(result.requestCounts.dns, 1);
assert.deepStrictEqual(outputFile(result, 'name.bin'), Buffer.from('dns')); checked(result);

result = run('http://host.test./dot.bin -y', scenario({}, {
  dns: {address: [192,168,7,44]}, tcp: {mode: 'http', port: 80,
    response: response('200 OK', 'trailing-dot')}, arp: {mac: [2,0,0,0,0,44]},
}));
assert.strictEqual(result.exitCode, 0, result.output);
assert.deepStrictEqual(outputFile(result, 'dot.bin'), Buffer.from('trailing-dot')); checked(result);

for (const dnsFault of [
  {badChecksumBeforeReply: true, badChecksumAddress: [192,168,7,99]},
  {badLengthBeforeReply: true, badLengthAddress: [192,168,7,99]},
  {cnameBeforeAnswer: true},
  {paddingBeforeAnswer: 205},
]) {
  result = run('http://host.test/validated.bin -y', scenario({}, {
    dns: {address: [192,168,7,44], ...dnsFault}, tcp: {mode: 'http', port: 80,
      response: response('200 OK', 'validated')}, arp: {mac: [2,0,0,0,0,44]},
  }));
  assert.strictEqual(result.exitCode, 0, result.output);
  assert.match(result.output, /Resolved host\.test -> 192\.168\.7\.44 port 80/);
  assert.deepStrictEqual(outputFile(result, 'validated.bin'), Buffer.from('validated'));
  checked(result);
}

result = run('http://host.test/a -y', scenario({}, {
  dns: {mode: 'drop'}, tcp: undefined, timeStepSeconds: 1,
}));
assert.strictEqual(result.exitCode, 3); assert.match(result.output, /could not resolve host/);
assert.strictEqual(result.requestCounts.dns, 6); checked(result);

result = run('http://192.168.7.44/a -y', scenario({mode: 'drop'}, {timeStepSeconds: 1}));
assert.strictEqual(result.exitCode, 3); assert.match(result.output, /TCP connect failed, code 0x/);
assert.match(normalized(result.output), /<REGS-HARDWARE>/); checked(result);

// The status byte alone cannot separate these three: a refused connect and a
// silent host both end an OPEN, and a gateway that never answers ARP reports
// the same 0x1E as a host that never answers the SYN. NETERR.DESCRIBE_TCP
// pairs the status with the stage TCPX published, so each prints its own
// cause. The hex code stays in the line either way -- the phrase is advice.
result = run('http://192.168.7.44/a -y',
  scenario({resetOnSyn: true, resetAlways: true}, {timeStepSeconds: 1}));
assert.strictEqual(result.exitCode, 3);
assert.match(result.output,
  /TCP connect failed, code 0x1F \(refused, no server on that port\)/);
checked(result);

result = run('http://192.168.7.44/a -y', scenario({mode: 'drop'}, {timeStepSeconds: 1}));
assert.strictEqual(result.exitCode, 3);
assert.match(result.output, /TCP connect failed, code 0x1E \(no answer from host\)/);
checked(result);

result = run('http://192.168.7.44/a -y',
  scenario({}, {arp: {mode: 'drop'}, timeStepSeconds: 1}));
assert.strictEqual(result.exitCode, 3);
assert.match(result.output,
  /TCP connect failed, code 0x1E \(no ARP reply, check gateway\)/);
checked(result);

result = run('http://192.168.7.44/PART.BIN -y', scenario({
  response: {raw: 'HTTP/1.0 200 OK\r\nContent-Length: 10000\r\n\r\npartial'}, keepOpen: true,
}, {timeStepSeconds: 1}));
assert.strictEqual(result.exitCode, 3); assert.deepStrictEqual(outputFile(result, 'part.bin'), Buffer.from('partial'));
assert.match(result.output, /TCP recv failed, code 0x1E/);
checked(result);

for (const key of ['escape', 'ctrl-c']) {
  result = run('http://192.168.7.44/CANCEL.BIN -y', scenario({
    response: response('200 OK', Buffer.alloc(10000, 0x63)), keepOpen: true},
    // The responder now fills the advertised window in one burst, so the key
    // has to land after WGET has drained a few segments rather than after the
    // first one -- otherwise the cancel is seen before any body is buffered.
    {key, keyAfterHttpBytes: 4000, timeStepSeconds: 1}));
  assert.strictEqual(result.exitCode, 7); assert.match(result.output, /Aborted by user \(Esc\/Ctrl\+C\)\./);
  assert.ok(outputFile(result, 'cancel.bin').length > 0); checked(result);
}

result = run('http://192.168.7.44/RATE.BIN -y', scenario({
  response: response('200 OK', 'hello')},
  {clockFreezeAfterReads: undefined, timeStepSeconds: 1}));
assert.match(result.output, /  5 bytes in [1-9][0-9]* sec, 0 B\/s\r\n/); checked(result);

// 0.03 s per emulated clock read, not 0.01: the same 70 KiB now arrives in
// roughly a third as many segments (MSS 1460), so it costs a third as many
// polls and clock reads. At the old step the transfer finished inside one
// emulated second and the rate line correctly suppressed itself, which is the
// "sample too short" path rather than the formatting this case is here to pin.
result = run('http://192.168.7.44/FAST.BIN -y', scenario({
  response: response('200 OK', Buffer.alloc(70001, 0x21))},
  {clockFreezeAfterReads: undefined, timeStepSeconds: 0.03}));
assert.match(result.output, /  70001 bytes in [1-9][0-9]* sec, [1-9][0-9]* KB\/s\r\n/);
// Two things are worth gating on a fixed 70 KiB download. Emulated CPU work is
// one: the hot loops (ETHERNET.ACCUMULATE, EL3IO.FIFO_READ) brought it from
// 2664k to 2055k steps, and advertising a real receive window took it to 1706k
// by removing one redundant ACK per segment.
assert.ok(result.steps < 1_900_000,
  `70 KiB download cost ${result.steps} steps, over the 1900k budget`);
// The other is the depth of the receive pipe, which is what a latency-bound
// link actually cares about and what CPU steps cannot see. The peer must be
// able to keep a whole window in flight; a binary or one-MSS window shows up
// here immediately. The window is now two whole 1460-byte segments.
assert.ok(result.maxInFlight >= 2 * 1460,
  `peer kept only ${result.maxInFlight} bytes in flight, expected a 2-segment window`);
// WGET asks for a whole Ethernet payload, and the peer must actually use it:
// a responder that ignored the MSS option would leave every other assertion
// here green while the transfer kept paying per-segment costs it need not.
assert.strictEqual(clientSyn(result).mss, 1460,
  'WGET did not advertise MSS 1460 on its SYN');
checked(result);

result = run('http://192.168.7.44/MIDNIGHT.BIN -y', scenario({
  response: response('200 OK', 'midnight')},
  {clockFreezeAfterReads: undefined, clockSecond: 86398, timeStepSeconds: 1}));
assert.match(result.output, /  8 bytes in [1-9][0-9]* sec, [0-9]+ B\/s\r\n/);
assert.doesNotMatch(result.output, /bytes in [0-9]{5,} sec/); checked(result);

// Round-2's two-phase receive (see the throughput plan) only fast-paths a
// clean, in-order, single-context ACK+PSH segment; everything below must
// keep falling through to the unmodified slow path and still land the exact
// bytes on disk. These six TCPTEST fault options (originally exercised only
// against TCPTEST/UDPTEST in test-stage11-exe.js) are read generically by
// respondTcp/drainConnectionSendQueue regardless of options.mode, so they
// apply unchanged to an http-mode download. WGET's disk write makes this a
// sha256 check rather than DLSPEED's byte-count-only one.
const FAULT_BODY = Buffer.from(Array.from({length: 5000}, (_, i) => (i * 13 + 5) & 0xff));
// corruptDataOnce sends one byte-damaged copy of a segment ahead of the good
// one, still carrying the undamaged segment's checksum: the receive checksum
// has to reject it and take the good copy behind it. WGET is still on the
// unmodified slow path (it does not define EL3_SESSION_RX yet), so here this
// guards @TCP.PARSE's own verification; the sha256 below is what makes it
// bite, since a damaged byte that got through would land in the file.
for (const tcp of [{duplicateData: true}, {outOfOrderBeforeData: true},
  {outOfOrderFinAfterData: true}, {resetOnData: true}, {zeroWindowProbes: 2},
  {corruptDataOnce: 9}]) {
  result = run('http://192.168.7.44/FAULT.BIN -y', scenario({
    response: response('200 OK', FAULT_BODY), ...tcp,
  }));
  if (tcp.resetOnData) {
    // A mid-transfer RST is a real transfer failure, not a fault the
    // download recovers from -- WGET must report it, not hang or silently
    // write a truncated file as if it were complete.
    assert.notStrictEqual(result.exitCode, 0, `${JSON.stringify(tcp)}: ${result.output}`);
  } else {
    assert.strictEqual(result.exitCode, 0, `${JSON.stringify(tcp)}: ${result.output}`);
    assert.strictEqual(sha256(outputFile(result, 'fault.bin')), sha256(FAULT_BODY),
      `${JSON.stringify(tcp)}: ${result.output}`);
  }
  checked(result);
}

// remoteFinAfterData attaches FIN to the *next* chunk drainConnectionSendQueue
// sends regardless of queue depth (see harness.js), so it only mirrors
// TCPTEST's "FIN on the one and only reply" case when the whole body fits in
// a single MSS; a multi-segment body would make this a premature-close fault
// instead, which is a different scenario from the one being ported here.
const FIN_BODY = Buffer.from(Array.from({length: 400}, (_, i) => (i * 13 + 5) & 0xff));
result = run('http://192.168.7.44/FIN.BIN -y', scenario({
  response: response('200 OK', FIN_BODY), remoteFinAfterData: true,
}));
assert.strictEqual(result.exitCode, 0, result.output);
assert.strictEqual(sha256(outputFile(result, 'fin.bin')), sha256(FIN_BODY));
checked(result);

console.log(`Stage 12 actual EXE: ${cases} CLI/golden/HTTP/file/resume/fault scenarios passed`);
