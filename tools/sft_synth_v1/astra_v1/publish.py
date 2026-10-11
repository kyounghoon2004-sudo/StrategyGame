"""Publish an audited Astra extraction into requested root. Run only after parent checks.

Old root artifacts are snapshotted once under pre_astra_publish/ before replacement.
Native prior stage evidence is never edited or re-audited with new policy sources.
"""
from __future__ import annotations
import json
import shutil
import hashlib
from pathlib import Path
from .extract import OUT

def read(p,default):
    return json.loads(p.read_text(encoding='utf-8-sig')) if p.exists() else default

def write(p,x):
    p.write_text(json.dumps(x,ensure_ascii=False,indent=2),encoding='utf-8')

def digest(p):
    return hashlib.sha256(p.read_bytes()).hexdigest()

def combine(old,new):
    merged={}
    for row in old+new:
        key=(row['game'],row['turn'])
        if key in merged and merged[key]!=row:raise ValueError('Conflicting frozen row '+str(key))
        merged[key]=row
    return list(merged.values())

def main():
    root=OUT.parent;backup=root/'pre_astra_publish';backup.mkdir(exist_ok=True)
    names=['REPORT.md','PATTERNS.md','sft_rows.json','sft_lost_rows.json','sft_rejected_winner_rows.json',
           'sft_transform_lineage.json','validation.json','coverage_counts.json','generator_gates.json']
    for name in names:
        src=root/name;dst=backup/name
        if src.exists() and not dst.exists():shutil.copy2(src,dst)
    # Human-visible historical report alias requested by parent.
    if (backup/'REPORT.md').exists() and not (root/'REPORT_pre_astra.md').exists():shutil.copy2(backup/'REPORT.md',root/'REPORT_pre_astra.md')
    summary=read(OUT/'extraction_summary.json',None)
    if summary is None:raise ValueError('Run audited extraction first')
    training=read(OUT/'sft_rows.json',None);lineage=read(OUT/'sft_transform_lineage.json',None)
    if training is None or lineage is None:raise ValueError('Missing extracted rows/lineage')
    if read(backup/'sft_rows.json',[]):raise ValueError('Unexpected previously admitted rows; do not silently replace')
    if len(training)!=summary['training_rows'] or {(r['game'],r['turn']) for r in training}!={(r['game'],r['turn']) for r in lineage}:
        raise ValueError('Extraction summary/lineage mismatch')
    # No new inference, normalization or prose edits at publish time.
    for name in ['sft_rows.json','sft_transform_lineage.json']:shutil.copy2(OUT/name,root/name)
    for name in ['sft_lost_rows.json','sft_rejected_winner_rows.json']:
        write(root/name,combine(read(backup/name,[]),read(OUT/name,[])))
    old=read(backup/'validation.json',{})
    aggregate={'prior_frozen':old,'astra':summary,'games':old.get('games',45)+summary['games'],
               'verified_wins':old.get('wins',0)+summary['verified_wins'],
               'training_rows':len(training),'admitted_games':summary['admitted_games'],
               'status':summary['status'],'full_coverage':False,'direct_teacher_fraction':None if not training else 0,
               'direct_teacher_mixture':'MISSING','old_evidence_reaudited':False,
               'note':'Old results remain frozen; current Astra audits/extraction supersede only deliverable summary.'}
    write(root/'validation.json',aggregate)
    # Old and new gates stay attributed, never pooled to fabricate a pass.
    write(root/'generator_gates.json',
          [dict(g,source_campaign='prior_frozen') for g in read(backup/'generator_gates.json',[])]+
          [dict(g,source_campaign='astra_v1') for g in read(OUT/'generator_gates.json',[])])
    previous={tuple(c['cell']):c for c in read(backup/'coverage_counts.json',[])}
    combined=[]
    for c in read(OUT/'coverage_counts.json',[]):
        prior=previous.get(tuple(c['cell']),{})
        combined.append(dict(c,prior_played=prior.get('played',0),prior_won=prior.get('won',0),
                             total_played=prior.get('played',0)+c['played'],total_won=prior.get('won',0)+c['won'],
                             status='PRIOR_FAILED_NO_NEW_MEASUREMENT' if not c['played'] and prior.get('played',0) else c['status']))
    write(root/'coverage_counts.json',combined)
    oldpatterns=(backup/'PATTERNS.md').read_text(encoding='utf-8-sig') if (backup/'PATTERNS.md').exists() else ''
    newpatterns=(OUT/'PATTERNS.md').read_text(encoding='utf-8-sig')
    for document in ['V2_CONDITIONAL_DESIGN.md','CLOSURE_PATTERNS.md','FAILURES.md','NEXT_CELLS.md']:
        if (OUT/document).exists():newpatterns+='\n\n---\n\n'+(OUT/document).read_text(encoding='utf-8-sig')
    (root/'PATTERNS.md').write_text(oldpatterns+'\n\n---\n\n# Astra addition (supersedes no frozen evidence)\n\n'+newpatterns,encoding='utf-8')
    astra_report=(OUT/'REPORT.md').read_text(encoding='utf-8-sig')
    intro=['# Synthetic commander SFT — combined delivery','',
           f"Prior frozen campaign: {old.get('games',45)} games, {old.get('wins',0)} verified wins, 0 admitted rows. New Astra: {summary['games']} games, {summary['verified_wins']} verified wins. Combined: {aggregate['games']} games. Current deliverable: {summary['admitted_games']} admitted games / {len(training)} SFT rows.",'',
           'This report supersedes the old root status. The historical report is REPORT_pre_astra.md; original reports/data are retained in pre_astra_publish/. Prior native stage games and calls were neither modified nor re-audited with newer sources.',
           '', 'No full-coverage or teacher-mixture claim is made. The frozen baseline38/1170 and separate closure54/1639 are distinguished below; all54 closure teacher games contain a tactical hint and remain pattern evidence. Interrupted closure IDs are excluded. Direct teacher mixture is missing. Held-out evaluation, model training and deployment were not performed.', '', astra_report]
    (root/'REPORT.md').write_text('\n'.join(intro),encoding='utf-8')
    write(root/'astra_publish_manifest.json',{'generation_author':'GPT-6 Astra','reasoning':'medium',
          'source_package':str(OUT),'backup':str(backup),
          'teacher_source_facts':summary.get('teacher_source_facts'),
          'published_hashes':{name:digest(root/name) for name in names if (root/name).exists()},
          'admitted_generator_versions':sorted({(r.get('generation_version','unknown'),r['pattern'],r['generator_sha256']) for r in training}),
          'backup_hashes':{p.name:digest(p) for p in backup.iterdir() if p.is_file()},
          'root_rows_exact_copy':digest(root/'sft_rows.json')==digest(OUT/'sft_rows.json')})
    print(json.dumps(aggregate))

if __name__=='__main__':main()
