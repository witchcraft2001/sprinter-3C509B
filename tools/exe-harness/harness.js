// Execute a real Sprinter DSS EXE against strict DSS/ISA/3C509B models.
// SPDX-License-Identifier: BSD-3-Clause
'use strict';

const fs = require('fs');
global.window = {};
const Z80 = require('./Z80core.js');

const DEFAULT_MAC = [0x02, 0x60, 0x8c, 0x12, 0x34, 0x56];
const u16 = (buf, off) => buf[off] | (buf[off + 1] << 8);
const hex = (bytes) => Buffer.from(bytes).toString('hex');
const equal = (a, b) => a.length === b.length && a.every((v, i) => v === b[i]);

function checksum(bytes) {
  let sum = 0;
  for (let i = 0; i < bytes.length; i += 2) {
    sum += (bytes[i] << 8) | (bytes[i + 1] || 0);
    sum = (sum & 0xffff) + (sum >>> 16);
  }
  return (~sum) & 0xffff;
}

function dhcpMessageType(frame) {
  if (frame.length < 286 || frame[12] !== 8 || frame[13] !== 0) return 0;
  for (let i = 282; i < frame.length;) {
    const code = frame[i++];
    if (code === 255) break;
    if (code === 0) continue;
    if (i >= frame.length) break;
    const length = frame[i++];
    if (code === 53 && length === 1 && i < frame.length) return frame[i];
    i += length;
  }
  return 0;
}

function buildDhcpReply(request, type, options = {}) {
  const serverMac = options.serverMac || [0x02, 0, 0, 0, 0, 1];
  const serverIp = options.serverIp || [192, 168, 7, 1];
  const offeredIp = options.offeredIp || [192, 168, 7, 100];
  const mask = options.mask || [255, 255, 255, 0];
  const router = options.router || serverIp;
  const dns = options.dns || [[1, 1, 1, 1], [8, 8, 8, 8]];
  const lease = options.lease || 3600;
  const destination = options.foreignDestination ? [2, 9, 9, 9, 9, 9] :
    (options.unicastReply ? request.slice(6, 12) : Array(6).fill(0xff));
  const destinationIp = options.unicastReply ? request.slice(26, 30) : [255, 255, 255, 255];
  const frame = [...destination, ...serverMac, 8, 0];
  const ip = [0x45, 0, 0, 0, 0x12, 0x34, 0x40, 0, 64, 17, 0, 0, ...serverIp, ...destinationIp];
  const udp = [0, 67, 0, 68, 0, 0, 0, 0];
  const bootp = Array(240).fill(0);
  bootp[0] = 2; bootp[1] = 1; bootp[2] = 6;
  bootp.splice(4, 4, ...request.slice(46, 50));
  if (type !== 6 && !options.zeroYiaddr) bootp.splice(16, 4, ...offeredIp);
  bootp.splice(28, 6, ...request.slice(70, 76));
  bootp.splice(236, 4, 0x63, 0x82, 0x53, 0x63);
  const opts = [53, 1, type];
  if (!options.missingServer) opts.push(54, 4, ...serverIp);
  if (type !== 6) {
    const maskData = options.badMaskLength ? [...mask, 0] : mask;
    const routerData = options.badRouterLength ? [...router, 0] : router;
    const dnsData = options.badDnsLength ? [...dns.flat(), 0] : dns.flat();
    if (!options.omitMask) opts.push(1, maskData.length, ...maskData);
    if (!options.omitRouter) opts.push(3, routerData.length, ...routerData);
    if (!options.omitDns) opts.push(6, dnsData.length, ...dnsData);
    if (!options.missingLease) {
      const leaseData = [(lease >>> 24) & 255, (lease >>> 16) & 255, (lease >>> 8) & 255, lease & 255];
      if (options.badLeaseLength) leaseData.push(0);
      opts.push(51, leaseData.length, ...leaseData);
    }
  }
  opts.push(255);
  const udpLength = udp.length + bootp.length + opts.length;
  udp[4] = udpLength >> 8; udp[5] = udpLength & 255;
  const ipLength = ip.length + udpLength;
  ip[2] = ipLength >> 8; ip[3] = ipLength & 255;
  const ipSum = checksum(ip); ip[10] = ipSum >> 8; ip[11] = ipSum & 255;
  frame.push(...ip, ...udp, ...bootp, ...opts);
  if (options.badXid) frame[46] ^= 1;
  if (options.badChaddr) frame[70] ^= 1;
  if (options.badCookie) frame[278] ^= 1;
  if (options.badOptions) frame[frame.length - 1] = 54;
  const pseudo = [...serverIp, ...destinationIp, 0, 17,
    udpLength >> 8, udpLength & 255, ...frame.slice(34)];
  const udpSum = checksum(pseudo); frame[40] = udpSum >> 8; frame[41] = udpSum & 255;
  if (options.badUdpChecksum) frame[40] ^= 1;
  return frame;
}

function buildArpReply(request, options = {}) {
  const senderMac = options.mac || [0x02, 0, 0, 0, 0, 1];
  const senderIp = options.ip || request.slice(38, 42);
  const targetMac = request.slice(22, 28), targetIp = request.slice(28, 32);
  const reply = [...targetMac, ...senderMac, 8, 6, 0, 1, 8, 0, 6, 4, 0, 2,
    ...senderMac, ...senderIp, ...targetMac, ...targetIp, ...Array(18).fill(0)];
  if (options.badEtherSource) reply[6] ^= 1;
  if (options.foreignDestination) { reply.splice(0, 6, 2, 9, 9, 9, 9, 9); reply.splice(32, 6, 2, 9, 9, 9, 9, 9); }
  if (options.badOpcodeHigh) reply[20] = 1;
  return reply;
}

function buildArpRequest(targetMac, targetIp, options = {}) {
  const senderMac = options.requesterMac || [0x02, 0, 0, 0, 0, 2];
  const senderIp = options.requesterIp || [192, 168, 7, 2];
  return [...Array(6).fill(0xff), ...senderMac, 8, 6, 0, 1, 8, 0, 6, 4, 0, 1,
    ...senderMac, ...senderIp, ...Array(6).fill(0), ...targetIp, ...Array(18).fill(0)];
}

function icmpEchoRequest(frame) {
  if (frame.length < 42 || frame[12] !== 8 || frame[13] !== 0) return false;
  const ihl = (frame[14] & 15) * 4;
  return frame[14] >> 4 === 4 && ihl === 20 && frame[23] === 1 && frame[14 + ihl] === 8;
}

function udpDatagram(frame) {
  if (frame.length < 42 || frame[12] !== 8 || frame[13] !== 0) return null;
  const ip = frame.slice(14);
  if (ip[0] !== 0x45 || ip[9] !== 17 || checksum(ip.slice(0, 20))) return null;
  const total = (ip[2] << 8) | ip[3];
  if (total < 28 || total > 1500 || total > ip.length || (ip[6] & 0xbf) || ip[7]) return null;
  const udp = ip.slice(20, total), udpLength = (udp[4] << 8) | udp[5];
  if (udpLength !== udp.length || udpLength < 8) return null;
  if (udp[6] || udp[7]) {
    const pseudo = [...ip.slice(12, 20), 0, 17, udpLength >> 8, udpLength & 255, ...udp];
    if (checksum(pseudo)) return null;
  }
  return {
    etherSource: frame.slice(6, 12), source: ip.slice(12, 16), destination: ip.slice(16, 20),
    sourcePort: (udp[0] << 8) | udp[1], destinationPort: (udp[2] << 8) | udp[3],
    payload: udp.slice(8), ip: ip.slice(0, total),
  };
}

function buildUdpReply(request, options = {}) {
  const sourceMac = options.mac || request.etherSource.map((_, i) => i === 5 ? 44 : (i === 0 ? 2 : 0));
  const sourceIp = options.ip || request.destination;
  const destinationIp = request.source.slice();
  const payload = options.payload ? Array.from(options.payload) : request.payload.slice();
  if (options.corruptPayload && payload.length) payload[0] ^= 1;
  const sourcePort = options.sourcePort ?? request.destinationPort;
  const destinationPort = options.destinationPort ?? request.sourcePort;
  const udpLength = 8 + payload.length;
  const udp = [sourcePort >> 8, sourcePort & 255, destinationPort >> 8, destinationPort & 255,
    udpLength >> 8, udpLength & 255, 0, 0, ...payload];
  let udpSum = checksum([...sourceIp, ...destinationIp, 0, 17, udpLength >> 8, udpLength & 255, ...udp]);
  if (!udpSum) udpSum = 0xffff;
  udp[6] = udpSum >> 8; udp[7] = udpSum & 255;
  const total = 20 + udpLength;
  const ip = [0x45, 0, total >> 8, total & 255, 0x63, 0x21, 0x40, 0, options.ttl || 61,
    17, 0, 0, ...sourceIp, ...destinationIp];
  putChecksum(ip, 0, 20, 10);
  const reply = [...request.etherSource, ...sourceMac, 8, 0, ...ip, ...udp];
  if (options.foreignSource) { reply[26] ^= 1; putChecksum(reply, 14, 20, 24); }
  if (options.foreignDestination) { reply[30] ^= 1; putChecksum(reply, 14, 20, 24); }
  if (options.badIpChecksum) reply[24] ^= 1;
  if (options.badUdpChecksum) reply[40] ^= 1;
  if (options.udpLengthDelta) {
    const claimed = udpLength + options.udpLengthDelta;
    reply[38] = (claimed >> 8) & 255; reply[39] = claimed & 255;
    // A zero checksum remains legal for IPv4 and isolates length validation.
    reply[40] = 0; reply[41] = 0;
  }
  while (reply.length < 60) reply.push(0);
  return reply;
}

function tcpSegment(frame) {
  if (frame.length < 54 || frame[12] !== 8 || frame[13] !== 0) return null;
  const ip = frame.slice(14);
  if (ip[0] !== 0x45 || ip[9] !== 6 || checksum(ip.slice(0, 20))) return null;
  const total = (ip[2] << 8) | ip[3];
  if (total < 40 || total > 1500 || total > ip.length || (ip[6] & 0xbf) || ip[7]) return null;
  const tcp = ip.slice(20, total), headerLength = (tcp[12] >> 4) * 4;
  if (headerLength < 20 || headerLength > tcp.length || (tcp[12] & 15)) return null;
  const pseudo = [...ip.slice(12, 20), 0, 6, tcp.length >> 8, tcp.length & 255, ...tcp];
  if (checksum(pseudo)) return null;
  let mss = 0;
  for (let at = 20; at < headerLength;) {
    const kind = tcp[at];
    if (!kind) break;
    if (kind === 1) { at++; continue; }
    if (at + 1 >= headerLength || tcp[at + 1] < 2 || at + tcp[at + 1] > headerLength) return null;
    if (kind === 2 && tcp[at + 1] === 4) mss = (tcp[at + 2] << 8) | tcp[at + 3];
    at += tcp[at + 1];
  }
  const sourcePort = (tcp[0] << 8) | tcp[1];
  const destinationPort = (tcp[2] << 8) | tcp[3];
  if (!sourcePort || !destinationPort) return null;
  return {
    etherSource: frame.slice(6, 12), source: ip.slice(12, 16), destination: ip.slice(16, 20),
    sourcePort, destinationPort,
    sequence: ((tcp[4] * 0x1000000) + (tcp[5] << 16) + (tcp[6] << 8) + tcp[7]) >>> 0,
    acknowledgement: ((tcp[8] * 0x1000000) + (tcp[9] << 16) + (tcp[10] << 8) + tcp[11]) >>> 0,
    flags: tcp[13], window: (tcp[14] << 8) | tcp[15], mss,
    payload: tcp.slice(headerLength),
  };
}

function buildTcpReply(request, options = {}) {
  const sourceMac = options.mac || [2, 0, 0, 0, 0, 44];
  const sourceIp = options.ip || request.destination;
  const destinationIp = request.source;
  const payload = Array.from(options.payload || []);
  const tcp = [request.destinationPort >> 8, request.destinationPort & 255,
    request.sourcePort >> 8, request.sourcePort & 255];
  const sequence = options.sequence >>> 0, acknowledgement = options.acknowledgement >>> 0;
  tcp.push(sequence >>> 24, (sequence >>> 16) & 255, (sequence >>> 8) & 255, sequence & 255,
    acknowledgement >>> 24, (acknowledgement >>> 16) & 255,
    (acknowledgement >>> 8) & 255, acknowledgement & 255);
  const syn = options.flags & 2;
  tcp.push(syn ? 0x60 : 0x50, options.flags, (options.window ?? 4096) >> 8,
    (options.window ?? 4096) & 255, 0, 0, 0, 0);
  if (syn) tcp.push(2, 4, ((options.mss || 536) >> 8) & 255, (options.mss || 536) & 255);
  tcp.push(...payload);
  const tcpSum = checksum([...sourceIp, ...destinationIp, 0, 6,
    tcp.length >> 8, tcp.length & 255, ...tcp]);
  tcp[16] = tcpSum >> 8; tcp[17] = tcpSum & 255;
  const total = 20 + tcp.length;
  const ip = [0x45, 0, total >> 8, total & 255, 0x51, 0x11, 0x40, 0,
    options.ttl || 62, 6, 0, 0, ...sourceIp, ...destinationIp];
  putChecksum(ip, 0, 20, 10);
  const reply = [...request.etherSource, ...sourceMac, 8, 0, ...ip, ...tcp];
  while (reply.length < 60) reply.push(0);
  return reply;
}

function buildDnsReply(request, options = {}) {
  const query = request.payload;
  if (query.length < 17) return null;
  let cursor = 12;
  while (cursor < query.length && query[cursor]) {
    const size = query[cursor++];
    if (!size || size > 63 || cursor + size > query.length) return null;
    cursor += size;
  }
  if (cursor >= query.length || query[cursor] !== 0) return null;
  cursor++;
  if (cursor + 4 !== query.length || query[cursor] !== 0 || query[cursor + 1] !== 1 ||
      query[cursor + 2] !== 0 || query[cursor + 3] !== 1) return null;
  const question = query.slice(12, cursor + 4);
  const id = ((query[0] << 8) | query[1]) ^ (options.staleId ? 1 : 0);
  const rcode = options.nxdomain ? 3 : (options.rcode || 0);
  const prefixedAnswer = options.cnameBeforeAnswer || options.paddingBeforeAnswer;
  const answers = rcode || options.noAnswer ? 0 : (prefixedAnswer ? 2 : 1);
  const payload = [id >> 8, id & 255, 0x81, 0x80 | rcode, 0, 1, 0, answers, 0, 0, 0, 0,
    ...question];
  if (answers) {
    const address = options.address || [192, 168, 7, 44];
    if (options.cnameBeforeAnswer)
      payload.push(0xc0, 0x0c, 0, 5, 0, 1, 0, 0, 0, 60, 0, 2, 0xc0, 0x0c);
    if (options.paddingBeforeAnswer) {
      const size = options.paddingBeforeAnswer;
      payload.push(0xc0, 0x0c, 0, 16, 0, 1, 0, 0, 0, 60,
        (size >> 8) & 255, size & 255, ...Array(size).fill(0x41));
    }
    if (options.pointerLoop) {
      const answerOffset = payload.length;
      payload.push(0xc0 | ((answerOffset >> 8) & 0x3f), answerOffset & 255);
    } else if (options.pointerOob) payload.push(0xff, 0xff);
    else payload.push(0xc0, 0x0c);
    payload.push(0, options.cnameOnly ? 5 : 1, 0, 1, 0, 0, 0, 60,
      0, options.cnameOnly ? 2 : 4);
    if (options.cnameOnly) payload.push(0xc0, 0x0c); else payload.push(...address);
  }
  if (options.truncated) payload.splice(Math.max(12, payload.length - 3));
  return buildUdpReply(request, {
    payload,
    sourcePort: options.sourcePort ?? 53,
    destinationPort: options.destinationPort ?? request.sourcePort,
    badUdpChecksum: options.badChecksum,
    udpLengthDelta: options.udpLengthDelta,
  });
}

function buildNtpReply(request, options = {}) {
  if (request.payload.length !== 48) return null;
  const payload = Array(48).fill(0);
  const version = options.version ?? 4;
  const mode = options.modeValue ?? 4;
  const leap = options.leap ?? 0;
  payload[0] = ((leap & 3) << 6) | ((version & 7) << 3) | (mode & 7);
  payload[1] = options.stratum ?? 2;
  payload[2] = 6;
  payload[3] = 0xec;
  const cookie = request.payload.slice(40, 48);
  if (options.staleCookie) cookie[7] ^= 1;
  payload.splice(24, 8, ...cookie);
  const ntpSeconds = options.ntpSeconds ??
    ((options.unixSeconds ?? 1_735_732_799) + 2_208_988_800);
  if (!options.zeroTransmit) {
    payload[40] = (ntpSeconds >>> 24) & 255;
    payload[41] = (ntpSeconds >>> 16) & 255;
    payload[42] = (ntpSeconds >>> 8) & 255;
    payload[43] = ntpSeconds & 255;
    payload[44] = 0x80;
  }
  if (options.truncated) payload.splice(Math.max(0, options.truncateAt ?? 44));
  return buildUdpReply(request, {
    payload,
    sourcePort: options.sourcePort ?? 123,
    destinationPort: options.destinationPort ?? request.sourcePort,
    badUdpChecksum: options.badChecksum,
  });
}

function putChecksum(bytes, offset, length, field) {
  bytes[field] = 0; bytes[field + 1] = 0;
  const value = checksum(bytes.slice(offset, offset + length));
  bytes[field] = value >> 8; bytes[field + 1] = value & 255;
}

function buildIcmpReply(request, options = {}) {
  const ipLength = (request[16] << 8) | request[17];
  const icmpLength = ipLength - 20;
  const peerMac = options.mac || request.slice(0, 6);
  const peerIp = options.ip || request.slice(30, 34);
  const localMac = request.slice(6, 12), localIp = request.slice(26, 30);
  const icmp = request.slice(34, 34 + icmpLength);
  icmp[0] = 0;
  putChecksum(icmp, 0, icmp.length, 2);
  const ip = [0x45, 0, ipLength >> 8, ipLength & 255, 0x43, 0x21, 0x40, 0,
    options.ttl || 63, 1, 0, 0, ...peerIp, ...localIp];
  putChecksum(ip, 0, 20, 10);
  const frame = [...localMac, ...peerMac, 8, 0, ...ip, ...icmp];
  if (options.unrelated) frame[38] ^= 1;
  if (options.corruptPayload && icmpLength > 8) frame[42] ^= 1;
  if (options.unrelated || (options.corruptPayload && icmpLength > 8))
    putChecksum(frame, 34, icmpLength, 36);
  if (options.foreignSource) { frame[26] ^= 1; putChecksum(frame, 14, 20, 24); }
  if (options.foreignDestination) { frame[30] ^= 1; putChecksum(frame, 14, 20, 24); }
  if (options.badIcmpChecksum) frame[36] ^= 1;
  if (options.badIpChecksum) frame[24] ^= 1;
  while (frame.length < 60) frame.push(0);
  return frame;
}

function buildIcmpUnreachable(request, options = {}) {
  const routerMac = options.mac || request.slice(0, 6);
  const routerIp = options.routerIp || [192, 168, 7, 1];
  const localMac = request.slice(6, 12), localIp = request.slice(26, 30);
  const quote = request.slice(14, 42);
  const icmp = [3, options.code || 1, 0, 0, 0, 0, 0, 0, ...quote];
  putChecksum(icmp, 0, icmp.length, 2);
  const total = 20 + icmp.length;
  const ip = [0x45, 0, total >> 8, total & 255, 0x22, 0x22, 0x40, 0,
    64, 1, 0, 0, ...routerIp, ...localIp];
  putChecksum(ip, 0, 20, 10);
  const frame = [...localMac, ...routerMac, 8, 0, ...ip, ...icmp];
  if (options.unrelated) {
    frame[69] ^= 1; // low byte of the quoted Echo sequence
    putChecksum(frame, 34, icmp.length, 36);
  }
  return frame;
}

function buildIncomingEchoRequest(outgoing, options = {}) {
  const localMac = outgoing.slice(6, 12), peerMac = options.requesterMac || [2, 0, 0, 0, 0, 77];
  const localIp = outgoing.slice(26, 30), peerIp = options.requesterIp || [192, 168, 7, 77];
  const payload = [0xa5, 0x5a, 1];
  const icmp = [8, 0, 0, 0, 0x77, 0x77, 0, 1, ...payload];
  putChecksum(icmp, 0, icmp.length, 2);
  const total = 20 + icmp.length;
  const ip = [0x45, 0, total >> 8, total & 255, 0x11, 0x11, 0x40, 0,
    32, 1, 0, 0, ...peerIp, ...localIp];
  putChecksum(ip, 0, 20, 10);
  const frame = [...localMac, ...peerMac, 8, 0, ...ip, ...icmp];
  if (options.badIcmpChecksum) frame[36] ^= 1;
  while (frame.length < 60) frame.push(0);
  return frame;
}

function eepromWords(mac, base) {
  const words = new Uint16Array(64);
  words[0] = mac[0] | (mac[1] << 8);
  words[1] = mac[2] | (mac[3] << 8);
  words[2] = mac[4] | (mac[5] << 8);
  words[3] = 0x9550;
  words[7] = 0x6d50;
  words[8] = ((base - 0x200) >> 4) & 0x1f;
  words[9] = 0x3000;
  words[10] = words[0]; words[11] = words[1]; words[12] = words[2];
  words[13] = 0x0001;
  words[16] = 0x2083; words[18] = 0x0002; words[19] = 0x0001;
  words[20] = 0x0001;
  let high = 0, low = 0;
  for (let i = 0; i < 15; i++) {
    const x = (words[i] & 0xff) ^ (words[i] >> 8);
    if (i === 8 || i === 9 || i === 13) low ^= x; else high ^= x;
  }
  words[15] = low | (high << 8);
  high = 0; low = 0;
  for (const i of [16, 17, 18, ...Array.from({length: 32}, (_, n) => n + 32)])
    high ^= (words[i] & 0xff) ^ (words[i] >> 8);
  for (const i of [19, 20, 21, 22]) low ^= (words[i] & 0xff) ^ (words[i] >> 8);
  words[23] = low | (high << 8);
  return words;
}

class EtherLinkIII {
  constructor(scenario) {
    this.scenario = scenario;
    this.present = scenario.cardPresent !== false;
    this.slot = scenario.slot === 0 ? 0 : 1;
    this.base = scenario.base || 0x300;
    this.eepromBase = scenario.eepromBase || this.base;
    this.mac = Array.from(scenario.mac || DEFAULT_MAC);
    this.eeprom = eepromWords(this.mac, this.eepromBase);
    this.active = false;
    this.window = 0;
    this.rxEnabled = false; this.txEnabled = false; this.statsEnabled = false;
    this.station = [0, 0, 0, 0, 0, 0];
    this.mediaWritable = 0;
    this.netDiag = 0;
    this.rxFilter = 0;
    this.intrMask = 0; this.readZero = 0;
    this.rxEarly = 0x7fc; this.txAvailable = 0x7fc; this.txStart = 0x600;
    this.txStatus = [];
    this.txFifo = [];
    this.txExpected = 0;
    this.rxQueue = [];
    this.pendingInput = (scenario.rxFrames || []).map((f) => Array.from(f));
    this.transmitted = [];
    this.txRecords = [];
    this.rejected = [];
    this.link = scenario.link !== false;
    this.linkDelay = scenario.linkDelay || 0;
    this.linkReads = 0;
    this.idZeros = 0; this.idIndex = -1; this.idSelected = false;
    this.tagged = false; this.serialBits = [];
    this.wordWriteLow = new Map();
    this.wordReadHigh = new Map();
    this.dhcpDiscoverCount = 0; this.dhcpRequestCount = 0; this.dhcpReleaseCount = 0;
    this.arpRequestCount = 0;
    this.icmpRequestCount = 0;
    this.udpRequestCount = 0;
    this.dnsRequestCount = 0;
    this.ntpRequestCount = 0;
    this.tftpResponseCount = 0;
    this.tftpSession = null;
    this.tcpRequestCount = 0;
    this.tcpSynCount = 0;
    this.tcpDataCount = 0;
    this.tcpConnections = new Map();
    this.httpRequests = [];
    this.httpBytesSent = 0;
    // FTP mode (scenario.ftp): the control connection is a fixed port that
    // pushes an unsolicited banner on ESTABLISHED and answers a small verb
    // table; PASV self-announces a data port tracked the same way the TFTP
    // responder tracks its own TID. Both channels reuse respondTcp's SYN/ACK
    // and window-filling machinery via the onEstablished/onData/onFinSent
    // hooks below -- see respondFtp().
    this.ftpRequests = [];
    this.ftpUploadChunks = [];
    this.ftpDataPort = null;
    this.ftpControlConn = null;
    this.ftpPendingVerb = null;
    this.ftpControlOptions = null;
    this.ftpDataOptions = null;
    // Destination ports the client RST'd, in order. A channel the client
    // walks away from without an RST or a FIN simply never appears here,
    // which is what lets a scenario assert that a failed transfer actually
    // tore its data connection down instead of leaving it half-open.
    this.tcpResetPorts = [];
    // Peak bytes the server has sent but the client has not yet acknowledged:
    // the depth of the receive pipe, and the one number that says whether an
    // advertised window is actually keeping segments in flight.
    this.maxInFlight = 0;
    this.delayed = [];
    this.generated = [];
  }

  resetRuntime() {
    this.active = false; this.window = 0; this.rxEnabled = false; this.txEnabled = false;
    this.statsEnabled = false; this.mediaWritable = 0; this.netDiag = 0;
    this.rxFilter = 0; this.txStatus = []; this.txFifo = []; this.txExpected = 0;
    this.rxQueue = [];
    this.wordWriteLow.clear(); this.wordReadHigh.clear();
  }

  lfsr(index) {
    let v = 0xff;
    for (let i = 0; i < index; i++) v = ((v << 1) & 0xff) ^ ((v & 0x80) ? 0xcf : 0);
    return v;
  }

  idWrite(value) {
    if (!this.present) return;
    value &= 0xff;
    if (this.idIndex >= 0) {
      const want = this.lfsr(this.idIndex);
      if (value !== want) throw new Error(`bad ID sequence byte ${this.idIndex}: ${value.toString(16)} != ${want.toString(16)}`);
      if (++this.idIndex === 255) { this.idIndex = -1; this.idSelected = true; }
      return;
    }
    if (value === 0 && !this.tagged) {
      if (++this.idZeros === 2) { this.idZeros = 0; this.idIndex = 0; this.idSelected = false; }
      return;
    }
    this.idZeros = 0;
    if (!this.idSelected) throw new Error(`ID command without activation sequence: ${value.toString(16)}`);
    if (!this.tagged && value === 0xc0) { this.resetRuntime(); return; }
    if (value === 0xd0) { this.tagged = true; return; }
    if ((value & 0xc0) === 0x80) {
      const word = this.eeprom[value & 0x3f];
      this.serialBits = Array.from({length: 16}, (_, i) => (word >> (15 - i)) & 1);
      return;
    }
    if (value === 0xff) {
      this.base = this.eepromBase;
      this.active = true;
      return;
    }
    if ((value & 0xe0) === 0xe0) {
      this.base = 0x200 + ((value & 0x1f) << 4);
      this.active = true;
      return;
    }
    throw new Error(`unknown ID command ${value.toString(16)}`);
  }

  idRead() { return this.serialBits.length ? this.serialBits.shift() : 1; }

  linkUp() {
    const up = this.link && this.linkReads >= this.linkDelay;
    this.linkReads++;
    return up;
  }

  accepts(frame) {
    const dest = frame.slice(0, 6);
    const broadcast = dest.every((v) => v === 0xff);
    if (broadcast) return (this.rxFilter & 4) !== 0;
    return (this.rxFilter & 1) !== 0 && equal(dest, this.station);
  }

  deliverPending() {
    if (!this.rxEnabled) return;
    for (const frame of this.pendingInput.splice(0)) {
      if (this.accepts(frame)) this.rxQueue.push({frame, cursor: 0});
      else this.rejected.push(frame);
    }
  }

  command(word) {
    const op = word & 0xf800, param = word & 0x07ff;
    switch (op) {
      case 0x0000: this.resetRuntime(); break;
      case 0x0800: if (param > 6) throw new Error(`bad window ${param}`); this.window = param; break;
      case 0x1800: this.rxEnabled = false; break;
      case 0x2000: this.rxEnabled = true; this.deliverPending(); break;
      case 0x2800: this.rxEnabled = false; this.rxQueue = []; break;
      case 0x4000:
        if (!this.rxQueue.length) throw new Error('RX_DISCARD on empty queue');
        this.rxQueue.shift();
        break;
      case 0x4800: this.txEnabled = true; break;
      case 0x5000: this.txEnabled = false; break;
      case 0x5800: this.txEnabled = false; this.txFifo = []; this.txExpected = 0; this.txStatus = []; break;
      case 0x6800: break;
      case 0x7000: this.intrMask = param; break;
      case 0x7800: this.readZero = param; break;
      case 0x8000: this.rxFilter = param; this.deliverPending(); break;
      case 0x8800: this.rxEarly = param & 0x7fc; break;
      case 0x9000: this.txAvailable = param & 0x7fc; break;
      case 0x9800: this.txStart = param & 0x7fc; break;
      case 0xa800: this.statsEnabled = true; break;
      case 0xb000: this.statsEnabled = false; break;
      default: throw new Error(`unknown 3C509B command ${word.toString(16)}`);
    }
  }

  txByte(value) {
    if (this.window !== 1) throw new Error(`TX FIFO write in window ${this.window}`);
    this.txFifo.push(value & 0xff);
    if (this.txFifo.length === 2) {
      const len = (this.txFifo[0] | (this.txFifo[1] << 8)) & 0x7ff;
      this.txExpected = 4 + ((len + 3) & ~3);
    }
    if (this.txExpected && this.txFifo.length === this.txExpected) {
      if (!this.txEnabled) throw new Error('completed TX FIFO entry while transmitter disabled');
      const preamble = this.txFifo.slice(0, 4);
      const len = (preamble[0] | (preamble[1] << 8)) & 0x7ff;
      const frame = this.txFifo.slice(4, 4 + len);
      const dwordPad = this.txFifo.slice(4 + len);
      if (preamble[2] || preamble[3]) throw new Error(`non-zero TX preamble second word: ${hex(preamble)}`);
      if (dwordPad.some(Boolean)) throw new Error('non-zero TX DWORD padding');
      this.transmitted.push(frame);
      this.txRecords.push({preamble, dwordPad, frame});
      this.txStatus.push(0xc0);
      if (this.netDiag & 0xf000) this.rxQueue.push({frame: frame.slice(), cursor: 0});
      this.respond(frame);
      this.txFifo = []; this.txExpected = 0;
    }
  }

  respond(frame) {
    const dhcp = this.scenario.dhcp;
    const type = dhcpMessageType(frame);
    if (dhcp && type === 7) {
      this.dhcpReleaseCount++;
    }
    if (dhcp && (type === 1 || type === 3)) {
      const isDiscover = type === 1;
      const countKey = isDiscover ? 'dhcpDiscoverCount' : 'dhcpRequestCount';
      const dropKey = isDiscover ? 'dropDiscover' : 'dropRequest';
      this[countKey]++;
      if ((dhcp[dropKey] || 0) >= this[countKey] || dhcp.mode === 'drop') return;
      const replyType = isDiscover ? 2 : (dhcp.mode === 'nak' ? 6 : 5);
      const reply = buildDhcpReply(frame, replyType, dhcp);
      this.generated.push(reply);
      if (this.accepts(reply)) this.rxQueue.push({frame: reply, cursor: 0});
    }
    const arp = this.scenario.arp;
    if (arp && frame.length >= 42 && frame[12] === 8 && frame[13] === 6 && frame[20] === 0 && frame[21] === 1) {
      this.arpRequestCount++;
      if ((arp.drop || 0) >= this.arpRequestCount || arp.mode === 'drop') return;
      if (arp.requestBeforeReply && this.arpRequestCount === 1) {
        const incoming = buildArpRequest(frame.slice(22, 28), frame.slice(28, 32), arp);
        this.generated.push(incoming);
        if (this.accepts(incoming)) this.rxQueue.push({frame: incoming, cursor: 0});
      }
      const reply = buildArpReply(frame, arp);
      this.generated.push(reply);
      if (this.accepts(reply)) this.rxQueue.push({frame: reply, cursor: 0});
    }
    const icmp = this.scenario.icmp;
    if (icmp && icmpEchoRequest(frame)) {
      this.icmpRequestCount++;
      if ((icmp.drop || 0) >= this.icmpRequestCount || icmp.mode === 'drop') return;
      if (icmp.badRequestBeforeReply && this.icmpRequestCount === 1) {
        const incoming = buildIncomingEchoRequest(frame, {...icmp, badIcmpChecksum: true});
        this.generated.push(incoming);
        if (this.accepts(incoming)) this.rxQueue.push({frame: incoming, cursor: 0});
      }
      if (icmp.requestBeforeReply && this.icmpRequestCount === 1) {
        const incoming = buildIncomingEchoRequest(frame, icmp);
        this.generated.push(incoming);
        if (this.accepts(incoming)) this.rxQueue.push({frame: incoming, cursor: 0});
      }
      const replies = [];
      if (icmp.unrelatedBeforeReply) replies.push(buildIcmpReply(frame, {...icmp, unrelated: true}));
      if (icmp.foreignSourceBeforeReply) replies.push(buildIcmpReply(frame, {...icmp, foreignSource: true}));
      if (icmp.foreignDestinationBeforeReply) replies.push(buildIcmpReply(frame, {...icmp, foreignDestination: true}));
      if (icmp.badIpBeforeReply) replies.push(buildIcmpReply(frame, {...icmp, badIpChecksum: true}));
      if (icmp.badIcmpBeforeReply) replies.push(buildIcmpReply(frame, {...icmp, badIcmpChecksum: true}));
      if (icmp.corruptBeforeReply) replies.push(buildIcmpReply(frame, {...icmp, corruptPayload: true}));
      if (icmp.unrelatedUnreachableBeforeReply || icmp.onlyUnrelatedUnreachable)
        replies.push(buildIcmpUnreachable(frame, {...icmp, unrelated: true}));
      if (!icmp.onlyUnrelatedUnreachable) {
        if (icmp.mode === 'unreachable') replies.push(buildIcmpUnreachable(frame, icmp));
        else replies.push(buildIcmpReply(frame, icmp));
      }
      if (icmp.rxStatusBeforeReply) {
        const damaged = buildIcmpReply(frame, icmp);
        this.generated.push(damaged);
        if (this.accepts(damaged)) this.rxQueue.push({frame: damaged, cursor: 0, statusError: true});
      }
      for (const reply of replies) {
        this.generated.push(reply);
        if (!this.accepts(reply)) continue;
        if (icmp.delayPolls) this.delayed.push({polls: icmp.delayPolls, frame: reply});
        else this.rxQueue.push({frame: reply, cursor: 0});
      }
    }
    const tcp = tcpSegment(frame);
    if (this.scenario.tcp && tcp &&
        (!this.scenario.tcp.port || tcp.destinationPort === this.scenario.tcp.port))
      this.respondTcp(tcp, this.scenario.tcp);
    if (this.scenario.ftp && tcp) this.respondFtp(tcp);
    const datagram = udpDatagram(frame);
    const dnsScenario = this.scenario.dns;
    if (dnsScenario && datagram && datagram.destinationPort === 53) {
      this.dnsRequestCount = (this.dnsRequestCount || 0) + 1;
      const destination = datagram.destination.join('.');
      const dns = dnsScenario.servers && dnsScenario.servers[destination] ?
        {...dnsScenario, ...dnsScenario.servers[destination], servers: undefined} : dnsScenario;
      if ((dns.drop || 0) >= this.dnsRequestCount || dns.mode === 'drop') return;
      const replies = [];
      if (dns.staleBeforeReply) replies.push(buildDnsReply(datagram, {...dns, staleId: true}));
      if (dns.foreignPortBeforeReply) replies.push(buildDnsReply(datagram, {...dns, sourcePort: 54}));
      if (dns.badChecksumBeforeReply) replies.push(buildDnsReply(datagram, {...dns,
        address: dns.badChecksumAddress || dns.address, badChecksum: true}));
      if (dns.badLengthBeforeReply) replies.push(buildDnsReply(datagram, {...dns,
        address: dns.badLengthAddress || dns.address, udpLengthDelta: 1}));
      if (dns.malformedBeforeReply) replies.push(buildDnsReply(datagram, {...dns, pointerLoop: true}));
      replies.push(buildDnsReply(datagram, dns));
      for (const reply of replies.filter(Boolean)) {
        this.generated.push(reply);
        if (this.accepts(reply)) this.rxQueue.push({frame: reply, cursor: 0});
      }
    }
    const ntpScenario = this.scenario.ntp;
    if (ntpScenario && datagram && datagram.destinationPort === 123) {
      this.ntpRequestCount++;
      if ((ntpScenario.drop || 0) < this.ntpRequestCount && ntpScenario.mode !== 'drop') {
        const replies = [];
        if (ntpScenario.staleBeforeReply)
          replies.push(buildNtpReply(datagram, {...ntpScenario, staleCookie: true}));
        if (ntpScenario.foreignPortBeforeReply)
          replies.push(buildNtpReply(datagram, {...ntpScenario, sourcePort: 124}));
        if (ntpScenario.badChecksumBeforeReply)
          replies.push(buildNtpReply(datagram, {...ntpScenario, badChecksum: true}));
        replies.push(buildNtpReply(datagram, ntpScenario));
        for (const reply of replies.filter(Boolean)) {
          this.generated.push(reply);
          if (this.accepts(reply)) this.rxQueue.push({frame: reply, cursor: 0});
        }
      }
    }
    const tftp = this.scenario.tftp;
    if (tftp && datagram) this.respondTftp(datagram, tftp);
    const udpScenario = this.scenario.udp;
    if (udpScenario && datagram &&
        (!udpScenario.port || datagram.destinationPort === udpScenario.port)) {
      this.udpRequestCount++;
      if ((udpScenario.drop || 0) >= this.udpRequestCount || udpScenario.mode === 'drop') return;
      const replies = [];
      if (udpScenario.unrelatedBeforeReply)
        replies.push(buildUdpReply(datagram, {sourcePort: ((datagram.destinationPort + 1) & 0xffff) || 1}));
      if (udpScenario.foreignSourceBeforeReply)
        replies.push(buildUdpReply(datagram, {foreignSource: true}));
      if (udpScenario.foreignDestinationBeforeReply)
        replies.push(buildUdpReply(datagram, {foreignDestination: true}));
      if (udpScenario.badIpBeforeReply)
        replies.push(buildUdpReply(datagram, {badIpChecksum: true}));
      if (udpScenario.badUdpBeforeReply)
        replies.push(buildUdpReply(datagram, {badUdpChecksum: true}));
      if (udpScenario.corruptBeforeReply)
        replies.push(buildUdpReply(datagram, {corruptPayload: true}));
      if (udpScenario.requestBeforeReply) {
        const incoming = buildIncomingEchoRequest(frame, udpScenario);
        this.generated.push(incoming);
        if (this.accepts(incoming)) this.rxQueue.push({frame: incoming, cursor: 0});
      }
      if (udpScenario.arpBeforeReply) {
        const incoming = buildArpRequest(frame.slice(6, 12), frame.slice(26, 30), udpScenario);
        this.generated.push(incoming);
        if (this.accepts(incoming)) this.rxQueue.push({frame: incoming, cursor: 0});
      }
      if (udpScenario.mode === 'unreachable') {
        const unreachable = buildIcmpUnreachable(frame, udpScenario);
        if (udpScenario.unrelatedUnreachable) {
          unreachable[65] ^= 1;
          putChecksum(unreachable, 34, unreachable.length - 34, 36);
        }
        replies.push(unreachable);
      } else {
        replies.push(buildUdpReply(datagram, udpScenario));
      }
      if (udpScenario.duplicate) replies.push(replies[replies.length - 1].slice());
      for (const reply of replies) {
        this.generated.push(reply);
        if (!this.accepts(reply)) continue;
        if (udpScenario.delayPolls) this.delayed.push({polls: udpScenario.delayPolls, frame: reply});
        else this.rxQueue.push({frame: reply, cursor: 0});
      }
    }
  }

  respondTcp(segment, options) {
    this.tcpRequestCount++;
    const key = `${segment.source.join('.')}:${segment.sourcePort}/${segment.destinationPort}`;
    const queue = (reply) => {
      this.generated.push(reply);
      if (this.accepts(reply)) this.rxQueue.push({frame: reply, cursor: 0});
    };
    if (segment.flags & 4) {
      this.tcpResetPorts.push(segment.destinationPort);
      this.tcpConnections.delete(key);
      return;
    }
    if ((options.drop || 0) >= this.tcpRequestCount || options.mode === 'drop') return;
    if (segment.flags & 2) {
      this.tcpSynCount++;
      if ((options.dropSyn || 0) >= this.tcpSynCount) return;
      if (options.resetOnSyn && (options.resetAlways ||
          this.tcpSynCount === (options.resetOnSynAt || 1))) {
        queue(buildTcpReply(segment, {sequence: 0,
          acknowledgement: (segment.sequence + 1) >>> 0, flags: 0x14, window: 0,
          mac: options.mac, ip: options.ip}));
        return;
      }
      let connection = this.tcpConnections.get(key);
      if (!connection || connection.clientNext !== (segment.sequence + 1) >>> 0) {
        const ordinal = this.tcpConnections.size + 1;
        const serverIsn = ((options.serverIsn ?? 0x10203040) + ordinal * 0x10000) >>> 0;
        connection = {serverIsn, serverNext: (serverIsn + 1) >>> 0,
          serverAcked: (serverIsn + 1) >>> 0, clientNext: (segment.sequence + 1) >>> 0,
          sendQueue: Buffer.alloc(0), clientWindow: segment.window, established: false,
          advertisedWindow: options.zeroWindowProbes ? 0 : (options.window ?? 4096), finSent: false,
          httpRequest: Buffer.alloc(0), httpReady: false};
        this.tcpConnections.set(key, connection);
      }
      // Kept fresh on every segment so an out-of-band push (e.g. an FTP data
      // channel that must send unprompted once a command arrives on a wholly
      // different connection) can still address a reply without a fresh
      // triggering frame -- see drainConnectionSendQueue()/respondFtp().
      connection.lastSegment = segment;
      queue(buildTcpReply(segment, {sequence: connection.serverIsn, acknowledgement: connection.clientNext,
        flags: 0x12, window: connection.advertisedWindow,
        mss: options.mss || 536,
        mac: options.mac, ip: options.ip}));
      return;
    }
    const connection = this.tcpConnections.get(key);
    if (!connection) {
      queue(buildTcpReply(segment, {sequence: 0, acknowledgement: 0, flags: 4,
        window: 0, mac: options.mac, ip: options.ip}));
      return;
    }
    // A connection this respondTcp itself RST'd (options.abortAfterBytes) is
    // dead: no real peer answers anything further on it, including a client
    // frame that was already in flight when the RST went out. Without this,
    // a data burst queued ahead of the abort point kept draining across a
    // later trigger as if the RST had never happened.
    if (connection.aborted) return;
    connection.lastSegment = segment;
    connection.clientWindow = segment.window;
    if (segment.flags & 0x10) {
      const acknowledged = (segment.acknowledgement - connection.serverAcked) >>> 0;
      const outstanding = (connection.serverNext - connection.serverAcked) >>> 0;
      if (acknowledged <= outstanding) connection.serverAcked = segment.acknowledgement;
    }
    if (!connection.established && !segment.payload.length && !(segment.flags & 1) &&
        segment.acknowledgement === connection.serverNext) {
      connection.established = true;
      // FTP's control channel pushes an unsolicited "220 ..." banner the
      // instant the connection comes up, with no request to react to; other
      // callers never set this, so the early return below is unchanged for
      // them.
      if (options.onEstablished) options.onEstablished(connection);
      if (!connection.sendQueue.length) return;
    }
    if (segment.payload.length && options.zeroWindowProbes &&
        segment.sequence === (connection.clientNext - 1) >>> 0) {
      connection.probes = (connection.probes || 0) + 1;
      if (connection.probes >= options.zeroWindowProbes)
        connection.advertisedWindow = options.window ?? 4096;
      queue(buildTcpReply(segment, {sequence: connection.serverNext,
        acknowledgement: connection.clientNext, flags: 0x10,
        window: connection.advertisedWindow, mac: options.mac, ip: options.ip}));
      return;
    }
    if (segment.payload.length) {
      this.tcpDataCount++;
      if (options.resetOnData && (options.resetAlways ||
          this.tcpDataCount === (options.resetOnDataAt || 1))) {
        queue(buildTcpReply(segment, {sequence: connection.serverNext,
          acknowledgement: connection.clientNext, flags: 0x14, window: 0,
          mac: options.mac, ip: options.ip}));
        return;
      }
      if (segment.sequence !== connection.clientNext) {
        queue(buildTcpReply(segment, {sequence: connection.serverNext,
          acknowledgement: connection.clientNext, flags: 0x10, window: connection.advertisedWindow,
          mac: options.mac, ip: options.ip}));
        return;
      }
      connection.clientNext = (connection.clientNext + segment.payload.length) >>> 0;
      if (options.onData) {
        // FTP mode owns both directions of the connection itself (command
        // parsing on control, upload capture on data), so it replaces the
        // generic http/echo handling below rather than adding to it.
        options.onData(connection, Buffer.from(segment.payload));
      } else if (options.mode === 'http') {
        connection.httpRequest = Buffer.concat([connection.httpRequest, Buffer.from(segment.payload)]);
        if (!connection.httpReady && connection.httpRequest.includes(Buffer.from('\r\n\r\n'))) {
          connection.httpReady = true;
          const request = connection.httpRequest.toString('latin1');
          this.httpRequests.push(request);
          const requestLine = request.split('\r\n', 1)[0].split(' ');
          const target = requestLine.length >= 2 ? requestLine[1] : '';
          let response = options.responses && Object.prototype.hasOwnProperty.call(options.responses, target) ?
            options.responses[target] : options.response;
          if (Array.isArray(response)) response = response.shift();
          if (response && typeof response === 'object' && !Buffer.isBuffer(response)) {
            if (response.raw !== undefined) response = response.raw;
            else {
              const body = Buffer.isBuffer(response.body) ? response.body :
                Buffer.from(response.body || '', 'latin1');
              const headers = {...(response.headers || {})};
              if (!response.closeDelimited && !Object.keys(headers).some((name) =>
                  name.toLowerCase() === 'content-length')) headers['Content-Length'] = body.length;
              response = Buffer.concat([Buffer.from(`HTTP/1.0 ${response.status || '200 OK'}\r\n` +
                Object.entries(headers).map(([name, value]) => `${name}: ${value}\r\n`).join('') +
                '\r\n', 'latin1'), body]);
            }
          }
          if (response === undefined) response = 'HTTP/1.0 404 Not Found\r\nContent-Length: 0\r\n\r\n';
          connection.sendQueue = Buffer.isBuffer(response) ? Buffer.from(response) :
            Buffer.from(response, 'latin1');
        }
      } else {
        connection.sendQueue = Buffer.concat([connection.sendQueue, Buffer.from(segment.payload)]);
      }
      if ((options.dropDataResponses || 0) >= this.tcpDataCount) return;
      if (options.outOfSequenceRstBeforeData && !connection.badRstSent) {
        connection.badRstSent = true;
        queue(buildTcpReply(segment, {sequence: (connection.serverNext + 1) >>> 0,
          acknowledgement: connection.clientNext, flags: 0x14, window: 0,
          mac: options.mac, ip: options.ip}));
      }
    }
    if (segment.flags & 1) {
      connection.clientNext = (connection.clientNext + 1) >>> 0;
      if (options.ackOnlyClose && !connection.finSent) {
        queue(buildTcpReply(segment, {sequence: connection.serverNext,
          acknowledgement: connection.clientNext, flags: 0x10,
          window: connection.advertisedWindow, mac: options.mac, ip: options.ip}));
        return;
      }
      if (options.splitClose && !connection.finSent) {
        queue(buildTcpReply(segment, {sequence: connection.serverNext,
          acknowledgement: connection.clientNext, flags: 0x10,
          window: connection.advertisedWindow, mac: options.mac, ip: options.ip}));
        queue(buildTcpReply(segment, {sequence: connection.serverNext,
          acknowledgement: connection.clientNext, flags: 0x11,
          window: connection.advertisedWindow, mac: options.mac, ip: options.ip}));
        connection.finSent = true;
        connection.serverNext = (connection.serverNext + 1) >>> 0;
        return;
      }
      queue(buildTcpReply(segment, {sequence: connection.serverNext,
        acknowledgement: connection.clientNext, flags: connection.finSent ? 0x10 : 0x11,
        window: connection.advertisedWindow,
        mac: options.mac, ip: options.ip}));
      if (!connection.finSent) {
        connection.finSent = true;
        connection.serverNext = (connection.serverNext + 1) >>> 0;
        // FTP's STOR completes this way: the client closes the data channel
        // once its upload is done, and that close is the cue to send "226"
        // on the (separate) control connection.
        if (options.onFinSent) options.onFinSent(connection);
      }
      return;
    }
    const sentAny = this.drainConnectionSendQueue(connection, segment, options);
    if (!sentAny && segment.payload.length) {
      queue(buildTcpReply(segment, {sequence: connection.serverNext,
        acknowledgement: connection.clientNext, flags: 0x10, window: connection.advertisedWindow,
        mac: options.mac, ip: options.ip}));
    }
  }

  // Keep sending while the window the client advertised still has room, the
  // way a real server does. Replying with a single segment per received
  // frame made the model a strict stop-and-wait pipe, so no receive-window
  // change could ever show up in a measurement taken here. `template` only
  // supplies addressing (ports/IPs/ether source): it need not be the frame
  // that triggered this call, which is what lets an out-of-band FTP command
  // (arriving on a different connection entirely) drain a data channel's
  // queue using that channel's own last-seen segment as the template.
  drainConnectionSendQueue(connection, template, options) {
    const queue = (reply) => {
      this.generated.push(reply);
      if (this.accepts(reply)) this.rxQueue.push({frame: reply, cursor: 0});
    };
    let sentAny = false;
    for (;;) {
      const inFlight = (connection.serverNext - connection.serverAcked) >>> 0;
      const available = Math.max(0, connection.clientWindow - inFlight);
      if (!connection.sendQueue.length || !available) break;
      const size = Math.min(options.responseChunkSize || options.mss || 536,
        available, connection.sendQueue.length);
      sentAny = true;
      const payload = connection.sendQueue.subarray(0, size);
      connection.sendQueue = connection.sendQueue.subarray(size);
      if (options.outOfOrderBeforeData && !connection.outOfOrderSent) {
        connection.outOfOrderSent = true;
        queue(buildTcpReply(template, {sequence: (connection.serverNext + payload.length) >>> 0,
          acknowledgement: connection.clientNext, flags: 0x18, payload,
          window: options.window ?? 4096, mac: options.mac, ip: options.ip}));
      }
      const remoteFin = !connection.finSent &&
        ((options.mode === 'http' && !options.keepOpen && connection.httpReady &&
          connection.sendQueue.length === 0) ||
         (options.finWhenDrained && connection.sendQueue.length === 0) ||
         options.remoteFinAfterData);
      const reply = buildTcpReply(template, {sequence: connection.serverNext,
        acknowledgement: connection.clientNext, flags: remoteFin ? 0x19 : 0x18, payload,
        window: connection.advertisedWindow, mac: options.mac, ip: options.ip});
      queue(reply);
      if (options.mode === 'http') this.httpBytesSent += size;
      if (options.duplicateData) queue(reply.slice());
      if (options.outOfOrderFinAfterData && !connection.badFinSent) {
        connection.badFinSent = true;
        queue(buildTcpReply(template, {sequence: (connection.serverNext + size + 1) >>> 0,
          acknowledgement: connection.clientNext, flags: 0x11,
          window: connection.advertisedWindow, mac: options.mac, ip: options.ip}));
      }
      connection.serverNext = (connection.serverNext + size + (remoteFin ? 1 : 0)) >>> 0;
      if (remoteFin) {
        connection.finSent = true;
        if (options.onFinSent) options.onFinSent(connection);
      }
      if (options.mode === 'ftpData') this.ftpDataBytesSent = (this.ftpDataBytesSent || 0) + size;
      this.maxInFlight = Math.max(this.maxInFlight,
        (connection.serverNext - connection.serverAcked) >>> 0);
      if (options.abortAfterBytes !== undefined || options.stallAfterBytes !== undefined) {
        connection.bytesSent = (connection.bytesSent || 0) + size;
        const threshold = options.abortAfterBytes ?? options.stallAfterBytes;
        if (connection.bytesSent >= threshold && !connection.aborted) {
          connection.aborted = true;
          if (options.abortAfterBytes !== undefined) {
            queue(buildTcpReply(template, {sequence: connection.serverNext,
              acknowledgement: connection.clientNext, flags: 0x04, window: 0,
              mac: options.mac, ip: options.ip}));
          } else {
            // Silence, no RST: the remainder of the queue is simply dropped,
            // so the peer's own idle-receive timeout is what has to notice
            // and fail the transfer -- unlike an RST, this has only one
            // sane interpretation on the client side.
            connection.sendQueue = Buffer.alloc(0);
          }
          break;
        }
      }
    }
    return sentAny;
  }

  // ------------------------------------------------------------------
  // FTP mode (scenario.ftp): a fixed control port plus a self-announced
  // data port picked on PASV, the same "own the dynamic endpoint" pattern
  // as the TFTP responder's server TID. Both channels are ordinary
  // respondTcp connections; FTP semantics hook in via onEstablished (push
  // the unsolicited 220 banner / a RETR-LIST fixture), onData (parse
  // control-channel command lines / capture a STOR upload) and onFinSent
  // (queue "226 Transfer complete" once a data channel closes), so the
  // handshake and window-filling machinery above is reused rather than
  // reimplemented.
  // ------------------------------------------------------------------

  respondFtp(segment) {
    const ftp = this.scenario.ftp;
    const controlPort = ftp.port || 21;
    if (segment.destinationPort === controlPort) {
      if (!this.ftpControlOptions) this.ftpControlOptions = this.buildFtpControlOptions(ftp);
      this.respondTcp(segment, this.ftpControlOptions);
      return;
    }
    if (this.ftpDataPort && segment.destinationPort === this.ftpDataPort) {
      if (!this.ftpDataOptions) this.ftpDataOptions = this.buildFtpDataOptions(ftp);
      this.respondTcp(segment, this.ftpDataOptions);
    }
  }

  buildFtpControlOptions(ftp) {
    return {
      mac: ftp.mac, ip: ftp.ip, window: ftp.controlWindow ?? 4096,
      onEstablished: (connection) => {
        this.ftpControlConn = connection;
        if (ftp.suppressBanner) return;
        const banner = ftp.banner || '220 Test FTP server ready.\r\n';
        connection.sendQueue = Buffer.concat([connection.sendQueue, Buffer.from(banner, 'latin1')]);
      },
      onData: (connection, payload) => this.handleFtpControlData(connection, payload, ftp),
    };
  }

  buildFtpDataOptions(ftp) {
    return {
      mac: ftp.mac, ip: ftp.ip, window: ftp.dataWindow ?? 4096, mss: ftp.mss || 536,
      responseChunkSize: ftp.responseChunkSize,
      mode: 'ftpData',
      finWhenDrained: true,
      abortAfterBytes: ftp.dataAbortAfterBytes,
      stallAfterBytes: ftp.dataStallAfterBytes,
      onEstablished: (connection) => {
        // Normally beaten to it by pushFtpDataIfReady() below, since RETR/LIST
        // arrives on the control channel only after this data channel's own
        // handshake has already completed. Kept as a fallback for the
        // reverse ordering.
        const pending = this.ftpPendingVerb;
        if (!pending || pending.verb === 'STOR') return;
        connection.sendQueue = Buffer.concat([connection.sendQueue, this.resolveFtpFixture(pending, ftp)]);
      },
      onData: (connection, payload) => {
        this.ftpUploadChunks.push(payload);
        connection.bytesReceived = (connection.bytesReceived || 0) + payload.length;
        if (ftp.dataAbortAfterBytes !== undefined &&
            connection.bytesReceived >= ftp.dataAbortAfterBytes && !connection.aborted) {
          connection.aborted = true;
          const template = connection.lastSegment;
          const rst = buildTcpReply(template, {sequence: connection.serverNext,
            acknowledgement: connection.clientNext, flags: 0x04, window: 0,
            mac: ftp.mac, ip: ftp.ip});
          this.generated.push(rst);
          if (this.accepts(rst)) this.rxQueue.push({frame: rst, cursor: 0});
        }
      },
      onFinSent: () => {
        if (ftp.suppress226) return;
        this.sendFtpControlReply('226 Transfer complete.\r\n');
      },
    };
  }

  resolveFtpFixture(pending, ftp) {
    if (pending.verb === 'LIST') {
      const listing = ftp.listing !== undefined ? ftp.listing : '';
      return Buffer.isBuffer(listing) ? listing : Buffer.from(listing, 'latin1');
    }
    const fixtures = ftp.fixtures || {};
    const key = Object.keys(fixtures).find((name) => name.toUpperCase() === pending.arg.toUpperCase());
    const data = key === undefined ? Buffer.alloc(0) : fixtures[key];
    return Buffer.isBuffer(data) ? data : Buffer.from(data);
  }

  sendFtpControlReply(text) {
    const connection = this.ftpControlConn;
    if (!connection) return;
    connection.sendQueue = Buffer.concat([connection.sendQueue, Buffer.from(text, 'latin1')]);
    this.drainConnectionSendQueue(connection, connection.lastSegment, this.ftpControlOptions);
  }

  // Once RETR/LIST is accepted, the data channel's handshake has already
  // completed (ftp.asm opens it, then optionally REST, before sending the
  // verb), so push straight into that connection's queue instead of waiting
  // for a triggering frame that will never come on an otherwise-idle
  // download channel.
  pushFtpDataIfReady(ftp) {
    if (!this.ftpDataPort || !this.ftpPendingVerb) return;
    for (const [key, connection] of this.tcpConnections) {
      if (!key.endsWith(`/${this.ftpDataPort}`)) continue;
      if (!connection.established) return;
      connection.sendQueue = Buffer.concat([connection.sendQueue, this.resolveFtpFixture(this.ftpPendingVerb, ftp)]);
      if (!this.ftpDataOptions) this.ftpDataOptions = this.buildFtpDataOptions(ftp);
      this.drainConnectionSendQueue(connection, connection.lastSegment, this.ftpDataOptions);
      return;
    }
  }

  handleFtpControlData(connection, payload, ftp) {
    connection.ftpAccum = Buffer.concat([connection.ftpAccum || Buffer.alloc(0), payload]);
    for (;;) {
      const idx = connection.ftpAccum.indexOf('\r\n', 0, 'latin1');
      if (idx < 0) break;
      const line = connection.ftpAccum.slice(0, idx).toString('latin1');
      connection.ftpAccum = connection.ftpAccum.slice(idx + 2);
      this.ftpRequests.push(line);
      const reply = this.computeFtpReply(line, ftp, connection);
      if (reply) connection.sendQueue = Buffer.concat([connection.sendQueue, Buffer.from(reply, 'latin1')]);
      if (this.ftpPendingVerb && this.ftpPendingVerb.needsPush) {
        this.ftpPendingVerb.needsPush = false;
        this.pushFtpDataIfReady(ftp);
      }
    }
  }

  computeFtpReply(line, ftp, connection) {
    const spaceAt = line.indexOf(' ');
    const verb = (spaceAt < 0 ? line : line.slice(0, spaceAt)).toUpperCase();
    const arg = spaceAt < 0 ? '' : line.slice(spaceAt + 1);
    const refused = new Set((ftp.refuseVerbs || []).map((v) => v.toUpperCase()));
    switch (verb) {
      case 'USER':
        return `${ftp.userReply ?? 331} User ${arg} OK, need password.\r\n`;
      case 'PASS':
        if (ftp.refusePass) return '530 Login incorrect.\r\n';
        return `${ftp.passReply ?? 230} Login successful.\r\n`;
      case 'TYPE':
        return '200 Type set to I.\r\n';
      case 'SIZE': {
        if (ftp.refuseSize) return '550 Could not get file size.\r\n';
        const sizes = ftp.fixtureSizes || {};
        const known = Object.keys(sizes).find((n) => n.toUpperCase() === arg.toUpperCase());
        const n = known !== undefined ? sizes[known] : (ftp.sizeBytes ?? 0);
        return `213 ${n}\r\n`;
      }
      case 'PASV': {
        if (ftp.pasvGarbled) return '227 Not really passive.\r\n';
        this.ftpDataPort = ftp.dataPort || (30000 + (this.ftpPasvCount = (this.ftpPasvCount || 0) + 1));
        // Reusing the control host as the data host (the simplest legal PASV
        // reply, and the one every fixture below relies on) keeps the data
        // channel on the same routable subnet as the control channel without
        // requiring a gateway in the scenario's NET_GW config.
        const ip = ftp.dataIp || (connection.lastSegment ? Array.from(connection.lastSegment.destination) : [127, 0, 0, 1]);
        const p = this.ftpDataPort;
        return `227 Entering Passive Mode (${ip[0]},${ip[1]},${ip[2]},${ip[3]},${(p >> 8) & 255},${p & 255}).\r\n`;
      }
      case 'REST':
        if (ftp.restRefused) return '502 REST not supported.\r\n';
        return `350 Restarting at ${arg}.\r\n`;
      case 'RETR':
      case 'STOR':
      case 'LIST': {
        const refusedNow = refused.has(verb) || (verb === 'RETR' && ftp.refuseRetr) ||
          (verb === 'STOR' && ftp.refuseStor) || (verb === 'LIST' && ftp.refuseList);
        if (refusedNow) return '550 Failed.\r\n';
        // Deferred to handleFtpControlData, once this "150" text is actually
        // queued: pushing the data-channel fixture from here can complete a
        // small transfer (and its "226") synchronously, before the caller
        // has appended this very reply -- sending 226 ahead of 150 on the
        // wire, which no real server does even though ftp.asm's reader
        // tolerates whatever order replies arrive in.
        this.ftpPendingVerb = {verb, arg, needsPush: verb !== 'STOR'};
        return '150 Opening data connection.\r\n';
      }
      case 'QUIT':
        return '221 Goodbye.\r\n';
      default:
        return '500 Unknown command.\r\n';
    }
  }

  respondTftp(datagram, tftp) {
    const payload = datagram.payload, opcode = payload.length >= 2 ? (payload[0] << 8) | payload[1] : 0;
    const requestPorts = new Set([tftp.port || 69, ...(tftp.extraPorts || [6969])]);
    const serverTid = tftp.serverTid ?? 0xbeef;
    const isTftpPacket = requestPorts.has(datagram.destinationPort) ||
      datagram.destinationPort === serverTid;
    if (!isTftpPacket) return;
    this.tftpPacketCount = (this.tftpPacketCount || 0) + 1;
    if ((tftp.dropPackets || 0) >= this.tftpPacketCount ||
        (tftp.dropPacketNumbers || []).includes(this.tftpPacketCount)) return;
    const remoteFiles = tftp.files || {};
    const findFile = (name) => {
      const key = Object.keys(remoteFiles).find((candidate) => candidate.toUpperCase() === name.toUpperCase());
      return key === undefined ? null : (Buffer.isBuffer(remoteFiles[key]) ? remoteFiles[key] : Buffer.from(remoteFiles[key]));
    };
    const packet = (port, body) => buildUdpReply(datagram, {sourcePort: port, payload: body,
      mac: tftp.mac || [2,0,0,0,0,44], ip: tftp.ip || datagram.destination});
    const queue = (body, port = serverTid, options = {}) => {
      const reply = packet(port, body);
      if (options.badChecksum) reply[40] ^= 1;
      this.generated.push(reply);
      if (this.accepts(reply)) this.rxQueue.push({frame: reply, cursor: 0});
    };
    const emit = (body, port = serverTid) => {
      this.tftpResponseCount++;
      if ((tftp.dropResponses || 0) >= this.tftpResponseCount ||
          (tftp.dropResponseNumbers || []).includes(this.tftpResponseCount)) return;
      if (tftp.badChecksum && this.tftpResponseCount === 1)
        queue(body, port, {badChecksum: true});
      if (tftp.unknownTidMalformed && this.tftpResponseCount ===
          (tftp.unknownTidMalformedAt ?? 2))
        queue([0], ((serverTid + 1) & 0xffff) || 1);
      else if (tftp.unknownTid && this.tftpResponseCount === 2)
        queue(body, ((serverTid + 1) & 0xffff) || 1);
      queue(body, port);
      if (tftp.duplicate) queue(body, port);
    };
    const parseRequest = () => {
      let end = payload.indexOf(0, 2);
      if (end < 0) return null;
      return Buffer.from(payload.slice(2, end)).toString('ascii');
    };
    const dataPacket = (session, block) => {
      const start = (block - 1) * session.blockSize;
      const data = start <= session.file.length ? session.file.subarray(start, start + session.blockSize) : Buffer.alloc(0);
      if (data.length < session.blockSize) session.finalBlock = block;
      return [0, 3, (block >> 8) & 255, block & 255, ...data];
    };
    if ((opcode === 1 || opcode === 2) && requestPorts.has(datagram.destinationPort)) {
      const name = parseRequest();
      if (!name) return;
      if (tftp.error) {
        const message = Buffer.from(tftp.error.message || 'Remote error', 'ascii');
        emit([0,5,0,tftp.error.code || 1,...message,0]);
        return;
      }
      const blockSize = tftp.fallback ? 512 : (tftp.blockSize || 1428);
      if (opcode === 1) {
        const file = findFile(name);
        if (file === null) { emit([0,5,0,1,...Buffer.from('File not found'),0]); return; }
        this.tftpSession = {mode: 'get', name, file, blockSize, clientPort: datagram.sourcePort};
        if (tftp.oversizedOack) emit([0,6,...Buffer.from('blksize'),0,...Buffer.from('1429'),0]);
        else if (!tftp.fallback) emit([0,6,...Buffer.from('blksize'),0,...Buffer.from(String(blockSize)),0]);
        else emit(dataPacket(this.tftpSession, 1));
      } else {
        this.tftpSession = {mode: 'put', name, chunks: [], expected: 1, blockSize,
          clientPort: datagram.sourcePort};
        if (tftp.oversizedOack) emit([0,6,...Buffer.from('blksize'),0,...Buffer.from('1429'),0]);
        else if (!tftp.fallback) emit([0,6,...Buffer.from('blksize'),0,...Buffer.from(String(blockSize)),0]);
        else emit([0,4,0,0]);
      }
      return;
    }
    const session = this.tftpSession;
    if (!session || datagram.destinationPort !== serverTid) return;
    if (opcode === 4 && session.mode === 'get' && payload.length === 4) {
      const ack = (payload[2] << 8) | payload[3];
      if (session.finalBlock === ack) {
        if (tftp.unknownTidDally) queue([0], ((serverTid + 1) & 0xffff) || 1);
        return;
      }
      if (tftp.reorder && !session.reordered) {
        session.reordered = true;
        queue(dataPacket(session, (ack + 2) & 0xffff));
      }
      emit(dataPacket(session, (ack + 1) & 0xffff));
      return;
    }
    if (opcode === 3 && session.mode === 'put' && payload.length >= 4) {
      const block = (payload[2] << 8) | payload[3], data = Buffer.from(payload.slice(4));
      if (block === session.expected) {
        session.chunks.push(data); session.expected = (session.expected + 1) & 0xffff;
        if (data.length < session.blockSize) {
          if (!tftp.uploads) tftp.uploads = {};
          tftp.uploads[session.name] = Buffer.concat(session.chunks);
        }
      }
      emit([0,4,payload[2],payload[3]]);
    }
  }

  advanceDelayed() {
    const ready = [];
    for (const item of this.delayed) {
      if (--item.polls <= 0) ready.push(item);
    }
    this.delayed = this.delayed.filter((item) => item.polls > 0);
    for (const item of ready) this.rxQueue.push({frame: item.frame, cursor: 0});
  }

  rxByte() {
    if (this.window !== 1) throw new Error(`RX FIFO read in window ${this.window}`);
    if (!this.rxQueue.length) throw new Error('RX FIFO read on empty queue');
    const q = this.rxQueue[0];
    const value = q.cursor < q.frame.length ? q.frame[q.cursor] : 0;
    q.cursor++;
    return value;
  }

  readWord(offset) {
    if (offset === 0x0e) return (this.window << 13);
    switch (this.window) {
      case 0:
        if (offset === 0x00) return 0x6d50;
        if (offset === 0x02) return 0x9550;
        if (offset === 0x0a) return 0;
        if (offset === 0x0c) return 0;
        break;
      case 1:
        if (offset === 0x08) {
          this.advanceDelayed();
          return this.rxQueue.length ? this.rxQueue[0].frame.length |
            (this.rxQueue[0].statusError ? 0x4000 : 0) : 0;
        }
        if (offset === 0x0c) return 0x2000;
        break;
      case 2:
        if (offset >= 0 && offset < 6 && !(offset & 1)) return this.station[offset] | (this.station[offset + 1] << 8);
        break;
      case 4:
        if (offset === 0x04) return 0;
        if (offset === 0x06) return this.netDiag | 0x0004 | (this.txEnabled ? 0x0800 : 0) | (this.rxEnabled ? 0x0400 : 0);
        if (offset === 0x0a) {
          const link = (this.mediaWritable & 0x80) && this.linkUp();
          return 0xa000 | this.mediaWritable | (link ? 0x0800 : 0);
        }
        break;
      case 5:
        if (offset === 0x00) return this.txStart;
        if (offset === 0x02) return this.txAvailable;
        if (offset === 0x06) return this.rxEarly;
        if (offset === 0x08) return this.rxFilter;
        if (offset === 0x0a) return this.intrMask;
        if (offset === 0x0c) return this.readZero;
        break;
    }
    return 0;
  }

  writeWord(offset, value) {
    if (offset === 0x0e) return this.command(value);
    switch (this.window) {
      case 4:
        if (offset === 0x06) { this.netDiag = value & 0xf000; return; }
        if (offset === 0x0a) { this.mediaWritable = value & 0x00cc; return; }
        if (offset === 0x04) return;
        break;
    }
    throw new Error(`unknown word write w${this.window}+${offset.toString(16)}=${value.toString(16)}`);
  }

  readByte(offset) {
    if (!this.active) return 0xff;
    if (this.window === 1 && offset === 0) return this.rxByte();
    if (this.window === 1 && offset > 0 && offset < 4) throw new Error(`wrong RX FIFO offset ${offset}`);
    if (this.window === 1 && offset === 0x0b) return this.txStatus[0] || 0;
    if (this.window === 2 && offset < 6) return this.station[offset];
    if (this.window === 6 && offset < 14) return 0;
    if (offset & 1) {
      const even = offset - 1;
      if (!this.wordReadHigh.has(even)) throw new Error(`high byte read without low byte at ${offset.toString(16)}`);
      const high = this.wordReadHigh.get(even); this.wordReadHigh.delete(even);
      return high;
    }
    const word = this.readWord(offset);
    this.wordReadHigh.set(offset, (word >> 8) & 0xff);
    return word & 0xff;
  }

  writeByte(offset, value) {
    if (!this.active) return;
    if (this.window === 1 && offset === 0) return this.txByte(value);
    if (this.window === 1 && offset > 0 && offset < 4) throw new Error(`wrong TX FIFO offset ${offset}`);
    if (this.window === 1 && offset === 0x0b) { if (this.txStatus.length) this.txStatus.shift(); return; }
    if (this.window === 2 && offset < 6) { this.station[offset] = value & 0xff; return; }
    if (offset & 1) {
      const even = offset - 1;
      if (!this.wordWriteLow.has(even)) throw new Error(`high byte write without low byte at ${offset.toString(16)}`);
      const low = this.wordWriteLow.get(even); this.wordWriteLow.delete(even);
      return this.writeWord(even, low | ((value & 0xff) << 8));
    }
    this.wordWriteLow.set(offset, value & 0xff);
  }
}

function normalizeFrame(frame) {
  if (typeof frame === 'string') return Array.from(Buffer.from(frame.replace(/[^0-9a-f]/gi, ''), 'hex'));
  return Array.from(frame);
}

function runExe(exePath, args = '', inputScenario = {}) {
  const scenario = {...inputScenario};
  scenario.rxFrames = (scenario.rxFrames || []).map(normalizeFrame);
  const exe = fs.readFileSync(exePath);
  if (exe.length <= 128 || exe.toString('ascii', 0, 3) !== 'EXE' || exe[3] !== 1)
    throw new Error('invalid DSS EXE header');
  const headerSize = u16(exe, 4), entry = u16(exe, 16), entry2 = u16(exe, 18), stack = u16(exe, 20);
  if (headerSize !== 128 || entry !== entry2) throw new Error('unsupported DSS EXE header layout');
  const loadAddress = entry - headerSize;
  if (loadAddress < 0 || loadAddress + exe.length > 0xc000) throw new Error('EXE crosses 0xC000');
  // DSS installs this stack before the entry point runs, and it runs the loader
  // and the interrupt handlers on it. An entry stack sitting just above the
  // image therefore corrupts whichever routine happens to end that image --
  // silently, and only where that routine is reached. Demand a real gap.
  // It may descend through the consumed header, or clear the whole image; what
  // it may not do is start just above the last routine.
  const entryStackGap = 0x40, imageEnd = loadAddress + exe.length;
  if (stack > entry && stack - imageEnd < entryStackGap)
    throw new Error(`entry stack 0x${stack.toString(16)} leaves ` +
      `${stack - imageEnd} bytes above the image end 0x${imageEnd.toString(16)}, ` +
      `needs ${entryStackGap} or must sit at or below the entry point`);

  // Real DSS hands out pages with arbitrary contents. pageFill models that:
  // a byte value, or 'random' with the optional pageSeed for a repeatable run.
  let fillState = (scenario.pageSeed || 0x2545) & 0xffff;
  const fillByte = () => {
    if (scenario.pageFill === 'random') {
      fillState = (fillState * 25173 + 13849) & 0xffff;
      return fillState >> 8;
    }
    return scenario.pageFill & 0xff;
  };
  const freshPage = (size) => {
    const page = new Uint8Array(size);
    if (scenario.pageFill !== undefined)
      for (let i = 0; i < size; i++) page[i] = fillByte();
    return page;
  };
  const ram = freshPage(0x10000);
  for (let i = 0; i < exe.length; i++) ram[loadAddress + i] = exe[i];
  const card = new EtherLinkIII(scenario);
  let page3 = 3, systemIsa = false, isaOpen = false, selectedSlot = 0;
  let win1 = null, win2 = null, nextBlock = 16;
  const pages = new Map(), allocations = new Map();
  const allocated = (id) => pages.has(id);
  const environment = scenario.environment || {};
  const envKey = (name) => name.toUpperCase();
  let currentDir = (scenario.currentDir || 'C:\\NET').replace(/\//g, '\\').toUpperCase();
  const canonicalName = (name) => {
    const normalized = name.replace(/\//g, '\\').toUpperCase();
    if (/^[A-Z]:\\/.test(normalized) || normalized.startsWith('\\')) return normalized;
    return `${currentDir}${currentDir.endsWith('\\') ? '' : '\\'}${normalized}`;
  };
  const files = new Map(Object.entries(scenario.files || {}).map(([name, data]) => [
    canonicalName(name), Buffer.isBuffer(data) ? Buffer.from(data) : Buffer.from(data, 'utf8'),
  ]));
  const openFiles = new Map();
  let nextHandle = 4, envSetCount = 0, clockSecond = scenario.clockSecond || 0;
  let fileReadCalls = 0, fileWriteCalls = 0, fileCloseCalls = 0, totalWritten = 0;
  let clockReads = 0, scanCount = 0, keyDelivered = false;
  const dssEvents = [];
  let stdout = '', exitCode = null, steps = 0, minimumSp = stack, minimumPageSp = 0x10000;
  const setTimeCalls = [];
  const pcTrace = [];

  const cardPort = (address) => address & 0x3fff;
  const assertCardSlot = () => selectedSlot === card.slot && card.present;
  const assertWordCycleComplete = () => {
    if (card.wordReadHigh.size) throw new Error('ISA closed after low byte read without high byte');
    if (card.wordWriteLow.size) throw new Error('ISA closed after low byte write without high byte');
  };
  const rd = (address) => {
    address &= 0xffff;
    if (address >= 0xc000 && isaOpen) {
      const port = cardPort(address);
      if (!assertCardSlot()) return 0xff;
      if (!card.active && port === (scenario.idPort || 0x110)) return card.idRead();
      if (card.active && port >= card.base && port < card.base + 0x10) return card.readByte(port - card.base);
      return 0xff;
    }
    if (address >= 0x4000 && address < 0x8000 && win1 !== null) return pages.get(win1)[address - 0x4000];
    if (address >= 0x8000 && address < 0xc000 && win2 !== null) return pages.get(win2)[address - 0x8000];
    return ram[address];
  };
  const wr = (address, value) => {
    address &= 0xffff; value &= 0xff;
    if (address >= 0xc000 && isaOpen) {
      const port = cardPort(address);
      if (!assertCardSlot()) return;
      if (!card.active && port === (scenario.idPort || 0x110)) return card.idWrite(value);
      if (card.active && port >= card.base && port < card.base + 0x10) return card.writeByte(port - card.base, value);
      return;
    }
    if (address >= 0x4000 && address < 0x8000 && win1 !== null) { pages.get(win1)[address - 0x4000] = value; return; }
    if (address >= 0x8000 && address < 0xc000 && win2 !== null) { pages.get(win2)[address - 0x8000] = value; return; }
    ram[address] = value;
  };

  const cpu = new Z80({
    mem_read: rd,
    mem_write: wr,
    io_read: (port) => {
      port &= 0xffff;
      if (port === 0x00e2) return page3;
      throw new Error(`unknown I/O read ${port.toString(16)}`);
    },
    io_write: (port, value) => {
      port &= 0xffff; value &= 0xff;
      if (port === 0x1ffd) {
        if (value === 0x11) systemIsa = true;
        else if (value === 0x01) {
          if (isaOpen) assertWordCycleComplete();
          systemIsa = false; isaOpen = false;
        }
        else throw new Error(`unknown PORT_SYSTEM value ${value.toString(16)}`);
        return;
      }
      if (port === 0x00e2) {
        page3 = value;
        if (systemIsa && (value === 0xd4 || value === 0xd6)) selectedSlot = (value - 0xd4) >> 1;
        return;
      }
      if (port === 0x9fbd) {
        if (!systemIsa || value !== 0) throw new Error('invalid ISA mapping sequence');
        isaOpen = true;
        return;
      }
      throw new Error(`unknown I/O write ${port.toString(16)}=${value.toString(16)}`);
    },
  });

  // DSS owns the PSP placement; model it outside the program's own image. For a
  // WIN2-loaded image that is 0x7000, inside the window the program is about to
  // remap, which is what makes SAVE_COMMAND's copy necessary. A WIN1-loaded
  // image occupies that window itself, so its PSP goes in DSS's low memory.
  const cmdAddress = loadAddress < 0x8000 ? 0x3000 : 0x7000;
  if (Buffer.byteLength(args, 'ascii') > 255) throw new Error('command line exceeds DSS byte length');
  wr(cmdAddress, Buffer.byteLength(args, 'ascii'));
  for (let i = 0; i < args.length; i++) wr(cmdAddress + 1 + i, args.charCodeAt(i));
  let state = cpu.getState(); state.pc = entry; state.sp = stack; state.ix = cmdAddress; cpu.setState(state);
  // DSS reaches the entry point with the loader's own frames, and at least one
  // interrupt frame, already spent below this stack. Model that so a program
  // that parks its entry stack on top of its own code fails here too.
  for (let i = 1; i <= entryStackGap; i++) wr((stack - i) & 0xffff, 0x76 + (i & 1));
  const setCarry = (s, value) => { s.flags.C = value ? 1 : 0; };
  const ret = (s) => {
    const lo = rd(s.sp), hi = rd((s.sp + 1) & 0xffff);
    s.sp = (s.sp + 2) & 0xffff; s.pc = lo | (hi << 8); cpu.setState(s);
  };
  const cstr = (address) => {
    let result = '';
    for (let guard = 0; guard < 0x4000; guard++) { const value = rd(address++); if (!value) return result; result += String.fromCharCode(value); }
    throw new Error('unterminated DSS string');
  };
  const writeCstr = (address, value) => {
    const bytes = Buffer.from(value, 'ascii');
    for (let i = 0; i < bytes.length; i++) wr(address + i, bytes[i]);
    wr(address + bytes.length, 0);
  };
  // Real DSS runs its handler on the caller's stack. Model that: a call
  // scribbles the words below SP, so a program whose stack sits too close to
  // its own code corrupts itself here instead of only on hardware.
  const dssStackBytes = scenario.dssStackBytes === undefined ? 48 : scenario.dssStackBytes;
  const spendCallerStack = (sp) => {
    for (let i = 1; i <= dssStackBytes; i++) wr((sp - i) & 0xffff, 0x76 + (i & 1));
  };
  const dss = () => {
    if (isaOpen) throw new Error('DSS call while ISA window is open');
    const s = cpu.getState(), fn = s.c, count = s.b || 1;
    // Console output that scrolls calls BIOS WIN_MOVE, which maps the video
    // page over WIN1 and then restores SLOT1 from a POP taken while that page
    // is still mapped: a caller whose stack is in WIN1 wedges on its first
    // scrolled line. Nothing here can model that page swap, so reject the
    // placement itself. Non-console calls are fine on a WIN1 stack, which is
    // what lets a WIN1-resident image claim its page before it prints.
    if ((fn === 0x5b || fn === 0x5c) && s.sp > 0x4000 && s.sp <= 0x8000)
      throw new Error(`DSS console call with the caller stack in WIN1: SP=${s.sp.toString(16)}`);
    spendCallerStack(s.sp);
    switch (fn) {
      case 0x11: {
        const name = canonicalName(cstr((s.h << 8) | s.l));
        const data = files.get(name);
        if (scenario.traceDss) dssEvents.push(`OPEN ${name} ${data ? data.length : 'missing'}`);
        if (!data || ![0, 1, 2].includes(s.a)) { setCarry(s, true); s.a = 3; return ret(s); }
        const handle = nextHandle++;
        openFiles.set(handle, {name, data, offset: 0});
        s.a = handle; setCarry(s, false); return ret(s);
      }
      case 0x12: {
        fileCloseCalls++;
        if (scenario.fileCloseFailAt === fileCloseCalls) {
          s.a = 1; setCarry(s, true); return ret(s);
        }
        if (!openFiles.delete(s.a)) throw new Error(`CLOSE_FILE of unknown handle ${s.a}`);
        setCarry(s, false); return ret(s);
      }
      case 0x13: {
        const file = openFiles.get(s.a);
        if (!file) throw new Error(`READ_FILE of unknown handle ${s.a}`);
        fileReadCalls++;
        if (scenario.fileReadFailAt === fileReadCalls) { s.a = 1; setCarry(s, true); return ret(s); }
        let requested = (s.d << 8) | s.e;
        if (scenario.fileReadMax) requested = Math.min(requested, scenario.fileReadMax);
        const chunk = file.data.subarray(file.offset, file.offset + requested);
        const destination = (s.h << 8) | s.l;
        for (let i = 0; i < chunk.length; i++) wr(destination + i, chunk[i]);
        file.offset += chunk.length;
        if (scenario.traceDss) dssEvents.push(`READ ${file.name} ${chunk.length}/${requested}`);
        s.d = chunk.length >> 8; s.e = chunk.length & 0xff;
        setCarry(s, false); return ret(s);
      }
      case 0x0a:
      case 0x0b: {
        const name = canonicalName(cstr((s.h << 8) | s.l));
        if (fn === 0x0b && files.has(name)) { s.a = 7; setCarry(s, true); return ret(s); }
        const data = Buffer.alloc(0); files.set(name, data);
        const handle = nextHandle++; openFiles.set(handle, {name, data, offset: 0});
        if (scenario.traceDss) dssEvents.push(`CREATE ${name}`);
        s.a = handle; setCarry(s, false); return ret(s);
      }
      case 0x0e: {
        const name = canonicalName(cstr((s.h << 8) | s.l));
        if (!files.delete(name)) { s.a = 3; setCarry(s, true); return ret(s); }
        if (scenario.traceDss) dssEvents.push(`DELETE ${name}`);
        setCarry(s, false); return ret(s);
      }
      case 0x14: {
        const file = openFiles.get(s.a);
        if (!file) throw new Error(`WRITE of unknown handle ${s.a}`);
        fileWriteCalls++;
        const requested = (s.d << 8) | s.e;
        if (scenario.fileWriteFailAt === fileWriteCalls ||
            (scenario.diskFullAfter !== undefined && totalWritten + requested > scenario.diskFullAfter)) {
          s.a = 1; setCarry(s, true); return ret(s);
        }
        const source = (s.h << 8) | s.l;
        const end = file.offset + requested;
        const data = Buffer.alloc(Math.max(file.data.length, end));
        file.data.copy(data); for (let i = 0; i < requested; i++) data[file.offset + i] = rd(source + i);
        file.data = data; file.offset = end; files.set(file.name, data); totalWritten += requested;
        if (scenario.traceDss) dssEvents.push(`WRITE ${file.name} ${requested}`);
        setCarry(s, false); return ret(s);
      }
      case 0x15: {
        const file = openFiles.get(s.a);
        if (!file) throw new Error(`MOVE_FP of unknown handle ${s.a}`);
        const raw = ((((s.h << 8) | s.l) * 0x10000) + s.ix) >>> 0;
        const offset = raw > 0x7fffffff ? raw - 0x100000000 : raw;
        let base;
        if (s.b === 0) base = 0;
        else if (s.b === 1) base = file.offset;
        else if (s.b === 2) base = file.data.length;
        else throw new Error(`MOVE_FP with invalid whence ${s.b}`);
        const position = base + offset;
        if (scenario.fileSeekFail || position < 0 || position > 0xffffffff) {
          s.a = 1; setCarry(s, true); return ret(s);
        }
        file.offset = position;
        s.ix = position & 0xffff;
        s.h = (position >>> 24) & 0xff;
        s.l = (position >>> 16) & 0xff;
        if (scenario.traceDss) dssEvents.push(`SEEK ${file.name} ${position}`);
        setCarry(s, false); return ret(s);
      }
      case 0x1e:
        writeCstr((s.h << 8) | s.l, currentDir); setCarry(s, false); return ret(s);
      case 0x1d: {
        const requested = cstr((s.h << 8) | s.l).replace(/\//g, '\\').toUpperCase();
        if ((scenario.missingDirs || []).map((v) => v.toUpperCase()).includes(requested)) {
          s.a = 3; setCarry(s, true); return ret(s);
        }
        currentDir = /^[A-Z]:\\/.test(requested) || requested.startsWith('\\') ? requested : canonicalName(requested);
        if (scenario.traceDss) dssEvents.push(`CHDIR ${currentDir}`);
        setCarry(s, false); return ret(s);
      }
      case 0x35: {
        if (s.b !== 0x30) throw new Error(`unknown K_CLEAR subfunction ${s.b}`);
        const key = scenario.promptKey || 'n';
        s.a = key === 'escape' ? 0x1b : key.charCodeAt(0); setCarry(s, false); return ret(s);
      }
      case 0x21: {
        const now = Math.floor(clockSecond) % 86400;
        s.h = Math.floor(now / 3600); s.l = Math.floor(now / 60) % 60; s.b = now % 60;
        const frozen = scenario.clockFreezeAfterReads !== undefined &&
          clockReads >= scenario.clockFreezeAfterReads;
        clockSecond = (clockSecond + (frozen ? 0 : (scenario.timeStepSeconds ?? 1))) % 86400;
        clockReads++;
        // DSS does not promise IX/IY preservation. Exercise callers that need
        // their context pointer across the system-time service.
        if (scenario.clobberIndexOnSystime) { s.ix = 0x1f3d; s.iy = 0x2e4c; }
        setCarry(s, false); return ret(s);
      }
      case 0x22: {
        setTimeCalls.push({day: s.d, month: s.e, year: s.ix,
          hour: s.h, minute: s.l, second: s.b});
        if (scenario.traceDss) {
          const value = setTimeCalls[setTimeCalls.length - 1];
          dssEvents.push(`SETTIME ${value.year}-${value.month}-${value.day} ` +
            `${value.hour}:${value.minute}:${value.second}`);
        }
        if (scenario.setTimeFail) {
          s.a = scenario.setTimeError || 1; setCarry(s, true); return ret(s);
        }
        s.a = 0; setCarry(s, false); return ret(s);
      }
      case 0x31: {
        scanCount++;
        const keyReady = scenario.keyAfterHttpBytes !== undefined ?
          card.httpBytesSent >= scenario.keyAfterHttpBytes :
          scenario.keyAfterFtpBytes !== undefined ?
          (card.ftpDataBytesSent || 0) >= scenario.keyAfterFtpBytes :
          scanCount === (scenario.keyAtScan || 1);
        if (scenario.key && !keyDelivered && keyReady) {
          keyDelivered = true;
          if (scenario.key === 'escape') { s.b = 0; s.d = 1; s.e = 0x1b; }
          // DSS represents Ctrl+letter as a positional scancode with bit 7
          // set and the X_CTRL modifier; it does not return ASCII 0x03.
          else if (scenario.key === 'ctrl-c') { s.b = 0x20; s.d = 0xac; s.e = 0; }
          else throw new Error(`unknown simulated key ${scenario.key}`);
          s.a = 1; s.flags.Z = 0; setCarry(s, false); return ret(s);
        }
        s.a = 0; s.b = 0; s.d = 0; s.e = 0; s.flags.Z = 1; setCarry(s, false); return ret(s);
      }
      case 0x5b: stdout += String.fromCharCode(s.a); setCarry(s, false); return ret(s);
      case 0x5c: stdout += cstr((s.h << 8) | s.l); setCarry(s, false); return ret(s);
      case 0x3d: {
        const base = nextBlock; nextBlock += count;
        allocations.set(base, count);
        for (let i = 0; i < count; i++) pages.set(base + i, freshPage(0x4000));
        s.a = base; setCarry(s, false); return ret(s);
      }
      case 0x39: {
        const page = s.a + s.b;
        if (!allocated(page)) throw new Error(`SETWIN1 of unallocated page ${page}`);
        if (loadAddress < 0x8000) throw new Error('SETWIN1 would remap the image window');
        win1 = page; setCarry(s, false); return ret(s);
      }
      case 0x3a: {
        const page = s.a + s.b;
        if (!allocated(page)) throw new Error(`SETWIN2 of unallocated page ${page}`);
        if (loadAddress >= 0x8000) throw new Error('SETWIN2 would remap the image window');
        win2 = page; setCarry(s, false); return ret(s);
      }
      case 0x3e: {
        const countPages = allocations.get(s.a);
        if (!countPages) throw new Error(`FREEMEM of unknown block ${s.a}`);
        for (let i = 0; i < countPages; i++) pages.delete(s.a + i);
        allocations.delete(s.a);
        if (!allocated(win1)) win1 = null;
        if (!allocated(win2)) win2 = null;
        setCarry(s, false); return ret(s);
      }
      case 0x46: {
        if (s.b === 1) {
          const name = envKey(cstr((s.h << 8) | s.l));
          if (!Object.prototype.hasOwnProperty.call(environment, name)) {
            s.a = 0; setCarry(s, false); return ret(s);
          }
          writeCstr((s.d << 8) | s.e, String(environment[name]));
          s.a = 0xff; setCarry(s, false); return ret(s);
        }
        if (s.b === 2) {
          envSetCount++;
          if (scenario.envFailAt && envSetCount === scenario.envFailAt) {
            s.a = 1; setCarry(s, true); return ret(s);
          }
          const assignment = cstr((s.h << 8) | s.l);
          const split = assignment.indexOf('=');
          if (split < 1) throw new Error(`invalid ENV_SET '${assignment}'`);
          const name = envKey(assignment.slice(0, split)), value = assignment.slice(split + 1);
          if (value === '') delete environment[name]; else environment[name] = value;
          s.a = 0; setCarry(s, false); return ret(s);
        }
        throw new Error(`unknown ENVIRON subfunction ${s.b}`);
      }
      case 0x47: {
        if (s.b === 1) { writeCstr((s.h << 8) | s.l, scenario.appDir || 'C:\\NET'); setCarry(s, false); return ret(s); }
        if (s.b === 0) { writeCstr((s.h << 8) | s.l, args); setCarry(s, false); return ret(s); }
        throw new Error(`unknown APPINFO subfunction ${s.b}`);
      }
      case 0x41:
        exitCode = s.b;
        if (isaOpen) throw new Error('EXIT with ISA window open');
        if (allocations.size) throw new Error('EXIT with unreleased DSS pages');
        if (openFiles.size) throw new Error('EXIT with unclosed files');
        cpu.setState(s);
        throw {dssExit: true};
      default: {
        const state = cpu.getState();
        throw new Error(`unknown DSS call ${fn.toString(16)} ` +
          `SP=${state.sp.toString(16)} BC=${state.b.toString(16)}${state.c.toString(16)} ` +
          `trace=${pcTrace.map((value) => value.toString(16)).join(',')}`);
      }
    }
  };

  try {
    const limit = scenario.stepLimit || 200_000_000;
    for (;;) {
      const sp = cpu.getState().sp;
      minimumSp = Math.min(minimumSp, sp);
      // The runtime stack lives in the claimed page, which is a different window
      // from the entry stack, so the overall minimum says nothing about it.
      if (win2 !== null && sp > 0x8000 && sp <= 0xc000) minimumPageSp = Math.min(minimumPageSp, sp);
      else if (win1 !== null && sp > 0x4000 && sp <= 0x8000) minimumPageSp = Math.min(minimumPageSp, sp);
      if (scenario.stopPc !== undefined && cpu.getState().pc === scenario.stopPc) {
        const stopped = cpu.getState();
        throw new Error(`stop PC=${stopped.pc.toString(16)} SP=${stopped.sp.toString(16)} ` +
          `AF=${stopped.a.toString(16)}/${JSON.stringify(stopped.flags)} ` +
          `BC=${stopped.b.toString(16)}${stopped.c.toString(16)} ` +
          `DE=${stopped.d.toString(16)}${stopped.e.toString(16)} ` +
          `HL=${stopped.h.toString(16)}${stopped.l.toString(16)} ` +
          `IX=${stopped.ix.toString(16)} IY=${stopped.iy.toString(16)} ` +
          `stack=${Array.from({length: 8}, (_, offset) => rd((stopped.sp + offset) & 0xffff).toString(16).padStart(2, '0')).join('')} ` +
          `trace=${pcTrace.map((v) => v.toString(16)).join(',')}`);
      }
      if (scenario.strictPc && cpu.getState().pc !== 0x0010 &&
          (cpu.getState().pc < loadAddress || cpu.getState().pc >= loadAddress + exe.length))
        throw new Error(`PC escaped image: PC=${cpu.getState().pc.toString(16)} SP=${cpu.getState().sp.toString(16)} trace=${pcTrace.map((v) => v.toString(16)).join(',')}`);
      if (scenario.traceCpu) { pcTrace.push(cpu.getState().pc); if (pcTrace.length > 32) pcTrace.shift(); }
      // Production polling yields use this exact bounded BC loop. Collapse all
      // but its final iteration so multi-second actual-EXE timeout tests retain
      // their logical tick count without interpreting ~2400 Z80 instructions
      // per millisecond. No ISA/DSS operation occurs inside this pattern.
      const delay = cpu.getState();
      if (scenario.fastDelayLoops !== false &&
          rd(delay.pc) === 0x0b && rd(delay.pc + 1) === 0x78 &&
          rd(delay.pc + 2) === 0xb1 && rd(delay.pc + 3) === 0x20 &&
          rd(delay.pc + 4) === 0xfb && ((delay.b << 8) | delay.c) > 1) {
        delay.b = 0; delay.c = 1; cpu.setState(delay);
      }
      if (cpu.getState().pc === 0x0010) dss(); else cpu.run_instruction();
      if (++steps > limit) throw new Error(`step limit at PC=${cpu.getState().pc.toString(16)} SP=${cpu.getState().sp.toString(16)} trace=${pcTrace.map((v) => v.toString(16)).join(',')}`);
    }
  } catch (error) {
    if (!error || !error.dssExit) throw error;
  }
  return {
    exitCode,
    output: stdout,
    transmittedFrames: card.transmitted.map(hex),
    txRecords: card.txRecords.map((r) => ({preamble: hex(r.preamble), frame: hex(r.frame), dwordPad: hex(r.dwordPad)})),
    rejectedFrames: card.rejected.map(hex),
    generatedFrames: card.generated.map(hex),
    rxRemaining: card.rxQueue.length,
    cleanup: {
      isaClosed: !isaOpen,
      pagesFreed: allocations.size === 0,
      done: !card.rxEnabled && !card.txEnabled && card.window === 0,
    },
    card: {slot: card.slot, base: card.base, mac: hex(card.mac), station: hex(card.station), active: card.active},
    httpRequests: card.httpRequests.slice(),
    environment: {...environment},
    currentDir,
    files: Object.fromEntries([...files].map(([name, data]) => [name, Buffer.from(data)])),
    tftpUploads: scenario.tftp && scenario.tftp.uploads ? {...scenario.tftp.uploads} : {},
    ftpRequests: card.ftpRequests.slice(),
    ftpUploads: Buffer.concat(card.ftpUploadChunks),
    ftpDataBytesSent: card.ftpDataBytesSent || 0,
    ftpDataPort: card.ftpDataPort,
    tcpResetPorts: card.tcpResetPorts.slice(),
    requestCounts: {
      dhcpDiscover: card.dhcpDiscoverCount, dhcpRequest: card.dhcpRequestCount,
      dhcpRelease: card.dhcpReleaseCount,
      arp: card.arpRequestCount, icmp: card.icmpRequestCount, dns: card.dnsRequestCount,
      ntp: card.ntpRequestCount, udp: card.udpRequestCount,
      tcp: card.tcpRequestCount,
    },
    maxInFlight: card.maxInFlight,
    setTimeCalls,
    ...(scenario.traceDss ? {dssEvents} : {}),
    ...(scenario.dumpMemory ? {memory: Object.fromEntries(scenario.dumpMemory.map(([start, length]) => [
      start.toString(16), hex(Array.from({length}, (_, i) => ram[(start + i) & 0xffff])),
    ]))} : {}),
    steps,
    minimumSp,
    minimumPageSp: minimumPageSp === 0x10000 ? null : minimumPageSp,
  };
}

module.exports = {runExe, eepromWords};
