// plan-viz.mjs — render a superlazy plan as a self-contained HTML review page.
// Pure node, zero deps. Usage: node plan-viz.mjs <plan.md> [--json]
//   HTML  -> <plan.md>.html (path printed)
//   --json -> {stats, waves, problems} on stdout (test surface; no HTML write)
// Detector semantics are pinned by the 2026-07-22 design spec — change them
// there first.

import { readFileSync, writeFileSync } from 'node:fs';

// ---------- parsing ----------

export function parseTasks(tasksJson) {
  // tasks.json shape: {planPath, tasks:[{id, subject, description, blockedBy?}]}
  const tasks = (tasksJson.tasks ?? []).map(t => {
    const fence = extractFence(t.description ?? '');
    return { id: t.id, subject: t.subject ?? `task-${t.id}`, blockedBy: t.blockedBy ?? [], fence, description: t.description ?? '' };
  });
  return tasks;
}

export function extractFence(description) {
  const m = /```json:metadata\n([\s\S]*?)\n```/.exec(description);
  if (!m) return null;
  try { return JSON.parse(m[1]); } catch { return null; }
}

export function normalizePath(p) {
  return String(p).trim().replace(/\\/g, '/').replace(/^\.\//, '').replace(/\/\/+/g, '/');
}

// ---------- waves (Kahn layering) ----------

export function computeWaves(tasks) {
  const ids = new Set(tasks.map(t => t.id));
  const problems = [];
  // unknown refs: flag, ignore edge
  const deps = new Map();
  for (const t of tasks) {
    const real = [];
    for (const d of t.blockedBy) {
      if (!ids.has(d)) problems.push({ kind: 'unknown-dep', task: t.id, detail: `blockedBy ${d} does not exist` });
      else real.push(d);
    }
    deps.set(t.id, real);
  }
  const waves = [];
  const placed = new Set();
  let remaining = tasks.map(t => t.id);
  while (remaining.length) {
    const ready = remaining.filter(id => deps.get(id).every(d => placed.has(d)));
    if (!ready.length) break; // cycle among remaining
    waves.push(ready);
    ready.forEach(id => placed.add(id));
    remaining = remaining.filter(id => !placed.has(id));
  }
  if (remaining.length) {
    for (const id of remaining) problems.push({ kind: 'cycle', task: id, detail: 'part of a dependency cycle — unschedulable' });
  }
  return { waves, unschedulable: remaining, problems };
}

// ---------- detectors ----------

export function detectProblems(tasks, waves) {
  const problems = [];
  const byId = new Map(tasks.map(t => [t.id, t]));

  for (const t of tasks) {
    if (!t.fence) { problems.push({ kind: 'no-metadata', task: t.id, detail: 'missing or unparseable json:metadata fence' }); continue; }
    const tier = t.fence.modelTier;
    if (!['mechanical', 'standard', 'frontier'].includes(tier))
      problems.push({ kind: 'bad-tier', task: t.id, detail: `modelTier "${tier}" invalid` });
    if (!t.fence.verifyCommand || !String(t.fence.verifyCommand).trim())
      problems.push({ kind: 'no-verify', task: t.id, detail: 'missing or blank verifyCommand' });
    if (!Array.isArray(t.fence.acceptanceCriteria) || t.fence.acceptanceCriteria.length === 0)
      problems.push({ kind: 'no-criteria', task: t.id, detail: 'missing or empty acceptanceCriteria' });
  }

  // frontier-heavy: strictly more than 30% of tasks
  const withFence = tasks.filter(t => t.fence);
  const frontier = withFence.filter(t => t.fence.modelTier === 'frontier').length;
  if (tasks.length > 0 && frontier / tasks.length > 0.3)
    problems.push({ kind: 'frontier-heavy', task: null, detail: `${frontier}/${tasks.length} tasks are frontier (>30%) — plan smell: incomplete specification` });

  // same-wave file overlap
  for (const wave of waves) {
    const seen = new Map(); // normalized path -> task id
    for (const id of wave) {
      const t = byId.get(id);
      for (const f of (t?.fence?.files ?? [])) {
        const n = normalizePath(f);
        if (seen.has(n) && seen.get(n) !== id)
          problems.push({ kind: 'file-overlap', task: id, detail: `${n} also touched by task ${seen.get(n)} in the same wave — write race` });
        else seen.set(n, id);
      }
    }
  }
  return problems;
}

// ---------- stats ----------

export function computeStats(tasks, waves) {
  const tiers = { mechanical: 0, standard: 0, frontier: 0, unknown: 0 };
  for (const t of tasks) {
    const k = t.fence?.modelTier;
    if (k in tiers) tiers[k]++; else tiers.unknown++;
  }
  return { tasks: tasks.length, waves: waves.length, tiers };
}

export function analyze(tasksJson) {
  const tasks = parseTasks(tasksJson);
  const { waves, unschedulable, problems: waveProblems } = computeWaves(tasks);
  const problems = [...waveProblems, ...detectProblems(tasks, waves)];
  return { stats: computeStats(tasks, waves), waves, unschedulable, problems, tasks };
}

// ---------- HTML ----------

const esc = s => String(s).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');

export function renderHTML(planPath, analysis) {
  const { stats, waves, unschedulable, problems, tasks } = analysis;
  const byId = new Map(tasks.map(t => [t.id, t]));
  const tierChip = t => `<span class="chip ${esc(t)}">${esc(t)}</span>`;
  const goal = d => { const m = /\*\*Goal:\*\*\s*([^\n]+)/.exec(d); return m ? m[1] : ''; };

  const card = id => {
    const t = byId.get(id); if (!t) return '';
    const f = t.fence ?? {};
    return `<div class="card">
      <h4>${esc(t.subject)} ${f.modelTier ? tierChip(f.modelTier) : '<span class="chip bad">no tier</span>'}</h4>
      <p class="goal">${esc(goal(t.description))}</p>
      <p class="files">${(f.files ?? []).map(x => `<code>${esc(x)}</code>`).join(' ')}</p>
      ${f.verifyCommand ? `<p class="verify">verify: <code>${esc(String(f.verifyCommand).slice(0, 120))}</code></p>` : ''}
    </div>`;
  };

  const waveCols = waves.map((w, i) =>
    `<div class="wave"><h3>Wave ${i + 1}</h3>${w.map(card).join('')}</div>`).join('');
  const unsched = unschedulable.length
    ? `<div class="wave bad"><h3>Unschedulable (cycle)</h3>${unschedulable.map(card).join('')}</div>` : '';

  const probList = problems.length
    ? problems.map(p => `<li><b>${esc(p.kind)}</b>${p.task !== null && p.task !== undefined ? ` · task ${p.task}` : ''} — ${esc(p.detail)}</li>`).join('')
    : '<li class="ok">none — plan is structurally clean</li>';

  return `<!doctype html><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>plan review — ${esc(planPath)}</title>
<style>
:root{--bg:#f5f7fa;--sf:#fff;--bd:#d7dde6;--ink:#1a2029;--soft:#54606f;--faint:#8791a0;
--mech:#1f9d68;--std:#2560c4;--fro:#7c53e6;--bad:#cc4444;--mono:ui-monospace,Menlo,Consolas,monospace}
@media(prefers-color-scheme:dark){:root{--bg:#0d1117;--sf:#161c25;--bd:#2a3441;--ink:#e7ecf3;--soft:#9aa6b6;--faint:#647084;--mech:#43c78c;--std:#5b8cf0;--fro:#a689f7;--bad:#e5706b}}
:root[data-theme="light"]{--bg:#f5f7fa;--sf:#fff;--bd:#d7dde6;--ink:#1a2029;--soft:#54606f;--faint:#8791a0;--mech:#1f9d68;--std:#2560c4;--fro:#7c53e6;--bad:#cc4444}
:root[data-theme="dark"]{--bg:#0d1117;--sf:#161c25;--bd:#2a3441;--ink:#e7ecf3;--soft:#9aa6b6;--faint:#647084;--mech:#43c78c;--std:#5b8cf0;--fro:#a689f7;--bad:#e5706b}
*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--ink);font:15px/1.5 system-ui,-apple-system,sans-serif;padding:32px}
h1{font-size:22px;margin:0 0 4px}h3{font-size:13px;text-transform:uppercase;letter-spacing:.05em;color:var(--faint);font-family:var(--mono)}
.sub{color:var(--soft);font-family:var(--mono);font-size:12.5px;margin-bottom:22px}
.stats{display:flex;gap:12px;flex-wrap:wrap;margin-bottom:26px}
.stat{background:var(--sf);border:1px solid var(--bd);border-radius:10px;padding:10px 16px}
.stat b{font-size:20px;display:block}.stat span{font-size:11.5px;color:var(--faint);font-family:var(--mono)}
.problems{background:var(--sf);border:1px solid var(--bd);border-radius:12px;padding:14px 18px;margin-bottom:26px}
.problems li{margin:4px 0;color:var(--soft)}.problems b{color:var(--bad);font-family:var(--mono);font-size:12.5px}
.problems .ok{color:var(--mech)}
.waves{display:flex;gap:16px;overflow-x:auto;align-items:flex-start;padding-bottom:8px}
.wave{min-width:250px;flex:1}
.wave.bad h3{color:var(--bad)}
.card{background:var(--sf);border:1px solid var(--bd);border-radius:10px;padding:11px 13px;margin-bottom:10px}
.card h4{margin:0 0 4px;font-size:13.5px}.goal{margin:0 0 6px;font-size:12.5px;color:var(--soft)}
.files{margin:0;font-size:11px}.verify{margin:5px 0 0;font-size:11px;color:var(--faint)}
code{font-family:var(--mono);font-size:.9em;background:color-mix(in srgb,var(--bd) 40%,transparent);padding:1px 4px;border-radius:4px}
.chip{font-family:var(--mono);font-size:10px;font-weight:700;padding:1px 7px;border-radius:10px;vertical-align:1px}
.chip.mechanical{color:var(--mech);background:color-mix(in srgb,var(--mech) 14%,transparent)}
.chip.standard{color:var(--std);background:color-mix(in srgb,var(--std) 14%,transparent)}
.chip.frontier{color:var(--fro);background:color-mix(in srgb,var(--fro) 14%,transparent)}
.chip.bad{color:var(--bad);background:color-mix(in srgb,var(--bad) 14%,transparent)}
</style>
<h1>Plan review</h1>
<div class="sub">${esc(planPath)}</div>
<div class="stats">
  <div class="stat"><b>${stats.tasks}</b><span>tasks</span></div>
  <div class="stat"><b>${stats.waves}</b><span>waves</span></div>
  <div class="stat"><b style="color:var(--mech)">${stats.tiers.mechanical}</b><span>mechanical</span></div>
  <div class="stat"><b style="color:var(--std)">${stats.tiers.standard}</b><span>standard</span></div>
  <div class="stat"><b style="color:var(--fro)">${stats.tiers.frontier}</b><span>frontier</span></div>
  <div class="stat"><b style="color:var(--bad)">${problems.length}</b><span>problems</span></div>
</div>
<div class="problems"><h3>Auto-flagged problems</h3><ul>${probList}</ul></div>
<div class="waves">${waveCols}${unsched}</div>
`;
}

// ---------- CLI ----------

function main(argv) {
  const jsonMode = argv.includes('--json');
  const planPath = argv.find(a => !a.startsWith('--'));
  if (!planPath) { console.error('usage: plan-viz.mjs <plan.md> [--json]'); process.exit(1); }
  const tasksJson = JSON.parse(readFileSync(planPath + '.tasks.json', 'utf8'));
  const analysis = analyze(tasksJson);
  if (jsonMode) {
    const { stats, waves, problems } = analysis;
    console.log(JSON.stringify({ stats, waves, problems }, null, 1));
    return;
  }
  const out = planPath + '.html';
  writeFileSync(out, renderHTML(planPath, analysis));
  console.log(out);
}

if (import.meta.url === `file://${process.argv[1]}`) main(process.argv.slice(2));
