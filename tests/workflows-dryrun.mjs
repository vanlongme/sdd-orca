// Mock dry-run for review-gate, sweep and verify-facts: every agent() call is answered by a mock. Run: node tests/workflows-dryrun.mjs
import fs from 'node:fs'
Date.now = () => { throw new Error('Date.now used') }
Math.random = () => { throw new Error('Math.random used') }
const dir = new URL('../workflows/', import.meta.url).pathname
async function run(file, args, mock) {
  const src = fs.readFileSync(dir + file, 'utf8')
  const metaSrc = src.match(/export const meta = (\{[\s\S]*?\n\})\n/)[1]
  const meta = Function('return ' + metaSrc)()  // literal check: evaluates with no free variables
  const body = src.replace(/export const meta = /, 'const meta = ')
  const calls = []
  const agent = async (prompt, opts = {}) => { calls.push({ label: opts.label, model: opts.model, effort: opts.effort, phase: opts.phase }); return mock(prompt, opts, calls.length) }
  const parallel = async thunks => Promise.all(thunks.map(t => t().catch(() => null)))
  const pipeline = async (items, ...stages) => Promise.all(items.map(async (it, i) => { let r = it; for (const s of stages) { try { r = await s(r, it, i) } catch { return null } } return r }))
  const logs = []
  const fn = new Function('args', 'agent', 'parallel', 'pipeline', 'log', 'phase', 'budget', 'workflow', `return (async () => {${body}\n})()`)
  const out = await fn(args, agent, parallel, pipeline, m => logs.push(m), () => {}, { total: null }, async () => null)
  const phases = meta.phases.map(p => p.title)
  const badPhase = calls.filter(c => c.phase && !phases.includes(c.phase))
  return { name: meta.name, agents: calls.length, labels: calls.map(c => `${c.label}(${c.model || 'inherit'}/${c.effort || '-'})`).join(' '), logs, out, badPhase }
}
const has = (o, k) => o.schema && o.schema.properties && k in o.schema.properties
let rv = 0
let failures = 0
const show = (t, r) => { console.log(`\n## ${t}\nagents=${r.agents} badPhase=${r.badPhase.length}\n${r.labels}\nlogs=${JSON.stringify(r.logs)}\nout=${JSON.stringify(r.out).slice(0, 600)}`); return r }
const expect = (name, cond) => { if (!cond) failures++; console.log(`${cond ? 'PASS' : 'FAIL'} ${name}`) }

// sdd-run (v2) has its own dry-run: sdd-dryrun.mjs

// review-gate: multi-tenant preset, duplicates + a critical finding, one verifier dies
let r = show('review-gate multi-tenant', await run('review-gate.js', { base: 'main', preset: 'multi-tenant', maxVerify: 4 }, (p, o) => {
  if (has(o, 'findings')) {
    const k = o.label.split(':')[1]
    if (k === 'tenancy') return { findings: [{ file: 'svc/a.go', line: 10, severity: 'critical', title: 'leak', scenario: 's' }, { file: 'svc/b.go', line: 5, severity: 'medium', title: 'm', scenario: 's' }] }
    if (k === 'auth') return { findings: [{ file: 'svc/a.go', line: 10, severity: 'high', title: 'dup', scenario: 's' }, { file: 'web/c.ts', line: 3, severity: 'high', title: 'h', scenario: 's' }] }
    if (k === 'evidence') return { findings: [{ file: 'x.md', line: 1, severity: 'medium', title: 'doc', scenario: 's' }, { file: 'y.go', line: 2, severity: 'medium', title: 'y', scenario: 's' }] }
    return { findings: [] }
  }
  if (has(o, 'refuted')) { if (o.label.startsWith('verify:c.ts')) throw new Error('agent died'); return { refuted: o.label.includes(':security') ? false : true, reason: 'r' } }
}))
expect('review-gate: duplicates merged, critical gets a second security vote and survives', r.out.confirmed.length === 1 && r.out.confirmed[0].title === 'leak' && r.out.confirmed[0].votes.length === 2 && !r.badPhase.length)
expect('review-gate: refuted, dead-verifier and over-cap findings are reported, not dropped', r.out.refuted.length === 2 && r.out.unverified.map(u => u.where).join() === 'web/c.ts:3,y.go:2' && r.agents === 10)
r = show('review-gate empty', await run('review-gate.js', 'main', (p, o) => ({ findings: [] })))
expect('review-gate: no findings -> no verifiers, default dimensions', r.agents === 4 && r.out.confirmed.length === 0 && r.out.dimensions.join() === 'correctness,security,tests,contracts')
r = await run('review-gate.js', {}, () => null)
expect('review-gate: missing base is refused without agents', r.out.started === false && r.agents === 0)

// sweep report + edit
r = show('sweep report', await run('sweep.js', { items: ['services/a', 'services/b', 'apps/c'], task: 'docs drift' }, (p, o) => {
  if (has(o, 'findings')) return { item: 'i', summary: 's', findings: [{ severity: 'high', where: 'f', issue: 'i' }] }
  if (has(o, 'top')) return { top: [], themes: ['t'] }
}))
expect('sweep report: one agent per item plus a synthesis', r.agents === 4 && r.out.reports.length === 3 && r.out.missing.length === 0 && r.out.synthesis.themes[0] === 't')
r = show('sweep edit blocked', await run('sweep.js', JSON.stringify({ items: ['a', 'b', 'c'], task: 'translate comments', mode: 'edit', model: 'haiku', effort: 'low' }), (p, o) => {
  return o.label === 'edit:b' ? { item: 'b', status: 'blocked', summary: 'conflict' } : { item: 'a', status: 'done', commit: 'c'.repeat(40), summary: 's' }
}))
expect('sweep edit: sequential, stops at the first blocked item', r.agents === 2 && r.out.done === 1 && r.out.notReached.join() === 'c' && r.logs.includes('stopped at b: conflict'))
try { await run('sweep.js', { items: ['../etc'], task: 't' }, () => null); expect('sweep: path traversal rejected', false) } catch (e) { expect(`sweep: path traversal rejected (${e.message})`, /unsafe item/.test(e.message)) }

// verify-facts from newline string
r = show('verify-facts', await run('verify-facts.js', 'Go 1.26 is supported\nGitHub Free private repos get code scanning', (p, o) => ({ claim: 'c', verdict: o.label === 'fact:2' ? 'refuted' : 'confirmed', sources: [{ url: 'u', quote: 'q' }] })))
expect('verify-facts: newline-separated claims, counted verdicts', r.agents === 2 && r.out.counts.confirmed === 1 && r.out.counts.refuted === 1)
console.log(failures ? `\n${failures} FAILURE(S)` : '\nALL PASS')
process.exitCode = failures ? 1 : 0
