"""Decisions use ONLY game-emitted messages. No request state or game record is accepted."""
from __future__ import annotations
import json
import math
import re
from collections import Counter

POLICIES = {
    'mass_focus':dict(focus=3, counter=.25, approach=1.4, opening=0, threat=1, wounded=0),
    'matched_pairs':dict(focus=2, counter=.65, approach=1.0, opening=0, threat=1, wounded=0),
    'screened_fire':dict(focus=3, counter=1.2, approach=1.0, opening=0, threat=2, wounded=.18),
    'defensive_anvil':dict(focus=3, counter=.65, approach=1.0, opening=3, threat=3, wounded=.12),
}
PLAN = {
    'mass_focus':'Close the field army in small assault groups and focus reachable, weakened field units until 70% are destroyed. Keep the HQ stationary and intercept immediate threats; ignore the enemy HQ.',
    'matched_pairs':'Close on favorable field matchups with paired attackers, then finish weakened units. Keep the HQ at home. Destroy the required field-unit count instead of attacking the enemy HQ.',
    'screened_fire':'Use infantry and spears as the screen, combine ranged fire on weakened field units, and preserve badly wounded units when safe. Keep the HQ fortified; win by field-unit destruction.',
    'defensive_anvil':'Form a compact screened line near our HQ, draw the enemy field army into combined attacks, then advance together to finish the required field units. Keep our HQ fixed and do not chase their HQ.',
    'intercept':'Switch to concentrated interception of enemies threatening our HQ, with the field army attacking the threat together. After it is removed, resume destroying field units; keep the HQ fixed.',
    'finish':'Abandon dispersed pairing and concentrate groups on reachable field units to break the lack of kills. Keep pressing with explicit ATTACK orders while protecting our stationary HQ.',
}
RX=re.compile(r'^(\S+) eta (\d+) dealt (\d+)-(\d+) taken (\d+)-(\d+)(?: fw (\d+))?')

def distance(a,b):
    q=a['q']-b['q'];r=a['r']-b['r'];return (abs(q)+abs(r)+abs(q+r))/2

def view(messages):
    """Rebuild current displayed units from immutable opening plus the last resident delta."""
    users=[m['content'] for m in messages if m['role']=='user']
    # Folded intermediate turns begin with a human-readable BATTLE DIGEST, not JSON.
    # The immutable opening and latest turn are the two complete displayed state views.
    opening=json.loads(users[0]); now=json.loads(users[-1])
    if isinstance(now['my_units'][0],dict): return json.loads(json.dumps(now))
    index={u['id']:u for key in ['my_units','enemy_units'] for u in opening[key]}
    out={k:opening[k] for k in ['class_stats','matchups','map_radius'] if k in opening}
    out.update(turn=now['turn'],turns_left=now.get('turns_left',60-now['turn']+1))
    for key in ['my_units','enemy_units']:
        rows=[]
        for line in now[key]:
            body,*vs=line.split(' | ');tok=body.split();uid=tok[0]
            old=index.get(uid,{});c=old.get('class')
            if c is None:
                aliases={'INF':'INFANTRY','SPE':'SPEAR','ARC':'ARCHER','CAV':'CAVALRY','SCT':'SCOUT','HQ':'HQ'}
                c=aliases.get(uid.split('_')[1],uid.split('_')[1])
            q,r=map(int,tok[1].split(','));row={'id':uid,'class':c,'q':q,'r':r}
            if key=='my_units': row.update(soldiers=int(tok[2]),start=old.get('start',int(tok[2])),vs=vs[0].split('; ') if vs else [])
            else: row['troops']=tok[2]
            for label,dest in [('fort','fortified'),('eta_my_hq','eta_strike_my_hq')]:
                if label in tok: row[dest]=int(tok[tok.index(label)+1])
            if 'next' in tok: row['can_strike_next']=tok[tok.index('next')+1].split(',')
            if 'seen' in tok: row['last_seen_turn']=int(tok[tok.index('seen')+1].lstrip('t'))
            rows.append(row)
        out[key]=rows
    return out

def previews(u):
    out={}
    for text in u.get('vs',[]):
        m=RX.match(text)
        if m: out[m[1]]=dict(eta=int(m[2]),dealt=(int(m[3])+int(m[4]))/2,taken=(int(m[5])+int(m[6]))/2,fw=int(m[7] or 0))
    return out

def band(e):
    ns=[int(n) for n in re.findall(r'\d+',str(e.get('troops','')))];return sum(ns)/len(ns) if ns else 300

def matchup(pkt,u,e):
    row=pkt.get('matchups',{}).get(u['class'],'')
    m=re.search(r'\b'+re.escape(e['class'])+r' ([0-9.]+)',str(row));return float(m[1]) if m else 1.0

def order_text(o):
    s=o.get('do','HOLD')
    for k in ['target','to','back_to']:
        if k in o:
            v=o[k];s+=(' back ' if k=='back_to' else ' ')+(','.join(map(str,v)) if isinstance(v,list) else str(v))
    return s

def decide(messages,policy,memory):
    pkt=view(messages);p=POLICIES[policy];system=messages[0]['content']
    assert 'Focus fire:' not in system, 'Hints must be removed in the isolated game before play'
    turn=int(pkt['turn']); own=sorted(pkt['my_units'],key=lambda u:u['id']);mine=[u for u in own if u['class']!='HQ']
    foes=[e for e in pkt['enemy_units'] if e['class']!='HQ'];hq=next(u for u in own if u['class']=='HQ')
    current=set(e['id'] for e in foes)
    if memory.get('previous_enemies',current)-current: memory['last_kill']=turn
    memory['previous_enemies']=current
    threats=[e for e in foes if int(e.get('eta_strike_my_hq',99))<=p['threat'] or hq['id'] in e.get('can_strike_next',[])]
    stage='intercept' if threats else 'opening' if turn<=p['opening'] else 'finish' if turn-memory.get('last_kill',1)>=12 else policy
    desired={hq['id']:{'do':'FORTIFY' if '"do": "FORTIFY"' in system else 'HOLD'}}
    assigned=Counter();trace=[];focus=max(p['focus'],4) if stage in ['intercept','finish'] else p['focus']
    if stage=='opening':
        # Point-mirrored formation, occupied cells avoided; positions computed from displayed own HQ.
        direction=-1 if hq['q']>0 else 1
        for i,u in enumerate(mine):
            line=4 if u['class']=='ARCHER' else 6
            lateral=(i//2+1)*(1 if i%2==0 else -1)
            q=hq['q']+direction*line;r=hq['r']+lateral
            while (abs(q)+abs(r)+abs(q+r))/2>pkt['map_radius']:r=int(r/2);q=int(q/2)
            desired[u['id']]={'do':'MOVE','to':[q,r]}
    else:
        for u in mine:
            vs=previews(u);candidates=[]
            for e in foes:
                st=pkt['class_stats'].get(u['class'],{})
                eta=max(0,math.ceil((distance(u,e)-float(st.get('range',1)))/max(.1,float(st.get('mp',3)))))
                v=vs.get(e['id']); mult=matchup(pkt,u,e)
                if v: score=(v['dealt']+.5*v['fw']-p['counter']*v['taken'])/(1+p['approach']*v['eta']);eta=v['eta']
                else:score=20*mult*(u['soldiers']/max(1,u.get('start',300)))/(1+p['approach']*eta)
                score += 8*max(0,(300-band(e))/300)/(1+eta)
                score += 10*assigned[e['id']]/(1+eta)
                if stage=='intercept' and e in threats: score+=150/(1+eta)
                candidates.append((assigned[e['id']]>=focus,-score,eta,e['id'],v))
            if candidates:
                _,neg,eta,tgt,v=min(candidates)
                if p['wounded'] and len(mine)>3 and u['soldiers']<p['wounded']*u.get('start',300) and not threats and (v or {}).get('taken',0)>u['soldiers']*.5:
                    desired[u['id']]={'do':'MOVE','to':'MY_HQ'}
                else:
                    desired[u['id']]={'do':'ATTACK','target':tgt};assigned[tgt]+=1
                trace.append({'unit':u['id'],'target':tgt,'score':round(-neg,5),'eta':eta,'preview':v})
            else:
                # Scout toward a remembered displayed field position; never turn to enemy HQ.
                last=memory.get('last_field_pos')
                desired[u['id']]={'do':'MOVE','to':last} if last else {'do':'HOLD'}
    if foes:memory['last_field_pos']=[foes[0]['q'],foes[0]['r']]
    standing=memory.setdefault('standing',{})
    # Opening standing orders are visible; later standing orders come from our played replies.
    for u in own:
        if 'order' in u and u['id'] not in standing:
            if u['order']=='HOLD':standing[u['id']]={'do':'HOLD'}
    changed={uid:o for uid,o in desired.items() if standing.get(uid,{'do':'HOLD'})!=o}
    standing.update(changed)
    answer={'orders':changed}
    plan_stage=policy if stage=='opening' else stage
    if turn==1 or memory.get('plan_stage')!=plan_stage:
        answer['plan']=PLAN[plan_stage];memory['plan_stage']=plan_stage
    assert all(not ('target' in o and 'HQ' in o['target']) for o in desired.values())
    assert desired[hq['id']]['do'] in ['HOLD','FORTIFY']
    return answer,{'pattern':policy,'stage':stage,'visible_targets':sorted(current),'assignments':dict(assigned),'choices':trace}
