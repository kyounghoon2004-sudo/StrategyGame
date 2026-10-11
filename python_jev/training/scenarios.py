"""Deterministic T0 scenario generator (jev-scenario-gen-v0.1.0).

Produces varied full-information battle scenarios for the first supervised
training corpus. Every scenario derives from (master_seed, scenario_index)
via an isolated RNG stream — regeneration is byte-identical.

Design notes:
- Scenario geometry uses absolute axial coordinates to BUILD battles; the
  neural observation stays actor-relative (ObservationLayoutV0), so the
  model cannot rely on absolute map coordinates.
- Force-ratio groups (inferior / parity / superior) are enforced on total
  live soldiers (blue:red) at spawn.
- A rotating featured class guarantees every learned class spawns on both
  sides across the corpus.
- MissionContext anchors are declared from DEPLOYMENT geometry (scenario
  level), never from decision-time hidden state.
"""

from __future__ import annotations

import random

SCENARIO_GENERATOR_VERSION = "jev-scenario-gen-v0.1.0"
SCENARIO_MASTER_SEED = 20260919

LEARNED_SPAWN_CLASSES = ("infantry", "spearman", "cavalry", "archer", "scout")

# soldiers ranges per class at spawn (hq last)
SOLDIERS_RANGE = {
    "infantry": (350, 500),
    "spearman": (320, 450),
    "cavalry": (240, 340),
    "archer": (200, 300),
    "scout": (60, 100),
    "hq": (250, 300),
}

# blue:red total-soldier ratio bands at spawn
RATIO_GROUPS = {
    "inferior": (0.50, 0.70),
    "parity": (0.85, 1.15),
    "superior": (1.40, 2.00),
}
OOD_RATIO_GROUPS = {
    "extreme_inferior": (0.30, 0.42),
    "extreme_superior": (2.40, 3.00),
}

# fixed stronghold footprints (WorldState defaults) — never spawn on these
STRONGHOLD_CELLS = {
    (-4, 2), (-3, 2), (-4, 3),          # Fortress_Hulao
    (14, -5), (15, -5), (14, -4),       # Capital_Luoyang
}
CAPITAL_CELLS = [(14, -5), (15, -5), (14, -4)]

# terrain ints (Step3Config port): 0 plains 1 mountains 2 forest 3 swamp
# 4 fortress 5 village 6 road 7 river 8 wall 9/10 stronghold
T_PLAINS, T_MOUNTAIN, T_FOREST, T_SWAMP = 0, 1, 2, 3
T_VILLAGE, T_ROAD, T_RIVER, T_WALL = 5, 6, 7, 8


# ---------------------------------------------------------------- families
# profile: None = alternate DEV/TERRAIN; otherwise forced.
FAMILIES = (
    {"id": "open_clash", "missions": ("destroy_all_red",), "terrain": "open",
     "bounds_w": (10, 14), "bounds_h": (9, 13), "blue_n": (4, 7), "red_n": (4, 7)},
    {"id": "meeting_forest", "missions": ("destroy_all_red",), "terrain": "forest_blocks",
     "bounds_w": (10, 14), "bounds_h": (9, 13), "blue_n": (4, 7), "red_n": (4, 7)},
    {"id": "river_line", "missions": ("destroy_all_red", "hold_hq"), "terrain": "river_line",
     "bounds_w": (11, 14), "bounds_h": (9, 13), "blue_n": (4, 7), "red_n": (4, 7)},
    {"id": "ridge_defense", "missions": ("hold_hq", "destroy_all_red"), "terrain": "ridge",
     "bounds_w": (10, 14), "bounds_h": (9, 13), "blue_n": (4, 6), "red_n": (4, 7)},
    {"id": "village_hold", "missions": ("hold_hq",), "terrain": "mixed",
     "bounds_w": (10, 13), "bounds_h": (9, 12), "blue_n": (4, 6), "red_n": (4, 7)},
    {"id": "capital_push", "missions": ("capture_capital",), "terrain": "capital_approach",
     "bounds_w": (30, 32), "bounds_h": (13, 15), "blue_n": (5, 7), "red_n": (4, 6),
     "profile": "TERRAIN_FULL_INFO", "capital": True},
    {"id": "hq_stand", "missions": ("hold_hq",), "terrain": "mixed",
     "bounds_w": (10, 13), "bounds_h": (9, 12), "blue_n": (3, 5), "red_n": (4, 7)},
    {"id": "survive_withdraw", "missions": ("survive_turns",), "terrain": "open",
     "bounds_w": (12, 15), "bounds_h": (9, 13), "blue_n": (3, 5), "red_n": (4, 7)},
    {"id": "recon_screen", "missions": ("survive_turns", "destroy_all_red"),
     "terrain": "forest_blocks", "bounds_w": (12, 15), "bounds_h": (10, 14),
     "blue_n": (4, 6), "red_n": (4, 6), "scout_bias": True},
    {"id": "cavalry_flank", "missions": ("destroy_all_red",), "terrain": "open",
     "bounds_w": (12, 15), "bounds_h": (10, 14), "blue_n": (4, 7), "red_n": (4, 7),
     "class_bias": "cavalry"},
    {"id": "archer_line", "missions": ("destroy_all_red", "hold_hq"), "terrain": "ridge",
     "bounds_w": (10, 14), "bounds_h": (9, 12), "blue_n": (4, 7), "red_n": (4, 6),
     "class_bias": "archer"},
    {"id": "spear_wall", "missions": ("hold_hq", "destroy_all_red"), "terrain": "mixed",
     "bounds_w": (10, 13), "bounds_h": (9, 12), "blue_n": (4, 6), "red_n": (4, 7),
     "class_bias": "spearman"},
)

# TEST-ONLY distribution-shift families (never in train/val generation).
OOD_FAMILIES = (
    {"id": "ood_cavalry_horde", "missions": ("destroy_all_red",), "terrain": "open",
     "bounds_w": (12, 15), "bounds_h": (10, 14), "blue_n": (5, 7), "red_n": (5, 7),
     "class_bias": "cavalry", "heavy_bias": True},
    {"id": "ood_archer_ridge", "missions": ("destroy_all_red", "hold_hq"), "terrain": "ridge",
     "bounds_w": (10, 14), "bounds_h": (9, 12), "blue_n": (5, 7), "red_n": (4, 6),
     "class_bias": "archer", "heavy_bias": True},
    {"id": "ood_scout_net", "missions": ("survive_turns",), "terrain": "forest_blocks",
     "bounds_w": (13, 16), "bounds_h": (11, 14), "blue_n": (4, 6), "red_n": (4, 6),
     "scout_bias": True, "heavy_bias": True},
    {"id": "ood_pass_choke", "missions": ("destroy_all_red", "hold_hq"), "terrain": "pass",
     "bounds_w": (11, 13), "bounds_h": (11, 14), "blue_n": (4, 6), "red_n": (4, 6)},
    {"id": "ood_extreme_odds", "missions": ("destroy_all_red", "survive_turns"),
     "terrain": "mixed", "bounds_w": (11, 14), "bounds_h": (9, 13),
     "blue_n": (3, 7), "red_n": (3, 7), "extreme_ratio": True},
    {"id": "ood_swamp_crossing", "missions": ("destroy_all_red",), "terrain": "swamp_crossing",
     "bounds_w": (11, 14), "bounds_h": (10, 14), "blue_n": (4, 6), "red_n": (4, 6)},
)

FORMATION_STYLES = ("line", "cluster", "skirmish", "refused_flank")


# ------------------------------------------------------------- generation
def family_for_index(index: int, ood: bool = False) -> dict:
    pool = OOD_FAMILIES if ood else FAMILIES
    return pool[index % len(pool)]


def scenario_seed_for_index(index: int, ood: bool = False) -> int:
    salt = 0x0D00 if ood else 0
    return SCENARIO_MASTER_SEED + salt + index


def generate_scenario(index: int, ood: bool = False) -> dict:
    """Build one deterministic scenario dict + generator metadata.

    Returns {"scenario": <Battle-ready dict>, "meta": {...}} where meta holds
    family/ratio/mission/formation provenance (also embedded in scenario).
    """
    fam = family_for_index(index, ood)
    seed = scenario_seed_for_index(index, ood)
    rng = random.Random(seed)
    scen_id = f"{'ood' if ood else 't0'}_{fam['id']}_{index:04d}"

    ratio_group = _ratio_group_for_index(index, fam)
    mission = rng.choice(list(fam["missions"]))
    turn_limit = _turn_limit(rng, mission)
    bounds = _bounds(rng, fam)
    default_terrain, overrides, river_cells = _terrain(rng, fam, bounds)
    blocked = _blocked_cells(overrides)
    blue_forces, red_forces, formation, spacing = _forces(
        rng, fam, index, scen_id, bounds, blocked, ratio_group, mission)

    scenario = {
        "scenario_id": scen_id,
        "scenario_version": "0.1.0",
        "seed": seed,
        "mission_contract": {"primary_objective": mission, "turn_limit": turn_limit},
        "map": {
            "bounds": bounds,
            "default_terrain": default_terrain,
            "terrain_overrides": overrides,
            "river_cells": river_cells,
        },
        "forces": blue_forces + red_forces,
        "t0_meta": {
            "family": fam["id"],
            "ood": bool(ood),
            "ratio_group": ratio_group,
            "formation": formation,
            "spacing": spacing,
            "terrain_style": fam["terrain"],
            "generator": SCENARIO_GENERATOR_VERSION,
        },
    }
    return {"scenario": scenario, "meta": dict(scenario["t0_meta"])}


def _ratio_group_for_index(index: int, fam: dict) -> str:
    if fam.get("extreme_ratio"):
        return ["extreme_inferior", "extreme_superior"][index % 2]
    return ["inferior", "parity", "superior"][index % 3]


def _turn_limit(rng: random.Random, mission: str) -> int:
    if mission == "destroy_all_red":
        return rng.randint(12, 18)
    if mission == "capture_capital":
        return rng.randint(14, 20)
    return rng.randint(8, 12)


def _bounds(rng: random.Random, fam: dict) -> dict:
    w = rng.randint(*fam["bounds_w"])
    h = rng.randint(*fam["bounds_h"])
    if fam.get("capital"):
        # capital footprint must sit inside the playable map (east edge)
        q_max = 16
        q_min = q_max - w
        r_mid = -3
    else:
        q_mid = rng.randint(-28, -22)
        q_min = q_mid - w // 2
        q_max = q_min + w
        r_mid = rng.randint(-2, 2)
    r_min = r_mid - h // 2
    return {"q_min": q_min, "q_max": q_max, "r_min": r_min, "r_max": r_min + h}


def _in_bounds(q: int, r: int, bounds: dict) -> bool:
    return (bounds["q_min"] <= q <= bounds["q_max"]
            and bounds["r_min"] <= r <= bounds["r_max"])


def _terrain(rng: random.Random, fam: dict, bounds: dict):
    style = fam["terrain"]
    overrides: dict[str, int] = {}
    river_cells: list[list[int]] = []
    default = T_PLAINS

    def put(q, r, t):
        if _in_bounds(q, r, bounds):
            overrides[f"{q},{r}"] = t

    def blob(cq, cr, radius, t):
        for dq in range(-radius, radius + 1):
            for dr in range(-radius, radius + 1):
                if abs(dq) + abs(dr) + abs(dq + dr) <= 2 * radius + (rng.randint(0, 1)):
                    put(cq + dq, cr + dr, t)

    q0, q1 = bounds["q_min"], bounds["q_max"]
    r0, r1 = bounds["r_min"], bounds["r_max"]
    q_mid = (q0 + q1) // 2
    r_mid = (r0 + r1) // 2

    if style == "open":
        for _ in range(rng.randint(4, 8)):
            put(rng.randint(q0, q1), rng.randint(r0, r1), T_FOREST)
        put(rng.randint(q0, q1), rng.randint(r0, r1), T_VILLAGE)
    elif style == "forest_blocks":
        for _ in range(rng.randint(2, 4)):
            blob(rng.randint(q0 + 1, q1 - 1), rng.randint(r0 + 1, r1 - 1),
                 rng.randint(1, 2), T_FOREST)
        if rng.random() < 0.5:
            blob(rng.randint(q0 + 1, q1 - 1), rng.randint(r0 + 1, r1 - 1), 1, T_SWAMP)
    elif style == "river_line":
        for r in range(r0, r1 + 1):
            put(q_mid, r, T_RIVER)
            river_cells.append([q_mid, r])
        for _ in range(rng.randint(2, 5)):
            put(rng.randint(q0, q1), rng.randint(r0, r1), T_FOREST)
    elif style == "ridge":
        for r in range(r0, r1 + 1):
            if rng.random() < 0.8:
                put(q_mid, r, T_MOUNTAIN)
            if rng.random() < 0.4:
                put(q_mid + rng.choice((-1, 1)), r, T_MOUNTAIN)
        for _ in range(rng.randint(2, 4)):
            put(rng.randint(q0, q1), rng.randint(r0, r1), T_FOREST)
    elif style == "mixed":
        blob(rng.randint(q0 + 2, q1 - 2), rng.randint(r0 + 1, r1 - 1), 1, T_FOREST)
        blob(rng.randint(q0 + 2, q1 - 2), rng.randint(r0 + 1, r1 - 1), 1, T_SWAMP)
        put(rng.randint(q0, q1), rng.randint(r0, r1), T_VILLAGE)
        for q in range(q0, q1 + 1):
            if rng.random() < 0.7:
                put(q, r_mid, T_ROAD)
    elif style == "pass":
        gap = rng.randint(r0 + 1, r1 - 1)
        gap_w = rng.randint(2, 3)
        for r in range(r0, r1 + 1):
            if abs(r - gap) >= gap_w:
                put(q_mid, r, T_WALL)
                if rng.random() < 0.6:
                    put(q_mid + rng.choice((-1, 1)), r, T_MOUNTAIN)
        put(q_mid, gap, T_ROAD)
    elif style == "capital_approach":
        for q in range(q0, 14):
            put(q, -4, T_ROAD)
        blob(q_mid, r_mid - 2, 2, T_FOREST)
        blob(q_mid, r_mid + 2, 2, T_FOREST)
        put(q0 + 2, r_mid, T_VILLAGE)
    elif style == "swamp_crossing":
        for q in range(q0, q1 + 1):
            for r in range(r_mid - 1, r_mid + 2):
                if rng.random() < 0.75:
                    put(q, r, T_SWAMP)
            if rng.random() < 0.5:
                river_cells.append([q, r_mid])
                put(q, r_mid, T_RIVER)
        blob(q0 + 1, r0 + 1, 1, T_FOREST)
        blob(q1 - 1, r1 - 1, 1, T_FOREST)
    else:
        raise ValueError(f"unknown terrain style {style!r}")

    # capital footprint cells stay clear of blocking terrain
    for (cq, cr) in CAPITAL_CELLS:
        overrides.pop(f"{cq},{cr}", None)
    return default, overrides, river_cells


def _blocked_cells(overrides: dict[str, int]) -> set[tuple[int, int]]:
    blocked = set(STRONGHOLD_CELLS)
    for key, t in overrides.items():
        if t in (T_WALL, 9, 10):
            q, r = key.split(",")
            blocked.add((int(q), int(r)))
    return blocked


SPACING_STYLES = ("close", "standard", "far")


def _forces(rng, fam, index, scen_id, bounds, blocked, ratio_group, mission):
    formation = rng.choice(list(FORMATION_STYLES))
    # (2i+1)%3 cycles all 9 (ratio_group, spacing) combos per 9 indices.
    spacing = SPACING_STYLES[(2 * index + 1) % 3]
    featured = LEARNED_SPAWN_CLASSES[index % len(LEARNED_SPAWN_CLASSES)]
    blue_n = rng.randint(*fam["blue_n"])
    red_n = rng.randint(*fam["red_n"])

    blue_classes = _composition(rng, fam, blue_n, featured, "blue")
    red_classes = _composition(rng, fam, red_n, featured, "red")

    taken: set[tuple[int, int]] = set()  # shared: both sides never collide
    blue_cells = _deployment_cells(
        rng, bounds, blocked, "blue", len(blue_classes) + 1, formation, fam, spacing, taken)
    red_cells = _deployment_cells(
        rng, bounds, blocked, "red", len(red_classes) + 1, formation, fam, spacing, taken)
    if fam.get("capital"):
        red_cells = _capital_garrison_cells(bounds, blocked, len(red_classes) + 1, rng, taken)

    lo, hi = (OOD_RATIO_GROUPS if ratio_group.startswith("extreme") else RATIO_GROUPS)[ratio_group]
    target_ratio = rng.uniform(lo, hi)

    blue_forces = _spawn_side(rng, scen_id, "blue", blue_classes, blue_cells, 1.0)
    blue_total = sum(f["soldiers"] for f in blue_forces if f["class"] != "hq")
    red_forces = _spawn_side(rng, scen_id, "red", red_classes, red_cells, 1.0)
    red_total = sum(f["soldiers"] for f in red_forces if f["class"] != "hq")
    # scale red soldiers to hit the target blue:red ratio band
    if red_total > 0 and blue_total > 0:
        factor = (blue_total / target_ratio) / red_total
        factor = min(2.5, max(0.4, factor))
        for f in red_forces:
            if f["class"] == "hq":
                continue
            cls_lo, cls_hi = SOLDIERS_RANGE[f["class"]]
            scaled = int(round(f["soldiers"] * factor))
            f["soldiers"] = min(cls_hi + 120, max(50, scaled))
    return blue_forces, red_forces, formation, spacing


def _composition(rng, fam, n, featured, side):
    classes = [featured]  # featured class always present on both sides
    pool = list(LEARNED_SPAWN_CLASSES)
    bias = fam.get("class_bias")
    while len(classes) < n:
        if bias and rng.random() < (0.55 if fam.get("heavy_bias") else 0.35):
            classes.append(bias)
        elif fam.get("scout_bias") and rng.random() < (0.45 if fam.get("heavy_bias") else 0.30):
            classes.append("scout")
        else:
            classes.append(rng.choice(pool))
    # light touch: scouts appear in most forces (recon coverage)
    if "scout" not in classes and rng.random() < 0.6 and n >= 3:
        classes[rng.randrange(1, len(classes))] = "scout"
    rng.shuffle(classes)
    return classes


def _deployment_cells(rng, bounds, blocked, side, n, formation, fam, spacing="standard",
                      taken: set | None = None):
    q0, q1 = bounds["q_min"], bounds["q_max"]
    r0, r1 = bounds["r_min"], bounds["r_max"]
    q_mid = (q0 + q1) // 2
    zone_w = max(2, (q1 - q0) // 4)
    if spacing == "close" and not fam.get("capital"):
        # vanguard contact: zones hug the midline (attack-legal early states)
        if side == "blue":
            q_lo, q_hi = max(q0, q_mid - 3), min(q_mid - 1, q1)
            back_q = q_lo
        else:
            q_lo, q_hi = max(q0, q_mid + 1), min(q_mid + 3, q1)
            back_q = q_hi
    elif spacing == "far" and not fam.get("capital"):
        # approach march: zones pinned to the map edges
        if side == "blue":
            q_lo, q_hi = q0, min(q0 + 1, q1)
            back_q = q0
        else:
            q_lo, q_hi = max(q1 - 1, q0), q1
            back_q = q1
    elif side == "blue":
        q_lo, q_hi = q0, min(q0 + zone_w, q1)
        back_q = q0
    else:
        q_lo, q_hi = max(q1 - zone_w, q0), q1
        back_q = q1
    if fam.get("capital") and side == "blue":
        q_lo, q_hi = q0, min(q0 + zone_w + 2, q1)

    if taken is None:
        taken = set()
    cells: list[tuple[int, int]] = []

    def claim(q, r):
        q = min(max(q, bounds["q_min"]), bounds["q_max"])
        r = min(max(r, bounds["r_min"]), bounds["r_max"])
        if (q, r) in taken or (q, r) in blocked:
            return None
        taken.add((q, r))
        cells.append((q, r))
        return (q, r)

    # HQ first: back corner of the zone
    hq_r = r0 if rng.random() < 0.5 else r1
    if claim(back_q, hq_r) is None:
        _claim_anywhere(rng, bounds, blocked, taken, cells)

    if formation == "line":
        qs = q_lo if side == "blue" else q_hi
        rs = _spread(rng, r0, r1, n - 1)
        for r in rs:
            if claim(qs + rng.randint(-1, 1), r) is None:
                _claim_near(rng, bounds, blocked, taken, cells, qs, r)
    elif formation == "cluster":
        cq = (q_lo + q_hi) // 2
        cr = rng.randint(r0 + 1, max(r0 + 1, r1 - 1))
        for _ in range(n - 1):
            if claim(cq + rng.randint(-2, 2), cr + rng.randint(-2, 2)) is None:
                _claim_near(rng, bounds, blocked, taken, cells, cq, cr)
    elif formation == "refused_flank":
        for i in range(n - 1):
            t = i / max(1, n - 2)
            q = int(round(q_lo + t * (q_hi - q_lo)))
            r = int(round(r0 + t * (r1 - r0)))
            if claim(q, r) is None:
                _claim_near(rng, bounds, blocked, taken, cells, q, r)
    else:  # skirmish
        for _ in range(n - 1):
            if claim(rng.randint(q_lo, q_hi), rng.randint(r0, r1)) is None:
                _claim_near(rng, bounds, blocked, taken, cells,
                            (q_lo + q_hi) // 2, (r0 + r1) // 2)
    while len(cells) < n:
        _claim_anywhere(rng, bounds, blocked, taken, cells)
    return cells


def _capital_garrison_cells(bounds, blocked, n, rng, taken: set | None = None):
    # red defends the capital + fortress approaches (east side)
    anchors = [(12, -5), (13, -4), (12, -3), (11, -5), (13, -6),
               (10, -4), (11, -3), (12, -6), (9, -5), (10, -6)]
    if taken is None:
        taken = set()
    cells: list[tuple[int, int]] = []
    for (q, r) in anchors:
        if len(cells) >= n:
            break
        if _in_bounds(q, r, bounds) and (q, r) not in blocked and (q, r) not in taken:
            taken.add((q, r))
            cells.append((q, r))
    while len(cells) < n:
        _claim_anywhere(rng, bounds, blocked, taken, cells)
    return cells


def _spread(rng, r0, r1, n):
    if n <= 1:
        return [rng.randint(r0, r1)]
    span = max(1, r1 - r0)
    return [r0 + int(round(i * span / (n - 1))) + rng.randint(-1, 1) for i in range(n)]


def _claim_near(rng, bounds, blocked, taken, cells, q, r, radius=4):
    for _ in range(40):
        c = (q + rng.randint(-radius, radius), r + rng.randint(-radius, radius))
        if _in_bounds(*c, bounds) and c not in taken and c not in blocked:
            taken.add(c)
            cells.append(c)
            return c
    return _claim_anywhere(rng, bounds, blocked, taken, cells)


def _claim_anywhere(rng, bounds, blocked, taken, cells):
    for _ in range(200):
        c = (rng.randint(bounds["q_min"], bounds["q_max"]),
             rng.randint(bounds["r_min"], bounds["r_max"]))
        if c not in taken and c not in blocked:
            taken.add(c)
            cells.append(c)
            return c
    raise RuntimeError("deployment failed: no free cell (bounds too tight)")


def _spawn_side(rng, scen_id, side, classes, cells, jitter):
    prefix = "B" if side == "blue" else "R"
    forces = []
    hq_cell = cells[0]
    forces.append({
        "id": f"{prefix}_HQ_1", "class": "hq", "faction": side,
        "q": hq_cell[0], "r": hq_cell[1],
        "soldiers": rng.randint(*SOLDIERS_RANGE["hq"]),
    })
    counters: dict[str, int] = {}
    for cls, cell in zip(classes, cells[1:]):
        counters[cls] = counters.get(cls, 0) + 1
        short = {"infantry": "INF", "spearman": "SPR", "cavalry": "CAV",
                 "archer": "ARC", "scout": "SCT"}[cls]
        lo, hi = SOLDIERS_RANGE[cls]
        forces.append({
            "id": f"{prefix}_{short}_{counters[cls]}", "class": cls, "faction": side,
            "q": cell[0], "r": cell[1], "soldiers": rng.randint(lo, hi),
        })
    return forces


def mission_context_for_side(scenario: dict, side: str) -> dict:
    """Scenario-declared MissionContext kwargs for one side.

    Anchors derive from DEPLOYMENT geometry only (both forces' spawn cells
    and HQ cells), never from decision-time hidden state.
    """
    bounds = scenario["map"]["bounds"]
    own = [f for f in scenario["forces"] if f["faction"] == side]
    foe = [f for f in scenario["forces"] if f["faction"] != side]

    def centroid(units):
        qs = sum(u["q"] for u in units) / max(1, len(units))
        rs = sum(u["r"] for u in units) / max(1, len(units))
        return (int(round(qs)), int(round(rs)))

    def clamp(cell):
        return (min(max(cell[0], bounds["q_min"]), bounds["q_max"]),
                min(max(cell[1], bounds["r_min"]), bounds["r_max"]))

    own_hq = next((u for u in own if u["class"] == "hq"), own[0] if own else None)
    hq_cell = (own_hq["q"], own_hq["r"]) if own_hq else clamp(centroid(own))
    own_c = centroid([u for u in own if u["class"] != "hq"] or own)
    foe_c = centroid([u for u in foe if u["class"] != "hq"] or foe)
    mid = ((own_c[0] + foe_c[0]) // 2, (own_c[1] + foe_c[1]) // 2)

    back = bounds["q_min"] if side == "blue" else bounds["q_max"]
    mc = scenario["mission_contract"]
    role = "RECON" if mc["primary_objective"] == "survive_turns" else "PRIMARY"
    return {
        "scenario_id": str(scenario["scenario_id"]),
        "primary_objective": str(mc["primary_objective"]),
        "turn_limit": int(mc["turn_limit"]),
        "actor_mission_role": role,
        "advance_anchor": clamp(foe_c),
        "reposition_anchor": clamp(((own_c[0] + mid[0]) // 2, (own_c[1] + mid[1]) // 2)),
        "withdraw_anchor": hq_cell,
        "reserve_anchor": clamp((back, own_c[1])),
        "regroup_anchor": clamp(own_c),
        "screen_anchor": clamp(mid),
        "recon_waypoint": clamp((mid[0], mid[1] + (1 if side == "blue" else -1))),
    }


__all__ = [
    "FAMILIES",
    "FORMATION_STYLES",
    "LEARNED_SPAWN_CLASSES",
    "OOD_FAMILIES",
    "OOD_RATIO_GROUPS",
    "RATIO_GROUPS",
    "SCENARIO_GENERATOR_VERSION",
    "SCENARIO_MASTER_SEED",
    "family_for_index",
    "generate_scenario",
    "mission_context_for_side",
    "scenario_seed_for_index",
]
