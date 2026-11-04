"""Adds V2 gameplay data to the editor-imported M1 (data/battlefields/editor_v1/m1.json).

Design is done in EDITOR coordinates (E): the map editor view has north up, the village (hall at E(6,7))
at the bottom (south = +r). The game view puts blue at the bottom with -r = south, so the game map G is the
editor map rotated 180 deg: G(q,r) = E(-q,-r). Rows are rotated, the baked scene is rotated 180 deg about Y
(tools/rules_v2/bake_editor_map.gd), and units/structures are written in G coordinates. Idempotent.
"""
import json, collections
P = 'data/battlefields/editor_v1/m1.json'
d = json.load(open(P, encoding='utf-8'))
meta = d.setdefault('map_metadata', {})
rows = d['rows']
if meta.get('rotated_180'):          # restore editor orientation first
    rows = [r[::-1] for r in reversed(rows)]
E_rows = rows
q0 = d['q_min']; r0 = d['r_min']

def terr(q, r):                       # editor coords
    i, j = q - q0, r - r0
    if 0 <= i < len(E_rows) and 0 <= j < len(E_rows[i]): return E_rows[i][j]
    return '#'
def ok(q, r): return terr(q, r) in '.RV'
def inside(q, r): return max(abs(q), abs(r), abs(q + r)) <= 20
used = set()
def snap(q, r):
    seen = {(q, r)}; dq = collections.deque([(q, r)])
    while dq:
        c = dq.popleft()
        if ok(*c) and inside(*c) and c not in used:
            return c
        for a, b in ((1,0),(-1,0),(0,1),(0,-1),(1,-1),(-1,1)):
            n = (c[0]+a, c[1]+b)
            if n not in seen: seen.add(n); dq.append(n)
units = []
def add(uid, cls, side, q, r, hp):
    c = snap(q, r); used.add(c)
    units.append([uid, cls, side, -c[0], -c[1], hp])      # -> game coords

hall = (6, 7)
# blue (village defenders) just south of the village hall (+r = south in editor coords)
add('B_GUARD', 'spearman', 'blue', hall[0], hall[1], 74)       # garrisons the hall
add('B_HQ', 'hq', 'blue', 6, 11, 300)
for i, (cls, dq, hp) in enumerate([('conscript', -3, 54), ('conscript', 0, 48), ('conscript', 3, 52), ('spearman', -1, 61)]):
    add('B_%s_%d' % (cls.upper()[:4], i + 1), cls, 'blue', 6 + dq, 9, hp)
add('B_SCOUT_1', 'scout', 'blue', 2, 10, 30); add('B_SCOUT_2', 'scout', 'blue', 10, 10, 30)
# red attackers from the north edge (-r)
add('R_HQ', 'hq', 'red', 0, -16, 300)
for i, (cls, dq, hp) in enumerate([('conscript', -3, 60), ('conscript', 0, 58), ('conscript', 3, 52), ('spearman', -2, 66), ('spearman', 2, 62)]):
    add('R_%s_%d' % (cls.upper()[:4], i + 1), cls, 'red', dq, -14, hp)
add('R_SCOUT_1', 'scout', 'red', -5, -15, 30); add('R_SCOUT_2', 'scout', 'red', 5, -15, 30)

d['rows'] = [r[::-1] for r in reversed(E_rows)]                 # game orientation
meta['rotated_180'] = True
d['river_cells'] = [[-a, -b] for a, b in (c for c in d['river_cells'])] if not meta.get('rotated_180_rivers') else d['river_cells']
meta['rotated_180_rivers'] = True
d['units'] = units
d['strongholds'] = [{"id": "M1_VILLAGE", "name": "Village Hall", "name_kr": "강변 마을", "type": "fortress", "owner": "blue",
                     "footprint": [[-hall[0], -hall[1]]], "hp": 300, "slots": 0}]
sc = d['scenario']
sc['rules_version'] = 'v2'
sc['mission_family'] = 'defense_delay'
sc['side_role'] = {"blue": "defender", "red": "attacker"}
sc['rules_v2'] = {"supply": {"near": 3, "normal": 6, "link": 10, "stock": {"blue": 4, "red": 4}, "seed": 1031,
                              "fixed_edge_bases": 2, "edge_link": 10}}
sc['round_limit'] = 20
d['info']['units'] = {'blue': 8, 'red': 8}
d['info']['strongholds'] = ['M1_VILLAGE']
json.dump(d, open(P, 'w', encoding='utf-8'), ensure_ascii=False, indent=2)
print(units)
