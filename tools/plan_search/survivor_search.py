"""Real-game search through the existing arena + manual collector proxy. No LLM calls."""
from __future__ import annotations
import argparse, collections, concurrent.futures, hashlib, json, os, queue, secrets, socket, subprocess, sys, threading, time, re
from pathlib import Path
from tools.contextual_brain import rl_vs_utility as RV
from tools.plan_search.eval_plans import Hands
from tools.brain_review.harvest import post, wait_port
from tools.plan_search.survivor_policy import decide, normalize, rationale

def dump(p,o): p.write_text(json.dumps(o,ensure_ascii=False,indent=2),encoding='utf8')
def digest(p):return hashlib.sha256(p.read_bytes()).hexdigest()
STYLES=['SPEARHEAD','BULWARK','OUTRIDER','HARRIER']
FAMILIES=['fixed','mild','broad','counterfactual_valid']

class Arena(RV.Arena):
    def __init__(self,log,idx,env,out):
        super().__init__(log,idx,env)
        self.dir=out/('arena_%d'%idx);self.dir.mkdir(parents=True,exist_ok=True)
    def ensure(self):
        if self.proc is not None and self.proc.poll() is None:return
        for f in ('job.json','alive.json','idle_ack.json'): (self.dir/f).unlink(missing_ok=True)
        self.proc=subprocess.Popen([RV.GODOT,'--headless','--path',str(RV.ROOT),'-s','res://tools/rl_arena.gd'],
            env=dict(os.environ,RL_ARENA_DIR=str(self.dir.resolve()),**self.env_extra),
            stdout=open(self.dir/'godot.log','a',encoding='utf8'),stderr=subprocess.STDOUT)
        deadline=time.time()+120
        while not (self.dir/'alive.json').exists():
            if time.time()>deadline or self.proc.poll() is not None:raise RuntimeError('arena failed')
            time.sleep(.2)
        self.log('arena up %s'%self.dir.name)

def readjsonl(path):
    if not path.exists():return []
    return [json.loads(l) for l in path.read_text(encoding='utf8').splitlines() if l.strip()]

def export(out,pop):
    results=readjsonl(out/'results.jsonl');by=collections.defaultdict(list)
    for r in results:by[(r['strategy'],r['tier'])].append(r)
    rankings=[];robust=set();weak=set()
    for (sid,tier),rr in sorted(by.items()):
        wins=[r for r in rr if r['kind']=='WIN'];wr=len(wins)/len(rr)
        varied=len({(r['style'],r['family'],r['seed']) for r in rr})==len(rr)
        strong=len(rr)>=5 and wr==1 and len({r['style'] for r in rr})==4 and len({r['family'] for r in rr})>=3 and varied
        category='robust' if strong else ('unstable' if len(rr)>1 and wins else 'single_run' if wins else 'rejected')
        (robust if strong else weak).add((sid,tier)) if wins else None
        red=lambda r:(r.get('units') or {}).get('red') or {}
        rank={'strategy':sid,'tier':tier,'family':pop[sid]['family'],'class':category,'games':len(rr),'wins':len(wins),
            'losses':len(rr)-len(wins),'win_rate':wr,'average_turns_to_victory':sum(r['turn'] for r in wins)/len(wins) if wins else None,
            'average_friendly_losses':sum(red(r).get('start',0)-red(r).get('alive',0) for r in rr)/len(rr),
            'average_surviving_friendly_units':sum(red(r).get('alive',0) for r in rr)/len(rr),
            'failure_modes':dict(collections.Counter(r['kind']+(':'+str((r.get('fault') or {}).get('code')) if r.get('fault') else '') for r in rr if r['kind']!='WIN')),
            'execution_diagnostics':[{'game':r['game'],**r.get('execution_diagnostics',{})} for r in rr],
            'settings':[{'game':r['game'],'style':r['style'],'family':r['family'],'seed':r['seed'],'kind':r['kind']} for r in rr]}
        rankings.append(rank)
    rankings.sort(key=lambda r:(r['tier'],r['class']!='robust',-r['win_rate'],r['average_turns_to_victory'] or 999,r['average_friendly_losses'],-r['average_surviving_friendly_units'],r['strategy']))
    dump(out/'ranking.json',rankings);dump(out/'robust_survivors.json',[r for r in rankings if r['class']=='robust'])
    dump(out/'weak_survivors.json',[r for r in rankings if r['class'] in ['single_run','unstable']])
    eligible={r['game']:r for r in results if r['kind']=='WIN' and (r['strategy'],r['tier']) in robust}
    weakgames={r['game']:r for r in results if r['kind']=='WIN' and (r['strategy'],r['tier']) in weak}
    main=[];weakrows=[];lineage=[];seen=set();audit={'replayed_decisions':0,'order_mismatches':0,'message_mismatches':0,'deduplicated_decisions':0,'llm_gameplay_calls':0}
    allgames={r['game']:r for r in results}
    requests=collections.defaultdict(list)
    for f in list(out.glob('slot_*/manual/req_*.json'))+list(out.glob('slot_*/manual_sessions/*/req_*.json')):
        req=json.loads(f.read_text(encoding='utf8'));requests[(req.get('tag'),req.get('turn'))].append(req['messages'])
    trajectories=collections.defaultdict(list)
    for raw in sorted(out.glob('slot_*/raw/calls.jsonl')):
        for c in readjsonl(raw):
            if c.get('request')=='VICTORY_COMMAND' and c['tag'] in eligible:
                pkt=json.loads(c['messages'][-1]['content'])
                state={k:v for k,v in pkt.items() if k not in ['current_plan','history','why_asked']}
                trajectories[c['tag']].append([state,json.loads(c['raw'])['orders']])
    duplicates=[];trajectory_seen={}
    for g,seq in trajectories.items():
        key=hashlib.sha256(json.dumps([eligible[g]['tier'],seq],sort_keys=True).encode()).hexdigest()
        if key in trajectory_seen:duplicates.append({'game':g,'equivalent_to':trajectory_seen[key],'fingerprint':key})
        else:trajectory_seen[key]=g
    excluded={d['game'] for d in duplicates};audit['deduplicated_trajectories']=len(duplicates)
    dump(out/'duplicate_trajectories.json',duplicates)
    for raw in sorted(out.glob('slot_*/raw/calls.jsonl')):
        for c in readjsonl(raw):
            if c.get('request')!='VICTORY_COMMAND':continue
            game=c['tag'];r=allgames[game];strategy=pop[r['strategy']];pkt=json.loads(c['messages'][-1]['content'])
            if c['messages'] not in requests[(game,c['turn'])]:
                audit['message_mismatches']+=1;raise RuntimeError('original request mismatch '+game)
            reply,trace=decide(pkt,c['messages'][0]['content'],strategy['params']);actual=json.loads(c['raw'])
            if reply!=actual:audit['order_mismatches']+=1;raise RuntimeError('decision replay mismatch '+game)
            audit['replayed_decisions']+=1
            if game not in eligible and game not in weakgames:continue
            if game in excluded:continue
            completion=rationale(pkt,trace)+'\n</think>\n\n'+c['raw']
            row={'messages':c['messages'],'completion':completion,'game':game,'tier':r['tier'],'turn':c['turn'],'run':out.name,
                'strategy':r['strategy'],'validation_strength':'robust_5_of_5_varied' if game in eligible else 'weak_or_unstable'}
            # Exact input/action duplicates only. No prose-based filtering or order rewriting.
            key=hashlib.sha256(json.dumps([c['messages'],actual['orders']],sort_keys=True).encode()).hexdigest()
            if game in eligible:
                if key in seen:audit['deduplicated_decisions']+=1;continue
                seen.add(key);main.append(row)
                lineage.append({'row':len(main)-1,'game':game,'strategy':r['strategy'],'raw_source':str(raw.relative_to(out)),
                                'messages_sha256':hashlib.sha256(json.dumps(c['messages'],ensure_ascii=False).encode()).hexdigest(),
                                'raw_sha256':hashlib.sha256(c['raw'].encode()).hexdigest(),'policy_sha256':strategy['policy_sha256'],'trace':trace})
            else: weakrows.append(row)
    dump(out/'sft_robust.json',main);dump(out/'sft_weak.json',weakrows);dump(out/'sft_lineage.json',lineage);dump(out/'audit.json',audit)
    samples=[]
    for tier in ['BASIC','INTER']:
        rr=[r for r in main if r['tier']==tier]
        for r in rr[::max(1,len(rr)//3)][:3]:
            if len(samples)<5:samples.append(r)
    dump(out/'five_samples.json',samples)
    summary={}
    for tier in ['BASIC','INTER']:
        tt=[r for r in rankings if r['tier']==tier];games=[r for r in results if r['tier']==tier]
        initial=[r for r in games if r['stage']=='initial']
        summary[tier]={'generated':len(pop),'tested_plans':len(tt),'plans_with_win':sum(r['wins']>0 for r in tt),
            'repeated_plans':sum(r['games']>1 for r in tt),'robust_plans':sum(r['class']=='robust' for r in tt),
            'weak_or_unstable_plans':sum(r['class'] in ['single_run','unstable'] for r in tt),'evaluation_games':len(games),
            'wins':sum(r['kind']=='WIN' for r in games),'losses_or_nonwins':sum(r['kind']!='WIN' for r in games),
            'result_kinds':dict(collections.Counter(r['kind'] for r in games)),
            'initial_wins':sum(r['kind']=='WIN' for r in initial),'initial_nonwins':sum(r['kind']!='WIN' for r in initial),
            'initial_win_rate':sum(r['kind']=='WIN' for r in initial)/len(initial) if initial else 0,
            'repeated_plan_win_rate_distribution':dict(collections.Counter(str(r['win_rate']) for r in tt if r['games']>1)),
            'robust_survivor_rate':sum(r['class']=='robust' for r in tt)/len(tt) if tt else 0,
            'robust_win_rates':[r['win_rate'] for r in tt if r['class']=='robust'],'sft_rows':sum(r['tier']==tier for r in main)}
    dump(out/'summary.json',{'tiers':summary,'rows':len(main),'distinct_games':len({r['game'] for r in main}),
                            'distinct_strategies':len({r['strategy'] for r in main}),'audit':audit})
    print(json.dumps({'summary':summary,'rows':len(main)},ensure_ascii=False),flush=True)

def main():
    ap=argparse.ArgumentParser();ap.add_argument('--out',required=True);ap.add_argument('--slots',default='0,5');ap.add_argument('--windows',type=int,default=6)
    ap.add_argument('--smoke',action='store_true');ap.add_argument('--export-only',action='store_true')
    ap.add_argument('--jobs', help='Frozen code-only replay jobs; no nomination or legacy export')
    a=ap.parse_args()
    out=Path(a.out).resolve();poplist=json.loads((out/'population.json').read_text(encoding='utf8'));pop={p['id']:p for p in poplist}
    for p in pop.values():p['params']=normalize(p['params'])
    if a.export_only:export(out,pop);return
    slots=[int(x) for x in a.slots.split(',')];assert all(s not in [1,2,3,4] for s in slots)
    assert 1<=a.windows<=9
    # Ports are checked, never borrowed or shut down from another run.
    for port in [x for s in slots for x in [8200+2*s,8201+2*s,11460+s]]:
        with socket.socket() as sock:
            try:sock.bind(('127.0.0.1',port))
            except OSError:raise RuntimeError('occupied port '+str(port))
    lock=threading.Lock();stop=threading.Event();q=queue.Queue();assign={};state={'jobs':0}
    def log(msg):
        with lock:
            print(time.strftime('%H:%M:%S ')+msg,flush=True)
            with open(out/'search.log','a',encoding='utf8') as f:f.write(msg+'\n')
    results=readjsonl(out/'results.jsonl');done={r['game'] for r in results}
    def job(p,tier,stage,rep):
        ri=p['recipe'];si=ri%4 if stage=='initial' else rep
        fi=(ri//4)%4 if stage=='initial' else rep
        seed=9300000+(0 if tier=='BASIC' else 100000)+ (ri%16 if stage=='initial' else 1000+rep)
        game=f"{p['id']}_{tier}_{stage}_{rep}_{STYLES[si]}_{FAMILIES[fi]}_s{seed}"
        return dict(game=game,strategy=p['id'],tier=tier,stage=stage,repeat=rep,style=STYLES[si],family=FAMILIES[fi],seed=seed)
    def enqueue(j):
        assign[j['game']]=j
        if j['game'] not in done:q.put(j)
    # Reconstruct full assignments on resume, including completed games.
    if a.jobs:
        for j in json.loads(Path(a.jobs).read_text(encoding='utf8')):
            assert j['strategy'] in pop and j['tier'] in ['BASIC','INTER']
            enqueue(j)
    else:
        for p in poplist[:1] if a.smoke else poplist:
            for tier in ['BASIC','INTER']:enqueue(job(p,tier,'initial',0))
    for r in results:
        assign[r['game']]=r
    dump(out/'search_config.json',{'slots':slots,'windows_per_slot':a.windows,'turn_cap':80,'command_every':5,'field_fortify':True,
         'eligibility':'initial WIN + 4/4 repeated WIN, all 4 styles and >=3 stat families; tier-specific',
         'repeat_budget':'best initial winner per strategy family per tier, four additional evaluations (at most 256 repeated games)',
         'smoke':a.smoke,'population_sha256':digest(out/'population.json'),'policy_source_sha256':digest(Path(__file__).with_name('survivor_policy.py'))})
    resources=[];responders=[];errors=[]
    def responder(md,sd):
        handled=set()
        while not stop.is_set():
            for f in sorted(md.glob('req_*.json')):
                if f.name in handled:continue
                resp=f.with_name(f.name.replace('req_','resp_').replace('.json','.txt'))
                if resp.exists():handled.add(f.name);continue
                try:r=json.loads(f.read_text(encoding='utf8'))
                except (ValueError,OSError):continue
                if r['request']!='VICTORY_COMMAND':doc={};trace={}
                else:
                    try:
                        j=assign[r['tag']];p=pop[j['strategy']]
                        doc,trace=decide(r.get('state') or json.loads(r['messages'][-1]['content']),r['messages'][0]['content'],p['params'])
                        with open(sd/'decision_trace.jsonl','a',encoding='utf8') as fp:fp.write(json.dumps({'n':r['n'],'tag':r['tag'],'strategy':p['id'],'policy_sha256':p['policy_sha256'],'trace':trace},ensure_ascii=False)+'\n')
                    except Exception as ex:
                        errors.append({'request':str(f),'error':repr(ex)});log('POLICY ERROR '+repr(ex));doc={'orders':{},'skipped':'POLICY_ERROR'}
                temp=resp.with_suffix('.tmp');temp.write_text(json.dumps(doc,ensure_ascii=False),encoding='utf8');os.replace(temp,resp);handled.add(f.name)
            time.sleep(.02)
    def worker(ar,port,sd):
        while True:
            try:j=q.get_nowait()
            except queue.Empty:return
            try:
                post(port,'/admin/tags',{'w%d'%ar.idx:j['game']})
                dest=out/'games'/(j['game']+'.json');dest.parent.mkdir(exist_ok=True)
                gl=ar.dir/'godot.log';offset=gl.stat().st_size if gl.exists() else 0
                t0=time.time();err=ar.play({k:j[k] for k in ['tier','style','family','seed']}|{'turn_cap':80,'session':resources[slots.index((ar.idx-10)//10)]['token']},dest,1800)
                res=json.loads(dest.read_text(encoding='utf8')) if dest.exists() else {'error':err or 'no result'}
                score=RV.score(res) if not res.get('error') else {'kind':'ERROR','win':False}
                row=j|score|{k:res.get(k) for k in ['outcome','turn','units','hq','red_actions','brain','error']}|{'fault':res.get('strict_fault'),'wall_s':round(time.time()-t0,2),'slot':(ar.idx-10)//10}
                with open(gl,'rb') as gf:gf.seek(offset);lines=gf.read().decode('utf8',errors='replace').splitlines()
                actions=[l for l in lines if re.match(r'^\[Commander\] t\d+ R_\S+ ',l)]
                actiondir=out/'executed_actions';actiondir.mkdir(exist_ok=True)
                (actiondir/(j['game']+'.log')).write_text('\n'.join(actions),encoding='utf8')
                damage=collections.Counter();hqdamage=collections.Counter();attacks=collections.Counter()
                for line in actions:
                    m=re.match(r'^\[Commander\] t(\d+) (\S+) ATTACK (\S+) dealt (\d+) took (\d+)(?: fieldworks -(\d+))?',line)
                    if m:
                        uid=m[2];d=int(m[4]);fw=int(m[6] or 0);damage[uid]+=d;attacks[uid]+=1
                        if 'HQ' in m[3]:hqdamage[uid]+=d+fw
                row['execution_diagnostics']={'attacks_per_unit':dict(attacks),'soldier_damage_per_unit':dict(damage),
                    'hq_damage_per_unit':dict(hqdamage),'max_unit_damage_share':max(damage.values(),default=0)/max(1,sum(damage.values())),
                    'distinct_attackers':len(attacks),'distinct_hq_damage_units':sum(v>0 for v in hqdamage.values()),
                    'render_errors':sum(l.startswith('ERROR:') for l in lines)}
                with lock:
                    with open(out/'results.jsonl','a',encoding='utf8') as f:f.write(json.dumps(row,ensure_ascii=False)+'\n')
                    results.append(row);done.add(j['game']);state['jobs']+=1
                log(j['game']+' -> '+row['kind']+' turn='+str(row['turn']))
            except BaseException as ex:errors.append({'game':j['game'],'error':repr(ex)});log('WORKER ERROR '+repr(ex))
            finally:q.task_done()
    try:
        for s in slots:
            sd=out/f'slot_{s}';port=8200+2*s;token=secrets.token_hex(8)
            md=sd/'manual_sessions'/token;md.mkdir(parents=True,exist_ok=True);(sd/'raw').mkdir(exist_ok=True)
            proxy=subprocess.Popen([sys.executable,'-m','tools.brain_review.teacher_proxy','--session',token,'--capture-dir',str(sd/'raw'),
                '--port',str(port),'--brain-port',str(port+1),'--default-mode','TEACHER','--initial-stub','--manual-dir',str(md),'--manual-poll-s','0.02'],
                cwd=str(RV.ROOT),stdout=open(sd/'raw/proxy.log','a',encoding='utf8'),stderr=subprocess.STDOUT)
            res={'proxy':proxy,'token':token,'port':port,'hands':None,'arenas':[]};resources.append(res)
            th=threading.Thread(target=responder,args=(md,sd),daemon=True);th.start();responders.append(th)
            if not wait_port(port,token,60):raise RuntimeError('proxy startup')
            hands=Hands(s,sd,log,'cpu');res['hands']=hands;hands.start()
            for i in range(a.windows):
                env={'LAYA_URL':hands.url,'BRAIN_CONTRACT_MODE':'unalloc_v1','SELFPLAY_GENERAL_TIMEOUT_SEC':'1800',
                     'WATCH_STRATEGIC_REPLAN_TURNS':'0','WATCH_RED_MODE':'COMMANDER','WATCH_CMD_EVERY':'5','WATCH_CMD_FACTS':'1',
                     'FIELD_FORTIFY':'1','WATCH_CMD_URL':f'http://127.0.0.1:{port}/v1/chat/completions','WATCH_BRAIN_PORT':str(port),
                     'WATCH_PREFER_FEWER_LOSSES':'0','WATCH_HISTORY_MAX_CHARS':'0','WATCH_ENEMY_FOCUS':'0','WATCH_THINK_TEMPLATE':'0',
                     'WATCH_TURN_PROGRESS':'0','WATCH_CMD_TRACE':'1'}
                res['arenas'].append(Arena(log,10+10*s+i,env,sd))
        with concurrent.futures.ThreadPoolExecutor(max_workers=len(slots)*a.windows) as pool:
            fs=[pool.submit(worker,ar,r['port'],out/f"slot_{(ar.idx-10)//10}") for r in resources for ar in r['arenas']]
            for f in fs:f.result()
            if not a.smoke and not a.jobs:
                winners=[r for r in results if r['stage']=='initial' and r['kind']=='WIN']
                def quality(r):
                    red=(r.get('units') or {}).get('red') or {}
                    return (r['turn'],red.get('start',0)-red.get('alive',0),-red.get('alive',0),r['strategy'])
                nominees={}
                for r in sorted(winners,key=quality):nominees.setdefault((pop[r['strategy']]['family'],r['tier']),r)
                dump(out/'repeat_nominees.json',list(nominees.values()))
                log('Initial population completed; repeated validation of %d distinct family/tier winners'%len(nominees))
                for r in nominees.values():
                    for rep in range(4):enqueue(job(pop[r['strategy']],r['tier'],'repeat',rep))
                fs=[pool.submit(worker,ar,r['port'],out/f"slot_{(ar.idx-10)//10}") for r in resources for ar in r['arenas']]
                for f in fs:f.result()
    finally:
        for r in resources:
            for ar in r['arenas']:ar.quit()
            if r['hands']:r['hands'].stop()
            try:post(r['port'],'/admin/shutdown',{})
            except Exception:pass
            try:r['proxy'].wait(timeout=10)
            except subprocess.TimeoutExpired:r['proxy'].kill()
        stop.set();dump(out/'technical_errors.json',errors)
    if not a.jobs:export(out,pop)
if __name__=='__main__':main()
