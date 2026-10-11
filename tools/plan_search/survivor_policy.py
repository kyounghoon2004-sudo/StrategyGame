"""Packet-only executable policy. No model, simulator, private state, or random decisions."""
from __future__ import annotations
import json
import math
from tools.plan_search.synth_commander import _mult, _vs

DEFAULT = dict(commit_turn=17, commit_share=.3, cleanup_count=2, threat_eta=3,
               max_focus=2, casualty_weight=1., approach_weight=1., fieldwork_weight=.5,
               attack_floor=-100., wounded_soldiers=0, wounded_mode="fight",
               reserve_share=0., opening_turns=0, opening="engage", flank=0,
               hq_exploit_eta=0, hq_classes=[], target_priority=[], raid=False,
               raid_back="MY_HQ", abandon_turn=65, regroup_eta=99)
ENUMS = {"wounded_mode": ["fight", "retreat", "fortify"],
         "opening": ["engage", "defend", "regroup", "flank"],
         "raid_back": ["MY_HQ", "support"]}
BOUNDS = {"commit_turn": (1,70), "commit_share": (0,1), "cleanup_count": (0,6),
          "threat_eta": (0,8), "max_focus": (1,9), "casualty_weight": (0,3),
          "approach_weight": (0,3), "fieldwork_weight": (0,2), "attack_floor": (-100,30),
          "wounded_soldiers": (0,160), "reserve_share": (0,.5), "opening_turns": (0,20),
          "flank": (-1,1), "hq_exploit_eta": (0,8), "abandon_turn": (15,80),
          "regroup_eta": (1,99)}
CLASSES = ["CAVALRY","INFANTRY","SPEAR","ARCHER","SCOUT","SIEGE","CONSCRIPT"]

def normalize(raw):
    if set(raw)-set(DEFAULT): raise ValueError("unknown policy parameters")
    p = DEFAULT | raw
    for k,(lo,hi) in BOUNDS.items():
        if not isinstance(p[k], (int,float)) or isinstance(p[k],bool) or not lo <= p[k] <= hi:
            raise ValueError(f"bad {k}: {p[k]}")
        if isinstance(DEFAULT[k],int) and not isinstance(p[k],int): raise ValueError(f"integer {k}")
    for k,vals in ENUMS.items():
        if p[k] not in vals: raise ValueError(f"bad {k}")
    if not isinstance(p['raid'],bool): raise ValueError('raid boolean')
    for k in ['hq_classes','target_priority']:
        if not isinstance(p[k],list) or any(x not in CLASSES for x in p[k]): raise ValueError(k)
    return p

def preview(u):
    out = _vs(u)
    for v in u.get('vs',[]):
        if isinstance(v,dict):
            def mid(x):
                s=str(x or '0'); a=s.split('-');return sum(float(z) for z in a)/len(a)
            out[v['id']] = dict(eta=int(v.get('eta',99)),dealt=mid(v.get('dealt')),
                                taken=mid(v.get('taken')),fw=mid(v.get('fw')))
    return out

def distance(a,b):
    dq=a.get('q',0)-b.get('q',0);dr=a.get('r',0)-b.get('r',0)
    return (abs(dq)+abs(dr)+abs(dq+dr))/2

def decide(pkt,system,p):
    """Returns exact reply plus auditable branch facts, used for post-survival rationales."""
    turn=int(pkt['turn']); left=int(pkt.get('turns_left',80-turn+1))
    mine=sorted([u for u in pkt['my_units'] if u['class']!='HQ'],key=lambda u:u['id'])
    foes=sorted([e for e in pkt['enemy_units'] if e['class']!='HQ'],key=lambda e:e['id'])
    hq=next((u for u in pkt['my_units'] if u['class']=='HQ'),None)
    ehq=next((e for e in pkt['enemy_units'] if e['class']=='HQ'),None)
    verbs={'ATTACK','MOVE','HOLD'} | {v for v in ['FORTIFY','RAID'] if '"do": "%s"'%v in system}
    orders={}; branches={}; assigned={}; free=list(mine)
    def setorder(u,o,branch,facts):
        orders[u['id']]=o;branches[u['id']]={'branch':branch,'facts':facts}
        if u in free: free.remove(u)
        if 'target' in o: assigned[o['target']]=assigned.get(o['target'],0)+1
    def defend(u,branch,facts):
        setorder(u,{'do':'FORTIFY' if 'FORTIFY' in verbs else 'HOLD'},branch,facts)
    if hq: defend(hq,'hq_defense',{'fortify_available':'FORTIFY' in verbs})
    # Defense is allocated before the strike group, unlike the old synthesis baseline.
    threats=[e for e in foes if int(e.get('eta_strike_my_hq',99))<=p['threat_eta']]
    for e in sorted(threats,key=lambda e:(int(e.get('eta_strike_my_hq',99)),e['id'])):
        if not free: break
        best=max(free,key=lambda u:(_mult(pkt,u['class'],e['class'])/(1+preview(u).get(e['id'],{}).get('eta',99)),u['soldiers'],u['id']))
        setorder(best,{'do':'ATTACK','target':e['id']},'hq_threat',{'enemy':e['id'],'eta_strike_my_hq':e.get('eta_strike_my_hq')})
    for u in list(free):
        if u['soldiers']<=p['wounded_soldiers'] and p['wounded_mode']!='fight':
            facts={'soldiers':u['soldiers'],'threshold':p['wounded_soldiers']}
            if p['wounded_mode']=='fortify': defend(u,'wounded_fortify',facts)
            else: setorder(u,{'do':'MOVE','to':'MY_HQ'},'wounded_retreat',facts)
    reserve=round(len(mine)*p['reserve_share'])
    if hq and not threats and turn<p['abandon_turn']:
        for u in sorted(free,key=lambda u:(distance(u,hq),u['id']))[:reserve]:
            defend(u,'reserve',{'reserve_share':p['reserve_share'],'distance_my_hq':distance(u,hq)})
    strike_n=0
    if ehq and (turn>=p['commit_turn'] or len(foes)<=p['cleanup_count'] or turn>=p['abandon_turn']):
        strike_n=len(free) if len(foes)<=p['cleanup_count'] or turn>=p['abandon_turn'] else round(len(mine)*p['commit_share'])
    eligible=sorted(free,key=lambda u:(bool(p['hq_classes']) and u['class'] not in p['hq_classes'],u.get('eta',{}).get('strike_enemy_hq',99),-u['soldiers'],u['id']))
    strike={u['id'] for u in eligible[:strike_n]}
    if ehq:
        strike |= {u['id'] for u in free if u.get('eta',{}).get('strike_enemy_hq',99)<=p['hq_exploit_eta']}
    for u in list(free):
        if u['id'] in strike:
            setorder(u,{'do':'ATTACK','target':'ENEMY_HQ'},'hq_strike',{'eta':u.get('eta',{}).get('strike_enemy_hq'),'turn':turn,'commit_turn':p['commit_turn'],'field_enemies':len(foes)})
    for u in list(free):
        vs=preview(u); candidates=[]
        for e in foes:
            if e['id'] not in vs: continue
            v=vs[e['id']]
            priority=len(p['target_priority'])-p['target_priority'].index(e['class']) if e['class'] in p['target_priority'] else 0
            score=(_mult(pkt,u['class'],e['class'])*(v['dealt']+p['fieldwork_weight']*v['fw'])-p['casualty_weight']*v['taken'])/(1+p['approach_weight']*v['eta'])+priority*3
            candidates.append((assigned.get(e['id'],0)>=p['max_focus'],-score,e['id'],v))
        if turn<=p['opening_turns'] and p['opening']!='engage':
            if p['opening']=='defend': defend(u,'opening_defend',{'turn':turn,'opening_turns':p['opening_turns']});continue
            if p['opening']=='regroup' and mine:
                anchor=min(mine,key=lambda x:(x.get('eta',{}).get('reach_my_hq',99),x['id']))
                if anchor['id']==u['id']: defend(u,'regroup_anchor',{'turn':turn})
                else: setorder(u,{'do':'MOVE','to':anchor['id']},'opening_regroup',{'anchor':anchor['id'],'turn':turn})
                continue
            if p['opening']=='flank' and ehq:
                radius=int(pkt.get('map_radius',pkt.get('map',{}).get('radius',24))) if isinstance(pkt.get('map',{}),dict) else 24
                r=round(p['flank']*min(10,radius//2)); q=round((u['q']+ehq['q'])/2)
                while (abs(q)+abs(r)+abs(q+r))/2>radius: q=round(q/2);r=round(r/2)
                setorder(u,{'do':'MOVE','to':[q,r]},'opening_flank',{'enemy_hq':[ehq['q'],ehq['r']],'flank':p['flank'],'destination':[q,r]});continue
        if candidates:
            _,neg,tgt,v=min(candidates,key=lambda x:x[:3]);score=-neg
            facts={'target':tgt,'preview':v,'score':round(score,5),'floor':p['attack_floor']}
            if score<p['attack_floor'] and turn<p['abandon_turn']:
                defend(u,'unfavorable_hold',facts)
            elif v['eta']>p['regroup_eta'] and turn<p['abandon_turn'] and hq:
                setorder(u,{'do':'MOVE','to':'MY_HQ'},'distant_regroup',facts)
            elif p['raid'] and u['class']=='CAVALRY' and 'RAID' in verbs:
                support=next((x['id'] for x in mine if x['class'] in ['SPEAR','INFANTRY'] and x['id']!=u['id']),'MY_HQ')
                setorder(u,{'do':'RAID','target':tgt,'back_to':support if p['raid_back']=='support' else 'MY_HQ'},'raid',facts)
            else: setorder(u,{'do':'ATTACK','target':tgt},'field_attack',facts)
        elif ehq: setorder(u,{'do':'ATTACK','target':'ENEMY_HQ'},'no_field_target',{'visible_field_enemies':len(foes)})
        else: defend(u,'no_visible_target',{'visible_field_enemies':len(foes)})
    counts={b:sum(x['branch']==b for x in branches.values()) for b in sorted({x['branch'] for x in branches.values()})}
    plan=('Execute %s: %s.'%(p['opening'],', '.join('%s=%d'%(k,v) for k,v in counts.items())))[:300]
    reply={'plan':plan,'notes':('Turn %d; %d visible field enemies; commit from %d; abandon delay from %d.'%(turn,len(foes),p['commit_turn'],p['abandon_turn']))[:600],'orders':orders}
    validate(pkt,system,reply)
    return reply,{'turn':turn,'turns_left':left,'branches':branches,'branch_counts':counts}

def validate(pkt,system,reply):
    own={u['id']:u for u in pkt['my_units']};enemy={e['id'] for e in pkt['enemy_units']}
    for uid,o in reply['orders'].items():
        assert uid in own and o['do'] in ['ATTACK','MOVE','HOLD','RAID','FORTIFY']
        if o['do'] in ['ATTACK','RAID']: assert o['target'] in enemy or o['target']=='ENEMY_HQ'
        if o['do']=='RAID': assert own[uid]['class']=='CAVALRY' and '"do": "RAID"' in system
        if o['do']=='FORTIFY': assert '"do": "FORTIFY"' in system

def rationale(pkt,trace):
    # Brief decision summary, no hindsight or private enemy counts.
    bits=['Turn %s: follow the configured policy using the visible packet.'%pkt['turn']]
    for uid,t in trace['branches'].items():
        f=t['facts'];b=t['branch']
        if b in ['field_attack','raid']:
            v=f['preview'];bits.append('%s %s %s (eta %s, preview dealt %.1f, taken %.1f, fieldworks %.1f).'%(uid,'raids' if b=='raid' else 'attacks',f['target'],v['eta'],v['dealt'],v['taken'],v['fw']))
        elif b=='hq_threat': bits.append('%s answers %s, whose HQ attack ETA is %s.'%(uid,f['enemy'],f['eta_strike_my_hq']))
        elif b=='hq_strike': bits.append('%s pressures the enemy HQ (ETA %s) under the commitment rule.'%(uid,f['eta']))
        else: bits.append('%s follows %s.'%(uid,b.replace('_',' ')))
    return ' '.join(bits)
