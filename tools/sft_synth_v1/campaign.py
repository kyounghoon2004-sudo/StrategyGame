"""Owned Godot arenas, CPU-only Hands boot, exact resident calls, no cloud or GPU calls.

python -m tools.sft_synth_v1.campaign --stage pilot --windows 5
The runner never kills or edits any pre-existing process or package.
"""
from __future__ import annotations
import argparse
import concurrent.futures
import hashlib
import json
import os
import secrets
import socket
import subprocess
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import unquote
import re

from .analyze import ROOT, OUT, sha
from .policy import POLICIES, decide
from tools.contextual_brain import rl_vs_utility as RV
from tools.plan_search.eval_plans import Hands
from tools.brain_review.harvest import post

HELDOUT=set(range(8831101,8831107))
BUCKETS=[(3,6),(7,11),(12,16),(17,25),(26,35)]
MISSION={'enemy_non_hq_destroy_share':.7,'rounding':'ceil','own_hq_loss':'defeat','enemy_hq_loss':'nonterminal','symmetric_collapse':True,'turn_cap':60}

def policy_sha(name):
    data=(ROOT/'tools/sft_synth_v1/policy.py').read_bytes()
    if name=='cohesive_focus':data+=(ROOT/'tools/sft_synth_v1/policy_v2.py').read_bytes()
    return sha(data)

def evaluate(messages,name,memory):
    if name=='cohesive_focus':
        from .policy_v2 import decide as v2_decide
        return v2_decide(messages,name,memory)
    return decide(messages,name,memory)

class CPUHands(Hands):
    def start(self):
        self.shutdown_token=secrets.token_hex(12)
        self.proc=subprocess.Popen([RV.LAYA_PY,'-u',str(ROOT/'tools/cloud_pipeline/hands_worker.py'),
            '--host','127.0.0.1','--port',str(self.port),'--device','cpu','--parent-pid',str(os.getpid()),
            '--shutdown-token',self.shutdown_token,'--log-file',str(self.dir/'hands_worker.log'),
            '--log-dir',str(self.dir/'runtime_logs')],stdout=(self.dir/'stdout.log').open('a'),stderr=subprocess.STDOUT)
        deadline=time.time()+180
        while not self.healthy():
            if time.time()>deadline or self.proc.poll() is not None:raise RuntimeError('Owned CPU Hands boot failed')
            time.sleep(.5)
        self.log(f'[SYNTH] CPU Hands READY port={self.port}; all new logs stay in this package')
    def stop(self):
        if self.proc is None or self.proc.poll() is not None:return
        try:
            post(self.port,'/shutdown',{'token':self.shutdown_token})
            self.proc.wait(timeout=15)
        except Exception:
            subprocess.run(['taskkill.exe','/PID',str(self.proc.pid),'/T','/F'],capture_output=True)

class SpeedArena(RV.Arena):
    """Time scale affects animation/timer pacing; parity must pass before bulk use."""
    def ensure(self):
        if self.proc is not None and self.proc.poll() is None:return
        for name in ['job.json','alive.json','idle_ack.json']:(self.dir/name).unlink(missing_ok=True)
        self.proc=subprocess.Popen([RV.GODOT,'--headless','--time-scale',str(self.speed),'--path',str(RV.ROOT),'-s','res://tools/rl_arena.gd'],
            env=dict(os.environ,RL_ARENA_DIR=str(self.dir),**self.env_extra),
            stdout=(self.dir/'godot.log').open('a',encoding='utf-8',errors='replace'),stderr=subprocess.STDOUT)
        deadline=time.time()+120
        while not (self.dir/'alive.json').exists():
            if time.time()>deadline or self.proc.poll() is not None:raise RuntimeError('Owned arena failed to boot')
            time.sleep(.1)
        self.log(f'[SYNTH] arena pid={self.proc.pid} {self.dir.name} time_scale={self.speed}')
    def quit(self):
        if self.proc is None or self.proc.poll() is not None:return
        self._job({'cmd':'quit'})
        try:self.proc.wait(timeout=25)
        except subprocess.TimeoutExpired:subprocess.run(['taskkill.exe','/PID',str(self.proc.pid),'/T','/F'],capture_output=True)
    def wait(self,out,timeout_s):
        deadline=time.time()+timeout_s+30
        while True:
            if out.exists():
                try:
                    json.loads(out.read_text(encoding='utf-8'))
                    return ''
                except (ValueError,OSError):pass  # Godot creates the file before store_string/close completes.
            if self.proc.poll() is not None:return f'arena exited rc={self.proc.returncode}'
            if time.time()>deadline:
                subprocess.run(['taskkill.exe','/PID',str(self.proc.pid),'/T','/F'],capture_output=True)
                return 'owned arena timeout; complete tree stopped'
            time.sleep(.2)

def occupied(port):
    with socket.socket() as s:return s.connect_ex(('127.0.0.1',port))==0

def victory(res,pov):
    import math
    snaps=(res.get('record') or {}).get('snapshots',[])
    if len(snaps)<2:return False,{'error':'missing snapshots'}
    def n(s,side,hq=False):return sum(u[1]==side and (u[2]=='hq')==hq and u[5]>0 for u in s)
    own=pov.lower();enemy='blue' if own=='red' else 'red';first=snaps[0]['units'];last=snaps[-1]['units']
    es=n(first,enemy);os_=n(first,own);ek=es-n(last,enemy);ok=os_-n(last,own)
    facts={'enemy_initial_non_hq':es,'own_initial_non_hq':os_,'enemy_destroyed':ek,'own_destroyed':ok,
           'threshold':math.ceil(.7*es),'own_hq_alive':n(last,own,True)==1}
    yes=res.get('outcome')==pov+'_WIN' and ek>=math.ceil(.7*es) and ok<math.ceil(.7*os_) and facts['own_hq_alive'] and not res.get('strict_fault') and res.get('turn_cap')==60
    return yes,facts

class Controller:
    def __init__(self,args,token):
        self.args=args;self.token=token;self.jobs={};self.memory={};self.lock=threading.Lock()
        self.raw=OUT/args.stage/'raw';self.raw.mkdir(parents=True,exist_ok=True)
    def log(self,name,row):
        with self.lock:
            with (self.raw/name).open('a',encoding='utf-8') as f:f.write(json.dumps(row,ensure_ascii=False,separators=(',',':'))+'\n')

def handler(controller):
    class H(BaseHTTPRequestHandler):
        def log_message(self,*a):pass
        def send(self,obj):
            b=json.dumps(obj,ensure_ascii=False,separators=(',',':')).encode();self.send_response(200)
            self.send_header('Content-Type','application/json');self.send_header('Content-Length',str(len(b)));self.end_headers();self.wfile.write(b)
        def do_GET(self):
            self.send({'ok':True,'label':'RL_POLICY','model':'rl_policy','rl_session':controller.token,'adapter_is_csft6':False})
        def do_POST(self):
            body=json.loads(self.rfile.read(int(self.headers['Content-Length'])))
            msgs=body.get('messages',[])
            if msgs and msgs[-1]['content']=='Reply with OK.':answer='OK'
            else:
                spec=unquote(self.headers.get('X-Episode-Spec-Path',''))
                m=re.search(r'_(w\d+)\.json$',spec)
                window=m[1] if m else None;job=controller.jobs.get(window)
                # The unused old mount asks an opening-plan request. Never send a model call.
                req=body.get('request') or ''
                if not job or not body.get('state') or 'VICTORY_COMMAND' not in str(body.get('state')):
                    answer='{}'
                else:
                    try:
                        memory=controller.memory.setdefault(job['game'],{})
                        doc,trace=evaluate(msgs,job['policy'],memory)
                        answer=json.dumps(doc,ensure_ascii=False,separators=(',',':'))
                        # Store the extra state only for independent legality/order audits. Never pass it to decide.
                        row={'game':job['game'],'request':'VICTORY_COMMAND','turn':body['state']['turn'],'messages':msgs,'raw':answer,
                             'state':body['state'],'trace':trace,'window':window,'policy':job['policy'],'source_sha256':policy_sha(job['policy'])}
                        controller.log('calls.jsonl',row)
                    except Exception as e:
                        controller.log('errors.jsonl',{'game':job['game'],'error':repr(e),'messages':msgs});answer='{"orders":{}}'
            self.send({'choices':[{'message':{'role':'assistant','content':answer}}]})
    return H

def build_jobs(stage):
    # A bounded first test: four pattern hypotheses on the SAME five new seeds.
    # Pilot seed range is disjoint from teacher, old data, validation and expansion ranges.
    if stage=='pilot':
        return [dict(game=f'{stage}_{p}_BASIC_n10_RED_s{seed}',policy=p,seed=seed,size=10,tier='BASIC',style='SPEARHEAD',family='fixed',pov='RED')
                for p in POLICIES for seed in range(8940001,8940006)]
    plan=OUT/(stage+'_jobs.json')
    if not plan.exists():raise SystemExit(f'Prepare {plan} from completed pilot gates first')
    return json.loads(plan.read_text(encoding='utf-8'))

def main():
    ap=argparse.ArgumentParser();ap.add_argument('--stage',default='pilot');ap.add_argument('--windows',type=int,default=5)
    ap.add_argument('--port',type=int,default=8098);ap.add_argument('--hands-slot',type=int,default=2)
    ap.add_argument('--max-games',type=int,default=0);ap.add_argument('--speed',type=float,default=1)
    ap.add_argument('--runtime',choices=['red','blue'],default='red');a=ap.parse_args()
    if a.speed!=1 and a.stage!='timing_check' and not (OUT/'timing_parity.json').exists():raise SystemExit('Accelerated pacing requires timing parity first')
    if occupied(a.port) or occupied(11460+a.hands_slot):raise SystemExit('Selected proxy or Hands slot is occupied; leave it alone')
    if a.windows<1 or a.windows>8:raise SystemExit('Use 1..8 arenas within the dedicated slot')
    jobs=build_jobs(a.stage);assert not any(j['seed'] in HELDOUT for j in jobs)
    # The copied teacher shell guards RED HQ only. Do not claim BLUE mission coverage
    # until a separate POV-correct snapshot has been implemented and validated.
    if any(j['pov']=='BLUE' for j in jobs) and a.runtime!='blue':raise SystemExit('BLUE requires the separately validated BLUE HQ-guard runtime')
    runtime=OUT/('runtime_blue' if a.runtime=='blue' else 'runtime')
    runtime_manifest=OUT/('runtime_blue_manifest.json' if a.runtime=='blue' else 'runtime_manifest.json')
    if a.runtime=='blue':
        probe=OUT/'blue_hq_contract_probe.json'
        if not probe.exists() or not json.loads(probe.read_text(encoding='utf-8')).get('pass'):raise SystemExit('BLUE HQ contract must pass actual Godot probe first')
    d=OUT/a.stage;d.mkdir(parents=True,exist_ok=True);(d/'games').mkdir(exist_ok=True)
    results=d/'results.jsonl'
    done={json.loads(l)['game'] for l in results.read_text(encoding='utf-8').splitlines() if l.strip()} if results.exists() else set()
    jobs=[j for j in jobs if j['game'] not in done]
    if a.max_games:jobs=jobs[:a.max_games]
    if not jobs:print('No unplayed jobs');return
    (d/'jobs.json').write_text(json.dumps(jobs,indent=2),encoding='utf-8')
    (d/'collector.pid').write_text(str(os.getpid()),encoding='utf-8')
    RV.ROOT=runtime;RV.OUT=d/'arenas';RV.OUT.mkdir(exist_ok=True)
    token=secrets.token_hex(12);c=Controller(a,token)
    server=ThreadingHTTPServer(('127.0.0.1',a.port),handler(c));threading.Thread(target=server.serve_forever,daemon=True).start()
    def log(s):
        print(s,flush=True)
        with c.lock:
            with (d/'collect.log').open('a',encoding='utf-8') as f:f.write(s+'\n')
    hands=CPUHands(a.hands_slot,d,log,'cpu')
    # hands_worker is a script in the production tools directory; its checkpoint loads are read-only.
    RV.ROOT=ROOT;hands.start();RV.ROOT=runtime
    from queue import Queue
    queue=Queue()
    for j in jobs:queue.put(j)
    arenas=[]
    try:
        for i in range(a.windows):
            env={'LAYA_URL':hands.url,'BRAIN_CONTRACT_MODE':'unalloc_v1','SELFPLAY_GENERAL_TIMEOUT_SEC':'1800',
                 'WATCH_STRATEGIC_REPLAN_TURNS':'0','WATCH_CMD_FACTS':'1','FIELD_FORTIFY':'1',
                 'WATCH_CMD_URL':f'http://127.0.0.1:{a.port}/v1/chat/completions','WATCH_CMD_URL_BLUE':f'http://127.0.0.1:{a.port}/v1/chat/completions',
                 'WATCH_BRAIN_PORT':str(a.port),'WATCH_PREFER_FEWER_LOSSES':'0','WATCH_MISSION':'remaining30_hq_guard',
                 'WATCH_ROUT_MIN':'0','WATCH_NO_HQ_WIN':'1','WATCH_RECENT_TURNS':'5','WATCH_COMPACT_AT':'10'}
            arena=SpeedArena(log,10+10*a.hands_slot+i,env,headless=True);arena.speed=a.speed;arenas.append(arena)
        def worker(ar):
            while not queue.empty() and not (OUT/'STOP').exists():
                try:j=queue.get_nowait()
                except Exception:return
                win=f'w{ar.idx}';c.jobs[win]=j
                ar.env_extra.update(WATCH_RED_MODE='COMMANDER' if j['pov']=='RED' else 'GX',WATCH_BLUE_MODE='GX' if j['pov']=='RED' else 'COMMANDER')
                # POV must stay constant per arena process; restart only our owned arena on a side change.
                if getattr(ar,'last_pov',j['pov'])!=j['pov']:ar.quit()
                ar.last_pov=j['pov']
                job={'family':j['family'],'seed':j['seed'],'tier':j['tier'],'style':j['style'],'red_style':j['style'],
                     'turn_cap':60,'session':token,'random_roster':True,'roster_sizes':f"{j['size']}-{j['size']}"}
                t=time.time();out=d/'games'/f"{j['game']}.json";err=ar.play(job,out,1800)
                res=json.loads(out.read_text(encoding='utf-8')) if out.exists() else {'error':err}
                won,facts=victory(res,j['pov']);row=j|facts|{'win':won,'kind':'WIN' if won else res.get('outcome','ERROR'),
                      'outcome':res.get('outcome'),'turn':res.get('turn'),'wall_s':round(time.time()-t,2),'error':res.get('error'),
                      'strict_fault':res.get('strict_fault'),'time_scale':a.speed,'runtime_version':a.runtime,'runtime_manifest_sha256':sha(runtime_manifest.read_bytes())}
                with c.lock:
                    with results.open('a',encoding='utf-8') as f:f.write(json.dumps(row,separators=(',',':'))+'\n')
                log(f"[SYNTH] {j['game']} {row['kind']} t={row['turn']} kills={facts.get('enemy_destroyed')}/{facts.get('enemy_initial_non_hq')} losses={facts.get('own_destroyed')} {row['wall_s']}s")
                queue.task_done()
        with concurrent.futures.ThreadPoolExecutor(max_workers=a.windows) as pool:
            futs=[pool.submit(worker,ar) for ar in arenas]
            for f in futs:f.result()
    finally:
        for ar in arenas:ar.quit()
        hands.stop();server.shutdown();server.server_close()
        (d/'STOPPED').write_text('Owned arenas and CPU worker stopped.',encoding='utf-8')
    (d/'DONE').write_text('All scheduled jobs terminated and resources stopped.',encoding='utf-8')
    print('Stage completed',flush=True)

if __name__=='__main__':main()
