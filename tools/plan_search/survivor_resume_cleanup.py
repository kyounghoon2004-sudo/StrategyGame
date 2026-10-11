"""Preserve completed outcomes and quarantine incomplete captures after owned-worker stops."""
import argparse, json
from pathlib import Path

def main():
    ap=argparse.ArgumentParser()
    ap.add_argument('--out',required=True)
    ap.add_argument('--incident',required=True)
    a=ap.parse_args();out=Path(a.out);dest=out/a.incident
    dest.mkdir(exist_ok=False)
    results=[json.loads(x) for x in (out/'results.jsonl').read_text(encoding='utf8').splitlines() if x.strip()]
    completed=[r for r in results if r['kind']!='ERROR'];done={r['game'] for r in completed}
    (dest/'error_results.json').write_text(json.dumps([r for r in results if r['kind']=='ERROR'],indent=2),encoding='utf8')
    (out/'results.jsonl').write_text(''.join(json.dumps(r,ensure_ascii=False)+'\n' for r in completed),encoding='utf8')
    incomplete=set();removed=0
    for raw in out.glob('slot_*/raw/calls.jsonl'):
        keep=[];reject=[]
        for line in raw.read_text(encoding='utf8').splitlines():
            if not line.strip():continue
            c=json.loads(line)
            if c.get('tag') in done:keep.append(line)
            else:reject.append(line);incomplete.add(c.get('tag'))
        if reject:
            (dest/(raw.parent.parent.name+'_incomplete_calls.jsonl')).write_text('\n'.join(reject)+'\n',encoding='utf8')
            removed+=len(reject)
        raw.write_text('\n'.join(keep)+'\n',encoding='utf8')
    for name in ['summary.json','audit.json','ranking.json','robust_survivors.json','weak_survivors.json','sft_robust.json','sft_weak.json','sft_lineage.json','five_samples.json','duplicate_trajectories.json','technical_errors.json']:
        p=out/name
        if p.exists():p.rename(dest/name)
    record={'preserved_completed_games':len(completed),'incomplete_games':sorted(x for x in incomplete if x),
            'quarantined_calls':removed,'reason':'User reported memory pressure; stopped only owned search tree to lower concurrency from 24 to 12.'}
    (dest/'incident.json').write_text(json.dumps(record,indent=2),encoding='utf8')
    print(json.dumps(record))

if __name__=='__main__':main()
