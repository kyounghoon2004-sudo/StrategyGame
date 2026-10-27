from pathlib import Path
import json,struct,hashlib,collections,re,os,argparse
root=Path(__file__).resolve().parents[2]
parser=argparse.ArgumentParser()
parser.add_argument("--out",default=os.environ.get("SG_ENV_LAB_OUT",str(root/"artifacts/dev_environment_lab")))
out=Path(parser.parse_args().out)
out.mkdir(parents=True,exist_ok=True)
def sha(p): return hashlib.sha256(p.read_bytes()).hexdigest()
def glb_counts(p):
    if p.suffix.lower()!='.glb': return {}
    with p.open('rb') as f:
        f.read(12);n,t=struct.unpack('<II',f.read(8));doc=json.loads(f.read(n))
    accessors=doc.get('accessors',[]);triangles=0;vertices=0;parts=0
    for mesh in doc.get('meshes',[]):
        for primitive in mesh.get('primitives',[]):
            parts+=1
            count=accessors[primitive['attributes']['POSITION']]['count'];vertices+=count
            count=accessors[primitive['indices']]['count'] if 'indices' in primitive else count
            mode=primitive.get('mode',4)
            triangles+=count//3 if mode==4 else max(0,count-2) if mode in (5,6) else 0
    return {'meshes':len(doc.get('meshes',[])),'primitives':parts,'vertices':vertices,'triangle_list_equivalent':triangles,'materials':len(doc.get('materials',[])),'images':len(doc.get('images',[]))}

source_text=[]
for directory in ('scripts/visual','scripts/ui','tools'):
    for p in (root/directory).rglob('*.gd'):
        if any(x in p.parts for x in ('synth_adv_v1','cmd_rl','cloud_pipeline','dev_visual_lab')): continue
        source_text.append((p.relative_to(root).as_posix(),p.read_text(encoding='utf-8-sig',errors='replace')))
entries=[];allfiles=[];protected={}
for p in sorted((root/'assets').rglob('*')):
    if not p.is_file() or p.suffix=='.import': continue
    path=p.relative_to(root).as_posix()
    if path.startswith('assets/units/') or path.startswith(('assets/ui/','assets/badges/','assets/sprites/','assets/audio/')): continue
    if any(x in path for x in ('/formations/','/ui/','/advisor_overlays/')): continue
    digest=sha(p);protected[path]=digest
    row={'id':digest[:10]+'_'+hashlib.sha256(path.encode()).hexdigest()[:6], 'path':path,'bytes':p.stat().st_size,'sha256':digest}
    row['family']=str(p.parent.relative_to(root)).replace(chr(92),'/')
    if p.suffix.lower() in ('.glb','.scn','.res'):
        row['kind']='model'
        row['role']='source' if '/source_glb/' in path else 'strategy_source' if '/strategy_lod/src/' in path else 'derivative'
        row.update(glb_counts(p))
        if p.suffix.lower()=='.glb':
            with p.open('rb') as f:
                f.read(12);n,t=struct.unpack('<II',f.read(8)); doc=json.loads(f.read(n))
            row['missing_external_images']=[im['uri'] for im in doc.get('images',[]) if 'uri' in im and not im['uri'].startswith('data:') and not (p.parent/im['uri']).exists()]
            row['generator']=doc.get('asset',{}).get('generator')
            row['materials_flags']=[{'name':m.get('name',''), 'double_sided':m.get('doubleSided',False),'alpha':m.get('alphaMode','OPAQUE'),'roughness':m.get('pbrMetallicRoughness',{}).get('roughnessFactor',1),'metallic':m.get('pbrMetallicRoughness',{}).get('metallicFactor',1),'base_color_texture':'baseColorTexture' in m.get('pbrMetallicRoughness',{})} for m in doc.get('materials',[])]
            row['vertex_color_primitives']=sum('COLOR_0' in pr.get('attributes',{}) for m in doc.get('meshes',[]) for pr in m.get('primitives',[]))
        entries.append(row)
    elif p.suffix.lower() in ('.png','.webp','.jpg','.jpeg'):
        if '/map_composition_v0/' in path:
            row['kind']='model_texture_or_reference'
        else:
            row['kind']='raster'
            row['role']='2d_environment'
            if p.suffix.lower()=='.png':
                with p.open('rb') as f:
                    f.seek(16);row['width'],row['height']=struct.unpack('>II',f.read(8))
            entries.append(row)
    else: row['kind']='metadata_or_source'
    refs=[name for name,text in source_text if path in text or ('res://'+str(p.parent.relative_to(root)).replace(chr(92),'/')+'/') in text]
    row['literal_reference_files']=refs[:15]
    row['reference_note']='Literal file/directory matches only; not proof of runtime use or non-use.'
    allfiles.append(row)
for p in (root/'data/battlefields/tutorial_v1').rglob('*'):
    if p.is_file():protected[p.relative_to(root).as_posix()]=sha(p)
for name in ('mission_rules.gd','mission_play_mount.gd','mission_config.gd','gx_missions_config.json'):
    p=root/'scripts/gx_missions'/name;protected[p.relative_to(root).as_posix()]=sha(p)
# A model containing only part of a larger mesh is intentionally still listed for full audit coverage.
(out/'catalogue.json').write_text(json.dumps({'project_root':str(root),'entries':entries},ensure_ascii=False,indent=2),encoding='utf8')
(out/'inventory.json').write_text(json.dumps({'files':allfiles,'counts_by_kind':dict(collections.Counter(r['kind'] for r in allfiles))},ensure_ascii=False,indent=2),encoding='utf8')
if not (out/'protected-before.json').exists(): (out/'protected-before.json').write_text(json.dumps(protected,indent=2),encoding='utf8')
print('Preview entries',len(entries),'kinds',dict(collections.Counter(r['kind'] for r in entries)))
print('Model directories',dict(collections.Counter(r['family'] for r in entries if r['kind']=='model')))
print('Total environment files',len(allfiles),'protected',len(protected),'missing external images',sum(len(r.get('missing_external_images',[])) for r in entries))
