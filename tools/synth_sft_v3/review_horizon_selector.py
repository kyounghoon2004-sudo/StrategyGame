"""Independent read-only CPU review using actual recorded short/native games."""
import hashlib
import inspect
import json
from pathlib import Path
from tools.synth_sft_v3.crosscheck import SYN,facts
from tools.synth_sft_v2.crosscheck import facts as v2facts

def counts(s):
    return {side:{'n':sum(u[1]==side and u[2]!='hq' for u in s['units']),
                  'soldiers':sum(u[5] for u in s['units'] if u[1]==side),
                  'hq':any(u[1]==side and u[2]=='hq' for u in s['units'])} for side in ('red','blue')}

def main():
    bank=json.loads((SYN/'bank_all_v3.json').read_text(encoding='utf-8'))
    old=SYN.parent/'synth_sft_v2/xcheck/pilot_r2'
    oldtests=[]
    for b in [json.loads(x) for x in (old/'branches.jsonl').read_text().splitlines()]:
        f=old/'games'/(b['id']+'.json')
        oldtests.append({'id':b['id'],'equal_v2_facts':v2facts(f,b['turn'])==facts(f,b['turn'],b['horizon'])})
    boundary=[];future=[]
    for gid,b in bank.items():
        f=Path(b['game_file']);g=json.loads(f.read_text(encoding='utf-8'))
        if g.get('outcome') not in ('RED_WIN','BLUE_WIN'):continue
        ft=g['turn'];h=8 if ft>=39 else 5
        t=ft-1-h
        if h != (8 if t>=30 else 5):continue
        snaps=g['record']['snapshots'];s0=next((s for s in snaps if s.get('turn')==t and s.get('to_act')=='red'),None)
        sb=next((s for s in snaps if s.get('turn')==ft and s.get('to_act')=='blue'),None)
        if s0 is None or sb is None:continue
        fx=facts(f,t,h)
        endpoint_blue_actions=[a for a in g['record']['actions']['blue'] if a.get('turn')==ft]
        desired_counts=counts(sb)
        entry={'game':gid,'source_file':str(f),'turn':t,'horizon':h,'cap':ft-1,'endpoint':ft,
          'current_facts':fx,'first_blue_endpoint_counts':desired_counts,'terminal_counts':counts(snaps[-1]),
          'endpoint_blue_actions':endpoint_blue_actions,'endpoint_units_equal_final':sb['units']==snaps[-1]['units'],
          'blue_future_kill_leaked':fx is not None and fx['kill']!=counts(s0)['blue']['n']-desired_counts['blue']['n'],
          'future_terminal_outcome_leaked':bool(endpoint_blue_actions) and sb['units']!=snaps[-1]['units'] and fx is not None and fx['outcome']==g['outcome']}
        boundary.append(entry)
        # One earlier, valid endpoint must not inherit a future full-game win.
        earlier=t-1
        if earlier>=1 and next((s for s in snaps if s.get('turn')==earlier and s.get('to_act')=='red'),None):
            earlier_h=8 if earlier>=30 else 5
            ef=facts(f,earlier,earlier_h)
            future.append({'game':gid,'turn':earlier,'horizon':earlier_h,'outcome':ef.get('outcome') if ef else None,'future_win_absent':ef is not None and ef['outcome']=='CAP'})
    gate=[]
    for f in (SYN/'replay_gate/production/games').glob('*.json'):
        g=json.loads(f.read_text(encoding='utf-8'));turn=1;h=5
        fx=facts(f,turn,h)
        gate.append({'file':str(f),'full_game_outcome':g.get('outcome'),'full_game_turn':g.get('turn'),'horizon_facts':fx})
    summary={'facts_function_sha256':hashlib.sha256(inspect.getsource(facts).encode()).hexdigest(),
       'old_shortcap_compared':len(oldtests),'old_shortcap_equal_v2':sum(t['equal_v2_facts'] for t in oldtests),
       'actual_terminal_boundary_records':len(boundary),'endpoint_future_actions_records':sum(bool(x['endpoint_blue_actions']) for x in boundary),
       'future_terminal_outcome_leaks':sum(x['future_terminal_outcome_leaked'] for x in boundary),
       'future_kill_leaks':sum(x['blue_future_kill_leaked'] for x in boundary),
       'earlier_native_endpoints_tested':len(future),'earlier_endpoints_future_win_absent':sum(x['future_win_absent'] for x in future),
       'native_gateB_files_reviewed':len(gate)}
    payload=dict(summary,boundary_records=boundary,earlier_endpoints=future,old_shortcap_tests=oldtests,native_gateB=gate)
    (SYN/'HORIZON_SELECTOR_REVIEW_V3.json').write_text(json.dumps(payload,indent=2),encoding='utf-8')
    example=next((x for x in boundary if x['game']=='s9300000_it01_r5'),None)
    md=['# Native-60 horizon selector independent review','',json.dumps(summary,indent=2),'',
      '## Actual-record counterexample',json.dumps(example,indent=2),'',
      '- At T27,H5 the evaluation finishes after RED32, immediately before BLUE33. The actual source record s9300000_it01_r5 has B_CAV_1 alive with one soldier in the BLUE33 snapshot. Its BLUE33 attack then dies to a RED counter, causing RED_WIN. A final snapshot after that action is outside the evaluation horizon.',
      '- The first inspected revision only replaced the final snapshot when g.turn>cap+1. Equality leaked both the future mission kill and the RED_WIN exception in the actual counterexample. Replay worker then repaired the selector to use >=, the first endpoint BLUE snapshot, and phase/action evidence. Current tested function hash and leak counts above describe the repaired revision.',
      '- A genuine RED victory completed by RED at cap can also be stored with final turn cap+1. Its endpoint BLUE snapshot already equals the terminal winning state and has no subsequent BLUE action. Do not replace every boundary terminal win with CAP without distinguishing these two actual cases.',
      '- Earlier endpoints and old shortcap comparisons are counted separately; this is a boundary-specific defect, not evidence that all normal horizon selections fail.',
      '- Repaired behavior selects the earliest BLUE-to-act cap+1 snapshot whenever it exists. Terminal outcome is retained only when no future actions occurred and terminal units match the selected state; otherwise CAP. Attack counters remain restricted to turns T through cap. Boundary examples use the required H5 before T30 and H8 at/after T30.',
      '- Read-only CPU review of actual source/branch records. No game execution, fabricated game state, rule change or input mutation. Replay worker owns fixes.']
    (SYN/'HORIZON_SELECTOR_REVIEW_V3.md').write_text('\n'.join(md)+'\n',encoding='utf-8')
    print(json.dumps(summary))

if __name__=='__main__':main()
