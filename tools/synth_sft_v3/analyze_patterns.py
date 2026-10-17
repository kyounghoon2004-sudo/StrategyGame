"""CPU-only analysis of original grind victories and the frozen 40-teacher cohort.

Run from the project root: python -m tools.synth_sft_v3.analyze_patterns.
Does not run games or modify source data. Measures supplied orders separately from
orders that differ from the previously standing order. Tactical labels are explicit
state/action proxies, not causal claims or self-graded synthetic verification.
"""
from __future__ import annotations
import collections
import json
import math
import re
from pathlib import Path
from statistics import mean

ROOT = Path(__file__).resolve().parents[2]
BP = ROOT / 'artifacts/brain_pipeline_v1'
OUT = BP / 'synth_sft_v3'

def answer(x):
    if isinstance(x, dict):
        return x
    x = re.sub(r'<think>.*?</think>', '', x, flags=re.S).strip()
    if x.startswith('```'):
        x = re.sub(r'^```(?:json)?\s*|\s*```$', '', x)
    return json.loads(x)

def phase(t):
    return 'T1' if t == 1 else 'T2-10' if t <= 10 else 'T11-30' if t <= 30 else 'T31+'

def load_cohorts():
    cohorts = []
    for run in ('seed_grind_v1', 'seed_grind_v2_inter_adv'):
        seeds = {int(x['seed']): x for x in json.loads((BP/run/'seeds.json').read_text(encoding='utf-8'))}
        games = collections.defaultdict(list)
        for r in json.loads((BP/run/'harvest/sft_rows_wins.json').read_text(encoding='utf-8')):
            games[r['game']].append(r)
        for g, rows in games.items():
            it = re.search(r'_it(\d+)_', g).group(1)
            f = BP/run/'seeds'/str(rows[0]['seed'])/('it'+it)/'games'/(g+'.json')
            cohorts.append(('grind', g, seeds[int(rows[0]['seed'])], sorted(rows, key=lambda x:x['turn']), f))
    frozen = json.loads((BP/'synth_sft_v2/bank_v1_40games.json').read_text(encoding='utf-8'))
    situations = collections.defaultdict(list)
    for line in (BP/'synth_sft_v2/situations.jsonl').read_text(encoding='utf-8').splitlines():
        s = json.loads(line)
        if s['game'] in frozen and str(s['turn']) in frozen[s['game']]['answers']:
            situations[s['game']].append({'game':s['game'], 'turn':s['turn'], 'messages':s['messages'], 'completion':frozen[s['game']]['answers'][str(s['turn'])]})
    for g,b in frozen.items():
        cohorts.append(('teacher40',g,b,sorted(situations[g],key=lambda x:x['turn']),Path(b['game_file'])))
    return cohorts

def aggregate(rows):
    n=len(rows)
    if not n:return {}
    stale=sum(r['stale_units'] for r in rows)
    return {'rows':n,'empty':sum(r['empty'] for r in rows), 'empty_pct':round(100*mean(r['empty'] for r in rows),2),
            'supplied_orders_mean':round(mean(r['supplied'] for r in rows),3),
            'changed_orders_mean':round(mean(r['changed'] for r in rows),3),
            'stale_unit_opportunities':stale,'retarget_live':sum(r['retarget_live'] for r in rows),
            'retarget_live_pct':round(100*sum(r['retarget_live'] for r in rows)/stale,2) if stale else None,
            'focus_max_mean':round(mean(r['focus_max'] for r in rows),3),
            'focus_histogram':dict(sorted(collections.Counter(r['focus_max'] for r in rows).items())),
            'new_attack_blue_hq':sum(r['blue_hq_orders'] for r in rows),
            'hq_orders':dict(collections.Counter(v for r in rows for v in r['hq_orders'])),
            'late_proxies':dict(collections.Counter(v for r in rows for v in r['late_proxies']))}

def main():
    OUT.mkdir(parents=True,exist_ok=True)
    decisions=[]; games=[]; exclusions=[]; burst_rows=[]; answer_issues=[]
    for source,g,meta,rows,f in load_cohorts():
        if not f.exists():
            exclusions.append({'game':g,'reason':'missing record','path':str(f)});continue
        rec=json.loads(f.read_text(encoding='utf-8'))
        if rec.get('outcome')!='RED_WIN':
            exclusions.append({'game':g,'reason':'record not RED_WIN'});continue
        snaps=rec['record']['snapshots']; start=snaps[0]
        blue0=sum(u[1]=='blue' and u[2]!='hq' for u in start['units'])
        byturn={s['turn']:s for s in snaps if s.get('to_act')=='red'}
        standing={}; local=[]
        for r in rows:
            t=int(r['turn'])
            try:
                a=answer(r['completion'])
            except (ValueError,TypeError) as e:
                from tools.synth_sft_v3.grind_bank import decode_answer
                try:
                    a=decode_answer(r['completion'])
                    answer_issues.append({'game':g,'turn':t,'reason':'original JSON recovered by collection parser','error':str(e),'recovered_answer':a})
                except (ValueError,TypeError):
                    answer_issues.append({'game':g,'turn':t,'reason':'unparseable original and collection parser','error':str(e)})
                    continue
            supplied_orders=a.get('orders') or {}
            orders={str(u).upper():o for u,o in supplied_orders.items() if isinstance(o,dict)}
            if len(orders)!=len(supplied_orders):
                answer_issues.append({'game':g,'turn':t,'reason':'non-dictionary order ignored by commander','units':[u for u,o in supplied_orders.items() if not isinstance(o,dict)]})
            users=[m['content'] for m in r['messages'] if m['role']=='user']
            op=json.loads(users[0]); now=json.loads(users[-1])
            # Packet ids are the information available to the commander.
            mine={u['id'] for u in op['my_units']} if t==1 else {u.split()[0] for u in now['my_units']}
            blue={u['id'] for u in op['enemy_units']} if t==1 else {u.split()[0] for u in now['enemy_units']}
            if t==1:
                threats={u['id'] for u in op['enemy_units'] if u.get('eta_strike_my_hq',99)<=2}
            else:
                threats={line.split()[0] for line in now['enemy_units'] if re.search(r'eta_my_hq\s+([012])(?:\s|$)',line)}
            stale=[u for u,o in standing.items() if u in mine and o.get('do') in ('ATTACK','RAID') and o.get('target','').startswith('B_') and o['target'] not in blue]
            changed={u:o for u,o in orders.items() if o!=standing.get(u,{'do':'HOLD'})}
            retarget=sum(u in changed and changed[u].get('do') in ('ATTACK','RAID') and changed[u].get('target') in blue for u in stale)
            standing.update(orders)
            targets=collections.Counter(o['target'] for u,o in standing.items() if u in mine and o.get('do') in ('ATTACK','RAID') and o.get('target') in blue and '_HQ_' not in o['target'])
            s=byturn.get(t)
            units={u[0]:u for u in s['units']} if s else {}
            proxies=[]
            if t>=30:
                if retarget:proxies.append('retarget_dead_to_live')
                if max(targets.values(),default=0)>=3:proxies.append('standing_focus_3plus')
                for u,o in changed.items():
                    unit=units.get(u); target=units.get(o.get('target'))
                    if o.get('do') in ('ATTACK','RAID') and target:
                        if target[7]>0:proxies.append('attack_fieldworks')
                        if unit and unit[2]=='cavalry' and target[2] in ('archer','scout'):proxies.append('cavalry_attack_archer_scout')
                        if unit and (abs(unit[3]-target[3])+abs(unit[4]-target[4])+abs(unit[3]+unit[4]-target[3]-target[4]))//2>3:proxies.append('pursuit_order_distance_gt3')
                    if unit and unit[2]!='hq' and unit[5]/max(1,unit[6])<.4 and o.get('do') in ('MOVE','HOLD','FORTIFY'):proxies.append('damaged_unit_disengage_or_fortify')
            d={'source':source,'game':g,'turn':t,'tier':meta['tier'],'phase':phase(t),'empty':not orders,
               'supplied':len(orders),'changed':len(changed),'stale_units':len(stale),'retarget_live':retarget,
               'focus_max':max(targets.values(),default=0),'blue_hq_orders':sum(o.get('target')=='ENEMY_HQ' or '_HQ_' in str(o.get('target','')) for o in orders.values()),
               'hq_orders':[o.get('do') for u,o in orders.items() if '_HQ_' in u], 'late_proxies':proxies,
               'plan':bool(a.get('plan')),'record_snapshot':s is not None,
               'hq_threats':len(threats),'hq_response':bool(threats and any('_HQ_' in u or o.get('target') in threats for u,o in changed.items()))}
            decisions.append(d);local.append(d)
        redactions=rec['record']['actions']['red']
        kills=collections.Counter(x['turn'] for x in redactions if x.get('destroyed') and '_HQ_' not in str(x.get('target','')))
        for t,k in kills.items():
            if k>=2:
                prev=[d for d in local if max(1,t-5)<=d['turn']<t]
                burst_rows.append({'source':source,'game':g,'turn':t,'kills':k,'preceding_rows':len(prev),'preceding_changed_orders':sum(d['changed'] for d in prev),'preceding_nonempty':sum(not d['empty'] for d in prev)})
        checkpoints={}
        for t in (20,30,40):
            reached=t in byturn
            s=byturn.get(t) or (snaps[-1] if rec['turn']<=t else None)
            checkpoints[str(t)]={'alive_at_turn':reached,'terminal_carried':not reached and s is not None,
                'kills':blue0-sum(u[1]=='blue' and u[2]!='hq' for u in s['units']) if s else None,'initial':blue0}
        games.append({'source':source,'game':g,'tier':meta['tier'],'turn':rec['turn'],'rows':len(rows),'checkpoints':checkpoints,
                      'red_hq_alive_final':any(u[1]=='red' and u[2]=='hq' for u in snaps[-1]['units']),
                      'record':str(f),'initial_blue_nonhq':blue0,'need':math.ceil(.7*blue0)})
    summary={source:{tier:{ph:aggregate([r for r in decisions if r['source']==source and r['tier']==tier and r['phase']==ph]) for ph in ('T1','T2-10','T11-30','T31+')} for tier in ('BASIC','INTER','ADV')} for source in ('grind','teacher40')}
    payload={'summary':summary,'games':games,'decisions':decisions,'kill_bursts':burst_rows,'exclusions':exclusions,'answer_issues':answer_issues}
    (OUT/'pattern_metrics_v3.json').write_text(json.dumps(payload,ensure_ascii=False,indent=2),encoding='utf-8')
    report=['# Winning patterns V3: measured original experience','',
      'CPU-only original-record analysis. Exact source messages/completions remain unchanged. No synthetic verification is claimed here.',
      '', '## Cohorts and definitions',
      '- Grind: both winning harvests. Teacher reference: exact frozen `bank_v1_40games.json` membership, matched to current V2 situation messages and original records.',
      '- Empty means no supplied orders. Supplied order count and genuinely changed order count are separate: repeated standing orders do not count as changes; previously unordered units default HOLD.',
      '- Retarget denominator is live own units with standing ATTACK/RAID on absent BLUE ids; numerator changes to ATTACK/RAID on a currently visible live BLUE id. Visibility absence may not prove death in other runtimes; these full-board collapse packets enumerate the battlefield.',
      '- Focus = maximum live own units with standing ATTACK/RAID on the same currently live non-HQ BLUE target after the answer, not proof all reach/attack together.',
      '- Kill checkpoints use RED-to-act snapshots (after BLUE, before RED). Terminal states are carried for already-finished wins and reported separately. Non-HQ only.',
      '- Burst = >=2 destroyed BLUE non-HQ targets in recorded RED actions in one turn. Preburst window is five preceding decision turns, excluding burst turn. This is association, not causality.',
      '', '## Tier and phase metrics',
      '| Cohort | Tier | Phase | Rows | Empty % | Supplied mean | Changed mean | Dead-target retarget | Mean max focus |',
      '|---|---|---|---:|---:|---:|---:|---:|---:|']
    for src,tiers in summary.items():
        for tier,phases in tiers.items():
            for ph,m in phases.items():
                if m:report.append(f"| {src} | {tier} | {ph} | {m['rows']} | {m['empty_pct']} | {m['supplied_orders_mean']} | {m['changed_orders_mean']} | {m['retarget_live']}/{m['stale_unit_opportunities']} | {m['focus_max_mean']} |")
    report+=['','## Victory counts and kill progress','| Cohort | Tier | Wins | T20 kills % | T30 kills % | T40 kills % |','|---|---|---:|---:|---:|---:|']
    for src in ('grind','teacher40'):
        for tier in ('BASIC','INTER','ADV'):
            gs=[g for g in games if g['source']==src and g['tier']==tier]
            if not gs:continue
            vals=[]
            for t in ('20','30','40'):
                cs=[g['checkpoints'][t] for g in gs if g['checkpoints'][t]['kills'] is not None]
                vals.append(f"{100*mean(c['kills']/c['initial'] for c in cs):.1f} ({sum(c['alive_at_turn'] for c in cs)} live / {sum(c['terminal_carried'] for c in cs)} terminal)")
            report.append(f"| {src} | {tier} | {len(gs)} | {' | '.join(vals)} |")
    for src in ('grind','teacher40'):
        ds=[d for d in decisions if d['source']==src];bs=[b for b in burst_rows if b['source']==src];late=[d for d in ds if d['turn']>=30]
        report+=['',f'## {src}: HQ, bursts and contested late-game proxies',
          f"- Wins {sum(g['source']==src for g in games)}; decisions {len(ds)}; missing snapshots {sum(not d['record_snapshot'] for d in ds)}.",
          f"- HQ orders: {dict(collections.Counter(v for d in ds for v in d['hq_orders']))}; new BLUE-HQ attacks/raids {sum(d['blue_hq_orders'] for d in ds)}; final RED HQ survivors {sum(g['red_hq_alive_final'] for g in games if g['source']==src)}.",
          f"- Visible HQ threat decisions (enemy eta_my_hq <=2): {sum(d['hq_threats']>0 for d in ds)}; responding with a genuinely changed HQ order or targeting a threat: {sum(d['hq_response'] for d in ds)}. Existing standing defense is not counted as a new response.",
          f"- Plans: T1 {sum(d['plan'] for d in ds if d['turn']==1)}/{sum(d['turn']==1 for d in ds)}; later {sum(d['plan'] for d in ds if d['turn']>1)}.",
          f"- Bursts {len(bs)}; preceding-window decisions {sum(b['preceding_rows'] for b in bs)}; changed orders {sum(b['preceding_changed_orders'] for b in bs)}; nonempty decisions {sum(b['preceding_nonempty'] for b in bs)}. Windows overlap; do not treat these as independent samples.",
          f"- T>=30 decisions {len(late)}; state/order proxy counts {dict(collections.Counter(v for d in late for v in d['late_proxies']))}. Counts are order occurrences except retarget/focus, which are decision occurrences; labels can overlap."]
    report+=['','## Observations and synthesis hypotheses',
      '- Observed rates above describe winners only; they do not prove the same answer wins another situation. Frequent empty late answers may be correct when standing attacks still reach targets, but stale targets create measurable idle-unit opportunities.',
      '- Grounded candidates should respond to actual absent-target orders, visible reachability, depleted own soldiers, target fieldworks, and live mission kills still required. Preserve successful focus unless a specific reachable alternative or HQ threat justifies changing it.',
      '- Pursuit-distance, cavalry target-class, fieldworks and withdrawal proxies motivate distinct candidate strategies; they do not prove flanking, encirclement or tactical improvement. Directional flanks require inspecting actual board geometry per situation.',
      '- HQ fortification is not automatically superior: observed HOLD/ATTACK and survival counts describe the winning baseline. Candidate HQ defense needs a visible threat or exposure.',
      '- Godot branch/control results are required for every authored variant. No inferred tactical proxy is a PASS label.',
      '', '## Missing facts and exclusions',json.dumps(exclusions,ensure_ascii=False),
      f'- Original answer issues: {len(answer_issues)}. Two malformed original JSON rows are recovered using the same collection parser as the actual served answers; no row is manufactured or omitted. Four non-dictionary nested plan orders are ignored for order metrics as the commander does. Raw harvest completions remain unchanged. Bank capture matching supplies independent served-answer provenance. Exact issues and recovered objects are in machine metrics.',
      '- Full row-level metrics, source record paths, checkpoints and burst windows are in `pattern_metrics_v3.json`. No paid service, training or GPU was used.']
    (OUT/'PATTERNS_V3.md').write_text('\n'.join(report)+'\n',encoding='utf-8')
    print(json.dumps({'games':len(games),'decisions':len(decisions),'exclusions':exclusions,'cohorts':dict(collections.Counter(g['source'] for g in games))}))

if __name__=='__main__':main()
