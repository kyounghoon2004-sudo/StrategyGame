"""CPU-only state-grounded tactical authoring, after replay gate PASS.

API: author_partition(assignment_path) writes parts/<stem>.jsonl plus
parts/<stem>_rejected.jsonl and parts/<stem>_author_audit.json. Assignments must
contain original `situation`, `primary_category`, and measured features. Target
selection uses real positions/classes, visible soldier bands and game combat
forecasts; every proposal is checked against the exact V3 command schema.
"""
from __future__ import annotations
import collections
import json
import math
import re
import sys
from pathlib import Path

from tools.synth_sft_v3.crosscheck import check
from tools.synth_sft_v3.view import parse_now, dist, OUT

def attack(target):return {'do':'ATTACK','target':target}

def proposals(s):
    op,mine,enemies=parse_now(s)
    blue={u:v for u,v in enemies.items() if v['cls']!='HQ'}
    red={u:v for u,v in mine.items() if v['cls']!='HQ'}
    standing=s.get('standing_orders',{})
    if not blue or not red:return []
    stats=op.get('class_stats',{})
    def speed(u):return stats.get(mine[u]['cls'],{}).get('mp',3 if mine[u]['cls']=='CAVALRY' else 2)
    def reach(u,b):
        rang=stats.get(mine[u]['cls'],{}).get('range',3 if mine[u]['cls']=='ARCHER' else 1)
        return max(0,math.ceil((dist(mine[u]['pos'],blue[b]['pos'])-rang)/max(1,speed(u))))
    def band(b):
        n=re.findall(r'\d+',str(blue[b]['troops']))
        return sum(map(int,n))/max(1,len(n)) if n else 300
    previews={}
    for u,v in mine.items():
        extra=v.get('extra','')
        if int(s['turn'])==1:
            extra='; '.join(next(x for x in op['my_units'] if x['id']==u).get('vs',[]))
        for m in re.finditer(r'(B_\w+) eta (\d+) dealt (\d+)-(\d+) taken (\d+)-(\d+)(?: fw (\d+))?',extra):
            b,eta,dl,dh,tl,th,fw=m.groups()
            previews[u,b]={'eta':int(eta),'damage':(int(dl)+int(dh))/2,'loss':(int(tl)+int(th))/2,'fw':int(fw or 0)}
    matchup={}
    for c,x in op.get('matchups',{}).items():
        for item in x.split(', '):
            k,v=item.rsplit(' ',1);matchup[c,k]=float(v)
    def value(u,b):
        p=previews.get((u,b));eta=p['eta'] if p else reach(u,b)
        mult=matchup.get((mine[u]['cls'],blue[b]['cls']),1)
        damage=p['damage'] if p else mine[u]['sol']*.16*mult
        loss=p['loss'] if p else (0 if mine[u]['cls']=='ARCHER' else band(b)*.08)
        return damage+.4*(p['fw'] if p else 0)-.65*loss-18*eta
    def priority(b,unfortified=False):
        scores=sorted((value(u,b) for u in red),reverse=True)
        return sum(scores[:max(2,min(5,len(scores)))])-band(b)*.07-(blue[b]['fort']*.28 if unfortified else 0)
    targets=sorted(blue,key=lambda b:(-priority(b),b))
    fresh=sorted(red,key=lambda u:(-mine[u]['sol']/max(1,mine[u]['start']),u))
    good=[u for u in fresh if mine[u]['sol']/max(1,mine[u]['start'])>=.35]
    if len(good)<2:good=fresh
    output=[]
    def add(pattern,orders,reason):
        changed={u:o for u,o in orders.items() if o!=standing.get(u,{'do':'HOLD'})}
        if not changed:return
        ans={'orders':changed}
        if int(s['turn'])==1:
            ans['plan']=reason[:300]
        output.append((pattern,ans,reason))
    # Restore only idle units while preserving a surviving, already-effective group.
    stale=[u for u in red if standing.get(u,{}).get('do') in ('ATTACK','RAID') and standing[u].get('target') not in enemies]
    if stale:
        live_focus=collections.Counter(o.get('target') for u,o in standing.items() if u in red and o.get('do') in ('ATTACK','RAID') and o.get('target') in blue)
        orders={}
        for u in stale:
            viable=sorted(blue,key=lambda b:(-(value(u,b)+12*live_focus[b]),b))
            orders[u]=attack(viable[0])
        add('retarget_dead_preserve_focus',orders,'Replace attacks on destroyed targets with reachable live enemies; preserve the surviving focus group and count only non-HQ kills.')
    # Finish one target, choosing actual reach/forecast over target-id templates.
    b=targets[0]
    attackers=sorted(good,key=lambda u:(-value(u,b),u))
    attackers=[u for u in attackers if reach(u,b)<=min(reach(x,b) for x in good)+2]
    add('coordinated_focus_finish',{u:attack(b) for u in attackers},'Concentrate healthy units on the reachable non-HQ enemy with the best combined damage and approach prospects; ranged units avoid melee counters and HQ stays safe.')
    # A distinct allocation: counter-matchups in two groups, avoiding overkill.
    if len(blue)>=2 and len(good)>=3:
        candidates=sorted(blue,key=lambda b:(-priority(b,True),b))[:min(3,len(blue))]
        loads=collections.Counter();orders={}
        for u in good:
            b=max(candidates,key=lambda b:(value(u,b)-18*loads[b],b))
            orders[u]=attack(b);loads[b]+=1
        if len(loads)>1:
            add('matchup_two_target_pressure',orders,'Use reachable class counters in separate supporting groups to finish exposed non-HQ targets rather than send every class into one unfavorable melee matchup.')
    # Withdraw depleted exposed combatants to an actual friendly rear position.
    damaged=[u for u in red if mine[u]['sol']/max(1,mine[u]['start'])<.4 and min(dist(mine[u]['pos'],v['pos']) for v in blue.values())<=4]
    if damaged:
        orders={u:attack(targets[0]) for u in good if u not in damaged}
        for u in damaged:
            own_positions=[(rid,v) for rid,v in mine.items() if rid!=u and v['pos']!=mine[u]['pos']]
            if not own_positions:continue
            rear=max(own_positions,key=lambda kv:(min(dist(kv[1]['pos'],b['pos']) for b in blue.values())-.4*dist(mine[u]['pos'],kv[1]['pos']),kv[0]))
            # This coordinate is copied from the current packet, not invented.
            orders[u]={'do':'MOVE','to':list(rear[1]['pos'])}
        add('withdraw_damaged_reform_focus',orders,'Move depleted exposed troops toward a real friendly rear position while healthy units continue coordinated attacks on the remaining non-HQ targets.')
    soft=[b for b,v in blue.items() if v['cls'] in ('ARCHER','SCOUT')]
    cavalry=[u for u,v in red.items() if v['cls']=='CAVALRY' and v['sol']/max(1,v['start'])>=.35]
    if soft and cavalry:
        orders={}
        for u in cavalry:
            b=max(soft,key=lambda b:value(u,b));orders[u]={'do':'RAID','target':b,'back_to':'MY_HQ'}
        hard=[b for b in blue if b not in soft]
        for u in good:
            if u in cavalry:continue
            b=max(hard or list(blue),key=lambda b:value(u,b));orders[u]=attack(b)
        add('cavalry_soft_target_raid_screen',orders,'Cavalry raids visible archers or scouts with a safe return direction; the slower formation focuses reachable non-HQ enemies and keeps ranged pressure.')
    fortified=[b for b,v in blue.items() if v['fort']>0]
    if fortified:
        b=max(fortified,key=lambda b:priority(b))
        grinders=sorted(good,key=lambda u:(-value(u,b),u))
        add('concentrated_fieldworks_break',{u:attack(b) for u in grinders},'Bring multiple healthy hitters and ranged support onto one live fortified non-HQ target until its fieldworks collapse; stay focused to obtain the missing mission kills.')
    hq=next((u for u,v in mine.items() if v['cls']=='HQ'),None)
    threats=[b for b,v in blue.items() if re.search(r'eta_my_hq [012](?:\s|$)',v.get('extra',''))]
    if hq and threats:
        b=min(threats,key=lambda b:dist(mine[hq]['pos'],blue[b]['pos']))
        guards=sorted(good,key=lambda u:(reach(u,b),-value(u,b),u))[:max(1,min(3,len(good)//2))]
        orders={u:attack(b) for u in guards}
        if not mine[hq]['fort']:orders[hq]={'do':'FORTIFY'}
        for u in good:
            if u not in guards:orders[u]=attack(targets[0])
        add('visible_hq_threat_intercept',orders,'Intercept the visible enemy able to reach our HQ soon with nearby healthy defenders; keep the remaining army pursuing the non-HQ collapse objective.')
    return output

def author_partition(path):
    path=Path(path);parts=OUT/'parts';parts.mkdir(exist_ok=True)
    assignments=[json.loads(x) for x in path.read_text(encoding='utf-8').splitlines() if x.strip()]
    accepted=[];rejected=[];audit=[]
    for item in assignments:
        s=item['situation'];seen=set();valid=[]
        for pattern,ans,reason in proposals(s):
            text=json.dumps(ans,separators=(',',':'),ensure_ascii=False)
            key=json.dumps(ans.get('orders'),sort_keys=True)
            row={'sid':s['id'],'variant':pattern,'pattern':pattern,'answer':text,'primary_category':item['primary_category'],
                 'author_partition':path.stem,'tactical_reason':reason,'observed_features':item.get('observed_features',{})}
            problems=check(s,text)
            if key in seen:problems.append('duplicate tactical orders within situation')
            seen.add(key)
            if problems:
                rejected.append(dict(row,rejection_reasons=problems));continue
            valid.append(row)
        # Prefer distinct nonempty tactical families: repaired idle orders, a
        # preservation/disengagement or class split, and coordinated finishing.
        ranks={'retarget_dead_preserve_focus':0,'withdraw_damaged_reform_focus':1,'visible_hq_threat_intercept':2,
               'cavalry_soft_target_raid_screen':3,'matchup_two_target_pressure':4,'concentrated_fieldworks_break':5,'coordinated_focus_finish':6}
        valid.sort(key=lambda x:(ranks[x['pattern']],x['pattern']))
        selected=valid[:3]
        accepted.extend(selected)
        rejected.extend(dict(r,rejection_reasons=['additional valid proposal beyond three variants']) for r in valid[3:])
        audit.append({'sid':s['id'],'authored':len(selected),'patterns':[r['pattern'] for r in selected],'available_valid_proposals':len(valid),'compact_view_review':bool(item.get('compact_view'))})
    output=parts/(path.stem+'.jsonl');reject=parts/(path.stem+'_rejected.jsonl')
    temporary=output.with_suffix('.jsonl.tmp')
    temporary.write_text(''.join(json.dumps(r,ensure_ascii=False)+'\n' for r in accepted),encoding='utf-8')
    temporary.replace(output)
    reject.write_text(''.join(json.dumps(r,ensure_ascii=False)+'\n' for r in rejected),encoding='utf-8')
    totals={'partition':path.stem,'situations':len(assignments),'authored':len(accepted),'rejected_proposals':len(rejected),
            'patterns':dict(collections.Counter(x['pattern'] for x in accepted)),'per_situation':audit}
    (parts/(path.stem+'_author_audit.json')).write_text(json.dumps(totals,indent=2),encoding='utf-8')
    print(json.dumps({k:v for k,v in totals.items() if k!='per_situation'}))
    return totals

if __name__=='__main__':
    for part in sys.argv[1:]:author_partition(part)
