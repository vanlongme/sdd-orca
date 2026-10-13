import json,sys,collections,statistics as st
res=json.load(open(sys.argv[1]))
P={'opus-5-5':(4,20,5,8,0.20),'opus-5':(5,25,6.25,10,0.5),'opus-4':(5,25,6.25,10,0.5),'sonnet-5':(2,10,2.5,4,0.2),
   'sonnet-4-6':(3,15,3.75,6,0.3),'haiku-5-5':(0.1,0.5,0.125,0.2,0.01),'haiku-4-5':(1,5,1.25,2,0.1),'fable-5-1':(10,50,12.5,20,0.25),'fable-5':(10,50,12.5,20,1.0)}
def price(m):
    for k in P:
        pass
    m=m or ''
    for k in ['opus-5-5','opus-5','opus-4','sonnet-5','sonnet-4-6','haiku-5-5','haiku-4-5','fable-5-1','fable-5']:
        if k in m: return P[k]
    return (0,0,0,0,0)
def ccost(c):
    ctx,cw,cw1h,cr,out,m,ln=c; p=price(m)
    return ((cw-cw1h)*p[2]+cw1h*p[3]+cr*p[4]+out*p[1]+(ctx-cw-cr)*p[0])/1e6
def fmt(n): return f"{n/1e6:,.1f}M" if n>=1e6 else f"{n/1e3:,.0f}k"
for r in res: r['cost']=sum(ccost(c) for c in r['calls_list'])
TOT=sum(r['cost'] for r in res)
main=[r for r in res if not r['sub']]; sub=[r for r in res if r['sub']]
print('== Context size per call: share of calls and of cost')
B=[(0,50e3,'<50k'),(50e3,100e3,'50-100k'),(100e3,200e3,'100-200k'),(200e3,400e3,'200-400k'),(400e3,700e3,'400-700k'),(700e3,2e6,'>700k')]
for name,rs in (('main',main),('sub',sub)):
    calls=[c for r in rs for c in r['calls_list']]
    tc=sum(ccost(c) for c in calls)
    print(f" {name}: calls={len(calls)} median_ctx={fmt(st.median([c[0] for c in calls]))} mean_ctx={fmt(st.mean([c[0] for c in calls]))}")
    for lo,hi,l in B:
        sel=[c for c in calls if lo<=c[0]<hi]
        print(f"   {l:9s} calls {100*len(sel)/len(calls):5.1f}%  cost ${sum(ccost(c) for c in sel):7,.0f} ({100*sum(ccost(c) for c in sel)/tc:4.1f}%)")
print('\n== Cache rebuild events (one call writing >=100k tokens)')
for name,rs in (('main',main),('sub',sub)):
    ev=[(c,r) for r in rs for c in r['calls_list'] if c[1]>=100e3]
    wc=sum(((c[1]-c[2])*price(c[5])[2]+c[2]*price(c[5])[3])/1e6 for c,r in ev)
    print(f" {name}: events={len(ev)} written={fmt(sum(c[1] for c,r in ev))} write_cost=${wc:,.0f} sessions_affected={len(set(r['path'] for c,r in ev))}")
allw=sum(((c[1]-c[2])*price(c[5])[2]+c[2]*price(c[5])[3])/1e6 for r in res for c in r['calls_list'])
print(f" all cache-write cost ${allw:,.0f}")
print('\n== Sessions (main + its subagents) top 12 by cost')
sess=collections.defaultdict(lambda:{'main':0,'sub':0,'nsub':0,'proj':'','calls':0,'peak':0,'comp':0,'fam':collections.Counter(),'ts':None,'hp':0})
for r in res:
    k=(r['project'],r['session']); s=sess[k]; s['proj']=r['project']
    if r['sub']: s['sub']+=r['cost']; s['nsub']+=1
    else:
        s['main']+=r['cost']; s['calls']+=len(r['calls_list']); s['peak']=max(s['peak'],r['peak']); s['comp']+=r['compactions']; s['ts']=r['ts']; s['hp']=r['human_prompts']
        for c in r['calls_list']: s['fam'][c[5]]+=1
top=sorted(sess.items(),key=lambda kv:-(kv[1]['main']+kv[1]['sub']))
cum=0
for (p,sid),s in top[:12]:
    t=s['main']+s['sub']; cum+=t
    m=s['fam'].most_common(1)[0][0] if s['fam'] else '?'
    print(f" ${t:6,.0f} main=${s['main']:5,.0f} sub=${s['sub']:5,.0f}({s['nsub']:2d}) calls={s['calls']:5d} peak={fmt(s['peak']):>6s} comp={s['comp']} {m:16s} {sid[:8]} {p.replace('-home-ubuntu-','')[:48]}")
print(f" top12 share {100*cum/TOT:.1f}% ; sessions total {len(sess)}; with subagents {sum(1 for s in sess.values() if s['nsub'])}")
c10=sorted([s['main']+s['sub'] for s in sess.values()],reverse=True)
print(' top10% sessions share', round(100*sum(c10[:len(c10)//10])/TOT,1),'%')
print('\n== Per project family')
pf=collections.Counter()
for r in res:
    k=r['project'].replace('-home-ubuntu-','')
    k=k[:40]
    pf[k]+=r['cost']
for k,v in pf.most_common(10): print(f"  ${v:7,.0f} {k}")
print('\n== Tool results volume (chars) main vs sub, top tools')
for name,rs in (('main',main),('sub',sub)):
    tr=collections.Counter(); tc=collections.Counter()
    for r in rs:
        for k,v in r['tool_result_chars'].items(): tr[k]+=v
        for k,v in r['tools'].items(): tc[k]+=v
    print(' ',name,' total chars',fmt(sum(tr.values())))
    for k,v in tr.most_common(9): print(f"    {k:28s} {fmt(v):>7s} calls={tc[k]:6d} avg={v/max(tc[k],1):7,.0f}")
print('\n== Orchestration signals (main sessions)')
sp=[s for r in main for s in r['spawns']]
print(' Agent spawns',len(sp),' models',collections.Counter(s['model'] or 'inherit' for s in sp).most_common(),' types',collections.Counter(s['type'] for s in sp).most_common(5))
print(' spawn prompt chars median',st.median([s['prompt_chars'] for s in sp]) if sp else 0,' p90',sorted(s['prompt_chars'] for s in sp)[int(.9*len(sp))] if sp else 0,' total',fmt(sum(s['prompt_chars'] for s in sp)))
print(' task-notifications',sum(r['notif_count'] for r in main),' chars',fmt(sum(r['notif_chars'] for r in main)))
print(' Read/Bash of agent .output files',sum(r['output_file_reads'] for r in main),' sleep polls(main)',sum(r['sleep_polls'] for r in main),' sleep polls(sub)',sum(r['sleep_polls'] for r in sub))
tools_all=collections.Counter()
for r in res:
    for k,v in r['tools'].items(): tools_all[k]+=v
print(' Workflow tool calls',tools_all.get('Workflow',0),' SendMessage',tools_all.get('SendMessage',0),' TaskOutput',tools_all.get('TaskOutput',0),' Skill',tools_all.get('Skill',0),' ToolSearch',tools_all.get('ToolSearch',0))
print(' compactions main',sum(r['compactions'] for r in main))
ef=collections.Counter()
for r in res:
    for k,v in r['effort'].items(): ef[('sub' if r['sub'] else 'main',k)]+=v
print(' effort per API call',sorted(ef.items()))
ai=collections.Counter(); at=collections.Counter()
for r in res:
    for k,v in r['advisor_iters'].items(): ai[k]+=v
    for k,v in r['advisor_tokens'].items(): at[k]+=v
print(' non-message iterations',dict(ai),{k:fmt(v) for k,v in at.items()})
print('\n== Subagent startup overhead (first call)')
fc=[r['calls_list'][0] for r in sub if r['calls_list']]
print(' first-call ctx median',fmt(st.median([c[0] for c in fc])),' first-call write median',fmt(st.median([c[1] for c in fc])))
print(' subagent calls median',st.median([len(r['calls_list']) for r in sub]),' ctx-at-end median',fmt(st.median([r['calls_list'][-1][0] for r in sub if r['calls_list']])))
