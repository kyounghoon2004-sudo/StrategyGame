"""Rebuilds map-editor documents for M1/M2 from the imported gameplay terrain (data/battlefields/editor_v1/mN.json).
The original editor maps (D:/StrategyGame_Transfer/maps/map_*.json) were lost on 2026-11-13; the gameplay rows
still hold one glyph per hex (F forest, M mountain, V village, X fort), so every glyph becomes an editor object again.
Mountain clusters are covered greedily with massif25 pieces whose path best fits the cluster.
usage: python tools/rules_v2/rebuild_editor_maps.py <massif25 catalog.json> <out_dir>
"""
import json, sys, collections
CAT = json.load(open(sys.argv[1], encoding='utf-8'))['catalog']
OUT = sys.argv[2]
DIRS = ((1,0),(-1,0),(0,1),(0,-1),(1,-1),(-1,1))
SPEC = {1: {'name': 'M1 (River Roads) rebuilt', 'hall': (6, 7)},
        2: {'name': 'M2 (Gate Fort) rebuilt', 'hall': (10, 7), 'fort_variant': 'castle_v1'}}
HOUSES = ['building_small_house', 'building_medium_house', 'building_workshop', 'building_granary', 'building_farm_granary']

def rot(c, k):
    q, r = c
    for _ in range(k % 6):
        q, r = -r, q + r          # axial 60 deg step
    return (q, r)

def load(k):
    d = json.load(open(f'data/battlefields/editor_v1/m{k}.json', encoding='utf-8'))
    rows = d['rows']
    if d['map_metadata'].get('rotated_180'):
        rows = [r[::-1] for r in reversed(rows)]
    cells = {}
    for i, row in enumerate(rows):
        for j, ch in enumerate(row):
            if ch not in '#.':
                cells[(d['q_min'] + i, d['r_min'] + j)] = ch
    return cells

def cover_mountains(cells):
    todo = {c for c, ch in cells.items() if ch == 'M'}
    objs = []
    while todo:
        best = None
        for anchor in sorted(todo):
            for item in CAT:
                path = [(p['q'], p['r']) for p in item['pathCells']]
                for k in range(6):
                    pts = {(anchor[0] + rot(p, k)[0], anchor[1] + rot(p, k)[1]) for p in path}
                    hit = len(pts & todo); miss = len(pts - set(cells_m))
                    score = hit - 0.75 * miss
                    if hit and (best is None or score > best[0]):
                        best = (score, anchor, item['id'], k, pts)
        _, anchor, vid, k, pts = best
        objs.append({'kind': 'mountain', 'variant': vid, 'q': anchor[0], 'r': anchor[1], 'rotation': k})
        todo -= pts
        todo.discard(anchor)
    return objs

for k, spec in SPEC.items():
    cells = load(k)
    cells_m = [c for c, ch in cells.items() if ch == 'M']
    objs = cover_mountains(cells)
    used = {(o['q'], o['r']) for o in objs}
    hi = 0
    for c, ch in sorted(cells.items()):
        if c in used: continue
        if ch == 'F':
            objs.append({'kind': 'forest', 'variant': 'pine' if (c[0] * 7 + c[1] * 3) % 3 == 0 else 'mixed', 'q': c[0], 'r': c[1], 'rotation': 0})
        elif ch == 'V':
            v = 'building_hall' if c == spec['hall'] else HOUSES[hi % len(HOUSES)]
            if c != spec['hall']: hi += 1
            objs.append({'kind': 'building', 'variant': v, 'q': c[0], 'r': c[1], 'rotation': (c[0] + c[1]) % 6})
        elif ch == 'X':
            objs.append({'kind': 'castle', 'variant': spec.get('fort_variant', 'castle_v1'), 'q': c[0], 'r': c[1], 'rotation': 0})
        else:
            continue
        used.add(c)
    if spec['hall'] not in used:
        objs.append({'kind': 'building', 'variant': 'building_hall', 'q': spec['hall'][0], 'r': spec['hall'][1], 'rotation': 0})
    doc = {'schema_version': 1, 'id': f'map_m{k}_rebuilt_20261114', 'name': spec['name'], 'radius': 20, 'hex_radius': 18.0, 'objects': objs}
    path = f'{OUT}/{doc["id"]}.json'
    json.dump(doc, open(path, 'w', encoding='utf-8'), ensure_ascii=False, indent=1)
    print(path, collections.Counter(o['kind'] for o in objs))
