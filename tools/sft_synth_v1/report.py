from __future__ import annotations
import itertools
import json
from collections import defaultdict,Counter
from .analyze import OUT,ROOT,sha
from .campaign import BUCKETS,MISSION
from .validate import audit,lines

def cell(j):
    n=j['size'];bucket=next(f'{lo}-{hi}' for lo,hi in BUCKETS if lo<=n<=hi)
    return (bucket,j['tier'],j['style'],j['family'],j['pov'])

def main():
    completed=[]
    for stage in ['pilot','replication','mass_replication','repair','expansion','repair_expansion','coverage']:
        if (OUT/stage/'results.jsonl').exists():
            a=audit(stage);completed.extend(dict(x,stage=stage) for x in a)
            (OUT/stage/'validation.json').write_text(json.dumps(a,ensure_ascii=False,indent=2),encoding='utf-8')
    # Gate is cell-specific, measured on five distinct seeds, never inferred from another cell.
    gates=[];groups=defaultdict(list)
    for g in completed:
        if g['stage'] in ['pilot','replication','mass_replication','repair']:groups[(cell(g),g['size'],g['policy'])].append(g)
    allowed=set()
    for (c,size,p),games in groups.items():
        unique={g['seed']:g for g in games};ordered=sorted(unique.values(),key=lambda g:g['seed'])[:5]
        win=sum(g['verified_win'] and g['audit_pass'] for g in ordered)
        passed=len(ordered)==5 and win>=4
        replica=[g for g in games if g['stage'] in ['replication','mass_replication']]
        replica_wins=sum(g['verified_win'] and g['audit_pass'] for g in replica)
        if len(replica)>=5 and replica_wins<4:passed=False
        gates.append({'cell':c,'actual_size':size,'policy':p,'seeds':[g['seed'] for g in ordered],'wins':win,'games':len(ordered),'pass':passed,
                      'replication_wins':replica_wins,'replication_games':len(replica)})
        if passed:allowed.add((c,size,p))
    (OUT/'generator_gates.json').write_text(json.dumps(gates,indent=2),encoding='utf-8')
    selected=defaultdict(list)
    # At most ten games per cell, prefer expansion over gate trials; keep distinct seeds when available.
    for g in sorted(completed,key=lambda g:(g['stage']!='expansion',g['seed'],g['policy'])):
        if g['verified_win'] and g['audit_pass'] and (cell(g),g['size'],g['policy']) in allowed:selected[cell(g)].append(g)
    admitted=set()
    for c,games in selected.items():
        chosen=[];seen=set()
        for g in games:
            if g['seed'] not in seen and len(chosen)<10:chosen.append(g);seen.add(g['seed'])
        for g in games:
            if len(chosen)<10 and g not in chosen:chosen.append(g)
        admitted.update(g['game'] for g in chosen)
    rows=defaultdict(list);lost=[];rejected=[];lineage=[]
    bygame={g['game']:g for g in completed}
    for stage in ['pilot','replication','mass_replication','repair','expansion','repair_expansion','coverage']:
        for r in lines(OUT/stage/'raw/calls.jsonl'):
            g=bygame.get(r['game'])
            if g is None:continue
            row={k:r[k] for k in ['messages','game','turn']}
            row.update(completion=r['raw'],seed=g['seed'],tier=g['tier'],gx_style=g['style'],rule_family=g['family'],
                units_per_side={'red':g['size'],'blue':g['size']},win_condition=MISSION,outcome='WIN' if g['verified_win'] else g['kind'],
                teacher_model='visible-code/'+g['policy'],teacher_reasoning='deterministic',system_prompt_sha256=sha(r['messages'][0]['content']),
                game_outcome=g['outcome'],pov=g['pov'],size_bucket=cell(g)[0],pattern=g['policy'],generator_sha256=r['source_sha256'])
            if g['game'] in admitted:rows[cell(g)].append(row)
            elif not g['verified_win']:lost.append(row)
            else:rejected.append(row)
    training=[]
    for c,candidates in rows.items():
        # 300 rows per cell; distribute slots across games, retain opening and real plan changes.
        games=defaultdict(list)
        for r in candidates:games[r['game']].append(r)
        ranked=[]
        for game,rs in sorted(games.items()):
            rank=sorted(rs,key=lambda r:(0 if 'plan' in json.loads(r['completion']) else 1 if json.loads(r['completion'])['orders'] else 2,
                                        sha(f"{game}:{r['turn']}")))
            ranked.append(rank)
        chosen=[]
        for i in range(max(map(len,ranked),default=0)):
            for rank in ranked:
                if i<len(rank) and len(chosen)<300:chosen.append(rank[i])
        for row in sorted(chosen,key=lambda r:(r['game'],r['turn'])):
            g=bygame[row['game']];training.append(row)
            lineage.append({'game':row['game'],'turn':row['turn'],'source':f"{g['stage']}/raw/calls.jsonl",'game_source':f"{g['stage']}/games/{row['game']}.json",
                'messages_sha256':sha(json.dumps(row['messages'],ensure_ascii=False,separators=(',',':'))),'completion_sha256':sha(row['completion']),
                'game_sha256':g['game_sha256'],'policy_sha256':row['generator_sha256'],'cell_gate':'4/5 distinct seeds','transform':'none: game-emitted messages and played compact completion'})
    for name,obj in [('sft_rows.json',training),('sft_lost_rows.json',lost),('sft_rejected_winner_rows.json',rejected),('sft_transform_lineage.json',lineage)]:
        (OUT/name).write_text(json.dumps(obj,ensure_ascii=False,separators=(',',':')),encoding='utf-8')
    bycell=defaultdict(list)
    for g in completed:bycell[cell(g)].append(g)
    rowcounts=Counter((r['size_bucket'],r['tier'],r['gx_style'],r['rule_family'],r['pov']) for r in training)
    coverage=[]
    for c in itertools.product([f'{lo}-{hi}' for lo,hi in BUCKETS],['BASIC','INTER','ADV'],['SPEARHEAD','BULWARK','OUTRIDER','HARRIER'],['fixed','mild','broad','counterfactual_valid'],['RED','BLUE']):
        gs=bycell[c];kept=[g for g in gs if g['game'] in admitted]
        coverage.append({'cell':c,'played':len(gs),'won':sum(g['verified_win'] for g in gs),'admitted_games':len(kept),'distinct_winning_seeds':len({g['seed'] for g in kept}),
            'rows':rowcounts[c],'sizes_played':sorted({g['size'] for g in gs}),'patterns':dict(Counter(g['policy'] for g in kept)),
            'coverage_complete':len(kept)>=10 and len({g['seed'] for g in kept})>=5,'status':'UNMEASURED' if not gs else 'COMPLETE' if len(kept)>=10 and len({g['seed'] for g in kept})>=5 else 'INSUFFICIENT'})
    (OUT/'coverage_counts.json').write_text(json.dumps(coverage,indent=2),encoding='utf-8')
    complete=sum(c['coverage_complete'] for c in coverage)
    validation={'games':len(completed),'wins':sum(g['verified_win'] for g in completed),'audits_passed':sum(g['audit_pass'] for g in completed),
        'admitted_games':len(admitted),'training_rows':len(training),'nonwinning_rows':len(lost),'rejected_winner_rows':len(rejected),
        'cells_complete':complete,'total_cells':480,'teacher_direct_games':0,'teacher_share':0 if training else None,'heldout_used':False,
        'coverage_status':'FAILED_GENERATOR_GATE' if completed and not admitted else 'PILOT_ONLY',
        'note':'Source teacher games contain a tactical prompt hint and are not silently rewritten or admitted to this facts-only package.',
        'extra_timing_duplicate_games':1,'technical_failed_probe_attempts':3,'all_godot_attempts_including_probes':len(completed)+4}
    (OUT/'validation.json').write_text(json.dumps(validation,indent=2),encoding='utf-8')
    diversity={}
    for stage in ['pilot','replication','mass_replication','repair','expansion','repair_expansion']:
        cs=lines(OUT/stage/'raw/calls.jsonl')
        diversity[stage]={'opening_orders':len({sha(json.dumps(json.loads(r['raw'])['orders'],sort_keys=True)) for r in cs if r['turn']==1}),
                          'stages':dict(Counter(r['trace']['stage'] for r in cs)),
                          'plan_turns':dict(Counter(r['turn'] for r in cs if 'plan' in json.loads(r['raw'])))}
    (OUT/'dataset_diversity.json').write_text(json.dumps(diversity,indent=2),encoding='utf-8')
    behavior=[]
    for policy in sorted({g['policy'] for g in completed}):
        gs=[g for g in completed if g['policy']==policy]
        changes=[];straight=[]
        for g in gs:
            cs=[r for r in lines(OUT/g['stage']/'raw/calls.jsonl') if r['game']==g['game']]
            changes.append(sum(sum(o.get('do')=='ATTACK' for o in json.loads(r['raw'])['orders'].values()) for r in cs))
            native=json.loads((OUT/g['stage']/'games'/f"{g['game']}.json").read_text())
            value=native.get('wander',{}).get('mean_straightness')
            if value is not None:straight.append(value)
        behavior.append({'pattern':policy,'games':len(gs),'wins':sum(g['verified_win'] for g in gs),
                         'mean_attack_order_changes':round(sum(changes)/len(changes),2),
                         'mean_straightness':round(sum(straight)/len(straight),3) if straight else None})
    (OUT/'behavior_comparison.json').write_text(json.dumps(behavior,indent=2),encoding='utf-8')
    text=['# Synthetic commander SFT V1 — pilot', '',
        f"Played {len(completed)} main games; Godot-verified wins {validation['wins']}; admitted {len(admitted)} games / {len(training)} SFT rows. Cell completion {complete}/480. This is a bounded pilot, not full coverage. Final status: {validation['coverage_status']}.", '',
        f"All Godot attempts including probes: {len(completed)+4}. In addition to the main games: one successful duplicate for time-scale parity, two completed parser-failure CAP probes, and one aborted duplicate-hint wiring probe. These four attempts are excluded from gameplay-generator win rates and training admission.", '',
        'Mission is the current 70%-destroy, symmetric army-collapse, own-HQ guard, enemy-HQ nonterminal mission; cap 60. Fortification ON, equal seeded armies, one resident conversation per game. No model inference, paid calls, or GPU training used by this campaign.', '',
        'Gate: each generator × cell requires >=4 wins on five distinct new seeds. Only its independently audited winning games are admitted. Ten games maximum and 300 rows maximum per cell; at least five distinct winning seeds are needed for cell completion. No seed-specific generator exists.', '',
        '|Bucket|Tier|GX|Family|POV|Actual sizes|Played|Won|Admitted|Winning seeds|Rows|Patterns|Status|', '|---|---|---|---|---|---|---:|---:|---:|---:|---:|---|---|']
    for c in coverage:
        if c['played']:text.append('|'+ '|'.join(map(str,[*c['cell'],','.join(map(str,c['sizes_played'])),c['played'],c['won'],c['admitted_games'],c['distinct_winning_seeds'],c['rows'],c['patterns'],c['status']]))+'|')
    text+=['', '## Generator gates', '', '|Cell|Pattern|Wins / seeds|Pass|','|---|---|---|---|']
    for g in gates:text.append(f"|{' / '.join(g['cell'])} (actual size {g['actual_size']})|{g['policy']}|{g['wins']}/{g['games']} (replication {g['replication_wins']}/{g['replication_games']})|{g['pass']}|")
    text+=['', '## Pattern behavior (all valid attempts, including losses)', '',
           '|Pattern|Played|Won|Mean changed attack orders / game|Mean straightness|','|---|---:|---:|---:|---:|']
    for b in behavior:text.append(f"|{b['pattern']}|{b['games']}|{b['wins']}|{b['mean_attack_order_changes']}|{b['mean_straightness']}|")
    text+=['', 'The screened-fire generator initially passed 4/5, but independent 10v10 replication won only 3/5. Its admission was revoked, including its initial wins. Mass-focus also initially passed 4/5 but independent 10v10 replication won only 1/5; its admission was revoked as well. Mixed-size mass-focus expansion was only 5/10. The cohesive-focus revision maintained one shared target rather than changing individual pairings every turn, but won only 2/5 and was rejected.', '',
        'The implemented generators are coarse approximations of the teacher trajectories. These failures do not establish that the teacher strategies themselves fail; they establish that these executable implementations are not reliable enough on new seeds. No generator is promoted and no winner is admitted merely because it won once.', '',
        '## Limits and unfilled coverage', '',
        '- All 480 cells, including unmeasured ones, are enumerated in `coverage_counts.json`. No unmeasured tier, scale, style, family, or BLUE POV is called solved. Gate admission is limited to the actual army size tested: a 10v10 4/5 gate does not admit 7v7, 8v8, 9v9 or 11v11 winners without their own gate. Within a bucket, the actual sizes tested are recorded; a single representative size does not prove every size.',
        '- No direct-teacher game is admitted. With no admitted synthetic games the mixture ratio is undefined; the 10–20% teacher target is not fulfilled. The six source teacher wins retain a focus-fire prompt hint; copying them unchanged would violate the new prompt constraint, and editing their recorded prompts would violate exact-emission lineage. They are used only for pattern evidence. Additional facts-only direct teacher games remain needed; no paid teacher was called.',
        '- Nonwins are in `sft_lost_rows.json`; won games excluded by generator gate, validation, or cell game cap are in `sft_rejected_winner_rows.json`. All full games and calls remain preserved.',
        '- The failed wiring smoke is preserved in `wiring_smoke_rejected/` and excluded from all game/row counts. It caught a duplicate hint before any row admission. CPU Hands boot wrote one legacy service log before its log directory was isolated; existing source packages and running jobs were not edited or stopped.',
        '- Earlier 738-row SFT, survivor/growth data and 368 RL-v8 games are contrast only; no old HQ-win labels are admitted.', '',
        'The frozen teacher shell guards RED HQ specifically. BLUE POV is unmeasured and the runner refuses BLUE jobs until a separate POV-correct runtime is validated; simply swapping the prompt would not establish the required BLUE mission.', '',
        'Production files changed during this run; the isolated gameplay runtime stayed byte-identical. `source_boundary_audit.json` records the live-source drift without attributing those edits to this campaign. The fixed teacher collection inputs remained unchanged.', '',
        '## Verification and provenance', '',
        'Per-game validations replay every decision using only the saved messages, compare it with the played reply, compare changed orders with actual Godot standing orders, inspect native action logs for unauthorized attacks, and independently recompute victory from initial/final non-HQ snapshots plus HQ survival. Messages and completions are not rewritten.', '',
        'Source hashes and frozen runtime: `source_analysis.json`, `runtime_manifest.json`. Generator source: `tools/sft_synth_v1/policy.py`. Every admitted row has message/completion/game/policy hashes in `sft_transform_lineage.json`. Held-out seeds 8831101–8831106 are prohibited in the job builder and audit.', '',
        'Next gate: repair the actual pursuit/cohesion/target-finishing behavior, then pass >=4/5 on fresh seeds plus an independent >=4/5 replication in the same actual-size cell before collecting ten wins. Do not change losing-game text to create training labels. New tiers/scales/styles/families/BLUE POV and direct teacher mixture remain deferred, not completed. No SFT training or runtime integration was performed.']
    (OUT/'REPORT.md').write_text('\n'.join(text)+'\n',encoding='utf-8')
    print(json.dumps(validation))

if __name__=='__main__':main()
