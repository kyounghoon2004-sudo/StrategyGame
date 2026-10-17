"""Prepare and compare Gate B replay evidence, without starting a game."""
from __future__ import annotations
import argparse
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / 'artifacts/brain_pipeline_v1/synth_sft_v3'

def final(r):
    return {'turn': r.get('turn'), 'outcome': r.get('outcome'),
            'red': (r.get('units', {}).get('red') or {}).get('alive'),
            'blue': (r.get('units', {}).get('blue') or {}).get('alive')}

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('stage', choices=['prepare', 'compare'])
    ap.add_argument('--runtime', default='frozen')
    a = ap.parse_args()
    bank = json.loads((OUT/'bank_grind.json').read_text(encoding='utf-8'))
    d = OUT/'replay_gate'/a.runtime
    d.mkdir(parents=True, exist_ok=True)
    if a.stage == 'prepare':
        # Fast representative complete victory per tier; identical selection for both runtimes.
        selected = [min((g for g in bank.values() if g['tier']==tier), key=lambda g: (g['turn'], g['game']))
                    for tier in ['BASIC', 'INTER', 'ADV']]
        branches = [{'id':'R__'+g['game'], 'game':g['game'], 'turn':0, 'horizon':60} for g in selected]
        (d/'branches.jsonl').write_text(''.join(json.dumps(x)+'\n' for x in branches), encoding='utf-8')
        print(json.dumps([{'game':g['game'], 'tier':g['tier'], 'expected_turn':g['turn']} for g in selected]))
        return
    rows = []
    source_rows = {}
    for run in ('seed_grind_v1', 'seed_grind_v2_inter_adv'):
        for r in json.loads((OUT.parent/run/'harvest/sft_rows_wins.json').read_text(encoding='utf-8')):
            source_rows[(r['game'],r['turn'])] = r
    for line in (d/'branches.jsonl').read_text(encoding='utf-8').splitlines():
        b = json.loads(line); g = bank[b['game']]
        source = Path(g['game_file'])
        original = json.loads(source.read_text(encoding='utf-8'))
        f = d/'games'/(b['id']+'.json')
        actual = json.loads(f.read_text(encoding='utf-8')) if f.exists() else {}
        expected, replay = final(original), final(actual)
        prompt_results = []
        wire_results = []
        calls_file = d/'raw/calls.jsonl'
        calls = [json.loads(x) for x in calls_file.read_text(encoding='utf-8').splitlines()] if calls_file.exists() else []
        for key, r in source_rows.items():
            if key[0] != g['game']:
                continue
            req = d/'requests'/(b['id']+'__t'+str(key[1])+'.json')
            prompt_results.append({'turn':key[1], 'equal':req.exists() and json.loads(req.read_text(encoding='utf-8'))==r['messages']})
            c = next((c for c in calls if c.get('tag')==b['id'] and c.get('turn')==key[1] and c.get('request')=='VICTORY_COMMAND'), None)
            wire_results.append({'turn':key[1], 'equal':c is not None and c.get('raw')==g.get('engine_answers',{}).get(str(key[1]))})
        rows.append({'game':g['game'],'tier':g['tier'],'runtime':a.runtime,'original_file':str(source),
                     'replay_file':str(f), 'expected':expected,'actual':replay,
                     'technical_error':actual.get('error') or (None if f.exists() else 'missing record'),
                     'exact':expected==replay and not actual.get('error'),
                     'prompt_count':len(prompt_results),'prompts_exact':all(x['equal'] for x in prompt_results),
                     'prompt_mismatch_turns':[x['turn'] for x in prompt_results if not x['equal']],
                     'wire_exact':all(x['equal'] for x in wire_results),
                     'wire_mismatch_turns':[x['turn'] for x in wire_results if not x['equal']]})
    (d/'comparison.json').write_text(json.dumps(rows,indent=2), encoding='utf-8')
    print(json.dumps(rows,indent=2))

if __name__ == '__main__':
    main()
