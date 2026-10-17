"""Prepare/check corrected polling, native deadline, and late roster replay gates."""
import argparse
import json
from pathlib import Path
from tools.synth_sft_v3.crosscheck import SYN,jl,facts,situations
from tools.synth_sft_v3.replay_gate import final

def main():
    ap=argparse.ArgumentParser();ap.add_argument('stage',choices=['prepare','compare']);a=ap.parse_args()
    bank=json.loads((SYN/'bank_all_v3.json').read_text(encoding='utf-8'))
    d=SYN/'replay_gate/corrected_native_poll';d.mkdir(parents=True,exist_ok=True)
    selected=[b['game'] for b in jl(SYN/'replay_gate/production/branches.jsonl')]
    late=[g['game'] for g in bank.values() if g.get('source')!='seed_grind']
    sid='s9500001_it01_r0__t29'; sit=situations({sid})[sid]
    control={'id':'C__'+sid,'game':sit['game'],'turn':29,'horizon':5,'answer':sit['teacher_answer']}
    if a.stage=='prepare':
        for name,games in [('grind',selected),('late',late)]:
            rows=[{'id':'R__'+g,'game':g,'turn':0,'horizon':60} for g in games]
            if name=='late': rows.insert(0,control)
            p=d/name;p.mkdir(exist_ok=True)
            (p/'branches.jsonl').write_text(''.join(json.dumps(r)+'\n' for r in rows),encoding='utf-8')
        print('grind',len(selected),'late',len(late),'and one own-H control');return
    source=situations(); rows=[]
    for name in ('grind','late'):
        p=d/name
        for b in jl(p/'branches.jsonl'):
            game=bank[b['game']]; path=p/'games'/(b['id']+'.json')
            if not path.exists():
                rows.append({'id':b['id'],'technical':'missing record'});continue
            replay=json.loads(path.read_text(encoding='utf-8'))
            original=json.loads(Path(game['game_file']).read_text(encoding='utf-8'))
            requests=[json.loads(f.read_text(encoding='utf-8')) for f in p.joinpath('requests').glob(b['id']+'__t*.json')]
            if b['turn']==0:
                comparisons=[]
                for key,s in source.items():
                    if s['game']!=b['game']: continue
                    f=p/'requests'/(b['id']+'__t'+str(s['turn'])+'.json')
                    comparisons.append(f.exists() and json.loads(f.read_text(encoding='utf-8'))==s['messages'])
                orig_snaps={(s['turn'],s.get('to_act')):sorted(s['units']) for s in original['record']['snapshots']}
                compared=[sorted(s['units'])==orig_snaps.get((s['turn'],s.get('to_act'))) for s in replay['record']['snapshots']]
                rows.append({'id':b['id'],'final_expected':final(original),'final_actual':final(replay),
                             'final_exact':final(original)==final(replay),'source_situations':len(comparisons),
                             'prompts_exact':all(comparisons),'snapshot_count':len(compared),'snapshots_exact':all(compared)})
            else:
                f=p/'requests'/(b['id']+'.json')
                msg=json.loads(f.read_text(encoding='utf-8')) if f.exists() else None
                old=next((SYN/'xcheck/v3_05_b000/attempt_evidence').glob('attempt_*/games/'+b['id']+'.json'),None)
                old_fx=facts(old,b['turn'],b['horizon']) if old else None
                new_fx=facts(path,b['turn'],b['horizon'])
                old_record=json.loads(old.read_text(encoding='utf-8')) if old else {}
                old_units=sorted(old_record.get('record',{}).get('snapshots',[{'units':[]}])[-1]['units'])
                endpoint=next((s for s in replay['record']['snapshots'] if s.get('turn')==35 and s.get('to_act')=='blue'),None)
                rows.append({'id':b['id'],'original_prompt_exact':msg==source[sid]['messages'],
                             'old_short_cap_facts':old_fx,'native_own_H_facts':new_fx,'facts_exact':old_fx==new_fx,
                             'endpoint_units_exact':endpoint is not None and sorted(endpoint['units'])==old_units})
    (d/'comparison.json').write_text(json.dumps(rows,indent=2),encoding='utf-8');print(json.dumps(rows,indent=2))

if __name__=='__main__':main()
