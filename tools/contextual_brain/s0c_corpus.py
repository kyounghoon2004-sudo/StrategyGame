"""CONTEXTUAL_BRAIN_S0C corpus: paired-counterfactual SFT corpus.

Extends S0B (tools/contextual_brain/s0b_corpus.py):
1. Teacher v3:
   - Replace every alphabetical tie-break between sectors with pack-visible quantities:
     not rough (extra path cost < 3) > more visible enemy formations > lower extra path cost >
     fewer travel turns for the line class. If two sectors are STILL tied: pair is AMBIGUOUS -> drop it.
   - Assert SCOUT and HQ are never the maneuver force.
   - Drop any target where target == SCOUT (enforces target SCOUT < 1%).
   - Prose carries 0% class names.
2. 96 NEW TRAIN-split EpisodeSpecs sampled from Track B (seeds 5100..5123, 6100..6123, 7100..7123, 8100..8123).
   Per episode: 1 flat window + 2 catalog-terrain windows = 288 base battles.
3. Pair families:
   A. NO-MANEUVER outcomes (>= 350)
   B. MANEUVER APPEARS (None -> class) (>= 200)
   C. MANEUVER CHANGES CLASS (mobility rotation) (>= 150)
   D. TERRAIN, main effort moves TO CENTER (>= 250)
   E. TERRAIN, flank chosen by pack-visible asymmetry (>= 250, N and S >= 40% each)
   F. TERRAIN, leaves a blocked sector (>= 150)
   G. VISIBLE ENEMY COMPOSITION (>= 200)
   H. CONTROLS (tiny nudge, rear forest, identical resample) (>= 12% of all pairs)
4. Balance gates enforced:
   - maneuver = None in 30-45% of rows; no single class > 35% of maneuver values
   - main effort: each of NORTH / CENTER / SOUTH between 25% and 45% of rows
   - target SCOUT < 1% of rows
   - flat vs terrain windows: each >= 30% of pairs in every family A-G
   - prose class-name rate 0%; distinct doctrine vectors >= 300
"""
from __future__ import annotations

import copy
import hashlib
import json
import os
import random
import re
import statistics
from collections import Counter
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple

from tools.contract_sft import harness as H
from tools.contextual_brain.s0_corpus import catalog_terrain, region, render_spec, rk

ROOT = Path(r"D:\Game development\Demon slayer\StrategyGame")
OUT = ROOT / "artifacts" / "contextual_brain_s0c_corpus"
EPIS = OUT / "episodes"
SECT3 = ["NORTH", "CENTER", "SOUTH"]
NOT_COMBAT = {"HQ", "SCOUT"}
ROUGH_EXTRA = 3.0
CLASS_REGEX = re.compile(r"\b(infantry|spearman|archer|cavalry|scout|siege|conscript)\b", re.IGNORECASE)


# ------------------------------------------------------------------ teacher v3
def teacher(packet: Dict[str, Any], rng_seed: str) -> Tuple[Optional[Dict[str, Any]], Dict[str, Any]]:
    """Deterministic rule teacher v3. Returns (plan, decisions).
    If sector tie-breaking is ambiguous or target is SCOUT, returns (None, {'ambiguous': True, ...})."""
    ctx, cs = packet["context"], packet["compact_state"]
    rules = ctx["rules"]["classes"]
    mu = {(a, d): m for a, d, m in ctx["rules"]["matchups"]}

    def match(a: str, d: str) -> float:
        return mu.get((a, d)) or (1 / mu[(d, a)] if (d, a) in mu else 1.0)

    fr = ctx["forces"]["friendly"]["by_class"]
    combat = sorted(c for c in fr if c not in NOT_COMBAT)
    mps = [rules[c]["mp"] for c in combat for _ in range(fr[c][0])]
    line_mp = statistics.median(mps) if mps else 1.0
    fast = max(combat, key=lambda c: (rules[c]["mp"], fr[c][0], c)) if combat else None
    maneuver = fast if fast and rules[fast]["mp"] >= line_mp + 1 else None

    # Hard assertion 2: SCOUT and HQ are never the maneuver force
    assert maneuver not in ("SCOUT", "HQ"), f"Maneuver force cannot be SCOUT or HQ: {maneuver}"

    line_cls = max(combat, key=lambda c: (fr[c][0], c)) if combat else None
    vis = ctx["forces"]["enemy_visible"]["by_class"]
    pool = [c for c in vis if c in rules and c not in NOT_COMBAT] or [c for c in vis if c in rules and c != "HQ"]
    target, best = None, None
    for c in sorted(pool):
        edge = max((match(f, c) * rules[f]["atk"] / max(1.0, rules[c]["def"]) for f in combat), default=1.0)
        soldiers = vis[c][1] if vis[c][1] > 0 else 300 * vis[c][0]
        s = (soldiers * edge, c)
        if best is None or s > best:
            target, best = c, s

    # Hard gate: target SCOUT < 1% of rows. If target is SCOUT, drop the battle as invalid
    if target == "SCOUT":
        return None, {"ambiguous": True, "reason": "target_is_scout"}

    tr = ctx["map"].get("travel_from_own_hq", {})
    by_sec = ctx["forces"]["formations_by_sector"]

    def leg(s: str) -> Tuple[float, Dict[str, Any]]:
        t = tr.get(f"NEAREST_ENEMY_{s}") or tr.get(s) or {}
        pc = t.get("path_cost_std_terrain")
        extra = (pc - t["hexes"]) if isinstance(pc, (int, float)) else 99.0
        return extra, t

    def sector_pack_metric(s: str) -> Tuple[Tuple[int, int, float, float], float, Dict[str, Any]]:
        extra, t = leg(s)
        rough = 1 if extra >= ROUGH_EXTRA else 0
        vis_enemies = by_sec[s][1]
        turns_val = t.get("turns", {}).get(line_cls) if line_cls else None
        turns = float(turns_val) if isinstance(turns_val, (int, float)) else 999.0
        return (rough, -vis_enemies, extra, turns), extra, t

    # Sector ranking order:
    # not rough (extra < 3) > more visible enemy formations > lower extra path cost > fewer travel turns
    sec_metrics = {s: sector_pack_metric(s) for s in SECT3}

    # Evaluate main effort:
    sorted_main = sorted(SECT3, key=lambda s: (sec_metrics[s][0], s != "CENTER"))
    best_m = sec_metrics[sorted_main[0]][0]
    second_m = sec_metrics[sorted_main[1]][0]

    # If the top two sectors tie on all 4 pack metrics without center preference:
    if best_m == second_m and sorted_main[0] != "CENTER" and sorted_main[1] != "CENTER":
        return None, {"ambiguous": True, "reason": f"main_tied_{sorted_main[0]}_{sorted_main[1]}"}
    if best_m == second_m and sec_metrics[sorted_main[0]][1] >= ROUGH_EXTRA:
        return None, {"ambiguous": True, "reason": "main_rough_tied"}

    main = sorted_main[0]

    # Evaluate flank:
    flank_cands = [s for s in SECT3 if s != main]
    if main == "CENTER":
        m_north = sec_metrics["NORTH"][0]
        m_south = sec_metrics["SOUTH"][0]
        if m_north == m_south:
            return None, {"ambiguous": True, "reason": "flank_tied_north_south"}
        flank = "NORTH" if m_north < m_south else "SOUTH"
    else:
        flank = min(flank_cands, key=lambda s: (sec_metrics[s][0][0], s == "CENTER", sec_metrics[s][0][1:]))

    hq_sec = next((u.get("region") for u in cs["friendly_units"] if u["class"] == "HQ"), None) or "CENTER"
    tmain = sec_metrics[main][2]
    turns = tmain.get("turns", {}).get(line_cls) if line_cls else None
    T = max(2, min(6, turns if isinstance(turns, int) else 4))
    foe = "BLUE" if packet["acting_side"] == "RED" else "RED"
    c_extra, c_leg = leg("CENTER")
    c_cost = c_leg.get("path_cost_std_terrain")
    note = (f" CENTER route costs {c_cost:g} MP for {c_leg['hexes']} hexes."
            if main != "CENTER" and c_extra >= ROUGH_EXTRA and c_leg.get("hexes") and isinstance(c_cost, (int, float)) else "")
    r = ctx["forces"].get("visible_soldier_ratio") or 1.0
    cl = lambda x: round(min(0.9, max(0.1, x)), 2)
    fast_mp = rules[fast]["mp"] if fast else line_mp
    doctrine = [cl(0.3 + 0.2 * min(r, 2.5)), cl(0.25 + 0.15 * min(r, 2.5)),
                cl(0.35 + 0.15 * (fast_mp - line_mp) + 0.025 * T),
                cl(0.35 + (0.2 if maneuver else 0.0)),
                cl(0.65 if (ctx["map"].get("nearest_visible_contact_hexes") or 99) <= 4 else 0.45),
                cl(0.3 if maneuver else 0.12)]
    rng = random.Random(rng_seed)
    names = [rng.choice(["SHAPE", "DEVELOP", "OPEN"]), rng.choice(["ENGAGE", "BREAK IN", "COMMIT"]),
             rng.choice(["DECIDE", "FINISH", "EXPLOIT"])]
    tv = {"vs": target} if target else {}
    win_t = [{"when": "TURNS_ELAPSED", "turns": T, "since": 1}]
    hx = tmain.get("hexes", "?")
    if maneuver:
        man = {"task": "FLANK", "area": flank, "prefer": {"classes": [maneuver]},
               "intent": f"Fastest force (mp {rules[maneuver]['mp']:g} vs line {line_mp:g}) swings through {flank} onto the {main} flank."}
    else:
        man = {"task": "ADVANCE", "area": flank,
               "intent": f"No force outpaces the line (best mp {fast_mp:g} vs {line_mp:g}); widen the front through {flank}."}
    scout = "SCOUT" in fr
    third = ({"task": "RECON", "area": flank if target else main, "prefer": {"classes": ["SCOUT"]},
              "intent": "Screen and confirm enemy strength ahead of the front."} if scout else
             {"task": "HOLD", "area": hq_sec, "preserve": True, "intent": f"Cover the HQ sector ({hq_sec})."})
    p1 = [dict(task="FIX", area=main, priority="high", **tv,
               intent=f"Pin the main visible concentration at {main}, {hx} hexes out.{note}"[:160],
               win=win_t, stop=[{"when": "FORCE_STRENGTH_BELOW", "fraction": 0.5}]),
          dict(man, priority="medium", **tv, win=win_t, stop=["HQ_THREATENED"]),
          dict(third, priority="low", win=win_t, stop=["HQ_THREATENED"])]
    p2 = [dict(task="ATTACK", area=main, priority="high", **tv, intent=f"Break the pinned line at {main}.",
               win=[{"when": "LOCAL_ADVANTAGE_HIGH", "region": main, "ratio": 1.5}],
               stop=[{"when": "FORCE_STRENGTH_BELOW", "fraction": 0.4}]),
          dict(man, priority="medium", **tv,
               intent=("Keep the flank attack moving" if maneuver else "Keep the wide front moving") + f" through {flank}.",
               win=win_t, stop=["HQ_THREATENED"]),
          dict(task="RESERVE", area=hq_sec, preserve=True, priority="medium",
               intent=f"Reserve at {hq_sec}: protect the HQ, exploit a breach.",
               win=win_t, stop=["HQ_THREATENED"])]
    p3 = [dict(task="ATTACK", area=main, vs="HQ", pursue=True, priority="high",
               intent=f"Drive on the {foe} HQ through {main}.",
               win=win_t, stop=[{"when": "FORCE_STRENGTH_BELOW", "fraction": 0.3}]),
          dict(task="ATTACK", area=flank, priority="medium", **tv,
               intent=f"Collapse the {flank} side of the {foe} line.", win=win_t, stop=["HQ_THREATENED"]),
          dict(task="HOLD", area=hq_sec, preserve=True, priority="medium",
               intent=f"Keep the HQ covered at {hq_sec}.", win=win_t, stop=["HQ_THREATENED"])]
    phases = []
    for i, (nm, ms) in enumerate(zip(names, (p1, p2, p3))):
        phases.append({"id": f"P{i + 1}", "name": f"{nm} {main}",
                       "purpose": ["Fix and shape", "Break the line", "Win"][i] + f" at {main}.",
                       "intent": (man["intent"] if i == 0 else f"Main effort {main}; {flank} supports.")[:160],
                       "missions": ms,
                       "win": win_t, "lose": [{"when": "FORCE_STRENGTH_BELOW", "fraction": 0.4}],
                       "abort": ["HQ_THREATENED"],
                       "next": "END" if i == 2 else f"P{i + 2}", "on_fail": "HOLD"})
    plan = {"objective": f"Destroy the {foe} HQ: main effort {main}, " + (
        "fast flank via " if maneuver else "broad front via ") + f"{flank}, HQ covered.",
            "end_state": f"{foe} HQ destroyed; own HQ intact.", "cadence": max(2, min(5, T)), "doctrine": doctrine,
            "phases": phases,
            "abort": [{"when": "FORCE_STRENGTH_BELOW", "fraction": 0.25}],
            "hypotheses": [{"h": f"{foe}_MASS_{max(SECT3, key=lambda s: by_sec[s][1])}", "conf": 0.6,
                            "ev": [f"{sum(by_sec[s][1] for s in SECT3)} visible formations"]}]}
    return plan, {"maneuver": maneuver, "main": main, "flank": flank, "target": target}


def decisions(plan: Dict[str, Any]) -> Dict[str, Any]:
    """Structured decision fields (same extractor for teacher targets and model outputs)."""
    ms = plan["phases"][0]["missions"]
    fix = next((m for m in ms if m.get("task") == "FIX"), ms[0])
    fl = next((m for m in ms if m.get("task") == "FLANK"), None)
    return {"main": fix.get("area"),
            "maneuver": ((fl or {}).get("prefer") or {}).get("classes", [None])[0] if fl else None,
            "target": fix.get("vs")}


def extract_prose(plan: Dict[str, Any]) -> str:
    """Collect all prose strings from a plan for regex validation."""
    parts = [str(plan.get("objective", "")), str(plan.get("end_state", ""))]
    for ph in plan.get("phases", []):
        parts.append(str(ph.get("purpose", "")))
        parts.append(str(ph.get("intent", "")))
        for m in ph.get("missions", []):
            parts.append(str(m.get("intent", "")))
    return " ".join(parts)


# ------------------------------------------------------------------ battles
def base_battle(spec_path: Path, k: int, flat: bool, spec_idx: int) -> Dict[str, Any]:
    spec = json.loads(Path(spec_path).read_text(encoding="utf-8"))
    rng = random.Random(f"s0c:{spec['episode_id']}:{k}")
    w, h = rng.choice([18, 20, 22, 24]), rng.choice([8, 9, 10, 12])
    cq, cr = rng.randint(-8, 8), rng.randint(-8, 8)
    b = {"q_min": cq - w, "q_max": cq + w, "r_min": cr - h, "r_max": cr + h}
    terr_all = {} if flat else catalog_terrain(spec["map"]["id"])
    terr = {(q, r): terr_all.get((q, r), 0) for q in range(b["q_min"], b["q_max"] + 1) for r in
            range(b["r_min"], b["r_max"] + 1)}
    gap = rng.choice([2, 2, 2, 3]) if flat else rng.choice([2, 2, 3, 4])
    side = "red" if rng.random() < 0.5 else "blue"
    rosters = {}
    for fac in ("red", "blue"):
        rows = [u for u in spec["armies"] if u["faction"] == fac and u["class"] != "hq"]
        rng.shuffle(rows)
        # Ensure combat classes are always present and at least 6 units
        combat_rows = [u for u in rows if u["class"] in ("infantry", "archer", "cavalry", "spear")]
        other_rows = [u for u in rows if u["class"] not in ("infantry", "archer", "cavalry", "spear")]
        selected = combat_rows[:6] + other_rows[:2]
        rosters[fac] = ([("spearman" if u["class"] == "spear" else u["class"]) for u in selected], [u["count"] for u in selected])

    red_front = cq + gap // 2 + gap % 2
    blue_front = red_front - gap

    # Base design setup:
    # 1. Base maneuver distribution across all 4 combat classes + None:
    rules = copy.deepcopy(spec["rules"])
    own_cls = rosters[side][0]
    own_combat = [c for c in own_cls if c not in ("scout", "hq")]
    for c in set(own_combat):
        rules["base_mp"][rk(c)] = 2.0

    fast_speeds = [3.5, 4.0, 4.5, 5.0]
    speed = fast_speeds[(spec_idx + k) % 4]
    maneuver_mode = spec_idx % 5
    if maneuver_mode == 0:
        # None: all combat classes stay at 2.0
        pass
    elif maneuver_mode == 1:
        # ARCHER is fastest
        tgt_cls = "archer" if "archer" in own_combat else own_combat[0]
        rules["base_mp"][rk(tgt_cls)] = speed
    elif maneuver_mode == 2:
        # SPEARMAN is fastest
        tgt_cls = "spearman" if "spearman" in own_combat else own_combat[0]
        rules["base_mp"][rk(tgt_cls)] = speed
    elif maneuver_mode == 3:
        # CAVALRY is fastest
        tgt_cls = "cavalry" if "cavalry" in own_combat else own_combat[0]
        rules["base_mp"][rk(tgt_cls)] = speed
    elif maneuver_mode == 4:
        # INFANTRY is fastest
        tgt_cls = "infantry" if "infantry" in own_combat else own_combat[0]
        rules["base_mp"][rk(tgt_cls)] = speed

    # 2. Base terrain setup:
    # ~55% of bases have rough center, balanced equally between NORTH and SOUTH:
    has_rough_center = (spec_idx % 2 == 1) or (spec_idx % 4 == 0 and k in (1, 2))
    if has_rough_center:
        # Block center
        for q in range(blue_front - 2, red_front + 3):
            for r in range(b["r_min"], b["r_max"] + 1):
                if region(q, r, b) == "CENTER" and b["q_min"] <= q <= b["q_max"]:
                    terr[(q, r)] = 8
        pick_north = (spec_idx % 4 == 1) or (spec_idx % 4 == 0 and k in (1, 2))
        if pick_north:
            # Block south as well -> NORTH is unambiguously main!
            for q in range(blue_front - 2, red_front + 3):
                for r in range(b["r_min"], b["r_max"] + 1):
                    if region(q, r, b) == "SOUTH" and b["q_min"] <= q <= b["q_max"]:
                        terr[(q, r)] = 8
            # Clear north corridor
            for q in range(blue_front - 5, red_front + 6):
                for r in range(b["r_min"], b["r_max"] + 1):
                    if region(q, r, b) == "NORTH" and b["q_min"] <= q <= b["q_max"]:
                        terr[(q, r)] = 0
        else:
            # Block north as well -> SOUTH is unambiguously main!
            for q in range(blue_front - 2, red_front + 3):
                for r in range(b["r_min"], b["r_max"] + 1):
                    if region(q, r, b) == "NORTH" and b["q_min"] <= q <= b["q_max"]:
                        terr[(q, r)] = 8
            # Clear south corridor
            for q in range(blue_front - 5, red_front + 6):
                for r in range(b["r_min"], b["r_max"] + 1):
                    if region(q, r, b) == "SOUTH" and b["q_min"] <= q <= b["q_max"]:
                        terr[(q, r)] = 0

    return {"spec": spec, "spec_path": str(spec_path).replace("\\", "/"),
            "rng_seed": f"{spec['episode_id'][:12]}_{k}",
            "bounds": b, "terr": terr, "side": side, "rosters": rosters, "fronts": (red_front, blue_front),
            "hq_depth": rng.randint(5, 8), "rules": rules, "flat": flat,
            "has_rough_center": has_rough_center}


def band(bt: Dict[str, Any], sector: str) -> List[Tuple[int, int]]:
    rf, bf = bt["fronts"]
    return [(q, r) for q in range(bf + 1, rf) for r in range(bt["bounds"]["r_min"], bt["bounds"]["r_max"] + 1)
            if region(q, r, bt["bounds"]) == sector]


def deep_band(bt: Dict[str, Any], sector: str) -> List[Tuple[int, int]]:
    rf, bf = bt["fronts"]
    out = []
    for q in range(bf - 3, rf + 4):
        for r in range(bt["bounds"]["r_min"], bt["bounds"]["r_max"] + 1):
            if region(q, r, bt["bounds"]) == sector and bt["bounds"]["q_min"] <= q <= bt["bounds"]["q_max"]:
                out.append((q, r))
    return out


# ------------------------------------------------------------------ variants
def variants(bt: Dict[str, Any], dec: Dict[str, Any], pkt: Dict[str, Any]) -> List[Tuple[str, str, Dict[str, Any]]]:
    """Generates candidate variants for all families A through H."""
    own = bt["side"]
    foe = "blue" if own == "red" else "red"
    rules = bt["rules"]
    mine = [c for c in bt["rosters"][own][0] if c not in ("scout", "hq")]
    seen = [u for u in pkt["compact_state"]["known_enemy_units"] if u["contact_state"] == "current_visible"]
    out = []

    # ---------------- FAMILY A: NO-MANEUVER outcomes (None) ----------------
    if dec["maneuver"]:
        man_cls = dec["maneuver"].lower()
        # A1: mobility: slow fastest class to line_mp
        v = copy.deepcopy(bt)
        mps = [float(rules["base_mp"][rk(c)]) for c in mine for _ in range(bt["rosters"][own][0].count(c))]
        line_mp = statistics.median(mps) if mps else 2.0
        v["rules"]["base_mp"][rk(man_cls)] = line_mp
        out.append(("A", "mobility_slow_fastest", v))

        # A2: mobility: speed line up to fastest class
        v = copy.deepcopy(bt)
        fast_mp = float(rules["base_mp"][rk(man_cls)])
        for c in set(mine):
            v["rules"]["base_mp"][rk(c)] = fast_mp
        out.append(("A", "mobility_speed_line", v))

        # A3: scout is fastest unit in army (mp 5.0), all combat classes are 2.0 -> no FLANK!
        v = copy.deepcopy(bt)
        for c in set(mine):
            v["rules"]["base_mp"][rk(c)] = 2.0
        v["rules"]["base_mp"]["scout"] = 5.0
        cls, cnt = v["rosters"][own]
        if "scout" not in cls:
            v["rosters"][own] = (cls[:-1] + ["scout"], cnt[:-1] + [250])
        out.append(("A", "scout_fastest", v))

    # ---------------- FAMILY B: MANEUVER APPEARS (None -> class) ----------------
    if dec["maneuver"] is None and mine:
        # B1: speed up archer
        if "archer" in mine:
            v = copy.deepcopy(bt)
            v["rules"]["base_mp"]["archer"] = 4.0
            out.append(("B", "speed_up_archer", v))

        # B2: speed up spearman
        if "spearman" in mine:
            v = copy.deepcopy(bt)
            v["rules"]["base_mp"]["spear"] = 4.0
            out.append(("B", "speed_up_spearman", v))

        # B3: speed up infantry
        if "infantry" in mine:
            v = copy.deepcopy(bt)
            v["rules"]["base_mp"]["infantry"] = 4.0
            out.append(("B", "speed_up_infantry", v))

        # B4: speed up cavalry (or add cavalry)
        v = copy.deepcopy(bt)
        v["rules"]["base_mp"]["cavalry"] = 4.0
        cls, cnt = v["rosters"][own]
        if "cavalry" not in cls:
            v["rosters"][own] = (cls[:-1] + ["cavalry"], cnt[:-1] + [300])
        out.append(("B", "speed_up_cavalry", v))

    # ---------------- FAMILY C: MANEUVER CHANGES CLASS ----------------
    if dec["maneuver"] and len(set(mine)) >= 2:
        fast_cur = dec["maneuver"].lower()
        candidates = [c for c in ("archer", "spearman", "infantry", "cavalry") if c in mine and c != fast_cur]
        for new_fast in candidates:
            v = copy.deepcopy(bt)
            v["rules"]["base_mp"][rk(fast_cur)] = 1.0
            v["rules"]["base_mp"][rk(new_fast)] = 4.0
            out.append(("C", f"fastest_to_{new_fast}", v))

    # ---------------- FAMILY D: TERRAIN, moves TO CENTER ----------------
    if dec["main"] != "CENTER":
        # Base has rough center. Variant opens CENTER!
        # D1: open center completely
        v = copy.deepcopy(bt)
        for cell in deep_band(v, "CENTER"):
            v["terr"][cell] = 0
        out.append(("D", "open_center", v))

        # D2: open center + block previous main flank
        v = copy.deepcopy(bt)
        for cell in deep_band(v, "CENTER"):
            v["terr"][cell] = 0
        for cell in deep_band(v, dec["main"]):
            v["terr"][cell] = 8
        out.append(("D", "open_center_block_flank", v))

        # D3: open center and clear any front obstacles in center
        v3 = copy.deepcopy(bt)
        rf, bf = bt["fronts"]
        for q in range(bf - 4, rf + 5):
            for r in range(bt["bounds"]["r_min"], bt["bounds"]["r_max"] + 1):
                if region(q, r, bt["bounds"]) == "CENTER" and bt["bounds"]["q_min"] <= q <= bt["bounds"]["q_max"]:
                    v3["terr"][(q, r)] = 0
        out.append(("D", "open_center_clear_corridor", v3))

    # ---------------- FAMILY E: TERRAIN, flank asymmetry (NORTH vs SOUTH) ----------------
    # E1: Make NORTH the clear answer (SOUTH has mountain band, NORTH is clear plains)
    v_n = copy.deepcopy(bt)
    for cell in deep_band(v_n, "CENTER"): v_n["terr"][cell] = 8
    for cell in deep_band(v_n, "SOUTH"): v_n["terr"][cell] = 1
    rf, bf = bt["fronts"]
    for q in range(bf - 5, rf + 6):
        for r in range(bt["bounds"]["r_min"], bt["bounds"]["r_max"] + 1):
            if region(q, r, bt["bounds"]) == "NORTH" and bt["bounds"]["q_min"] <= q <= bt["bounds"]["q_max"]:
                v_n["terr"][(q, r)] = 0
    out.append(("E", "asymmetry_pick_north", v_n))

    # E2: Make SOUTH the clear answer (NORTH has mountain band, SOUTH is clear plains)
    v_s = copy.deepcopy(bt)
    for cell in deep_band(v_s, "CENTER"): v_s["terr"][cell] = 8
    for cell in deep_band(v_s, "NORTH"): v_s["terr"][cell] = 1
    for q in range(bf - 5, rf + 6):
        for r in range(bt["bounds"]["r_min"], bt["bounds"]["r_max"] + 1):
            if region(q, r, bt["bounds"]) == "SOUTH" and bt["bounds"]["q_min"] <= q <= bt["bounds"]["q_max"]:
                v_s["terr"][(q, r)] = 0
    out.append(("E", "asymmetry_pick_south", v_s))

    # E3: Make NORTH the clear answer with road corridor (low path cost)
    v_nr = copy.deepcopy(bt)
    for cell in deep_band(v_nr, "CENTER"): v_nr["terr"][cell] = 8
    for cell in deep_band(v_nr, "SOUTH"): v_nr["terr"][cell] = 1
    for q in range(bf - 5, rf + 6):
        for r in range(bt["bounds"]["r_min"], bt["bounds"]["r_max"] + 1):
            if region(q, r, bt["bounds"]) == "NORTH" and bt["bounds"]["q_min"] <= q <= bt["bounds"]["q_max"]:
                v_nr["terr"][(q, r)] = 6
    out.append(("E", "asymmetry_road_north", v_nr))

    # E4: Make SOUTH the clear answer with road corridor (low path cost)
    v_sr = copy.deepcopy(bt)
    for cell in deep_band(v_sr, "CENTER"): v_sr["terr"][cell] = 8
    for cell in deep_band(v_sr, "NORTH"): v_sr["terr"][cell] = 1
    for q in range(bf - 5, rf + 6):
        for r in range(bt["bounds"]["r_min"], bt["bounds"]["r_max"] + 1):
            if region(q, r, bt["bounds"]) == "SOUTH" and bt["bounds"]["q_min"] <= q <= bt["bounds"]["q_max"]:
                v_sr["terr"][(q, r)] = 6
    out.append(("E", "asymmetry_road_south", v_sr))

    # ---------------- FAMILY F: TERRAIN, leaves blocked sector ----------------
    if dec["main"] == "CENTER":
        v1 = copy.deepcopy(bt)
        for cell in deep_band(v1, "CENTER"): v1["terr"][cell] = 8
        for cell in deep_band(v1, "SOUTH"): v1["terr"][cell] = 8
        for q in range(bf - 5, rf + 6):
            for r in range(bt["bounds"]["r_min"], bt["bounds"]["r_max"] + 1):
                if region(q, r, bt["bounds"]) == "NORTH" and bt["bounds"]["q_min"] <= q <= bt["bounds"]["q_max"]:
                    v1["terr"][(q, r)] = 0
        out.append(("F", "wall_center_to_north", v1))

        v2 = copy.deepcopy(bt)
        for cell in deep_band(v2, "CENTER"): v2["terr"][cell] = 8
        for cell in deep_band(v2, "NORTH"): v2["terr"][cell] = 8
        for q in range(bf - 5, rf + 6):
            for r in range(bt["bounds"]["r_min"], bt["bounds"]["r_max"] + 1):
                if region(q, r, bt["bounds"]) == "SOUTH" and bt["bounds"]["q_min"] <= q <= bt["bounds"]["q_max"]:
                    v2["terr"][(q, r)] = 0
        out.append(("F", "wall_center_to_south", v2))
    elif dec["main"] == "NORTH":
        v3 = copy.deepcopy(bt)
        for cell in deep_band(v3, "NORTH"): v3["terr"][cell] = 8
        for q in range(bf - 5, rf + 6):
            for r in range(bt["bounds"]["r_min"], bt["bounds"]["r_max"] + 1):
                if region(q, r, bt["bounds"]) == "CENTER" and bt["bounds"]["q_min"] <= q <= bt["bounds"]["q_max"]:
                    v3["terr"][(q, r)] = 0
        out.append(("F", "wall_north_to_center", v3))
    elif dec["main"] == "SOUTH":
        v4 = copy.deepcopy(bt)
        for cell in deep_band(v4, "SOUTH"): v4["terr"][cell] = 8
        for q in range(bf - 5, rf + 6):
            for r in range(bt["bounds"]["r_min"], bt["bounds"]["r_max"] + 1):
                if region(q, r, bt["bounds"]) == "CENTER" and bt["bounds"]["q_min"] <= q <= bt["bounds"]["q_max"]:
                    v4["terr"][(q, r)] = 0
        out.append(("F", "wall_south_to_center", v4))

    # ---------------- FAMILY G: VISIBLE ENEMY COMPOSITION ----------------
    if len(seen) >= 3:
        for new in ("archer", "cavalry", "spearman", "infantry"):
            v = copy.deepcopy(bt)
            cls, cnt = v["rosters"][foe]
            v["rosters"][foe] = ([new if c not in ("hq", "scout") else c for c in cls], cnt)
            out.append(("G", f"enemy_to_{new}", v))
        v = copy.deepcopy(bt)
        cls, cnt = v["rosters"][foe]
        v["rosters"][foe] = ([("cavalry" if i % 2 else "archer") if c not in ("hq", "scout") else c for i, c in enumerate(cls)], cnt)
        out.append(("G", "enemy_mixed_cav_arc", v))

    # ---------------- FAMILY H: CONTROLS ----------------
    # H1: tiny attack nudge
    v = copy.deepcopy(bt)
    k0 = rk(max(set(mine), key=mine.count)) if mine else "infantry"
    v["rules"]["class_stats"][k0]["attack"] = float(rules["class_stats"][k0]["attack"]) + 0.25
    out.append(("H", "tiny_attack_nudge", v))

    # H2: rear forest patch
    v = copy.deepcopy(bt)
    b = bt["bounds"]
    qs = range(b["q_max"] - 2, b["q_max"] + 1) if own == "red" else range(b["q_min"], b["q_min"] + 3)
    for q in qs:
        for r in range(b["r_max"] - 2, b["r_max"] + 1):
            v["terr"][(q, r)] = 2
    out.append(("H", "rear_forest_patch", v))

    return out


FIELD = {
    "A": "maneuver",
    "B": "maneuver",
    "C": "maneuver",
    "D": "main",
    "E": "main",
    "F": "main",
    "G": "target",
}

# Caps per base battle to ensure balance and prevent over-representation
CAP = {
    "A": 2,
    "B": 4,
    "C": 1,
    "D": 3,
    "E": 2,
    "F": 2,
    "G": 3,
    "H": 2,
}


def build_corpus():
    os.environ["BRAIN_CONTRACT_MODE"] = "unalloc_v1"
    os.environ["BRAIN_CONTEXT_PACK"] = "v0"

    spec_paths = sorted(EPIS.glob("*.json"))
    assert len(spec_paths) == 96, f"Expected 96 specs, found {len(spec_paths)}"

    bases = []
    for spec_idx, p in enumerate(spec_paths):
        for k in range(3):
            bases.append(base_battle(p, k, flat=(k == 0), spec_idx=spec_idx))

    for i, bt in enumerate(bases):
        bt["sid"] = f"s0cb{i:03d}"

    print(f"[Build] Rendering {len(bases)} base battles...")
    rendered_bases = H.build_prompts([render_spec(bt, bt["sid"]) for bt in bases])

    prompts: Dict[str, Dict[str, Any]] = {}
    valid_bases: List[Dict[str, Any]] = []
    var_specs: List[Tuple[Dict[str, Any], str, str, Dict[str, Any], str]] = []

    for bt, r in zip(bases, rendered_bases):
        assert "error" not in r, f"Error rendering base {bt['sid']}: {r}"
        pkt = json.loads(r["messages"][1]["content"])
        plan, dec = teacher(pkt, bt["rng_seed"])
        if plan is None:
            # Ambiguous base battle dropped!
            continue
        bt["plan"], bt["dec"] = plan, dec
        bt["pid"] = f"{bt['sid']}|base"
        prompts[bt["pid"]] = {"messages": r["messages"], "spec": render_spec(bt, bt["sid"])}
        valid_bases.append(bt)

        for j, (family, kind, v) in enumerate(variants(bt, dec, pkt)):
            pid = f"{bt['sid']}|v{j}_{family}_{kind}"
            var_specs.append((bt, family, kind, v, pid))

    print(f"[Build] Valid bases: {len(valid_bases)}/{len(bases)}. Rendering {len(var_specs)} variants...")
    BATCH_SIZE = 150
    rendered_vars = []
    for i in range(0, len(var_specs), BATCH_SIZE):
        chunk = var_specs[i:i + BATCH_SIZE]
        res = H.build_prompts([render_spec(v, bt["sid"]) for bt, _, _, v, _ in chunk])
        rendered_vars.extend(res)

    kept: List[Dict[str, Any]] = []
    rejected: List[Dict[str, Any]] = []
    per_base = Counter()
    kind_counts = Counter()

    for (bt, family, kind, v, pid), r in zip(var_specs, rendered_vars):
        if "error" in r or (r["messages"] == prompts[bt["pid"]]["messages"] and family != "H"):
            rejected.append({"pair": pid, "why": "render_error_or_identical"})
            continue

        pkt = json.loads(r["messages"][1]["content"])
        plan, dec = teacher(pkt, bt["rng_seed"])
        if plan is None:
            rejected.append({"pair": pid, "why": "ambiguous_tie"})
            continue

        # Acceptance check
        if family == "H":
            ok = (plan == bt["plan"])
            if not ok:
                rejected.append({"pair": pid, "why": "control_changed_plan"})
                continue
        else:
            field = FIELD[family]
            changed = (dec[field] != bt["dec"][field])
            if not changed:
                rejected.append({"pair": pid, "why": "decision_unchanged"})
                continue

            # Additional family-specific semantic checks:
            if family == "A" and dec["maneuver"] is not None:
                rejected.append({"pair": pid, "why": "family_A_maneuver_not_none"})
                continue
            if family == "B" and (bt["dec"]["maneuver"] is not None or dec["maneuver"] is None):
                rejected.append({"pair": pid, "why": "family_B_maneuver_invalid"})
                continue
            if family == "C":
                if bt["dec"]["maneuver"] is None or dec["maneuver"] is None:
                    rejected.append({"pair": pid, "why": "family_C_maneuver_none"})
                    continue
                if kind_counts["fam_c"] >= 180:
                    rejected.append({"pair": pid, "why": "cap_c"})
                    continue
            if family == "D":
                if bt["dec"]["main"] == "CENTER" or dec["main"] != "CENTER":
                    rejected.append({"pair": pid, "why": "family_D_not_to_center"})
                    continue
                # Ensure flat vs terrain balance in Family D (cap terrain pairs so flat >= 32%)
                if not bt["flat"] and kind_counts["fam_d_terrain"] >= 210:
                    rejected.append({"pair": pid, "why": "cap_d_terrain"})
                    continue
                if bt["flat"] and kind_counts["fam_d_flat"] >= 115:
                    rejected.append({"pair": pid, "why": "cap_d_flat"})
                    continue
            if family == "E":
                if dec["main"] not in ("NORTH", "SOUTH"):
                    rejected.append({"pair": pid, "why": "family_E_not_flank"})
                    continue
                # Balance NORTH vs SOUTH in Family E (each capped to maintain equal balance)
                if dec["main"] == "NORTH" and kind_counts["fam_e_north"] >= 155:
                    rejected.append({"pair": pid, "why": "cap_e_north"})
                    continue
                if dec["main"] == "SOUTH" and kind_counts["fam_e_south"] >= 155:
                    rejected.append({"pair": pid, "why": "cap_e_south"})
                    continue
            if family == "F":
                if dec["main"] == bt["dec"]["main"]:
                    rejected.append({"pair": pid, "why": "family_F_did_not_leave_main"})
                    continue
                if kind_counts["fam_f"] >= 200:
                    rejected.append({"pair": pid, "why": "cap_f"})
                    continue

        if per_base[(bt["sid"], family)] >= CAP.get(family, 2):
            rejected.append({"pair": pid, "why": "cap"})
            continue

        per_base[(bt["sid"], family)] += 1
        kind_counts[kind] += 1
        if family == "C":
            kind_counts["fam_c"] += 1
        elif family == "D":
            if bt["flat"]:
                kind_counts["fam_d_flat"] += 1
            else:
                kind_counts["fam_d_terrain"] += 1
        elif family == "E":
            if dec["main"] == "NORTH":
                kind_counts["fam_e_north"] += 1
            else:
                kind_counts["fam_e_south"] += 1
        elif family == "F":
            kind_counts["fam_f"] += 1

        prompts[pid] = {"messages": r["messages"], "spec": render_spec(v, bt["sid"])}
        kept.append({"pair": pid, "base": bt["pid"], "family": family, "kind": kind,
                     "bt": bt, "plan": plan, "dec": dec})

    print(f"[Build] Kept candidate pairs: {len(kept)}. Validating strict production pass...")

    targets = {bt["pid"]: bt["plan"] for bt in valid_bases}
    targets.update({p["pair"]: p["plan"] for p in kept})

    val_items = [{"id": k, "text": json.dumps(t, ensure_ascii=False, separators=(",", ":")),
                  "scenario": prompts[k]["spec"]} for k, t in targets.items()]
    val = H.validate(val_items)
    good = {x["id"] for x in val if x["strict_first_pass"]}
    final = [p for p in kept if p["pair"] in good and p["base"] in good]
    rejected += [{"pair": p["pair"], "why": "strict_invalid"} for p in kept if p not in final]

    print(f"[Build] Strict valid pairs: {len(final)}")
    used = sorted({p["base"] for p in final} | {p["pair"] for p in final})

    # Rows generation
    rows = []
    for pid in used:
        bt = next(b for b in valid_bases if pid.startswith(b["sid"] + "|"))
        spec = bt["spec"]
        pair = next((p for p in final if p["pair"] == pid), None)
        text = json.dumps(targets[pid], ensure_ascii=False, separators=(",", ":"))
        dev = (int(spec["seeds"]["sample"]) % 12 == 11)
        fam = pair["family"] if pair else "base"
        knd = pair["kind"] if pair else "base"
        p_base = pair["base"] if pair else None
        d = decisions(targets[pid])

        # Assert no class name in prose
        assert not CLASS_REGEX.search(extract_prose(targets[pid])), f"Class name in prose for {pid}"

        rows.append({
            "row_id": pid,
            "source": "contextual_s0c_teacher_v3",
            "prompt_id": pid,
            "target": text,
            "split": "dev" if dev else "train",
            "schema": "unalloc_v1",
            "episode_id": spec["episode_id"],
            "episode_spec_path": bt["spec_path"],
            "episode_family": spec["family"],
            "episode_split": spec["split"],
            "map": spec["map"]["id"],
            "terrain": "flat" if bt["flat"] else "catalog_window",
            "family": fam,
            "kind": knd,
            "pair_base": p_base,
            "decisions": d,
        })

    # Verification of balance gates
    print("\n[Build] Verifying Balance Gates...")
    counts = Counter(p["family"] for p in final)
    print("Pairs per family:", dict(counts))

    man_none_rate = sum(r["decisions"]["maneuver"] is None for r in rows) / len(rows)
    print(f"maneuver=None rate: {man_none_rate:.4f} (gate: 0.30 - 0.45)")

    man_classes = [r["decisions"]["maneuver"] for r in rows if r["decisions"]["maneuver"] is not None]
    cls_dist = Counter(man_classes)
    for c, cnt in cls_dist.items():
        crate = cnt / len(man_classes)
        print(f"maneuver class {c}: {crate:.4f} (gate: <= 0.35)")

    main_dist = Counter(r["decisions"]["main"] for r in rows)
    for s in ("NORTH", "CENTER", "SOUTH"):
        srate = main_dist[s] / len(rows)
        print(f"main {s}: {srate:.4f} (gate: 0.25 - 0.45)")

    scout_tgt = sum(r["decisions"]["target"] == "SCOUT" for r in rows) / len(rows)
    print(f"target SCOUT rate: {scout_tgt:.4f} (gate: < 0.01)")

    doctrine_distinct = len({json.dumps(targets[pid]["doctrine"]) for pid in used})
    print(f"Distinct doctrine vectors: {doctrine_distinct} (gate: >= 300)")

    fam_e = [p for p in final if p["family"] == "E"]
    e_n = sum(p["dec"]["main"] == "NORTH" for p in fam_e)
    e_s = sum(p["dec"]["main"] == "SOUTH" for p in fam_e)
    print(f"Family E directions: NORTH={e_n} ({e_n/len(fam_e):.4f}), SOUTH={e_s} ({e_s/len(fam_e):.4f}) (gate: >= 0.40 each)")

    for f in ("A", "B", "C", "D", "E", "F", "G"):
        f_pairs = [p for p in final if p["family"] == f]
        flat_r = sum(p["bt"]["flat"] for p in f_pairs) / len(f_pairs)
        print(f"Family {f} flat rate: {flat_r:.4f}, terrain rate: {1-flat_r:.4f} (gate: >= 0.30 each)")

    h_rate = counts["H"] / len(final)
    print(f"Family H rate: {h_rate:.4f} (gate: >= 0.12)")

    # Assert all gates
    assert counts["A"] >= 350, f"Family A {counts['A']} < 350"
    assert counts["B"] >= 200, f"Family B {counts['B']} < 200"
    assert counts["C"] >= 150, f"Family C {counts['C']} < 150"
    assert counts["D"] >= 250, f"Family D {counts['D']} < 250"
    assert counts["E"] >= 250, f"Family E {counts['E']} < 250"
    assert counts["F"] >= 150, f"Family F {counts['F']} < 150"
    assert counts["G"] >= 200, f"Family G {counts['G']} < 200"
    assert h_rate >= 0.12, f"Family H {h_rate:.4f} < 0.12"

    assert 0.30 <= man_none_rate <= 0.45, f"maneuver=None rate {man_none_rate:.4f} not in [0.30, 0.45]"
    for c, cnt in cls_dist.items():
        assert cnt / len(man_classes) <= 0.35, f"maneuver class {c} > 0.35"

    for s in ("NORTH", "CENTER", "SOUTH"):
        assert 0.25 <= main_dist[s] / len(rows) <= 0.45, f"main {s} not in [0.25, 0.45]"

    assert scout_tgt < 0.01, f"target SCOUT rate {scout_tgt:.4f} >= 0.01"
    assert e_n / len(fam_e) >= 0.40, f"Family E NORTH {e_n/len(fam_e):.4f} < 0.40"
    assert e_s / len(fam_e) >= 0.40, f"Family E SOUTH {e_s/len(fam_e):.4f} < 0.40"

    for f in ("A", "B", "C", "D", "E", "F", "G"):
        f_pairs = [p for p in final if p["family"] == f]
        flat_r = sum(p["bt"]["flat"] for p in f_pairs) / len(f_pairs)
        assert flat_r >= 0.30, f"Family {f} flat rate {flat_r:.4f} < 0.30"
        assert (1 - flat_r) >= 0.30, f"Family {f} terrain rate {1-flat_r:.4f} < 0.30"

    assert doctrine_distinct >= 300, f"Distinct doctrine {doctrine_distinct} < 300"

    print("\nALL BALANCE GATES PASSED!")

    # Write files
    OUT.mkdir(parents=True, exist_ok=True)
    with open(OUT / "sft_rows.jsonl", "w", encoding="utf-8", newline="\n") as f:
        for r in rows:
            f.write(json.dumps(r, ensure_ascii=False) + "\n")

    with open(OUT / "s0c_prompts.json", "w", encoding="utf-8", newline="\n") as f:
        json.dump([{"prompt_id": k, "messages": prompts[k]["messages"]} for k in used], f, ensure_ascii=False)

    with open(OUT / "rejected_pairs.json", "w", encoding="utf-8", newline="\n") as f:
        json.dump(rejected, f, indent=1)

    manifest = {
        "version": "CONTEXTUAL_BRAIN_S0C_CORPUS_V0",
        "episodes": len(spec_paths),
        "bases": len(valid_bases),
        "rows": len(rows),
        "train_rows": sum(r["split"] == "train" for r in rows),
        "dev_rows": sum(r["split"] == "dev" for r in rows),
        "pairs_kept": len(final),
        "pairs_by_family": dict(counts),
        "pairs_by_kind": dict(Counter(p["kind"] for p in final)),
        "pairs_by_family_and_terrain": dict(Counter(f"{p['family']}|{'flat' if p['bt']['flat'] else 'terrain'}" for p in final)),
        "rejected": dict(Counter(x["why"] for x in rejected)),
        "target_distribution": dict(Counter(r["decisions"]["target"] for r in rows)),
        "maneuver_distribution": dict(Counter(r["decisions"]["maneuver"] for r in rows)),
        "main_distribution": dict(Counter(r["decisions"]["main"] for r in rows)),
        "splits_used": sorted({r["episode_split"] for r in rows}),
        "doctrine_distinct": doctrine_distinct,
        "balance_gates": {
            "maneuver_none_rate": man_none_rate,
            "maneuver_class_max_rate": max(cls_dist.values()) / len(man_classes),
            "main_north_rate": main_dist["NORTH"] / len(rows),
            "main_center_rate": main_dist["CENTER"] / len(rows),
            "main_south_rate": main_dist["SOUTH"] / len(rows),
            "target_scout_rate": scout_tgt,
            "family_e_north_rate": e_n / len(fam_e),
            "family_e_south_rate": e_s / len(fam_e),
            "family_h_rate": h_rate,
            "prose_class_name_rate": 0.0,
            "doctrine_distinct_ge_300": doctrine_distinct >= 300,
        },
        "sft_rows_sha256": hashlib.sha256((OUT / "sft_rows.jsonl").read_bytes()).hexdigest(),
        "prompts_sha256": hashlib.sha256((OUT / "s0c_prompts.json").read_bytes()).hexdigest(),
    }
    with open(OUT / "CORPUS_MANIFEST.json", "w", encoding="utf-8", newline="\n") as f:
        json.dump(manifest, f, indent=1)

    print("\nCORPUS MANIFEST GENERATED:")
    print(json.dumps(manifest, indent=1))


if __name__ == "__main__":
    build_corpus()
