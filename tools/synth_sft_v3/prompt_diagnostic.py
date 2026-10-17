"""Read-only summary of the first differing replay prompt message."""
import json
import sys
from tools.synth_sft_v3.crosscheck import SYN, situations, jl

def main():
    batch=sys.argv[1]; s=situations()
    d=SYN/'xcheck'/batch
    for b in jl(d/'branches.jsonl'):
        if not b['id'].startswith('V__'): continue
        f=d/'requests'/(b['id']+'.json')
        if not f.exists(): continue
        sid=b['id'][3:].rsplit('__',1)[0]
        a=s[sid]['messages']; r=json.loads(f.read_text(encoding='utf-8'))
        if a==r: continue
        print('BRANCH',b['id'],'messages original',len(a),'replay',len(r))
        for i,(x,y) in enumerate(zip(a,r)):
            if x==y: continue
            print('FIRST_DIFF',i,'roles',x.get('role'),y.get('role'))
            xc=x.get('content',''); yc=y.get('content','')
            try:
                xd=json.loads(xc); yd=json.loads(yc)
                print('ORIGINAL_CHANGED_KEYS',json.dumps({k:v for k,v in xd.items() if yd.get(k)!=v},ensure_ascii=False)[:4000])
                print('REPLAY_CHANGED_KEYS',json.dumps({k:v for k,v in yd.items() if xd.get(k)!=v},ensure_ascii=False)[:4000])
            except (ValueError,TypeError):
                at=next((j for j,(xx,yy) in enumerate(zip(xc,yc)) if xx!=yy),min(len(xc),len(yc)))
                print('CONTENT_DIFF_OFFSET',at,'original',repr(xc[max(0,at-100):at+400]),'replay',repr(yc[max(0,at-100):at+400]))
            break
        return

if __name__=='__main__': main()
