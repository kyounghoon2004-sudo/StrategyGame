"""Reproducible final report from sealed game results; no model or training."""
import argparse, collections, hashlib, json, shutil, statistics
from pathlib import Path
from tools.plan_search.survivor_rationale import summarize

def load(p):return json.loads(p.read_text(encoding='utf8'))
def main():
    ap=argparse.ArgumentParser();ap.add_argument('--out',required=True);a=ap.parse_args();p=Path(a.out).resolve()
    s=load(p/'summary.json');r=load(p/'ranking.json');pop=load(p/'population.json');rows=load(p/'sft_robust.json')
    lineage=load(p/'sft_lineage.json')
    for meta in lineage:
        row=rows[meta['row']];suffix=row['completion'].split('</think>',1)[1]
        row['completion']=summarize(json.loads(row['messages'][-1]['content']),meta['trace'])+'\n</think>'+suffix
    (p/'sft_robust.json').write_text(json.dumps(rows,ensure_ascii=False,indent=2),encoding='utf8')
    robust=[x for x in r if x['class']=='robust'];weak=[x for x in r if x['class'] in ['single_run','unstable']]
    diversity={}
    for tier in ['BASIC','INTER']:
        selected=[m for m in lineage if rows[m['row']]['tier']==tier]
        branches=collections.Counter();phases=collections.Counter()
        for m in selected:
            branches.update(m['trace']['branch_counts'])
            turn=int(rows[m['row']]['turn']);phases['opening <=10' if turn<=10 else 'middle 11-30' if turn<=30 else 'late >30']+=1
        diversity[tier]={'unit_branch_counts':dict(branches),'decision_phase_counts':dict(phases),
                         'unique_turns':sorted({rows[m['row']]['turn'] for m in selected})}
    (p/'dataset_diversity.json').write_text(json.dumps(diversity,indent=2),encoding='utf8')
    samples=[];used=set()
    # Five complete original rows, different policies, both tiers and multiple turns.
    for tier,want in [('BASIC',1),('INTER',1),('BASIC',15),('INTER',25),('BASIC',40)]:
        options=[x for x in rows if x['tier']==tier and x['strategy'] not in used]
        if not options:options=[x for x in rows if x['tier']==tier]
        if not options:continue
        row=min(options,key=lambda x:(abs(int(x['turn'])-want),len(json.dumps(x)),x['game']))
        samples.append(row);used.add(row['strategy'])
    (p/'five_samples.json').write_text(json.dumps(samples,ensure_ascii=False,indent=2),encoding='utf8')
    before=load(p/'source_manifest_before.json');after={f:hashlib.sha256(Path(f).read_bytes()).hexdigest() for f in before}
    (p/'source_manifest_after.json').write_text(json.dumps(after,indent=2),encoding='utf8')
    repro=p/'reproduction';repro.mkdir(exist_ok=True)
    for f in ['tools/plan_search/survivor_policy.py','tools/plan_search/survivor_search.py','tools/plan_search/survivor_synthesis.py','tools/plan_search/survivor_report.py','tools/plan_search/survivor_live_audit.py','tools/plan_search/survivor_rationale.py','tools/plan_search/survivor_resume_cleanup.py','tools/plan_search/survivor_final_check.py','tools/brain_review/teacher_proxy.py']:
        shutil.copy2(f,repro/Path(f).name)
    lines=['# Commander survivor search','',
        'No model was trained. Offline synthesis used `opencode/space-bunny-free`; the CLI recorded cost 0. '
        'No LLM was queried by the game workers. Normal commander prompts and packets were captured unchanged.',
        '', '## Search volume','', '| Tier | Generated | Initially tested | Initial wins | Initial nonwins | Initial win rate | Repeated plans | Robust plans | Weak/unstable plans | Robust rate |',
        '|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|']
    volume_details=[]
    for tier,t in s['tiers'].items():
        lines.append('| %s | %d | %d | %d | %d | %.1f%% | %d | %d | %d | %.1f%% |'%(tier,t['generated'],t['tested_plans'],t['initial_wins'],t['initial_nonwins'],100*t['initial_win_rate'],t['repeated_plans'],t['robust_plans'],t['weak_or_unstable_plans'],100*t['robust_survivor_rate']))
        volume_details += ['',f"{tier}: all evaluation results = {t['result_kinds']}; {t['evaluation_games']} games. Repeated-plan win rates = {t['repeated_plan_win_rate_distribution']}."]
    lines += volume_details
    lines += ['', '## Dataset','',f"Primary JSON list: `{p/'sft_robust.json'}`.",
        f"{s['rows']} rows; BASIC {s['tiers']['BASIC']['sft_rows']}, INTER {s['tiers']['INTER']['sft_rows']}; {s['distinct_games']} distinct games and {s['distinct_strategies']} distinct strategies after deduplication.",
        'Weak/unstable winning trajectories are separate in `sft_weak.json`. Loss trajectories remain in raw captures for analysis and never enter either positive dataset.',
        'Complete game results, seed/style/family, frozen policy parameters, request files, response files, chosen branch facts, and executed action logs remain available. `sft_lineage.json` links each primary row to its exact source and validation evidence.',
        'Observed primary-dataset phase and code-branch diversity: '+json.dumps(diversity)+'. Branch totals count unit decisions; phase totals count SFT rows. Potential policy features that never execute do not establish observed behavioral diversity.',
        '', '## Eligibility and generalization limits','',
        'A robust plan won its initial game and all four extra evaluations, with four opponent styles and at least three stat families. The policy hash and complete strategic logic were unchanged. Nomination chose the fastest initial winner per strategy family per tier, then fewer lost units and more surviving units. Other winners remain weakly validated.',
        'Robust-plan measured win rates are 100% by construction, with only five games per plan/tier. This is repeated evidence, not a guarantee of future win rate. Selection used these evaluations; they are not an independent held-out benchmark. All tests use the real collector\'s STEP0_SANDBOX HQ battle, varying opponent style, movement/attack stat family and seed. Transfer to other maps, terrain, army compositions, or fog conditions remains unverified.',
        '', '## Strategy findings','']
    for tier in ['BASIC','INTER']:
        rr=[x for x in r if x['tier']==tier];strong=[x for x in rr if x['class']=='robust']
        lines.append(f'### {tier}')
        if tier=='BASIC':
            lines.append('Fast mobile HQ exploitation, gated HQ commitment and aggressive pressure repeatedly survived. The fastest measured families averaged roughly 14-18 turns with fewer than one destroyed unit. Slower field fighting, class-counter screens and defensive openings also produced robust plans, so the primary set is not restricted to a single opening. Regroup openings had only 4/16 initial wins; several preservation/avoidance plans that initially won failed a repeat at the turn limit.')
        else:
            lines.append('Blitz HQ pressure and gated/mobile exploitation also survived INTER, but several field-fighting families took longer and lost more units than their BASIC counterparts. Early pressure required adequate home defense: P029 won all five BASIC games but lost an INTER repeat with its own HQ destroyed at turn 21 while BLUE HQ still had 300 soldiers. The two_phase_fw_then_soldiers family won none of its eight INTER screening games. Regroup openings had only 5/16 initial wins. These observations are specific to the measured configurations and setups; they do not prove causal effects of individual parameters.')
        lines.append('Repeatedly successful families (plan win rate, average victory turn, average unit losses, survivors):')
        for x in strong[:10]:lines.append('- %s / %s: %.0f%%, %.1f turns, %.1f losses, %.1f surviving units.'%(x['strategy'],x['family'],100*x['win_rate'],x['average_turns_to_victory'],x['average_friendly_losses'],x['average_surviving_friendly_units']))
        unstable=[x for x in rr if x['class']=='unstable']
        lines.append('Inconsistent repeated winners: '+(', '.join('%s (%s: %.0f%%)'%(x['strategy'],x['family'],100*x['win_rate']) for x in unstable[:12]) or 'none observed')+'.')
        repeated_failures=[json.loads(l) for l in (p/'results.jsonl').read_text(encoding='utf8').splitlines() if json.loads(l)['tier']==tier and json.loads(l)['stage']=='repeat' and json.loads(l)['kind']!='WIN']
        for x in repeated_failures[:6]:
            lines.append('- Observed repeated failure %s: %s at turn %s; RED HQ soldiers %s, BLUE HQ soldiers %s; %s distinct RED attackers. The initial win did not generalize to this setup.'%(x['game'],x['kind'],x['turn'],(x.get('hq') or {}).get('red',{}).get('end'),(x.get('hq') or {}).get('blue',{}).get('end'),x.get('execution_diagnostics',{}).get('distinct_attackers')))
        initial=[json.loads(l) for l in (p/'results.jsonl').read_text(encoding='utf8').splitlines() if json.loads(l)['tier']==tier and json.loads(l)['stage']=='initial']
        fs=collections.defaultdict(list);by={x['id']:x for x in pop}
        for x in initial:fs[by[x['strategy']]['family']].append(x)
        failed=[(fam,len(v)) for fam,v in fs.items() if not any(x['kind']=='WIN' for x in v)]
        lines.append('Families with no initial wins: '+(', '.join('%s (%d games)'%x for x in failed) or 'none')+'.')
        lines.append('Failure outcomes: '+str(dict(collections.Counter(x['kind'] for x in initial if x['kind']!='WIN')))+'.')
        nonwins=[x for x in initial if x['kind']!='WIN']
        no_hq_damage=sum(not sum((x.get('execution_diagnostics',{}).get('hq_damage_per_unit') or {}).values()) for x in nonwins)
        capped=sum((x.get('turn') or 0)>=80 for x in nonwins)
        lines.append('%d/%d initial nonwins reached the turn cap; %d/%d recorded no RED attack damage to BLUE HQ. These are execution observations, not LLM quality judgments.'%(capped,len(nonwins),no_hq_damage,len(nonwins)))
        if strong:
            params=[by[x['strategy']]['params'] for x in strong]
            lines.append('Repeated-survivor policy parameters: median timed commitment %.1f; median HQ allocation %.2f; median focus limit %.1f; openings %s; RAID enabled %d/%d; preservation modes %s.'%(statistics.median(x['commit_turn'] for x in params),statistics.median(x['commit_share'] for x in params),statistics.median(x['max_focus'] for x in params),dict(collections.Counter(x['opening'] for x in params)),sum(x['raid'] for x in params),len(params),dict(collections.Counter(x['wounded_mode'] for x in params))))
        cohorts=collections.defaultdict(list)
        for x in initial:
            pp=by[x['strategy']]['params']
            bands=['opening='+pp['opening'],'preservation='+pp['wounded_mode'],
                   'HQ commitment='+('early <=15' if pp['commit_turn']<=15 else 'middle 16-30' if pp['commit_turn']<=30 else 'late >30'),
                   'HQ allocation='+('high >=0.6' if pp['commit_share']>=.6 else 'middle 0.3-0.59' if pp['commit_share']>=.3 else 'low <0.3'),
                   'RAID='+str(pp['raid'])]
            for band in bands:cohorts[band].append(x)
        lines += ['', 'Observed initial outcomes by overlapping policy configuration group:', '', '| Configuration group | Games | Wins | Win rate |', '|---|---:|---:|---:|']
        for band,gg in sorted(cohorts.items()):
            nw=sum(x['kind']=='WIN' for x in gg)
            lines.append('| %s | %d | %d | %.1f%% |'%(band,len(gg),nw,100*nw/len(gg)))
        measures=[]
        for x in strong:
            dd=x['execution_diagnostics']
            shares=[d.get('max_unit_damage_share',0) for d in dd];attackers=[d.get('distinct_attackers',0) for d in dd]
            measures.append({'strategy':x['strategy'],'family':x['family'],'max_unit_damage_share':max(shares,default=0),'min_distinct_attackers':min(attackers,default=0)})
        lines.append('Force-level contribution diagnostics: '+json.dumps(measures,ensure_ascii=False)+'.')
        lines.append('These family comparisons are descriptive; they do not establish causal parameter effects. Single-run wins are not called consistent success.')
    errors=load(p/'technical_errors.json');diagnostics=[d for x in r for d in x['execution_diagnostics']]
    engine_errors=collections.Counter();parse_errors=0;order_rejections=0
    for f in p.glob('slot_*/arena_*/godot.log'):
        for line in f.read_text(encoding='utf8',errors='replace').splitlines():
            if line.startswith('ERROR:'):engine_errors[line]+=1
            parse_errors+='Parse JSON failed' in line
            order_rejections+=any(w in line.lower() for w in ['invalid order','invalid target','illegal action','policy_error'])
    census={'scope':'All owned arena logs, including interrupted attempts; valid-game diagnostics are counted separately.',
            'error_lines':sum(engine_errors.values()),'json_parse_error_lines':parse_errors,'order_rejection_text_lines':order_rejections,
            'common_errors':dict(engine_errors.most_common(12))}
    (p/'engine_log_census.json').write_text(json.dumps(census,indent=2),encoding='utf8')
    lines += ['', '## Problems and checks','',
        '- The original offline wrapper returned empty output. Oversized and long-running Nemotron attempts were retained/cancelled; no paid fallback was used. Space Bunny completed successfully with a zero-cost event.',
        '- Two LLM-generated configurations were exact duplicates; 256 recipe expansions produced 254 unique policies.',
        '- The first partial sweep reused a manual directory whose proxy restarted request numbering. Old response files could therefore be served. That entire sweep was quarantined under `rejected_manual_collision_run/`, excluded from all survivor/SFT counts, and rerun using a unique manual session directory. A live replay audit was added to detect response/policy mismatches during execution.',
        '- A later technical interruption simultaneously ended all 24 arena processes and their proxy connections without a diagnostic traceback. Its 24 incomplete game results and partial calls are preserved in `technical_interruption_1/` and excluded from gameplay win-rate denominators. The 296 completed valid games were preserved; interrupted and untested cases were resumed using hidden detached Windows processes. The cause remains unconfirmed.',
        '- Offline analysis summarized all 3,341 corpus decisions and supplied 40 representative outcome-linked decisions to the free model. The model did not consume every historical packet verbatim. Selected original requests and results are separately preserved under `free_bunny/`.',
        '- Slot 3 was occupied at inspection despite the initial task inventory. Slots 1, 2, 3 and 4 were avoided. Search initially used slots 0, 5 and 6, each with separate proxy/brain ports and isolated arena/manual paths.',
        '- On a user memory-pressure query, the 24-game search used approximately 22 GiB resident RAM and 29 GiB private committed memory. System commit was 95% with 10 GiB RAM available. Only the owned search tree was stopped; 374 completed games were preserved, 24 incomplete captures quarantined under `memory_throttle_1/`, and these games retried. Concurrency was reduced to 12 arenas on slots 0 and 5 with two CPU support workers. Settled available RAM increased to 19.45 GiB and system commit fell to 82%. The protected slot 2 worker and unrelated WSL VM were left alone; no confirmed orphan was identified.',
        '- Same-seed engineering smoke replay reproduced both game results and exact decision trajectories. This check covers those two runs only.',
        f"- Technical search exceptions: {json.dumps(errors)}.",
        f"- Godot headless/dummy renderer logged {sum(d.get('render_errors',0) for d in diagnostics)} error lines (not all necessarily unique errors). Raw logs are retained. These are reported separately from strict commander faults and game outcomes.",
        f"- The whole-arena log census (including interrupted attempts) found {parse_errors} JSON-parse error lines and {order_rejections} lines matching invalid-order/target/action text. Occasional parse-error sources were not proven; captured accepted commander replies all parse and replay exactly. `engine_log_census.json` preserves the common console errors.",
        f"- Audit: {s['audit']}.",
        '- Exact tactical-state/order trajectory duplicates are removed from the primary set; original captures and rankings remain intact. Exact input/order decision duplicates are also removed. Similar wording alone is never a deduplication criterion.',
        '- Enemy contacts are limited to the normal packet, including any last-seen entries. The code does not access enemy true soldier counts or the simulator state.',
        '- Friendly losses count destroyed units (including HQ in the game start/alive counters), not individual soldier casualties. Damage-concentration diagnostics use executed RED attacks; they do not attribute counterattack damage.',
        '- Preservation uses an absolute visible soldier-count threshold, without a per-unit initial-strength baseline. A small full-strength unit can therefore enter the preservation branch immediately. This is a policy-representation weakness and a plausible source of passivity; it is not asserted as the proven cause of every failed game. Policies remained frozen during evaluation.',
        f"- Commander controller source unchanged during search: {before['scripts/cloud_pipeline/commander_controller.gd']==after['scripts/cloud_pipeline/commander_controller.gd']}.",
        '', '## Reproduce','',
        'Run from the StrategyGame project root. First choose free collector slots and verify ports. The configuration and policies are frozen in this artifact directory. Resuming this directory skips already completed games; use a new output directory and copy `population.json` to replay the frozen population.',
        '```powershell',
        'python -m tools.plan_search.survivor_search --out artifacts/brain_pipeline_v1/commander_survivors_20261007 --slots 0,5 --windows 6',
        'python -m tools.plan_search.survivor_search --out artifacts/brain_pipeline_v1/commander_survivors_20261007 --export-only',
        'python -m tools.plan_search.survivor_report --out artifacts/brain_pipeline_v1/commander_survivors_20261007',
        'python -m tools.plan_search.survivor_final_check --out artifacts/brain_pipeline_v1/commander_survivors_20261007',
        '```','',
        'Regenerating policies is optional and produces a new stochastic offline population; frozen replay is the reproducible route. The synthesis script only allows the two explicitly free model IDs. All requests and model responses are saved under `free_bunny/`.',
        '', '## Five complete sample SFT rows','',
        'These rows are also provided as one JSON list in `five_samples.json`. Every prompt, packet and executed reply below is complete.',
        '```json',json.dumps(samples,ensure_ascii=False,indent=2),'```']
    (p/'REPORT.md').write_text('\n'.join(lines),encoding='utf8')
    files=['population.json','results.jsonl','ranking.json','robust_survivors.json','weak_survivors.json','sft_robust.json','sft_weak.json','sft_lineage.json','five_samples.json','REPORT.md']
    (p/'deliverable_hashes.json').write_text(json.dumps({f:hashlib.sha256((p/f).read_bytes()).hexdigest() for f in files},indent=2),encoding='utf8')
    print('report',p/'REPORT.md')
if __name__=='__main__':main()
