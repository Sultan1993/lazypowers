// plan-viz.mjs — render a superlazy plan as a self-contained HTML page.
// Pure node, zero deps. Usage: node plan-viz.mjs <plan.md> [--json]
//   HTML  -> <plan.md>.html (path printed)
//   --json -> {stats, waves, problems} on stdout (test surface; no HTML write)
//
// The page is the PLAN, explained: the brief, then every task in execution
// order with its goal, steps, files, acceptance criteria and verify command.
// The structural checks are a footnote at the bottom, not the headline — a
// reader wants to know what will be built, not that the linter found nothing.
// Content comes from the plan MARKDOWN; .tasks.json supplies the dependency
// graph. tasks.json is the mirror, so section order matches task order.

import { readFileSync, writeFileSync, existsSync } from 'node:fs';

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

// The plan markdown is the source; tasks.json is its hand-derived mirror, and
// build executes the JSON while you read the markdown. If they drift, the page
// pairs one task's heading with another's metadata and nothing looks wrong —
// so check the pairing explicitly. (1.6.0 enforced this as an approval gate;
// here it is a reported finding, which is the same information without the gate.)
export function detectPlanDrift(tasks, planTasks) {
  if (!Array.isArray(planTasks) || planTasks.length === 0) return [];
  const problems = [];
  const norm = s => String(s ?? '').replace(/\s+/g, ' ').trim();
  if (planTasks.length !== tasks.length) {
    problems.push({
      kind: 'plan-tasks-count-mismatch', task: null,
      detail: `plan markdown has ${planTasks.length} task sections, tasks.json has ${tasks.length} — the page and the executed plan are not the same set`,
    });
  }
  const n = Math.min(planTasks.length, tasks.length);
  for (let i = 0; i < n; i++) {
    if (norm(planTasks[i].heading) !== norm(tasks[i].subject)) {
      problems.push({
        kind: 'plan-tasks-order-mismatch', task: tasks[i].id,
        detail: `position ${i}: plan markdown says "${norm(planTasks[i].heading)}", tasks.json says "${norm(tasks[i].subject)}" — metadata is being shown against the wrong task`,
      });
    } else if (planTasks[i].fence && !sameFence(planTasks[i].fence, tasks[i].fence)) {
      problems.push({
        kind: 'plan-tasks-fence-drift', task: tasks[i].id,
        detail: `json:metadata differs between the plan markdown and tasks.json — build executes the tasks.json version, not the one on this page`,
      });
    }
  }
  return problems;
}

function sameFence(rawMd, parsedJson) {
  try { return JSON.stringify(JSON.parse(rawMd)) === JSON.stringify(parsedJson); }
  catch { return false; }
}

export function analyze(tasksJson, planTasks = null) {
  const tasks = parseTasks(tasksJson);
  const { waves, unschedulable, problems: waveProblems } = computeWaves(tasks);
  const problems = [...waveProblems, ...detectProblems(tasks, waves), ...detectPlanDrift(tasks, planTasks)];
  return { stats: computeStats(tasks, waves), waves, unschedulable, problems, tasks };
}

// ---------- plan markdown ----------

// Fence-aware section walk: a '### Task' heading inside a ``` block is an
// example, not a task. Any other unfenced H2/H3 ends the current section.
export function parsePlanMarkdown(src) {
  const lines = String(src ?? '').split('\n');
  const ranges = [];
  let inCode = false, cur = null;
  for (let n = 0; n < lines.length; n++) {
    if (/^\s*```/.test(lines[n])) { inCode = !inCode; continue; }
    if (inCode) continue;
    if (/^### Task\b/.test(lines[n])) { if (cur !== null) ranges.push([cur, n]); cur = n; }
    else if (/^#{2,3} /.test(lines[n]) && cur !== null) { ranges.push([cur, n]); cur = null; }
  }
  if (cur !== null) ranges.push([cur, lines.length]);

  const intro = lines.slice(0, ranges.length ? ranges[0][0] : lines.length).join('\n');
  const trailing = ranges.length ? lines.slice(ranges[ranges.length - 1][1]).join('\n') : '';
  const tasks = ranges.map(([a, b]) => {
    const body = lines.slice(a + 1, b).join('\n');
    return {
      heading: lines[a].replace(/^###\s*/, '').trim(),
      fence: /```json:metadata\n([\s\S]*?)\n```/.exec(body)?.[1] ?? null,
      ...splitFields(body),
    };
  });
  return { intro, trailing, tasks };
}

// Split a task body on its **Field:** markers. The json:metadata fence is
// dropped — it is rendered from the parsed object instead.
export function splitFields(body) {
  const src = String(body ?? '').replace(/```json:metadata\n[\s\S]*?\n```/g, '').trim();
  const marks = [...src.matchAll(/^\*\*([^:*\n]+):\*\*/gm)];
  if (!marks.length) return { prose: src, fields: {} };
  const fields = {};
  marks.forEach((m, i) => {
    const start = m.index + m[0].length;
    const end = i + 1 < marks.length ? marks[i + 1].index : src.length;
    fields[m[1].trim().toLowerCase()] = src.slice(start, end).trim();
  });
  return { prose: src.slice(0, marks[0].index).trim(), fields };
}

// ---------- HTML ----------

const esc = s => String(s).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');

// Content here is LLM-authored and the page may be published, so only http(s)
// and in-page anchors become links; anything else renders as plain text.
const safeHref = u => /^(https?:\/\/|#|\.{0,2}\/)/i.test(u) ? u : null;

const mdInline = s => esc(s)
  .replace(/`([^`]+)`/g, '<code>$1</code>')
  .replace(/\*\*([^*]+)\*\*/g, '<strong>$1</strong>')
  .replace(/\[([^\]]+)\]\(([^)\s]+)\)/g, (m, text, url) =>
    safeHref(url) ? `<a href="${url}">${text}</a>` : `${text} (${url})`);

// Enough markdown for what plans actually contain: fenced code, lists,
// headings, paragraphs, inline code/bold/links. Not a spec-compliant parser.
export function mdToHtml(src) {
  const lines = String(src ?? '').split('\n');
  const out = [];
  let i = 0, list = null;
  const closeList = () => { if (list) { out.push(`</${list}>`); list = null; } };
  while (i < lines.length) {
    const fence = /^\s*```(\S*)/.exec(lines[i]);
    if (fence) {
      closeList();
      const buf = [];
      i++;
      while (i < lines.length && !/^\s*```/.test(lines[i])) buf.push(lines[i++]);
      i++;
      out.push(`<pre class="code"><code>${esc(buf.join('\n'))}</code></pre>`);
      continue;
    }
    const item = /^\s*([-*]|\d+[.)])\s+(.*)$/.exec(lines[i]);
    if (item) {
      const want = /^[-*]$/.test(item[1]) ? 'ul' : 'ol';
      if (list !== want) { closeList(); out.push(`<${want}>`); list = want; }
      out.push(`<li>${mdInline(item[2])}</li>`);
      i++; continue;
    }
    if (!lines[i].trim()) { closeList(); i++; continue; }
    closeList();
    const h = /^(#{1,6})\s+(.*)$/.exec(lines[i]);
    if (h) { out.push(`<h4>${mdInline(h[2])}</h4>`); i++; continue; }
    const buf = [lines[i++]];
    while (i < lines.length && lines[i].trim()
      && !/^\s*```/.test(lines[i]) && !/^\s*([-*]|\d+[.)])\s+/.test(lines[i]) && !/^#{1,6}\s/.test(lines[i])) {
      buf.push(lines[i++]);
    }
    out.push(`<p>${mdInline(buf.join(' '))}</p>`);
  }
  closeList();
  return out.join('\n');
}

export function renderHTML(planPath, analysis, plan = { intro: '', trailing: '', tasks: [] }) {
  const { stats, waves, unschedulable, problems, tasks } = analysis;
  const byId = new Map(tasks.map(t => [t.id, t]));
  const posById = new Map(tasks.map((t, i) => [t.id, i]));
  const tierChip = t => `<span class="chip ${esc(t)}">${esc(t)}</span>`;

  // The plan's `Spec:` pointer and H1, lifted out of the intro for the header.
  const specLine = /^Spec:\s*(\S+)/m.exec(plan.intro ?? '')?.[1] ?? '';
  const title = /^#\s+(.+)$/m.exec(plan.intro ?? '')?.[1] ?? 'Implementation plan';
  const brief = String(plan.intro ?? '')
    .replace(/^Spec:.*$/m, '')
    .replace(/^#\s+.+$/m, '')
    .trim();

  const card = id => {
    const t = byId.get(id);
    if (!t) return '';
    const f = t.fence ?? {};
    const md = plan.tasks[posById.get(id)] ?? { fields: {}, prose: '' };
    const F = md.fields ?? {};
    const deps = (t.blockedBy ?? []).map(d => byId.get(d)).filter(Boolean);
    const criteria = Array.isArray(f.acceptanceCriteria) && f.acceptanceCriteria.length
      ? `<ul class="crit">${f.acceptanceCriteria.map(c => `<li>${mdInline(c)}</li>`).join('')}</ul>`
      : mdToHtml(F['acceptance criteria'] ?? '');
    const files = (f.files ?? []).length
      ? `<p class="files">${f.files.map(x => `<code>${esc(x)}</code>`).join(' ')}</p>`
      : mdToHtml(F.files ?? '');
    const block = (label, body) => body && body.trim()
      ? `<div class="blk"><h5>${label}</h5>${body}</div>` : '';

    return `<article class="card" id="task-${esc(t.id)}">
  <header>
    <h4>${esc(md.heading || t.subject)}</h4>
    <div class="meta">
      ${f.modelTier ? tierChip(f.modelTier) : '<span class="chip bad">no tier</span>'}
      ${deps.length
        ? `<span class="after">after ${deps.map(d => `<a href="#task-${esc(d.id)}">${esc(d.subject)}</a>`).join(', ')}</span>`
        : '<span class="after free">no dependencies</span>'}
    </div>
  </header>
  ${block('Goal', mdToHtml(F.goal ?? md.prose ?? ''))}
  ${block('Files', files)}
  ${block('Steps', mdToHtml(F.steps ?? ''))}
  ${block('Done when', criteria)}
  ${block('Verify', f.verifyCommand
      ? `<pre class="code"><code>${esc(String(f.verifyCommand))}</code></pre>`
      : mdToHtml(F.verify ?? ''))}
</article>`;
  };

  const waveSections = waves.map((w, i) => `
<section class="wave">
  <h3><span class="wnum">Wave ${i + 1}</span>
    <span class="wmeta">${w.length} task${w.length === 1 ? '' : 's'}${w.length > 1 ? ' · run in parallel' : ''}</span></h3>
  <div class="grid">${w.map(card).join('')}</div>
</section>`).join('');

  const unsched = unschedulable.length ? `
<section class="wave bad">
  <h3><span class="wnum">Unschedulable</span><span class="wmeta">dependency cycle — cannot run</span></h3>
  <div class="grid">${unschedulable.map(card).join('')}</div>
</section>` : '';

  const probList = problems.length
    ? problems.map(p => `<li><b>${esc(p.kind)}</b>${p.task !== null && p.task !== undefined ? ` · task ${p.task}` : ''} — ${esc(p.detail)}</li>`).join('')
    : '<li class="ok">none — plan is structurally clean</li>';

  return `<!doctype html><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>${esc(title)}</title>
<style>
:root{--bg:#f5f7fa;--sf:#fff;--sf2:#eef1f6;--bd:#d7dde6;--ink:#1a2029;--soft:#54606f;--faint:#8791a0;
--mech:#1f9d68;--std:#2560c4;--fro:#7c53e6;--bad:#cc4444;--mono:ui-monospace,Menlo,Consolas,monospace}
@media(prefers-color-scheme:dark){:root{--bg:#0d1117;--sf:#161c25;--sf2:#1c232e;--bd:#2a3441;--ink:#e7ecf3;--soft:#9aa6b6;--faint:#647084;--mech:#43c78c;--std:#5b8cf0;--fro:#a689f7;--bad:#e5706b}}
:root[data-theme="light"]{--bg:#f5f7fa;--sf:#fff;--sf2:#eef1f6;--bd:#d7dde6;--ink:#1a2029;--soft:#54606f;--faint:#8791a0;--mech:#1f9d68;--std:#2560c4;--fro:#7c53e6;--bad:#cc4444}
:root[data-theme="dark"]{--bg:#0d1117;--sf:#161c25;--sf2:#1c232e;--bd:#2a3441;--ink:#e7ecf3;--soft:#9aa6b6;--faint:#647084;--mech:#43c78c;--std:#5b8cf0;--fro:#a689f7;--bad:#e5706b}
*{box-sizing:border-box}
body{margin:0 auto;max-width:1180px;background:var(--bg);color:var(--ink);font:15px/1.62 system-ui,-apple-system,sans-serif;padding:40px 24px 72px}
a{color:var(--std)}
h1{font-size:27px;line-height:1.25;margin:0 0 6px;letter-spacing:-.01em}
h3{font-size:12.5px;text-transform:uppercase;letter-spacing:.06em;font-family:var(--mono);margin:0 0 14px;display:flex;align-items:baseline;gap:10px;flex-wrap:wrap}
.wnum{color:var(--ink);font-weight:700}.wmeta{color:var(--faint);text-transform:none;letter-spacing:0}
.sub{color:var(--soft);font-family:var(--mono);font-size:12.5px;margin-bottom:24px;word-break:break-all}
.stats{display:flex;gap:10px;flex-wrap:wrap;margin-bottom:30px}
.stat{background:var(--sf);border:1px solid var(--bd);border-radius:10px;padding:9px 15px}
.stat b{font-size:19px;display:block;line-height:1.2}.stat span{font-size:11px;color:var(--faint);font-family:var(--mono)}
.brief{background:var(--sf);border:1px solid var(--bd);border-left:3px solid var(--std);border-radius:10px;padding:4px 20px;margin-bottom:34px}
.brief h4{font-size:14px;margin:14px 0 6px}
.wave{margin-bottom:34px}.wave.bad .wnum{color:var(--bad)}
.grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(330px,1fr));gap:14px;align-items:start}
.card{background:var(--sf);border:1px solid var(--bd);border-radius:12px;padding:15px 17px 5px}
.card header{border-bottom:1px solid var(--bd);padding-bottom:10px;margin-bottom:12px}
.card h4{margin:0 0 7px;font-size:15px;line-height:1.35}
.meta{display:flex;gap:8px;align-items:center;flex-wrap:wrap}
.after{font-family:var(--mono);font-size:10.5px;color:var(--faint)}.after.free{opacity:.65}
.blk{margin-bottom:14px}
.blk h5{margin:0 0 5px;font:600 10.5px/1 var(--mono);text-transform:uppercase;letter-spacing:.07em;color:var(--faint)}
.blk p{margin:0 0 7px}.blk ul,.blk ol{margin:0 0 7px;padding-left:20px}.blk li{margin:2px 0}
.blk :last-child{margin-bottom:0}
.crit li{color:var(--soft)}
.files code{display:inline-block;margin:0 4px 4px 0}
pre.code{background:var(--sf2);border:1px solid var(--bd);border-radius:8px;padding:9px 11px;overflow-x:auto;max-height:260px;overflow-y:auto;margin:0 0 7px}
pre.code code{background:none;padding:0;font-size:11.5px;line-height:1.5;white-space:pre}
code{font-family:var(--mono);font-size:.88em;background:color-mix(in srgb,var(--bd) 45%,transparent);padding:1px 5px;border-radius:4px;word-break:break-word}
.chip{font-family:var(--mono);font-size:10px;font-weight:700;padding:2px 8px;border-radius:10px}
.chip.mechanical{color:var(--mech);background:color-mix(in srgb,var(--mech) 14%,transparent)}
.chip.standard{color:var(--std);background:color-mix(in srgb,var(--std) 14%,transparent)}
.chip.frontier{color:var(--fro);background:color-mix(in srgb,var(--fro) 14%,transparent)}
.chip.bad{color:var(--bad);background:color-mix(in srgb,var(--bad) 14%,transparent)}
details.checks{background:var(--sf);border:1px solid var(--bd);border-radius:10px;padding:12px 18px;margin-top:10px}
details.checks summary{cursor:pointer;font:600 11.5px/1 var(--mono);text-transform:uppercase;letter-spacing:.06em;color:var(--faint)}
details.checks ul{margin:12px 0 2px;padding-left:20px}
details.checks li{margin:4px 0;color:var(--soft)}
details.checks b{color:var(--bad);font-family:var(--mono);font-size:12.5px}
details.checks .ok{color:var(--mech)}
</style>
<h1>${esc(title)}</h1>
<div class="sub">${esc(planPath)}${specLine ? ` &nbsp;·&nbsp; spec: ${esc(specLine)}` : ''}</div>
<div class="stats">
  <div class="stat"><b>${stats.tasks}</b><span>tasks</span></div>
  <div class="stat"><b>${stats.waves}</b><span>waves</span></div>
  <div class="stat"><b style="color:var(--mech)">${stats.tiers.mechanical}</b><span>mechanical</span></div>
  <div class="stat"><b style="color:var(--std)">${stats.tiers.standard}</b><span>standard</span></div>
  <div class="stat"><b style="color:var(--fro)">${stats.tiers.frontier}</b><span>frontier</span></div>
</div>
${brief ? `<div class="brief">${mdToHtml(brief)}</div>` : ''}
${waveSections}${unsched}
${plan.trailing && plan.trailing.trim() ? `<div class="brief">${mdToHtml(plan.trailing)}</div>` : ''}
<details class="checks"${problems.length ? ' open' : ''}>
  <summary>Structural checks (${problems.length})</summary>
  <ul>${probList}</ul>
</details>
`;
}

// ---------- CLI ----------

function main(argv) {
  const jsonMode = argv.includes('--json');
  const planPath = argv.find(a => !a.startsWith('--'));
  if (!planPath) { console.error('usage: plan-viz.mjs <plan.md> [--json]'); process.exit(1); }
  const tasksJson = JSON.parse(readFileSync(planPath + '.tasks.json', 'utf8'));
  // Content lives in the markdown; degrade to graph-only if it is missing.
  const plan = existsSync(planPath)
    ? parsePlanMarkdown(readFileSync(planPath, 'utf8'))
    : { intro: '', trailing: '', tasks: [] };
  const analysis = analyze(tasksJson, plan.tasks);
  if (jsonMode) {
    const { stats, waves, problems } = analysis;
    console.log(JSON.stringify({ stats, waves, problems }, null, 1));
    return;
  }
  const out = planPath + '.html';
  writeFileSync(out, renderHTML(planPath, analysis, plan));
  console.log(out);
  // stdout stays the path alone (callers consume it); findings go to stderr so
  // a coordinator that only reads the path still cannot miss them.
  if (analysis.problems.length) {
    console.error(`plan-viz: ${analysis.problems.length} structural problem(s) — REPORT THESE TO THE USER:`);
    for (const p of analysis.problems) {
      console.error(`  [${p.kind}]${p.task !== null && p.task !== undefined ? ` task ${p.task}` : ''} — ${p.detail}`);
    }
  }
}

if (import.meta.url === `file://${process.argv[1]}`) main(process.argv.slice(2));
