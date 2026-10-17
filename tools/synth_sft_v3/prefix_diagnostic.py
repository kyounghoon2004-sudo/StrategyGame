"""Compare physical engine snapshots before candidate injection, read-only."""
import json
import sys
from tools.synth_sft_v3.crosscheck import SYN, jl

def main():
    bank=json.loads((SYN/'bank_all_v3.json').read_text(encoding='utf-8'))
    d=SYN/'xcheck'/sys.argv[1]
    for b in jl(d/'branches.jsonl'):
        if not b['id'].startswith('V__'): continue
        f=d/'games'/(b['id']+'.json')
        if not f.exists(): continue
        original=json.loads(open(bank[b['game']]['game_file'],encoding='utf-8').read())
        replay=json.loads(f.read_text(encoding='utf-8'))
        originals={(s['turn'],s.get('to_act')):sorted(s['units']) for s in original['record']['snapshots'] if 'to_act' in s}
        checked=0; first=None
        for snap in replay['record']['snapshots']:
            key=(snap['turn'],snap.get('to_act'))
            if snap['turn']>b['turn'] or (snap['turn']==b['turn'] and snap.get('to_act')!='red'): continue
            if 'to_act' not in snap: continue
            checked+=1
            if sorted(snap['units'])!=originals.get(key):
                first=key; break
        print(json.dumps({'branch':b['id'],'prefix_snapshots_checked':checked,'first_physical_difference':first}))
        return

if __name__=='__main__': main()
