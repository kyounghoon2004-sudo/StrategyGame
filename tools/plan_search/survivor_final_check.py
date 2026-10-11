"""Verify full population coverage and survivor SFT against real captured actions."""
import argparse, collections, hashlib, json
from pathlib import Path
from tools.plan_search.survivor_policy import decide

def load(p):return json.loads(p.read_text(encoding='utf8'))
def main():
    ap=argparse.ArgumentParser();ap.add_argument('--out',required=True);a=ap.parse_args();p=Path(a.out)
    pop={x['id']:x for x in load(p/'population.json')}
    assert not (p/'LIVE_INTEGRITY_FAILURE.json').exists()
    policy_hash=hashlib.sha256(Path(__file__).with_name('survivor_policy.py').read_bytes()).hexdigest()
    assert load(p/'search_config.json')['policy_source_sha256']==policy_hash,'policy source changed during search'
    assert all(x['policy_sha256']==hashlib.sha256(json.dumps(x['params'],sort_keys=True).encode()).hexdigest() for x in pop.values()),'policy parameters changed'
    results=[json.loads(x) for x in (p/'results.jsonl').read_text(encoding='utf8').splitlines() if x.strip()]
    games={r['game']:r for r in results};assert len(games)==len(results),'duplicate evaluation IDs'
    initial=[r for r in results if r['stage']=='initial']
    assert len(initial)==2*len(pop)
    assert {(r['strategy'],r['tier']) for r in initial}=={(s,t) for s in pop for t in ['BASIC','INTER']}
    assert not any(r['kind']=='ERROR' for r in results),'technical errors in outcome denominator'
    robust={(r['strategy'],r['tier']):r for r in load(p/'robust_survivors.json')}
    for key,r in robust.items():
        rr=[x for x in results if (x['strategy'],x['tier'])==key]
        assert len(rr)>=5 and all(x['kind']=='WIN' for x in rr)
        assert len({x['style'] for x in rr})==4 and len({x['family'] for x in rr})>=3
        assert len({(x['style'],x['family'],x['seed']) for x in rr})==len(rr)
    nominees=load(p/'repeat_nominees.json')
    for r in nominees:
        assert {x['repeat'] for x in results if x['stage']=='repeat' and x['strategy']==r['strategy'] and x['tier']==r['tier']}==set(range(4))
    rows=load(p/'sft_robust.json');lineage=load(p/'sft_lineage.json');assert len(rows)==len(lineage)
    captured=collections.defaultdict(list)
    for f in p.glob('slot_*/raw/calls.jsonl'):
        for line in f.read_text(encoding='utf8').splitlines():
            if not line.strip():continue
            c=json.loads(line)
            if c.get('request')=='VICTORY_COMMAND':
                assert c['mode']=='MANUAL' and not c.get('cloud') and not c.get('local'), 'nonmanual capture'
                captured[(c['tag'],c['turn'])].append(c)
    words=[]
    for i,(row,meta) in enumerate(zip(rows,lineage)):
        assert meta['row']==i and row['game']==meta['game'] and row['strategy']==meta['strategy']
        assert (row['strategy'],row['tier']) in robust and games[row['game']]['kind']=='WIN'
        rationale,suffix=row['completion'].split('</think>',1);raw=suffix.lstrip('\n')
        assert hashlib.sha256(raw.encode()).hexdigest()==meta['raw_sha256']
        assert hashlib.sha256(json.dumps(row['messages'],ensure_ascii=False).encode()).hexdigest()==meta['messages_sha256']
        assert any(c['messages']==row['messages'] and c['raw']==raw for c in captured[(row['game'],row['turn'])])
        actual=json.loads(raw);packet=json.loads(row['messages'][-1]['content'])
        assert row['turn']==packet['turn']
        expected,_=decide(packet,row['messages'][0]['content'],pop[row['strategy']]['params'])
        assert expected==actual
        assert all(o['do'] in ['ATTACK','MOVE','HOLD','RAID','FORTIFY'] for o in actual['orders'].values())
        words.append(len(rationale.split()))
    assert len(load(p/'five_samples.json'))==5
    assert all(x in rows for x in load(p/'five_samples.json'))
    audit=load(p/'audit.json');assert audit['order_mismatches']==audit['message_mismatches']==audit['llm_gameplay_calls']==0
    record={'status':'PASS','population':len(pop),'initial_games':len(initial),'repeat_games':len(results)-len(initial),
            'robust_plan_tiers':len(robust),'sft_rows':len(rows),'tiers':dict(collections.Counter(x['tier'] for x in rows)),
            'distinct_games':len({x['game'] for x in rows}),'distinct_strategies':len({x['strategy'] for x in rows}),
            'rationale_words_max':max(words,default=0),'exact_action_and_message_checks':len(rows)}
    (p/'final_validation.json').write_text(json.dumps(record,indent=2),encoding='utf8');print(json.dumps(record))

if __name__=='__main__':main()
