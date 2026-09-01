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
  const destination = options.foreignDestination ? [2, 9, 9, 9, 9, 9] : Array(6).fill(0xff);
  const frame = [...destination, ...serverMac, 8, 0];
  const ip = [0x45, 0, 0, 0, 0x12, 0x34, 0x40, 0, 64, 17, 0, 0, ...serverIp, 255, 255, 255, 255];
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
    opts.push(1, maskData.length, ...maskData, 3, routerData.length, ...routerData,
      6, dnsData.length, ...dnsData);
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
  const pseudo = [...serverIp, 255, 255, 255, 255, 0, 17,
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
  while (reply.length < 60) reply.push(0);
  return reply;
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
    this.dhcpDiscoverCount = 0; this.dhcpRequestCount = 0;
    this.arpRequestCount = 0;
    this.icmpRequestCount = 0;
    this.udpRequestCount = 0;
    this.tftpResponseCount = 0;
    this.tftpSession = null;
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
    const datagram = udpDatagram(frame);
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

  const ram = new Uint8Array(0x10000);
  for (let i = 0; i < exe.length; i++) ram[loadAddress + i] = exe[i];
  const card = new EtherLinkIII(scenario);
  let page3 = 3, systemIsa = false, isaOpen = false, selectedSlot = 0;
  let win1 = null, nextBlock = 16;
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
  let fileReadCalls = 0, fileWriteCalls = 0, totalWritten = 0;
  let clockReads = 0, scanCount = 0;
  const dssEvents = [];
  let stdout = '', exitCode = null, steps = 0, minimumSp = stack;
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

  const cmdAddress = 0x7000;
  if (Buffer.byteLength(args, 'ascii') > 255) throw new Error('command line exceeds DSS byte length');
  wr(cmdAddress, Buffer.byteLength(args, 'ascii'));
  for (let i = 0; i < args.length; i++) wr(cmdAddress + 1 + i, args.charCodeAt(i));
  let state = cpu.getState(); state.pc = entry; state.sp = stack; state.ix = cmdAddress; cpu.setState(state);
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
  const dss = () => {
    if (isaOpen) throw new Error('DSS call while ISA window is open');
    const s = cpu.getState(), fn = s.c, count = s.b || 1;
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
        setCarry(s, false); return ret(s);
      }
      case 0x31: {
        scanCount++;
        if (scenario.key && scanCount === (scenario.keyAtScan || 1)) {
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
        for (let i = 0; i < count; i++) pages.set(base + i, new Uint8Array(0x4000));
        s.a = base; setCarry(s, false); return ret(s);
      }
      case 0x39: {
        const page = s.a + s.b;
        if (!allocated(page)) throw new Error(`SETWIN1 of unallocated page ${page}`);
        win1 = page; setCarry(s, false); return ret(s);
      }
      case 0x3e: {
        const countPages = allocations.get(s.a);
        if (!countPages) throw new Error(`FREEMEM of unknown block ${s.a}`);
        for (let i = 0; i < countPages; i++) pages.delete(s.a + i);
        allocations.delete(s.a); if (!allocated(win1)) win1 = null;
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
      default: throw new Error(`unknown DSS call ${fn.toString(16)}`);
    }
  };

  try {
    const limit = scenario.stepLimit || 200_000_000;
    for (;;) {
      minimumSp = Math.min(minimumSp, cpu.getState().sp);
      if (scenario.stopPc !== undefined && cpu.getState().pc === scenario.stopPc)
        throw new Error(`stop PC=${cpu.getState().pc.toString(16)} SP=${cpu.getState().sp.toString(16)} A=${cpu.getState().a.toString(16)} F=${JSON.stringify(cpu.getState().flags)} trace=${pcTrace.map((v) => v.toString(16)).join(',')}`);
      if (scenario.strictPc && cpu.getState().pc !== 0x0010 && cpu.getState().pc < 0x8080)
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
    environment: {...environment},
    currentDir,
    files: Object.fromEntries([...files].map(([name, data]) => [name, Buffer.from(data)])),
    tftpUploads: scenario.tftp && scenario.tftp.uploads ? {...scenario.tftp.uploads} : {},
    ...(scenario.traceDss ? {dssEvents} : {}),
    ...(scenario.dumpMemory ? {memory: Object.fromEntries(scenario.dumpMemory.map(([start, length]) => [
      start.toString(16), hex(Array.from({length}, (_, i) => ram[(start + i) & 0xffff])),
    ]))} : {}),
    steps,
    minimumSp,
  };
}

module.exports = {runExe, eepromWords};
