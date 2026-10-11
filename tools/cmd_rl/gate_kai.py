"""JEV-family gate for the resident commander (2026-10-08): a decision model (Decision-2.0-Kai-0.6B) reads the turn
and answers "does any order need to change?" before the LLM is called; when it is sure nothing changes, the LLM call
is skipped. This script measures it offline on resident games: labels = what the LLM actually answered (orders or a
new plan = change; {"orders": {}} = keep), plus the time the LLM spent on each turn.

  python -m tools.cmd_rl.gate_kai [--runs <dir>,<dir>] [--model <path>] [--limit N]
"""
from __future__ import annotations

import argparse
import glob
import json
import re
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
RUNS = ROOT / "artifacts" / "brain_pipeline_v1" / "cmd_collect_resident_ab"
MODEL = r"D:\StrategyAI\models\Decision-2.0-Kai-0.6B"
STANDING_RX = re.compile(r"Your orders standing after turn \d+: (.*)")
PLAN_RX = re.compile(r"Your plan \(since turn \d+\): (.*)")


def _order_text(o: dict) -> str:
    s = str(o.get("do", "HOLD")).upper()
    for k in ("target", "to", "back_to"):
        if k in o:
            s += " %s %s" % ("back" if k == "back_to" else "", o[k]) if k == "back_to" else " %s" % (o[k],)
    return s


def context(msgs: list) -> tuple[dict, str]:
    """Orders and plan standing before the last turn message, from the conversation the LLM read."""
    orders, plan = {}, ""
    for m in msgs[1:-1]:
        c = str(m.get("content", ""))
        if m.get("role") == "user":
            for line in c.splitlines():
                ms = STANDING_RX.match(line)
                if ms:
                    for part in ms.group(1).split("; "):
                        uid, _, rest = part.partition(" ")
                        orders[uid] = rest
                mp = PLAN_RX.match(line)
                if mp:
                    plan = mp.group(1)
        else:
            try:
                d = json.loads(c)
            except ValueError:
                continue
            for uid, o in (d.get("orders") or {}).items():
                if isinstance(o, dict):
                    orders[uid.upper()] = _order_text(o)
            if d.get("plan"):
                plan = str(d["plan"])
    return orders, plan


def rows(runs: list) -> list:
    out = []
    for run in runs:
        for f in glob.glob(str(Path(run) / "raw" / "calls.jsonl")):
            for line in open(f, encoding="utf-8"):
                c = json.loads(line)
                msgs = c.get("messages") or []
                if c.get("request") != "VICTORY_COMMAND" or len(msgs) < 4:
                    continue
                try:
                    d = json.loads(c["raw"])
                except ValueError:
                    continue
                if "skipped" in d:
                    continue
                a = ((c.get("local") or {}).get("attempts") or [{}])[-1]
                orders, plan = context(msgs)
                turn = str(msgs[-1]["content"])
                turn = turn[turn.find('{"turn"'):] if '{"turn"' in turn else turn  # the digest is older context
                out.append({"game": c["tag"], "turn": c["turn"], "change": bool(d.get("orders")) or bool(d.get("plan")),
                            "llm_s": a.get("s") or 0, "plan": plan, "orders": orders, "turn_msg": turn})
    return out


QUESTION = {
    "change": {
        "type": "noul",
        "instructions": ("You are the RED commander's aide. The state shows your plan, the orders every RED unit is "
                         "following, and what happened this turn. Must any RED unit get a new order this turn "
                         "(a target destroyed or out of reach, a new threat to the HQ, a unit badly hurt, an "
                         "opportunity the current orders miss)?"),
    }
}


def state_text(r: dict) -> str:
    return json.dumps({"plan": r["plan"], "standing_orders": r["orders"], "this_turn": json.loads(r["turn_msg"])},
                      ensure_ascii=False)


def load_kai(path: str):
    """Decision 2.0's own loader hashes file paths with the OS separator, so on Windows the identity check fails
    ("Model identity differs") on an intact download. The fingerprint is recomputed with '/' paths (as published)."""
    import hashlib
    import sys
    from transformers import AutoModel
    try:
        return AutoModel.from_pretrained(path, trust_remote_code=True)
    except ValueError as e:
        if "identity differs" not in str(e):
            raise
    infer = next(m for n, m in sys.modules.items() if n.endswith("_vendor.dev2model.infer"))
    orig = infer.checkpoint_fingerprint

    def posix_fingerprint(p, source_path=None):
        out = orig(p, source_path)
        hashes = {k.replace("\\", "/"): v for k, v in out["files_sha256"].items()}
        return {"model_sha256": hashlib.sha256(infer.canonical(hashes).encode("utf-8")).hexdigest(), "files_sha256": hashes}

    infer.checkpoint_fingerprint = posix_fingerprint
    return AutoModel.from_pretrained(path, trust_remote_code=True)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--runs", default=",".join(sorted(glob.glob(str(RUNS / "b0*")))))
    ap.add_argument("--model", default=MODEL)
    ap.add_argument("--limit", type=int, default=0)
    a = ap.parse_args()
    data = rows(a.runs.split(","))
    if a.limit:
        data = data[:a.limit]
    import torch
    model = load_kai(a.model)
    if torch.cuda.is_available():
        model = model.to("cuda")
    probs, ms = [], []
    for r in data:
        t0 = time.perf_counter()
        res = model.system_one(state=state_text(r), questions=QUESTION)
        ms.append((time.perf_counter() - t0) * 1000)
        ans = res["answers"]["change"]
        probs.append(float(ans["noul"]))  # a yes / no question returns P(yes) under "noul"
    print("rows", len(data), "change share %.2f" % (sum(r["change"] for r in data) / len(data)))
    ms_sorted = sorted(ms)
    print("gate latency ms: median %.1f p90 %.1f" % (ms_sorted[len(ms) // 2], ms_sorted[int(len(ms) * .9)]))
    total = sum(r["llm_s"] for r in data)
    for th in (0.1, 0.2, 0.3, 0.4, 0.5):
        skip = [i for i, p in enumerate(probs) if p < th]
        missed = sum(1 for i in skip if data[i]["change"])
        saved = sum(data[i]["llm_s"] for i in skip)
        print("p(change)<%.1f -> skip %d turns (%.0f%%), LLM time saved %.0f%%, missed changes %d of %d (%.0f%%)" % (
            th, len(skip), 100 * len(skip) / len(data), 100 * saved / total, missed, sum(r["change"] for r in data),
            100 * missed / max(1, sum(r["change"] for r in data))))
    Path(ROOT / "artifacts" / "brain_pipeline_v1" / "jev_gate").mkdir(parents=True, exist_ok=True)
    (ROOT / "artifacts" / "brain_pipeline_v1" / "jev_gate" / "zero_shot.json").write_text(json.dumps(
        [{"game": r["game"], "turn": r["turn"], "change": r["change"], "p": p, "llm_s": r["llm_s"]} for r, p in zip(data, probs)]),
        encoding="utf-8")
    print("example answer:", json.dumps(res["answers"])[:400])


if __name__ == "__main__":
    main()
