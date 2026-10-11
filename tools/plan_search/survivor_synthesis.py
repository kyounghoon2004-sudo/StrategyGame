"""Stage A/B only: historical evidence -> explicitly free offline model -> executable population."""
import argparse, collections, hashlib, json, subprocess, sys, os
from pathlib import Path
from tools.plan_search.survivor_policy import DEFAULT, BOUNDS, ENUMS, CLASSES, normalize
from tools.plan_search.cloud_brain import _run

def sha(b): return hashlib.sha256(b).hexdigest()
def dump(p,obj): p.write_text(json.dumps(obj,ensure_ascii=False,indent=2),encoding='utf8')
def main():
    ap=argparse.ArgumentParser();ap.add_argument('--out',required=True)
    ap.add_argument('--model',choices=['opencode/nemotron-3-ultra-free','opencode/space-bunny-free'],default='opencode/nemotron-3-ultra-free')
    a=ap.parse_args()
    out=Path(a.out);out.mkdir(parents=True,exist_ok=True)
    base=Path('artifacts/brain_pipeline_v1');data=(base/'plan_corpus/plans.jsonl').read_bytes()
    (out/'history_snapshot.jsonl').write_bytes(data)
    rows=[json.loads(x) for x in data.decode('utf8').splitlines()]
    known=[r for r in rows if r['tier'] in ['BASIC','INTER'] and r['outcome'] in ['WIN','LOSS','NOT_ACHIEVED']]
    grouped=collections.defaultdict(list)
    for r in known: grouped[(r['tier'],r['outcome'])].append(r)
    samples=[]
    for key,rr in sorted(grouped.items()):
        unique=list({r['plan']:r for r in rr if r['plan']}.values())
        samples += unique[::max(1,len(unique)//8)][:8]
    # The source calls and outcomes are also read; frozen selected raw calls keep exact requests.
    selected={(r['run'],r['game'],r['turn']) for r in samples};raw=[];sources=[];results=[]
    for f in sorted(base.glob('cmd_collect_*/raw/calls.jsonl')):
        b=f.read_bytes();run=f.parent.parent.name; sources.append({'path':str(f),'sha256':sha(b),'bytes':len(b)})
        for line in b.decode('utf8').splitlines():
            try: c=json.loads(line)
            except ValueError: continue
            if (run,c.get('tag'),int(c.get('turn') or 0)) in selected: raw.append({'run':run,**c})
        rp=f.parent.parent/'results.jsonl'
        if rp.exists():
            rb=rp.read_bytes();sources.append({'path':str(rp),'sha256':sha(rb),'bytes':len(rb)})
            for l in rb.decode('utf8').splitlines():
                try: results.append({'run':run,**json.loads(l)})
                except ValueError: pass
    dump(out/'historical_raw_examples.json',raw);dump(out/'historical_results_snapshot.json',results)
    dump(out/'historical_sources.json',sources)
    counts={str(k):len(v) for k,v in grouped.items()}
    prompt='''Offline strategy synthesis only. Do not use tools or access files, credentials, databases, or APIs.
Analyze BOTH historical successful and failed complete games from the attached evidence below.
Generate a behaviorally diverse population of executable RED commander policies, not SFT answers.
Return ONLY one JSON object: {"patterns":{"winning":[],"losing":[],"building_blocks":[],"tier_differences":[]},
"recipes":[{"name":"...","hypothesis":"...","history_refs":["run/game/turn"],"base":{...},"variants":[{...},...]}]}.
Generate EXACTLY 32 meaningfully different recipe families with EXACTLY 8 parameter override variants each.
The base is a complete policy configuration; each variant overrides any subset of it. Include {} as one variant.
All 256 merged configurations must be unique. Vary strategic logic, not just commit_turn or wording.
Include aggression, concentration, defense-first, regroup, early/late HQ pressure, casualty preservation,
RAID hit-and-run, flank openings, reserves, target class selection, and abandonment timing.
There is no hidden state or LLM in execution. Use packet-visible facts only. No hardcoded unit IDs or coordinates.
Every configuration is tested in BOTH BASIC and INTER; the game result controls survival, never your predicted quality.
Explain failure patterns honestly; outcome-linked historical rows below are examples, not causal proof.
Policy execution order: fortify HQ if available; allocate one responder per HQ threat within threat_eta;
preserve wounded units as configured; reserve nearest units before abandon_turn; allocate HQ strike share at
commit_turn or cleanup_count; exploit reachable HQ; everyone else takes best preview-scored field enemy.
Score = (matchup*(dealt + fieldwork_weight*fieldwork_damage)-casualty_weight*taken)/(1+approach_weight*eta)
+ class priority (3 per rank). max_focus discourages overcrowding. Under attack_floor units fortify/hold.
opening defend/regroup/flank applies only through opening_turns to non-strike units. flank is -1/0/1 and is
a relative waypoint derived from visible positions. hq_classes prioritizes classes but others can join.
wounded_soldiers is an absolute visible soldier threshold (0 disables). At abandon_turn reserves and holds
are released and remaining healthy free units attack the HQ. regroup_eta causes distant units to return home.
RAID is only offered cavalry; absent FORTIFY falls back to HOLD. Missing previews never invent enemy facts.
Use only the following parameter keys and allowed values. Integer default means integer parameter.
'''+json.dumps({'defaults':DEFAULT,'bounds':BOUNDS,'enums':ENUMS,'classes':CLASSES},indent=2)
    prompt+='\nHISTORY COUNTS:\n'+json.dumps(counts)+'\nHISTORICAL EVIDENCE (one row per decision):\n'
    prompt+='\n'.join(json.dumps({k:(r[k][:600] if k=='plan' else r[k]) for k in ['run','game','turn','tier','outcome','end_turn','red_alive','plan','orders']},ensure_ascii=False) for r in samples)
    (out/'offline_prompt.md').write_text(prompt,encoding='utf8')
    model=a.model
    exe=Path(os.environ['APPDATA'])/'npm/node_modules/opencode-ai/bin/opencode.exe'
    pf=(out/'offline_prompt.md').resolve();wd=(out/'offline_model').resolve();wd.mkdir(exist_ok=True)
    proc=subprocess.Popen([str(exe),'run','Follow the attached offline_prompt.md exactly. No tools. Return the requested JSON.',
        '--pure','-m',model,'--format','json','--dir',str(wd),'-f',str(pf)],
        stdin=subprocess.DEVNULL,stdout=open(out/'offline_events_v2.jsonl','w',encoding='utf8'),
        stderr=open(out/'offline_stderr_v2.log','w',encoding='utf8'),env=dict(os.environ,OPENCODE_EXPERIMENTAL_OUTPUT_TOKEN_MAX='24000'))
    try:proc.wait(timeout=900)
    except subprocess.TimeoutExpired:proc.kill();raise RuntimeError('free model timeout; no paid fallback')
    events=[json.loads(l) for l in (out/'offline_events_v2.jsonl').read_text(encoding='utf8').splitlines() if l.startswith('{')]
    text=''.join(e.get('part',{}).get('text','') for e in events if e.get('type')=='text');usage={};sid=''
    for e in events:
        sid=e.get('sessionID',sid)
        if e.get('type')=='step_finish':
            if e.get('part',{}).get('cost',0)!=0:raise RuntimeError('nonzero model charge; stop')
            usage=e.get('part',{}).get('tokens',{})
    (out/'offline_response.txt').write_text(text,encoding='utf8')
    dump(out/'offline_model_provenance.json',{'model':model,'usage':usage,'session':sid,'prompt_sha256':sha(prompt.encode()),'response_sha256':sha(text.encode()),'free_pricing_source':'https://opencode.ai/docs/en/zen/','gameplay_calls':0})
    dec=json.JSONDecoder();doc=None
    for i,ch in enumerate(text):
        if ch!='{': continue
        try: v,_=dec.raw_decode(text[i:])
        except ValueError: continue
        if isinstance(v,dict) and isinstance(v.get('recipes'),list):doc=v;break
    if doc is None: raise RuntimeError('Free model did not return recipes; no paid fallback')
    dump(out/'llm_recipes.json',doc);dump(out/'patterns.json',doc['patterns'])
    pop=[];seen=set()
    for ri,r in enumerate(doc['recipes']):
        for vi,v in enumerate(r['variants']):
            p=normalize(r['base']|v);h=sha(json.dumps(p,sort_keys=True).encode())
            if h in seen: continue
            seen.add(h);pop.append({'id':'P%03d'%len(pop),'family':r['name'],'hypothesis':r['hypothesis'],'history_refs':r.get('history_refs',[]),'recipe':ri,'variant':vi,'params':p,'policy_sha256':h,'synthesis_model':model})
    if len(pop)<200: raise RuntimeError(f'Only {len(pop)} distinct configs; do not call this mass production')
    dump(out/'population.json',pop);print('generated',len(pop),flush=True)
if __name__=='__main__':main()
