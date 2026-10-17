"""Preserve rejected author attempts with unique audit keys; never schedule them.

Run after scheduler ingestion completes (all parts in scheduler.json), avoiding
concurrent append writers. Existing selected candidates keep their original key.
"""
import hashlib
import json
from tools.synth_sft_v3.crosscheck import SYN, jl

def main():
    current=jl(SYN/'authored_v3.jsonl')
    have={(r['sid'],r['variant']) for r in current}
    added=[]
    for part in sorted((SYN/'parts').glob('v3_*_rejected.jsonl')):
        for index,row in enumerate(jl(part)):
            original=row['variant']
            variant=f'draft__{original}__{part.stem}__{index:05d}'
            if (row['sid'],variant) in have: continue
            r=dict(row,variant=variant,original_variant=original,status='AUTHOR_REJECTED',
                   author_rejection_reasons=row.get('rejection_reasons',[]),draft_source=part.name,draft_index=index)
            added.append(r); have.add((r['sid'],variant))
    with (SYN/'authored_v3.jsonl').open('a',encoding='utf-8') as f:
        for r in added: f.write(json.dumps(r,ensure_ascii=False)+'\n')
    with (SYN/'exclusions_v3.jsonl').open('a',encoding='utf-8') as f:
        for r in added: f.write(json.dumps(r,ensure_ascii=False)+'\n')
    print(f'Preserved {len(added)} new rejected drafts; selected candidates unchanged.')

if __name__=='__main__': main()
