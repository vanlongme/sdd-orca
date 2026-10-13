// Mock dry-run for workflows/sdd-run.js: every agent() call is answered by a scenario mock. Run: node tests/sdd-dryrun.mjs
import fs from 'node:fs'
Date.now = () => { throw new Error('Date.now used') }
Math.random = () => { throw new Error('Math.random used') }
const src = fs.readFileSync(new URL('../workflows/sdd-run.js', import.meta.url), 'utf8')
const meta = Function('return ' + src.match(/export const meta = (\{[\s\S]*?\n\})\n/)[1])()
const body = src.replace(/export const meta = /, 'const meta = ')
const phases = meta.phases.map(p => p.title)
let failures = 0
const sha = n => n.toString(16).padStart(40, '0')

async function run(args, mock) {
  const calls = []
  let n = 0
  const agent = async (prompt, o = {}) => { n++; calls.push({ label: o.label, model: o.model, phase: o.phase, prompt }); const r = mock(o.label || '', prompt, n); if (r instanceof Error) throw r; return r }
  const logs = []
  const fn = new Function('args', 'agent', 'parallel', 'pipeline', 'log', 'phase', `return (async () => {${body}\n})()`)
  const out = await fn(args, agent, async ts => Promise.all(ts.map(t => t().catch(() => null))), null, m => logs.push(m), () => {})
  return { out, calls, logs, labels: calls.map(c => `${c.label}(${c.model})`).join(' '), badPhase: calls.filter(c => !phases.includes(c.phase)).map(c => c.label) }
}
function check(name, cond, r) {
  if (!cond) failures++
  console.log(`${cond ? 'PASS' : 'FAIL'} ${name}\n   agents=${r.calls.length} ${r.labels}${r.badPhase.length ? `\n   BAD PHASE ${r.badPhase}` : ''}${r.logs.length ? `\n   logs=${JSON.stringify(r.logs)}` : ''}`)
  if (!cond) console.log('   out=' + JSON.stringify(r.out).slice(0, 900))
}
const SDD = '/home/u/.claude/plugins/cache/x/sdd-orca/0.1.0/skills/subagent-driven-development'
const pre = (tasks, extra = {}) => ({ sddDir: SDD, workspace: '/r/.superpowers/sdd/p', ledger: '/r/.superpowers/sdd/p/progress.md', constraints: '/r/.superpowers/sdd/p/constraints.md', head: sha(1), specFound: true, rulings: [{ ruling: 'Ruling: plan-wide — why — cost' }], tasks: tasks.map(([n, tier, done]) => ({ n, title: `t${n}`, tier, done: Boolean(done), brief: done ? '' : `/r/.superpowers/sdd/p/task-${n}-brief.md` })), ...extra })
const clean = { specOk: true, approved: true, issues: [], cannotVerify: [] }
let h = 100
const done = () => ({ status: 'DONE', commits: 1, tests: 'ok' })

// 1. happy path with a task fix round, a ⚠️ item, a final fix wave and verify
{
  let rv1 = 0
  const r = await run({ plan: 'docs/plans/p.md', verify: 'make check' }, (l) => {
    if (l === 'preflight') return pre([[1, 'transcribe'], [2, 'integrate'], [3, 'design']])
    if (l.startsWith('impl:') || l.startsWith('fix:') || l === 'final-fix') return done()
    if (l === 'review:1') return rv1++ ? clean : { specOk: true, approved: false, issues: [{ severity: 'important', where: 'a.go:1', problem: 'x' }, { severity: 'minor', where: 'a.go:9', problem: 'nit' }], cannotVerify: [] }
    if (l === 'review:3') return { ...clean, cannotVerify: ['config default lives in unchanged code'] }
    if (l.startsWith('review:')) return clean
    if (l.startsWith('gaps:')) return { gaps: [] }
    if (l.startsWith('rereview') || l === 'final-rereview') return { verdicts: [{ finding: 'x', addressed: true }], newBreakage: [], outOfScope: [] }
    if (l === 'final-review') return { ready: false, issues: [{ severity: 'important', where: 'b.go:2', problem: 'y' }], declined: [] }
    if (l === 'verify') return { passed: true, summary: 'ok' }
    if (l.startsWith('ledger:')) return { appended: true }
  })
  const m = Object.fromEntries(r.calls.map(c => [c.label, c.model]))
  check('happy path', r.out.completed === 3 && m['impl:1'] === 'haiku' && m['impl:2'] === 'sonnet' && m['impl:3'] === 'opus' && m['review:3'] === 'opus' && m['review:1'] === 'sonnet' && m['fix:1#1'] === 'haiku' && r.out.verify?.passed && r.out.final.ready && r.out.deferredMinors === 1 && r.calls.some(c => c.label === 'gaps:3') && r.out.rulings.length === 1 && !r.badPhase.length, r)
}
// 2. NEEDS_CONTEXT answered, then escalated BLOCKED
{
  let i1 = 0
  const r = await run({ plan: 'p.md' }, (l) => {
    if (l === 'preflight') return pre([[1, 'integrate'], [2, 'transcribe']])
    if (l === 'impl:1') return i1++ ? done() : { status: 'NEEDS_CONTEXT', commits: 0, tests: '', question: 'which port?' }
    if (l === 'impl:1+') return done()
    if (l === 'impl:2') return { status: 'BLOCKED', commits: 0, tests: '', question: 'too hard' }
    if (l === 'impl:2+') return done()
    if (l === 'resolve:1') return { action: 'answer', answer: 'use 8080', ruling: 'Ruling: port 8080 — plan silent — rework' }
    if (l === 'resolve:2') return { action: 'escalate', answer: 'think harder' }
    if (l.startsWith('review:')) return clean
    if (l === 'final-review') return { ready: true, issues: [], declined: [] }
    return { appended: true }
  })
  const m = Object.fromEntries(r.calls.map(c => [c.label, c.model]))
  check('needs-context answered + blocked escalated', r.out.completed === 2 && m['impl:2+'] === 'sonnet' && r.calls.find(c => c.label === 'impl:1+').prompt.includes('use 8080') && r.out.rulings.some(x => x.includes('port 8080')), r)
}
// 3. BLOCKED, resolver says stop -> stopped, no final review, verify skipped
{
  const r = await run({ plan: 'p.md', verify: 'make check' }, (l) => {
    if (l === 'preflight') return pre([[1, 'integrate'], [2, 'integrate']])
    if (l === 'impl:1') return done()
    if (l === 'review:1') return clean
    if (l === 'impl:2') return { status: 'BLOCKED', commits: 0, tests: '', question: 'disk full' }
    if (l === 'resolve:2') return { action: 'stop', answer: 'host out of disk' }
    return { appended: true }
  })
  check('blocked -> stop', r.out.stopped?.task === 2 && !r.out.final && !r.out.verify && r.logs.some(x => x.includes('stopped at Task 2')), r)
}
// 4. review never passes -> 3 rounds, last one tier up, breaker parks, run continues
{
  const r = await run({ plan: 'p.md' }, (l) => {
    if (l === 'preflight') return pre([[1, 'transcribe']])
    if (l.startsWith('impl:') || l.startsWith('fix:')) return done()
    if (l === 'review:1') return { specOk: false, approved: false, issues: [{ severity: 'critical', where: 'x:1', problem: 'p' }], cannotVerify: [] }
    if (l.startsWith('rereview')) return { verdicts: [{ finding: 'p', addressed: false }], newBreakage: [], outOfScope: ['elsewhere'] }
    if (l === 'breaker:1') return { decisions: [{ finding: 'p', decision: 'park', ruling: 'contestable — why — cost' }], stop: false }
    if (l === 'final-review') return { ready: true, issues: [], declined: [] }
    return { appended: true }
  })
  const m = Object.fromEntries(r.calls.map(c => [c.label, c.model]))
  check('cap -> escalate -> breaker park', r.out.completed === 1 && r.out.results[0].fixRounds === 3 && r.out.results[0].parked === 1 && m['fix:1#2'] === 'haiku' && m['fix:1#3'] === 'sonnet' && r.out.deferredMinors === 3, r)
}
// 5. breaker carry + stop
{
  const r = await run({ plan: 'p.md', maxFixRounds: 1 }, (l) => {
    if (l === 'preflight') return pre([[1, 'integrate'], [2, 'integrate']])
    if (l.startsWith('impl:') || l.startsWith('fix:')) return done()
    if (l === 'review:1') return { specOk: true, approved: false, issues: [{ severity: 'important', where: 'x:1', problem: 'p' }], cannotVerify: [] }
    if (l.startsWith('rereview')) return { verdicts: [{ finding: 'p', addressed: false }], newBreakage: [{ severity: 'critical', where: 'y:2', problem: 'new' }], outOfScope: [] }
    if (l === 'breaker:1') return { decisions: [{ finding: 'p', decision: 'carry', ruling: 'r1' }, { finding: 'new', decision: 'carry', ruling: 'r2' }], stop: true, stopReason: 'guess' }
    return { appended: true }
  })
  check('breaker carry + stop', r.out.stopped?.reason === 'guess' && r.out.results[0].status === 'stopped' && !r.calls.some(c => c.label === 'impl:2') && r.calls.find(c => c.label === 'fix:1#1').model === 'sonnet', r)
}
// 6. plan-mandated finding parked by ruling -> no fix loop
{
  const r = await run({ plan: 'p.md' }, (l) => {
    if (l === 'preflight') return pre([[1, 'integrate'], [2, 'integrate']])
    if (l.startsWith('impl:')) return done()
    if (l === 'review:1') return { specOk: true, approved: false, issues: [{ severity: 'important', where: 't_test.go:3', problem: 'asserts nothing', planMandated: true }], cannotVerify: [] }
    if (l.startsWith('review:')) return clean
    if (l === 'mandated:1') return { decisions: [{ finding: 'asserts nothing', decision: 'park', ruling: 'smoke test by design — why — cost' }], stop: false }
    if (l === 'final-review') return { ready: true, issues: [], declined: [] }
    return { appended: true }
  })
  check('plan-mandated parked', r.out.completed === 2 && !r.calls.some(c => c.label.startsWith('fix:')) && r.out.results[0].parked === 1 && r.calls.find(c => c.label === 'impl:2').prompt.includes('t2'), r)
}
// 7. carried ruling reaches the next implementer
{
  const r = await run({ plan: 'p.md', maxFixRounds: 1 }, (l) => {
    if (l === 'preflight') return pre([[1, 'integrate'], [2, 'integrate']])
    if (l.startsWith('impl:') || l.startsWith('fix:')) return done()
    if (l === 'review:1') return { specOk: true, approved: false, issues: [{ severity: 'important', where: 'x:1', problem: 'p' }], cannotVerify: [] }
    if (l.startsWith('review:')) return clean
    if (l.startsWith('rereview')) return { verdicts: [{ finding: 'p', addressed: false }], newBreakage: [], outOfScope: [] }
    if (l === 'breaker:1') return { decisions: [{ finding: 'p', decision: 'carry', ruling: 'rename Foo to Bar' }], stop: false }
    if (l === 'final-review') return { ready: true, issues: [], declined: [] }
    return { appended: true }
  })
  check('carry reaches next dispatch', r.out.completed === 2 && r.calls.find(c => c.label === 'impl:2').prompt.includes('rename Foo to Bar'), r)
}
// 8. resume: ledger says Task 1 complete; from/only selection
{
  const r = await run({ plan: 'p.md', from: 'Task 3' }, (l) => {
    if (l === 'preflight') return pre([[1, 'integrate', true], [2, 'integrate'], [3, 'integrate']])
    if (l.startsWith('impl:')) return done()
    if (l.startsWith('review:')) return clean
    if (l === 'final-review') return { ready: true, issues: [], declined: [] }
    return { appended: true }
  })
  check('resume + from', r.out.completed === 1 && r.out.results[0].n === 3 && !r.calls.some(c => c.label === 'impl:1' || c.label === 'impl:2'), r)
}
// 9. implementer reports DONE without committing -> stopped
{
  const r = await run({ plan: 'p.md' }, (l) => {
    if (l === 'preflight') return pre([[1, 'integrate']])
    if (l === 'impl:1') return { status: 'DONE', commits: 0, tests: 'ok' }
    return { appended: true }
  })
  check('no commit -> stopped', r.out.stopped?.reason === 'implementer made no commit', r)
}
// 10. final residual after fix wave -> adjudicated, not ready
{
  const r = await run({ plan: 'p.md' }, (l) => {
    if (l === 'preflight') return pre([[1, 'integrate']])
    if (l.startsWith('impl:') || l === 'final-fix') return done()
    if (l.startsWith('review:')) return clean
    if (l === 'final-review') return { ready: false, issues: [{ severity: 'critical', where: 'z:1', problem: 'race' }], declined: ['perf'] }
    if (l === 'final-rereview') return { verdicts: [{ finding: 'race', addressed: false }], newBreakage: [], outOfScope: [] }
    if (l === 'final-adjudicate') return { decisions: [{ finding: 'race', decision: 'carry', ruling: 'human decides lock order' }], stop: false }
    return { appended: true }
  })
  check('final residual', r.out.final.ready === false && r.out.final.residual.length === 1 && r.out.rulings.some(x => x.startsWith('Final: Ruling')) && r.calls.some(c => c.label === 'ledger:final'), r)
}
// 11. cwd reaches every agent prompt
{
  const r = await run({ plan: 'p.md', cwd: '/r/wt' }, (l) => {
    if (l === 'preflight') return pre([[1, 'integrate']])
    if (l.startsWith('impl:')) return done()
    if (l.startsWith('review:')) return clean
    if (l === 'final-review') return { ready: true, issues: [], declined: [] }
    return { appended: true }
  })
  check('role + cwd prefix on all agents', r.calls.length === 5 && r.calls.every(c => c.prompt.startsWith('You are one step of the sdd-run workflow') && c.prompt.includes('Work only in the git checkout at /r/wt: start every shell command with `cd /r/wt &&`')), r)
  try { await run({ plan: 'p.md', cwd: '/r/a b' }, () => null); failures++; console.log('FAIL unsafe cwd accepted') } catch (e) { console.log(`PASS unsafe cwd rejected: ${e.message}`) }
}
// 12. refs name every range; a no-commit fix is re-reviewed without a diff; a refused ledger write is returned
{
  let rv = 0
  const r = await run({ plan: 'docs/plans/2026-10-13-calc.md' }, (l, p) => {
    if (l === 'preflight') return pre([[1, 'transcribe'], [2, 'integrate']])
    if (l === 'impl:1' || l === 'impl:2') return done()
    if (l === 'fix:1#1') return { status: 'DONE_WITH_CONCERNS', commits: 0, tests: 'ok', concerns: 'report only' }
    if (l === 'review:1') return { specOk: true, approved: false, issues: [{ severity: 'important', where: 'report', problem: 'missing report' }], cannotVerify: [] }
    if (l.startsWith('review:')) return clean
    if (l.startsWith('rereview')) return { verdicts: [{ finding: 'missing report', addressed: true }], newBreakage: [], outOfScope: [] }
    if (l === 'ledger:2') return { appended: false }
    if (l === 'final-review') return { ready: true, issues: [], declined: [] }
    return { appended: true }
  })
  const p = l => r.calls.find(c => c.label === l).prompt
  check('refs + no-commit fix + ledgerPending',
    r.out.completed === 2 &&
    p('preflight').includes('git update-ref refs/sdd/2026-10-13-calc/base HEAD') &&
    p('review:1').includes('git update-ref refs/sdd/2026-10-13-calc/t1 HEAD') && p('review:1').includes('review-package docs/plans/2026-10-13-calc.md refs/sdd/2026-10-13-calc/base refs/sdd/2026-10-13-calc/t1') &&
    p('rereview:1#1').includes('made no commits') && !p('rereview:1#1').includes('review-package') &&
    p('review:2').includes('refs/sdd/2026-10-13-calc/t1 refs/sdd/2026-10-13-calc/t2') &&
    p('final-review').includes('git merge-base main refs/sdd/2026-10-13-calc/final') &&
    r.out.ledgerPending.some(x => x.startsWith('Task 2: complete')) && r.out.refs === 'refs/sdd/2026-10-13-calc' &&
    r.out.results[0].range === 'refs/sdd/2026-10-13-calc/base..refs/sdd/2026-10-13-calc/t1', r)
}
// 13b. every agent gets the rg search recipe through the role preamble
{
  const r = await run({ plan: 'p.md' }, (l) => {
    if (l === 'preflight') return pre([[1, 'transcribe']])
    if (l.startsWith('impl:')) return done()
    if (l.startsWith('review:')) return clean
    if (l === 'final-review') return { ready: true, issues: [], declined: [] }
    return { appended: true }
  })
  check('search recipe on every agent', r.calls.length > 3 && r.calls.every(c => c.prompt.includes('rg -n') && c.prompt.includes('rg --files') && c.prompt.includes('sed -n')), r)
}
// 14. Devin implementer: transcribe/integrate tasks and early fix rounds go to sdd-devin; design and the escalated round stay on Claude
{
  let d1 = 0
  const r = await run({ plan: 'p.md', implementer: 'devin' }, (l) => {
    if (l === 'preflight') return pre([[1, 'transcribe'], [2, 'integrate'], [3, 'design']])
    if (l === 'devin:1:impl') return d1++ ? done() : { status: 'NEEDS_CONTEXT', commits: 0, tests: '', question: 'which port?' }
    if (l === 'resolve:1') return { action: 'answer', answer: 'use 8080 exactly', ruling: 'Ruling: port 8080 — plan silent — rework' }
    if (l.startsWith('devin:') || l.startsWith('impl:') || l.startsWith('fix:')) return done()
    if (l === 'review:2') return { specOk: false, approved: false, issues: [{ severity: 'critical', where: 'x:1', problem: 'p' }], cannotVerify: [] }
    if (l.startsWith('review:')) return clean
    if (l.startsWith('rereview')) return { verdicts: [{ finding: 'p', addressed: false }], newBreakage: [], outOfScope: [] }
    if (l === 'breaker:2') return { decisions: [{ finding: 'p', decision: 'park', ruling: 'contestable — why — cost' }], stop: false }
    if (l === 'final-review') return { ready: true, issues: [], declined: [] }
    return { appended: true }
  })
  const c = l => r.calls.find(x => x.label === l)
  const m = Object.fromEntries(r.calls.map(x => [x.label, x.model]))
  const ctx = c('devin:1:impl2')?.prompt || ''
  const fix1 = c('devin:2:fix1')?.prompt || ''
  check('devin implementer routing', r.out.completed === 3 &&
    m['devin:1:impl'] === 'haiku' && m['devin:2:impl'] === 'haiku' && m['impl:3'] === 'opus' &&
    !c('impl:1') && !c('impl:2') && !r.calls.some(x => x.label.startsWith('devin:3')) &&
    m['devin:2:fix1'] === 'haiku' && m['devin:2:fix2'] === 'haiku' && m['fix:2#3'] === 'opus' && !c('devin:2:fix3') &&
    c('devin:1:impl').prompt.includes('sdd-devin start --task 1 --brief /r/.superpowers/sdd/p/task-1-brief.md --report /r/.superpowers/sdd/p/task-1-report.md --constraints /r/.superpowers/sdd/p/constraints.md --workspace /r/.superpowers/sdd/p`') &&
    ctx.includes('--context /r/.superpowers/sdd/p/task-1-impl2-context.md') && ctx.includes('use 8080 exactly') &&
    fix1.includes('--findings /r/.superpowers/sdd/p/task-2-fix1-findings.md') && fix1.includes('x:1') &&
    c('review:1').model === 'sonnet' && r.out.results.map(x => x.implementer).join() === 'devin,devin,opus' &&
    r.out.results[1].parked === 1, r)
}
// 15. Devin implementer: a task the resolver escalates goes to a stronger Claude model, not back to Devin
{
  const r = await run({ plan: 'p.md', implementer: 'devin' }, (l) => {
    if (l === 'preflight') return pre([[1, 'integrate']])
    if (l === 'devin:1:impl') return { status: 'BLOCKED', commits: 0, tests: '', question: 'too hard' }
    if (l === 'resolve:1') return { action: 'escalate', answer: 'think harder' }
    if (l === 'impl:1+') return done()
    if (l.startsWith('review:')) return clean
    if (l === 'final-review') return { ready: true, issues: [], declined: [] }
    return { appended: true }
  })
  const m = Object.fromEntries(r.calls.map(x => [x.label, x.model]))
  check('devin blocked -> escalated to Claude', r.out.completed === 1 && m['impl:1+'] === 'opus' && !r.calls.some(x => x.label === 'devin:1:impl2'), r)
}
// 16. default implementer never touches sdd-devin
{
  const r = await run({ plan: 'p.md' }, (l) => {
    if (l === 'preflight') return pre([[1, 'transcribe'], [2, 'integrate']])
    if (l.startsWith('impl:')) return done()
    if (l.startsWith('review:')) return clean
    if (l === 'final-review') return { ready: true, issues: [], declined: [] }
    return { appended: true }
  })
  check('claude implementer by default', r.out.completed === 2 && !r.calls.some(x => x.label.startsWith('devin:') || x.prompt.includes('sdd-devin')), r)
}
// 13. input guards
{
  const r = await run(undefined, () => null)
  check('no args', r.out.started === false && r.calls.length === 0, r)
  for (const [name, args, mock] of [
    ['unsafe plan', { plan: 'p.md; rm -rf /' }, () => null],
    ['unsafe sddDir from preflight', { plan: 'p.md' }, l => l === 'preflight' ? pre([[1, 'integrate']], { sddDir: '/x/$(id)' }) : { appended: true }],
    ['unsafe brief path', { plan: 'p.md' }, l => l === 'preflight' ? { ...pre([[1, 'integrate']]), tasks: [{ n: 1, title: 't', tier: 'integrate', done: false, brief: '/a b;c' }] } : { appended: true }],
  ]) {
    try { await run(args, mock); failures++; console.log(`FAIL ${name} accepted`) } catch (e) { console.log(`PASS ${name} rejected: ${e.message}`) }
  }
}
console.log(failures ? `\n${failures} FAILURE(S)` : '\nALL PASS')
process.exitCode = failures ? 1 : 0
