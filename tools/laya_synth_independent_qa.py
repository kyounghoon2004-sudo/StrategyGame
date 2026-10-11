"""Independent QA for artifacts/laya_synthetic_v1 (read-only on the corpus).

A. Counterfactual same-state set: fresh scenarios (ids >= 9_000_000, disjoint
   from the corpus' SYN_0..) through the SAME generator + Godot extractor +
   score_candidate; each unit gets several commands over the SAME candidates.
B. Defect scan of the frozen val split (labels vs observation / semantics).
Writes artifacts/laya_hand_b_v1/qa/*.json.
"""
import json, math, os, random, subprocess, sys, collections, statistics as st
sys.path.insert(0, os.path.dirname(__file__))
import generate_laya_synthetic_dataset as G

ROOT = r"D:\Game development\Demon slayer\StrategyGame"
OUT = os.path.join(ROOT, "artifacts", "laya_hand_b_v1", "qa")
GODOT = r"C:\Users\kyoun\AppData\Local\Programs\Godot\Godot_v4.2.2-stable_win64_console.exe"
os.makedirs(OUT, exist_ok=True)


def accepted_for(task, area, u, hq_own, hq_en, enemies, seed):
    random.seed(seed)  # FLANK ANY draws randomness inside score_candidate
    is_r = u["unit_class"] == "ARCHER"
    sc = [{"type": "move", "q": c["q"], "r": c["r"], "score": G.score_candidate(task, area, c, u, None, is_r, hq_own, hq_en, enemies)} for c in u["reachable"]]
    for a in u["attacks"]:
        s = 100
        if is_r and G.hex_dist(u["q"], u["r"], a["defender_q"], a["defender_r"]) < 2 and task not in ["HOLD", "RESERVE"]:
            s -= 50
        sc.append({"type": "attack", "target": a["defender_id"], "score": s})
    if not sc:
        return []
    best = max(c["score"] for c in sc)
    return [c for c in sc if c["score"] >= best - 10]


def frame(hq_own, hq_en):
    x1, y1 = G.hex_to_pixel(*hq_own); x2, y2 = G.hex_to_pixel(*hq_en)
    f = G.normalize((x2 - x1, y2 - y1))
    return f, (-f[1], f[0])  # forward, left (generator's convention)


def disp(u, acc, f, l):
    ux, uy = G.hex_to_pixel(u["q"], u["r"])
    fw, lt, mag, att = [], [], [], 0
    for c in acc:
        if c["type"] != "move":
            att += 1
            continue
        cx, cy = G.hex_to_pixel(c["q"], c["r"])
        fw.append((cx - ux) * f[0] + (cy - uy) * f[1]); lt.append((cx - ux) * l[0] + (cy - uy) * l[1])
        mag.append(G.hex_dist(u["q"], u["r"], c["q"], c["r"]))
    m = lambda v: st.mean(v) if v else 0.0
    return {"fwd": m(fw), "left": m(lt), "hexes": m(mag), "attack_share": att / max(1, len(acc)), "n": len(acc)}


def counterfactual(n_scen=60):
    random.seed(20260928)
    scen = [G.generate_random_scenario(9_000_000 + i) for i in range(n_scen)]
    bi, bo = os.path.join(OUT, "cf_batch_in.json"), os.path.join(OUT, "cf_batch_out.json")
    json.dump(scen, open(bi, "w"))
    r = subprocess.run([GODOT, "--headless", "--path", ROOT, "-s", "tools/extract_candidates.gd", "--in", bi, "--out", bo], capture_output=True, text=True)
    res = json.load(open(bo, encoding="utf-8"))
    sd = {s["id"]: s["scenario"] for s in scen}
    PAIRS = [("ADVANCE", "FORWARD", "WITHDRAW", "BACK"), ("FLANK", "LEFT", "FLANK", "RIGHT"),
             ("FIX", "FORWARD", "RESERVE", "FORWARD"), ("ATTACK", "FORWARD", "HOLD", "FORWARD")]
    rows, agg = [], collections.defaultdict(lambda: collections.defaultdict(list))
    extra = collections.defaultdict(list)
    for item in res:
        scn = sd[item["id"]]
        hr = next(f for f in scn["forces"] if f["id"] == "R_HQ"); hb = next(f for f in scn["forces"] if f["id"] == "B_HQ")
        for side, data in item["sides"].items():
            own = (hr["q"], hr["r"]) if side == "red" else (hb["q"], hb["r"])
            en = (hb["q"], hb["r"]) if side == "red" else (hr["q"], hr["r"])
            enemies = [(f["q"], f["r"]) for f in scn["forces"] if f["faction"] != side]
            f, l = frame(own, en)
            vis = len(data["obs"]["ledger"].get("current_enemy_observations", []))
            for u in data["units"]:
                if u["unit_class"] == "HQ" or not u["reachable"]:
                    continue
                stay = any(c["q"] == u["q"] and c["r"] == u["r"] for c in u["reachable"])
                rec = {"scenario": scn["scenario_id"], "side": side, "unit": u["unit_id"], "class": u["unit_class"],
                       "n_cand": len(u["reachable"]) + len(u["attacks"]), "stay_candidate": stay, "visible_enemies": vis, "cmds": {}}
                for (t1, a1, t2, a2) in PAIRS:
                    for t, a in ((t1, a1), (t2, a2)):
                        k = f"{t}_{a}"
                        if k in rec["cmds"]:
                            continue
                        acc = accepted_for(t, a, u, own, en, enemies, 7)
                        d = disp(u, acc, f, l)
                        rec["cmds"][k] = {"accepted": acc, **d}
                        agg[k]["fwd"].append(d["fwd"]); agg[k]["left"].append(d["left"]); agg[k]["hexes"].append(d["hexes"]); agg[k]["attack_share"].append(d["attack_share"])
                # label determinism for FLANK ANY (same state, same command, two seeds)
                a1 = accepted_for("FLANK", "ANY", u, own, en, enemies, 1); a2 = accepted_for("FLANK", "ANY", u, own, en, enemies, 2)
                extra["flank_any_label_changes_with_seed"].append(json.dumps(a1, sort_keys=True) != json.dumps(a2, sort_keys=True))
                rc = accepted_for("RECON", "FORWARD", u, own, en, enemies, 7)
                extra["recon_accept_frac"].append(len([c for c in rc if c["type"] == "move"]) / max(1, len(u["reachable"])))
                rows.append(rec)
    summary = {k: {m: round(st.mean(v), 3) for m, v in d.items()} for k, d in agg.items()}
    checks = {
        "ADVANCE_FWD_gt_WITHDRAW_BACK_fwd": summary["ADVANCE_FORWARD"]["fwd"] > summary["WITHDRAW_BACK"]["fwd"],
        "WITHDRAW_moves_back(fwd<0)": summary["WITHDRAW_BACK"]["fwd"] < 0,
        "FLANK_LEFT_left_gt_FLANK_RIGHT_left": summary["FLANK_LEFT"]["left"] > summary["FLANK_RIGHT"]["left"],
        "FIX_moves_more_than_RESERVE": summary["FIX_FORWARD"]["hexes"] > summary["RESERVE_FORWARD"]["hexes"],
        "HOLD_stays_put(mean_hexes<0.5)": summary["HOLD_FORWARD"]["hexes"] < 0.5,
        "HOLD_does_not_attack_more_than_ATTACK": summary["HOLD_FORWARD"]["attack_share"] <= summary["ATTACK_FORWARD"]["attack_share"],
    }
    ex = {"flank_any_label_nondeterministic_frac": round(st.mean(extra["flank_any_label_changes_with_seed"]), 3),
          "recon_accepted_fraction_of_moves": round(st.mean(extra["recon_accept_frac"]), 3),
          "units_with_stay_in_place_candidate_frac": round(st.mean([r["stay_candidate"] for r in rows]), 3),
          "states_with_zero_visible_enemies_frac": round(st.mean([r["visible_enemies"] == 0 for r in rows]), 3)}
    with open(os.path.join(OUT, "counterfactual_eval_set.jsonl"), "w") as fo:
        for r in rows:
            fo.write(json.dumps(r) + "\n")
    return {"units": len(rows), "scenarios": n_scen, "per_command": summary, "checks": checks, "generator_defects": ex}


def val_scan(path, limit=20000):
    c = collections.Counter(); n = 0
    per = collections.defaultdict(collections.Counter)
    with open(path, encoding="utf-8") as f:
        for line in f:
            if n >= limit:
                break
            r = json.loads(line); n += 1
            t = r["command"]["task"]
            acc = r["accepted_actions"]; cand = r["candidates"]
            vis = len(r["observation"]["ledger"].get("current_enemy_observations", []))
            has_att = any(a["type"] == "attack" for a in acc)
            per[t]["rows"] += 1
            per[t]["accepts_attack"] += has_att
            per[t]["no_visible_enemy"] += (vis == 0)
            per[t]["all_moves_accepted"] += (len([a for a in acc if a["type"] == "move"]) == len([x for x in cand if "defender_id" not in x]) and len(acc) > 1)
            per[t]["hq_unit"] += r["unit"]["class"] == "HQ"
            c["area_" + r["command"]["area"]] += 1
    return {"rows_scanned": n, "per_task": {k: dict(v) for k, v in per.items()}, "areas_on_wire": dict(c)}


if __name__ == "__main__" and "--v2" not in sys.argv:
    cf = counterfactual()
    vs = val_scan(os.path.join(ROOT, "artifacts", "laya_synthetic_v1", "val_split.jsonl"))
    out = {"counterfactual": cf, "val_scan": vs}
    json.dump(out, open(os.path.join(OUT, "INDEPENDENT_QA.json"), "w"), indent=1)
    print(json.dumps(out, indent=1))


# ======================================================================
# v2 mode (Hand B corpus laya_synthetic_v2): same checks + leakage/parity.
#   python tools/laya_synth_independent_qa.py --v2
# ======================================================================
def _v2_imports():
    sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "hand_b"))
    import common as HC
    import gen_v2 as HG
    return HC, HG


def st_mean(v):
    v = [x for x in v if x is not None]
    return sum(v) / len(v) if v else 0.0


def counterfactual_v2(n_scen=80):
    HC, HG = _v2_imports()
    HG.OUT = os.path.join(ROOT, "artifacts", "laya_hand_b_v1", "qa_v2")
    os.makedirs(os.path.join(HG.OUT, "tmp"), exist_ok=True)
    rnd = random.Random(99)
    reqs, sid = [], 9_000_000
    while len(reqs) < 2 * n_scen:
        s = HG.scenario(sid, rnd); sid += 1
        if s:
            reqs.extend(s)
    # leakage twin: same scenario + one extra enemy next to its own (far) HQ
    twins = []
    for r in reqs:
        t = json.loads(json.dumps(r)); t["id"] = r["id"] + "_twin"
        foe = "blue" if r["side"] == "red" else "red"
        hq = next(f for f in t["scenario"]["forces"] if f["faction"] == foe and f["class"] == "hq")
        occ = {(f["q"], f["r"]) for f in t["scenario"]["forces"]}
        for dq, dr in [(1, 0), (0, 1), (-1, 1), (-1, 0), (0, -1), (1, -1)]:
            h = (hq["q"] + dq, hq["r"] + dr)
            if h not in occ:
                t["scenario"]["forces"].append({"id": ("B" if foe == "blue" else "R") + "_INF_99", "class": "infantry",
                                                "faction": foe, "q": h[0], "r": h[1], "soldiers": 300})
                break
        twins.append(t)
    res = HG.extract(reqs, "qa2") + HG.extract(twins, "qa2t")
    by = {s["id"]: s for s in res if "units" in s}
    PAIRS = [("ADVANCE", "FORWARD"), ("WITHDRAW", "BACK"), ("FLANK", "LEFT"), ("FLANK", "RIGHT"), ("FIX", "FORWARD"),
             ("RESERVE", "ANY"), ("ATTACK", "ANY"), ("HOLD", "ANY"), ("RECON", "FORWARD"), ("ADVANCE", "ANY")]
    agg = collections.defaultdict(lambda: collections.defaultdict(list))
    diff = collections.defaultdict(list)
    leak_changed, leak_n, parity_bad, ranged_geo = 0, 0, 0, []
    kinds = collections.Counter()
    rows = []
    jac = lambda a, b: len(set(a) & set(b)) / max(1, len(set(a) | set(b)))
    for r in reqs:
        st = by.get(r["id"]); tw = by.get(r["id"] + "_twin")
        if not st:
            continue
        for u in st["units"]:
            if len(u["candidates"]) < 2:
                continue
            ctx = HC.build_ctx(st, u["unit"])
            up = HC.pos(u["unit"])
            ids = {c["candidate_id"] for c in u["candidates"]}
            for c in u["candidates"]:
                kinds[c["action_type"]] += 1
            acc_by = {}
            for t, d in PAIRS:
                acc, _ = HC.accepted_ids(t, d, u["unit"], u["candidates"], ctx)
                parity_bad += sum(1 for a in acc if a not in ids)
                k = t + "_" + d
                acc_by[k] = acc
                cs = [c for c in u["candidates"] if c["candidate_id"] in acc]
                mv = [HC.rel(up, HC.cand_pos(c, u["unit"]), ctx["fr"]) for c in cs if c["action_type"] == "MOVE"]
                agg[k]["fwd"].append(st_mean([m[0] for m in mv]) if mv else 0.0)
                agg[k]["left"].append(st_mean([m[1] for m in mv]) if mv else 0.0)
                agg[k]["stationary_share"].append(sum(c["action_type"] in HC.STATIONARY for c in cs) / max(1, len(cs)))
                agg[k]["attack_share"].append(sum(c["action_type"] == "ATTACK" for c in cs) / max(1, len(cs)))
                agg[k]["hexes"].append(st_mean([HC.hdist(up, HC.cand_pos(c, u["unit"])) for c in cs]))
                if u["unit"]["class"] == "archer" and ctx["V"] and t in ("FIX", "ATTACK"):
                    good = []
                    for c in cs:
                        if c["action_type"] == "ATTACK":
                            good.append(1.0 if HC.dmin(up, ctx["V"]) >= 2 else 0.0)
                        else:
                            good.append(1.0 if 2 <= HC.dmin(HC.cand_pos(c, u["unit"]), ctx["V"]) <= 3 else 0.0)
                    ranged_geo.append(st_mean(good))
            # RESERVE split by situation (behind line & unthreatened -> must not churn;
            # ahead of line -> must move back).
            rs = [c for c in u["candidates"] if c["candidate_id"] in acc_by["RESERVE_ANY"]]
            d0 = HC.dmin(up, ctx["V"])
            behind = ctx["fwd_coord"](up) <= ctx["line"] - 0.5 and not (d0 is not None and d0 <= 2)
            if behind:
                agg["RESERVE_ANY"]["stationary_share_when_behind"].append(sum(c["action_type"] in HC.STATIONARY for c in rs) / max(1, len(rs)))
            else:
                mv2 = [HC.rel(up, HC.cand_pos(c, u["unit"]), ctx["fr"])[0] for c in rs if c["action_type"] == "MOVE"]
                if mv2:
                    agg["RESERVE_ANY"]["fwd_when_ahead_or_threatened"].append(st_mean(mv2))
            diff["ADVANCE_vs_WITHDRAW"].append(jac(acc_by["ADVANCE_FORWARD"], acc_by["WITHDRAW_BACK"]))
            diff["FLANK_L_vs_R"].append(jac(acc_by["FLANK_LEFT"], acc_by["FLANK_RIGHT"]))
            diff["FIX_vs_RESERVE"].append(jac(acc_by["FIX_FORWARD"], acc_by["RESERVE_ANY"]))
            diff["FIX_vs_ADVANCE"].append(jac(acc_by["FIX_FORWARD"], acc_by["ADVANCE_FORWARD"]))
            diff["ATTACK_vs_ADVANCE"].append(jac(acc_by["ATTACK_ANY"], acc_by["ADVANCE_ANY"]))
            if any(c["action_type"] == "ATTACK" for c in u["candidates"]):
                diff["ATTACK_vs_HOLD(legal)"].append(jac(acc_by["ATTACK_ANY"], acc_by["HOLD_ANY"]))
            if tw:
                tu = next((x for x in tw["units"] if x["unit"]["id"] == u["unit"]["id"]), None)
                if tu and [c["candidate_id"] for c in tu["candidates"]] == [c["candidate_id"] for c in u["candidates"]]:
                    tctx = HC.build_ctx(tw, tu["unit"])
                    for t, d in PAIRS:
                        leak_n += 1
                        leak_changed += HC.accepted_ids(t, d, tu["unit"], tu["candidates"], tctx)[0] != acc_by[t + "_" + d]
            rows.append({"scenario": r["scenario"]["scenario_id"], "side": r["side"], "stage": r["stage"],
                         "unit": u["unit"], "state_id": r["id"], "accepted": acc_by})
    summary = {k: {m: round(st_mean(v), 3) for m, v in d.items()} for k, d in agg.items()}
    dsum = {k: round(st_mean(v), 3) for k, v in diff.items()}
    checks = {
        "HOLD_no_churn(stationary_share>=0.9)": summary["HOLD_ANY"]["stationary_share"] >= 0.9,
        "RESERVE_no_churn_when_behind(>=0.9)": summary["RESERVE_ANY"]["stationary_share_when_behind"] >= 0.9,
        "RESERVE_falls_back_when_ahead(fwd<0)": summary["RESERVE_ANY"]["fwd_when_ahead_or_threatened"] < 0,
        "WITHDRAW_clearly_back(fwd<-0.8)": summary["WITHDRAW_BACK"]["fwd"] < -0.8,
        "ADVANCE_forward(fwd>0.8)": summary["ADVANCE_FORWARD"]["fwd"] > 0.8,
        "FLANK_mirror(L.left>0.5,R.left<-0.5)": summary["FLANK_LEFT"]["left"] > 0.5 and summary["FLANK_RIGHT"]["left"] < -0.5,
        "FIX!=ADVANCE(jaccard<0.7)": dsum["FIX_vs_ADVANCE"] < 0.7,
        "ATTACK!=ADVANCE(jaccard<0.7)": dsum["ATTACK_vs_ADVANCE"] < 0.7,
        "counterfactual_sets_differ(jaccard<0.3)": max(dsum["ADVANCE_vs_WITHDRAW"], dsum["FLANK_L_vs_R"], dsum["FIX_vs_RESERVE"]) < 0.3,
        "ATTACK_vs_HOLD_differ_when_legal(<0.2)": dsum.get("ATTACK_vs_HOLD(legal)", 1.0) < 0.2,
        "nonzero_attack_examples": summary["ATTACK_ANY"]["attack_share"] > 0,
        "ranged_firing_geometry(>=0.8)": bool(ranged_geo) and st_mean(ranged_geo) >= 0.8,
        "zero_hidden_state_leakage": leak_n > 0 and leak_changed == 0,
        "runtime_candidate_parity": parity_bad == 0 and set(kinds) <= {"MOVE", "WAIT", "REST", "FORTIFY", "ATTACK", "ASSAULT", "DISMANTLE", "ENTER_GARRISON"},
    }
    with open(os.path.join(HG.OUT, "counterfactual_eval_set_v2.jsonl"), "w") as fo:
        for r in rows:
            fo.write(json.dumps(r) + "\n")
    return {"units": len(rows), "per_command": summary, "jaccard": dsum, "ranged_geo_units": len(ranged_geo),
            "ranged_geo_score": round(st_mean(ranged_geo), 3), "leakage_tests": leak_n, "leakage_changed": leak_changed,
            "candidate_kinds": dict(kinds), "checks": checks}


def corpus_scan_v2():
    base = os.path.join(ROOT, "artifacts", "laya_synthetic_v2")
    c = collections.Counter(); fam_split = collections.defaultdict(set); tasks = collections.Counter()
    for sp in ("train", "val", "test"):
        p = os.path.join(base, sp + ".jsonl")
        if not os.path.exists(p):
            continue
        with open(p, encoding="utf-8") as f:
            for line in f:
                r = json.loads(line)
                c[sp] += 1; tasks[r["order"]["task"]] += 1
                c["hq_rows"] += r["unit"]["class"] == "hq"
                acc = set(r["accepted"])
                c["attack_accepted_rows"] += any(x["candidate_id"] in acc and x["action_type"] == "ATTACK" for x in r["candidates"])
                c["ranged_rows"] += r["unit"]["class"] == "archer"
                c["counterfactual_rows"] += r["family_kind"] != "PRIMARY"
                fam_split[r["family_id"]].add(sp)
                c["bad_accept"] += any(a not in {x["candidate_id"] for x in r["candidates"]} for a in r["accepted"])
                c["relative_direction_missing"] += "relative_direction" not in r["order"]
    c["families_crossing_splits"] = sum(1 for v in fam_split.values() if len(v) > 1)
    return {"counts": dict(c), "tasks": dict(tasks)}


if __name__ == "__main__" and "--v2" in sys.argv:
    cf = counterfactual_v2()
    cs = corpus_scan_v2() if "--no-corpus" not in sys.argv else {"counts": {}}
    cc = cs["counts"]
    ok = all(cf["checks"].values()) and ("--no-corpus" in sys.argv or (cc.get("hq_rows", 0) == 0 and cc.get("families_crossing_splits", 0) == 0
                                          and cc.get("bad_accept", 0) == 0 and cc.get("attack_accepted_rows", 0) > 0))
    out = {"verdict": "READY_FOR_TRAINING" if ok else "DATA_FIX_REQUIRED", "counterfactual": cf, "corpus": cs}
    os.makedirs(os.path.join(ROOT, "artifacts", "laya_hand_b_v1", "qa_v2"), exist_ok=True)
    json.dump(out, open(os.path.join(ROOT, "artifacts", "laya_hand_b_v1", "qa_v2", "INDEPENDENT_QA_V2.json"), "w"), indent=1)
    print(json.dumps(out, indent=1))
