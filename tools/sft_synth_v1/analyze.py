from __future__ import annotations
import hashlib
import json
from collections import Counter, defaultdict
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / 'artifacts/brain_pipeline_v1/sft_synth_v1'
COLLECTION = ROOT / 'artifacts/brain_pipeline_v1/sft_collect_v2'

def sha(data):
    return hashlib.sha256(data if isinstance(data, bytes) else data.encode()).hexdigest()

def read(path):
    return json.loads(path.read_text(encoding='utf-8'))

def main():
    OUT.mkdir(parents=True, exist_ok=True)
    evidence = []
    for filename in ['sft_rows.json', 'sft_lost_rows.json']:
        groups = defaultdict(list)
        for row in read(COLLECTION / filename):
            groups[row['game']].append(row)
        for game, rows in groups.items():
            rows.sort(key=lambda r:r['turn'])
            counts = Counter()
            plans, turns, hq_orders = [], [], []
            for row in rows:
                answer = json.loads(row['completion'])
                if answer.get('plan'):
                    plans.append({'turn':row['turn'], 'text':answer['plan']})
                targets = Counter()
                for uid, order in answer['orders'].items():
                    counts[order['do']] += 1
                    if 'HQ' in uid: hq_orders.append({'turn':row['turn'], 'order':order})
                    if order['do'] in ['ATTACK','RAID']: targets[order.get('target')] += 1
                turns.append({'turn':row['turn'], 'changed_orders':len(answer['orders']),
                              'changed_target_counts':dict(targets)})
            evidence.append({'game':game, 'source':filename, 'metadata':{k:v for k,v in rows[0].items() if k not in ['messages','completion']},
                             'plans':plans, 'order_counts':dict(counts), 'hq_orders':hq_orders,
                             'turns':turns, 'system_has_focus_hint':'Focus fire:' in rows[0]['messages'][0]['content']})
    # Earlier datasets are contrast only: they used different rules and/or conversation formats.
    contrast = {}
    for rel in ['cmd_sft/sft_resident_v1.json', 'commander_survivors_20261007/sft_robust.json',
                'commander_growth_20261007/sft_expanded.json']:
        p=ROOT/'artifacts/brain_pipeline_v1'/rel
        if p.exists():
            rs=read(p); contrast[rel]={'rows':len(rs),'games':len({r.get('game') for r in rs}), 'sha256':sha(p.read_bytes()),
                                      'sample':{k:v for k,v in rs[0].items() if k!='messages'},
                                      'first_system':rs[0].get('messages',[{}])[0].get('content','')}
    rl=ROOT/'artifacts/brain_pipeline_v1/cmd_rl_v8/games.jsonl'
    if rl.exists():
        rs=[json.loads(l) for l in rl.read_text(encoding='utf-8').splitlines() if l.strip()]
        contrast['cmd_rl_v8']={'games':len(rs),'outcomes':dict(Counter(r.get('kind', r.get('outcome')) for r in rs)),
                               'sha256':sha(rl.read_bytes()), 'sample':rs[0]}
    lineage=read(COLLECTION/'sft_transform_lineage.json')
    (OUT/'source_analysis.json').write_text(json.dumps({'games':evidence,'contrast':contrast,'collection_lineage_rows':len(lineage),
        'source_hashes':{n:sha((COLLECTION/n).read_bytes()) for n in ['sft_rows.json','sft_lost_rows.json','sft_transform_lineage.json','coverage_counts.json']}},ensure_ascii=False,indent=2),encoding='utf-8')
    lines=['# Winning-pattern evidence', '', 'Mission: destroy ceil(0.70 × initial enemy non-HQ units); symmetric army defeat; own HQ destruction is defeat; enemy HQ destruction is not victory; cap 60.', '',
           'The six teacher wins supply hypotheses, not repeated reliability. Teacher prompts contained a focus-fire hint. New synthetic games remove it at game emission, preserve all original teacher files, and never read the extra request state for decisions.', '',
           '|Game|Size|Tier|GX|Family|Result|Plans (turn)|', '|---|---:|---|---|---|---|---|']
    for g in evidence:
        m=g['metadata'];lines.append(f"|{g['game']}|{m.get('units_per_side')}|{m.get('tier')}|{m.get('gx_style')}|{m.get('rule_family')}|{m.get('outcome')}|{','.join(str(p['turn']) for p in g['plans'])}|")
    lines += ['', '## Hypotheses implemented by the generators', '',
        '- **Mass closure and focus:** `freebuff_deepseek_fast_high`, `ds_b0001_1_basic_n7`, `ds_b0001_2_inter_n12`, `ds_b0004_1_basic_n6`, `ds_b0004_3_adv_n3` explicitly close as a group, concentrate attacks, and finish field units. The INTER12 opening assigns ten units to B_CAV_3. `mass_focus` forms small assault groups on reachable field targets; it never orders an enemy-HQ rush.',
        '- **Matchups and target choice:** BASIC10 and BASIC7 assign spearmen to cavalry, cavalry to scouts, and archers to spearmen. ADV3 focuses infantry first using the spear matchup. `matched_pairs` combines distance, visible troop bands, matchup multipliers, and same-turn previews instead of copying unit IDs.',
        '- **Screened ranged fire:** BASIC10 and ADV15 plans place spears/infantry ahead of archers and exploit ranged fire without counters. `screened_fire` penalizes costly melee trades; `defensive_anvil` first forms a near-HQ line using mirrored geometry, then switches to field attacks.',
        '- **HQ defense:** all six opening plans leave the HQ at home or fortified. INTER12 and ADV3 explicitly fortify. ADV3 uses its HQ in the final turn-32 attack on the last field unit; that exception is preserved in the teacher evidence but is not generalized into HQ sorties. Every new generator leaves its HQ stationary and redirects nearby units when visible enemies can strike it.',
        '- **Plan changes and stalemate breaking:** analyze the played teacher plan changes below; advance/focus vs withdraw/defend are real strategy changes. Merely replacing a destroyed target does not emit a new plan. Synthetic generators switch to concentrated HQ interception if an HQ threat appears, and abandon a defensive opening or dispersed pairing after a visible lack of progress. These transitions are hypotheses until tested.', '',
        '## Loss / invalid contrasts', '',
        '- `ds_b0004_2_inter_n4`: turn-cap nonwin. Its turn-20 plan splits the remaining force between a fortified archer near our side and a fortified spear across the board. Both remaining targets require fieldworks to be broken, and the small force does not complete the required third kill. This is a failed trajectory, not proof that all split plans fail.',
        '- `ds_b0005_1_basic_n16`: teacher session expired; invalid command transport at decision 55. It is not a tactical defeat and none of its rows are admitted.',
        '- Older survivor/growth policies explicitly commit units to the enemy HQ; their wins do not establish success on this mission. They also include old packet formats. They remain read-only contrasts, not training rows.',
        '- RL v8 uses the previous HQ-win mission. Its outcome labels cannot admit rows to this mission. `source_analysis.json` records measured counts and original sample metadata.', '',
        'BASIC7 also supplies a rare stalemate-breaking hypothesis: turn 27 concentrates hits to break fieldworks; turn 50 sends scouts as bait to draw a fortified cavalry unit out before the spears finish it. That single successful trajectory is evidence to investigate, not a verified general bait generator. The four initial generators test closure, pairing, ranged trades, and defensive formation first.', '', '## Played teacher plans', '']
    for g in evidence:
        lines.append('### '+g['game'])
        for p in g['plans']: lines.append(f"- Turn {p['turn']}: {p['text']}")
        lines.append('')
    lines += ['## Source and scope', '', 'Machine evidence and source hashes: `source_analysis.json`. Original completion-removal lineage: `../sft_collect_v2/sft_transform_lineage.json`. Implementation: `tools/sft_synth_v1/policy.py`. Win locations and empty cells are measured in REPORT.md; no unplayed candidate is counted as a win.']
    (OUT/'PATTERNS.md').write_text('\n'.join(lines)+'\n',encoding='utf-8')
    print(json.dumps({'teacher_games':len(evidence),'teacher_wins':sum(g['source']=='sft_rows.json' for g in evidence), 'contrast':{k:{kk:vv for kk,vv in v.items() if kk not in ['sample','first_system']} for k,v in contrast.items()}}))

if __name__=='__main__': main()
