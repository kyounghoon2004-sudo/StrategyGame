"""Frozen code-only commander campaign and exact-action SFT export. No model calls."""
from __future__ import annotations
import argparse, collections, copy, hashlib, itertools, json, random, re, statistics
from pathlib import Path
from tools.plan_search.survivor_policy import DEFAULT, decide, normalize
from tools.plan_search.survivor_search import dump, readjsonl
from tools.cmd_rl.refine_survivors import vs_map, band
ROOT=Path(__file__).resolve().parents[2]
SRC=ROOT/'artifacts/brain_pipeline_v1/commander_survivors_20261007'
OUT=ROOT/'artifacts/brain_pipeline_v1/commander_growth_20261007'
STYLES=['SPEARHEAD','BULWARK','OUTRIDER']
FAMILIES=['fixed','mild','broad','counterfactual_valid']
PARTS=['inter_extension','hq_timing_variant']
def sha(obj):return hashlib.sha256(json.dumps(obj,sort_keys=True,ensure_ascii=False).encode()).hexdigest()
def prepare():
    OUT.mkdir(exist_ok=False)
    pop=json.loads((SRC/'population.json').read_text(encoding='utf8'))
    refined=json.loads((SRC/'sft_refined.json').read_text(encoding='utf8'))
    rr=readjsonl(SRC/'results.jsonl'); robust=json.loads((SRC/'robust_survivors.json').read_text(encoding='utf8'))
    pairs={(r['strategy'],r['tier']) for r in refined}
    pairs={k for k in pairs if statistics.median(r['turn'] for r in rr if (r['strategy'],r['tier'])==k and r['kind']=='WIN')<=30}
    selected=[copy.deepcopy(p) for p in pop if any(s==p['id'] for s,t in pairs)]
    variants=[]
    for sid,tiers in [('P114',['BASIC']),('P216',['BASIC','INTER'])]:
        p=copy.deepcopy(next(x for x in pop if x['id']==sid));p['parent']=sid;p['id']=sid+'_focus2'
        p['params']['max_focus']=2;p['policy_sha256']=sha(p['params']);p['behavior_change']='Only max_focus changed to 2; prefer distributing field attacks before concentrating.'
        selected.append(p);variants.append({'parent':sid,'child':p['id'],'tiers':tiers,'changed':{'max_focus':[next(x for x in pop if x['id']==sid)['params']['max_focus'],2]}})
    jobs=[]
    def job(sid,tier,style,fam,seed,stage,rep):
        return dict(game=f'{sid}_{tier}_{stage}_{style}_{fam}_s{seed}',strategy=sid,tier=tier,stage=stage,repeat=rep,style=style,family=fam,seed=seed)
    for sid,tier in sorted(pairs):
        for si,style in enumerate(STYLES):
            for fi,fam in enumerate(FAMILIES):
                for rep in range(2):
                    seed=9700000+(1000 if tier=='INTER' else 0)+si*100+fi*10+rep
                    jobs.append(job(sid,tier,style,fam,seed,'grow',rep))
    for v in variants:
        for j in list(jobs):
            if j['strategy']==v['parent'] and j['tier'] in v['tiers']:
                jobs.append(job(v['child'],j['tier'],j['style'],j['family'],j['seed'],'variant',j['repeat']))
    hold=[]
    for tier,sids in [('BASIC',['P129','P143']),('INTER',['P012','P216'])]:
        for sid,fi,rep in itertools.product(sids,range(4),range(4)):
            seed=9900000+(1000 if tier=='INTER' else 0)+fi*10+rep
            hold.append(job(sid,tier,'HARRIER',FAMILIES[fi],seed,'holdout',rep))
    smoke=[next(j for j in jobs if j['strategy']==s and j['tier']==t) for s,t in [('P129','BASIC'),('P012','INTER'),('P114','BASIC'),('P216','INTER')]]
    random.Random(20261007).shuffle(jobs)
    dump(OUT/'population.json',selected);dump(OUT/'variants.json',variants)
    dump(OUT/'jobs.json',jobs+hold);dump(OUT/'smoke_jobs.json',smoke)
    dump(OUT/'holdout_definition.json',{'styles':['HARRIER'],'seeds':sorted({j['seed'] for j in hold}),'cases':hold,'rule':'Exclude ALL HARRIER games and all held seeds, including old source games, from training. Split frozen before collection; holdout results never select variants.'})
    dump(OUT/'source_hashes.json',{str(f.relative_to(SRC)):hashlib.sha256(f.read_bytes()).hexdigest() for f in SRC.rglob('*') if f.is_file()})
    dump(OUT/'campaign_config.json',{'pairs':sorted(pairs),'slots':[0,5],'windows_per_slot':6,'seeds':sorted({j['seed'] for j in jobs}),'jobs':len(jobs),'holdout_games':len(hold),'no_llm':True,'max_win_turn':35,'max_median':30,'friendly_loss_cap':2,'selection':'Source robust + fast median; final source and fresh winning medians <=30 separately; winning games <=35, <=2 unit losses; variant replaces only when each tier win rate and winning turn median/mean/max are no worse on 24 matched cases.'})
    print(json.dumps({'pairs':len(pairs),'training_jobs':len(jobs),'holdout':len(hold),'smoke':len(smoke)}))
def order_text(o):
    s=o['do']
    for k in ['target','to','back_to']:
        if k in o:
            v=o[k];s+=(' back ' if k=='back_to' else ' ')+((','.join(map(str,v))) if isinstance(v,list) else str(v))
    return s

def packet_text(raw,original,rewritten):
    """Replace echo string tokens only; preserve all other input bytes/formatting."""
    changes={a:b for a,b in zip(original.get('history',[]),rewritten.get('history',[])) if a!=b}
    a,b=original.get('current_plan') or {},rewritten.get('current_plan') or {}
    for key in ['text','notes']:
        if a.get(key)!=b.get(key):
            assert a[key] not in changes or changes[a[key]]==b[key]
            changes[a[key]]=b[key]
    def replace(m):
        value=json.loads(m[0])
        return json.dumps(changes[value],ensure_ascii=False) if value in changes else m[0]
    result=re.sub(r'"(?:[^"\\]|\\.)*"',replace,raw)
    assert json.loads(result)==rewritten
    return result

def words(pkt,reply,game,diverse=True):
    """Compose only directly checkable packet/order facts; no branch explanations."""
    orders=reply['orders'];mine={u['id']:u for u in pkt['my_units']};foes={e['id']:e for e in pkt['enemy_units']}
    rng=random.Random(sha([game,pkt['turn']]))
    pick=lambda opts:rng.choice(opts) if diverse else opts[0]
    attack=[(u,o) for u,o in orders.items() if o['do'] in ['ATTACK','RAID']]
    strike=[u for u,o in attack if o['target']=='ENEMY_HQ']
    field=[(u,o) for u,o in attack if o['target']!='ENEMY_HQ']
    moving=[u for u,o in orders.items() if o['do']=='MOVE'];fort=[u for u,o in orders.items() if o['do']=='FORTIFY'];hold=[u for u,o in orders.items() if o['do']=='HOLD']
    # The original standing plan repeats across turns. Its replacement must also repeat,
    # preserving the untouched game-generated since_turn field.
    pr=random.Random(sha([game,reply['plan']]))
    ppick=lambda opts:pr.choice(opts) if diverse else opts[0]
    intent=[]
    if strike:intent.append(ppick(['Press ENEMY_HQ with %d units','Send %d units against ENEMY_HQ','Commit %d units to ENEMY_HQ'])%len(strike))
    if field:intent.append(ppick(['engage field enemies with %d units','assign %d units to field engagements','use %d units against field targets'])%len(field))
    if moving:intent.append(ppick(['move %d units to their assigned destinations','reposition %d units','advance %d units to their ordered destinations'])%len(moving))
    if fort:intent.append(ppick(['fortify %d units','have %d units dig in','keep %d units on fortification orders'])%len(fort))
    if hold:intent.append('hold %d units'%len(hold))
    plan='; '.join(intent)+'.';assert len(plan)<=300
    mf=[u for u in mine.values() if u['class']!='HQ'];ef=[e for e in foes.values() if e['class']!='HQ']
    n=sum(u['soldiers'] for u in mf);lo=sum(band(e)[0] for e in ef);hi=sum(band(e)[1] for e in ef)
    facts=[pick(['Turn %d: %d friendly field units have %d soldiers.','At turn %d, our %d field units total %d soldiers.','Our field force at turn %d is %d units with %d soldiers.'])%(pkt['turn'],len(mf),n),pick(['Known enemy field force: %d units, %d-%d troops in the packet.','Enemy contacts in the packet: %d field units, %d-%d troops.','The packet lists %d enemy field units, %d-%d troops.'])%(len(ef),lo,hi)]
    # Three representative assignments, prioritizing a different action group, are enough
    # for a short rationale. The JSON retains every exact order.
    candidates=[];seen=set()
    for uid,o in sorted(orders.items(),key=lambda x:(0 if x[1].get('target')=='ENEMY_HQ' else 1 if x[1]['do'] in ['ATTACK','RAID'] else 2 if x[1]['do']=='MOVE' else 3,x[0])):
        kind=(o['do'],o.get('target')=='ENEMY_HQ')
        if kind not in seen: candidates.append((uid,o));seen.add(kind)
    details=[]
    for uid,o in candidates[:3]:
        if o['do'] in ['ATTACK','RAID']:
            target=o['target'];v=vs_map(mine[uid]).get(next((e['id'] for e in foes.values() if e['class']=='HQ'),'')) if target=='ENEMY_HQ' else vs_map(mine[uid]).get(target)
            eta=mine[uid].get('eta',{}).get('strike_enemy_hq') if target=='ENEMY_HQ' else (v or {}).get('eta')
            lead=pick(['%s attacks %s','Assign %s to attack %s','%s goes against %s'])%(uid,target) if o['do']=='ATTACK' else '%s raids %s, then returns toward %s'%(uid,target,o['back_to'])
            if eta is not None:lead+=' (ETA %s)'%eta
            if v:lead+='; preview dealt %s, taken %s%s'%(v['dealt'],v['taken'],', fieldworks damage %d'%v['fw'] if v['fw'] else '')
            details.append(lead+'.')
        elif o['do']=='MOVE':details.append(pick(['%s moves toward %s.','Reposition %s toward %s.','%s heads for %s.'])%(uid,json.dumps(o['to'],ensure_ascii=False) if isinstance(o['to'],list) else o['to']))
        elif o['do']=='FORTIFY':details.append(pick(['%s fortifies.','%s digs in.','Keep %s on fortification.'])%uid)
        else:details.append('%s holds position.'%uid)
    if diverse and rng.randrange(2):details.reverse()
    think=' '.join(facts+details)
    pairs=collections.Counter(o['target'] for _,o in attack)
    notes=pick(['Turn %d assignments: ','At turn %d: ','Remember the turn %d allocation: '])%pkt['turn']
    notes+=('; '.join('%s: %d units'%(t,n) for t,n in sorted(pairs.items()))+'. ') if pairs else ''
    if moving:notes+='Moving: '+', '.join(moving)+'. '
    if fort:notes+='Fortifying: '+', '.join(fort)+'. '
    if hold:notes+='Holding: '+', '.join(hold)+'. '
    think,plan,notes=[re.sub(r'\b1 ((?:friendly field|enemy field|field) )?units\b',lambda m:'1 '+(m[1] or '')+'unit',s) for s in [think,plan,notes]]
    plan=plan[:1].upper()+plan[1:]
    assert len(notes)<=600 and len(think.split())<=160
    assert not re.search(r'configured|threshold|policy|branch|variant|commit_|abandon|opening_|score|winning|victory',think+' '+plan+' '+notes,re.I)
    ids=set(re.findall(r'\b[RB]_[A-Z]+_\d+\b',think+' '+plan+' '+notes));assert ids<=set(mine)|set(foes)
    return think,{'plan':plan,'notes':notes.strip(),'orders':copy.deepcopy(orders)}

def awkward(pkt,orders,previous):
    """Conservative row selection, never an evaluation substitute or action rewrite."""
    mine={u['id']:u for u in pkt['my_units']};foes={e['id']:e for e in pkt['enemy_units']};groups=collections.defaultdict(list)
    for uid,o in orders.items():
        if o['do'] in ['ATTACK','RAID'] and o['target']!='ENEMY_HQ':groups[o['target']].append(uid)
    reasons=[]
    for target,us in groups.items():
        e=foes[target];lo,hi=band(e)
        if 'last_seen_turn' in e:continue
        if len(us)>=4 and e['class']=='SCOUT' and hi<=150 and e.get('eta_strike_my_hq',99)>3 and not e.get('fortified'):
            reasons.append('over_concentration_on_small_non_HQ_threat')
        dealt=sum(int(v['dealt'].split('-')[0]) for uid in us if (v:=vs_map(mine[uid]).get(target)) and v['eta']<=1)
        if len(us)>=4 and hi<=100 and hi>0 and dealt>2*hi and not e.get('fortified') and e.get('eta_strike_my_hq',99)>3:reasons.append('severe_near_range_overkill')
    unreachable=[]
    for uid,o in orders.items():
        if o['do'] in ['ATTACK','RAID']:
            eta=mine[uid].get('eta',{}).get('strike_enemy_hq',99) if o['target']=='ENEMY_HQ' else vs_map(mine[uid]).get(o['target'],{}).get('eta',99)
            if eta>=99:unreachable.append(uid)
    if unreachable:reasons.append('unreachable_preview_sentinel')
    if len(previous)>=2:
        for uid,o in orders.items():
            if o['do']!='MOVE':continue
            stalled=True
            for oldpkt,oldorders in previous[-2:]:
                old=next((u for u in oldpkt['my_units'] if u['id']==uid),None)
                if not old or oldorders.get(uid)!=o or [old['q'],old['r']]!=[mine[uid]['q'],mine[uid]['r']]:stalled=False
            if stalled and isinstance(o.get('to'),list) and o['to']==[mine[uid]['q'],mine[uid]['r']]:reasons.append('repeated_move_already_at_waypoint')
    return sorted(set(reasons))

def performance(rows):
    wins=[r for r in rows if r['kind']=='WIN'];ts=[r['turn'] for r in wins]
    losses=[r['units']['red']['start']-r['units']['red']['alive'] for r in rows if r.get('units')]
    return dict(games=len(rows),wins=len(wins),losses=sum(r['kind'] in ['LOSS','NOT_ACHIEVED'] for r in rows),technical_failures=sum(r['kind'] in ['ERROR','INVALID'] for r in rows),win_rate=len(wins)/len(rows) if rows else 0,median_win_turn=statistics.median(ts) if ts else None,mean_win_turn=statistics.mean(ts) if ts else None,max_win_turn=max(ts) if ts else None,mean_friendly_losses=statistics.mean(losses) if losses else None,mean_friendly_survivors=statistics.mean(r['units']['red']['alive'] for r in rows if r.get('units')) if losses else None,failure_modes=dict(collections.Counter(r['kind'] for r in rows if r['kind']!='WIN')))

def results():
    rr=readjsonl(OUT/'results.jsonl')
    if not (OUT/'merged_extension.json').exists():
        for part in PARTS:rr+=readjsonl(OUT/part/'results.jsonl')
    return rr

def trajectory_hash(tier,seq):
    return sha([tier,[[{k:v for k,v in json.loads(c['messages'][-1]['content']).items() if k not in ['history','current_plan','why_asked']},json.loads(c['raw'])['orders']] for c,_ in sorted(seq,key=lambda x:x[0]['turn'])]])

def export():
    pop={p['id']:p for p in json.loads((OUT/'population.json').read_text(encoding='utf8'))}
    rr=results();assert len({r['game'] for r in rr})==len(rr)
    oldrr=readjsonl(SRC/'results.jsonl');allresults={r['game']:r for r in oldrr+rr}
    oldpop={p['id']:p for p in json.loads((SRC/'population.json').read_text(encoding='utf8'))};pop=oldpop|pop
    hold=json.loads((OUT/'holdout_definition.json').read_text(encoding='utf8'));config=json.loads((OUT/'campaign_config.json').read_text(encoding='utf8'))
    holdseeds=set(hold['seeds']);pairs={tuple(x) for x in config['pairs']};comparisons=[];approved=set()
    for v in json.loads((OUT/'variants.json').read_text(encoding='utf8')):
        okay=True;per={}
        for tier in v['tiers']:
            parent=[r for r in rr if r['strategy']==v['parent'] and r['tier']==tier and r['stage']!='holdout'];child=[r for r in rr if r['strategy']==v['child'] and r['tier']==tier]
            keys=lambda rows:{(r['style'],r['family'],r['seed']) for r in rows}
            a,b=performance(parent),performance(child)
            matched=keys(parent)==keys(child) and len(parent)==len(child)==24
            good=matched and b['technical_failures']==a['technical_failures']==0 and b['win_rate']>=a['win_rate'] and all(b[k] is not None and a[k] is not None and b[k]<=a[k] for k in ['median_win_turn','mean_win_turn','max_win_turn','mean_friendly_losses'])
            failed=[]
            if not matched:failed.append('incomplete_or_unmatched_cases')
            if b['technical_failures'] or a['technical_failures']:failed.append('technical_failure')
            if b['win_rate']<a['win_rate']:failed.append('win_rate')
            failed += [k for k in ['median_win_turn','mean_win_turn','max_win_turn','mean_friendly_losses'] if b[k] is None or a[k] is None or b[k]>a[k]]
            okay &= good;per[tier]={'parent':a,'variant':b,'matched_24_cases':matched,'qualifies':good,'failed_metrics':failed,'pairs':[{'parent_game':r['game'],'child_game':next((c['game'] for c in child if (c['style'],c['family'],c['seed'])==(r['style'],r['family'],r['seed'])),None)} for r in parent]}
        comparisons.append(v|{'performance':per,'replaced_parent':okay,'reason':'All tier gates passed' if okay else 'Child excluded; failed gates: '+'; '.join(t+': '+', '.join(p['failed_metrics']) for t,p in per.items() if p['failed_metrics'])})
        if okay:
            for tier in v['tiers']:approved.add((v['child'],tier))
    dump(OUT/'variant_evaluation.json',comparisons)
    # Never use holdout wins in admission statistics.
    freshby=collections.defaultdict(list)
    for r in rr:
        if r['stage']!='holdout':freshby[(r['strategy'],r['tier'])].append(r)
    qualified={k for k,v in freshby.items() if (k in pairs or k in approved) and (ts:=[r['turn'] for r in v if r['kind']=='WIN']) and statistics.median(ts)<=30}
    # Drop replaced parent games, while retaining honest parent/child evaluation results.
    replaced={(v['parent'],t) for v in comparisons if v['replaced_parent'] for t in v['tiers']}
    eligible={};game_rejections={}
    for r in rr:
        if r['stage']=='holdout':continue
        red=(r.get('units') or {}).get('red',{});k=(r['strategy'],r['tier'])
        reason='nonwin' if r['kind']!='WIN' else 'unapproved_variant' if pop[r['strategy']].get('parent') and k not in approved else 'strategy_median_above_30' if k not in qualified else 'late_win' if r['turn']>35 else 'friendly_losses_above_2' if red.get('start',0)-red.get('alive',0)>2 else 'replaced_parent' if k in replaced else None
        if reason:game_rejections[r['game']]=reason
        else:eligible[r['game']]=r
    oldref=json.loads((SRC/'sft_refined.json').read_text(encoding='utf8'));oldgames={r['game'] for r in oldref}
    for r in oldrr:
        red=(r.get('units') or {}).get('red',{})
        if r['game'] in oldgames and (r['strategy'],r['tier']) in pairs and (r['strategy'],r['tier']) in qualified and r['style'] not in hold['styles'] and r['seed'] not in holdseeds and red.get('start',0)-red.get('alive',0)<=2 and (r['strategy'],r['tier']) not in replaced:eligible[r['game']]=r
    dump(OUT/'game_selection.json',{'eligible_games':sorted(eligible),'new_rejections':game_rejections})
    captures=collections.defaultdict(list)
    for source in [SRC,OUT]:
        for raw in sorted(source.glob('slot_*/raw/calls.jsonl'))+([f for part in PARTS for f in sorted(source.glob(part+'/slot_*/raw/calls.jsonl'))] if source==OUT else []):
            for c in readjsonl(raw):
                if c.get('request')!='VICTORY_COMMAND':continue
                if c['tag'] not in allresults:continue  # Interrupted games have no terminal proof and never become rows.
                if source==SRC and c['tag'] not in eligible:continue
                assert c['mode']=='MANUAL' and not c.get('cloud') and not c.get('local')
                captures[c['tag']].append((c,str(raw.relative_to(ROOT))))
    fingerprints={g:trajectory_hash(allresults[g]['tier'],seq) for g,seq in captures.items() if g in eligible or allresults[g].get('stage')=='holdout'}
    holdprints={fp for g,fp in fingerprints.items() if allresults[g].get('stage')=='holdout'}
    behavior=collections.defaultdict(collections.Counter)
    for game,seq in captures.items():
        r=allresults[game];previous=[]
        assert len(seq)==r['brain']['decisions']['COMMAND'],('capture count differs from game',game,len(seq),r['brain'])
        for c,_ in sorted(seq,key=lambda x:x[0]['turn']):
            pkt=json.loads(c['messages'][-1]['content']);actual=json.loads(c['raw'])
            replay,_=decide(pkt,c['messages'][0]['content'],normalize(pop[r['strategy']]['params']));assert replay==actual
            key=(r['strategy'],r['tier'],r.get('stage')=='holdout');bc=behavior[key];bc['decisions']+=1
            reasons=awkward(pkt,actual['orders'],previous)
            if reasons:bc['flagged_decisions']+=1
            for reason in reasons:bc[reason]+=1
            bc['max_field_target_concentration']=max(bc['max_field_target_concentration'],max(collections.Counter(o['target'] for o in actual['orders'].values() if o['do'] in ['ATTACK','RAID'] and o['target']!='ENEMY_HQ').values(),default=0))
            previous.append((pkt,actual['orders']))
    dump(OUT/'behavioral_audit.json',[{'strategy':s,'tier':t,'holdout':h,**b,'flagged_rate':b['flagged_decisions']/b['decisions']} for (s,t,h),b in sorted(behavior.items())])
    train=[];holdrows=[];lineage=[];drops=[];alltext=[];seen={};decision_seen=set();duplicates=[];checked=0;history_checks=0
    for game,seq in sorted(captures.items()):
        r=allresults[game];is_hold=r.get('stage')=='holdout'
        if game not in eligible and not is_hold:continue
        seq.sort(key=lambda x:x[0]['turn']);assert len({c['turn'] for c,_ in seq})==len(seq)
        # Dedupe at whole-trajectory level, ignoring textual echoes only. Check against
        # holdout before writing training to prevent equivalent-copy leakage.
        fingerprint=fingerprints[game]
        if fingerprint in seen:duplicates.append({'game':game,'equivalent_to':seen[fingerprint],'holdout':is_hold})
        else:seen[fingerprint]=game
        prior={};previous=[]
        for c,rawpath in seq:
            checked+=1;pkt=json.loads(c['messages'][-1]['content']);orig=copy.deepcopy(pkt);actual=json.loads(c['raw'])
            replay,trace=decide(pkt,c['messages'][0]['content'],normalize(pop[r['strategy']]['params']));assert replay==actual
            for j,h in enumerate(pkt.get('history',[])):
                m=re.match(r'^t(\d+) RED decision ',h)
                if not m:continue
                turn=int(m[1]);assert turn in prior,(game,turn)
                old,new=prior[turn]
                orderline='; '.join(uid+' '+order_text(o) for uid,o in old['orders'].items())
                assert 'plan: '+old['plan']+' | orders: '+orderline in h,(game,turn,h)
                pkt['history'][j]=h.replace('plan: '+old['plan']+' | orders:','plan: '+new['plan']+' | orders:',1);history_checks+=1
            cp=pkt.get('current_plan')
            if cp and cp.get('text'):
                assert previous
                lastturn=max(prior);old,new=prior[lastturn];assert cp['text']==old['plan'] and cp['notes']==old['notes']
                cp['text']=new['plan'];cp['notes']=new['notes'];history_checks+=1
            think,new=words(pkt,actual,game);assert words(pkt,actual,game)==(think,new)
            assert new['orders']==actual['orders'];prior[c['turn']]=(actual,new)
            # A standing plan must retain exactly the game's since_turn semantics.
            if cp and cp.get('text'):
                same=[t for t,(a,b) in prior.items() if a['plan']==actual['plan']]
                assert all(prior[t][1]['plan']==new['plan'] for t in same)
            allowed=copy.deepcopy(pkt);allowed['history']=orig.get('history',[]);allowed['current_plan']=orig.get('current_plan');assert allowed==orig
            reasons=awkward(orig,actual['orders'],previous);previous.append((orig,actual['orders']))
            alltext.append({'game':game,'turn':c['turn'],'old':actual,'new':new,'thinking':think,'excluded_reasons':reasons})
            msgs=copy.deepcopy(c['messages']);msgs[-1]['content']=packet_text(c['messages'][-1]['content'],orig,pkt)
            completion=think+'\n</think>\n\n'+json.dumps(new,ensure_ascii=False)
            capture_run=str(Path(rawpath).parent.parent.parent.relative_to(Path('artifacts/brain_pipeline_v1'))).replace('\\','/')
            row={'messages':msgs,'completion':completion,'game':game,'tier':r['tier'],'turn':c['turn'],'run':capture_run,'strategy':r['strategy']}
            decision_key=sha([msgs[:-1],pkt,new['orders']])
            meta={'row':len(train),'game':game,'strategy':r['strategy'],'variant':r['strategy'] if pop[r['strategy']].get('parent') else None,'parent':pop[r['strategy']].get('parent'),'tier':r['tier'],'turn':c['turn'],'run':capture_run,'dataset_run':OUT.name,'seed':r['seed'],'style':r['style'],'family':r['family'],'source':rawpath,'original_messages_sha256':sha(c['messages']),'original_reply_sha256':sha(actual),'orders_sha256':sha(actual['orders']),'policy_sha256':pop[r['strategy']]['policy_sha256'],'trace':trace,'win_turn':r['turn']}
            if is_hold:holdrows.append(row)
            elif reasons:drops.append(meta|{'reasons':reasons})
            elif fingerprint in holdprints:drops.append(meta|{'reasons':['holdout_equivalent_trajectory']})
            elif any(d['game']==game for d in duplicates):drops.append(meta|{'reasons':['duplicate_trajectory']})
            elif decision_key in decision_seen:drops.append(meta|{'reasons':['exact_duplicate_decision']})
            else:decision_seen.add(decision_key);train.append(row);lineage.append(meta)
    assert not any(fingerprints[row['game']] in holdprints for row in train)
    assert all(allresults[r['game']]['style'] not in hold['styles'] and allresults[r['game']]['seed'] not in holdseeds for r in train)
    for f,h in json.loads((OUT/'source_hashes.json').read_text(encoding='utf8')).items():assert hashlib.sha256((SRC/f).read_bytes()).hexdigest()==h,('source changed',f)
    code_hashes=json.loads((OUT/'execution_code_hashes.json').read_text(encoding='utf8'))
    code_unchanged=all(hashlib.sha256((ROOT/f).read_bytes()).hexdigest()==h for f,h in code_hashes.items())
    assert hashlib.sha256((ROOT/'tools/plan_search/survivor_policy.py').read_bytes()).hexdigest()==code_hashes['tools/plan_search/survivor_policy.py'],'immutable policy executor changed'
    if not code_unchanged:assert (OUT/'execution_source_drift.json').exists(),'Record execution source changes explicitly before sealing historical data'
    dump(OUT/'sft_expanded.json',train);dump(OUT/'sft_lineage.json',lineage);dump(OUT/'holdout_decisions.json',holdrows);dump(OUT/'holdout_results.json',[r for r in rr if r['stage']=='holdout']);dump(OUT/'dropped_rows.json',drops);dump(OUT/'trajectory_texts.json',alltext);dump(OUT/'duplicate_trajectories.json',duplicates)
    dump(OUT/'holdout_summary.json',{tier:{'games':sum(r['tier']==tier and r['stage']=='holdout' for r in rr),'unique_situations':sum(x['tier']==tier for x in hold.get('evaluation_situations',[])),'teachers':{sid:performance([r for r in rr if r['tier']==tier and r['stage']=='holdout' and r['strategy']==sid]) for sid in sorted({r['strategy'] for r in rr if r['tier']==tier and r['stage']=='holdout'})}} for tier in ['BASIC','INTER']})
    stat={'status':'PASS','rows_checked':checked,'all_captured_policy_decisions_replayed':sum(b['decisions'] for b in behavior.values()),'training_rows_accepted':len(train),'holdout_rows':len(holdrows),'training_rows_dropped':len(drops),'rejection_reasons':dict(collections.Counter(reason for d in drops for reason in d['reasons'])),'rows_regenerated':checked,'cross_turn_echo_checks':history_checks,'order_mismatches':0,'packet_non_echo_changes':0,'unsupported_generated_facts':0,'external_llm_calls':0,'source_hashes_unchanged':True,'execution_code_snapshot_unchanged':True,'tier_rows':dict(collections.Counter(r['tier'] for r in train)),'unique_games':len({r['game'] for r in train}),'unique_strategies':len({r['strategy'] for r in train}),'unique_variants':len({m['variant'] for m in lineage if m['variant']}),'complete_campaign':{j['game'] for j in json.loads((OUT/'jobs.json').read_text(encoding='utf8'))}<={r['game'] for r in rr}}
    dump(OUT/'validation.json',stat)
    stat['execution_code_snapshot_unchanged']=code_unchanged
    stat['collection_status']='COMPLETE' if stat['complete_campaign'] else 'INTERRUPTED_PARTIAL'
    dump(OUT/'validation.json',stat)
    dump(OUT/'performance.json',[{'strategy':s,'tier':t,**performance(v)} for (s,t),v in sorted(freshby.items())]);print(json.dumps(stat))

def validate():
    """Independent saved-artifact check, including omitted predecessor decisions."""
    rows=json.loads((OUT/'sft_expanded.json').read_text(encoding='utf8'));lin=json.loads((OUT/'sft_lineage.json').read_text(encoding='utf8'))
    texts={(x['game'],x['turn']):x for x in json.loads((OUT/'trajectory_texts.json').read_text(encoding='utf8'))}
    assert len(rows)==len(lin)
    hold=json.loads((OUT/'holdout_definition.json').read_text(encoding='utf8'))
    requests=collections.defaultdict(list)
    for root in [SRC,OUT]:
        for f in list(root.glob('slot_*/manual_sessions/*/req_*.json'))+([f for part in PARTS for f in root.glob(part+'/slot_*/manual_sessions/*/req_*.json')] if root==OUT else []):
            c=json.loads(f.read_text(encoding='utf8'))
            if c.get('request')=='VICTORY_COMMAND':requests[(c['tag'],c['turn'])].append(c['messages'])
        for f in root.glob('slot_*/manual/req_*.json'):
            c=json.loads(f.read_text(encoding='utf8'))
            if c.get('request')=='VICTORY_COMMAND':requests[(c['tag'],c['turn'])].append(c['messages'])
    captured={}
    for rawpath in {m['source'] for m in lin}:
        for c in readjsonl(ROOT/rawpath):
            if c.get('request')=='VICTORY_COMMAND':captured[(rawpath,c['tag'],c['turn'])]=c
    echo_checks=0;zero_eta_checks=0
    for i,(row,meta) in enumerate(zip(rows,lin)):
        assert meta['row']==i and all(meta[k]==row[k] for k in ['game','tier','turn','run','strategy'])
        c=captured[(meta['source'],row['game'],row['turn'])];assert c['messages'] in requests[(row['game'],row['turn'])]
        assert sha(c['messages'])==meta['original_messages_sha256']
        actual=json.loads(c['raw']);assert sha(actual)==meta['original_reply_sha256']
        thinking,suffix=row['completion'].split('\n</think>\n\n');new=json.loads(suffix);assert len(thinking.split())<=160
        assert new['orders']==actual['orders'] and sha(new['orders'])==meta['orders_sha256']
        assert new==texts[(row['game'],row['turn'])]['new']
        original=json.loads(c['messages'][-1]['content']);pkt=json.loads(row['messages'][-1]['content']);assert row['turn']==pkt['turn']
        assert row['messages'][-1]['content']==packet_text(c['messages'][-1]['content'],original,pkt)
        assert row['messages'][:-1]==c['messages'][:-1]
        assert {k:v for k,v in pkt.items() if k not in ['current_plan','history']}=={k:v for k,v in original.items() if k not in ['current_plan','history']}
        assert len(pkt['history'])==len(original['history'])
        for old,h in zip(original['history'],pkt['history']):
            m=re.match(r'^t(\d+) RED decision ',old)
            if not m:assert h==old;continue
            earlier=texts[(row['game'],int(m[1]))]
            assert h==old.replace('plan: '+earlier['old']['plan']+' | orders:','plan: '+earlier['new']['plan']+' | orders:',1);echo_checks+=1
        cp=pkt.get('current_plan');ocp=original.get('current_plan')
        if cp and cp.get('text'):
            before=[t for g,t in texts if g==row['game'] and t<row['turn']];earlier=texts[(row['game'],max(before))]
            assert cp==ocp|{'text':earlier['new']['plan'],'notes':earlier['new']['notes']};echo_checks+=1
        own={u['id']:u for u in pkt['my_units']};enemy={u['id']:u for u in pkt['enemy_units']}
        assert set(re.findall(r'\b[RB]_[A-Z]+_\d+\b',thinking+new['plan']+new['notes']))<=set(own)|set(enemy)
        targets=collections.Counter(o['target'] for o in new['orders'].values() if o['do'] in ['ATTACK','RAID'])
        noted={m[1]:int(m[2]) for m in re.finditer(r'(ENEMY_HQ|[RB]_[A-Z]+_\d+): (\d+) units?',new['notes'])};assert noted==targets
        hq_count=targets.get('ENEMY_HQ',0);field_count=sum(targets.values())-hq_count
        for clause in new['plan'].rstrip('.').split('; '):
            count=int(re.search(r'\d+',clause)[0]);lower=clause.lower()
            expected=hq_count if 'ENEMY_HQ' in clause else field_count if 'field ' in lower else sum(o['do']=='MOVE' for o in new['orders'].values()) if any(w in lower for w in ['move','reposition','advance']) else sum(o['do']=='FORTIFY' for o in new['orders'].values()) if any(w in lower for w in ['fortify','dig in','fortification']) else sum(o['do']=='HOLD' for o in new['orders'].values())
            assert count==expected,(row['game'],row['turn'],clause,expected)
        for clause in thinking.split('. '):
            if not any(w in clause for w in [' attacks ',' to attack ',' goes against ',' raids ']):continue
            uid=next(u for u in own if u in clause);o=new['orders'][uid];assert o['do'] in ['ATTACK','RAID'] and o['target'] in clause
            if o['do']=='RAID':assert str(o['back_to']) in clause
        mf=[u for u in own.values() if u['class']!='HQ'];ef=[u for u in enemy.values() if u['class']!='HQ']
        assert any(s in thinking for s in ['%d friendly field units have %d soldiers'%(len(mf),sum(u['soldiers'] for u in mf)), 'our %d field units total %d soldiers'%(len(mf),sum(u['soldiers'] for u in mf)), '%d units with %d soldiers'%(len(mf),sum(u['soldiers'] for u in mf))])
        assert '%d-%d troops'%(sum(band(e)[0] for e in ef),sum(band(e)[1] for e in ef)) in thinking
        for clause in thinking.split('. '):
            if 'preview dealt ' not in clause:continue
            uid=next(u for u in own if u in clause);o=new['orders'][uid]
            target=o['target'];eid=next(e for e,u in enemy.items() if u['class']=='HQ') if target=='ENEMY_HQ' else target
            v=vs_map(own[uid])[eid];assert 'preview dealt %s, taken %s'%(v['dealt'],v['taken']) in clause
            eta=own[uid]['eta']['strike_enemy_hq'] if target=='ENEMY_HQ' else v['eta'];assert '(ETA %d)'%eta in clause
            if eta==0:zero_eta_checks+=1
            if v['fw']:assert 'fieldworks damage %d'%v['fw'] in clause
        assert meta['seed'] not in hold['seeds'] and meta['style'] not in hold['styles'] and meta['win_turn']<=35
    record={'status':'PASS','training_rows_verified':len(rows),'parked_request_matches':len(rows),'immutable_order_matches':len(rows),'independent_echo_checks':echo_checks,'zero_ETA_facts_verified':zero_eta_checks,'held_seed_or_style_leaks':0}
    dump(OUT/'independent_validation.json',record);print(json.dumps(record))

def report():
    rr=results();rows=json.loads((OUT/'sft_expanded.json').read_text(encoding='utf8'));lin=json.loads((OUT/'sft_lineage.json').read_text(encoding='utf8'))
    audit=json.loads((OUT/'validation.json').read_text(encoding='utf8'));hold=json.loads((OUT/'holdout_definition.json').read_text(encoding='utf8'));variants=json.loads((OUT/'variant_evaluation.json').read_text(encoding='utf8'));perf=json.loads((OUT/'performance.json').read_text(encoding='utf8'))
    accepted={r['game'] for r in rows};lines=['# Code-tested commander growth report','', 'All new gameplay used executable Python policies through the existing manual collector and the real Godot game. No external LLM calls, weight updates, training, or trained-checkpoint evaluation were performed. Original survivor artifacts are unchanged (all source-file SHA256 hashes verified).','', '## Games and rows','', '| Tier | New games played | Won | New games contributing training rows | New games excluded from training | New training rows | Source rows | Final rows |','|---|---:|---:|---:|---:|---:|---:|---:|']
    newgames={r['game'] for r in rr}
    for tier in ['BASIC','INTER']:
        games=[r for r in rr if r['tier']==tier];newrows=[r for r in rows if r['tier']==tier and r['game'] in newgames];oldrows=[r for r in rows if r['tier']==tier and r['game'] not in newgames]
        n=sum(r['game'] in accepted for r in games)
        lines.append('| %s | %d | %d | %d | %d | %d | %d | %d |'%(tier,len(games),sum(r['kind']=='WIN' for r in games),n,len(games)-n,len(newrows),len(oldrows),len(newrows)+len(oldrows)))
    lines+=['','Exclusion counts above include holdout games and parent/variant comparison games not admitted; they are not all gameplay failures. Complete outcomes are in results.jsonl; individual selection reasons are in game_selection.json and dropped_rows.json.','', '## Complete-strategy results (new non-holdout games)','', '| Tier | Strategy | Games | Wins | Win rate | Median / mean / max win turn | Mean friendly losses | Mean survivors | Training games / rows |','|---|---|---:|---:|---:|---|---:|---:|---|']
    for p in perf:
        t,s=p['tier'],p['strategy'];dr=[r for r in rows if r['tier']==t and r['strategy']==s and r['game'] in newgames]
        lines.append('| %s | %s | %d | %d | %.1f%% | %s / %s / %s | %s | %s | %d / %d |'%(t,s,p['games'],p['wins'],100*p['win_rate'],p['median_win_turn'],round(p['mean_win_turn'],2) if p['mean_win_turn'] else None,p['max_win_turn'],round(p['mean_friendly_losses'],2) if p['mean_friendly_losses'] is not None else None,round(p['mean_friendly_survivors'],2) if p['mean_friendly_survivors'] is not None else None,len({r['game'] for r in dr}),len(dr)))
    lines+=['','## Variant results','', 'Each child changes one parameter only. max_focus is a soft preference in the existing executor, not a hard attack cap: when every candidate is saturated, concentration can still occur. The P012 threat_eta variant delays defensive reassignment to avoid premature return pursuits during the full HQ advance. Parent and child use identical seed/style/stat-family/tier cases. Admission requires all 24 matched games per tier, no lower win rate, no slower winning median, mean or maximum, and no higher average unit losses. Holdout results do not participate in this gate.']
    for v in variants:
        lines+=['', '### %s → %s'%(v['parent'],v['child']), '', 'Behavior changed: '+', '.join('%s %s → %s'%(k,vals[0],vals[1]) for k,vals in v['changed'].items())+'.', '', 'Replaced parent: **%s**. %s.'%(v['replaced_parent'],v['reason'])]
        for tier,p in v['performance'].items():
            lines+=['',tier+':', '', '- Parent: '+json.dumps(p['parent']),'- Variant: '+json.dumps(p['variant']),'- Matched gate passed: '+str(p['qualifies'])]
    behavior=json.loads((OUT/'behavioral_audit.json').read_text(encoding='utf8'))
    lines+=['', '### Measured behavioral flags (packet-based review, not performance scoring)', '', '| Tier | Strategy | Decisions | Flagged decisions | Maximum field concentration | Flag reasons |','|---|---|---:|---:|---:|---|']
    for b in behavior:
        if b['holdout']:continue
        reasons={k:v for k,v in b.items() if k not in ['tier','strategy','holdout','decisions','flagged_decisions','max_field_target_concentration','flagged_rate']}
        lines.append('| %s | %s | %d | %d | %d | %s |'%(b['tier'],b['strategy'],b['decisions'],b.get('flagged_decisions',0),b['max_field_target_concentration'],json.dumps(reasons)))
    lines+=['','## Behavioral cleanup','', 'Observed source wins included six attackers assigned to a 50-150 troop scout, repeated concentration on wounded field targets, and wording that advertised focus limits even though the code treats them as a soft preference. New data selects rows conservatively; it never edits played orders.','', 'Excluded row rules: at least four attackers on an unfortified scout of at most 150 visible troops that is more than three turns from our HQ; at least four attackers with near-range minimum preview damage exceeding twice a small target\'s troop upper bound, with no fieldworks or immediate HQ threat; ETA 99 sentinel pursuit; repeated MOVE orders to a waypoint already occupied across three decisions. These are data selection rules, not game scoring. HQ concentration and fortified targets are not rejected merely for having many attackers.','', 'Remaining limitations: soft focus fallback, chasing moving enemies, and movement without meaningful progress can still occur. Only the narrow rules above are mechanically excluded; tactical elegance or optimality is not claimed. Winning but late/high-loss games remain in the results and are excluded rather than described more favorably.','', '## Language diversity','', 'Seeded standard-library wording choices vary battlefield summaries, assignment verbs, clause ordering, memory wording, and standing-plan phrasing. Facts come directly from packets and exact orders; no future result, branch name, policy threshold, or unplayed tactical claim is used. Thinking is capped at 160 words. Standing plans that originally repeat retain the same replacement so the untouched since_turn field stays meaningful. All earlier decisions are reconstructed before row filtering, including predecessors omitted from training.','']
    old=json.loads((SRC/'sft_refined.json').read_text(encoding='utf8'));oldmap={(r['game'],r['turn']):r for r in old};examples=[]
    texts={(x['game'],x['turn']):x for x in json.loads((OUT/'trajectory_texts.json').read_text(encoding='utf8'))}
    lines+=['OLD below is the canonical wording of the same grounded fact set before diversity; NEW is the final varied wording. This isolates wording changes from semantic cleanup. The original source completion is also saved in language_examples.json for a separate cleanup comparison.','']
    for tier in ['BASIC','INTER']:
        cand=[r for r in rows if r['tier']==tier and (r['game'],r['turn']) in oldmap]
        for r in cand:
            if len(examples)>=3:break
            if any(x['strategy']==r['strategy'] for x in examples):continue
            examples.append(r)
            if tier=='BASIC' and len(examples)==2:break
    for i,r in enumerate(examples):
        before=oldmap[(r['game'],r['turn'])];original=json.loads(before['completion'].split('</think>')[1]);b=json.loads(r['completion'].split('</think>')[1]);assert original['orders']==b['orders']
        oldthink,a=words(json.loads(r['messages'][-1]['content']),texts[(r['game'],r['turn'])]['old'],r['game'],False)
        bt=r['completion'].split('</think>')[0].strip()
        assert collections.Counter(re.findall(r'-?\d+',oldthink+a['plan']+a['notes']))==collections.Counter(re.findall(r'-?\d+',bt+b['plan']+b['notes']))
        lines+=['### Example %d: %s, turn %d'%(i+1,r['game'],r['turn']),'','| OLD | NEW |','|---|---|','| '+oldthink.replace('\n','<br>').replace('|','\\|')+' | '+bt.replace('\n','<br>').replace('|','\\|')+' |','| Plan: '+a['plan'].replace('|','\\|')+' | Plan: '+b['plan'].replace('|','\\|')+' |','| Notes: '+a['notes'].replace('|','\\|')+' | Notes: '+b['notes'].replace('|','\\|')+' |','', 'Exact unchanged orders: `'+json.dumps(b['orders'])+'`','']
    dump(OUT/'language_examples.json',[{'game':r['game'],'turn':r['turn'],'old_canonical':words(json.loads(r['messages'][-1]['content']),texts[(r['game'],r['turn'])]['old'],r['game'],False),'original_source':oldmap[(r['game'],r['turn'])]['completion'],'new':r['completion']} for r in examples])
    lines+=['## Text validation','', '```json',json.dumps(audit,indent=2),'```','', 'Independent saved-file validation:','', '```json',(OUT/'independent_validation.json').read_text(encoding='utf8'),'```','', 'Rows checked counts admitted game candidates plus holdout decisions. Losses and disqualified games are retained as evidence, not training candidates. Rejection reasons can overlap. Text is regenerated from grounded facts, so old unsupported rationale and plan claims are not carried forward. Numeric preview ranges, force counts, IDs, ETA 0, immutable orders, exact parked requests, unchanged non-echo packet fields, and previous-decision history/current_plan echoes are checked mechanically.','', '## Final dataset','', '- Path: `'+str(OUT/'sft_expanded.json')+'`','- Total rows: '+str(len(rows)),'- BASIC / INTER: %d / %d'%(sum(r['tier']=='BASIC' for r in rows),sum(r['tier']=='INTER' for r in rows)),'- Unique games / strategies / accepted variants: %d / %d / %d'%(audit['unique_games'],audit['unique_strategies'],audit['unique_variants']),'- Winning turns by unique contributing game: '+json.dumps(dict(sorted(collections.Counter(m['win_turn'] for m in {x['game']:x for x in lin}.values()).items()))),'', '## Hold-out','', '- Definition: `holdout_definition.json`; actual outcomes: `holdout_results.json`; complete decision trajectories: `holdout_decisions.json`.','- BASIC / INTER played cases: %d / %d'%(sum(r['stage']=='holdout' and r['tier']=='BASIC' for r in rr),sum(r['stage']=='holdout' and r['tier']=='INTER' for r in rr)),'- Held seeds: %d; held opponent styles: %d (%s).'%(len(hold['seeds']),len(hold['styles']),', '.join(hold['styles'])),'- No held seed or style appears in final training lineage. Complete trajectories are fingerprinted using non-echo packet state and orders; duplicate copies are excluded.','- HARRIER is unseen in this prepared training set, but original survivor selection had already tested teachers on that style. Thus this is a learner holdout, not a strategy-selection-blind holdout. Fresh held seeds were reserved before collection; no holdout result influences variant admission.','', '## Problems and practical limits','', '- Current collection outcomes: '+json.dumps(dict(collections.Counter(r['kind'] for r in rr))),'- Technical errors: '+(OUT/'technical_errors.json').read_text(encoding='utf8'),'- Collector slot 2 and its 8098/8108 ports were preserved. This campaign owns slots 0 and 5, proxy/brain ports 8200/8201 and 8210/8211, and CPU mount workers 11460/11465. No model was used for commander decisions; the existing CPU Hands mount is required by collector startup but never commands these games.','- New seed evaluation found weaker/late results despite historical 5/5 survivor status. Fast-game filtering is not a claim of universal policy reliability; performance.json retains complete tier-specific denominators and failure modes.','- This remains the existing STEP0_SANDBOX HQ battle distribution, with four stat families and three training styles. New maps, army compositions, terrain and fog patterns were not added.','- Same-seed fresh-process determinism was not separately established; paired evaluation uses the same configured situations. No exact determinism claim is made.','- Source packet history omissions are preserved; only echoed plan/notes change. Dropped decisions still exist in trajectory_texts.json, so later retained rows consistently reflect them.','- INTER volume: %d rows (%.1f%% of final set).'%(sum(r['tier']=='INTER' for r in rows),100*sum(r['tier']=='INTER' for r in rows)/max(1,len(rows))),'- Entire frozen campaign completed: '+str(audit['complete_campaign']), '', '## Reproduce','', 'From the project root:', '', '```powershell','python -m tools.plan_search.commander_growth prepare','python -m tools.plan_search.survivor_search --out artifacts/brain_pipeline_v1/commander_growth_20261007 --jobs artifacts/brain_pipeline_v1/commander_growth_20261007/smoke_jobs.json --slots 0 --windows 2','python -m tools.plan_search.survivor_search --out artifacts/brain_pipeline_v1/commander_growth_20261007 --jobs artifacts/brain_pipeline_v1/commander_growth_20261007/jobs.json --slots 0,5 --windows 8','python -m tools.plan_search.commander_growth export','python -m tools.plan_search.commander_growth validate','python -m tools.plan_search.commander_growth report','```','', 'prepare intentionally refuses to overwrite the artifact directory. For replay in a separate directory, set OUT in the archived script copy. Recheck actual occupied slots and ports before resuming. jobs.json and population.json contain the frozen exact assignments. Existing completed game IDs are skipped.']
    start=lines.index('## Reproduce')
    lines[start:]=['## Runtime and reproducibility','', '- Sum of newly played game wall times: %.1f seconds.'%sum(r.get('wall_s',0) for r in rr),'- Slots used: 0, 5, 6 and 7; proxy/brain ports 8200/8201, 8210/8211, 8212/8213 and 8214/8215; CPU mount ports 11460, 11465, 11466 and 11467. Maximum simultaneous arena count was 26.','- Collector failures and render errors are retained in technical_errors.json and each result\'s execution_diagnostics.','', 'To replay the final frozen population and all jobs into a new directory, run from the project root:','', '```powershell','& ".\\artifacts\\brain_pipeline_v1\\commander_growth_20261007\\reproduce\\replay.ps1" -OutputDirectory "'+str(OUT.parent/'commander_growth_replay')+'"','```','', 'The replay script checks occupied collector slots and listening ports, excludes reserved slots, refuses to overwrite an existing directory, copies the frozen configuration, then runs the real-game collector and all export/validation/report steps. Its PowerShell syntax was checked; the full second replay was not run because the original complete campaign already supplies the required real-game evidence.','', 'The initial prepare command sets up the first campaign. inter_extension and hq_timing_variant are additional experiments recorded in the final jobs.json/population.json. Replay uses those frozen final files, including all experiments.','', 'To refresh finalization of this completed campaign:','', '```powershell','python -m tools.plan_search.commander_growth finalize','```','', 'Snapshots of commander_growth.py, survivor_search.py and the immutable policy executor are stored in reproduce/. Source hashes cover the original artifacts and 37 execution source files (the execution-code snapshot was taken after the small pilot, before later experiments). Current execution code must match the snapshot for final validation. The normal Godot game and its existing helpers are required.','', '## Hold-out teacher baseline','', 'Each tier has 16 unique reserved situations and 32 teacher games. Future Qwen evaluation should use the 32 distinct evaluation_situations, not count the two teacher policies as separate situations.','', '```json',(OUT/'holdout_summary.json').read_text(encoding='utf8'),'```']
    if (OUT/'execution_accounting.json').exists():
        acc=json.loads((OUT/'execution_accounting.json').read_text(encoding='utf8'))
        lines[1:1]=['','**Status: validated historical training package; collection interrupted before all planned games completed.** %d terminal games were retained for accounting; %d started games have no terminal result, and %d jobs never started. All partial trajectories are excluded.'%(acc['completed_games'],len(acc['interrupted_games']),len(acc['not_started_games'])),'']
        lines=[s.replace('New games played','Completed new games').replace('Each tier has 16 unique reserved situations and 32 teacher games.','Each tier has 16 unique reserved situations and 32 planned teacher games; actual terminal teacher games are BASIC 32 and INTER 6.').replace('Current execution code must match the snapshot for final validation.','The immutable policy executor must match for static capture validation. Exact future engine replay requires the historical execution sources; live-project changes are never overwritten.') for s in lines]
        lines+=['','## Interruption and source changes','', '- Planned games: %d; started: %d; completed with terminal outcome: %d; interrupted: %d; not started: %d.'%(acc['planned_games'],acc['completed_games']+len(acc['interrupted_games']),acc['completed_games'],len(acc['interrupted_games']),len(acc['not_started_games'])),'- The interrupted games are all INTER: 16 holdout and 5 extension games. Another 10 INTER holdout jobs never started. No interrupted trajectory is a training example, a win, or a measured loss. See execution_accounting.json for exact assignments.','- Final collection stopped at the original interrupted turn; later source changes and collectors occupying slots 0/1 were discovered on resume. No other collector was stopped, and no new game was mixed into the historical collection under the changed game revision.','- Six execution files now differ from the recorded source hashes. Four changed Godot/commander files were modified on 2026-10-08, after the final captured call at 2026-10-07 23:45:13 KST. The policy executor is unchanged, and every terminal captured decision was replayed exactly. Detailed hashes/timestamps are in execution_source_drift.json.','- The coordinator\'s one later parsing edit was reversed in an archived copy only; survivor_search_historical.py matches the historical SHA256. Live files were not changed. Full historical Godot source bodies were not archived, so exact engine replay requires recovering those sources to match the recorded hashes. replay.ps1 refuses a replay with mismatched execution sources.','- Static SFT regeneration and validation from the saved requests, replies, trajectories and terminal results pass. The final set matches the captured original commander protocol. Compatibility with the subsequently changed live prompt/packet format must be checked before later training/integration. No training or current-format migration was attempted.','- Holdout definition still reserves all 32 unique cases and all HARRIER games from training. BASIC teacher baseline is complete; INTER baseline covers 6 of 16 distinct reserved situations, with 26 planned teacher games lacking terminal results. Future learner evaluation cases are fully defined; do not present the INTER teacher baseline as complete.']
    (OUT/'REPORT.md').write_text('\n'.join(lines)+'\n',encoding='utf8')
    print('report',OUT/'REPORT.md')

def finalize(available=False):
    rr=results();expected=json.loads((OUT/'jobs.json').read_text(encoding='utf8'))
    assert len(rr)==len({r['game'] for r in rr})
    if not available:assert {r['game'] for r in rr}=={j['game'] for j in expected},'collection incomplete'
    else:assert (OUT/'execution_accounting.json').exists(),'partial accounting required'
    if not (OUT/'merged_extension.json').exists():
        (OUT/'results.jsonl').write_text(''.join(json.dumps(r,ensure_ascii=False)+'\n' for r in rr),encoding='utf8')
        dump(OUT/'merged_extension.json',{'sources':{part:len(readjsonl(OUT/part/'results.jsonl')) for part in PARTS},'total':len(rr)})
        errors=json.loads((OUT/'technical_errors.json').read_text(encoding='utf8'))
        for part in PARTS:
            f=OUT/part/'technical_errors.json'
            if f.exists():errors+=json.loads(f.read_text(encoding='utf8'))
        if available:
            for j in json.loads((OUT/'execution_accounting.json').read_text(encoding='utf8'))['interrupted_games']:errors.append({'game':j['game'],'kind':'COLLECTOR_INTERRUPTION','error':'No terminal game result; partial trajectory excluded'})
        dump(OUT/'technical_errors.json',errors)
    # The legacy runner's generic nomination description does not apply to frozen jobs.
    for configpath in [OUT/'search_config.json']+[OUT/part/'search_config.json' for part in PARTS]:
        c=json.loads(configpath.read_text(encoding='utf8'));c['eligibility']='Frozen code-only jobs; admission is defined by campaign_config.json and commander_growth.py';c['repeat_budget']='No nomination; exact jobs.json assignments';dump(configpath,c)
    export();validate();report()
    code=OUT/'reproduce';code.mkdir(exist_ok=True)
    for name in ['commander_growth.py','survivor_search.py','survivor_policy.py']:
        (code/name).write_bytes((ROOT/'tools/plan_search'/name).read_bytes())
    dump(OUT/'artifact_hashes.json',{str(p.relative_to(OUT)):hashlib.sha256(p.read_bytes()).hexdigest() for p in OUT.glob('*') if p.is_file() and p.name!='artifact_hashes.json'})

if __name__=='__main__':
    ap=argparse.ArgumentParser();ap.add_argument('mode',choices=['prepare','export','validate','report','finalize','seal-available']);a=ap.parse_args()
    finalize(available=True) if a.mode=='seal-available' else globals()[a.mode]()
