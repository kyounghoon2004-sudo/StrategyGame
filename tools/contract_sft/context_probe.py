"""CONTEXTUAL BRAIN V0 — counterfactual context-sensitivity probes (CSFT5 = probe only).

  python -m tools.contract_sft.context_probe build     # specs + prompts (Godot) + jobs
  <RL venv> -m tools.contract_sft.generate --adapter <CSFT5> --label CSFT5_ctxprobe \
      --jobs <OUT>/jobs.json --out <OUT>/gen_CSFT5.json --batch-size 12
  python -m tools.contract_sft.context_probe analyze   # Godot strict validation + sensitivity

Each probe = two specs that differ in ONE factor (rules / friendly roster /
visible enemy roster / terrain / game mode), plus controls whose change is
irrelevant (tiny stat nudge, rear-corner terrain) or absent (same prompt,
resampled). Arms: CTX = production prompt + context pack (BRAIN_CONTEXT_PACK=v0);
PROD = today's production prompt. Rule/terrain-only probes whose PROD prompts
are byte-identical are reported as BLIND (no generation needed: the model
cannot respond to what it is not shown). Nothing here trains anything.
"""
from __future__ import annotations

import json
import os
import random
import re
import sys
from collections import Counter
from pathlib import Path

from tools.contract_sft import harness as H

OUT = Path(r"D:\Game development\Demon slayer\StrategyGame\artifacts\contextual_brain_pipeline_v0\probe")
N = 8  # samples per (arm, variant)
BOUNDS = {"q_min": -22, "q_max": 22, "r_min": -10, "r_max": 10}
TAG = {"infantry": "INF", "archer": "ARC", "cavalry": "CAV", "spearman": "SPE", "scout": "SCT", "hq": "HQ"}
SOL = {"infantry": 420, "archer": 240, "cavalry": 300, "spearman": 380, "scout": 90, "hq": 300}
# Fixed deployment slots (r values); fronts 2 hexes apart -> all 9 enemy front units visible.
SLOTS = [-8, -6, -4, -2, 0, 2, 4, 6, 8]
BASE_RED = ["cavalry", "infantry", "spearman", "archer", "scout", "archer", "spearman", "infantry", "cavalry"]
BASE_BLUE = ["cavalry", "infantry", "spearman", "archer", "scout", "archer", "spearman", "infantry", "cavalry"]


def army(prefix, faction, classes, front_q, hq_q):
    seen, units = Counter(), []
    for r, cls in zip(SLOTS, classes):
        seen[cls] += 1
        units.append({"id": f"{prefix}_{TAG[cls]}_{seen[cls]}", "class": cls, "faction": faction,
                      "q": front_q, "r": r, "soldiers": SOL[cls]})
    units.append({"id": f"{prefix}_HQ_1", "class": "hq", "faction": faction, "q": hq_q, "r": 0, "soldiers": 300})
    return sorted(units, key=lambda u: u["id"])


def spec(pid, red=BASE_RED, blue=BASE_BLUE, side="red", **kw):
    s = {"scenario_id": f"ctxprobe_{pid}", "side": side, "seed": 29,
         "red_forces": army("R", "red", red, 1, 7), "blue_forces": army("B", "blue", blue, -1, -8),
         "primary_objective": "destroy_all_red", "turn_limit": 12, "bounds": dict(BOUNDS),
         # Always install an episode (base rules + deltas): installing one changes the
         # obs mission framing, so both variants must carry one.
         "rule_deltas": {}}
    s.update(kw)
    return s


def center_wall():
    """Impassable wall between the fronts (q=0) across the whole CENTER band; flanks open."""
    return {f"0,{r}": 8 for r in range(-10, 11) if abs(2 * r) <= 14}


def rear_patch():
    return {f"{q},{r}": 2 for q in range(19, 23) for r in range(7, 11)}


# probe id -> (factor, expectation, variant A kwargs, variant B kwargs)
PROBES = {
    "RULES_MOBILITY": ("rules", "cavalry slowest / infantry-line fastest -> maneuver roles should stop leaning on cavalry",
                       {}, {"rule_deltas": {"base_mp": {"cavalry": 1.0, "infantry": 3.0, "spear": 3.0, "archer": 3.0}}}),
    "RULES_COMBAT": ("rules", "archers lose range/attack, spear no longer counters cavalry -> targeting/caution should shift",
                     {}, {"rule_deltas": {"class_stats": {"archer": {"range": 1, "attack": 6.0}},
                                          "matchup": {"spear_vs_cavalry": 0.7}}}),
    "ROSTER_FRIENDLY": ("roster", "cavalry-heavy vs no-cavalry friendly army -> task mix should change",
                        {"red": ["cavalry", "cavalry", "cavalry", "archer", "scout", "archer", "infantry", "cavalry", "cavalry"]},
                        {"red": ["spearman", "infantry", "spearman", "archer", "scout", "archer", "spearman", "infantry", "infantry"]}),
    "ENEMY_VISIBLE": ("enemy", "visible enemy archer-heavy vs cavalry-heavy -> vs targets / threat handling should change",
                      {"blue": ["archer", "infantry", "archer", "archer", "scout", "archer", "spearman", "infantry", "archer"]},
                      {"blue": ["cavalry", "infantry", "cavalry", "cavalry", "scout", "cavalry", "spearman", "infantry", "cavalry"]}),
    "MAP_CENTER_WALL": ("map", "impassable CENTER wall, open flanks -> areas should move off CENTER",
                        {}, {"terrain_overrides": center_wall()}),
    "MODE_HOLD": ("mode", "BLUE: annihilate RED vs keep HQ alive to turn 8 -> plan should turn defensive",
                  {"side": "blue"}, {"side": "blue", "primary_objective": "hold_hq", "turn_limit": 8}),
    "CTRL_NOISE": ("control", "identical prompt resampled -> no systematic difference", {}, {}),
    "CTRL_TINY_RULE": ("control", "+0.5 attack/defense nudges -> no plan churn",
                       {}, {"rule_deltas": {"class_stats": {"infantry": {"attack": 10.5, "defense": 10.5},
                                                            "archer": {"attack": 12.5}}}}),
    "CTRL_REAR_TERRAIN": ("control", "forest patch in the far rear corner -> no plan churn",
                          {}, {"terrain_overrides": rear_patch()}),
}


def _prompts(specs, ctx: bool):
    os.environ["BRAIN_CONTRACT_MODE"] = "unalloc_v1"
    os.environ.pop("BRAIN_CONTEXT_PACK", None)
    if ctx:
        os.environ["BRAIN_CONTEXT_PACK"] = "v0"
    try:
        return H.build_prompts(specs)
    finally:
        os.environ.pop("BRAIN_CONTEXT_PACK", None)


def _unhashed(messages):
    return [re.sub(r"step1_[A-Za-z0-9_]+_v\d+_[0-9a-f]{12}", "<SNAPSHOT>", m["content"]) for m in messages]


def build() -> int:
    OUT.mkdir(parents=True, exist_ok=True)
    specs = []
    for pid, (_, _, a, b) in PROBES.items():
        # Same scenario_id for both variants: the id must not leak the manipulation.
        specs.append(dict(spec(pid, **a), probe=pid, variant="A"))
        specs.append(dict(spec(pid, **b), probe=pid, variant="B"))
    ctx = _prompts(specs, True)
    prod = _prompts(specs, False)
    prompts, jobs, identity = {}, [], {}
    for s, c, p in zip(specs, ctx, prod):
        assert "error" not in c and "error" not in p, (c, p)
        assert "context" in json.loads(c["messages"][1]["content"]), "CTX prompt lacks the context pack"
        assert "context" not in json.loads(p["messages"][1]["content"]), "PROD prompt carries the context pack"
        for arm, r in (("CTX", c), ("PROD", p)):
            prompts[f"{s['probe']}|{arm}|{s['variant']}"] = {"spec": s, "messages": r["messages"],
                                                           "n_known_enemies": r["n_known_enemies"], "roster": r["roster"]}
    for pid, (factor, _, _, _) in PROBES.items():
        # Semantic identity: ignore the snapshot hash (it fingerprints hidden mp/rules).
        same = {arm: _unhashed(prompts[f"{pid}|{arm}|A"]["messages"]) == _unhashed(prompts[f"{pid}|{arm}|B"]["messages"])
                for arm in ("CTX", "PROD")}
        identity[pid] = same
        arms = ["CTX"] if (same["PROD"] or factor == "control") else ["CTX", "PROD"]
        for arm in arms:
            for v in ("A", "B"):
                for k in range(N):
                    jobs.append({"job_id": f"{pid}|{arm}|{v}|{k}", "prompt_id": f"{pid}|{arm}|{v}",
                                 "messages": prompts[f"{pid}|{arm}|{v}"]["messages"], "seed": 7000 + k})
    random.Random(11).shuffle(jobs)  # mix probes inside batches; per-batch seed = first job's
    (OUT / "prompts.json").write_text(json.dumps(prompts, ensure_ascii=False, indent=1), encoding="utf-8")
    (OUT / "jobs.json").write_text(json.dumps(jobs, ensure_ascii=False), encoding="utf-8")
    (OUT / "prompt_identity.json").write_text(json.dumps(identity, indent=1), encoding="utf-8")
    sizes = {k: [len(m["content"]) for m in v["messages"]] for k, v in prompts.items() if k.endswith("|A")}
    print(json.dumps({"jobs": len(jobs), "identity_A_eq_B": identity, "chars_sys_user": sizes,
                      "known_enemies": {k: v["n_known_enemies"] for k, v in prompts.items()}}, indent=1))
    return 0


# ---------------------------------------------------------------- analysis
TASKS = ["HOLD", "ADVANCE", "FIX", "ATTACK", "FLANK", "RECON", "RESERVE", "WITHDRAW", "EXECUTE"]
AREAS = ["NORTH", "CENTER", "SOUTH", "WEST", "EAST", "ANY"]
CLASSES = ["INFANTRY", "ARCHER", "CAVALRY", "SPEAR", "SCOUT", "HQ"]
CLASS_RE = {c: re.compile(p, re.I) for c, p in {"INFANTRY": r"\binf(antry)?\b", "ARCHER": r"\barch(er|ers)?\b|ranged",
            "CAVALRY": r"\bcav(alry)?\b|horse", "SPEAR": r"\bspear(man|men|s)?\b|pike",
            "SCOUT": r"\bscouts?\b", "HQ": r"\bhq\b|headquarter"}.items()}
KW = {"defend": r"defen|hold|protect|surviv|guard|preserve", "attack": r"attack|destroy|strike|assault|kill|break",
      "maneuver": r"flank|envelop|maneuver|manoeuv|wheel|outflank|bypass", "hq": r"\bhq\b"}


def _doc(text):
    try:
        d = json.loads(text.strip())
        return d if isinstance(d, dict) else None
    except ValueError:
        return None


def _texts(m):
    out = [str(m.get(k, "")) for k in ("intent", "tag")]
    for k in ("effects", "limits"):
        out += [str(x) for x in (m.get(k) or []) if isinstance(x, str)]
    pref = m.get("prefer") if isinstance(m.get("prefer"), dict) else {}
    out += [str(x) for x in (pref.get("classes") or [])]
    return " ".join(out)


def features(doc):
    ms = [m for p in doc.get("phases") or [] if isinstance(p, dict) for m in p.get("missions") or [] if isinstance(m, dict)]
    n = max(1, len(ms))
    f = {}
    tc = Counter(str(m.get("task", "EXECUTE")).upper() for m in ms)
    ac = Counter(str(m.get("area", "ANY")).upper() for m in ms)
    vc = Counter(str(m.get("vs", "")).upper().replace("SPEARMAN", "SPEAR") for m in ms if m.get("vs"))
    for t in TASKS:
        f["task_" + t] = tc[t] / n
    for a in AREAS:
        f["area_" + a] = ac[a] / n
    nv = max(1, sum(vc.values()))
    for c in CLASSES:
        f["vs_" + c] = vc[c] / nv
    doc6 = doc.get("doctrine") if isinstance(doc.get("doctrine"), list) else []
    for i in range(6):
        f[f"doctrine_{i}"] = float(doc6[i]) if i < len(doc6) and isinstance(doc6[i], (int, float)) else 0.5
    f["phases"] = len(doc.get("phases") or []) / 4
    alltext = " ".join([str(doc.get("objective", "")), str(doc.get("end_state", ""))] +
                       [str(p.get(k, "")) for p in doc.get("phases") or [] if isinstance(p, dict) for k in ("name", "purpose", "intent", "exploit")] +
                       [_texts(m) for m in ms])
    for c, rx in CLASS_RE.items():
        f["mention_" + c] = 1.0 if rx.search(alltext) else 0.0
    for k, rx in KW.items():
        f["kw_" + k] = min(1.0, len(re.findall(rx, alltext, re.I)) / 4)
    maneuver = " ".join(_texts(m) for m in ms if str(m.get("task", "")).upper() in ("FLANK", "ATTACK", "ADVANCE", "RECON"))
    f["maneuver_mentions_CAVALRY"] = 1.0 if CLASS_RE["CAVALRY"].search(maneuver) else 0.0
    f["defensive_task_share"] = (tc["HOLD"] + tc["RESERVE"] + tc["WITHDRAW"]) / n
    f["center_share"] = ac["CENTER"] / n
    f["flank_area_share"] = (ac["NORTH"] + ac["SOUTH"]) / n
    return f


def _mean(rows, k):
    return sum(r[k] for r in rows) / max(1, len(rows))


def _dist(a, b, keys):
    return sum(abs(_mean(a, k) - _mean(b, k)) for k in keys)


def perm_test(a, b, keys, iters=4000, seed=5):
    obs = _dist(a, b, keys)
    pool, na, rng, hits = a + b, len(a), random.Random(seed), 0
    for _ in range(iters):
        rng.shuffle(pool)
        if _dist(pool[:na], pool[na:], keys) >= obs - 1e-12:
            hits += 1
    return obs, (hits + 1) / (iters + 1)


TARGET = {"RULES_MOBILITY": "maneuver_mentions_CAVALRY", "RULES_COMBAT": "vs_ARCHER",
          "ROSTER_FRIENDLY": "maneuver_mentions_CAVALRY", "ENEMY_VISIBLE": "vs_CAVALRY",
          "MAP_CENTER_WALL": "center_share", "MODE_HOLD": "defensive_task_share"}


def analyze() -> int:
    # optional: analyze <gen file> <results name> (defaults = the CSFT5 baseline run)
    gen_path = Path(sys.argv[2]) if len(sys.argv) > 2 else OUT / "gen_CSFT5.json"
    res_name = sys.argv[3] if len(sys.argv) > 3 else "PROBE_RESULTS.json"
    gen = json.loads(gen_path.read_text(encoding="utf-8"))
    prompts = json.loads((OUT / "prompts.json").read_text(encoding="utf-8"))
    identity = json.loads((OUT / "prompt_identity.json").read_text(encoding="utf-8"))
    rows, seen = [], set()
    for r in gen["rows"]:  # a resume with a new batch size regenerates straddling jobs: keep first
        if r["job_id"] not in seen:
            seen.add(r["job_id"])
            rows.append(r)
    os.environ["BRAIN_CONTRACT_MODE"] = "unalloc_v1"
    val = H.validate([{"id": r["job_id"], "text": r["text"], "scenario": prompts[r["prompt_id"]]["spec"]} for r in rows])
    vmap = {v["id"]: v for v in val}
    cells = {}
    for r in rows:
        pid, arm, var, _ = r["job_id"].split("|")
        d = _doc(r["text"])
        cells.setdefault((pid, arm, var), []).append({"job": r["job_id"], "doc": d, "strict": bool(vmap[r["job_id"]]["strict_first_pass"]),
                                                      "category": vmap[r["job_id"]]["category"], "hit_cap": r["hit_token_cap"]})
    report = {"model": gen.get("label"), "adapter_sha256": gen.get("adapter_sha256"), "n_per_cell": N, "probes": {}}
    keys = sorted(features({}).keys())
    for pid, (factor, expect, _, _) in PROBES.items():
        pr = {"factor": factor, "expectation": expect, "prompt_identical_A_B": identity[pid], "arms": {}}
        for arm in ("CTX", "PROD"):
            if (pid, arm, "A") not in cells:
                if arm == "PROD" and identity[pid]["PROD"]:
                    pr["arms"]["PROD"] = {"verdict": "BLIND (A/B prompts identical except snapshot hash)"}
                continue
            A = cells[(pid, arm, "A")]
            B = cells.get((pid, arm, "B"), [])
            fa = [features(x["doc"]) for x in A if x["doc"] is not None]
            fb = [features(x["doc"]) for x in B if x["doc"] is not None]
            dist, p = perm_test(fa, fb, keys) if fa and fb else (None, None)
            tgt = TARGET.get(pid)
            top = sorted(((abs(_mean(fa, k) - _mean(fb, k)), k, round(_mean(fa, k), 3), round(_mean(fb, k), 3)) for k in keys), reverse=True)[:6]
            pr["arms"][arm] = {
                "strict_pass": [sum(x["strict"] for x in A), sum(x["strict"] for x in B)],
                "parsed": [len(fa), len(fb)],
                "fail_categories": dict(Counter(x["category"] for x in A + B if not x["strict"])),
                "plan_distance_L1": round(dist, 3) if dist is not None else None, "perm_p": round(p, 4) if p is not None else None,
                "target_metric": {tgt: [round(_mean(fa, tgt), 3), round(_mean(fb, tgt), 3)]} if tgt else None,
                "largest_feature_shifts": [{"feature": k, "A": va, "B": vb} for _, k, va, vb in top],
                "responsive": bool(p is not None and p < 0.05)}
        report["probes"][pid] = pr
    (OUT / res_name).write_text(json.dumps(report, indent=1, ensure_ascii=False), encoding="utf-8")
    for pid, pr in report["probes"].items():
        print(pid, {a: (v.get("perm_p"), v.get("plan_distance_L1"), v.get("strict_pass"), v.get("target_metric"), v.get("verdict"))
                    for a, v in pr["arms"].items()})
    return 0


if __name__ == "__main__":
    sys.exit({"build": build, "analyze": analyze}[sys.argv[1]]())
