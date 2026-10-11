"""Byte-preserving ingestion authorized by the 2026-09-07 production brief.
Only manifest-listed transparent runtime renders are admitted; originals are read-only.
"""
from pathlib import Path
import hashlib, json, re, shutil
from PIL import Image

PROJECT = Path(__file__).resolve().parents[1]
SOURCE = Path('C:/Users/kyoun/Documents/Codex/2026-09-05/referenced-chatgpt-conversation-this-is-an-2/work/sf3d-local/artifacts/production_asset_expansion_v1')
OUT = PROJECT / 'assets/production_ingestion_v1'
OUT.mkdir(parents=True, exist_ok=True)
def digest(p): return hashlib.sha256(p.read_bytes()).hexdigest()
def copy_checked(src, dst):
    dst.parent.mkdir(parents=True, exist_ok=True)
    if dst.exists() and digest(src) != digest(dst): raise RuntimeError(f'Conflicting destination: {dst}')
    if not dst.exists(): shutil.copy2(src, dst)
    assert digest(src) == digest(dst)

settlements = {'courtyard_house_A','fenced_yard_A','field_edge_A','granary_A','hamlet_cluster_A','hamlet_cluster_B','market_town_cluster_A','roadside_inn_A','rural_house_A','rural_house_B','rural_house_C','small_shrine_A','stable_A','village_cluster_A','village_cluster_B','warehouse_A','workshop_A','hay_stack_A'}
roster, counts = [], {}
for batch, base in [('batch2_units','units/formations'),('batch3_fortifications','structures/fortifications'),('batch4_settlements_props','structures/settlements')]:
    folder = SOURCE / batch
    manifest = (folder/'manifest.md').read_text(encoding='utf-8')
    names = re.findall(r'^\| (\w+) \|', manifest, re.M)
    names = [n for n in names if n != 'Name']
    validation = json.loads((folder/'receipts/validation.json').read_text())
    assert not validation['errors'], batch
    for name in names:
        if batch == 'batch4_settlements_props' and name == 'defensive_stakes_A': continue
        family = 'props' if batch == 'batch4_settlements_props' and name not in settlements else base
        dest = PROJECT/'assets'/family/'approved_v1'
        copy_checked(folder/'manifest.md',dest/'manifest.md')
        copy_checked(folder/'receipts/validation.json',dest/'source_validation.json')
        for side in (['','enemy'] if batch == 'batch2_units' else ['']):
            src = folder/'preview_png'/side/(name+'.png')
            dst = dest/side/src.name
            im = Image.open(src)
            assert im.mode == 'RGBA' and im.getchannel('A').getextrema()[0] == 0, src
            copy_checked(src,dst)
            roster.append({'source':str(src),'destination':str(dst),'sha256':digest(src),'family':family})
            counts[family] = counts.get(family,0)+1
copy_checked(SOURCE/'manifest.md',OUT/'source_master_manifest.md')

# Measure every approved PNG, excluding review sheets by manifest membership.
files = [Path(x['destination']) for x in roster]
for family in ['terrain/mountains','vegetation']:
    root = PROJECT/'assets'/family/'approved_v1'
    names = re.findall(r'^\| (\w+) \|',(root/'manifest.md').read_text(encoding='utf-8'),re.M)
    files += [root/(n+'.png') for n in names if (root/(n+'.png')).exists()]
cohesion = PROJECT/'assets/terrain/cohesion/approved_v1'
cm = json.loads((cohesion/'manifest.json').read_text())
files += [cohesion/(a['name']+'.png') for a in cm['assets']]
metadata = {}
for p in sorted(set(files)):
    im = Image.open(p).convert('RGBA'); alpha = im.getchannel('A')
    box = alpha.getbbox(); assert box
    x0,y0,x1,y1 = box
    bottom = alpha.crop((x0,y1-1,x1,y1)).getdata()
    weights = list(bottom); total = sum(weights)
    contact_x = x0+sum((i+.5)*w for i,w in enumerate(weights))/total
    key = 'res://'+p.relative_to(PROJECT).as_posix()
    metadata[key] = {'bounds':[x0,y0,x1-x0,y1-y0], 'content_width':x1-x0,'content_height':y1-y0,'bottom_contact':[round(contact_x,3),y1], 'visual_center':[(x0+x1)/2,(y0+y1)/2], 'canvas':list(im.size),'sha256':digest(p)}
(OUT/'alpha_bounds.json').write_text(json.dumps(metadata,indent=2)+'\n')
(OUT/'ingestion_receipt.json').write_text(json.dumps({'authorization':'Current user production-ingestion brief explicitly human-approves and requests import of batches 2-4; supersedes historical pending-review labels.','duplicate_choice':'defensive_stakes_A: Batch 3 canonical fortification; Batch 4 repeated design excluded.','counts':counts,'files':roster},indent=2)+'\n')
print(json.dumps({'imported':counts,'alpha_measured':len(metadata)}))
