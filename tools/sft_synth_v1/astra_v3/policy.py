"""Teacher-grounded large-army hypothesis: stable local combined-arms groups.

No seed/style/hidden-state inputs. Small rosters delegate to the frozen v2.
"""
from __future__ import annotations
import json
import math
from collections import Counter
from ..astra_v2.policy import decide as small_decide, SOURCE_FILES as V2_FILES
from ..astra_v1.policy import stats, reach, reposition, upper
from ..policy import view, distance, previews

POLICIES={'astra_sector_groups':{}}
SOURCE_FILES=V2_FILES+('tools/sft_synth_v1/astra_v3/__init__.py','tools/sft_synth_v1/astra_v3/policy.py')

def health(u):
    return u['soldiers']/max(1,u.get('start',300))

def establish_groups(own,foes,hq):
    combat=[u for u in own if u['class'] not in ('HQ','SCOUT')]
    count=max(1,math.ceil(len(combat)/6))
    slow=[u for u in combat if u['class'] not in ('ARCHER','CAVALRY')]
    if not slow:slow=[u for u in combat if u['class']!='CAVALRY'] or combat
    count=min(count,len(slow));assigned=set();groups=[[] for _ in range(count)]
    enemy_center={'q':sum(e['q'] for e in foes)/max(1,len(foes)),
                  'r':sum(e['r'] for e in foes)/max(1,len(foes))}
    dq=enemy_center['q']-hq['q'];dr=enemy_center['r']-hq['r']
    lateral=lambda u:((u['q']-hq['q'])*dr-(u['r']-hq['r'])*dq,u['id'])
    slow=sorted(slow,key=lateral)
    for i,u in enumerate(slow):
        k=min(count-1,i*count//len(slow));groups[k].append(u);assigned.add(u['id'])
    # Archers and cavalry join a nearby slow group, with a capacity penalty that
    # distributes support instead of sending every ranged unit to one front.
    for cls in ('ARCHER','CAVALRY','OTHER'):
        pending=[u for u in combat if u['id'] not in assigned and (u['class']==cls or cls=='OTHER')]
        for u in sorted(pending,key=lateral):
            k=min(range(count),key=lambda k:(min(distance(u,v) for v in groups[k])+len(groups[k])*2+
                                            2*sum(v['class']==u['class'] for v in groups[k]),k))
            groups[k].append(u);assigned.add(u['id'])
    return [[u['id'] for u in g] for g in groups]

def decide(messages,name,memory):
    assert name in POLICIES
    pkt=view(messages);turn=int(pkt['turn'])
    opening=json.loads(next(m['content'] for m in messages if m['role']=='user'))
    initial=sum(u['class']!='HQ' for u in opening['my_units'])
    if initial<=16:return small_decide(messages,'astra_coordinated_finish',memory)
    now=json.loads(next(m['content'] for m in reversed(messages) if m['role']=='user'))
    own=sorted(pkt['my_units'],key=lambda u:u['id']);hq=next(u for u in own if u['class']=='HQ')
    foes=sorted([u for u in pkt['enemy_units'] if u['class']!='HQ'],key=lambda e:e['id'])
    enemy={e['id']:e for e in foes};units={u['id']:u for u in own}
    if 'groups' not in memory:memory['groups']=establish_groups(own,foes,hq)
    groups=[[units[x] for x in ids if x in units] for ids in memory['groups']]
    standing=memory.setdefault('standing',{});targets=memory.setdefault('group_targets',{})
    lastcontact=memory.setdefault('group_contact',{});selected=memory.setdefault('group_selected',{})
    events=now.get('events',[]);threats=[e for e in foes if e.get('eta_strike_my_hq',99)<=1 or hq['id'] in e.get('can_strike_next',[])]
    def group_eta(group,e):
        useful=[u for u in group if health(u)>=.18] or group
        slow=[u for u in useful if stats(pkt,u).get('mp',2)<=2] or useful
        es=sorted(reach(pkt,u,e) for u in slow)
        return es[len(es)//2] if es else 99
    interceptor=min(range(len(groups)),key=lambda k:(min((group_eta(groups[k],e) for e in threats),default=99),k)) if threats else None
    desired={hq['id']:{'do':'FORTIFY' if 'FORTIFY' in messages[0]['content'] else 'HOLD'}}
    occupied_targets=Counter();reserved=set();trace=[]
    for k,group in enumerate(groups):
        if not group:continue
        key=str(k);old=targets.get(key)
        if any(' attack '+str(old)+':' in ev and any(' '+u['id']+' attack ' in ' '+ev for u in group) for ev in events):lastcontact[key]=turn
        useful=[u for u in group if health(u)>=.18] or group
        anchor=min(useful,key=lambda u:sum(distance(u,v) for v in useful))
        scores=[]
        for e in foes:
            eta=group_eta(group,e);vs=[(u,previews(u).get(e['id'])) for u in useful]
            immediate=sum(max(0,v['dealt']+.6*v.get('fw',0)-.75*v['taken']) for u,v in vs if v and v['eta']<=1)
            nearby=sum(reach(pkt,u,e)<=2 for u in useful)
            penalty=2.5*eta+upper(e)/220+e.get('fortified',0)/220-immediate/45-nearby*.35
            penalty+=occupied_targets[e['id']]*3
            if stats(pkt,e).get('mp',2)>2 and eta>1:penalty+=2
            if interceptor==k and e in threats:penalty-=15
            scores.append((penalty,e['id'],eta))
        best=min(scores) if scores else None;target=enemy.get(old);reason='retained'
        if target is None:target=enemy[best[1]] if best else None;reason='new local field target'
        elif best:
            current=next(x for x in scores if x[1]==old)
            stalled=turn-lastcontact.get(key,selected.get(key,turn))>=6
            immediate_threat=interceptor==k and target not in threats and best[1] in {e['id'] for e in threats}
            if immediate_threat or (stalled and best[2]+2<=current[2]):
                target=enemy[best[1]];reason='HQ interception' if immediate_threat else 'no-contact local redirect'
        if target and target['id']!=old:
            targets[key]=target['id'];selected[key]=turn;lastcontact[key]=turn
        if target:occupied_targets[target['id']]+=1
        for u in sorted(group,key=lambda u:u['id']):
            uid=u['id'];v=previews(u).get(target['id']) if target else None
            danger=any(uid in e.get('can_strike_next',[]) for e in foes)
            taken=v['taken'] if v else 0
            weak=health(u)<.18 and (not v or taken>u['soldiers']*.25)
            if target is None:order={'do':'HOLD'}
            elif weak or taken>=u['soldiers']*.65:
                order=reposition(pkt,u,foes,hq,reserved) if danger else {'do':'HOLD'}
            elif stats(pkt,u).get('range',1)>=2 and distance(u,target)<=1 and taken>0:
                order=reposition(pkt,u,foes,anchor,reserved,ranged_target=target)
            else:
                eta=reach(pkt,u,target);support=sum(reach(pkt,a,target)<=1 for a in useful if a['id']!=uid)
                if u['class']=='CAVALRY' and eta<=1 and support==0 and len(useful)>1:
                    order=reposition(pkt,u,foes,anchor,reserved)
                elif u['class']=='CAVALRY' and v and v['eta']<=1 and support>=1 and 'RAID' in messages[0]['content']:
                    # Attack, then return to this displayed approach cell; no engine
                    # assumption about unspent movement or successful escape is made.
                    order={'do':'RAID','target':target['id'],'back_to':[u['q'],u['r']]}
                else:order={'do':'ATTACK','target':target['id']}
            desired[uid]=order
        trace.append({'group':k,'members':[u['id'] for u in group],'target':target['id'] if target else None,
                      'reason':reason,'group_eta':group_eta(group,target) if target else None})
    for u in own:
        if u['class']!='SCOUT':continue
        danger=any(u['id'] in e.get('can_strike_next',[]) for e in foes)
        desired[u['id']]=reposition(pkt,u,foes,hq,reserved) if danger else {'do':'HOLD'}
    changed={uid:o for uid,o in desired.items() if standing.get(uid,{'do':'HOLD'})!=o}
    standing.update(changed);answer={'orders':changed}
    stage='local_interception' if threats else 'local_groups'
    if turn==1 or memory.get('group_stage')!=stage:
        answer['plan']=('Local interception: the nearest combined-arms group turns onto the visible HQ threat while other groups finish their field targets. Keep HQ fortified and scouts safe.' if threats else
                        'Local combined-arms groups: advance on separate nearby field targets, keep archers with their melee support and stage cavalry until support can join. Retain group targets through fieldworks, release groups after kills and preserve scouts and HQ.')
        memory['group_stage']=stage
    return answer,{'pattern':name,'stage':stage,'visible_targets':sorted(enemy),'groups':trace,'assignments':dict(occupied_targets)}
