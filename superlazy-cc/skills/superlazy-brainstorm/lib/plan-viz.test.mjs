import { test } from 'node:test';
import assert from 'node:assert/strict';
import { analyze, normalizePath, extractFence } from './plan-viz.mjs';

// fixture helper: task with a valid fence unless overridden
const T = (id, over = {}, fence = {}) => ({
  id,
  subject: `Task ${id}`,
  description: `**Goal:** g${id}\n\n\`\`\`json:metadata\n${JSON.stringify({
    files: [`src/f${id}.js`], modelTier: 'mechanical',
    verifyCommand: 'true', acceptanceCriteria: ['a'], ...fence,
  })}\n\`\`\``,
  ...over,
});
const plan = tasks => ({ planPath: 'p.md', tasks });
const kinds = a => a.problems.map(p => p.kind);

test('wave layering follows blockedBy', () => {
  const a = analyze(plan([T(0), T(1), T(2, { blockedBy: [0, 1] }), T(3, { blockedBy: [2] })]));
  assert.deepEqual(a.waves, [[0, 1], [2], [3]]);
  assert.equal(a.stats.waves, 3);
  assert.deepEqual(kinds(a), []);
});

test('unknown blockedBy flagged, edge ignored', () => {
  const a = analyze(plan([T(0), T(1, { blockedBy: [99] })]));
  assert.ok(kinds(a).includes('unknown-dep'));
  assert.deepEqual(a.waves, [[0, 1]]); // edge ignored → same wave
});

test('cycle flagged and unschedulable', () => {
  const a = analyze(plan([T(0, { blockedBy: [1] }), T(1, { blockedBy: [0] }), T(2)]));
  assert.equal(kinds(a).filter(k => k === 'cycle').length, 2);
  assert.deepEqual(a.unschedulable.sort(), [0, 1]);
  assert.deepEqual(a.waves, [[2]]);
});

test('frontier-heavy: 31% flags, 30% does not', () => {
  // 13 tasks, 4 frontier = 30.8% → flag
  const heavy = analyze(plan(Array.from({ length: 13 }, (_, i) =>
    T(i, {}, { modelTier: i < 4 ? 'frontier' : 'mechanical' }))));
  assert.ok(kinds(heavy).includes('frontier-heavy'));
  // 10 tasks, 3 frontier = 30% exactly → no flag
  const ok = analyze(plan(Array.from({ length: 10 }, (_, i) =>
    T(i, {}, { modelTier: i < 3 ? 'frontier' : 'mechanical' }))));
  assert.ok(!kinds(ok).includes('frontier-heavy'));
});

test('same-wave file overlap flagged after normalization', () => {
  const a = analyze(plan([
    T(0, {}, { files: ['./src//x.js'] }),
    T(1, {}, { files: ['src/x.js'] }),
  ]));
  assert.ok(kinds(a).includes('file-overlap'));
  // different waves → no overlap problem
  const b = analyze(plan([
    T(0, {}, { files: ['src/x.js'] }),
    T(1, { blockedBy: [0] }, { files: ['src/x.js'] }),
  ]));
  assert.ok(!kinds(b).includes('file-overlap'));
});

test('missing verify / criteria / fence / tier flagged', () => {
  const a = analyze(plan([
    T(0, {}, { verifyCommand: '  ' }),
    T(1, {}, { acceptanceCriteria: [] }),
    T(2, { description: 'no fence here' }),
    T(3, {}, { modelTier: 'galactic' }),
  ]));
  const k = kinds(a);
  assert.ok(k.includes('no-verify'));
  assert.ok(k.includes('no-criteria'));
  assert.ok(k.includes('no-metadata'));
  assert.ok(k.includes('bad-tier'));
});

test('stats count tiers', () => {
  const a = analyze(plan([T(0), T(1, {}, { modelTier: 'standard' }), T(2, {}, { modelTier: 'frontier' })]));
  assert.deepEqual(a.stats, { tasks: 3, waves: 1, tiers: { mechanical: 1, standard: 1, frontier: 1, unknown: 0 } });
});

test('normalizePath', () => {
  assert.equal(normalizePath(' ./a//b\\c.js '), 'a/b/c.js');
});

test('extractFence tolerates garbage', () => {
  assert.equal(extractFence('no fence'), null);
  assert.equal(extractFence('```json:metadata\n{broken\n```'), null);
});
