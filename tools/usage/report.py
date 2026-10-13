import json,sys,collections,statistics as st
res=json.load(open(sys.argv[1]))
# $/MTok: in, out, cw5m, cw1h, cr  (from claude-api skill, cached 2026-10-06)
P={'opus-5-5':(4,20,5,8,0.20),'opus-5':(5,25,6.25,10,0.5),'opus-4':(5,25,6.25,10,0.5),'sonnet-5':(2,10,2.5,4,0.2),
   'sonnet-4-6':(3,15,3.75,6,0.3),'haiku-5-5':(0.1,0.5,0.125,0.2,0.01),'haiku-4-5':(1,5,1.25,2,0.1),'fable-5-1':(10,50,12.5,20,0.25),'fable-5':(10,50,12.5,20,1.0)}
def price(m):
    m=m or ''
    for k in ['opus-5-5','opus-5','opus-4','sonnet-5','sonnet-4-6','haiku-5-5','haiku-4-5','fable-5-1','fable-5']:
        if k in m: return P[k]
    return None
def cost(t,m):
    p=price(m)
    if not p: return 0
    return (t.get('input',0)*p[0]+t.get('out',0)*p[1]+t.get('cw5m',0)*p[2]+t.get('cw1h',0)*p[3]+t.get('cr',0)*p[4])/1e6
def fmt(n): return f"{n/1e6:,.1f}M" if n>=1e6 else f"{n/1e3:,.0f}k"
K=['calls','input','cw5m','cw1h','cr','out']
for r in res:
    r['cost']=sum(cost(v,m) for m,v in r['by_model'].items())
    r['fam']=max(r['by_model'].items(),key=lambda kv:kv[1].get('calls',0))[0] if r['by_model'] else '?'
ts=[x for r in res for x in r['ts'] if x]
print('Range',min(ts),'->',max(ts))
unk=collections.Counter(m for r in res for m in r['by_model'] if not price(m))
print('unpriced models',unk)
def agg(rs):
    t=collections.Counter()
    for r in rs:
        for v in r['by_model'].values():
            for k in K: t[k]+=v.get(k,0)
    return t
def row(name,rs):
    t=agg(rs); c=sum(r['cost'] for r in rs); tot_in=t['input']+t['cw5m']+t['cw1h']+t['cr']
    print(f"{name:34s} n={len(rs):4d} calls={t['calls']:6d} in_total={fmt(tot_in):>8s} cr={fmt(t['cr']):>8s} cw5m={fmt(t['cw5m']):>7s} cw1h={fmt(t['cw1h']):>7s} out={fmt(t['out']):>7s} ${c:,.0f}")
    return c
print('\n== Overall')
call=row('ALL',res)
main=[r for r in res if not r['sub']]; sub=[r for r in res if r['sub']]
row('main sessions',main); row('subagents',sub)
print('\n== Cost share by token class (all)')
cc=collections.Counter()
for r in res:
    for m,v in r['by_model'].items():
        p=price(m)
        if not p: continue
        for i,k in enumerate(['input','out','cw5m','cw1h','cr']): cc[k]+=v.get(k,0)*p[i]/1e6
for k,v in cc.most_common(): print(f"  {k:5s} ${v:,.0f} {100*v/call:.1f}%")
print('\n== By model (calls / $)')
bm=collections.defaultdict(collections.Counter); bmc=collections.Counter()
for r in res:
    for m,v in r['by_model'].items():
        for k in K: bm[m][k]+=v.get(k,0)
        bmc[m]+=cost(v,m)
for m,c in bmc.most_common(): print(f"  {m:28s} calls={bm[m]['calls']:6d} out={fmt(bm[m]['out']):>7s} cr={fmt(bm[m]['cr']):>8s} ${c:,.0f}")
print('\n== Subagents by meta.model (requested) and agentType')
g=collections.defaultdict(list)
for r in sub: g[(r['meta'].get('agentType','?'),r['meta'].get('model') or 'inherit')].append(r)
for k,rs in sorted(g.items(),key=lambda kv:-sum(r['cost'] for r in kv[1]))[:14]:
    c=sum(r['cost'] for r in rs); calls=[r['tot'].get('calls',0) for r in rs]
    print(f"  {str(k):42s} n={len(rs):3d} ${c:7,.0f} med_calls={st.median(calls):5.0f} med$/agent={st.median([r['cost'] for r in rs]):6.2f} max$={max(r['cost'] for r in rs):6.1f}")
print('\n== Subagent resolved model family (by_model)')
fam=collections.Counter(); famn=collections.Counter()
for r in sub: fam[r['fam']]+=r['cost']; famn[r['fam']]+=1
for k,v in fam.most_common(): print(f"  {k:28s} n={famn[k]:3d} ${v:,.0f}")
json.dump({'all':call},open(sys.argv[1]+'.sum','w'))
