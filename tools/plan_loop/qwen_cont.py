"""HQ same-state / different-choice with the QWEN continuation (2026-10-12, user: HQ only, no GX continuation).

The evaldata_v1 branches (same state at T, a different candidate answer) were labelled with a fixed GX continuing from
T+5. Here the same situations and candidates are played again with the live Qwen policy ("policy" on :8000, an HQ
adapter) answering every turn after T, R times each (sampling differs), so a candidate gets a win RATE.

  python -m tools.plan_loop.qwen_cont jobs  --split test --situations 30 --cands 5 --rollouts 4 --out <jobs.jsonl>
  python -m tools.synth_sft_v2.branch <jobs.jsonl> <run dir> --mode hq --bank .../plan_loop_v1/bank_hq.json \
        --windows 8 --slot 0 --proxy-port 8120 --brain-port 8130
  python -m tools.plan_loop.qwen_cont agg <run dir> [<run dir> ...] --out <table.json>
"""
from __future__ import annotations

import argparse
import collections
import json
import random
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
EV = ROOT / "artifacts" / "brain_pipeline_v1" / "plan_loop_v1" / "evaldata_v1"
RANK = {"RED_WIN": 2, "CAP": 1, "BLUE_WIN": 0}


def jobs(a):
    done = {}
    for line in (EV / "completed.jsonl").read_text(encoding="utf-8").splitlines():
        x = json.loads(line)
        done[x["id"]] = x
    spec = {}
    for line in (EV / "branches.jsonl").read_text(encoding="utf-8").splitlines():
        b = json.loads(line)
        spec[b["id"]] = b
    by = collections.defaultdict(list)
    for i, x in done.items():
        if x["split"] == a.split and i in spec:
            by[x["situation"]].append(x)
    rng = random.Random(a.seed)
    # contested under the GX continuation: at least one RED_WIN and one non-win
    cont = [s for s, v in by.items() if any(y["outcome"] == "RED_WIN" for y in v) and any(y["outcome"] != "RED_WIN" for y in v)]
    cont.sort()
    rng.shuffle(cont)
    picked = cont[: a.situations]
    out, table = [], []
    for s in picked:
        v = by[s]
        rec = [y for y in v if y["variant"] == "recorded"]
        best = sorted(v, key=lambda y: -RANK[y["outcome"]])
        chosen, seen = [], set()
        for y in rec + best[:1] + best[-1:] + v:
            if y["id"] in seen or len({c["answer_hash"] for c in chosen}) >= a.cands and y["answer_hash"] not in {c["answer_hash"] for c in chosen}:
                continue
            if y["answer_hash"] in {c["answer_hash"] for c in chosen}:
                continue
            chosen.append(y)
            seen.add(y["id"])
            if len(chosen) >= a.cands:
                break
        for y in chosen:
            b = dict(spec[y["id"]])
            for r in range(a.rollouts):
                bb = dict(b)
                bb["id"] = "%s__q%d" % (b["id"], r)
                bb["after"] = "live"
                bb["parent_id"] = b["id"]
                bb["gx_outcome"] = y["outcome"]
                out.append(bb)
        table.append({"situation": s, "candidates": [{"id": y["id"], "variant": y["variant"], "gx_outcome": y["outcome"]} for y in chosen]})
    Path(a.out).write_text("".join(json.dumps(b) + "\n" for b in out), encoding="utf-8")
    Path(a.out).with_suffix(".situations.json").write_text(json.dumps(table, indent=1), encoding="utf-8")
    print("situations %d, branches %d" % (len(picked), len(out)))


def agg(a):
    res = collections.defaultdict(list)
    for run in a.runs:
        f = Path(run) / "results.jsonl"
        if not f.exists():
            continue
        for line in f.read_text(encoding="utf-8").splitlines():
            r = json.loads(line)
            gid = str(r.get("game", ""))
            if "__q" not in gid:
                continue
            if r.get("error") or (r.get("turn") or 0) <= 1 or r.get("kind") in ("INVALID", "ERROR"):
                continue
            res[gid.rsplit("__q", 1)[0]].append(r.get("outcome"))
    table = {}
    for pid, outs in res.items():
        n = len(outs)
        table[pid] = {"n": n, "win": sum(o == "RED_WIN" for o in outs), "loss": sum(o == "BLUE_WIN" for o in outs),
                      "cap": sum(o == "CAP" for o in outs), "p_win": round(sum(o == "RED_WIN" for o in outs) / n, 3)}
    Path(a.out).write_text(json.dumps(table, indent=1), encoding="utf-8")
    print("candidates with rollouts: %d" % len(table))


def main():
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)
    j = sub.add_parser("jobs")
    j.add_argument("--split", default="test")
    j.add_argument("--situations", type=int, default=30)
    j.add_argument("--cands", type=int, default=5)
    j.add_argument("--rollouts", type=int, default=4)
    j.add_argument("--seed", type=int, default=0)
    j.add_argument("--out", required=True)
    g = sub.add_parser("agg")
    g.add_argument("runs", nargs="+")
    g.add_argument("--out", required=True)
    a = ap.parse_args()
    jobs(a) if a.cmd == "jobs" else agg(a)


if __name__ == "__main__":
    main()
