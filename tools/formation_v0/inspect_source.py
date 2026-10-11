"""Inspect supplied GLB, independent of the previous Blender assets."""
from pathlib import Path
import json,struct,hashlib,math
PROJECT=Path(__file__).resolve().parents[2]
OUT=PROJECT/'artifacts/godot_20man_formation_v0'
SOURCE=Path('C:/Users/kyoun/OneDrive/사진/전쟁 GLB 파일/기본 바디.glb')
ASSET=PROJECT/'assets/units/formation_v0/supplied_soldier.glb'
raw=SOURCE.read_bytes();assert raw==ASSET.read_bytes()
magic,version,size=struct.unpack_from('<III',raw);assert magic==0x46546c67 and version==2 and size==len(raw)
n,t=struct.unpack_from('<II',raw,12);doc=json.loads(raw[20:20+n]);bin_offset=20+n+8
parents={c:i for i,node in enumerate(doc['nodes']) for c in node.get('children',[])}
def global_translation(index):
    node=doc['nodes'][index];assert 'matrix' not in node and 'rotation' not in node and 'scale' not in node
    co=node.get('translation',[0,0,0])
    if index in parents:co=[a+b for a,b in zip(co,global_translation(parents[index]))]
    return co
triangles=sum(doc['accessors'][p['indices']]['count']//3 for m in doc['meshes'] for p in m['primitives'])
all_positions=[doc['accessors'][p['attributes']['POSITION']] for m in doc['meshes'] for p in m['primitives']]
lo=[min(a['min'][i] for a in all_positions) for i in range(3)]
hi=[max(a['max'][i] for a in all_positions) for i in range(3)]
for a in doc['accessors']:
    if a['componentType']!=5126 or 'bufferView' not in a:continue
    v=doc['bufferViews'][a['bufferView']];components={'SCALAR':1,'VEC2':2,'VEC3':3,'VEC4':4,'MAT4':16}[a['type']]
    offset=bin_offset+v.get('byteOffset',0)+a.get('byteOffset',0);stride=v.get('byteStride',components*4)
    for i in range(a['count']):assert all(math.isfinite(x) for x in struct.unpack_from('<'+'f'*components,raw,offset+i*stride))
bones=[{'name':doc['nodes'][i]['name'],'node':i,'parent':doc['nodes'][parents[i]].get('name') if i in parents else None,'global_rest':global_translation(i)} for skin in doc.get('skins',[]) for i in skin['joints']]
report={'source':str(SOURCE),'asset':str(ASSET),'source_sha256':hashlib.sha256(raw).hexdigest(),'source_copied_byte_for_byte':True,'bytes':len(raw),'mesh_count':len(doc['meshes']),'material_count':len(doc.get('materials',[])),'triangle_count':triangles,'skin_count':len(doc.get('skins',[])),'bone_count':len(bones),'animations':[a.get('name') for a in doc.get('animations',[])],'skinned':any('JOINTS_0' in p['attributes'] and 'WEIGHTS_0' in p['attributes'] for m in doc['meshes'] for p in m['primitives']),'bounds_min':lo,'bounds_max':hi,'dimensions':[hi[i]-lo[i] for i in range(3)],'units':'glTF meters; model nominally 1.000782 meters tall with centered root','orientation':'glTF +Y up; facing to be confirmed by visual review','all_float_accessors_finite':True,'bones':bones,'materials':doc.get('materials',[]),'source_mesh_modified':False}
(OUT/'source_inspection.json').write_text(json.dumps(report,indent=2,ensure_ascii=False),encoding='utf-8')
print(json.dumps({k:v for k,v in report.items() if k not in ['materials']},indent=2,ensure_ascii=False))
