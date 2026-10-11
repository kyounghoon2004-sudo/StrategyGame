"""Read-only live replay checker; detects data integrity problems before the sweep ends."""
import argparse, collections, json, time
from pathlib import Path
from tools.plan_search.survivor_policy import decide

def main():
    ap=argparse.ArgumentParser();ap.add_argument('--out',required=True);ap.add_argument('--once',action='store_true');a=ap.parse_args();out=Path(a.out)
    pop={r['id']:r for r in json.loads((out/'population.json').read_text(encoding='utf8'))}
    calls=collections.defaultdict(list);offsets={};checked=set();decisions=0
    while True:
        for path in out.glob('slot_*/raw/calls.jsonl'):
            with open(path,'rb') as f:
                f.seek(offsets.get(str(path),0))
                while True:
                    pos=f.tell();line=f.readline()
                    if not line or not line.endswith(b'\n'):offsets[str(path)]=pos;break
                    c=json.loads(line)
                    if c.get('request')=='VICTORY_COMMAND':calls[c['tag']].append(c)
        res=[]
        if (out/'results.jsonl').exists():
            for line in (out/'results.jsonl').read_text(encoding='utf8').splitlines():
                try:res.append(json.loads(line))
                except ValueError:pass
        for r in res:
            if r['game'] in checked:continue
            for c in calls[r['game']]:
                expected,_=decide(json.loads(c['messages'][-1]['content']),c['messages'][0]['content'],pop[r['strategy']]['params'])
                if expected!=json.loads(c['raw']):
                    (out/'LIVE_INTEGRITY_FAILURE.json').write_text(json.dumps({'game':r['game'],'turn':c['turn'],'reason':'executed response differs from assigned frozen policy'},indent=2));raise RuntimeError('live replay mismatch '+r['game'])
                assert c['mode']=='MANUAL' and not c.get('cloud') and not c.get('local')
                decisions+=1
            checked.add(r['game'])
        (out/'live_audit.json').write_text(json.dumps({'completed_games_checked':len(checked),'decisions_checked':decisions,'mismatches':0,'llm_gameplay_calls':0},indent=2))
        if a.once or (out/'summary.json').exists():break
        time.sleep(10)
if __name__=='__main__':main()
