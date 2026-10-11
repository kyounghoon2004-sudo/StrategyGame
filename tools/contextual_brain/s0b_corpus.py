"""CONTEXTUAL_BRAIN_S0B corpus (revised S0; same plumbing, new teacher + pair mix).

  python -m tools.contextual_brain.s0b_corpus

Changes vs S0 (see artifacts/contextual_brain_s0b/README.md):
* Teacher v2: decisions ONLY in structured fields (P1 FIX area = main effort, P1 FLANK prefer.classes = maneuver
  force, FIX/ATTACK vs = target). Prose carries no class names (only sectors / numbers). Target = visible class with
  the largest VISIBLE SOLDIERS x best current matchup edge; scouts are never a target unless nothing else is seen.
  Terrain: a sector is rough when its path to known contacts costs >= 3 MP more than the straight distance.
* Battles: per TRAIN episode 1 flat window + 2 catalog-terrain windows (both flat and terrain-heavy coverage).
* Pairs: up to 3 terrain (wall / mountain band / wall+flank), up to 3 visible-enemy recompositions, mobility,
  friendly composition, one combat/matchup, one control (alternating tiny-nudge / rear-terrain).
Sealed probes (tools/contextual_brain/s0b_sealed_probe.py) are built from a flat layout and VALIDATION maps that
this corpus never uses; overlap is checked at build time.
"""
from __future__ import annotations

import copy
import hashlib
import json
import os
import random
import statistics
from collections import Counter
from pathlib import Path

from tools.contract_sft import harness as H
from tools.contextual_brain.s0_corpus import catalog_terrain, region, render_spec, rk

ROOT = Path(r"D:\Game development\Demon slayer\StrategyGame")
OUT = ROOT / "artifacts" / "contextual_brain_s0b"
EPIS = ROOT / "artifacts" / "contextual_brain_s0" / "episodes"  # same 48 TRAIN-split specs
SECT3 = ["NORTH", "CENTER", "SOUTH"]
NOT_COMBAT = {"HQ", "SCOUT"}
ROUGH_EXTRA = 3.0


# ------------------------------------------------------------------ teacher v2
def teacher(packet, rng_seed):
    ctx, cs = packet["context"], packet["compact_state"]
    rules = ctx["rules"]["classes"]
    mu = {(a, d): m for a, d, m in ctx["rules"]["matchups"]}

    def match(a, d):
        return mu.get((a, d)) or (1 / mu[(d, a)] if (d, a) in mu else 1.0)

    fr = ctx["forces"]["friendly"]["by_class"]
    combat = sorted(c for c in fr if c not in NOT_COMBAT)
    mps = [rules[c]["mp"] for c in combat for _ in range(fr[c][0])]
    line_mp = statistics.median(mps) if mps else 1.0
    fast = max(combat, key=lambda c: (rules[c]["mp"], fr[c][0], c)) if combat else None
    maneuver = fast if fast and rules[fast]["mp"] >= line_mp + 1 else None
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
    tr = ctx["map"].get("travel_from_own_hq", {})
    by_sec = ctx["forces"]["formations_by_sector"]

    def leg(s):
        t = tr.get(f"NEAREST_ENEMY_{s}") or tr.get(s) or {}
        pc = t.get("path_cost_std_terrain")
        extra = (pc - t["hexes"]) if isinstance(pc, (int, float)) else 99.0
        return extra, t

    cands = [s for s in SECT3 if by_sec[s][1] > 0] or SECT3
    main = min(cands, key=lambda s: (leg(s)[0] >= ROUGH_EXTRA, -by_sec[s][1], leg(s)[0], s != "CENTER", s))
    flank = min([s for s in SECT3 if s != main], key=lambda s: (leg(s)[0] >= ROUGH_EXTRA, leg(s)[0], s == "CENTER", s))
    hq_sec = next((u.get("region") for u in cs["friendly_units"] if u["class"] == "HQ"), None) or "CENTER"
    tmain = leg(main)[1]
    turns = tmain.get("turns", {}).get(line_cls) if line_cls else None
    T = max(2, min(6, turns if isinstance(turns, int) else 4))
    foe = "BLUE" if packet["acting_side"] == "RED" else "RED"
    c_extra, c_leg = leg("CENTER")
    note = (f" CENTER route costs {c_leg['path_cost_std_terrain']:g} MP for {c_leg['hexes']} hexes."
            if main != "CENTER" and c_extra >= ROUGH_EXTRA and c_leg.get("hexes") else "")
    r = ctx["forces"].get("visible_soldier_ratio") or 1.0
    cl = lambda x: round(min(0.9, max(0.1, x)), 2)
    fast_mp = rules[fast]["mp"] if fast else line_mp
    doctrine = [cl(0.3 + 0.2 * min(r, 2.5)), cl(0.25 + 0.15 * min(r, 2.5)), cl(0.35 + 0.15 * (fast_mp - line_mp) + 0.025 * T),
                cl(0.35 + (0.2 if maneuver else 0.0)),
                cl(0.65 if (ctx["map"].get("nearest_visible_contact_hexes") or 99) <= 4 else 0.45), cl(0.3 if maneuver else 0.12)]
    rng = random.Random(rng_seed)
    names = [rng.choice(["SHAPE", "DEVELOP", "OPEN"]), rng.choice(["ENGAGE", "BREAK IN", "COMMIT"]), rng.choice(["DECIDE", "FINISH", "EXPLOIT"])]
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
    p1 = [dict(task="FIX", area=main, priority="high", **tv, intent=f"Pin the main visible concentration at {main}, {hx} hexes out.{note}"[:160],
               win=win_t, stop=[{"when": "FORCE_STRENGTH_BELOW", "fraction": 0.5}]),
          dict(man, priority="medium", **tv, win=win_t, stop=["HQ_THREATENED"]),
          dict(third, priority="low", win=win_t, stop=["HQ_THREATENED"])]
    p2 = [dict(task="ATTACK", area=main, priority="high", **tv, intent=f"Break the pinned line at {main}.",
               win=[{"when": "LOCAL_ADVANTAGE_HIGH", "region": main, "ratio": 1.5}], stop=[{"when": "FORCE_STRENGTH_BELOW", "fraction": 0.4}]),
          dict(man, priority="medium", **tv, intent=("Keep the flank attack moving" if maneuver else "Keep the wide front moving") + f" through {flank}.",
               win=win_t, stop=["HQ_THREATENED"]),
          dict(task="RESERVE", area=hq_sec, preserve=True, priority="medium", intent=f"Reserve at {hq_sec}: protect the HQ, exploit a breach.",
               win=win_t, stop=["HQ_THREATENED"])]
    p3 = [dict(task="ATTACK", area=main, vs="HQ", pursue=True, priority="high", intent=f"Drive on the {foe} HQ through {main}.",
               win=win_t, stop=[{"when": "FORCE_STRENGTH_BELOW", "fraction": 0.3}]),
          dict(task="ATTACK", area=flank, priority="medium", **tv, intent=f"Collapse the {flank} side of the {foe} line.", win=win_t, stop=["HQ_THREATENED"]),
          dict(task="HOLD", area=hq_sec, preserve=True, priority="medium", intent=f"Keep the HQ covered at {hq_sec}.", win=win_t, stop=["HQ_THREATENED"])]
    phases = []
    for i, (nm, ms) in enumerate(zip(names, (p1, p2, p3))):
        phases.append({"id": f"P{i + 1}", "name": f"{nm} {main}", "purpose": ["Fix and shape", "Break the line", "Win"][i] + f" at {main}.",
                       "intent": (man["intent"] if i == 0 else f"Main effort {main}; {flank} supports.")[:160], "missions": ms,
                       "win": win_t, "lose": [{"when": "FORCE_STRENGTH_BELOW", "fraction": 0.4}], "abort": ["HQ_THREATENED"],
                       "next": "END" if i == 2 else f"P{i + 2}", "on_fail": "HOLD"})
    plan = {"objective": f"Destroy the {foe} HQ: main effort {main}, " + ("fast flank via " if maneuver else "broad front via ") + f"{flank}, HQ covered.",
            "end_state": f"{foe} HQ destroyed; own HQ intact.", "cadence": max(2, min(5, T)), "doctrine": doctrine, "phases": phases,
            "abort": [{"when": "FORCE_STRENGTH_BELOW", "fraction": 0.25}],
            "hypotheses": [{"h": f"{foe}_MASS_{max(SECT3, key=lambda s: by_sec[s][1])}", "conf": 0.6,
                            "ev": [f"{sum(by_sec[s][1] for s in SECT3)} visible formations"]}]}
    return plan, {"maneuver": maneuver, "main": main, "flank": flank, "target": target}


def decisions(plan):
    """Structured decision fields (same extractor for teacher targets and model outputs)."""
    ms = plan["phases"][0]["missions"]
    fix = next((m for m in ms if m.get("task") == "FIX"), ms[0])
    fl = next((m for m in ms if m.get("task") == "FLANK"), None)
    return {"main": fix.get("area"), "maneuver": ((fl or {}).get("prefer") or {}).get("classes", [None])[0] if fl else None,
            "target": fix.get("vs")}


# ------------------------------------------------------------------ battles
def base_battle(spec_path, k, flat):
    spec = json.loads(Path(spec_path).read_text(encoding="utf-8"))
    rng = random.Random(f"s0b:{spec['episode_id']}:{k}")
    w, h = rng.choice([18, 20, 22, 24]), rng.choice([8, 9, 10, 12])
    cq, cr = rng.randint(-8, 8), rng.randint(-8, 8)
    b = {"q_min": cq - w, "q_max": cq + w, "r_min": cr - h, "r_max": cr + h}
    terr_all = {} if flat else catalog_terrain(spec["map"]["id"])
    terr = {(q, r): terr_all.get((q, r), 0) for q in range(b["q_min"], b["q_max"] + 1) for r in range(b["r_min"], b["r_max"] + 1)}
    gap = rng.choice([2, 2, 2, 3]) if flat else rng.choice([2, 2, 3, 4])
    side = "red" if rng.random() < 0.5 else "blue"
    rosters = {}
    for fac in ("red", "blue"):
        rows = [u for u in spec["armies"] if u["faction"] == fac and u["class"] != "hq"]
        rng.shuffle(rows)
        rows = rows[:rng.randint(6, 9)]
        rosters[fac] = ([("spearman" if u["class"] == "spear" else u["class"]) for u in rows], [u["count"] for u in rows])
    red_front = cq + gap // 2 + gap % 2
    return {"spec": spec, "spec_path": str(spec_path).replace("\\", "/"), "rng_seed": f"{spec['episode_id'][:12]}_{k}",
            "bounds": b, "terr": terr, "side": side, "rosters": rosters, "fronts": (red_front, red_front - gap),
            "hq_depth": rng.randint(5, 8), "rules": copy.deepcopy(spec["rules"]), "flat": flat}


def band(bt, sector):
    rf, bf = bt["fronts"]
    return [(q, r) for q in range(bf + 1, rf) for r in range(bt["bounds"]["r_min"], bt["bounds"]["r_max"] + 1)
            if region(q, r, bt["bounds"]) == sector]


def variants(bt, dec, pkt):
    own = bt["side"]
    foe = "blue" if own == "red" else "red"
    rules = bt["rules"]
    mine = [c for c in bt["rosters"][own][0] if c not in ("scout", "hq")]
    out = []
    if len(set(mine)) >= 2:  # mobility: fastest combat class becomes slowest, another becomes fastest
        fast = max(set(mine), key=lambda c: (rules["base_mp"][rk(c)], mine.count(c), c))
        other = max((c for c in set(mine) if c != fast), key=lambda c: (-mine.count(c), c))
        v = copy.deepcopy(bt)
        v["rules"]["base_mp"][rk(fast)] = 1.0
        v["rules"]["base_mp"][rk(other)] = min(5.0, max(float(rules["base_mp"][rk(c)]) for c in set(mine)) + 1.0)
        out.append(("movement", "fastest_rotated", v))
    if mine:  # friendly composition
        v = copy.deepcopy(bt)
        cls, cnt = v["rosters"][own]
        if dec["maneuver"]:
            gone = dec["maneuver"].lower()
            repl = max((c for c in set(mine) if c != gone), key=lambda c: (mine.count(c), c), default="infantry")
            v["rosters"][own] = ([repl if c == gone else c for c in cls], cnt)
        else:
            quick = max(("cavalry", "infantry", "spearman", "archer"), key=lambda c: (rules["base_mp"][rk(c)], c))
            v["rosters"][own] = ([quick if (c in mine and i % 3 == 0) else c for i, c in enumerate(cls)], cnt)
        out.append(("friendly_composition", "reclass", v))
    seen = [u for u in pkt["compact_state"]["known_enemy_units"] if u["contact_state"] == "current_visible"]
    if len(seen) >= 3:  # visible enemy composition: several recompositions (kept only if the target changes)
        for new in ("archer", "cavalry", "spearman", "infantry"):
            v = copy.deepcopy(bt)
            cls, cnt = v["rosters"][foe]
            v["rosters"][foe] = ([new if c not in ("hq", "scout") else c for c in cls], cnt)
            out.append(("enemy_composition", f"to_{new}", v))
        v = copy.deepcopy(bt)  # half-and-half recomposition
        cls, cnt = v["rosters"][foe]
        v["rosters"][foe] = ([("cavalry" if i % 2 else "archer") if c not in ("hq", "scout") else c for i, c in enumerate(cls)], cnt)
        out.append(("enemy_composition", "mixed_cav_arc", v))
    for kind, tiles in (("wall_main", {s: 8 for s in [dec["main"]]}), ("mountain_main", {s: 1 for s in [dec["main"]]}),
                        ("wall_main_flank", {dec["main"]: 8, dec["flank"]: 8})):
        v = copy.deepcopy(bt)
        for sec, t in tiles.items():
            for cell in band(v, sec):
                v["terr"][cell] = t
        if kind == "mountain_main":  # a mountain band needs depth to matter: extend 2 hexes onto each side's rear area
            rf, bf = bt["fronts"]
            for q in list(range(bf - 3, bf)) + list(range(rf + 1, rf + 4)):
                for r in range(bt["bounds"]["r_min"], bt["bounds"]["r_max"] + 1):
                    if region(q, r, bt["bounds"]) == dec["main"] and bt["bounds"]["q_min"] <= q <= bt["bounds"]["q_max"]:
                        v["terr"][(q, r)] = 1
        out.append(("terrain", kind, v))
    if dec["target"]:
        tk = rk(dec["target"].lower())
        v = copy.deepcopy(bt)
        v["rules"]["class_stats"][tk]["defense"] = min(25.0, float(rules["class_stats"][tk]["defense"]) * 3.0)
        out.append(("combat", "target_hardened", v))
    v = copy.deepcopy(bt)  # one control per base, alternating kind
    if int(hashlib.sha256(bt["rng_seed"].encode()).hexdigest(), 16) % 2:
        k0 = rk(max(set(mine), key=mine.count)) if mine else "infantry"
        v["rules"]["class_stats"][k0]["attack"] = float(rules["class_stats"][k0]["attack"]) + 0.25
        out.append(("control", "tiny_attack_nudge", v))
    else:
        b = bt["bounds"]
        qs = range(b["q_max"] - 2, b["q_max"] + 1) if own == "red" else range(b["q_min"], b["q_min"] + 3)
        for q in qs:
            for r in range(b["r_max"] - 2, b["r_max"] + 1):
                v["terr"][(q, r)] = 2
        out.append(("control", "rear_forest_patch", v))
    return out


FIELD = {"movement": "maneuver", "friendly_composition": "maneuver", "enemy_composition": "target", "terrain": "main",
         "combat": "target"}
CAP = {"enemy_composition": 3, "terrain": 3}


def main():
    os.environ["BRAIN_CONTRACT_MODE"] = "unalloc_v1"
    os.environ["BRAIN_CONTEXT_PACK"] = "v0"
    specs = sorted(EPIS.glob("*.json"))
    bases = [base_battle(p, k, flat=(k == 0)) for p in specs for k in range(3)]
    for i, bt in enumerate(bases):
        bt["sid"] = f"s0bb{i:03d}"
    rendered = H.build_prompts([render_spec(bt, bt["sid"]) for bt in bases])
    prompts, var_specs = {}, []
    for bt, r in zip(bases, rendered):
        assert "error" not in r, r
        pkt = json.loads(r["messages"][1]["content"])
        bt["plan"], bt["dec"] = teacher(pkt, bt["rng_seed"])
        bt["pid"] = f"{bt['sid']}|base"
        prompts[bt["pid"]] = {"messages": r["messages"], "spec": render_spec(bt, bt["sid"])}
        for j, (factor, kind, v) in enumerate(variants(bt, bt["dec"], pkt)):
            var_specs.append((bt, factor, kind, v, f"{bt['sid']}|v{j}_{factor}_{kind}"))
    rv = H.build_prompts([render_spec(v, bt["sid"]) for bt, _, _, v, _ in var_specs])
    kept, rejected = [], []
    per_base = Counter()
    for (bt, factor, kind, v, pid), r in zip(var_specs, rv):
        if "error" in r or r["messages"] == prompts[bt["pid"]]["messages"]:
            rejected.append({"pair": pid, "why": "render_error_or_identical"})
            continue
        pkt = json.loads(r["messages"][1]["content"])
        plan, dec = teacher(pkt, bt["rng_seed"])
        if factor == "control":
            ok = plan == bt["plan"]
        else:
            ok = dec[FIELD[factor]] != bt["dec"][FIELD[factor]]
        if not ok:
            rejected.append({"pair": pid, "why": "control_changed_plan" if factor == "control" else "decision_unchanged"})
            continue
        if per_base[(bt["sid"], factor)] >= CAP.get(factor, 1):
            rejected.append({"pair": pid, "why": "cap"})
            continue
        per_base[(bt["sid"], factor)] += 1
        prompts[pid] = {"messages": r["messages"], "spec": render_spec(v, bt["sid"])}
        kept.append({"pair": pid, "base": bt["pid"], "factor": factor, "kind": kind, "bt": bt, "plan": plan, "dec": dec})
    targets = {bt["pid"]: bt["plan"] for bt in bases}
    targets.update({p["pair"]: p["plan"] for p in kept})
    val = H.validate([{"id": k, "text": json.dumps(t, ensure_ascii=False, separators=(",", ":")), "scenario": prompts[k]["spec"]}
                      for k, t in targets.items()])
    good = {x["id"] for x in val if x["strict_first_pass"]}
    final = [p for p in kept if p["pair"] in good and p["base"] in good]
    rejected += [{"pair": p["pair"], "why": "strict_invalid"} for p in kept if p not in final]
    used = sorted({p["base"] for p in final} | {p["pair"] for p in final})
    rows = []
    for pid in used:
        bt = next(b for b in bases if pid.startswith(b["sid"] + "|"))
        spec = bt["spec"]
        pair = next((p for p in final if p["pair"] == pid), None)
        text = json.dumps(targets[pid], ensure_ascii=False, separators=(",", ":"))
        rows.append({"row_id": pid, "source": "contextual_s0b_teacher_v2", "prompt_id": pid, "target": text,
                     "split": "dev" if int(spec["seeds"]["sample"]) % 12 == 11 else "train",
                     "target_sha256": hashlib.sha256(text.encode()).hexdigest(), "schema": "unalloc_v1",
                     "episode_id": spec["episode_id"], "episode_spec_path": bt["spec_path"], "episode_family": spec["family"],
                     "episode_split": spec["split"], "map": spec["map"]["id"], "terrain": "flat" if bt["flat"] else "catalog_window",
                     "factor": pair["factor"] if pair else "base", "kind": pair["kind"] if pair else "base",
                     "pair_base": pair["base"] if pair else None, "decisions": decisions(targets[pid])})
    OUT.mkdir(parents=True, exist_ok=True)
    with open(OUT / "sft_rows.jsonl", "w", encoding="utf-8") as f:
        for r in rows:
            f.write(json.dumps(r, ensure_ascii=False) + "\n")
    (OUT / "s0b_prompts.json").write_text(json.dumps([{"prompt_id": k, "messages": prompts[k]["messages"]} for k in used],
                                                     ensure_ascii=False), encoding="utf-8")
    man = {"version": "CONTEXTUAL_BRAIN_S0B_CORPUS_V0", "episodes": len(specs), "bases": len(bases),
           "bases_flat": sum(b["flat"] for b in bases), "rows": len(rows),
           "train_rows": sum(r["split"] == "train" for r in rows), "dev_rows": sum(r["split"] == "dev" for r in rows),
           "pairs_kept": len(final), "pairs_by_factor": dict(Counter(p["factor"] for p in final)),
           "pairs_by_kind": dict(Counter(p["kind"] for p in final)),
           "pairs_by_factor_and_terrain": dict(Counter(f"{p['factor']}|{'flat' if p['bt']['flat'] else 'terrain'}" for p in final)),
           "rejected": dict(Counter(x["why"] for x in rejected)),
           "target_distribution": dict(Counter(r["decisions"]["target"] for r in rows)),
           "maneuver_distribution": dict(Counter(r["decisions"]["maneuver"] for r in rows)),
           "main_distribution": dict(Counter(r["decisions"]["main"] for r in rows)),
           "splits_used": sorted({r["episode_split"] for r in rows}),
           "doctrine_distinct": len({json.dumps(targets[p]["doctrine"]) for p in used}),
           "sft_rows_sha256": hashlib.sha256((OUT / "sft_rows.jsonl").read_bytes()).hexdigest(),
           "prompts_sha256": hashlib.sha256((OUT / "s0b_prompts.json").read_bytes()).hexdigest()}
    (OUT / "CORPUS_MANIFEST.json").write_text(json.dumps(man, indent=1), encoding="utf-8")
    (OUT / "rejected_pairs.json").write_text(json.dumps(rejected, indent=1), encoding="utf-8")
    print(json.dumps(man, indent=1))


if __name__ == "__main__":
    main()
