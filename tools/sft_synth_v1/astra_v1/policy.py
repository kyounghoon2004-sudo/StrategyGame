"""Only displayed opening/delta and this policy's resident memory enter decisions.

Scores are heuristic estimates, not hidden troop counts or promised kills.
No opponent style, seed, external state, records, files or model calls are read.
"""
from __future__ import annotations
import json
import math
import re
from collections import defaultdict, deque
from ..policy import view, distance, previews, matchup

SOURCE_FILES = ('tools/sft_synth_v1/astra_v1/__init__.py',
                'tools/sft_synth_v1/astra_v1/policy.py', 'tools/sft_synth_v1/policy.py')
POLICIES = {
    'astra_sustained_groups': {'counter': .75, 'retention': 1.45, 'reserve': .20},
    'astra_screened_pressure': {'counter': 1.15, 'retention': 1.30, 'reserve': .28},
}
DIRS = ((1,0),(1,-1),(0,-1),(-1,0),(-1,1),(0,1))

def upper(e):
    ns = [int(x) for x in re.findall(r'\d+', str(e.get('troops','')))]
    return max(ns) if ns else 400

def stats(pkt,u):
    return pkt.get('class_stats',{}).get(u['class'],{})

def reach(pkt,u,e):
    s=stats(pkt,u)
    return max(0, math.ceil((distance(u,e)-s.get('range',1))/max(1,s.get('mp',2))))

def cell(p):
    return (int(p['q']),int(p['r']))

def point(c):
    return {'q':c[0],'r':c[1]}

def open_cells(pkt,u,reserved):
    """Small visible-board BFS; no hidden terrain or state is consulted."""
    start=cell(u); busy={cell(x) for key in ('my_units','enemy_units') for x in pkt[key]} | reserved
    busy.discard(start)
    limit=max(0,int(stats(pkt,u).get('mp',2))-(1 if u.get('fortified',0) else 0))
    queue=deque([(start,0)]); seen={start}; out=[]
    while queue:
        p,n=queue.popleft();out.append(p)
        if n>=limit:continue
        for dq,dr in DIRS:
            v=(p[0]+dq,p[1]+dr)
            if v not in seen and v not in busy and distance(point(v),{'q':0,'r':0})<=pkt.get('map_radius',40):
                seen.add(v);queue.append((v,n+1))
    return out

def reposition(pkt,u,foes,anchor,reserved,ranged_target=None):
    choices=open_cells(pkt,u,reserved)
    def score(c):
        p=point(c)
        # Penalize next-turn reach of every visible enemy using its printed stats.
        danger=sum(max(0,stats(pkt,e).get('range',1)+stats(pkt,e).get('mp',2)+1-distance(p,e))
                   for e in foes)
        if ranged_target is not None:
            rng=stats(pkt,u).get('range',1); d=distance(p,ranged_target)
            return (20*(d<2)+5*max(0,d-rng)+danger+0.1*distance(p,anchor),distance(p,u),c)
        return (danger*4+distance(p,anchor),distance(p,u),c)
    best=min(choices,key=score);reserved.add(best)
    return {'do':'HOLD'} if best==cell(u) else {'do':'MOVE','to':list(best)}

def decide(messages,name,memory):
    p=POLICIES[name];pkt=view(messages);turn=int(pkt['turn'])
    own=sorted(pkt['my_units'],key=lambda x:x['id']);field=[u for u in own if u['class']!='HQ']
    hq=next(u for u in own if u['class']=='HQ')
    foes=sorted((e for e in pkt['enemy_units'] if e['class']!='HQ'),key=lambda x:x['id'])
    index={e['id']:e for e in foes};standing=memory.setdefault('standing',{})
    # Current delta only: intermediate user messages may contain a BATTLE DIGEST.
    latest=json.loads(next(m['content'] for m in reversed(messages) if m['role']=='user'))
    events=latest.get('events',latest.get('history',[]))
    hits=[e for e in events if ' attack ' in e and any(' '+u['id']+' attack ' in ' '+e for u in field)]
    if hits:memory['last_attack']=turn
    prev=memory.get('enemy_ids',[e['id'] for e in foes])
    if set(prev)-set(index):memory['last_kill']=turn
    memory['enemy_ids']=list(index)
    # Committed siege changes only once, after contact without kills; not while marching.
    contact=any(reach(pkt,u,e)<=1 for u in field for e in foes)
    if contact:memory.setdefault('first_contact',turn)
    if (turn-memory.get('last_kill',memory.get('first_contact',turn))>=9 and contact):
        memory['siege']=True
    threats=[e for e in foes if e.get('eta_strike_my_hq',99)<=1 or hq['id'] in e.get('can_strike_next',[])]
    stage='hq_interception' if threats else 'sustained_siege' if memory.get('siege') else name
    desired={hq['id']:{'do':'FORTIFY' if 'FORTIFY' in messages[0]['content'] else 'HOLD'}}
    reserved=set();trace=[];damage=defaultdict(float);assigned=defaultdict(int)
    main=[u for u in field if u['class']!='SCOUT'] or field
    anchor=min(main,key=lambda u:sum(distance(u,v) for v in main)) if main else hq
    # Group target picked collectively. Fortified rear guards do not distract from exposed field units.
    def collective(e):
        etas=sorted(reach(pkt,u,e) for u in main)
        near=sum(1/(1+t) for t in etas[:max(2,len(main)//2)])
        exposed=1 if not e.get('fortified') else .58
        return near*exposed/(1+upper(e)/500)
    leader=max(foes,key=lambda e:(collective(e),e['id'])) if foes else None
    oldfocus=index.get(memory.get('focus'))
    if oldfocus and leader and collective(oldfocus)>=collective(leader)*.72:leader=oldfocus
    if leader:memory['focus']=leader['id']
    # Use actual execution order for estimated damage allocation; avoid claiming an exact kill.
    for u in field:
        uid=u['id'];vs=previews(u);previous=standing.get(uid,{}).get('target')
        candidates=[]
        for e in foes:
            eid=e['id'];v=vs.get(eid);eta=v['eta'] if v else reach(pkt,u,e)
            mult=matchup(pkt,u,e)
            dealt=(v['dealt']+v.get('fw',0)) if v else 30*mult*u['soldiers']/max(1,u.get('start',300))
            taken=v['taken'] if v else 15/max(.25,mult)
            value=max(1,dealt-p['counter']*taken)/(1+eta*1.5)
            value*=1.25 if leader and eid==leader['id'] else 1
            value*=p['retention'] if eid==previous else 1
            # Saturation uses the upper displayed band, never a hidden exact count.
            need=upper(e)+e.get('fortified',0)
            value*=.12 if damage[eid]>=need*1.12 else 1+min(.65,assigned[eid]*.16)
            if threats and e in threats:value*=4
            if e.get('fortified') and not memory.get('siege'):value*=.65
            # Scouts contribute only safe finishing blows; they are units in the collapse count.
            if u['class']=='SCOUT' and (not v or eta>1 or taken>max(2,u['soldiers']*.08) or dealt<2):value*=.01
            if v and taken>=u['soldiers']*.65:value*=.08
            candidates.append((value,eid,e,eta,v,dealt,taken))
        if not candidates:
            desired[uid]={'do':'HOLD'};continue
        _,eid,e,eta,v,dealt,taken=max(candidates,key=lambda c:(c[0],c[1]))
        rng=stats(pkt,u).get('range',1)
        reserve=(u['class']=='SCOUT' and (not v or eta>1 or taken>max(2,u['soldiers']*.08) or dealt<2))
        wounded=u['soldiers']<p['reserve']*max(1,u.get('start',300)) and taken>u['soldiers']*.25
        if reserve or wounded:
            # Reserve scouts stay at their safe opening positions until actually threatened.
            danger=any(uid in f.get('can_strike_next',[]) for f in foes)
            desired[uid]=reposition(pkt,u,foes,hq,reserved) if danger else {'do':'HOLD'}
        elif rng>=2 and distance(u,e)<=1 and v and v['taken']>0:
            desired[uid]=reposition(pkt,u,foes,anchor,reserved,ranged_target=e)
        else:
            support=sum(reach(pkt,a,e)<=max(1,eta) for a in main if a['id']!=uid)
            # Fast units cannot run several turns ahead into a hostile formation.
            rush=(stats(pkt,u).get('mp',2)>2 and eta<=1 and len(main)>2 and support==0)
            if rush and e not in threats and not memory.get('siege'):
                desired[uid]=reposition(pkt,u,foes,anchor,reserved)
            else:
                desired[uid]={'do':'ATTACK','target':eid}
                assigned[eid]+=1
                if eta<=1:damage[eid]+=dealt
                # Break physical congestion after 3 consecutive stationary attack decisions.
                pos=cell(u);old=memory.setdefault('motion',{}).get(uid,{})
                stalled=old.get('stalled',0)+1 if old.get('pos')==list(pos) and eta>0 and not any(' '+uid+' attack ' in ' '+h for h in hits) else 0
                memory['motion'][uid]={'pos':list(pos),'stalled':stalled}
                if stalled>=3 and eta>1:
                    options=open_cells(pkt,u,reserved)
                    best=min(options,key=lambda c:(distance(point(c),e),distance(point(c),anchor),c))
                    if best!=pos:desired[uid]={'do':'MOVE','to':list(best)};reserved.add(best)
        trace.append({'unit':uid,'target':eid,'eta':eta,'preview':v,'order':desired[uid]})
    changed={uid:o for uid,o in desired.items() if standing.get(uid,{'do':'HOLD'})!=o}
    standing.update(changed);answer={'orders':changed}
    if turn==1 or memory.get('plan_stage')!=stage:
        plans={
            'astra_sustained_groups':'Sustained groups: advance supporting combat units together, retain field targets and finish them with combined attacks. Keep scouts safe, favor class matchups and ranged fire, and fortify HQ. Destroy the required 70% of field units.',
            'astra_screened_pressure':'Screened pressure: preserve weak units, keep fast attackers supported and use ranged fire behind the line. Concentrate on exposed field units and retain targets until finished. Fortify HQ and destroy the required field-unit count.',
            'hq_interception':'HQ interception: redirect nearby combat strength onto visible field units that can strike our HQ now. Keep HQ fortified, preserve reserves and continue finishing field targets with supported attacks.',
            'sustained_siege':'Sustained siege: the field fight has stalled. Commit supporting attackers to reachable field targets, include fieldworks damage, restore ranged spacing and work around blocked approaches. Keep HQ fortified and reserves safe.'}
        answer['plan']=plans[stage];memory['plan_stage']=stage
    assert all(o.get('target') in index for o in desired.values() if 'target' in o)
    return answer,{'pattern':name,'stage':stage,'visible_targets':sorted(index),'assignments':dict(assigned),'choices':trace}
