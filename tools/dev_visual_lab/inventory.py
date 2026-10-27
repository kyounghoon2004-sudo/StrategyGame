from pathlib import Path
import json, struct, hashlib, os, argparse
root=Path(__file__).resolve().parents[2]
parser=argparse.ArgumentParser()
parser.add_argument("--out", default=os.environ.get("SG_DEV_LAB_OUT", str(root/"artifacts/dev_visual_lab")))
out=Path(parser.parse_args().out)
out.mkdir(parents=True,exist_ok=True)
rows=[]
for p in sorted((root/'assets').rglob('*')):
    if not p.is_file() or p.suffix.lower() not in {'.glb','.gltf','.scn','.tscn','.res','.tres','.fbx'}: continue
    row={'path':p.relative_to(root).as_posix(),'bytes':p.stat().st_size}
    if p.suffix.lower()=='.glb':
        try:
            with p.open('rb') as f:
                magic,version,length=struct.unpack('<4sII',f.read(12))
                size,kind=struct.unpack('<II',f.read(8))
                doc=json.loads(f.read(size))
            acc=doc.get('accessors',[])
            triangles=0;vertices=0;parts=0
            for m in doc.get('meshes',[]):
                for q in m['primitives']:
                    parts+=1
                    n=acc[q['attributes']['POSITION']]['count']; vertices+=n
                    n=acc[q['indices']]['count'] if 'indices' in q else n
                    mode=q.get('mode',4)
                    triangles+=n//3 if mode==4 else max(0,n-2) if mode in (5,6) else 0
            row.update(meshes=len(doc.get('meshes',[])),primitives=parts,vertices=vertices,triangle_list_equivalent=triangles,skins=[len(s.get('joints',[])) for s in doc.get('skins',[])],animations=[a.get('name','unnamed') for a in doc.get('animations',[])],materials=len(doc.get('materials',[])),images=len(doc.get('images',[])))
        except Exception as e: row['parse_error']=str(e)
    rows.append(row)
protected=[p for p in (root/'data/battlefields/tutorial_v1').rglob('*') if p.is_file()]
protected += [root/'scripts/gx_missions'/p for p in ['mission_rules.gd','mission_play_mount.gd','mission_config.gd','gx_missions_config.json']]
if not (out/'protected-before.json').exists(): (out/'protected-before.json').write_text(json.dumps({p.relative_to(root).as_posix():hashlib.sha256(p.read_bytes()).hexdigest() for p in protected},indent=2),encoding='utf8')
(out/'asset-inventory.json').write_text(json.dumps(rows,indent=2),encoding='utf8')
units=[r for r in rows if r['path'].startswith('assets/units/') and r['path'].endswith('.glb')]
print(json.dumps({'resource_count':len(rows),'glb_count':sum(r['path'].endswith('.glb') for r in rows),'fbx_count':sum(r['path'].endswith('.fbx') for r in rows),'unit_glbs':units},indent=2))

