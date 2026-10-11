"""Extract exact played rows from parent-audited stages; no game or model execution.

python -m tools.sft_synth_v1.astra_v1.extract --pilot PATH --replication PATH --expansion PATH
Paths contain validation.json (list of per-game audits), raw/calls.jsonl and games/.
Pass each stage once. Missing stages yield no admission. Runtime hashes separate versions.
"""
from __future__ import annotations
import argparse
import hashlib
import json
import itertools
from pathlib import Path
from collections import defaultdict, Counter

ROOT=Path(__file__).resolve().parents[3]
OUT=ROOT/'artifacts/brain_pipeline_v1/sft_synth_v1/astra_v1'
HELDOUT=set(range(8831101,8831107))
MISSION={'enemy_non_hq_destroy_share':.7,'rounding':'ceil','own_hq_loss':'defeat',
         'enemy_hq_loss':'nonterminal','symmetric_collapse':True,'turn_cap':60}
BUCKETS=((3,6),(7,11),(12,16),(17,25),(26,35))

def sha(x):
    return hashlib.sha256(x if isinstance(x,bytes) else x.encode('utf-8')).hexdigest()

def read(path):
    return json.loads(path.read_text(encoding='utf-8-sig'))

def lines(path):
    return [json.loads(x) for x in path.read_text(encoding='utf-8-sig').splitlines() if x.strip()] if path.exists() else []

def cell(g):
    return (g['size'],g['tier'],g['style'],g['family'],g['pov'])

def bucketcell(g):
    return (next(f'{a}-{b}' for a,b in BUCKETS if a<=g['size']<=b),g['tier'],g['style'],g['family'],g['pov'])

def teacher_facts():
    baseline=read(OUT/'teacher_source_inventory.json')
    closurepath=OUT/'teacher_closure_inventory.json'
    inventory=read(closurepath) if closurepath.exists() else baseline
    models=Counter();model_rows=Counter();seen=set();hinted=0
    for i,source in enumerate(inventory['sources']):
        p=Path(source['snapshot']) if 'snapshot' in source else OUT/'source_snapshots'/f'{i}_sft_rows.json'
        if sha(p.read_bytes())!=source['sha256']:raise ValueError('teacher snapshot changed: '+str(p))
        for row in read(p):
            model=row.get('teacher_model','unspecified');model_rows[model]+=1
            if row['game'] not in seen:
                seen.add(row['game']);models[model]+=1
                hinted+=int('Focus fire:' in row['messages'][0]['content'])
    return {'baseline_games':baseline['games'],'baseline_rows':baseline['rows'],
            'closure_games':inventory['games'],'closure_rows':inventory['rows'],
            'closure_inventory':'teacher_closure_inventory.json' if closurepath.exists() else None,
            'games_with_tactical_hint':hinted,'models_games':dict(models),'models_rows':dict(model_rows),
            'excluded_unfinished':inventory.get('excluded_unfinished',[])}

def main():
    ap=argparse.ArgumentParser()
    for role in ('pilot','replication','expansion'):ap.add_argument('--'+role,action='append',default=[])
    args=ap.parse_args();games=[];seen=set();allrows=[];errors=[];teachers=teacher_facts()
    for role in ('pilot','replication','expansion'):
        for rawpath in getattr(args,role):
            path=Path(rawpath).resolve()
            seal={}
            sealpath=path/'sealed_audit_manifest.json'
            if sealpath.exists():
                seal=read(sealpath)
                for key,filename in [('calls_sha256','raw/calls.jsonl'),('validation_sha256','validation.json')]:
                    if not seal.get(key) or sha((path/filename).read_bytes())!=seal[key]:raise ValueError('sealed audit mismatch: '+str(path)+' '+key)
            audits=read(path/'validation.json')
            if not isinstance(audits,list):raise ValueError('validation.json must contain per-game audit list')
            calls=defaultdict(list)
            for r in lines(path/'raw/calls.jsonl'):calls[r['game']].append(r)
            for original in audits:
                g=dict(original);gid=g['game']
                if gid in seen:raise ValueError('duplicate game: '+gid)
                seen.add(gid);rs=sorted(calls[gid],key=lambda r:r['turn'])
                hashes={r.get('source_sha256') for r in rs}
                g.update(role=role,path=str(path),audit_calls=g.get('calls'),calls=rs,source_hash=next(iter(hashes)) if len(hashes)==1 else None)
                g['eligible']=bool(g.get('audit_pass') and g.get('verified_win') and rs and g['source_hash'] and g['seed'] not in HELDOUT)
                bad=[]
                if seal.get('runtime_manifest_sha256') and g.get('runtime_manifest_sha256')!=seal['runtime_manifest_sha256']:
                    bad.append('runtime manifest differs from seal')
                if [r['turn'] for r in rs]!=list(range(1,len(rs)+1)):bad.append('nonsequential calls')
                if len(rs)!=g.get('audit_calls'):bad.append('audit call count differs')
                for r in rs:
                    parsed=json.loads(r['raw'])
                    if r['raw']!=json.dumps(parsed,ensure_ascii=False,separators=(',',':')):bad.append('noncompact played JSON')
                    opening=sha(json.dumps(r['messages'][:2],sort_keys=True,ensure_ascii=False))
                    if opening!=g.get('opening_sha256'):bad.append('resident opening differs from audit')
                    if r.get('source_sha256')!=g['source_hash']:bad.append('call source hash differs')
                    if 'Focus fire:' in r['messages'][0]['content']:bad.append('tactical prompt hint')
                if bad:g['eligible']=False;errors.extend(gid+': '+e for e in sorted(set(bad)))
                if len({r['turn'] for r in rs})!=len(rs):g['eligible']=False;errors.append(gid+': duplicate turn')
                if g['seed'] in HELDOUT:raise ValueError('forbidden heldout seed')
                native=path/'games'/f'{gid}.json'
                if not native.exists() or sha(native.read_bytes())!=g.get('game_sha256'):
                    g['eligible']=False;errors.append(gid+': missing or changed native game')
                games.append(g)
    grouped=defaultdict(list)
    for g in games:grouped[(cell(g),g['policy'],g['source_hash'])].append(g)
    gates=[];passed=set()
    for key,gs in grouped.items():
        ps=sorted((g for g in gs if g['role']=='pilot'),key=lambda g:(g['seed'],g['game']))
        rs=sorted((g for g in gs if g['role']=='replication'),key=lambda g:(g['seed'],g['game']))
        # Never select the best five or replace failed seeds with successful repeats.
        unique_p=len({g['seed'] for g in ps})==len(ps)
        unique_r=len({g['seed'] for g in rs})==len(rs)
        independent=not ({g['seed'] for g in ps}&{g['seed'] for g in rs})
        pw=sum(g['eligible'] for g in ps[:5]);rw=sum(g['eligible'] for g in rs[:5])
        ok=len(ps)>=5 and len(rs)>=5 and unique_p and unique_r and independent and pw>=4 and rw>=4
        gates.append({'cell':key[0],'policy':key[1],'source_sha256':key[2],
                      'pilot_seeds':[g['seed'] for g in ps[:5]],'pilot_wins':pw,
                      'replication_seeds':[g['seed'] for g in rs[:5]],'replication_wins':rw,
                      'independent':independent,'pass':ok})
        if ok:passed.add(key)
    candidates=defaultdict(list)
    for g in games:
        if g['eligible'] and (cell(g),g['policy'],g['source_hash']) in passed:candidates[cell(g)].append(g)
    admitted=set();coverage=[]
    for c in sorted({cell(g) for g in games}):
        eligible=candidates[c]; seeds={g['seed'] for g in eligible}
        complete=len(eligible)>=10 and len(seeds)>=5
        chosen=[]
        if complete:
            # Deterministic seed-first selection, not score/turn/loss based cherry-picking.
            ordered=sorted(eligible,key=lambda g:(g['seed'],g['game']))
            used=set()
            for g in ordered:
                if g['seed'] not in used and len(chosen)<10:chosen.append(g);used.add(g['seed'])
            for g in ordered:
                if len(chosen)<10 and g not in chosen:chosen.append(g)
            admitted.update(g['game'] for g in chosen)
        coverage.append({'cell':c,'gated_wins':len(eligible),'winning_seeds':len(seeds),'complete':complete})
    # Dataset caps apply to the published bucket cell as well as actual-size gates.
    bucket_admitted=defaultdict(list)
    for g in games:
        if g['game'] in admitted:bucket_admitted[bucketcell(g)].append(g)
    admitted=set()
    for gs in bucket_admitted.values():
        ordered=sorted(gs,key=lambda g:(g['seed'],g['game']));chosen=[];used=set()
        for g in ordered:
            if g['seed'] not in used and len(chosen)<10:chosen.append(g);used.add(g['seed'])
        for g in ordered:
            if len(chosen)<10 and g not in chosen:chosen.append(g)
        admitted.update(g['game'] for g in chosen)
    lost=[];rejected=[];bycell=defaultdict(lambda:defaultdict(list));lineage=[]
    for g in games:
        for r in g['calls']:
            # Validate compact played JSON but never repair or paraphrase it.
            completion=r['raw'];json.loads(completion)
            row={'messages':r['messages'],'completion':completion,'game':g['game'],'turn':r['turn'],
                 'seed':g['seed'],'tier':g['tier'],'gx_style':g['style'],'rule_family':g['family'],
                 'pov':g['pov'],'units_per_side':{'red':g['size'],'blue':g['size']},
                 'win_condition':MISSION,'outcome':'WIN' if g.get('verified_win') else g.get('kind','NONWIN'),
                 'teacher_model':'astra-authored-visible-code/'+g['policy'],'teacher_reasoning':'deterministic',
                 'generation_author':'gpt-6-astra','generation_reasoning':'medium','generation_mode':'code_policy_played_in_godot',
                 'generation_version':{'astra_coordinated_finish':'astra_v2','astra_sector_groups':'astra_v3'}.get(g['policy'],'astra_v1'),
                 'pattern_evidence_inventory':'teacher_closure_inventory.json' if g['policy']=='astra_sector_groups' else 'teacher_source_inventory.json',
                 'pattern':g['policy'],'generator_sha256':g['source_hash'],
                 'system_prompt_sha256':sha(r['messages'][0]['content'])}
            if g['game'] in admitted:bycell[bucketcell(g)][g['game']].append((row,g))
            elif not g.get('verified_win'):lost.append(row)
            else:rejected.append(row)
    training=[]
    for c,pergame in bycell.items():
        ranked=[sorted(rs,key=lambda rg:(0 if rg[0]['turn']==1 else 1 if 'plan' in json.loads(rg[0]['completion']) else 2 if json.loads(rg[0]['completion']).get('orders') else 3,rg[0]['turn'])) for _,rs in sorted(pergame.items())]
        selected=[]
        for i in range(max(map(len,ranked),default=0)):
            for rs in ranked:
                if i<len(rs) and len(selected)<300:selected.append(rs[i])
        for row,g in selected:
            training.append(row)
            lineage.append({'game':row['game'],'turn':row['turn'],'source':g['path']+'/raw/calls.jsonl',
                            'game_source':g['path']+'/games/'+g['game']+'.json',
                            'messages_sha256':sha(json.dumps(row['messages'],ensure_ascii=False,separators=(',',':'))),
                            'completion_sha256':sha(row['completion']),'game_sha256':g['game_sha256'],
                            'policy_sha256':g['source_hash'],'policy':g['policy'],'generation_version':row['generation_version'],
                            'transform':'none: exact messages and played completion'})
    training.sort(key=lambda r:(r['game'],r['turn']))
    coverage480=[]
    for c in itertools.product([f'{a}-{b}' for a,b in BUCKETS],['BASIC','INTER','ADV'],['SPEARHEAD','BULWARK','OUTRIDER','HARRIER'],['fixed','mild','broad','counterfactual_valid'],['RED','BLUE']):
        gs=[g for g in games if bucketcell(g)==c]; kept=[g for g in gs if g['game'] in admitted]
        coverage480.append({'cell':c,'played':len(gs),'won':sum(bool(g.get('verified_win')) for g in gs),
                            'admitted_games':len(kept),'winning_seeds':len({g['seed'] for g in kept}),
                            'actual_sizes_played':sorted({g['size'] for g in gs}),
                            'rows':sum(r['game'] in {g['game'] for g in kept} for r in training),
                            'status':'UNMEASURED' if not gs else 'ADMITTED_REPRESENTATIVE_SIZE' if kept else 'INSUFFICIENT'})
    summary={'games':len(games),'verified_wins':sum(bool(g.get('verified_win')) for g in games),
             'audited_wins':sum(g['eligible'] for g in games),'admitted_games':len({r['game'] for r in training}),
             'training_rows':len(training),'nonwinning_rows':len(lost),'rejected_winner_rows':len(rejected),
             'complete_measured_cells':sum(c['complete'] for c in coverage),'heldout_used':False,'errors':errors,
             'generation_author':'GPT-6 Astra','author_reasoning':'medium','direct_teacher_games':0,
             'teacher_source_facts':teachers,
             'direct_teacher_mixture_status':f"MISSING: {teachers['games_with_tactical_hint']}/{teachers['closure_games']} closure source teachers contain Focus fire hint; pattern evidence only",
             'status':'BOUNDED_PARTIAL_COVERAGE' if training else 'ZERO_ADMITTED_PENDING_GATES'}
    OUT.mkdir(parents=True,exist_ok=True)
    for name,data in [('sft_rows.json',training),('sft_lost_rows.json',lost),('sft_rejected_winner_rows.json',rejected),
                      ('sft_transform_lineage.json',lineage),('generator_gates.json',gates),('actual_size_coverage.json',coverage),('coverage_counts.json',coverage480),('extraction_summary.json',summary)]:
        (OUT/name).write_text(json.dumps(data,ensure_ascii=False,indent=2),encoding='utf-8')
    text=['# Astra synthetic pilot','',f"Played {summary['games']} games; verified wins {summary['verified_wins']}; admitted {summary['admitted_games']} games / {len(training)} rows.",'',
          'Admission requires the same generator source hash and exact size/tier/style/family/POV: at least 4 wins in the first five pilot seeds AND at least 4 in five independent replication seeds, all replay-audited. A cell then needs at least ten gated wins across five winning seeds before any rows enter SFT. Each cell is capped at 300 rows.',
          '', 'This is a bounded pilot. Unmeasured tiers, sizes, styles, families and BLUE POV remain unverified. Original teacher rows are pattern evidence only; they are not rewritten or copied into this facts-only dataset. No training or model deployment is performed.',
          '', 'Generation author: GPT-6 Astra, medium reasoning. Games use CPU Hands; no GPU/model inference or training is required by these code policies. Wins are independently verified against native initial/final field-unit snapshots, HQ survival, 70% ceil threshold, symmetric collapse and 60-decision cap, with policy replay and standing-order checks in parent audits.',
          '', 'Version provenance: screened-pressure and sustained-groups are frozen astra_v1 profiles; coordinated-finish is astra_v2; sector-groups is a separate large-army astra_v3 hypothesis. Later versions import frozen earlier helpers but retain independent profile/source hashes in every pilot and replication gate. Row and lineage generation_version fields identify the authored package; no game from one version counts toward another version qualification.',
          '', f"Teacher baseline remains frozen at {teachers['baseline_games']} wins/{teachers['baseline_rows']} rows. Separate closure inventory contains {teachers['closure_games']} wins/{teachers['closure_rows']} rows, of which {teachers['games_with_tactical_hint']} games have the Focus fire hint. Snapshots are SHA-checked during extraction. Interrupted IDs {teachers['excluded_unfinished']} are excluded.",
          '', 'Direct teacher mixture is MISSING. Both baseline and closure teachers remain pattern evidence only; copying hinted inputs unchanged or rewriting their prompts would violate this package. The requested 10–20% direct-teacher mixture has not been met.',
          '', '## Source models (closure evidence, not admitted direct teachers)', '', '|Recorded teacher model|Winning games|Rows|','|---|---:|---:|']
    for model,n in sorted(teachers['models_games'].items()):text.append(f"|{model}|{n}|{teachers['models_rows'][model]}|")
    text += [
          '', '## Gates','', '|Cell|Policy|Pilot|Replication|Pass|','|---|---|---:|---:|---|']
    for g in gates:text.append(f"|{g['cell']}|{g['policy']}|{g['pilot_wins']}/{len(g['pilot_seeds'])}|{g['replication_wins']}/{len(g['replication_seeds'])}|{g['pass']}|")
    text+=['','## All 480 coverage cells','','Actual sizes are recorded separately; one admitted representative size does not prove its entire bucket.','','|Bucket / tier / style / family / POV|Actual sizes|Played|Won|Rows|Status|','|---|---|---:|---:|---:|---|']
    for c in coverage480:text.append(f"|{' / '.join(c['cell'])}|{c['actual_sizes_played']}|{c['played']}|{c['won']}|{c['rows']}|{c['status']}|")
    text+=['','## Observed nonwins','','|Game|Policy|Native outcome|Audit errors|','|---|---|---|---|']
    for g in games:
        if not g.get('verified_win'):text.append(f"|{g['game']}|{g['policy']}|{g.get('outcome',g.get('kind','unknown'))}|{g.get('errors',[])}|")
    text+=['', 'Nonwinning rows and rejected winners remain separate. No failed behavior is made successful by editing prose. Source patterns and counterexamples are documented in PATTERNS_ASTRA.md. Observed tactical failure analysis is in FAILURES.md; the first sustained-groups CAP split its depleted attackers between two renewing fortifications after six kills, so zero own unit deaths did not imply enough finishing power.', '', 'Next gate: complete the first unmet pilot, independent replication, or ten-win collection requirement for one exact cell; do not expand a failed generator.']
    (OUT/'REPORT.md').write_text('\n'.join(text)+'\n',encoding='utf-8')
    print(json.dumps(summary))

if __name__=='__main__':main()
