"""Copy the teacher's frozen gameplay sources; mutations stay in our own runtime."""
from __future__ import annotations
import hashlib
import json
import shutil
import subprocess
from pathlib import Path
from .analyze import ROOT, OUT, COLLECTION, sha

def main():
    src=COLLECTION/'smoke_remaining30/runtime';dst=OUT/'runtime'
    if (OUT/'runtime_manifest.json').exists():
        print('Snapshot exists; verify it instead of overwriting.');return
    dst.mkdir(parents=True,exist_ok=True)
    for name in ['scripts','scenes','addons','data','.godot','dev']:
        if (src/name).exists():shutil.copytree(src/name,dst/name,dirs_exist_ok=True)
    for name in ['project.godot','icon.svg','icon.svg.import']:
        shutil.copy2(src/name,dst/name)
    # Do not copy or write other packages. Assets/checkpoints are referenced for runtime reading only.
    for name in ['assets','artifacts']:
        if not (dst/name).exists():
            subprocess.run(['powershell','-NoProfile','-Command',f"New-Item -ItemType Junction -Path '{dst/name}' -Target '{ROOT/name}' | Out-Null"],check=True)
    (dst/'tools').mkdir(exist_ok=True)
    shutil.copy2(ROOT/'tools/rl_arena.gd',dst/'tools/rl_arena.gd')
    # Disable the unused legacy mount's model workflow for commander/GX-only collection.
    # A real CPU Hands worker will satisfy the existing boot handshake; it is never used to choose orders.
    mission=dst/'scripts/cloud_pipeline/commander_mission.gd'
    text=mission.read_text(encoding='utf-8')
    start=text.index('\tif enabled() and not head.contains("Focus fire:"):')
    end=text.index('\treturn canonical_text',start)
    mission.write_text(text[:start]+text[end:],encoding='utf-8',newline='\n')
    commander=dst/'scripts/cloud_pipeline/commander_controller.gd'
    text=commander.read_text(encoding='utf-8')
    text=text.replace('Focus fire: prefer attacking the same BLUE unit with two or more of your units in the same turn, so it is destroyed\nbefore it can strike back again.\n','')
    commander.write_text(text,encoding='utf-8',newline='\n')
    cfg=dst/'project.godot';t=cfg.read_text(encoding='utf-8')
    t=t.replace('Commander SFT Smoke30','Commander Synthetic SFT V1').replace('CommanderSFTSmoke30','CommanderSFTSynthV1')
    t=t.replace('\nname="Commander Synthetic SFT V1"','\nconfig/name="Commander Synthetic SFT V1"')
    # Runtime editor connector / shadow monitoring are unrelated and can open colliding ports or files.
    t='\n'.join(l for l in t.splitlines() if not l.startswith(('MCPRuntimeServer=','JevShadowRuntime=')))+'\n'
    cfg.write_text(t,encoding='utf-8',newline='\n')
    manifest={}
    for folder in ['scripts','scenes','addons','data','dev','tools']:
        for f in (dst/folder).rglob('*'):
            if f.is_file():
                rel=f.relative_to(dst).as_posix();original=src/rel
                manifest[rel]={'runtime_sha256':sha(f.read_bytes()),'teacher_runtime_sha256':sha(original.read_bytes()) if original.exists() else None,
                               'production_sha256':sha((ROOT/rel).read_bytes()) if (ROOT/rel).exists() else None}
    (OUT/'runtime_manifest.json').write_text(json.dumps(manifest,indent=2),encoding='utf-8')
    print(json.dumps({'runtime':str(dst),'files':len(manifest),'hint_removed_at_emission':True,'user_directory':'CommanderSFTSynthV1'}))

if __name__=='__main__':main()
