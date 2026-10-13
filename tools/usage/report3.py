import json,sys,collections,statistics as st
from datetime import datetime
res=json.load(open(sys.argv[1]))
P={'opus-5-5':(4,20,5,8,0.20),'opus-5':(5,25,6.25,10,0.5),'opus-4':(5,25,6.25,10,0.5),'sonnet-5':(2,10,2.5,4,0.2),
   'sonnet-4-6':(3,15,3.75,6,0.3),'haiku-5-5':(0.1,0.5,0.125,0.2,0.01),'haiku-4-5':(1,5,1.25,2,0.1),'fable-5-1':(10,50,12.5,20,0.25),'fable-5':(10,50,12.5,20,1.0)}
def price(m):
    m=m or ''
    for k in ['opus-5-5','opus-5','opus-4','sonnet-5','sonnet-4-6','haiku-5-5','haiku-4-5','fable-5-1','fable-5']:
        if k in m: return P[k]
    return (0,0,0,0,0)
def ccost(c):
    ctx,cw,cw1h,cr,out,m=c[:6]; p=price(m)
    return ((cw-cw1h)*p[2]+cw1h*p[3]+cr*p[4]+out*p[1]+(ctx-cw-cr)*p[0])/1e6
def fmt(n): return f"{n/1e6:,.1f}M" if n>=1e6 else f"{n/1e3:,.0f}k"
def T(s): return datetime.fromisoformat(s.replace('Z','+00:00')) if s else None
main=[r for r in res if not r['sub']]; sub=[r for r in res if r['sub']]
print('== Main-loop calls classified by what the call did')
cls=collections.Counter(); cn=collections.Counter()
for r in main:
    for c in r['calls_list']:
        tags=c[8]
        if not tags: k='no tool (text/end turn)'
        elif any(t.startswith('POLL') for t in tags): k='poll: sleep / read .output'
        elif any(t in ('Agent','Task','SendMessage') for t in tags): k='spawn/message agent'
        elif all(t=='Bash:status' for t in tags): k='status check (git/gh)'
        elif any(t in ('Edit','Write','MultiEdit','NotebookEdit') for t in tags): k='edit/write'
        elif any(t in ('Read','Grep','Glob') for t in tags): k='read/search'
        elif any(t.startswith('Bash') for t in tags): k='bash other'
        else: k='other tools'
        cls[k]+=ccost(c); cn[k]+=1
tot=sum(cls.values())
for k,v in cls.most_common(): print(f"  {k:28s} calls={cn[k]:6d} ${v:7,.0f} {100*v/tot:5.1f}%  $/call={v/cn[k]:.3f}")
print('\n== Sizes of .output reads (chars)', 'n=',sum(len(r['out_reads_sizes']) for r in main),'median',st.median([x for r in main for x in r['out_reads_sizes']] or [0]),'p90',sorted([x for r in main for x in r['out_reads_sizes']])[int(.9*sum(len(r['out_reads_sizes']) for r in main))] , 'total',fmt(sum(sum(r['out_reads_sizes']) for r in main)))
print('\n== Cache rebuild causes (calls writing >=50k)')
for name,rs,ttl in (('main',main,3600),('sub',sub,300)):
    cause=collections.Counter(); cost=collections.Counter()
    for r in rs:
        cl=r['calls_list']
        # order by line
        cl=sorted(cl,key=lambda c:c[6])
        for i,c in enumerate(cl):
            if c[1]<50e3: continue
            p=price(c[5]); wc=((c[1]-c[2])*p[2]+c[2]*p[3])/1e6
            if i==0: k='first call of transcript'
            else:
                prev=cl[i-1]; gap=(T(c[7])-T(prev[7])).total_seconds() if c[7] and prev[7] else None
                if prev[5]!=c[5]: k='model switch'
                elif c[0]<prev[0]*0.7: k='context shrank (compaction/clear)'
                elif gap is not None and gap>ttl: k=f'idle gap > TTL ({ttl//60}m)'
                else: k='large new content / other'
            cause[k]+=1; cost[k]+=wc
    print(' ',name)
    for k,v in cost.most_common(): print(f"    {k:36s} n={cause[k]:4d} ${v:6,.0f}")
print('\n== Main sessions: per-turn context at session end vs. starting a fresh session')
lens=[len(r['calls_list']) for r in main if r['calls_list']]
print('  sessions with >=1 call',len(lens),' >500 calls:',sum(1 for x in lens if x>500),' >1000:',sum(1 for x in lens if x>1000))
big=[r for r in main if len(r['calls_list'])>500]
print('  cost in sessions >500 calls: $%.0f of $%.0f main'%(sum(ccost(c) for r in big for c in r['calls_list']),sum(ccost(c) for r in main for c in r['calls_list'])))
print('\n== Model alias -> resolved model for subagents')
al=collections.Counter()
for r in sub:
    if r['calls_list']: al[(r['meta'].get('model') or 'inherit', collections.Counter(c[5] for c in r['calls_list']).most_common(1)[0][0])]+=1
for k,v in al.most_common(): print('  ',k,v)
print('\n== Fable usage')
fm=collections.Counter(); fs=collections.Counter()
for r in res:
    for c in r['calls_list']:
        if 'fable' in (c[5] or ''): fm['sub' if r['sub'] else 'main']+=ccost(c); fs[r['session']]+=ccost(c)
print(' ',{k:round(v) for k,v in fm.items()}, ' sessions:',len(fs),' top:',[(k[:8],round(v)) for k,v in fs.most_common(4)])
print('\n== Weekly cost (API-equiv) main/sub')
wk=collections.defaultdict(lambda:[0,0])
for r in res:
    for c in r['calls_list']:
        if c[7]: wk[T(c[7]).strftime('%G-W%V')][1 if r['sub'] else 0]+=ccost(c)
for k in sorted(wk): print(f"  {k} main ${wk[k][0]:6,.0f} sub ${wk[k][1]:5,.0f}")
