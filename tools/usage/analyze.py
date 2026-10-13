#!/usr/bin/env python3
"""Read-only token/orchestration analyzer for Claude Code transcripts.

Usage semantics (verified on sample records): each assistant API response is
written as several JSONL records (one per content block) sharing message.id;
usage is per-request (not cumulative). We dedupe by message.id and keep the
record with the largest output_tokens (the final streamed value).
"""
import json, os, sys, re, collections

ROOT = sys.argv[1]
OUT = sys.argv[2]

def clen(c):
    if c is None:
        return 0
    if isinstance(c, str):
        return len(c)
    if isinstance(c, list):
        n = 0
        for b in c:
            if isinstance(b, dict):
                if b.get('type') == 'text':
                    n += len(b.get('text', ''))
                elif b.get('type') == 'image':
                    n += 0
                else:
                    n += len(json.dumps(b))
            else:
                n += len(str(b))
        return n
    return len(json.dumps(c))

files = []
for dp, dn, fn in os.walk(ROOT):
    for f in fn:
        if f.endswith('.jsonl'):
            files.append(os.path.join(dp, f))

res = []
for path in files:
    rel = os.path.relpath(path, ROOT)
    parts = rel.split('/')
    project = parts[0]
    is_sub = '/subagents/' in rel
    session = parts[1].replace('.jsonl', '') if not is_sub else parts[1]
    meta = {}
    if is_sub:
        mp = path.replace('.jsonl', '.meta.json')
        if os.path.exists(mp):
            try:
                meta = json.load(open(mp))
            except Exception:
                pass
    msgs = {}  # id -> (usage, model, line)
    mtools = collections.defaultdict(list)
    mts = {}
    out_reads_sizes = []
    out_read_ids = set()
    tool_names = {}
    tool_calls = collections.Counter()
    tool_result_chars = collections.Counter()
    tool_result_max = []  # (chars, tool, line)
    agent_spawns = []
    notif_chars = 0
    notif_count = 0
    compactions = 0
    ts_first = ts_last = None
    advisor_iters = collections.Counter()
    advisor_tokens = collections.Counter()
    effort = collections.Counter()
    output_file_reads = 0
    sleep_polls = 0
    human_prompts = 0
    with open(path, errors='replace') as fh:
        for ln, line in enumerate(fh, 1):
            try:
                r = json.loads(line)
            except Exception:
                continue
            ts = r.get('timestamp')
            if ts:
                ts_first = ts_first or ts
                ts_last = ts
            t = r.get('type')
            if t == 'system' and r.get('subtype') == 'compact_boundary':
                compactions += 1
            if r.get('isCompactSummary'):
                pass
            m = r.get('message') or {}
            if t == 'assistant':
                mid = m.get('id') or r.get('requestId') or f'line{ln}'
                mts.setdefault(mid, ts)
                u = m.get('usage') or {}
                prev = msgs.get(mid)
                if prev is None or (u.get('output_tokens') or 0) >= (prev[0].get('output_tokens') or 0):
                    msgs[mid] = (u, m.get('model'), ln)
                if r.get('effort') and prev is None:
                    effort[str(r.get('effort'))] += 1
                for b in m.get('content') or []:
                    if isinstance(b, dict) and b.get('type') == 'tool_use':
                        name = b.get('name')
                        tool_names[b.get('id')] = name
                        tag = name
                        tool_calls[name] += 1
                        inp = b.get('input') or {}
                        if name in ('Agent', 'Task'):
                            agent_spawns.append({
                                'line': ln,
                                'type': inp.get('subagent_type') or 'default',
                                'model': inp.get('model'),
                                'bg': inp.get('run_in_background'),
                                'desc': (inp.get('description') or '')[:60],
                                'prompt_chars': len(inp.get('prompt') or ''),
                            })
                        if name == 'Bash':
                            cmd = inp.get('command') or ''
                            if re.search(r'\bsleep\s+\d', cmd):
                                sleep_polls += 1; tag = 'POLL:sleep'
                            if '/tasks/' in cmd and '.output' in cmd:
                                output_file_reads += 1; tag = 'POLL:output'; out_read_ids.add(b.get('id'))
                            elif re.search(r'\b(gh (pr|run) (checks|view|list)|git (status|log|fetch))', cmd) and tag == 'Bash':
                                tag = 'Bash:status'
                        if name == 'Read' and '/tasks/' in (inp.get('file_path') or '') and (inp.get('file_path') or '').endswith('.output'):
                            output_file_reads += 1; tag = 'POLL:output'; out_read_ids.add(b.get('id'))
                        mtools[mid].append(tag)
            elif t == 'user':
                c = m.get('content')
                if isinstance(c, str):
                    if '<task-notification>' in c:
                        notif_chars += len(c); notif_count += 1
                    elif not r.get('isMeta') and not c.startswith('<'):
                        human_prompts += 1
                elif isinstance(c, list):
                    for b in c:
                        if not isinstance(b, dict):
                            continue
                        if b.get('type') == 'tool_result':
                            name = tool_names.get(b.get('tool_use_id'), '?')
                            n = clen(b.get('content'))
                            if b.get('tool_use_id') in out_read_ids:
                                out_reads_sizes.append(n)
                            tool_result_chars[name] += n
                            tool_result_max.append((n, name, ln))
                        elif b.get('type') == 'text':
                            tx = b.get('text', '')
                            if '<task-notification>' in tx:
                                notif_chars += len(tx); notif_count += 1
                            elif not r.get('isMeta') and not tx.startswith('<'):
                                human_prompts += 1
    tot = collections.Counter()
    by_model = collections.defaultdict(collections.Counter)
    peak = 0
    calls_list = []
    ctx_hist = collections.Counter()
    for mid, (u, model, ln) in msgs.items():
        if model == '<synthetic>':
            continue
        cc = u.get('cache_creation') or {}
        w5 = cc.get('ephemeral_5m_input_tokens')
        w1 = cc.get('ephemeral_1h_input_tokens')
        cw = u.get('cache_creation_input_tokens') or 0
        if w5 is None and w1 is None:
            w5, w1 = cw, 0
        d = {
            'calls': 1,
            'input': u.get('input_tokens') or 0,
            'cw5m': w5 or 0,
            'cw1h': w1 or 0,
            'cr': u.get('cache_read_input_tokens') or 0,
            'out': u.get('output_tokens') or 0,
        }
        for k, v in d.items():
            tot[k] += v
            by_model[model or '?'][k] += v
        ctx = d['input'] + cw + d['cr']
        calls_list.append([ctx, cw, d['cw1h'], d['cr'], d['out'], model, ln, mts.get(mid), mtools.get(mid, [])])
        peak = max(peak, ctx)
        bucket = '<50k' if ctx < 50e3 else '50-100k' if ctx < 100e3 else '100-150k' if ctx < 150e3 else '150-200k' if ctx < 200e3 else '>200k'
        ctx_hist[bucket] += 1
        for itn in u.get('iterations') or []:
            ty = itn.get('type', '?')
            if ty != 'message':
                advisor_iters[ty] += 1
                for k in ('input_tokens', 'output_tokens', 'cache_read_input_tokens', 'cache_creation_input_tokens'):
                    advisor_tokens[k] += itn.get(k) or 0
    tool_result_max.sort(reverse=True)
    res.append({
        'path': path, 'project': project, 'session': session, 'sub': is_sub,
        'meta': meta, 'tot': dict(tot), 'by_model': {k: dict(v) for k, v in by_model.items()},
        'peak': peak, 'ctx_hist': dict(ctx_hist), 'tools': dict(tool_calls),
        'tool_result_chars': dict(tool_result_chars), 'top_results': tool_result_max[:5],
        'spawns': agent_spawns, 'notif_chars': notif_chars, 'notif_count': notif_count,
        'compactions': compactions, 'ts': [ts_first, ts_last],
        'advisor_iters': dict(advisor_iters), 'advisor_tokens': dict(advisor_tokens),
        'output_file_reads': output_file_reads, 'sleep_polls': sleep_polls,
        'human_prompts': human_prompts, 'calls_list': calls_list, 'effort': dict(effort), 'out_reads_sizes': out_reads_sizes,
    })

json.dump(res, open(OUT, 'w'))
print('files', len(res))
