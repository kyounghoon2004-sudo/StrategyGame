"""Evaluate models on the sealed CSFT5 challenge (104 production-rebuilt
INITIAL prompts, visibility-faithful v2). Headline = strict raw first-pass
(real Godot production path, exactly one JSON object, no repair).

  python -m tools.contract_sft.eval_challenge jobs
  python -m tools.contract_sft.eval_challenge score --gen <gen.json> [...]

Failure families (all computed from raw text vs the rebuilt packet):
  unknown_friendly   own-side id not in roster
  example_copy       unknown own id whose tag is a system-prompt example id
                     (CAV_1, CAV_2, INF_1, INF_2)
  wrong_side         a friendly-roster id written with the enemy prefix, or
                     own-prefix id that exists only on the enemy side
  hidden_enemy       enemy id not fog-visible (excluding conventional HQ_1),
  hidden_enemy_hq    enemy HQ_1 referenced while not visible
"""
from __future__ import annotations

import argparse
import collections
import json
import re
from pathlib import Path

from tools.contract_sft import harness as H

ROOT = Path(r"D:\Game development\Demon slayer\StrategyGame\artifacts\contract_sft_v1")
UID = re.compile(r"\b([RB])_([A-Z]{2,4})_(\d+)\b")
EXAMPLE_TAGS = {"CAV_1", "CAV_2", "INF_1", "INF_2"}


def prompts():
    return {p["prompt_id"]: p for p in json.loads((ROOT / "prompts" / "csft5_challenge_v2.json").read_text(encoding="utf-8"))}


def cmd_jobs():
    P = prompts()
    jobs = [{"job_id": "c5_" + pid, "prompt_id": pid, "messages": p["messages"], "seed": 80000 + i // 8}
            for i, (pid, p) in enumerate(sorted(P.items()))]
    (ROOT / "eval" / "jobs_csft5_challenge.json").write_text(json.dumps(jobs, ensure_ascii=False), encoding="utf-8")
    print(len(jobs))


def families(p, text):
    pk = json.loads(p["messages"][1]["content"])
    own = p["side"][0]
    roster = {u["unit_id"] for u in pk["compact_state"]["friendly_units"]}
    vis = {u["unit_id"] for u in pk["compact_state"]["known_enemy_units"]}
    ids = {m.group(0) for m in UID.finditer(text)}
    enemy_all = {u["id"] for u in (p["scenario"]["blue_forces"] if own == "R" else p["scenario"]["red_forces"])}
    unk = sorted(u for u in ids if u[0] == own and u not in roster)
    wrong = sorted(u for u in ids if (u[0] != own and (own + u[1:]) in roster and u not in enemy_all)
                   or (u[0] == own and u not in roster and (("B" if own == "R" else "R") + u[1:]) in enemy_all))
    return {"unknown_friendly": unk,
            "example_copy": [u for u in unk if u[2:] in EXAMPLE_TAGS],
            "wrong_side": wrong,
            "hidden_enemy": sorted(u for u in ids if u[0] != own and u not in vis and not u.endswith("_HQ_1")),
            "hidden_enemy_hq": sorted(u for u in ids if u[0] != own and u not in vis and u.endswith("_HQ_1"))}


def cmd_score(gens):
    P = prompts()
    report = {"set": "csft5_challenge_v2 (sealed, production-rebuilt)", "n_prompts": len(P), "models": {}}
    for gp in gens:
        g = json.loads(Path(gp).read_text(encoding="utf-8"))
        res = H.validate([{"id": r["job_id"], "text": r["text"], "scenario": P[r["prompt_id"]]["scenario"]}
                          for r in g["rows"]])
        rows = []
        for r, v in zip(g["rows"], res):
            fam = families(P[r["prompt_id"]], r["text"])
            rows.append(dict(v, job_id=r["job_id"], family_set=P[r["prompt_id"]]["family"], **fam,
                             hit_token_cap=r["hit_token_cap"]))
        s = H.summarize(rows)
        s["failure_families_any_case"] = {k: sum(1 for x in rows if x[k]) for k in
                                          ("unknown_friendly", "example_copy", "wrong_side", "hidden_enemy",
                                           "hidden_enemy_hq")}
        s["hit_token_cap"] = sum(1 for x in rows if x["hit_token_cap"])
        s["strict_by_family"] = {f: f"{sum(1 for x in rows if x['family_set'] == f and x['strict_first_pass'])}/"
                                    f"{sum(1 for x in rows if x['family_set'] == f)}"
                                 for f in sorted({x['family_set'] for x in rows})}
        s["memory"] = g.get("memory")
        report["models"][g["label"]] = s
        Path(gp).with_name(Path(gp).stem + "_scored.jsonl").write_text(
            "\n".join(json.dumps(x, ensure_ascii=False) for x in rows) + "\n", encoding="utf-8")
    (ROOT / "eval" / "CSFT5_CHALLENGE_REPORT.json").write_text(json.dumps(report, indent=1), encoding="utf-8")
    for m, s in report["models"].items():
        print(m, "strict", s["strict_first_pass"], "families", s["failure_families_any_case"], "cats", s["categories"])


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("cmd", choices=["jobs", "score"])
    ap.add_argument("--gen", action="append", default=[])
    a = ap.parse_args()
    cmd_jobs() if a.cmd == "jobs" else cmd_score(a.gen)


if __name__ == "__main__":
    main()
