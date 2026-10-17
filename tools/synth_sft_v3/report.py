"""Rebuild cumulative audit reports from durable V3 artifacts; CPU only."""
import json
from collections import Counter, defaultdict
from datetime import datetime
from pathlib import Path

OUT = Path(__file__).resolve().parents[2] / 'artifacts/brain_pipeline_v1/synth_sft_v3'

def jl(name):
    p = OUT / name
    return [json.loads(s) for s in p.read_text(encoding='utf-8-sig').splitlines() if s.strip()] if p.exists() else []

def phase(turn):
    return 'T1' if turn == 1 else 'T2–10' if turn <= 10 else 'T11–30' if turn <= 30 else 'T31+'

def main():
    authored = jl('authored_v3.jsonl')
    selected = [x for x in authored if x.get('status') != 'AUTHOR_REJECTED']
    drafts = [x for x in authored if x.get('status') == 'AUTHOR_REJECTED']
    allx = jl('crosscheck_v3.jsonl')
    latest = {(x['sid'], x['variant']): x for x in allx}
    situations = {s['id']: s for s in jl('situations_grind.jsonl')}
    situations.update({s['id']: s for s in jl('situations_late_v3.jsonl')})
    lookup = {(x['sid'], x['variant']): x for x in authored}
    bank_path = OUT / 'bank_grind.json'
    bank = json.loads(bank_path.read_text(encoding='utf-8')) if bank_path.exists() else {}
    product_path = OUT / 'synth_rows_v3_verified.json'
    product = json.loads(product_path.read_text(encoding='utf-8')) if product_path.exists() else []
    counts = Counter(x.get('status', 'PASS' if x.get('pass') else 'FAIL') for x in latest.values())
    verified = counts['PASS'] + counts['FAIL']
    comparisons = []
    for runtime in ('frozen', 'frozen_wire', 'production'):
        p = OUT / 'replay_gate' / runtime / 'comparison.json'
        if p.exists():
            comparisons.extend(json.loads(p.read_text(encoding='utf-8')))
    gate = any(sum(r['exact'] for r in comparisons if r['runtime'] == mode) == 3 for mode in ('frozen', 'frozen_wire', 'production'))
    now = datetime.now().astimezone().isoformat()
    stage = 'Gate B pending or failed; authoring forbidden' if not gate else 'Gate B passed; production/verification in progress'
    if gate and (OUT/'STOP').exists():
        stage='Gate B passed; branch replay diagnostics/reconfiguration; next batches held'
    lines = [f'# Synthetic SFT V3 — {now}', '', f'Stage: {stage}',
             f'Grind winning bank: {len(bank)} games; all source situations: {len(situations)} (including stalled sources).',
             f'Selected candidates: {len(selected)}; all preserved proposals: {len(authored)}; rejected drafts: {len(drafts)}; verified: {verified}; PASS: {counts["PASS"]}; FAIL: {counts["FAIL"]}; TECHNICAL: {counts["TECHNICAL"]}.',
             f'Final admitted rows: {len(product)}.', '', 'CPU only. No training/model service launched. Slots 6/7 only.']
    (OUT / 'STATUS.md').write_text('\n'.join(lines)+'\n', encoding='utf-8')
    report = ['# V3 검증 보고서', '', f'갱신: {now}', '', f'- 실제 승리 뱅크: {len(bank)}게임 / {len(situations)}상황',
              f'- 실행 대상으로 작성한 후보: {len(selected)}개 / 상황: {len({x["sid"] for x in selected})}개',
              f'- 보존된 전체 제안: {len(authored)}개 (작성 단계 제외 초안 {len(drafts)}개 포함)',
              f'- 전술 검증: {verified}개 / 통과: {counts["PASS"]} / 실패: {counts["FAIL"]} / 기술 오류: {counts["TECHNICAL"]}',
              f'- 전체 전술 기준 통과율: {100*counts["PASS"]/verified:.2f}%' if verified else '- 전체 전술 통과율: 미측정',
              f'- 최종 데이터: {len(product)}행 (무접촉·무변경·중복 제외)', '', '## 재현 정확성', '']
    primary = Counter(x.get('primary_category','unknown') for x in selected)
    report.extend(['', '작성 후보의 기본 배분: '+str(dict(primary))])
    for r in comparisons:
        report.append(f'- {r["runtime"]} / {r["tier"]} / {r["game"]}: {"일치" if r["exact"] else "불일치"}; 원본 {r["expected"]}; 재현 {r["actual"]}; 기술 오류 {r.get("technical_error")}')
    if not gate:
        report.extend(['', '재현 게이트 미통과: 합성 답변 작성과 후보 검증을 진행하지 않음.'])
    report.extend(['', '## 티어·단계·패턴·변형별 통과율', '', '| 구분 | 값 | 검증 | 통과 | 통과율 |', '|---|---|---:|---:|---:|'])
    groups = defaultdict(Counter)
    for key, x in latest.items():
        if x.get('status') == 'TECHNICAL':
            continue
        s, a = situations.get(x['sid'], {}), lookup.get(key, {})
        for dim, value in [('tier', s.get('tier','unknown')), ('phase', phase(s.get('turn',0))), ('pattern', a.get('pattern','unknown')), ('variant', x['variant'])]:
            groups[(dim,value)]['n'] += 1
            groups[(dim,value)]['pass'] += bool(x.get('pass'))
    for (dim,value), c in sorted(groups.items()):
        report.append(f'| {dim} | {value} | {c["n"]} | {c["pass"]} | {100*c["pass"]/c["n"]:.2f}% |')
    reasons = Counter(x.get('why') for x in latest.values())
    no_contact = sum(bool(x.get('no_contact')) for x in latest.values())
    draft_reasons=Counter(reason for x in drafts for reason in x.get('author_rejection_reasons',[]))
    late = [x for x in latest.values() if situations.get(x['sid'],{}).get('turn',0)>=30 and x.get('status')!='TECHNICAL']
    report.extend(['', '## 대조군과 제외 사유', '', f'- 실제 대조군 결과: {len(jl("controls_v3.jsonl"))}상황',
                   f'- 판정 사유: {dict(reasons)}', f'- 무접촉 제외: {no_contact}',
                   f'- 초안 제외 사유(중복 이유 가능): {dict(draft_reasons)}',
                   f'- T≥30 검증: {len(late)} / 통과: {sum(bool(x.get("pass")) for x in late)}',
                   f'- 기술 오류 시도 기록: {sum(x.get("status")=="TECHNICAL" for x in allx)} (전술 실패에 미포함)',
                   '', '원본 60턴 임무 프롬프트를 유지한다. 각 후보와 대조군은 각자 분기의 T 및 검증 구간 종료 상태로 계산한다. H=5(T<30), H=8(T≥30), 종료 경계는 기존 V2와 동일하다.',
                   '검증 구간 이후의 게임 승리는 해당 후보의 승리 예외로 사용하지 않는다.',
                   'RED HQ 생존 및 V2 격파-손실/병력 손실률 기준을 유지한다. RED_WIN 예외는 V2와 동일하다.',
                   '', '## 한계', '', '작성 또는 대기 중인 후보는 통과 데이터가 아니다. 상세 원본·배제·재현 진단은 V3 audit JSON 파일을 참조한다.',
                   '작성기는 일곱 가지 상태 기반 전술 가설을 적용했다. 전투 예측이 없는 공격 점수는 휴리스틱이며 실제 피해 예측으로 주장하지 않는다.',
                   '무반격 사격 기회가 있는 궁수 철수 401건은 작성 감사의 미검증 우려다. 전술 실패 여부는 실제 엔진 결과로 판정한다.'])
    (OUT / 'VERIFY_REPORT_V3.md').write_text('\n'.join(report)+'\n', encoding='utf-8')
    print(json.dumps({'stage': stage, 'authored': len(authored), 'verified': verified, 'counts': dict(counts), 'admitted': len(product)}))

if __name__ == '__main__':
    main()
