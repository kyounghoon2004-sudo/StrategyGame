"""Read-only consistency audit of admitted rows against engine/provenance journals."""
import hashlib
import json
from collections import Counter
from tools.synth_sft_v3 import crosscheck as X

def main():
    p = X.SYN / 'synth_rows_v3_verified.json'
    rows = json.loads(p.read_text(encoding='utf-8-sig'))
    authored = {(r['sid'],r['variant']):r for r in X.jl(X.SYN/'authored_v3.jsonl')}
    latest = {(r['sid'],r['variant']):r for r in X.jl(X.SYN/'crosscheck_v3.jsonl')}
    source = X.situations({f"{r['game']}__t{r['turn']}" for r in rows})
    errors=[]; seen=set(); evidence=[]
    for i,r in enumerate(rows):
        sid=f"{r['game']}__t{r['turn']}"; key=(sid,r['variant'])
        a=authored.get(key); v=latest.get(key); s=source.get(sid)
        problems=[]
        if not a or a.get('status')=='AUTHOR_REJECTED': problems.append('missing or rejected author source')
        if not v or not v.get('pass') or v.get('status')!='PASS' or v.get('no_contact'): problems.append('no admissible engine verdict')
        if not s or r['messages']!=s['messages']: problems.append('source message mismatch')
        if a and r['completion']!=json.loads(a['answer']): problems.append('source answer mismatch')
        if r.get('mission')!='collapse70' or r.get('source')!='synth_v3': problems.append('wrong mission/source')
        if s and X.check(s,json.dumps(r['completion'])): problems.append('invalid/no-op completion')
        dedup=(sid,json.dumps(r['completion'],sort_keys=True))
        if dedup in seen: problems.append('duplicate situation/answer')
        seen.add(dedup)
        if v and s:
            d=X.XC/v['batch']; bfile=d/'branches.jsonl'
            branch=next((b for b in X.jl(bfile) if b['id']==X.bid(sid,r['variant'])),None)
            if not branch: problems.append('missing source branch')
            else:
                actual=X.facts(d/'games'/(branch['id']+'.json'),s['turn'],branch['horizon'])
                if actual!=v['candidate']: problems.append('engine game facts differ from journal')
                control=v['control']
                ctrlbranch=next((b for b in X.jl(bfile) if b['id']==X.bid(sid)),None)
                if ctrlbranch:
                    rawcontrol=X.facts(d/'games'/(ctrlbranch['id']+'.json'),s['turn'],ctrlbranch['horizon'])
                    if rawcontrol!=control: problems.append('raw control facts differ from journal')
                    ctrlreq=d/'requests'/(ctrlbranch['id']+'.json')
                    if not ctrlreq.exists() or json.loads(ctrlreq.read_text(encoding='utf-8'))!=r['messages']:
                        problems.append('control engine prompt mismatch')
                if not actual or not X.verdict(control,actual)[0]: problems.append('engine criteria fail')
                req=d/'requests'/(branch['id']+'.json')
                if not req.exists() or json.loads(req.read_text(encoding='utf-8'))!=r['messages']:
                    problems.append('engine prompt mismatch')
                evidence.append({'row':i,'sid':sid,'variant':r['variant'],'branch':branch['id'],'batch':v['batch']})
        if problems: errors.append({'row':i,'key':key,'problems':problems})
    selected=[a for a in authored.values() if a.get('status')!='AUTHOR_REJECTED']
    unresolved=[{'sid':a['sid'],'variant':a['variant']} for a in selected if (a['sid'],a['variant']) not in latest or latest[(a['sid'],a['variant'])].get('status')=='TECHNICAL']
    result={'admitted_rows':len(rows),'errors':errors,'selected_candidates':len(selected),'unresolved_candidates':len(unresolved),
            'remaining':unresolved,'tier_counts':dict(Counter(r['tier'] for r in rows)),
            'product_sha256':hashlib.sha256(p.read_bytes()).hexdigest(),'evidence':evidence,
            'status':'PASS' if not errors else 'FAIL','all_candidates_resolved':not unresolved}
    (X.SYN/'product_audit_v3.json').write_text(json.dumps(result,ensure_ascii=False,indent=2),encoding='utf-8')
    print(json.dumps({k:v for k,v in result.items() if k not in ('remaining','evidence','errors')}))
    if errors: raise SystemExit('Product audit found '+str(len(errors))+' inconsistent rows')

if __name__=='__main__':main()
