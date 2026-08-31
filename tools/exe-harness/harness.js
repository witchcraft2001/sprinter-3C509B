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
      this.txFifo = []; this.txExpected = 0;
    }
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
        if (offset === 0x08) return this.rxQueue.length ? this.rxQueue[0].frame.length : 0;
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
  let stdout = '', exitCode = null, steps = 0;

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
  const dss = () => {
    if (isaOpen) throw new Error('DSS call while ISA window is open');
    const s = cpu.getState(), fn = s.c, count = s.b || 1;
    switch (fn) {
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
      case 0x41:
        exitCode = s.b;
        if (isaOpen) throw new Error('EXIT with ISA window open');
        if (allocations.size) throw new Error('EXIT with unreleased DSS pages');
        cpu.setState(s);
        throw {dssExit: true};
      default: throw new Error(`unknown DSS call ${fn.toString(16)}`);
    }
  };

  try {
    const limit = scenario.stepLimit || 200_000_000;
    for (;;) {
      if (cpu.getState().pc === 0x0010) dss(); else cpu.run_instruction();
      if (++steps > limit) throw new Error(`step limit at PC=${cpu.getState().pc.toString(16)}`);
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
    rxRemaining: card.rxQueue.length,
    cleanup: {
      isaClosed: !isaOpen,
      pagesFreed: allocations.size === 0,
      done: !card.rxEnabled && !card.txEnabled && card.window === 0,
    },
    card: {slot: card.slot, base: card.base, mac: hex(card.mac), active: card.active},
    steps,
  };
}

module.exports = {runExe, eepromWords};
