"""CPU-only forensic inspection of existing INTER branch artifacts."""
import hashlib
import json
import re
from pathlib import Path
from tools.synth_sft_v3.crosscheck import SYN,jl

def normalized_deadlines(messages):
    return [{'role':m['role'],'content':re.sub(r'("(?:turn_limit|turns_left)"\s*:\s*)-?\d+',r'\1DEADLINE',m['content'])} for m in messages]

def main():
    d=SYN/'xcheck/v3_05_b000';bs=jl(d/'branches.jsonl')
    ids={b['game']+'__t'+str(b['turn']) for b in bs}
    situations={s['id']:s for s in jl(SYN/'situations_grind.jsonl') if s['id'] in ids}
    bank=json.loads((SYN/'bank_all_v3.json').read_text(encoding='utf-8'))
    diagnostics=[];manual={}
    for f in (d/'manual').glob('req_*.json'):
        req=json.loads(f.read_text(encoding='utf-8'))
        resp=f.with_name(f.name.replace('req_','resp_')).with_suffix('.txt')
        if resp.exists():manual[req.get('tag'),req.get('turn')]=(req,resp.read_text(encoding='utf-8'))
    for b in bs:
        f=d/'requests'/(b['id']+'.json')
        if not f.exists():continue
        req=json.loads(f.read_text(encoding='utf-8'));s=situations[b['game']+'__t'+str(b['turn'])];orig=s['messages']
        differences=[]
        for i in range(max(len(orig),len(req))):
            a=orig[i] if i<len(orig) else {};c=req[i] if i<len(req) else {}
            if a==c:continue
            aa=a.get('content','');cc=c.get('content','')
            k=next((j for j,(x,y) in enumerate(zip(aa,cc)) if x!=y),min(len(aa),len(cc)))
            differences.append({'index':i,'original_role':a.get('role'),'branch_role':c.get('role'),'first_diff_character':k,
              'original_excerpt':aa[max(0,k-100):k+240],'branch_excerpt':cc[max(0,k-100):k+240]})
        entry={'id':b['id'],'game':b['game'],'turn':b['turn'],'horizon':b['horizon'],'message_lengths':[len(orig),len(req)],
          'exact_original_prompt':orig==req,'deadline_fields_only_difference':normalized_deadlines(orig)==normalized_deadlines(req),
          'differences':differences,'original_game_file':bank[b['game']]['game_file']}
        gf=d/'games'/(b['id']+'.json')
        if gf.exists():
            game=json.loads(gf.read_text(encoding='utf-8'));source=json.loads(Path(entry['original_game_file']).read_text(encoding='utf-8'))
            source_snaps={(x['turn'],x.get('to_act')):x for x in source['record']['snapshots'] if not x.get('final')}
            prefix=[x for x in game['record']['snapshots'] if not x.get('final') and (x['turn']<b['turn'] or x['turn']==b['turn'] and x.get('to_act') in ('blue','red'))]
            entry['prefix_snapshots_compared']=len(prefix)
            entry['prefix_snapshots_exact']=sum(x==source_snaps.get((x['turn'],x.get('to_act'))) for x in prefix)
            entry['initial_units_exact']=game['record']['snapshots'][0]['units']==source['record']['snapshots'][0]['units']
            branch_t=next((x for x in prefix if x['turn']==b['turn'] and x.get('to_act')=='red'),None)
            entry['branch_turn_units_exact']=branch_t is not None and branch_t['units']==source_snaps.get((b['turn'],'red'),{}).get('units')
            entry['snapshot_mismatches']=[{'turn':x['turn'],'to_act':x.get('to_act')} for x in prefix if x!=source_snaps.get((x['turn'],x.get('to_act')))]
            entry['branch_turn_cap']=game.get('turn_cap');entry['branch_outcome']=game.get('outcome')
        checks=[]
        for t in range(1,b['turn']):
            observed=manual.get((b['id'],t))
            if observed:
                checks.append({'turn':t,'response_exact_engine_answer':observed[1]==bank[b['game']]['engine_answers'][str(t)]})
        entry['prefix_wire_observed']=len(checks);entry['prefix_wire_exact']=sum(x['response_exact_engine_answer'] for x in checks)
        entry['prefix_wire_mismatches']=[x for x in checks if not x['response_exact_engine_answer']]
        diagnostics.append(entry)
    summary={'batch':d.name,'requests_inspected':len(diagnostics),'exact_prompts':sum(x['exact_original_prompt'] for x in diagnostics),
      'deadline_only_difference':sum(x['deadline_fields_only_difference'] for x in diagnostics),
      'completed_game_files':sum('prefix_snapshots_compared' in x for x in diagnostics),
      'initial_units_exact':sum(x.get('initial_units_exact',False) for x in diagnostics),
      'branch_turn_units_exact':sum(x.get('branch_turn_units_exact',False) for x in diagnostics),
      'prefix_snapshots_compared':sum(x.get('prefix_snapshots_compared',0) for x in diagnostics),
      'prefix_snapshots_exact':sum(x.get('prefix_snapshots_exact',0) for x in diagnostics),
      'prefix_wire_observed':sum(x['prefix_wire_observed'] for x in diagnostics),'prefix_wire_exact':sum(x['prefix_wire_exact'] for x in diagnostics),
      'cause':'branch job turn_cap=T+H changes WATCH_TURN_CAP, read by commander packet turn_limit and turns_left; full turn0 GateB replays used60 and did not exercise this coupling',
      'required_next_gate':'restore original 60-turn prompt facts without modifying original prompts, independently bound or select branch own T+H evaluation endpoint, rerun mismatched branches and demand byte-exact source prompts'}
    (SYN/'INTER_PROMPT_DIAGNOSTIC_V3.json').write_text(json.dumps(dict(summary,branches=diagnostics),indent=2),encoding='utf-8')
    md=['# INTER branch prompt diagnostic V3','',json.dumps(summary,indent=2),'',
      '## Concrete cause',
      '`branch.py` assigns job `turn_cap = min(60,T+H)`. The arena forwards this as `WATCH_TURN_CAP`; `commander_controller.gd` uses it directly for packet `turn_limit` and `turns_left`. Therefore a short verification horizon changes deadline facts in every retained user turn message, even before injecting the candidate.',
      'Example: s9500001_it01_r0 T29,H5 opening turn_limit60 becomes34; retained T22 turns_left39 becomes13. Original battle state, event history and exact wire answers can remain the same while the prompt differs.',
      'Gate B used turn0/full60 replays, so all three exact replays did not test short-horizon prompt identity.',
      '', '## Evidence and interpretation',
      '- Per-branch first differing message index, role, character and excerpts are in the JSON diagnostic.',
      '- Initial and all pre-injection snapshots and manual wire answers are compared to original records/bank engine_answers when corresponding completed files exist. This separates prompt deadline coupling from actual simulation divergence.',
      '- CPU read-only diagnosis. No Godot execution, rule change, original prompt rewrite or prompt-gate weakening was performed.',
      '- Deadline normalization above is diagnostic only; it is not an admissibility rule. Every retained training row must still pass exact original-message comparison after repair.']
    (SYN/'INTER_PROMPT_DIAGNOSTIC_V3.md').write_text('\n'.join(md)+'\n',encoding='utf-8')
    print(json.dumps(summary))

if __name__=='__main__':main()
