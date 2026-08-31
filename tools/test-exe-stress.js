#!/usr/bin/env node
// Deliberately separate from make test-host: full 100-run actual-EXE stress.
// SPDX-License-Identifier: BSD-3-Clause
'use strict';

const assert = require('assert');
const path = require('path');
const {runExe} = require('./exe-harness/harness.js');

const image = path.resolve(__dirname, '..', 'build', 'EL3LB.EXE');
const result = runExe(image, '-n 100', {stepLimit: 500_000_000});
assert.strictEqual(result.exitCode, 0);
assert.strictEqual(result.transmittedFrames.length, 5200);
assert.match(result.output, /RUN OK=100/);
assert.match(result.output, /RESULT OK/);
assert.deepStrictEqual(result.cleanup, {isaClosed: true, pagesFreed: true, done: true});
console.log(`EL3LB actual-EXE stress: 100 runs, ${result.transmittedFrames.length} exact loopback frames passed`);
