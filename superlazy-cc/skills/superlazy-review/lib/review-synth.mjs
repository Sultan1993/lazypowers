#!/usr/bin/env node
// review-synth.mjs — pure synthesis for superlazy-review. No model calls, no network.
import { writeFileSync, readFileSync, mkdirSync } from 'node:fs';

export const SEVERITY_RANK = { Critical: 0, Important: 1, Minor: 2 };
export const DIMENSIONS = ['correctness', 'security', 'performance', 'tests', 'api-design', 'over-engineering'];
const PROX = 15; // lines within which same-file+dimension findings are "the same"

function matches(a, b) {
  if (a.file !== b.file || a.dimension !== b.dimension) return false;
  if (!a.line || !b.line) return true; // line unknown on either side -> match on file+dimension
  return Math.abs(a.line - b.line) <= PROX;
}

function moreSevere(a, b) {
  return (SEVERITY_RANK[a.severity] ?? 3) <= (SEVERITY_RANK[b.severity] ?? 3) ? a : b;
}

export function bucketFindings(claude = [], codex = []) {
  const pool = codex.map((f) => ({ ...f }));
  const used = new Set();
  const agreed = [];
  const single = [];
  for (const c of claude) {
    const idx = pool.findIndex((p, i) => !used.has(i) && matches(c, p));
    if (idx >= 0) {
      used.add(idx);
      agreed.push({ ...moreSevere(c, pool[idx]), raisedBy: ['claude', 'codex'], agreed: true });
    } else {
      single.push({ ...c, raisedBy: ['claude'], agreed: false });
    }
  }
  pool.forEach((p, i) => {
    if (!used.has(i)) single.push({ ...p, raisedBy: ['codex'], agreed: false });
  });
  single.forEach((s, i) => { s.id = `s${i}`; });
  return { agreed, single };
}

export function rankFindings(findings) {
  const dimIdx = (d) => { const i = DIMENSIONS.indexOf(d); return i < 0 ? 99 : i; };
  return [...findings].sort((a, b) => (
    (SEVERITY_RANK[a.severity] ?? 3) - (SEVERITY_RANK[b.severity] ?? 3)
    || (b.raisedBy.length - a.raisedBy.length)
    || dimIdx(a.dimension) - dimIdx(b.dimension)
  ));
}

export function applyRefutations(bucket, refutations = {}) {
  const survivors = bucket.single.filter((s) => !(refutations[s.id] && refutations[s.id].refuted));
  return rankFindings([...bucket.agreed, ...survivors]);
}

function counts(ranked) {
  const c = { Critical: 0, Important: 0, Minor: 0 };
  ranked.forEach((f) => { c[f.severity] = (c[f.severity] || 0) + 1; });
  return c;
}

export function renderReport(meta, ranked) {
  const c = counts(ranked);
  const out = [];
  out.push(`# superlazy-review — ${meta.target || 'diff'}`, '');
  out.push(`- Base \`${meta.base || '?'}\` → Head \`${meta.head || '?'}\``);
  out.push(`- Reviewers: Claude (${meta.claudeModel || 'opus'}) + Codex (${meta.codexModel || 'gpt-5.6-sol'})`);
  if (meta.note) out.push(`- Note: ${meta.note}`);
  out.push(`- Findings: ${c.Critical} Critical, ${c.Important} Important, ${c.Minor} Minor`, '');
  if (!ranked.length) { out.push('_No surviving findings._'); return `${out.join('\n')}\n`; }
  for (const f of ranked) {
    const tag = f.raisedBy.length === 2 ? 'both models' : f.raisedBy[0];
    out.push(`## [${f.severity}] ${f.title}`, '');
    out.push(`- **Where:** \`${f.file}${f.line ? `:${f.line}` : ''}\` · ${f.dimension} · raised by **${tag}**`);
    out.push(`- **Why:** ${f.why}`);
    if (f.failure_scenario) out.push(`- **Failure:** ${f.failure_scenario}`);
    if (f.fix) out.push(`- **Fix:** ${f.fix}`);
    out.push('');
  }
  return `${out.join('\n')}\n`;
}

export function renderDigest(meta, ranked) {
  const c = counts(ranked);
  const top = ranked.slice(0, 5).map((f) => {
    const tag = f.raisedBy.length === 2 ? 'both' : f.raisedBy[0];
    return `  [${f.severity}] ${f.title} (${f.file}${f.line ? `:${f.line}` : ''}, ${tag})`;
  });
  return [`superlazy-review: ${c.Critical} Critical, ${c.Important} Important, ${c.Minor} Minor`, ...top].join('\n');
}

// ---- CLI ----
function main(argv) {
  const readJson = (p) => JSON.parse(readFileSync(p, 'utf8'));
  const [cmd, ...rest] = argv;
  if (cmd === 'bucket') {
    const [claudePath, codexPath] = rest;
    const claude = (readJson(claudePath).findings) || [];
    const codex = (readJson(codexPath).findings) || [];
    process.stdout.write(JSON.stringify(bucketFindings(claude, codex)));
    return;
  }
  if (cmd === 'render') {
    const [bucketPath, refutePath, outDir, metaPath] = rest;
    const bucket = readJson(bucketPath);
    const refutations = refutePath && refutePath !== '-' ? readJson(refutePath) : {};
    const meta = metaPath ? readJson(metaPath) : {};
    const ranked = applyRefutations(bucket, refutations);
    mkdirSync(outDir, { recursive: true });
    writeFileSync(`${outDir}/report.md`, renderReport(meta, ranked));
    process.stdout.write(renderDigest(meta, ranked));
    return;
  }
  process.stderr.write('usage: review-synth.mjs bucket <claude.json> <codex.json>\n'
    + '       review-synth.mjs render <bucket.json> <refute.json|-> <outDir> <meta.json>\n');
  process.exit(2);
}

if (import.meta.url === `file://${process.argv[1]}`) main(process.argv.slice(2));
