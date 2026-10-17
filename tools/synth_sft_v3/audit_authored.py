"""Read-only CPU audit of frozen selected authored candidates and source prompts."""
import collections
import hashlib
import itertools
import json
import re
from statistics import mean
from tools.synth_sft_v3.crosscheck import SYN, jl, check
from tools.synth_sft_v3.grind_bank import BP
from tools.synth_sft_v3.view import parse_now

def main():
    parts=sorted((SYN/'parts').glob('v3_[0-9][0-9].jsonl'))
    rows=[r for p in parts for r in jl(p)]
    assignments={r['sid']:r for p in (SYN/'assignments').glob('v3_[0-9][0-9].jsonl') for r in jl(p)}
    grouped=collections.defaultdict(list)
    by_tier=collections.Counter();by_phase=collections.Counter();patterns=collections.Counter();primary=collections.Counter()
    empty=0;plans=collections.Counter();invalid=[];same=0;pair_differences=[];changed_counts=[];target_count=[];group_sizes=[]
    seen=set();duplicates=[];canonical_orders=set();archer_risks=[];forecast_available=0;forecast_total=0
    bank=json.loads((SYN/'bank_all_v3.json').read_text(encoding='utf-8'))
    filecache={};message_audit=[]
    for sid,item in assignments.items():
        s=item['situation'];b=bank[s['game']]
        if s['source']=='seed_grind':
            filename,index=b['rows'][str(s['turn'])]
            filename=str(BP/filename)
            if filename not in filecache:filecache[filename]=json.loads(open(filename,encoding='utf-8').read())
            original=filecache[filename][index]
        else:
            filename=b['raw_calls_file']
            if filename not in filecache:filecache[filename]=jl(__import__('pathlib').Path(filename))
            tag=s['game'].split('__collapse_',1)[1]
            matches=[c for c in filecache[filename] if c.get('tag')==tag and c.get('turn')==s['turn'] and c.get('request')=='VICTORY_COMMAND' and c.get('served')=='LOCAL']
            original=matches[-1] if matches else {}
        message_audit.append({'sid':sid,'messages_exact':s['messages']==original.get('messages'),'source_file':filename,
          'messages_sha256':hashlib.sha256(json.dumps(s['messages'],ensure_ascii=False,sort_keys=True).encode()).hexdigest()})
    for r in rows:
        s=assignments[r['sid']]['situation'];a=json.loads(r['answer']);orders=a['orders'];grouped[r['sid']].append(r)
        by_tier[s['tier']]+=1;ph='T1' if s['turn']==1 else 'T2-10' if s['turn']<=10 else 'T11-30' if s['turn']<=30 else 'T31+'
        by_phase[ph]+=1;patterns[r['pattern']]+=1;primary[r['primary_category']]+=1
        empty+=not orders;plans['T1' if s['turn']==1 else 'later']+=bool(a.get('plan'))
        changed_counts.append(sum(o!=s['standing_orders'].get(u,{'do':'HOLD'}) for u,o in orders.items()))
        key=(r['sid'],json.dumps(a,sort_keys=True));okey=json.dumps(orders,sort_keys=True)
        if key in seen:duplicates.append({'sid':r['sid'],'variant':r['variant']})
        seen.add(key);canonical_orders.add(okey)
        probs=check(s,r['answer'])
        if probs:invalid.append({'sid':r['sid'],'variant':r['variant'],'problems':probs})
        attacks=collections.Counter(o['target'] for o in orders.values() if o['do'] in ('ATTACK','RAID'))
        target_count.append(len(attacks));group_sizes.extend(attacks.values())
        op,mine,blue=parse_now(s)
        for uid,o in orders.items():
            if o['do'] not in ('ATTACK','RAID'):continue
            forecast_total+=1
            extra=mine[uid]['extra']
            if s['turn']==1:extra='; '.join(next(u for u in op['my_units'] if u['id']==uid).get('vs',[]))
            if re.search(re.escape(o['target'])+r' eta \d+ dealt \d+-\d+ taken \d+-\d+',extra):forecast_available+=1
        if r['pattern']=='withdraw_damaged_reform_focus':
            for uid,o in orders.items():
                if o['do']=='MOVE' and mine[uid]['cls']=='ARCHER' and re.search(r'taken 0-0',mine[uid]['extra']):
                    archer_risks.append({'sid':r['sid'],'variant':r['variant'],'unit':uid,'extra':mine[uid]['extra']})
    for sid,rs in grouped.items():
        for a,b in itertools.combinations(rs,2):
            oa=json.loads(a['answer'])['orders'];ob=json.loads(b['answer'])['orders'];u=set(oa)|set(ob)
            diff=sum(oa.get(k)!=ob.get(k) for k in u);same+=diff==0;pair_differences.append(diff)
    drafts=[r for p in (SYN/'parts').glob('v3_*_rejected.jsonl') for r in jl(p)]
    no_selected=[{'sid':sid,'reason':'state-conditioned solver found no genuinely changed applicable order vector',
      'draft_rejections':[r.get('rejection_reasons',[]) for r in drafts if r['sid']==sid]} for sid in assignments if sid not in grouped]
    summary={'selected_candidates':len(rows),'situations':len(grouped),'games':len({assignments[s]['situation']['game'] for s in grouped}),
      'authored_draft_proposals':len(drafts),'total_proposals_selected_plus_draft':len(rows)+len(drafts),
      'primary_counts':dict(primary),'primary_percentages':{k:round(100*v/len(rows),3) for k,v in primary.items()},
      'tier_counts':dict(by_tier),'phase_counts':dict(by_phase),'pattern_counts':dict(patterns),'empty_answers':empty,
      'T1_situations':sum(assignments[s]['situation']['turn']==1 for s in grouped),'T1_plan_answers':plans['T1'],'later_plan_answers':plans['later'],
      'changed_units_mean':round(mean(changed_counts),3),'changed_units_histogram':dict(sorted(collections.Counter(changed_counts).items())),
      'exact_situation_answer_duplicates':duplicates,'invalid_answers':invalid,'same_orders_different_variants_pairs':same,
      'pairwise_changed_unit_hamming_mean':round(mean(pair_differences),3),'pairwise_changed_unit_hamming_histogram':dict(sorted(collections.Counter(pair_differences).items())),
      'distinct_order_vectors_across_all_situations':len(canonical_orders),'distinct_target_count_histogram':dict(sorted(collections.Counter(target_count).items())),
      'new_attack_group_size_histogram':dict(sorted(collections.Counter(group_sizes).items())),
      'attack_order_current_preview_available':forecast_available,'attack_orders_total':forecast_total,
      'archer_withdraw_zero_counter_preview_occurrences':len(archer_risks),
      'original_messages_exact_situations':sum(r['messages_exact'] for r in message_audit),
      'original_messages_mismatches':[r['sid'] for r in message_audit if not r['messages_exact']],
      'selected_situations_without_valid_candidate':no_selected,
      'frozen_part_hashes':{p.name:hashlib.sha256(p.read_bytes()).hexdigest() for p in parts},
      'solver_family_count':7,'verification_status':'UNVERIFIED_AUTHOR_AUDIT_ONLY'}
    payload=dict(summary,source_message_audit=message_audit,archer_withdraw_concern=archer_risks)
    (SYN/'author_audit_v3.json').write_text(json.dumps(payload,ensure_ascii=False,indent=2),encoding='utf-8')
    report=['# Author audit V3: frozen selected candidates','',
      f"Selected {len(rows)} candidates / {len(grouped)} exact source situations / {summary['games']} games. Rejected or surplus drafts {len(drafts)}; all proposals {len(rows)+len(drafts)}. Selected inputs frozen; this audit makes no engine PASS claims.",
      '', '| Primary allocation | Selected answers | Share |','|---|---:|---:|']
    for k,v in primary.items():report.append(f'| {k} | {v} | {100*v/len(rows):.2f}% |')
    report+=['','- Allocation quotas were imposed on situations (40/35/15/10); candidate shares differ slightly because tactical applicability yields two or three valid variants.',
      f'- Tier counts: {dict(by_tier)}. Phase counts: {dict(by_phase)}. Pattern counts: {dict(patterns)}.',
      f'- Assigned situations with no selected valid candidate: {no_selected}. No candidate was manufactured to fill this gap.',
      f"- Empty answers {empty}; invalid answers {len(invalid)}; exact situation/answer duplicates {len(duplicates)}. T1 plans {plans['T1']} answers / {summary['T1_situations']} situations; later plan answers {plans['later']}.",
      f"- Source messages match original winning harvest or accepted LOCAL call messages in {summary['original_messages_exact_situations']}/{len(assignments)} situations. Per-situation source paths and hashes are retained in JSON; no prompt hints were added.",
      '', '## Tactical difference measurements',
      f"- Changed own units per selected answer: mean {summary['changed_units_mean']}; histogram {summary['changed_units_histogram']}.",
      f"- Same-situation variant pairs with identical tactical order objects: {same}. Pairwise unit-order differences mean {summary['pairwise_changed_unit_hamming_mean']}; histogram {summary['pairwise_changed_unit_hamming_histogram']}. Plan wording is excluded from this comparison.",
      f"- Distinct order vectors across the entire dataset: {len(canonical_orders)}. Own/enemy IDs can repeat between games, so this global count is descriptive; within-situation comparison is stronger evidence of tactical differences.",
      f"- Distinct newly ordered attack targets per answer: {summary['distinct_target_count_histogram']}. New attack group sizes: {summary['new_attack_group_size_histogram']}. These describe issued changes, not the full standing army allocation.",
      '', '## Seven state-conditioned solver families and limits',
      '1. Dead-target repair changes only idle attackers to live reachable enemies, favoring an existing focus group.',
      '2. Coordinated finishing assigns healthy reachable attackers to one live target ranked by combined forecasts, distance and visible troop bands.',
      '3. Matchup pressure allocates class-favored attackers across two or three actual targets while penalizing excessive group loading.',
      '4. Damaged-unit withdrawal sends exposed low-strength units toward a current friendly rear position while healthier units attack.',
      '5. Cavalry soft-target raids allocate actual cavalry against visible archers/scouts, with MY_HQ return direction and support attacks.',
      '6. Fieldworks breaking coordinates healthy ranged/melee hitters on one actual fortified non-HQ target.',
      '7. HQ interception applies only when a visible enemy eta_my_hq<=2; nearby healthy defenders intercept while the rest continue mission attacks.',
      '- This is a deterministic heuristic authoring solver with seven strategy families, not independent LLM authors or a proven tactical planner. Actual state changes determine units, targets, attack grouping, withdrawal locations and family applicability. The zero identical-order pair count rules out cosmetic-only sibling variations; it does not prove broad strategy novelty or tactical usefulness.',
      f'- Actual outgoing combat preview available for {forecast_available}/{forecast_total} selected attack/raid changes. Else authoring uses a rough heuristic: soldier strength times a damage factor and class matchup, estimated counter loss from visible troop-band midpoint, distance-based ETA and fieldworks ranking. These fallback scores are hypotheses and are not engine combat simulation.',
      '- Exact preview ranges themselves reflect outgoing strikes, not all future BLUE attacks or blocked movement. Distance estimates ignore unit congestion. MOVE destinations are copied from actual friendly positions, which can be occupied and approached rather than entered.',
      '', '## Known unverified concern',
      f'- {len(archer_risks)} selected withdrawal orders affect an ARCHER whose current packet contains at least one zero-counter preview. V2 warned that pulling a depleted archer out of safe shooting range can discard valuable damage. Such previews alone do not prove safety from BLUE next-turn attacks. These are flagged for engine/control evaluation, not marked FAIL or edited after freezing.',
      '- Only Godot branch/control outcomes may retain a row as PASS. No-contact and no-op examples must be excluded from the verified product. Rejected/surplus drafts remain audit-only and are not scheduled for verification.',
      '- CPU-only audit; no model calls, GPU, game execution, training or input mutation.']
    (SYN/'AUTHOR_AUDIT_V3.md').write_text('\n'.join(report)+'\n',encoding='utf-8')
    print(json.dumps({k:v for k,v in summary.items() if k not in ('frozen_part_hashes','changed_units_histogram','pairwise_changed_unit_hamming_histogram','new_attack_group_size_histogram')}))

if __name__=='__main__':main()
