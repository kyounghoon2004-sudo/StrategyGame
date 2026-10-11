"""CONTEXTUAL_BRAIN_S0 corpus: paired counterfactual SFT rows from TRAIN EpisodeSpecs.

  python -m tools.contextual_brain.s0_corpus

1. Battles: each TRAIN-split EpisodeSpec (artifacts/contextual_brain_s0/episodes, sampled by Track B's
   EpisodeSpec.sample) gives 2 battles rendered through the PRODUCTION harness: the episode's full
   rules (installed in EpisodeRuntime, read by the engine and the pack), a window of the episode's
   real catalog terrain, and the episode's roster classes/counts on two contact lines.
2. Pairs: one factor flipped per pair (movement, combat/matchup, friendly composition, visible enemy
   composition, terrain) + controls (tiny stat nudge, far-rear terrain). Objective: not variable in
   episode_spec_v0 (single native mode) -> no mode pairs.
3. Teacher: a deterministic plan from the CONTEXT PACK ONLY (never from class names): maneuver force =
   fastest combat class by current mp; main effort = sector with the cheapest path to known contacts;
   target = visible class with the best current matchup x attack/defense. unalloc_v1, no friendly ids.
4. Filters: strict production validation (Godot) + pair consistency (relevant pair must change the
   factor's decision, control pair must be identical). Failing pairs are dropped, never repaired.
Probe cases (tools/contract_sft/context_probe.py) are never used or imitated here.
"""
from __future__ import annotations

import copy
import hashlib
import json
import os
import random
import statistics
from pathlib import Path

from tools.contract_sft import harness as H

ROOT = Path(r"D:\Game development\Demon slayer\StrategyGame")
OUT = ROOT / "artifacts" / "contextual_brain_s0"
EPIS = OUT / "episodes"
CATALOG = ROOT / "data" / "battlefields" / "rl_canonical_v1"
LEGEND = {".": 0, "M": 1, "F": 2, "S": 3, "V": 5, "R": 6, "B": 6, "W": 7, "X": 9, "C": 11}
BLOCKED = {8, 9, 10}
TAG = {"infantry": "INF", "archer": "ARC", "cavalry": "CAV", "spearman": "SPE", "scout": "SCT", "siege": "SIE",
       "conscript": "CON", "hq": "HQ"}
SECT3 = ["NORTH", "CENTER", "SOUTH"]
COMBAT_EXCLUDE = {"HQ", "SCOUT"}  # scout = recon specialist (design invariant), HQ = terminal unit


# ------------------------------------------------------------------ battles
def catalog_terrain(map_id):
    f = {"BF01": "bf01_open_plain.json", "BF02": "bf02_forest_edge.json", "BF04": "bf04_mountain_pass.json",
         "BF07": "bf07_fortified_approach.json"}[map_id]  # TRAIN maps only
    d = json.loads((CATALOG / f).read_text(encoding="utf-8"))
    out = {}
    for i, row in enumerate(d["rows"]):
        for j, ch in enumerate(row):
            if ch != " ":
                out[(d["q_min"] + i, d["r_min"] + j)] = LEGEND[ch]
    return out


def region(q, r, b):
    vmin, vmax = 2 * b["r_min"] + b["q_min"], 2 * b["r_max"] + b["q_max"]
    t = (2 * r + q - vmin) / max(1, vmax - vmin)
    return "NORTH" if t < 1 / 3 else ("SOUTH" if t > 2 / 3 else "CENTER")


def place(slots, q0, taken, terr, b, direction):
    """Nearest free passable cell to (q0, r) for each slot, searching back from the front."""
    out = []
    for r in slots:
        for dq in range(0, 8):
            for rr in (r, r + 1, r - 1, r + 2, r - 2):
                q = q0 + direction * dq
                if b["q_min"] <= q <= b["q_max"] and b["r_min"] <= rr <= b["r_max"] and (q, rr) not in taken \
                        and terr.get((q, rr), 0) not in BLOCKED:
                    taken.add((q, rr))
                    out.append((q, rr))
                    break
            else:
                continue
            break
        else:
            out.append(None)
    return out


def army(prefix, faction, classes, counts, front, hq_q, terr, b, taken, direction):
    rng_slots = [round(b["r_min"] + 1 + k * (b["r_max"] - b["r_min"] - 2) / max(1, len(classes) - 1)) for k in range(len(classes))]
    cells = place(rng_slots, front, taken, terr, b, direction)
    hq = place([round((b["r_min"] + b["r_max"]) / 2)], hq_q, taken, terr, b, direction)[0]
    seen, units = {}, []
    for cls, n, cell in zip(classes, counts, cells):
        if cell is None:
            continue
        seen[cls] = seen.get(cls, 0) + 1
        units.append({"id": f"{prefix}_{TAG[cls]}_{seen[cls]}", "class": cls, "faction": faction,
                      "q": cell[0], "r": cell[1], "soldiers": int(n)})
    units.append({"id": f"{prefix}_HQ_1", "class": "hq", "faction": faction, "q": hq[0], "r": hq[1], "soldiers": 300})
    return sorted(units, key=lambda u: u["id"])


def base_battle(spec_path, k):
    spec = json.loads(Path(spec_path).read_text(encoding="utf-8"))
    rng = random.Random(f"{spec['episode_id']}:{k}")
    terr_all = catalog_terrain(spec["map"]["id"])
    w, h = rng.choice([20, 22, 24]), rng.choice([8, 10, 12])
    cq, cr = rng.randint(-8, 8), rng.randint(-8, 8)
    b = {"q_min": cq - w, "q_max": cq + w, "r_min": cr - h, "r_max": cr + h}
    terr = {(q, r): terr_all.get((q, r), 0) for q in range(b["q_min"], b["q_max"] + 1) for r in range(b["r_min"], b["r_max"] + 1)}
    gap = rng.choice([2, 2, 3, 4])
    side = "red" if (k + int(spec["seeds"]["sample"])) % 2 == 0 else "blue"
    rosters = {}
    for fac in ("red", "blue"):
        rows = [u for u in spec["armies"] if u["faction"] == fac and u["class"] != "hq"]
        rng.shuffle(rows)
        rows = rows[:rng.randint(6, 9)]
        rosters[fac] = ([("spearman" if u["class"] == "spear" else u["class"]) for u in rows], [u["count"] for u in rows])
    red_front = cq + gap // 2 + gap % 2
    blue_front = red_front - gap
    return {"spec": spec, "spec_path": str(spec_path).replace("\\", "/"), "rng_seed": f"{spec['episode_id'][:12]}_{k}",
            "bounds": b, "terr": terr, "side": side, "rosters": rosters, "fronts": (red_front, blue_front),
            "hq_depth": rng.randint(5, 8), "rules": copy.deepcopy(spec["rules"])}


def render_spec(bt, sid):
    b, terr = bt["bounds"], bt["terr"]
    taken = set()
    rf, bf = bt["fronts"]
    red = army("R", "red", *bt["rosters"]["red"], rf, rf + bt["hq_depth"], terr, b, taken, +1)
    blue = army("B", "blue", *bt["rosters"]["blue"], bf, bf - bt["hq_depth"], terr, b, taken, -1)
    spec = bt["spec"]
    return {"scenario_id": sid, "side": bt["side"], "seed": 29, "red_forces": red, "blue_forces": blue,
            "primary_objective": "destroy_all_red", "turn_limit": 12, "bounds": b, "default_terrain": 0,
            "terrain_overrides": {f"{q},{r}": t for (q, r), t in terr.items() if t != 0},
            "rule_deltas": bt["rules"],
            "episode_meta": {"episode_id": spec["episode_id"], "family": spec["family"], "split": spec["split"]}}


# ------------------------------------------------------------------ teacher
def teacher(packet, rng_seed):
    """Plan from the context pack + compact_state only. Returns (plan, decisions)."""
    ctx, cs = packet["context"], packet["compact_state"]
    rules = ctx["rules"]["classes"]
    mu = {(a, d): m for a, d, m in ctx["rules"]["matchups"]}

    def match(a, d):
        return mu.get((a, d)) or (1 / mu[(d, a)] if (d, a) in mu else 1.0)

    fr = ctx["forces"]["friendly"]["by_class"]
    combat = sorted(c for c in fr if c not in COMBAT_EXCLUDE)
    weights = [rules[c]["mp"] for c in combat for _ in range(fr[c][0])]
    line_mp = statistics.median(weights) if weights else 1.0
    line_cls = max(combat, key=lambda c: (fr[c][0], rules[c]["def"], c)) if combat else None
    fast = max(combat, key=lambda c: (rules[c]["mp"], fr[c][0], c)) if combat else None
    maneuver = fast if fast and rules[fast]["mp"] >= line_mp + 1 else None
    vis = ctx["forces"]["enemy_visible"]["by_class"]
    evis = [c for c in vis if c in rules]
    target, tscore, best_f, best_m = None, None, None, 1.0
    for c in sorted(evis):
        adv = max((match(f, c) * rules[f]["atk"] / max(1.0, rules[c]["def"]), f) for f in combat) if combat else (1.0, None)
        s = (vis[c][0] * adv[0], c)
        if tscore is None or s > tscore:
            target, tscore, best_f, best_m = c, s, adv[1], (match(adv[1], c) if adv[1] else 1.0)
    tr = ctx["map"].get("travel_from_own_hq", {})
    by_sec = ctx["forces"]["formations_by_sector"]

    def detour(s):
        t = tr.get(f"NEAREST_ENEMY_{s}") or tr.get(s)
        if not t or not isinstance(t.get("path_cost_std_terrain"), (int, float)):
            return 9.0, t
        return round(t["path_cost_std_terrain"] / max(1, t["hexes"]), 2), t

    cands = [s for s in SECT3 if by_sec[s][1] > 0] or SECT3
    main = min(cands, key=lambda s: (detour(s)[0] > 1.3, -by_sec[s][1], detour(s)[0], SECT3.index(s) != 1, s))
    flank = min([s for s in SECT3 if s != main], key=lambda s: (detour(s)[0], s == "CENTER", s))
    own_hq = next((u for u in cs["friendly_units"] if u["class"] == "HQ"), {"region": "CENTER"})
    hq_sec = own_hq.get("region") or "CENTER"
    tmain = detour(main)[1] or {}
    turns = tmain.get("turns", {}).get(line_cls) if line_cls else None
    T = max(2, min(6, turns if isinstance(turns, int) else 4))
    foe = "BLUE" if packet["acting_side"] == "RED" else "RED"
    cd = detour("CENTER")
    rough_center = main != "CENTER" and cd[0] > 1.3
    limits = []
    for f in combat:
        for c in sorted(set(evis) | set(ctx["forces"]["enemy_last_known"]["by_class"])):
            if c in rules and match(f, c) <= 0.8 and len(limits) < 2:
                limits.append(f"Keep {f.lower()} out of long contact with {c.lower()} (matchup x{match(f, c):.2f}).")
    r = ctx["forces"].get("visible_soldier_ratio") or 1.0
    cl = lambda x: round(min(0.9, max(0.1, x)), 2)
    doctrine = [cl(0.3 + 0.2 * min(r, 2.5)), cl(0.25 + 0.15 * min(r, 2.5)),
                cl(0.35 + 0.15 * ((rules[fast]["mp"] if fast else line_mp) - line_mp) + 0.05 * T / 2),
                cl(0.35 + (0.2 if maneuver else 0.0)),
                cl(0.65 if (ctx["map"].get("nearest_visible_contact_hexes") or 99) <= 4 else 0.45),
                cl(0.3 if maneuver else 0.12)]
    rng = random.Random(rng_seed)
    ph = [rng.choice(["SHAPE", "DEVELOP", "OPEN"]), rng.choice(["ENGAGE", "BREAK IN", "COMMIT"]), rng.choice(["DECIDE", "FINISH", "EXPLOIT"])]
    tv = {"vs": target} if target else {}
    hx = tmain.get("hexes", "?")
    terrain_note = (f" CENTER path costs {cd[1]['path_cost_std_terrain']} for {cd[1]['hexes']} hexes, so the main effort is {main}."
                    if rough_center and cd[1] else "")
    if maneuver:
        man_intent = f"{maneuver.lower()} is fastest here (mp {rules[maneuver]['mp']:g} vs line {line_mp:g}): swing through {flank} onto the {main} flank."
        man = {"task": "FLANK", "area": flank, "prefer": {"classes": [maneuver]}}
    else:
        man_intent = f"No class outpaces the line here (best mp {rules[fast]['mp']:g} vs {line_mp:g}): extend the front through {flank}." if fast \
            else f"Extend the front through {flank}."
        man = {"task": "ADVANCE", "area": flank}
    win_t = [{"when": "TURNS_ELAPSED", "turns": T, "since": 1}]
    third = ({"task": "RECON", "area": main if not evis else flank, "prefer": {"classes": ["SCOUT"]},
              "intent": f"Scout toward {main if not evis else flank}; confirm enemy strength."} if "SCOUT" in fr else
             {"task": "HOLD", "area": hq_sec, "preserve": True, "intent": f"Cover the HQ sector ({hq_sec})."})
    tgt_txt = (f"{target.lower()} ({vis[target][0]} seen; best matchup {best_f.lower()} x{best_m:.2f})" if target and best_f
               else (target.lower() if target else "enemy line"))
    p1 = [dict(task="FIX", area=main, intent=(f"Pin the {tgt_txt} at {main}, {hx} hexes out.{terrain_note}")[:160],
               priority="high", **tv, win=win_t, stop=[{"when": "FORCE_STRENGTH_BELOW", "fraction": 0.5}]),
          dict(man, intent=man_intent[:160], priority="medium", **tv, win=win_t, stop=["HQ_THREATENED"]),
          dict(third, priority="low", win=win_t, stop=["HQ_THREATENED"])]
    if limits:
        p1[0]["limits"] = limits[:2]
    p2 = [dict(task="ATTACK", area=main, intent=f"Strike the {tgt_txt}."[:160], priority="high", **tv,
               win=[{"when": "LOCAL_ADVANTAGE_HIGH", "region": main, "ratio": 1.5}], stop=[{"when": "FORCE_STRENGTH_BELOW", "fraction": 0.4}]),
          dict(man, intent=("Keep the " + ("flank attack" if maneuver else "wide front") + f" moving through {flank}.")[:160],
               priority="medium", **tv, win=win_t, stop=["HQ_THREATENED"]),
          dict(task="RESERVE", area=hq_sec, preserve=True, priority="medium",
               intent=f"Hold a reserve at {hq_sec} to protect the HQ and exploit a breach.", win=win_t, stop=["HQ_THREATENED"])]
    p3 = [dict(task="ATTACK", area=main, vs="HQ", pursue=True, priority="high", intent=f"Drive on the {foe} HQ through {main}.",
               win=win_t, stop=[{"when": "FORCE_STRENGTH_BELOW", "fraction": 0.3}]),
          dict(task="ATTACK", area=flank, priority="medium", **tv, intent=f"Collapse the {flank} side of the {foe} line.", win=win_t, stop=["HQ_THREATENED"]),
          dict(task="HOLD", area=hq_sec, preserve=True, priority="medium", intent=f"Keep the HQ covered at {hq_sec}.", win=win_t, stop=["HQ_THREATENED"])]
    phases = []
    for i, (name, ms) in enumerate(zip(ph, (p1, p2, p3))):
        phases.append({"id": f"P{i + 1}", "name": f"{name} {main}", "purpose": ("Fix and shape" if i == 0 else "Break the line" if i == 1 else "Win")
                       + f" at {main}.", "intent": (man_intent if i == 0 else f"Main effort {main}; {flank} supports.")[:160],
                       "missions": ms, "win": win_t, "lose": [{"when": "FORCE_STRENGTH_BELOW", "fraction": 0.4}],
                       "abort": ["HQ_THREATENED"], "next": "END" if i == 2 else f"P{i + 2}", "on_fail": "HOLD"})
    plan = {"objective": (f"Destroy the {foe} HQ: fix at {main}, " + (f"turn it through {flank} with {maneuver.lower()}"
                          if maneuver else f"widen through {flank}") + ", keep the HQ covered.")[:200],
            "end_state": f"{foe} HQ destroyed; own HQ intact.", "cadence": max(2, min(5, T)), "doctrine": doctrine,
            "phases": phases, "abort": [{"when": "FORCE_STRENGTH_BELOW", "fraction": 0.25}],
            "hypotheses": [{"h": f"{foe}_MASS_{max(SECT3, key=lambda s: by_sec[s][1])}", "conf": 0.6,
                            "ev": [f"{sum(by_sec[s][1] for s in SECT3)} visible formations"]}]}
    return plan, {"maneuver": maneuver, "main": main, "flank": flank, "target": target, "limits": limits}


# ------------------------------------------------------------------ counterfactuals
def combat_classes(bt, fac):
    return [c for c in bt["rosters"][fac][0] if c not in ("scout", "hq")]


def rk(cls):
    return "spear" if cls == "spearman" else cls


def variants(bt, dec, base_pkt):
    """[(factor, kind, battle)] one-factor counterfactuals of a rendered base battle."""
    own = bt["side"]
    foe = "blue" if own == "red" else "red"
    out = []
    mine = combat_classes(bt, own)
    rules = bt["rules"]
    if mine:
        fast = max(set(mine), key=lambda c: (rules["base_mp"][rk(c)], mine.count(c), c))
        other = max((c for c in set(mine) if c != fast), key=lambda c: (mine.count(c), c), default=None)
        if other:
            v = copy.deepcopy(bt)
            v["rules"]["base_mp"][rk(fast)] = 1.0
            v["rules"]["base_mp"][rk(other)] = min(5.0, float(rules["base_mp"][rk(fast)]) + 1.0)
            out.append(("movement", "swap_fastest", v))
    tgt = dec["target"]
    if tgt:
        v = copy.deepcopy(bt)
        tk = rk(tgt.lower())
        v["rules"]["class_stats"][tk]["defense"] = min(25.0, float(rules["class_stats"][tk]["defense"]) * 2.5)
        v["rules"]["class_stats"][tk]["attack"] = min(30.0, float(rules["class_stats"][tk]["attack"]) * 1.5)
        out.append(("combat", "target_hardened", v))
        flips = [k for k in rules["matchup"] if k.endswith("_vs_" + tk) or k.startswith(tk + "_vs_")]
        if flips:
            v = copy.deepcopy(bt)
            for k in flips:
                v["rules"]["matchup"][k] = round(min(2.0, max(0.4, 1.0 / float(rules["matchup"][k]))), 3)
            out.append(("combat", "matchup_inverted", v))
    if mine:
        v = copy.deepcopy(bt)
        cls, cnt = v["rosters"][own]
        if dec["maneuver"]:
            man = dec["maneuver"].lower()
            repl = max((c for c in set(mine) if c != man), key=lambda c: (mine.count(c), c), default="infantry")
            v["rosters"][own] = ([repl if c == man else c for c in cls], cnt)
        else:
            quick = max(("cavalry", "infantry", "spearman", "archer"), key=lambda c: (rules["base_mp"][rk(c)], c))
            v["rosters"][own] = ([quick if (c in mine and i % 2 == 0) else c for i, c in enumerate(cls)], cnt)
        out.append(("friendly_composition", "reclass", v))
    seen = [u for u in base_pkt["compact_state"]["known_enemy_units"] if u["contact_state"] == "current_visible"]
    if len(seen) >= 3:
        for new in ("archer", "cavalry", "spearman"):
            if tgt and new == tgt.lower():
                continue
            v = copy.deepcopy(bt)
            cls, cnt = v["rosters"][foe]
            v["rosters"][foe] = ([new if c not in ("hq", "scout") else c for c in cls], cnt)
            out.append(("enemy_composition", f"visible_to_{new}", v))
    rf, bf = bt["fronts"]
    v = copy.deepcopy(bt)
    b = bt["bounds"]
    for q in range(bf + 1, rf):
        for r in range(b["r_min"], b["r_max"] + 1):
            if region(q, r, b) == dec["main"]:
                v["terr"][(q, r)] = 8
    out.append(("terrain", f"wall_{dec['main'].lower()}", v))
    # controls
    v = copy.deepcopy(bt)
    k0 = rk(max(set(mine), key=mine.count)) if mine else "infantry"
    v["rules"]["class_stats"][k0]["attack"] = float(rules["class_stats"][k0]["attack"]) + 0.25
    out.append(("control", "tiny_attack_nudge", v))
    v = copy.deepcopy(bt)
    qe = b["q_max"] if own == "red" else b["q_min"]
    for q in range(qe - 2, qe + 1) if own == "red" else range(qe, qe + 3):
        for r in range(b["r_max"] - 2, b["r_max"] + 1):
            v["terr"][(q, r)] = 2
    out.append(("control", "rear_forest_patch", v))
    return out


def decision_changed(factor, da, db, pa, pb):
    if factor == "movement":
        return da["maneuver"] != db["maneuver"]
    if factor == "combat":
        return da["target"] != db["target"] or da["limits"] != db["limits"]
    if factor == "friendly_composition":
        return da["maneuver"] != db["maneuver"]
    if factor == "enemy_composition":
        return da["target"] != db["target"]
    if factor == "terrain":
        return da["main"] != db["main"]
    return pa != pb  # control: must be identical -> "changed" means reject


# ------------------------------------------------------------------ build
def main():
    os.environ["BRAIN_CONTRACT_MODE"] = "unalloc_v1"
    os.environ["BRAIN_CONTEXT_PACK"] = "v0"
    specs = sorted(EPIS.glob("*.json"))
    bases = [base_battle(p, k) for p in specs for k in range(2)]
    for i, bt in enumerate(bases):
        bt["sid"] = f"s0b{i:03d}"
    rendered = H.build_prompts([render_spec(bt, bt["sid"]) for bt in bases])
    items, pairs, prompts = [], [], {}
    var_specs = []
    for bt, r in zip(bases, rendered):
        assert "error" not in r, r
        pkt = json.loads(r["messages"][1]["content"])
        plan, dec = teacher(pkt, bt["rng_seed"])
        bt["pid"] = f"{bt['sid']}|base"
        prompts[bt["pid"]] = {"prompt_id": bt["pid"], "messages": r["messages"], "spec": render_spec(bt, bt["sid"])}
        bt["plan"], bt["dec"], bt["pkt"] = plan, dec, pkt
        for j, (factor, kind, v) in enumerate(variants(bt, dec, pkt)):
            v["sid"] = bt["sid"]  # same scenario id: the id never leaks the manipulation
            var_specs.append((bt, factor, kind, v, f"{bt['sid']}|v{j}_{factor}_{kind}"))
    rv = H.build_prompts([render_spec(v, v["sid"]) for _, _, _, v, _ in var_specs])
    kept_pairs, rejected = [], []
    for (bt, factor, kind, v, pid), r in zip(var_specs, rv):
        if "error" in r:
            rejected.append({"pair": pid, "why": "render_error"})
            continue
        pkt = json.loads(r["messages"][1]["content"])
        plan, dec = teacher(pkt, bt["rng_seed"])
        if r["messages"] == prompts[bt["pid"]]["messages"]:
            rejected.append({"pair": pid, "why": "prompt_identical"})
            continue
        changed = decision_changed(factor, bt["dec"], dec, bt["plan"], plan)
        if (factor == "control") == changed:
            rejected.append({"pair": pid, "why": "control_changed_plan" if factor == "control" else "teacher_did_not_respond"})
            continue
        prompts[pid] = {"prompt_id": pid, "messages": r["messages"], "spec": render_spec(v, v["sid"])}
        kept_pairs.append({"pair": pid, "base": bt["pid"], "factor": factor, "kind": kind, "bt": bt,
                           "plan": plan, "dec_a": bt["dec"], "dec_b": dec})
    # Strict production validation of every teacher target (base + variants).
    targets = {bt["pid"]: bt["plan"] for bt in bases}
    targets.update({p["pair"]: p["plan"] for p in kept_pairs})
    val = H.validate([{"id": k, "text": json.dumps(t, ensure_ascii=False, separators=(",", ":")), "scenario": prompts[k]["spec"]}
                      for k, t in targets.items()])
    ok = {v["id"] for v in val if v["strict_first_pass"]}
    bad_bases = {bt["pid"] for bt in bases} - ok
    final_pairs = [p for p in kept_pairs if p["pair"] in ok and p["base"] in ok]
    rejected += [{"pair": p["pair"], "why": "strict_invalid"} for p in kept_pairs if p not in final_pairs]
    used = {p["base"] for p in final_pairs} | {p["pair"] for p in final_pairs}
    rows = []
    for pid in sorted(used):
        bt = next(b for b in bases if pid.startswith(b["sid"] + "|"))
        spec = bt["spec"]
        dev = int(spec["seeds"]["sample"]) % 12 == 11  # whole episodes held out for dev loss
        text = json.dumps(targets[pid], ensure_ascii=False, separators=(",", ":"))
        pair = next((p for p in final_pairs if p["pair"] == pid), None)
        rows.append({"row_id": pid, "source": "contextual_s0_teacher_v0", "split": "dev" if dev else "train",
                     "prompt_id": pid, "target": text, "target_sha256": hashlib.sha256(text.encode()).hexdigest(),
                     "schema": "unalloc_v1", "episode_id": spec["episode_id"], "episode_spec_path": bt["spec_path"],
                     "episode_family": spec["family"], "episode_split": spec["split"], "map": spec["map"]["id"],
                     "factor": pair["factor"] if pair else "base", "kind": pair["kind"] if pair else "base",
                     "pair_base": pair["base"] if pair else None})
    OUT.mkdir(parents=True, exist_ok=True)
    with open(OUT / "sft_rows.jsonl", "w", encoding="utf-8") as f:
        for r in rows:
            f.write(json.dumps(r, ensure_ascii=False) + "\n")
    (OUT / "s0_prompts.json").write_text(json.dumps([{"prompt_id": k, "messages": prompts[k]["messages"]} for k in sorted(used)],
                                                    ensure_ascii=False), encoding="utf-8")
    from collections import Counter
    man = {"version": "CONTEXTUAL_BRAIN_S0_CORPUS_V0", "episodes": len(specs), "bases": len(bases),
           "bases_strict_invalid": sorted(bad_bases), "rows": len(rows),
           "train_rows": sum(r["split"] == "train" for r in rows), "dev_rows": sum(r["split"] == "dev" for r in rows),
           "pairs_kept": len(final_pairs), "pairs_by_factor": dict(Counter(p["factor"] for p in final_pairs)),
           "pairs_by_kind": dict(Counter(p["kind"] for p in final_pairs)),
           "rejected": dict(Counter(x["why"] for x in rejected)), "rejected_by_factor": dict(Counter(x["pair"].split("_")[1] for x in rejected)),
           "families": dict(Counter(r["episode_family"] for r in rows)), "maps": dict(Counter(r["map"] for r in rows)),
           "splits_used": sorted({r["episode_split"] for r in rows}),
           "doctrine_distinct": len({json.dumps(targets[p]["doctrine"]) for p in used}),
           "sft_rows_sha256": hashlib.sha256((OUT / "sft_rows.jsonl").read_bytes()).hexdigest(),
           "prompts_sha256": hashlib.sha256((OUT / "s0_prompts.json").read_bytes()).hexdigest()}
    (OUT / "CORPUS_MANIFEST.json").write_text(json.dumps(man, indent=1), encoding="utf-8")
    (OUT / "rejected_pairs.json").write_text(json.dumps(rejected, indent=1), encoding="utf-8")
    print(json.dumps(man, indent=1))


if __name__ == "__main__":
    main()
