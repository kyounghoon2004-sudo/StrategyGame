"""Conditional repair: preserve v1 opening, explicitly converge the final kill group.

No seed, opponent style, native record or hidden count enters decisions.
"""
from __future__ import annotations
import json
import math
from copy import deepcopy
from ..astra_v1.policy import (decide as opening_decide, SOURCE_FILES as V1_FILES,
                              stats, reach, reposition, upper)
from ..policy import view, distance, previews

POLICIES={'astra_coordinated_finish':{'opening':'astra_screened_pressure'}}
SOURCE_FILES=V1_FILES+('tools/sft_synth_v1/astra_v2/__init__.py','tools/sft_synth_v1/astra_v2/policy.py')

def decide(messages,name,memory):
    config=POLICIES[name]; pkt=view(messages);turn=int(pkt['turn'])
    first=json.loads(next(m['content'] for m in messages if m['role']=='user'))
    now=json.loads(next(m['content'] for m in reversed(messages) if m['role']=='user'))
    foes=sorted([u for u in pkt['enemy_units'] if u['class']!='HQ'],key=lambda u:u['id'])
    field=sorted([u for u in pkt['my_units'] if u['class']!='HQ'],key=lambda u:u['id'])
    hq=next(u for u in pkt['my_units'] if u['class']=='HQ')
    initial=sum(u['class']!='HQ' for u in first['enemy_units'])
    required=math.ceil(initial*.7); observed_destroyed=max(0,initial-len(foes))
    # The original opening is preserved until the last two required field kills.
    if observed_destroyed<max(1,required-2) and not memory.get('finish_mode'):
        return opening_decide(messages,config['opening'],memory)
    entering=not memory.get('finish_mode');memory['finish_mode']=True
    standing=memory.setdefault('standing',{})
    original=deepcopy(standing);index={e['id']:e for e in foes}
    events=now.get('events',[]);oldtarget=memory.get('finish_target')
    # Actual visible attacks measure progress; band fluctuation is not troop healing.
    progress=[s for s in events if ' attack '+str(oldtarget)+':' in s and any(' '+u['id']+' attack ' in ' '+s for u in field)]
    if progress:memory['finish_last_contact']=turn
    health=lambda u:u['soldiers']/max(1,u.get('start',300))
    force=[u for u in field if u['class']!='SCOUT' and health(u)>=.18]
    if not force:force=[u for u in field if u['class']!='SCOUT'] or field
    slow=[u for u in force if stats(pkt,u).get('mp',2)<=2] or force
    anchor=min(slow,key=lambda u:sum(distance(u,v) for v in slow)) if slow else hq
    threats=[e for e in foes if e.get('eta_strike_my_hq',99)<=1 or hq['id'] in e.get('can_strike_next',[])]
    estimates=[]
    for e in foes:
        etas=sorted(reach(pkt,u,e) for u in slow)
        group_eta=etas[min(len(etas)-1,math.ceil(len(etas)*.75)-1)] if etas else 99
        available=[(u,previews(u).get(e['id'])) for u in force]
        troop=sum(v['dealt'] for u,v in available if v and v['eta']<=1)
        works=sum(v.get('fw',0) for u,v in available if v and v['eta']<=1)
        # Potential support within two turns helps distinguish a credible combined siege.
        support=sum(reach(pkt,u,e)<=2 for u in force)
        oldpos=memory.get('finish_positions',{}).get(e['id'])
        moved=distance(e,oldpos) if oldpos else 0
        speed=stats(pkt,e).get('mp',2)
        fleeing_penalty=5 if speed>2 and moved>0 and group_eta>1 else 0
        cost=group_eta*3+fleeing_penalty+upper(e)/180+e.get('fortified',0)/180-support*.5-(troop+works*.45)/35
        if e in threats:cost-=15
        estimates.append((cost,e['id'],group_eta,troop,works))
    best=min(estimates) if estimates else None
    target=index.get(oldtarget)
    why='retained'
    if target is None:
        target=index[best[1]] if best else None;why='initial convergence' if entering else 'prior target destroyed or absent'
    elif best:
        old=next(x for x in estimates if x[1]==oldtarget)
        no_contact=turn-memory.get('finish_last_contact',memory.get('finish_selected_turn',turn))
        # Do not abandon a target simply because its fortifications renew. Redirect only
        # when the moving chase made no attacks for six decisions and another is nearer.
        moving=distance(target,memory.get('finish_positions',{}).get(oldtarget,target))>0
        if threats and target not in threats and best[1] in {e['id'] for e in threats}:
            target=index[best[1]];why='HQ interception'
        elif no_contact>=6 and moving and old[2]>2 and best[2]+2<=old[2]:
            target=index[best[1]];why='unproductive moving chase replaced'
    if target and target['id']!=oldtarget:
        memory['finish_target']=target['id'];memory['finish_selected_turn']=turn;memory['finish_last_contact']=turn
    memory['finish_positions']={e['id']:{'q':e['q'],'r':e['r']} for e in foes}
    desired={hq['id']:{'do':'FORTIFY' if 'FORTIFY' in messages[0]['content'] else 'HOLD'}}
    reserved=set();choices=[]
    for u in field:
        uid=u['id'];v=previews(u).get(target['id']) if target else None
        counter=v['taken'] if v else 0
        danger=any(uid in e.get('can_strike_next',[]) for e in foes)
        scout=u['class']=='SCOUT'
        unsafe=(health(u)<.18 and (not v or counter>u['soldiers']*.30)) or (v and counter>=u['soldiers']*.65)
        if target is None:order={'do':'HOLD'}
        elif scout and (not v or v['eta']>1 or counter>max(2,u['soldiers']*.08) or v['dealt']<2):
            order=reposition(pkt,u,foes,hq,reserved) if danger else {'do':'HOLD'}
        elif unsafe:
            order=reposition(pkt,u,foes,hq,reserved) if danger else {'do':'HOLD'}
        elif stats(pkt,u).get('range',1)>=2 and distance(u,target)<=1 and counter>0:
            order=reposition(pkt,u,foes,anchor,reserved,ranged_target=target)
        else:
            # This hard assignment is the repair: local per-unit scores cannot split
            # the remaining useful attackers between different board-edge pursuits.
            order={'do':'ATTACK','target':target['id']}
        desired[uid]=order;choices.append({'unit':uid,'target':target['id'] if target else None,'order':order,'preview':v})
    changed={uid:o for uid,o in desired.items() if original.get(uid,{'do':'HOLD'})!=o}
    standing.update(changed);answer={'orders':changed}
    if entering:
        answer['plan']='Coordinated finish: only the final required field kills remain. Converge useful infantry, spears and archers on one reachable field target, retain it through renewed works, and keep depleted units safe. Stop separate long chases; HQ stays fortified.'
    elif why=='HQ interception':
        answer['plan']='HQ interception: converge the finishing group on the visible field threat at our HQ. Keep HQ fortified and destroy this target together before resuming the final field kills.'
    elif why=='unproductive moving chase replaced':
        answer['plan']='End the unproductive chase: converge the finishing group on a nearer field target that the slower units can reach. Keep ranged support with that group, sustain attacks through works and preserve our fortified HQ.'
    return answer,{'pattern':name,'stage':'coordinated_finish','visible_targets':sorted(index),
                   'observed_destroyed':observed_destroyed,'required':required,'target':target['id'] if target else None,
                   'selection_reason':why,'estimates':[{'target':x[1],'cost':round(x[0],5),'group_eta':x[2],'troop_preview':x[3],'works_preview':x[4]} for x in estimates],
                   'choices':choices}
