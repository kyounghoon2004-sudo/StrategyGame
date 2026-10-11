"""Independent admission audit: recorded Godot outcomes, actual standing orders, prompt replay."""
from __future__ import annotations
import json
from collections import defaultdict
from pathlib import Path
from .analyze import OUT, ROOT, sha
from .policy import decide, order_text
from .campaign import HELDOUT, victory, evaluate, policy_sha

def lines(path):
    return [json.loads(l) for l in path.read_text(encoding='utf-8').splitlines() if l.strip()] if path.exists() else []

def audit(stage):
    d=OUT/stage;calls=defaultdict(list)
    for row in lines(d/'raw/calls.jsonl'):calls[row['game']].append(row)
    errors=defaultdict(list)
    for row in lines(d/'raw/errors.jsonl'):errors[row['game']].append(row['error'])
    audits=[]
    for result in lines(d/'results.jsonl'):
        game=result['game'];rs=sorted(calls[game],key=lambda r:r['turn']);bad=[];memory={}
        res=json.loads((d/'games'/f'{game}.json').read_text(encoding='utf-8'))
        won,facts=victory(res,result['pov'])
        if facts.get('own_initial_non_hq',-1)+1!=result['size'] or facts.get('enemy_initial_non_hq',-1)+1!=result['size']:bad.append('actual roster size mismatch')
        if not rs:bad.append('no commander calls')
        if errors[game]:bad+=errors[game]
        if result['seed'] in HELDOUT:bad.append('heldout seed used')
        if rs and [r['turn'] for r in rs]!=list(range(1,len(rs)+1)):bad.append('nonsequential resident calls')
        opening=sha(json.dumps(rs[0]['messages'][:2],sort_keys=True,ensure_ascii=False)) if rs else None
        for r in rs:
            prefix=f"turn {r['turn']}: "
            answer=json.loads(r['raw']);msgs=r['messages'];state=r['state']
            if r['source_sha256']!=policy_sha(result['policy']):bad.append(prefix+'policy source drift')
            if sha(json.dumps(msgs[:2],sort_keys=True,ensure_ascii=False))!=opening:bad.append(prefix+'resident opening changed/reset')
            if r['turn']>1 and len(msgs)<=2:bad.append(prefix+'fresh packet/reset')
            if any('\r' in m['content'] for m in msgs):bad.append(prefix+'noncanonical newlines')
            if 'Focus fire:' in msgs[0]['content']:bad.append(prefix+'hint in prompt')
            expected,trace=evaluate(msgs,result['policy'],memory)
            if answer!=expected or trace!=r['trace']:bad.append(prefix+'visible-message replay mismatch')
            if r['raw']!=json.dumps(answer,ensure_ascii=False,separators=(',',':')):bad.append(prefix+'noncompact completion')
            if len(answer.get('plan',''))>300 or r['turn']==1 and not answer.get('plan'):bad.append(prefix+'invalid plan')
            own={u['id']:u for u in state['my_units']};foes={e['id']:e for e in state['enemy_units']}
            for uid,o in answer['orders'].items():
                if uid not in own:bad.append(prefix+'non-own unit order');continue
                if order_text(o)==own[uid]['order']:bad.append(prefix+'unchanged order repeated: '+uid)
                direct_teacher = result['policy'] in ('astra_direct_teacher', 'native_direct_teacher')
                if o['do']=='ATTACK' and (o['target'] not in foes or not direct_teacher and foes.get(o['target'],{}).get('class')=='HQ'):bad.append(prefix+'invalid/HQ attack target')
                if not direct_teacher and own[uid]['class']=='HQ' and o['do'] not in ['FORTIFY','HOLD']:bad.append(prefix+'HQ sortie')
            # Recompute exact game actions: every attack needs a standing attack-capable order.
        by_turn={r['turn']:r for r in rs};standing={};attacks=0
        action_rows=res.get('record',{}).get('actions',{}).get(result['pov'].lower(),[])
        for turn in range(1,len(rs)+1):
            standing.update(json.loads(by_turn[turn]['raw'])['orders'])
            for action in action_rows:
                if action.get('turn')!=turn or action.get('do')!='ATTACK':continue
                attacks+=1;uid=action.get('unit',action.get('id'))
                if standing.get(uid,{}).get('do') not in ['ATTACK','RAID','ASSAULT']:bad.append(f'turn {turn}: attack without attack order {uid}')
                elif standing[uid].get('target')!=action.get('target'):bad.append(f'turn {turn}: attack target differs from standing order {uid}')
        audits.append(result|facts|{'verified_win':won,'audit_pass':not bad,'errors':bad,'calls':len(rs),'attacks_checked':attacks,
            'opening_sha256':opening,'game_sha256':sha((d/'games'/f'{game}.json').read_bytes())})
    return audits

def timing_parity():
    slow=OUT/'pilot';fast=OUT/'timing_check'
    s=lines(slow/'results.jsonl');f=lines(fast/'results.jsonl')
    if not s or not f:raise SystemExit('Both pacing games must finish first')
    ss=json.loads((slow/'games'/f"{s[0]['game']}.json").read_text())
    ff=json.loads((fast/'games'/f"{f[0]['game']}.json").read_text())
    checks={k:ss[k]==ff[k] for k in ['outcome','turn','units','hq','win_rule','record']}
    checks['no_policy_transport_errors']=not lines(slow/'raw/errors.jsonl') and not lines(fast/'raw/errors.jsonl')
    sc=lines(slow/'raw/calls.jsonl');fc=lines(fast/'raw/calls.jsonl')
    checks['resident_messages_and_replies']=len(sc)==len(fc) and all(a['messages']==b['messages'] and a['raw']==b['raw'] for a,b in zip(sc,fc))
    result={'pass':all(checks.values()),'checks':checks,'slow_wall_s':s[0]['wall_s'],'fast_wall_s':f[0]['wall_s'],'speed':20,'seed':s[0]['seed']}
    if result['pass']:(OUT/'timing_parity.json').write_text(json.dumps(result,indent=2),encoding='utf-8')
    else:(OUT/'timing_parity_failed.json').write_text(json.dumps(result,indent=2),encoding='utf-8')
    print(json.dumps(result))

def main():
    import argparse
    ap=argparse.ArgumentParser();ap.add_argument('--stage',default='pilot');ap.add_argument('--timing',action='store_true');a=ap.parse_args()
    if a.timing:timing_parity();return
    audits=audit(a.stage)
    (OUT/a.stage/'validation.json').write_text(json.dumps(audits,ensure_ascii=False,indent=2),encoding='utf-8')
    print(json.dumps({'games':len(audits),'passed':sum(x['audit_pass'] for x in audits),'verified_wins':sum(x['verified_win'] for x in audits),
                      'errors':[(x['game'],x['errors'][:3]) for x in audits if x['errors']]}))

if __name__=='__main__':main()
