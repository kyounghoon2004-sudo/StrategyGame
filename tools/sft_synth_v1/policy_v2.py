"""One-fist target continuity, derived from INTER12 and BASIC7 teacher trajectories.

Unlike the first generators, the whole mobile army shares one persistent field
target. A changed target does not rewrite the plan. Only HQ interception changes
the strategy. Inputs remain the exact resident messages, never the extra state.
"""
from __future__ import annotations
import math
from collections import Counter
from .policy import view,previews,distance,matchup,band

NAME='cohesive_focus'
FOCUS_PLAN='Advance the field army as one fist and keep one field target until it is destroyed, combining ranged fire with melee finishers. Avoid dispersed pursuit, then retarget the next field unit. Keep our HQ fortified; destroying their HQ is not our goal.'
GUARD_PLAN='Switch the field army to concentrated interception of the immediate threat to our HQ. Keep the HQ fortified. When the threat is gone, resume one-target field-unit destruction as a group.'

def decide(messages,policy,memory):
    assert policy==NAME
    pkt=view(messages);system=messages[0]['content'];assert 'Focus fire:' not in system
    own=sorted(pkt['my_units'],key=lambda u:u['id']);mine=[u for u in own if u['class']!='HQ']
    foes={e['id']:e for e in pkt['enemy_units'] if e['class']!='HQ'};hq=next(u for u in own if u['class']=='HQ')
    turn=pkt['turn'];threats={uid:e for uid,e in foes.items() if int(e.get('eta_strike_my_hq',99))<=1 or hq['id'] in e.get('can_strike_next',[])}
    stage='hq_intercept' if threats else 'cohesive_focus';pool=threats or foes
    target=memory.get('target')
    scored=[]
    for uid,e in pool.items():
        eta=[];damage=0
        for u in mine:
            v=previews(u).get(uid)
            stats=pkt['class_stats'][u['class']]
            step=max(0,math.ceil((distance(u,e)-stats['range'])/max(.1,stats['mp'])))
            eta.append(step)
            if v:damage+=(v['dealt']+v['fw']*.65-v['taken']*.35)/(1+step)
            else:damage+=18*matchup(pkt,u,e)*(u['soldiers']/max(1,u['start']))/(1+step)
        score=damage/(1+sum(eta)/max(1,len(eta)))+4*(300-band(e))/300
        scored.append((-score,uid,eta))
    # Keep a primary target through movement and fieldworks, instead of re-pairing
    # each unit every turn. If the target goes away, pick a new displayed field unit.
    if target not in pool or memory.get('stage')!=stage:
        target=min(scored)[1] if scored else None
    memory['target']=target;memory['stage']=stage
    desired={hq['id']:{'do':'FORTIFY' if '"do": "FORTIFY"' in system else 'HOLD'}}
    for u in mine:desired[u['id']]={'do':'ATTACK','target':target} if target else {'do':'HOLD'}
    standing=memory.setdefault('standing',{})
    changed={uid:o for uid,o in desired.items() if standing.get(uid,{'do':'HOLD'})!=o};standing.update(changed)
    answer={'orders':changed}
    if turn==1 or memory.get('plan_stage')!=stage:
        answer['plan']=GUARD_PLAN if stage=='hq_intercept' else FOCUS_PLAN;memory['plan_stage']=stage
    return answer,{'pattern':policy,'stage':stage,'visible_targets':sorted(foes),'assignments':dict(Counter(o['target'] for o in desired.values() if 'target' in o)),
        'choices':[{'target':uid,'score':round(-neg,5),'displayed_approach_turns':eta} for neg,uid,eta in scored]}
