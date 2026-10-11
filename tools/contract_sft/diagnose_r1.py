"""CSFT1 progress diagnosis + B03R1 coverage (read-only; no GPU, no training).

  python -m tools.contract_sft.diagnose_r1
Writes artifacts/contract_sft_v1/diagnosis/CSFT1_DIAGNOSIS.json + per-case jsonl.
"""
from __future__ import annotations

import collections
import json
import re
from pathlib import Path

ROOT = Path(r"D:\Game development\Demon slayer\StrategyGame\artifacts\contract_sft_v1")
UID = re.compile(r"\b([RB])_([A-Z]{2,3})_(\d+)\b")
EXAMPLE_TAGS = ("CAV_1", "CAV_2", "INF_1", "INF_2")  # literal ids in the production system prompt
RL_A_TAGS = {"ARC_1", "ARC_2", "CAV_1", "CAV_2", "HQ_1", "INF_1", "INF_2", "SCT_1", "SPE_1", "SPE_2"}
SCHEMA = ("VA_PHASES", "VA_MISSIONS", "VA_OBJECTIVE", "VA_MISSION_UNITS", "VA_SHAPE", "VA_RICH_SUPPORT",
          "VA_RICH_ROLE", "VP_")
ILLEGAL = ("VA_COND", "VA_MISSION_TASK", "VA_TRANSITION", "VA_BRANCH", "VA_MISSION_AREA", "VA_MISSION_ZONE",
           "VA_BRANCHES")


def load_prompts():
    P = {}
    for n in ("heldout", "rl_A", "train_gen", "train_gen2"):
        f = ROOT / "prompts" / f"{n}.json"
        if f.exists():
            for p in json.loads(f.read_text(encoding="utf-8")):
                P[p["prompt_id"]] = p
    return P


def packet(p):
    return json.loads(p["messages"][1]["content"])


def taxonomy(row):
    cat = row["category"]
    if cat == "PASS":
        return "1_VALID_FIRST_PASS"
    if cat in ("UNPARSEABLE_JSON", "EXTRA_TEXT_SALVAGED"):
        return "2_JSON_SYNTAX"
    code = cat.split(":", 1)[1]
    if code == "VA_UNKNOWN_UNIT":
        return "5_UNKNOWN_FRIENDLY_UNIT"
    if code.startswith(ILLEGAL):
        return "4_ILLEGAL_TRIGGER_TASK_TRANSITION"
    if code.startswith(SCHEMA):
        return "3_REQUIRED_FIELD_SCHEMA"
    return "OTHER:" + code


def main() -> int:
    import argparse
    ap = argparse.ArgumentParser()
    ap.add_argument("--label", default="CSFT1")
    label = ap.parse_args().label
    P = load_prompts()
    gen = {r["job_id"]: r for r in json.loads((ROOT / "eval" / f"gen_eval_{label}.json").read_text(encoding="utf-8"))["rows"]}
    scored = [json.loads(l) for l in open(ROOT / "eval" / f"gen_eval_{label}_scored.jsonl", encoding="utf-8")]
    held = [r for r in scored if r["split"] == "heldout"]
    assert len(held) == 96
    cases = []
    for r in held:
        p = P[r["prompt_id"]]
        side = p["side"][0]
        pk = packet(p)
        roster = {u["unit_id"] for u in pk["compact_state"]["friendly_units"]}
        enemies = {u["unit_id"] for u in pk["compact_state"]["known_enemy_units"]}
        user_text = p["messages"][1]["content"]
        text = gen[r["job_id"]]["text"]
        used = {m.group(0) for m in UID.finditer(text)}
        unknown_friendly = sorted(u for u in used if u[0] == side and u not in roster)
        unauth_enemy = sorted(u for u in used if u[0] != side and u not in enemies)
        src = {}
        for u in unknown_friendly:
            tag = u[2:]
            memb = {"A_system_example": tag in EXAMPLE_TAGS,
                    "B_elsewhere_in_scenario": u in user_text,
                    "C_familiar_rl_roster": tag in RL_A_TAGS}
            src[u] = {"membership": memb,
                      "primary": "A" if memb["A_system_example"] else "B" if memb["B_elsewhere_in_scenario"]
                      else "C" if memb["C_familiar_rl_roster"] else "D"}
        tags = {u[2:] for u in roster}
        cases.append({"job_id": r["job_id"], "prompt_id": r["prompt_id"], "side": p["side"],
                      "strict_first_pass": r["strict_first_pass"], "category": r["category"],
                      "taxonomy": taxonomy(r), "validator_detail": (r.get("fault_detail") or r.get("validator_detail")
                                                                     or r.get("parse_detail") or "")[:200],
                      "hit_token_cap": r["hit_token_cap"], "gen_tokens": r["gen_tokens"],
                      "roster": sorted(roster), "n_known_enemies": len(enemies),
                      "has": {t: t in tags for t in EXAMPLE_TAGS},
                      "unknown_friendly_ids": unknown_friendly, "unknown_friendly_sources": src,
                      "unauthorized_enemy_ids": unauth_enemy,
                      "example_copy": any(s["primary"] == "A" for s in src.values())})
    n = len(cases)
    tax = collections.Counter(c["taxonomy"] for c in cases)
    fails = [c for c in cases if not c["strict_first_pass"]]

    def rate(sel):
        return {"n": len(sel), "strict_pass": sum(c["strict_first_pass"] for c in sel),
                "rate": round(sum(c["strict_first_pass"] for c in sel) / len(sel), 4) if sel else None}
    roster_table = {}
    for t in EXAMPLE_TAGS:
        roster_table[f"HAS_{t}"] = rate([c for c in cases if c["has"][t]])
        roster_table[f"LACKS_{t}"] = rate([c for c in cases if not c["has"][t]])
    roster_table["HAS_ALL_EXAMPLE_IDS"] = rate([c for c in cases if all(c["has"].values())])
    roster_table["MISSING_ANY_EXAMPLE_ID"] = rate([c for c in cases if not all(c["has"].values())])
    roster_table["HAS_CAV_1_and_INF_2"] = rate([c for c in cases if c["has"]["CAV_1"] and c["has"]["INF_2"]])
    roster_table["LACKS_CAV_1_or_INF_2"] = rate([c for c in cases if not (c["has"]["CAV_1"] and c["has"]["INF_2"])])
    # per example id: presence in held-out rosters and hallucination when absent
    ex_stats = {}
    for t in EXAMPLE_TAGS:
        absent = [c for c in cases if not c["has"][t]]
        hall = [c for c in absent if any(u[2:] == t for u in c["unknown_friendly_ids"])]
        ex_stats[t] = {"present_in_heldout_cases": n - len(absent), "absent_cases": len(absent),
                       "hallucinated_when_absent": len(hall),
                       "hallucination_rate_when_absent": round(len(hall) / len(absent), 4) if absent else None}
    all_unknown = [(c, u, s) for c in cases for u, s in c["unknown_friendly_sources"].items()]
    src_counts = collections.Counter(s["primary"] for _, _, s in all_unknown)
    fail_with_example_copy = [c for c in fails if c["example_copy"]]
    va_unknown = [c for c in cases if c["taxonomy"] == "5_UNKNOWN_FRIENDLY_UNIT"]
    report = {
        "scope": f"{label} on the 96 held-out cases (48 unseen scenarios x 2 samples); raw generations; "
                 "verdicts from the real Godot production path",
        "headline": {"heldout_strict": rate(cases),
                     "rl_A_strict": rate([{"strict_first_pass": r["strict_first_pass"]} for r in scored
                                          if r["split"] == "rl_A"])},
        "taxonomy_primary": dict(sorted(tax.items())),
        "flags_any_case": {
            "6_unauthorized_enemy_id_cases": sum(1 for c in cases if c["unauthorized_enemy_ids"]),
            "6_unauthorized_enemy_id_cases_among_valid": sum(1 for c in cases if c["unauthorized_enemy_ids"]
                                                             and c["strict_first_pass"]),
            "7_example_id_copied_cases": sum(1 for c in cases if c["example_copy"]),
            "unknown_friendly_id_cases_any_category": sum(1 for c in cases if c["unknown_friendly_ids"]),
            "hit_token_cap": sum(1 for c in cases if c["hit_token_cap"])},
        "unknown_friendly_id_sources": {"instances": len(all_unknown), "primary_counts": dict(src_counts),
                                        "ids": dict(collections.Counter(u[2:] for _, u, _ in all_unknown))},
        "example_copy": {
            "example_ids": list(EXAMPLE_TAGS), "per_id": ex_stats,
            "failures_total": len(fails),
            "failures_with_example_id_copy": len(fail_with_example_copy),
            "share_of_all_failures": round(len(fail_with_example_copy) / len(fails), 4) if fails else None,
            "VA_UNKNOWN_UNIT_failures": len(va_unknown),
            "VA_UNKNOWN_UNIT_with_example_copy": sum(1 for c in va_unknown if c["example_copy"])},
        "roster_conditioned": roster_table,
        "unauthorized_enemy_ids_seen": dict(collections.Counter(u for c in cases for u in c["unauthorized_enemy_ids"])),
    }
    # B03R1 coverage
    b = [json.loads(l) for l in open(ROOT / "intake" / "B03R1_intake_v1.jsonl", encoding="utf-8")]
    scen = {}
    for r in b:
        scen.setdefault(r["prompt_id"], r)
    cov = collections.Counter()
    sigs, sides, objs = set(), collections.Counter(), collections.Counter()
    for pid in scen:
        p = P[pid]
        tags = {u["unit_id"][2:] for u in packet(p)["compact_state"]["friendly_units"]}
        cov["lacks_CAV_1"] += "CAV_1" not in tags
        cov["lacks_INF_2"] += "INF_2" not in tags
        cov["lacks_both"] += ("CAV_1" not in tags and "INF_2" not in tags)
        cov["lacks_any_example_id"] += not all(t in tags for t in EXAMPLE_TAGS)
        sigs.add(p["roster_signature"])
        sides[p["side"]] += 1
        objs[p["scenario"]["primary_objective"]] += 1
    def share(lst, key):
        return round(sum(1 for x in lst if key(x)) / len(lst), 4)
    heldp = [P[p] for p in {c["prompt_id"] for c in cases}]
    tg = [p for p in P.values() if p["split"] == "train_gen"]
    def lacks(p, t):
        return t not in {u["unit_id"][2:] for u in packet(p)["compact_state"]["friendly_units"]}
    r1_rows = [json.loads(l) for l in open(ROOT / "dataset" / "sft_rows.jsonl", encoding="utf-8")]
    r1_lack = sum(1 for r in r1_rows if r["prompt_id"] in P and (lacks(P[r["prompt_id"]], "CAV_1")
                                                                  or lacks(P[r["prompt_id"]], "INF_2")))
    report["B03R1_coverage"] = {
        "rows": len(b), "scenarios": len(scen), "variants_per_scenario": round(len(b) / len(scen), 2),
        "scenarios_lacking_CAV_1": cov["lacks_CAV_1"], "scenarios_lacking_INF_2": cov["lacks_INF_2"],
        "scenarios_lacking_both": cov["lacks_both"], "scenarios_lacking_any_example_id": cov["lacks_any_example_id"],
        "distinct_roster_signatures": len(sigs), "sides": dict(sides), "objective_families": dict(objs),
        "rows_lacking_CAV_1_or_INF_2": sum(1 for r in b if lacks(P[r["prompt_id"]], "CAV_1")
                                            or lacks(P[r["prompt_id"]], "INF_2")),
        "comparison": {
            "R1_train_rows": len(r1_rows),
            "R1_rows_on_rosters_lacking_CAV_1_or_INF_2": r1_lack,
            "R1_share_lacking": round(r1_lack / len(r1_rows), 4),
            "heldout_scenarios_share_lacking_CAV_1_or_INF_2": share(heldp, lambda p: lacks(p, "CAV_1") or lacks(p, "INF_2")),
            "train_gen_scenarios_share_lacking_CAV_1_or_INF_2": share(tg, lambda p: lacks(p, "CAV_1") or lacks(p, "INF_2")),
        },
        "B03R1_scenarios_overlap_heldout_rosters": sum(1 for pid in scen if P[pid]["roster_signature"] in
                                                       {p["roster_signature"] for p in heldp}),
    }
    out = ROOT / "diagnosis"
    out.mkdir(exist_ok=True)
    (out / f"{label}_DIAGNOSIS.json").write_text(json.dumps(report, indent=1), encoding="utf-8")
    with open(out / f"{label}_heldout_cases.jsonl", "w", encoding="utf-8") as f:
        for c in cases:
            f.write(json.dumps(c) + "\n")
    print(json.dumps(report, indent=1))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
