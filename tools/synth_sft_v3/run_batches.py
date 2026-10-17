"""Durable CPU-only V3 verification scheduler. Never authors or trains.

Completed parts/v3_*.jsonl are ingested; parts/AUTHORING_DONE closes the queue.
Only slots 6/7 are used, one branch process per slot, windows=10. Judges are
serialized here. Resume uses scheduler.json and engine results, never recreates
completed battles. STOP drains active jobs before exiting.
"""
from __future__ import annotations
import argparse
import collections
import hashlib
import json
import msvcrt
import os
import re
import socket
import subprocess
import sys
import time
from pathlib import Path
from tools.synth_sft_v3 import crosscheck as X

ROOT=Path(__file__).resolve().parents[2]
OUT=X.SYN
PY=r'D:\StrategyAI\runtimes\qwen3_8b_rl_v0\.venv\Scripts\python.exe'
MANIFEST=OUT/'scheduler.json'

def atomic(path, value):
    tmp=path.with_suffix(path.suffix+'.tmp')
    tmp.write_text(json.dumps(value,ensure_ascii=False,indent=2),encoding='utf-8')
    tmp.replace(path)

def append(path, rows):
    with path.open('a',encoding='utf-8') as f:
        for r in rows: f.write(json.dumps(r,ensure_ascii=False)+'\n')

def log(msg):
    print(time.strftime('%m-%d %H:%M:%S ')+msg,flush=True)

def persist(state):
    state['updated_at']=time.strftime('%Y-%m-%d %H:%M:%S')
    atomic(MANIFEST,state)

def ingest(state, batch_size):
    new_parts=[p for p in (OUT/'parts').glob('v3_*.jsonl') if re.fullmatch(r'v3_\d+\.jsonl',p.name) and p.name not in state['parts']]
    if not new_parts:
        return
    sit=X.situations()
    existing=X.jl(OUT/'authored_v3.jsonl')
    have={(r['sid'],r['variant']) for r in existing}
    semantics={(r['sid'],json.dumps(json.loads(r['answer']),sort_keys=True)) for r in existing if isinstance(r.get('answer'),str) and safe_json(r['answer'])}
    for part in sorted((OUT/'parts').glob('v3_*.jsonl')):
        if not re.fullmatch(r'v3_\d+\.jsonl',part.name):
            continue
        digest=hashlib.sha256(part.read_bytes()).hexdigest()
        if str(part.name) in state['parts']:
            if state['parts'][part.name]['sha256']!=digest:
                raise RuntimeError('Completed author part changed: '+str(part))
            continue
        rows=X.jl(part); valid=[]; rejected=[]; saved=[]
        for r in rows:
            key=(r.get('sid'),r.get('variant'))
            if key in have:
                rejected.append(dict(r,exclusion='duplicate_sid_variant',part=part.name))
                continue
            saved.append(dict(r,part=part.name)); have.add(key)
            probs=['unknown situation'] if r.get('sid') not in sit else X.check(sit[r['sid']],r.get('answer'))
            if not probs:
                sem=(r['sid'],json.dumps(json.loads(r['answer']),sort_keys=True))
                if sem in semantics: probs=['identical_situation_answer_duplicate']
                semantics.add(sem)
            if probs:
                rejected.append(dict(r,exclusion='invalid_or_duplicate',problems=probs,part=part.name))
            else: valid.append(dict(r,part=part.name))
        append(OUT/'authored_v3.jsonl',saved)
        append(OUT/'author_exclusions_v3.jsonl',rejected)
        # Each complete situation stays together; select late batches first but
        # queue selection below round-robins primary categories.
        groups=collections.defaultdict(list)
        for r in valid: groups[r['sid']].append(r)
        groups=sorted(groups.values(),key=lambda g:(-int(sit[g[0]['sid']]['turn']>=30),g[0]['sid']))
        names=[]
        for i in range(0,len(groups),batch_size):
            name=f"{part.stem}_b{i//batch_size:03d}"
            chosen=[r for group in groups[i:i+batch_size] for r in group]
            file=OUT/'parts'/(name+'.valid.jsonl')
            file.write_text(''.join(json.dumps(r,ensure_ascii=False)+'\n' for r in chosen),encoding='utf-8')
            X.cmd_prepare(name,str(file))
            cat=collections.Counter(r.get('primary_category',r.get('category','unspecified')) for r in chosen).most_common(1)[0][0]
            state['batches'][name]={'status':'pending','part':part.name,'category':cat,'candidates':len(chosen),'attempts':0}
            names.append(name)
        state['parts'][part.name]={'sha256':digest,'rows':len(rows),'valid':len(valid),'excluded':len(rejected),'batches':names}
        persist(state)
        log(f'INGEST {part.name}: {len(rows)} authored, {len(valid)} valid, {len(rejected)} exclusions, {len(names)} batches')
        return  # Start available jobs promptly before ingesting the next part.

def safe_json(text):
    try: json.loads(text); return True
    except (ValueError,TypeError): return False

def free(slot):
    for port in (8120+slot,8130+slot,11460+slot):
        with socket.socket() as s:
            if s.connect_ex(('127.0.0.1',port))==0: return False
    return True

def technical_branches(name):
    d=OUT/'xcheck'/name
    source=X.situations()
    bank=json.loads((OUT/'bank_all_v3.json').read_text(encoding='utf-8'))
    controls={r['sid'] for r in X.jl(OUT/'controls_v3.jsonl')}
    bad=[]
    for b in X.jl(d/'branches.jsonl'):
        f=d/'games'/(b['id']+'.json')
        if X.facts(f,b['turn'],b['horizon']) is None:
            bad.append((b,'missing_or_invalid_game')); continue
        if not X.source_state_exact(bank,b['game'],b['turn'],f):
            bad.append((b,'replay_source_state_mismatch')); continue
        if b['id'].startswith(('V__','C__')):
            sid=b['id'][3:].rsplit('__',1)[0] if b['id'].startswith('V__') else b['id'][3:]
            request=d/'requests'/(b['id']+'.json')
            try: msgs=json.loads(request.read_text(encoding='utf-8'))
            except (ValueError,OSError): msgs=None
            if msgs!=source[sid]['messages']: bad.append((b,'replay_prompt_mismatch'))
    return bad

def archive_retry(name, bad, attempt):
    d=OUT/'xcheck'/name; archive=d/'attempt_evidence'/f'attempt_{attempt:02d}'
    archive.mkdir(parents=True,exist_ok=True)
    ids={b['id'] for b,why in bad}
    atomic(archive/'technical.json',[dict(b,technical_reason=why) for b,why in bad])
    for b,why in bad:
        for folder in ('games','requests'):
            f=d/folder/(b['id']+'.json')
            if f.exists():
                target=archive/folder; target.mkdir(exist_ok=True)
                f.rename(target/f.name)
    results=d/'results.jsonl'; rows=X.jl(results)
    append(archive/'results.jsonl',[r for r in rows if r.get('game') in ids])
    results.write_text(''.join(json.dumps(r,ensure_ascii=False)+'\n' for r in rows if r.get('game') not in ids),encoding='utf-8')

def report():
    if (ROOT/'tools/synth_sft_v3/report.py').exists():
        subprocess.run([PY,'-m','tools.synth_sft_v3.report'],cwd=ROOT,env=dict(os.environ,PYTHONIOENCODING='utf-8'),check=False)

def main():
    ap=argparse.ArgumentParser(); ap.add_argument('--batch-situations',type=int,default=30)
    ap.add_argument('--max-retries',type=int,default=3); ap.add_argument('--once',action='store_true')
    a=ap.parse_args(); (OUT/'parts').mkdir(exist_ok=True)
    # Prevent two schedulers from touching global ledgers or slots.
    lock=(OUT/'scheduler.lock').open('a+b')
    lock.seek(0); lock.write(b'1'); lock.flush(); lock.seek(0)
    msvcrt.locking(lock.fileno(),msvcrt.LK_NBLCK,1)
    state=json.loads(MANIFEST.read_text(encoding='utf-8')) if MANIFEST.exists() else {'parts':{},'batches':{},'last_category':None}
    active={}; last_report=time.time(); last_stream=time.time()
    for b in state['batches'].values():
        if b['status']=='running': b['status']='pending'
    while True:
        ingest(state,a.batch_situations)
        if active and time.time()-last_stream>=60:
            X.cmd_judge([name for name,p,f in active.values()],completed_only=True)
            report(); last_stream=time.time(); last_report=last_stream
        for slot,(name,p,f) in list(active.items()):
            if p.poll() is None: continue
            f.close(); del active[slot]
            b=state['batches'][name]
            X.cmd_judge([name])
            bad=technical_branches(name)
            b['last_exit_code']=p.returncode; b['technical_branches']=len(bad)
            if bad and b['attempts']<=a.max_retries:
                archive_retry(name,bad,b['attempts']); b['status']='pending'
                log(f'RETRY {name}: {len(bad)} technical branches preserved attempt{b["attempts"]}')
            else:
                b['status']='technical_unresolved' if bad else 'done'
                log(f'FINISHED {name}: {b["status"]}, {b["candidates"]} candidates')
            persist(state); report(); last_report=time.time()
        stopping=(OUT/'STOP').exists()
        pending=[(n,b) for n,b in state['batches'].items() if b['status']=='pending']
        if not stopping:
            for slot in (6,7):
                if slot in active or not pending or not free(slot): continue
                categories=list(dict.fromkeys(b['category'] for b in state['batches'].values()))
                start=(categories.index(state['last_category'])+1)%len(categories) if state['last_category'] in categories else 0
                ordered=categories[start:]+categories[:start]
                pick=next((item for category in ordered for item in pending if item[1]['category']==category),pending[0])
                name,b=pick; pending.remove(pick); d=OUT/'xcheck'/name
                b['attempts']+=1; b['status']='running'; b['slot']=slot
                state['last_category']=b['category']; persist(state)
                f=(d/f'branch_attempt_{b["attempts"]:02d}.log').open('a',encoding='utf-8')
                cmd=[PY,'-m','tools.synth_sft_v3.branch',str(d/'branches.jsonl'),str(d),'--bank',str(OUT/'bank_all_v3.json'),
                     '--windows','10','--slot',str(slot),'--proxy-port',str(8120+slot),'--brain-port',str(8130+slot),'--runtime','production',
                     '--manual-poll-s','0.05']
                p=subprocess.Popen(cmd,cwd=ROOT,env=dict(os.environ,PYTHONIOENCODING='utf-8'),stdout=f,stderr=subprocess.STDOUT)
                active[slot]=(name,p,f); log(f'START {name} slot{slot} attempt{b["attempts"]} pid{p.pid}')
        if time.time()-last_report>=1800: report(); last_report=time.time()
        author_done=(OUT/'parts/AUTHORING_DONE').exists()
        if not active and (stopping or (author_done or a.once) and not pending):
            report(); persist(state); log('SCHEDULER finished'); return
        time.sleep(2)

if __name__=='__main__': main()
