"""HAND B corpus v2 generator.

  python tools/hand_b/gen_v2.py --scenarios N --workers W [--start ID]

Scenarios: opening (25%) and MID-BATTLE (75%: fronts 1-6 hexes apart,
damaged units, terrain, later turns, 35% with enemy repositions -> last-known
contacts). Candidates: runtime LayaEnumerator via extract_candidates_v2.gd.
Rows: one balanced primary order per unit + same-state counterfactual
families (ADVANCE/WITHDRAW, FLANK L/R, FIX/RESERVE, ATTACK/HOLD when legal).
Split by scenario (train/val/test = 90/5/5 by stable hash), so every family
stays in one partition. HQ units never produce rows.
"""
import argparse, hashlib, json, math, os, random, subprocess, sys
from concurrent.futures import ThreadPoolExecutor

sys.path.insert(0, os.path.dirname(__file__))
import common as C

ROOT = r"D:\Game development\Demon slayer\StrategyGame"
OUT = os.path.join(ROOT, "artifacts", "laya_synthetic_v2")
GODOT = r"C:\Users\kyoun\AppData\Local\Programs\Godot\Godot_v4.2.2-stable_win64_console.exe"
CLASSES = ["infantry", "cavalry", "archer", "spearman", "scout"]
CLASS_W = [3, 2, 2, 2, 1]
BOUNDS = {"q_min": -20, "q_max": 20, "r_min": -15, "r_max": 15}


def to_hex(x, y):
    q = (math.sqrt(3) / 3 * x - 1.0 / 3 * y)
    r = 2.0 / 3 * y
    # cube rounding
    s = -q - r
    rq, rr, rs = round(q), round(r), round(s)
    dq, dr, ds = abs(rq - q), abs(rr - r), abs(rs - s)
    if dq > dr and dq > ds:
        rq = -rr - rs
    elif dr > ds:
        rr = -rq - rs
    return int(rq), int(rr)


def inb(h):
    return BOUNDS["q_min"] + 1 <= h[0] <= BOUNDS["q_max"] - 1 and BOUNDS["r_min"] + 1 <= h[1] <= BOUNDS["r_max"] - 1


def scenario(sid, rnd):
    ang = rnd.uniform(0, 2 * math.pi)
    dist = rnd.uniform(10, 14)
    f = (math.cos(ang), math.sin(ang))
    l = (f[1], -f[0])
    hq_red = to_hex(-f[0] * dist * math.sqrt(3), -f[1] * dist * math.sqrt(3))
    hq_blue = to_hex(f[0] * dist * math.sqrt(3), f[1] * dist * math.sqrt(3))
    if not inb(hq_red) or not inb(hq_blue):
        return None
    stage = "opening" if rnd.random() < 0.25 else "mid"
    used = {hq_red, hq_blue}
    forces = [{"id": "R_HQ_1", "class": "hq", "faction": "red", "q": hq_red[0], "r": hq_red[1], "soldiers": 300},
              {"id": "B_HQ_1", "class": "hq", "faction": "blue", "q": hq_blue[0], "r": hq_blue[1], "soldiers": 300}]
    sep = rnd.choice([1, 1, 1, 2, 2, 2, 3, 4]) if stage == "mid" else None
    slots = [rnd.uniform(-5, 5) for _ in range(8)]
    engaged = stage == "mid" and rnd.random() < 0.45
    counters = {}
    for side, sgn, hq in (("red", -1, hq_red), ("blue", 1, hq_blue)):
        n = rnd.randint(4, 8)
        for _ in range(n):
            for _try in range(20):
                if stage == "opening":
                    h = (hq[0] + rnd.randint(-5, 5), hq[1] + rnd.randint(-5, 5))
                else:
                    if engaged and _try < 10:
                        depth = 0.55
                        lat = slots[len([x for x in forces if x["faction"] == side and x["class"] != "hq"]) % len(slots)]
                    else:
                        depth = sep / 2.0 + rnd.choice([0, 0, 0, 0, 0, 1, 2])
                        lat = rnd.choice(slots) + rnd.uniform(-1.0, 1.0)
                    x = (sgn * depth * f[0] + lat * l[0]) * math.sqrt(3)
                    y = (sgn * depth * f[1] + lat * l[1]) * math.sqrt(3)
                    h = to_hex(x, y)
                if h not in used and inb(h):
                    used.add(h)
                    cls = rnd.choices(CLASSES, CLASS_W)[0]
                    counters[(side, cls)] = counters.get((side, cls), 0) + 1
                    mx = rnd.randint(200, 500)
                    sold = mx if stage == "opening" else max(20, int(mx * rnd.uniform(0.15, 1.0)))
                    forces.append({"id": "%s_%s_%d" % ("R" if side == "red" else "B", cls[:3].upper(), counters[(side, cls)]),
                                   "class": cls, "faction": side, "q": h[0], "r": h[1], "soldiers": sold})
                    break
    terr = {}
    if stage == "mid" or rnd.random() < 0.5:
        for _ in range(rnd.randint(10, 60)):
            h = (rnd.randint(BOUNDS["q_min"], BOUNDS["q_max"]), rnd.randint(BOUNDS["r_min"], BOUNDS["r_max"]))
            if h not in used:
                terr["%d,%d" % h] = rnd.choices([2, 1, 3, 8, 6, 5], [5, 2, 2, 1, 2, 1])[0]
    scn = {"scenario_id": "HB2_%d" % sid, "scenario_version": "1.0.0", "seed": sid,
           "mission_contract": {"primary_objective": "destroy_all_red", "turn_limit": 100},
           "map": {"bounds": BOUNDS, "default_terrain": 0, "terrain_overrides": terr, "river_cells": []},
           "forces": forces, "start_turn": 1 if stage == "opening" else rnd.randint(2, 20)}
    reqs = []
    for side in ("red", "blue"):
        pre = []
        if stage == "mid" and rnd.random() < 0.35:
            sg = 1 if side == "red" else -1  # enemy retreats toward its own HQ
            foes = [x for x in forces if x["faction"] != side and x["class"] != "hq"]
            for e in rnd.sample(foes, min(len(foes), rnd.randint(1, 2))):
                back = rnd.randint(2, 3)
                h = to_hex((e["q"] * math.sqrt(3) + e["r"] * math.sqrt(3) / 2) + sg * back * f[0] * math.sqrt(3),
                           1.5 * e["r"] + sg * back * f[1] * math.sqrt(3))
                pre.append({"unit_id": e["id"], "q": h[0], "r": h[1]})
        reqs.append({"id": "%d_%s" % (sid, side), "scenario": scn, "side": side, "pre_moves": pre, "stage": stage})
    return reqs


def extract(batch, tag):
    bi = os.path.join(OUT, "tmp", "in_%s.json" % tag)
    bo = os.path.join(OUT, "tmp", "out_%s.json" % tag)
    json.dump(batch, open(bi, "w", encoding="utf-8"))
    subprocess.run([GODOT, "--headless", "--path", ROOT, "-s", "res://tools/hand_b/extract_candidates_v2.gd", "--", "--in", bi, "--out", bo],
                   capture_output=True, text=True)
    try:
        return json.load(open(bo, encoding="utf-8"))
    except Exception:
        return []


def split_of(scenario_id):
    h = int(hashlib.sha256(scenario_id.encode()).hexdigest()[:8], 16) % 100
    return "train" if h < 90 else ("val" if h < 95 else "test")


def order(task, rdir, rnd):
    if task == "EXECUTE":
        txt, bt, bd = rnd.choice(C.EXECUTE_INTENTS)
        return {"task": "EXECUTE", "relative_direction": "ANY", "intent": txt, "behaviour_task": bt, "behaviour_dir": bd}
    return {"task": task, "relative_direction": rdir, "intent": C.TASK_INTENTS[task]}


def make_row(state, u, o, family, fam_kind, stage, scen_id):
    ctx = C.build_ctx(state, u["unit"])
    bt, bd = C.behaviour(o)
    acc, sc = C.accepted_ids(bt, bd, u["unit"], u["candidates"], ctx)
    if not acc:
        return None
    cands = [{"candidate_id": c["candidate_id"], "action_type": c["action_type"], "option_text": c.get("option_text", ""),
              "destination": c.get("destination"), "target_id": c.get("target_id"), "target_q": c.get("target_q"),
              "target_r": c.get("target_r"), "target_class": c.get("target_class"), "terrain": c.get("terrain"),
              "matchup_mult": c.get("matchup_mult")} for c in u["candidates"]]
    return {"scenario_id": scen_id, "stage": stage, "side": state["side"], "turn": state["turn"], "bounds": state["bounds"],
            "family_id": family, "family_kind": fam_kind, "order": o, "unit": u["unit"],
            "ledger": {k: state["ledger"].get(k) for k in ("own_forces", "observed_blue_forces", "current_enemy_observations",
                                                           "last_known_blue_contacts", "last_known_enemy_contacts") if k in state["ledger"]},
            "candidates": cands, "accepted": acc}


FAMILIES = [("ADV_WDR", [("ADVANCE", "FORWARD"), ("WITHDRAW", "BACK")]),
            ("FLANK_LR", [("FLANK", "LEFT"), ("FLANK", "RIGHT")]),
            ("FIX_RES", [("FIX", "FORWARD"), ("RESERVE", "ANY")]),
            ("ATK_HOLD", [("ATTACK", "ANY"), ("HOLD", "ANY")])]


def rows_for(state, req, rnd, task_cycle):
    out = []
    scen_id = req["scenario"]["scenario_id"]
    for ui, u in enumerate(state.get("units", [])):
        if len(u["candidates"]) < 2:
            continue
        base = "%s|%s|%s" % (scen_id, state["side"], u["unit"]["id"])
        task = task_cycle[(hash(base) & 0xffff) % len(task_cycle)] if False else rnd.choice(C.TASKS)
        rdir = rnd.choice(C.ALLOWED_DIRS.get(task, ["ANY"]))
        r = make_row(state, u, order(task, rdir, rnd), base + "|P", "PRIMARY", req["stage"], scen_id)
        if r:
            out.append(r)
        if rnd.random() < 0.55:
            has_atk = any(c["action_type"] == "ATTACK" for c in u["candidates"])
            fams = [f for f in FAMILIES if f[0] != "ATK_HOLD" or has_atk]
            if has_atk and rnd.random() < 0.5:
                fams = [f for f in FAMILIES if f[0] == "ATK_HOLD"]
            kind, pair = rnd.choice(fams)
            fr = [make_row(state, u, order(t, d, rnd), base + "|" + kind, kind, req["stage"], scen_id) for t, d in pair]
            if all(fr):
                out.extend(fr)
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--scenarios", type=int, default=100)
    ap.add_argument("--workers", type=int, default=4)
    ap.add_argument("--start", type=int, default=0)
    ap.add_argument("--batch", type=int, default=40)
    ap.add_argument("--target_rows", type=int, default=0)
    a = ap.parse_args()
    os.makedirs(os.path.join(OUT, "tmp"), exist_ok=True)
    rnd = random.Random(20260928 + a.start)
    reqs, sid = [], a.start
    while len(reqs) < 2 * a.scenarios:
        s = scenario(sid, rnd)
        sid += 1
        if s:
            reqs.extend(s)
    batches = [reqs[i:i + a.batch] for i in range(0, len(reqs), a.batch)]
    files = {k: open(os.path.join(OUT, "%s.jsonl" % k), "a", encoding="utf-8") for k in ("train", "val", "test")}
    n = {"train": 0, "val": 0, "test": 0}
    by_id = {r["id"]: r for r in reqs}
    with ThreadPoolExecutor(a.workers) as ex:
        for bi, res in enumerate(ex.map(lambda ib: extract(ib[1], "%d_%d" % (a.start, ib[0])), enumerate(batches))):
            for state in res:
                if "units" not in state:
                    continue
                req = by_id[state["id"]]
                for row in rows_for(state, req, rnd, None):
                    sp = split_of(row["scenario_id"])
                    files[sp].write(json.dumps(row) + "\n")
                    n[sp] += 1
            print("batch %d/%d rows=%s" % (bi + 1, len(batches), n), flush=True)
            if a.target_rows and sum(n.values()) >= a.target_rows:
                break
    for f in files.values():
        f.close()
    print("DONE", n)


if __name__ == "__main__":
    main()
