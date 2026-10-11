"""CONTEXTUAL_BRAIN_S0 promotion gate (pre-registered in artifacts/contextual_brain_s0/GATE_PREREGISTRATION.md).

  python -m tools.contextual_brain.s0_gate
Reads the frozen probe analysis for CSFT5 (before) and S0 (after) and writes S0_GATE.json.
"""
import json
import re
from pathlib import Path

ROOT = Path(r"D:\Game development\Demon slayer\StrategyGame")
PROBE = ROOT / "artifacts" / "contextual_brain_pipeline_v0" / "probe"
OUT = ROOT / "artifacts" / "contextual_brain_s0"
RELEVANT = ["RULES_MOBILITY", "RULES_COMBAT", "ROSTER_FRIENDLY", "ENEMY_VISIBLE", "MAP_CENTER_WALL", "MODE_HOLD"]
CONTROLS = ["CTRL_NOISE", "CTRL_TINY_RULE", "CTRL_REAR_TERRAIN"]
DIRECTION = {"RULES_MOBILITY": ("maneuver_mentions_CAVALRY", -1), "ROSTER_FRIENDLY": ("maneuver_mentions_CAVALRY", -1),
             "ENEMY_VISIBLE": ("vs_CAVALRY", +1), "MAP_CENTER_WALL": ("center_share", -1),
             "MODE_HOLD": ("defensive_task_share", +1), "RULES_COMBAT": ("cav_avoid_spear_limit", -1)}
EXAMPLE_DOCTRINE = [0.6, 0.5, 0.6, 0.6, 0.7, 0.2]
CAV_AVOID_SPEAR = re.compile(r"cav\w*[^\"]{0,40}(spear)|(spear)[^\"]{0,40}cav", re.I)


def cells(gen):
    seen, out = set(), {}
    for r in gen["rows"]:
        if r["job_id"] in seen:
            continue
        seen.add(r["job_id"])
        pid, arm, var, _ = r["job_id"].split("|")
        out.setdefault((pid, arm, var), []).append(r["text"])
    return out


def limit_share(texts):
    n = 0
    for t in texts:
        try:
            d = json.loads(t)
        except ValueError:
            continue
        lims = [l for p in d.get("phases") or [] for m in p.get("missions") or [] for l in (m.get("limits") or [])]
        n += any(CAV_AVOID_SPEAR.search(str(l)) and "avoid" in str(l).lower() or
                 (CAV_AVOID_SPEAR.search(str(l)) and "out of" in str(l).lower()) for l in lims)
    return n / max(1, len(texts))


def evaluate(results_file, gen_file):
    res = json.loads((PROBE / results_file).read_text(encoding="utf-8"))
    gen = json.loads(Path(gen_file).read_text(encoding="utf-8"))
    cs = cells(gen)
    out = {"relevant": {}, "controls": {}}
    for pid in RELEVANT:
        a = res["probes"][pid]["arms"]["CTX"]
        metric, sign = DIRECTION[pid]
        if metric == "cav_avoid_spear_limit":
            va, vb = limit_share(cs[(pid, "CTX", "A")]), limit_share(cs[(pid, "CTX", "B")])
        else:
            va, vb = a["target_metric"][metric] if a.get("target_metric") and metric in a["target_metric"] else \
                next(([x["A"], x["B"]] for x in a["largest_feature_shifts"] if x["feature"] == metric), [None, None])
            if va is None:
                va, vb = feat_means(cs, pid, metric)
        moved = va is not None and (vb - va) * sign > 0
        identical = len(set(cs[(pid, "CTX", "A")] + cs[(pid, "CTX", "B")])) == 1
        out["relevant"][pid] = {"p": a["perm_p"], "metric": metric, "A": round(va, 3), "B": round(vb, 3),
                                "direction_ok": moved, "responds": bool(a["perm_p"] < 0.05 and moved), "all_identical": identical}
    for pid in CONTROLS:
        a = res["probes"][pid]["arms"]["CTX"]
        out["controls"][pid] = {"p": a["perm_p"], "flagged": a["perm_p"] < 0.05}
    ctx = [t for (p, arm, v), ts in cs.items() if arm == "CTX" for t in ts]
    docs = [json.loads(t) for t in ctx if _ok(t)]
    arms = [a for pr in res["probes"].values() for a in pr["arms"].values() if "strict_pass" in a]
    out["strict_pass"] = [sum(sum(a["strict_pass"]) for a in arms), 16 * len(arms)]
    out["doctrine_equals_example_rate"] = round(sum(d.get("doctrine") == EXAMPLE_DOCTRINE for d in docs) / max(1, len(docs)), 3)
    out["n_relevant_responding"] = sum(v["responds"] for v in out["relevant"].values())
    out["n_controls_flagged"] = sum(v["flagged"] for v in out["controls"].values())
    return out


def _ok(t):
    try:
        json.loads(t)
        return True
    except ValueError:
        return False


def feat_means(cs, pid, metric):
    from tools.contract_sft.context_probe import features
    fa = [features(json.loads(t))[metric] for t in cs[(pid, "CTX", "A")] if _ok(t)]
    fb = [features(json.loads(t))[metric] for t in cs[(pid, "CTX", "B")] if _ok(t)]
    return sum(fa) / max(1, len(fa)), sum(fb) / max(1, len(fb))


def main():
    before = evaluate("PROBE_RESULTS.json", PROBE / "gen_CSFT5.json")
    after = evaluate("PROBE_RESULTS_S0.json", PROBE / "gen_S0.json")
    ctxoff = json.loads((OUT / "context_off_identity.json").read_text(encoding="utf-8"))
    sp = after["strict_pass"]
    checks = {"relevant_ge_4": after["n_relevant_responding"] >= 4, "controls_0": after["n_controls_flagged"] == 0,
              "strict_ge_0.97": sp[0] / max(1, sp[1]) >= 0.97,
              "context_off_unchanged": bool(ctxoff["context_off_identical_to_pre_trackC_baseline"]),
              "doctrine_copy_lt_0.10": after["doctrine_equals_example_rate"] < 0.10,
              "no_identical_relevant_cell": not any(v["all_identical"] for v in after["relevant"].values())}
    gate = {"before_CSFT5": before, "after_S0": after, "checks": checks, "verdict": "PASS" if all(checks.values()) else "BLOCKED"}
    (OUT / "S0_GATE.json").write_text(json.dumps(gate, indent=1), encoding="utf-8")
    print(json.dumps(gate, indent=1))


if __name__ == "__main__":
    main()
