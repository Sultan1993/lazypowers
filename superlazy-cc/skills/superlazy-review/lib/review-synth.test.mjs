import { test } from 'node:test';
import assert from 'node:assert/strict';
import {
  bucketFindings, rankFindings, applyRefutations, renderReport,
} from './review-synth.mjs';

const mk = (o = {}) => ({
  severity: 'Important', dimension: 'correctness', file: 'a.js', line: 10,
  title: 'null deref crash', why: 'w', failure_scenario: 'f', fix: 'x', ...o,
});

test('same defect, same file+dimension+near line -> agreed', () => {
  const { agreed, single } = bucketFindings([mk({ line: 10 })], [mk({ line: 12 })]);
  assert.equal(agreed.length, 1);
  assert.equal(single.length, 0);
  assert.deepEqual(agreed[0].raisedBy, ['claude', 'codex']);
});

test('different dimension -> both single', () => {
  const { agreed, single } = bucketFindings([mk({ dimension: 'security' })], [mk({ dimension: 'tests' })]);
  assert.equal(agreed.length, 0);
  assert.equal(single.length, 2);
});

test('agreed keeps the higher severity', () => {
  const { agreed } = bucketFindings([mk({ severity: 'Minor' })], [mk({ severity: 'Critical' })]);
  assert.equal(agreed[0].severity, 'Critical');
});

test('singles get stable ids', () => {
  const { single } = bucketFindings([mk({ file: 'x.js' })], [mk({ file: 'y.js' })]);
  assert.deepEqual(single.map((s) => s.id), ['s0', 's1']);
});

// Regression: the two-model reviewer itself flagged that location-only matching
// merged unrelated defects and silently dropped one. Distinct titles must NOT merge.
test('distinct defects at nearby lines -> both single (no false merge)', () => {
  const { agreed, single } = bucketFindings(
    [mk({ line: 10, title: 'null pointer dereference' })],
    [mk({ line: 20, title: 'incorrect total calculation' })],
  );
  assert.equal(agreed.length, 0);
  assert.equal(single.length, 2);
});

test('line unknown (0): same defect merges, different defect does not', () => {
  const same = bucketFindings(
    [mk({ line: 0, title: 'null deref crash' })],
    [mk({ line: 0, title: 'null deref crash' })],
  );
  assert.equal(same.agreed.length, 1);
  assert.equal(same.single.length, 0);

  const diff = bucketFindings(
    [mk({ line: 0, title: 'null deref crash' })],
    [mk({ line: 0, title: 'wrong total sum' })],
  );
  assert.equal(diff.agreed.length, 0);
  assert.equal(diff.single.length, 2);
});

test('rank: Critical first, then agreed before single at same severity', () => {
  const agreedImp = mk({ severity: 'Important', raisedBy: ['claude', 'codex'] });
  const crit = mk({ severity: 'Critical', raisedBy: ['claude'] });
  const singleImp = mk({ severity: 'Important', raisedBy: ['claude'] });
  const r = rankFindings([agreedImp, crit, singleImp]);
  assert.equal(r[0].severity, 'Critical');
  assert.deepEqual(r[1].raisedBy, ['claude', 'codex']);
});

test('refuted single dropped, agreed kept', () => {
  const bucket = bucketFindings([mk({ file: 'a.js', line: 1 })], [mk({ file: 'b.js', line: 1 })]);
  const ag = bucketFindings([mk({ file: 'c.js', line: 5 })], [mk({ file: 'c.js', line: 5 })]);
  bucket.agreed = ag.agreed;
  const ranked = applyRefutations(bucket, { s0: { refuted: true, reason: 'no' } });
  const ids = ranked.map((f) => f.id).filter(Boolean);
  assert.ok(!ids.includes('s0'));
  assert.ok(ids.includes('s1'));
  assert.equal(ranked.filter((f) => f.agreed).length, 1);
});

test('renderReport shows severity header, tag, and where-line', () => {
  const md = renderReport(
    { target: 'PR #1', base: 'aaa', head: 'bbb' },
    rankFindings([mk({ severity: 'Critical', raisedBy: ['claude', 'codex'] })]),
  );
  assert.match(md, /\[Critical\] null deref crash/);
  assert.match(md, /both models/);
  assert.match(md, /a\.js:10/);
});
