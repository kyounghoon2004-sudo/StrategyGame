"""Adds V2 gameplay data to the editor-imported M2 (data/battlefields/editor_v1/m2.json).

Same frame rules as gen_m1_gameplay.py: the map is authored in EDITOR coords (rows are indexed by q,
columns by r, i.e. rows[q - q_min][r - r_min]); the game map G is the editor map rotated 180 deg
(G(q,r) = E(-q,-r)) so the village lands at the bottom of the screen and the mountain belt runs
horizontally (see RULES_V2_SPEC.md, orientation round). Idempotent.

M2 design (2026-11-01 decisions):
- neutral gate fort at E(4,1), 450 HP, no slots (V2 has no garrison); capture = victory.
- village hall E(10,7) is the only village structure (300 HP, blue); the other 7 house cells are decor.
- hills (source objects kind=="hill") are removed: terrain becomes plains, the hill models are skipped
  at bake time (tools/rules_v2/bake_editor_map.gd --skip-hills).
- blue starts at the village (9 hexes from the fort), red marches from the north (16), one archer each.
"""
import json
import collections

P = 'data/battlefields/editor_v1/m2.json'
SRC = 'D:/StrategyGame_Transfer/maps/map_m2_gate_fort_polished_20261029.json'

FORT_E = (4, 1)                 # gate fort (editor coords)
HALL_E = (10, 7)                # village hall building object
FORT_HP = 450
HALL_HP = 300

d = json.load(open(P, encoding='utf-8'))
meta = d.setdefault('map_metadata', {})
rows = d['rows']
if meta.get('rotated_180'):     # restore editor orientation first
    rows = [r[::-1] for r in reversed(rows)]
E_rows = [r for r in rows]
q0, r0 = d['q_min'], d['r_min']


def terr(q, r):
    i, j = q - q0, r - r0
    if 0 <= i < len(E_rows) and 0 <= j < len(E_rows[i]):
        return E_rows[i][j]
    return '#'


def set_terr(q, r, ch):
    i, j = q - q0, r - r0
    s = E_rows[i]
    E_rows[i] = s[:j] + ch + s[j + 1:]


# --- hills removed (source objects; the importer collapsed hill+mountain into 'M') -----
src = json.load(open(SRC, encoding='utf-8'))
hills = [(o['q'], o['r']) for o in src['objects'] if o.get('kind') == 'hill']
changed = 0
for h in hills:
    if terr(*h) == 'M':
        set_terr(h[0], h[1], '.')
        changed += 1

OK = '.RVX'
used = set()
structures = {FORT_E, HALL_E}


def ok(q, r):
    return terr(q, r) in OK


def inside(q, r):
    return max(abs(q), abs(r), abs(q + r)) <= 20


def snap(q, r):
    seen = {(q, r)}
    dq = collections.deque([(q, r)])
    while dq:
        c = dq.popleft()
        if ok(*c) and inside(*c) and c not in used and c not in structures:
            return c
        for a, b in ((1, 0), (-1, 0), (0, 1), (0, -1), (1, -1), (-1, 1)):
            n = (c[0] + a, c[1] + b)
            if n not in seen:
                seen.add(n)
                dq.append(n)
    return (q, r)


units = []


def add(uid, cls, side, q, r, hp):
    c = snap(q, r)
    used.add(c)
    units.append([uid, cls, side, -c[0], -c[1], hp])      # -> game coords


# --- blue: starts at the village (bottom of the screen) --------------------------------
add('B_HQ', 'hq', 'blue', 10, 11, 300)
for i, (cls, q, r, hp) in enumerate([
        ('conscript', 8, 10, 52), ('conscript', 10, 10, 50), ('conscript', 12, 9, 48),
        ('spearman', 9, 9, 62), ('archer', 11, 10, 50)]):
    add('B_%s_%d' % (cls.upper()[:4], i + 1), cls, 'blue', q, r, hp)
add('B_SCOUT_1', 'scout', 'blue', 7, 11, 30)
add('B_SCOUT_2', 'scout', 'blue', 12, 11, 30)

# --- red: marches in from the north (screen top = -q in editor coords) ----------------
add('R_HQ', 'hq', 'red', -11, 2, 300)
for i, (cls, q, r, hp) in enumerate([
        ('conscript', -10, 1, 60), ('conscript', -8, 2, 58), ('conscript', -9, 4, 54),
        ('spearman', -11, 4, 66), ('archer', -7, 4, 52)]):
    add('R_%s_%d' % (cls.upper()[:4], i + 1), cls, 'red', q, r, hp)
add('R_SCOUT_1', 'scout', 'red', -12, 1, 30)
add('R_SCOUT_2', 'scout', 'red', -6, 5, 30)

# --- rotate to the game frame --------------------------------------------------------
d['rows'] = [r[::-1] for r in reversed(E_rows)]
meta['rotated_180'] = True
d['river_cells'] = []
d['units'] = units
d['strongholds'] = [
    {"id": "M2_GATE_FORT", "name": "Gate Fort", "name_kr": "관문 요새", "type": "fortress", "owner": "neutral",
     "footprint": [[-FORT_E[0], -FORT_E[1]]], "hp": FORT_HP, "slots": 0},
    {"id": "M2_VILLAGE_HALL", "name": "Village Hall", "name_kr": "관문 마을", "type": "fortress", "owner": "blue",
     "footprint": [[-HALL_E[0], -HALL_E[1]]], "hp": HALL_HP, "slots": 0},
]
sc = d['scenario']
sc['rules_version'] = 'v2'
sc['mission_family'] = 'fort_contest'
sc['side_role'] = {"blue": "defender", "red": "attacker"}
sc['rules_v2'] = {"supply": {"near": 3, "normal": 6, "link": 10, "stock": {"blue": 4, "red": 4},
                            "seed": 1031, "fixed_edge_bases": 2, "edge_link": 10}}
sc['round_limit'] = 30
sc['round_limit_provisional'] = True
sc['fortified_objective_refs'] = ["M2_GATE_FORT"]
sc['objectives'] = [{"kind": "capture", "target_ref": "M2_GATE_FORT"}]
d['info']['units'] = {'blue': len([u for u in units if u[2] == 'blue']), 'red': len([u for u in units if u[2] == 'red'])}
d['info']['strongholds'] = ['M2_GATE_FORT', 'M2_VILLAGE_HALL']
d['info']['tactical'] = 'Neutral gate fort contest: blue from the village, red from the north.'
json.dump(d, open(P, 'w', encoding='utf-8'), ensure_ascii=False, indent=2)

# --- report (game coords) -------------------------------------------------------------
def gterr(q, r):
    i, j = q - q0, r - r0
    g = d['rows']
    if 0 <= i < len(g) and 0 <= j < len(g[i]):
        return g[i][j]
    return '#'


def off2ax(c, r):
    return (c, r - (c - (c & 1)) // 2)


def hd(a, b):
    A, B = off2ax(*a), off2ax(*b)
    return max(abs(A[0] - B[0]), abs(A[1] - B[1]), abs(-A[0] - A[1] + B[0] + B[1]))


print('hills -> plains:', changed, 'of', len(hills))
for u in units:
    print('  %-10s %-9s %-4s G(%3d,%3d) hp=%3d terrain=%s' % (u[0], u[1], u[2], u[3], u[4], u[5], gterr(u[3], u[4])))
blue_hq = [u for u in units if u[0] == 'B_HQ'][0]
red_hq = [u for u in units if u[0] == 'R_HQ'][0]
fort_g = (-FORT_E[0], -FORT_E[1])
hall_g = (-HALL_E[0], -HALL_E[1])
print('fort', fort_g, 'terrain', gterr(*fort_g), 'hall', hall_g, 'terrain', gterr(*hall_g))
print('blue HQ->fort', hd((blue_hq[3], blue_hq[4]), fort_g),
      '| red HQ->fort', hd((red_hq[3], red_hq[4]), fort_g),
      '| blue HQ->red HQ', hd((blue_hq[3], blue_hq[4]), (red_hq[3], red_hq[4])))
