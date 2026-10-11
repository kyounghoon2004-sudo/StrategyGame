"""CONTRACT_SFT_V1 evaluation: identical prompts/decoding, production verdict.

  python -m tools.contract_sft.evaluate jobs      -> eval/jobs_eval.json (+ jobs_latency.json)
  python -m tools.contract_sft.evaluate score --gen <a.json> --gen <b.json> [--latency <..>]

HEADLINE = strict first-pass validity of ONE raw generation: production
parser + validator PASS via the real Godot INITIAL path, the raw text is
exactly one JSON object (no fence/prose/trailing-junk salvage), no repair,
no retry, no fallback. Everything else is diagnostic.

Splits: heldout (48 unseen scenarios, rosters disjoint from all training
data, 2 samples each) is the clean generalization test; rl_A (the real RL
prompt A RED + eval BLUE mirror, 16 samples each) is the production RL prompt
- its prompt text IS in the SFT data (with other completions), reported
separately and labeled as such.
"""
from __future__ import annotations

import argparse
import json
import statistics
from pathlib import Path

from tools.contract_sft import harness as H

ROOT = Path(r"D:\Game development\Demon slayer\StrategyGame\artifacts\contract_sft_v1")
EVAL_SEED_BASE = 70000


def _prompts():
    P = {}
    for name in ("heldout", "rl_A"):
        for p in json.loads((ROOT / "prompts" / f"{name}.json").read_text(encoding="utf-8")):
            P[p["prompt_id"]] = p
    return P


def cmd_jobs() -> int:
    P = _prompts()
    held = [p for p in P.values() if p["split"] == "heldout"]
    jobs = []
    for s in range(2):
        for p in held:
            jobs.append({"job_id": f"ho_{p['prompt_id']}_k{s}", "prompt_id": p["prompt_id"],
                         "messages": p["messages"], "split": "heldout"})
    for s in range(16):
        for pid in ("A_RED", "A_BLUE"):
            jobs.append({"job_id": f"rl_{pid}_k{s}", "prompt_id": pid, "messages": P[pid]["messages"],
                         "split": "rl_A"})
    for i, j in enumerate(jobs):
        j["seed"] = EVAL_SEED_BASE + i // 8
    lat = []
    for i, pid in enumerate(["A_RED", held[0]["prompt_id"], "A_BLUE", held[25]["prompt_id"]]):
        lat.append({"job_id": f"lat_{pid}", "prompt_id": pid, "messages": P[pid]["messages"],
                    "split": "latency", "seed": EVAL_SEED_BASE + 900 + i})
    (ROOT / "eval").mkdir(parents=True, exist_ok=True)
    (ROOT / "eval" / "jobs_eval.json").write_text(json.dumps(jobs, ensure_ascii=False), encoding="utf-8")
    (ROOT / "eval" / "jobs_latency.json").write_text(json.dumps(lat, ensure_ascii=False), encoding="utf-8")
    print(f"eval jobs {len(jobs)} (heldout {sum(1 for j in jobs if j['split'] == 'heldout')}, "
          f"rl_A {sum(1 for j in jobs if j['split'] == 'rl_A')}); latency jobs {len(lat)}")
    return 0


def score_one(gen_path: str, P, split_of) -> dict:
    g = json.loads(Path(gen_path).read_text(encoding="utf-8"))
    rows = g["rows"]
    res = H.validate([{"id": r["job_id"], "text": r["text"], "scenario": P[r["prompt_id"]]["scenario"]}
                      for r in rows])
    # Additional safeguard (reported separately, never the headline): the
    # same samples under a root-close structural stop constraint.
    trunc = [H.root_close_truncate(r["text"]) for r in rows]
    cres = H.validate([{"id": r["job_id"], "text": t, "scenario": P[r["prompt_id"]]["scenario"]}
                       for r, t in zip(rows, trunc)])
    per = []
    for r, v, c, t in zip(rows, res, cres, trunc):
        v = dict(v)
        v.update({"job_id": r["job_id"], "prompt_id": r["prompt_id"], "split": split_of[r["job_id"]],
                  "gen_tokens": r["gen_tokens"], "hit_token_cap": r["hit_token_cap"],
                  "constrained_changed_text": t != r["text"],
                  "constrained_strict_first_pass": c["strict_first_pass"],
                  "constrained_category": c["category"]})
        per.append(v)
    out = {"label": g["label"], "adapter": g.get("adapter"), "adapter_sha256": g.get("adapter_sha256"),
           "memory": g.get("memory"), "complete": g.get("complete", False), "n": len(per), "splits": {}}
    for sp in ("heldout", "rl_A", "all"):
        sel = [x for x in per if sp == "all" or x["split"] == sp]
        s = H.summarize(sel)
        s["hit_token_cap"] = sum(1 for x in sel if x["hit_token_cap"])
        s["constrained_root_close_stop"] = {
            "strict_first_pass": H.summarize([dict(x, strict_first_pass=x["constrained_strict_first_pass"])
                                              for x in sel])["strict_first_pass"] if sel else None,
            "texts_changed": sum(1 for x in sel if x["constrained_changed_text"]),
            "note": "SAME samples under a structural stop constraint; NOT the raw headline"}
        s["gen_tokens_mean"] = round(statistics.mean(x["gen_tokens"] for x in sel), 1) if sel else None
        if sp == "heldout":
            for side in ("RED", "BLUE"):
                ss = [x for x in sel if P[x["prompt_id"]]["side"] == side]
                s[f"strict_first_pass_{side}"] = H.summarize(ss)["strict_first_pass"]
            cont = [x for x in sel if P[x["prompt_id"]].get("n_known_enemies", 0) > 0]
            s["strict_first_pass_enemy_contact"] = H.summarize(cont)["strict_first_pass"] if cont else None
        out["splits"][sp] = s
    return {"summary": out, "rows": per}


def latency(path: str) -> dict:
    g = json.loads(Path(path).read_text(encoding="utf-8"))
    rows = g["rows"]
    return {"label": g["label"], "batch_size": g["batch_size"], "n": len(rows),
            "mean_s_per_plan": round(statistics.mean(r["batch_wall_s"] for r in rows), 1),
            "mean_tokens": round(statistics.mean(r["gen_tokens"] for r in rows), 1),
            "tokens_per_s": round(sum(r["gen_tokens"] for r in rows) / sum(r["batch_wall_s"] for r in rows), 2),
            "memory": g.get("memory")}


def cmd_score(gens, lats) -> int:
    P = _prompts()
    jobs = json.loads((ROOT / "eval" / "jobs_eval.json").read_text(encoding="utf-8"))
    split_of = {j["job_id"]: j["split"] for j in jobs}
    report = {"headline_definition": "strict_first_pass = one raw generation; production parser + "
              "validator PASS (real Godot INITIAL path) AND raw text is exactly one JSON object; "
              "no repair, no retry, no fallback",
              "decoding": "temp 0.7 top_p 0.8 top_k 20 rep 1.0 max_new_tokens 1280 non-thinking; "
                          "batch 8, identical job order/batches/seeds for every model",
              "models": {}}
    for gp in gens:
        sc = score_one(gp, P, split_of)
        report["models"][sc["summary"]["label"]] = sc["summary"]
        Path(gp).with_name(Path(gp).stem + "_scored.jsonl").write_text(
            "\n".join(json.dumps(r, ensure_ascii=False) for r in sc["rows"]) + "\n", encoding="utf-8")
    report["latency_batch1"] = [latency(p) for p in lats]
    (ROOT / "eval" / "EVAL_REPORT.json").write_text(json.dumps(report, indent=1), encoding="utf-8")
    for lab, s in report["models"].items():
        h, a = s["splits"]["heldout"], s["splits"]["rl_A"]
        print(f"{lab}: heldout strict {h['strict_first_pass']} | rl_A strict {a['strict_first_pass']} | "
              f"heldout cats {h['categories']}")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("cmd", choices=["jobs", "score"])
    ap.add_argument("--gen", action="append", default=[])
    ap.add_argument("--latency", action="append", default=[])
    a = ap.parse_args()
    return cmd_jobs() if a.cmd == "jobs" else cmd_score(a.gen, a.latency)


if __name__ == "__main__":
    raise SystemExit(main())
