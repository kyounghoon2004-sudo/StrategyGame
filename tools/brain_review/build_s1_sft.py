"""Phase 3 — S1 SFT set: review corpus v2 + replayed S0B opening-plan rows (no forgetting).

Review targets are serialized compact (separators ',' ':'), exactly like the S0B opening-plan targets.
Replay rows are drawn deterministically from S0B's own TRAIN rows (its dev rows stay dev).

  python -m tools.brain_review.build_s1_sft --reviews <review_corpus_v2 dir> --out <dir> [--replay-frac 0.4]
"""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path

ROOT = Path(r"D:\Game development\Demon slayer\StrategyGame")
S0B_ROWS = ROOT / "artifacts" / "contextual_brain_s0b" / "sft_rows.jsonl"
S0B_PROMPTS = ROOT / "artifacts" / "contextual_brain_s0b" / "s0b_prompts.json"


def compact(obj) -> str:
    return json.dumps(obj, ensure_ascii=False, separators=(",", ":"))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--reviews", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--replay-frac", type=float, default=0.4, help="replay rows as a share of the FINAL train set")
    a = ap.parse_args()
    rdir, out = Path(a.reviews), Path(a.out)
    out.mkdir(parents=True, exist_ok=True)

    rv = [json.loads(l) for l in (rdir / "review_rows.jsonl").read_text(encoding="utf-8").splitlines() if l.strip()]
    rp = {p["prompt_id"]: p for p in json.loads((rdir / "review_prompts.json").read_text(encoding="utf-8"))}
    rows, prompts = [], {}
    for r in rv:
        pid = "rv_" + r["prompt_id"]
        prompts[pid] = {"prompt_id": pid, "messages": rp[r["prompt_id"]]["messages"]}
        rows.append({"row_id": "rv_" + r["row_id"], "prompt_id": pid, "target": compact(r["target"]),
                     "split": r["split"], "schema": "review_v2", "kind": "REVIEW", "decision": r["decision"],
                     "subkind": r["subkind"], "game_id": r["game_id"], "source": r.get("source")})

    n_rev_train = sum(1 for r in rows if r["split"] == "train")
    n_replay = round(n_rev_train * a.replay_frac / (1.0 - a.replay_frac))
    s0b = [json.loads(l) for l in S0B_ROWS.read_text(encoding="utf-8").splitlines() if l.strip()]
    s0b_p = {p["prompt_id"]: p for p in json.loads(S0B_PROMPTS.read_text(encoding="utf-8"))}
    train_pool = sorted([r for r in s0b if r["split"] == "train"], key=lambda r: hashlib.sha256(r["row_id"].encode()).hexdigest())
    dev_pool = [r for r in s0b if r["split"] == "dev"]
    for r in train_pool[:n_replay] + dev_pool:
        pid = "s0b_" + r["prompt_id"]
        prompts[pid] = {"prompt_id": pid, "messages": s0b_p[r["prompt_id"]]["messages"]}
        rows.append({"row_id": "s0b_" + r["row_id"], "prompt_id": pid, "target": r["target"], "split": r["split"],
                     "schema": r.get("schema", "unalloc_v1"), "kind": "INITIAL_REPLAY"})

    rows.sort(key=lambda r: hashlib.sha256(r["row_id"].encode()).hexdigest())  # interleave reviews and replay
    (out / "sft_rows.jsonl").write_text("".join(json.dumps(r, ensure_ascii=False) + "\n" for r in rows), encoding="utf-8")
    (out / "sft_prompts.json").write_text(json.dumps(list(prompts.values()), ensure_ascii=False), encoding="utf-8")
    man = {"review_rows": len(rv), "review_train": n_rev_train, "replay_train": min(n_replay, len(train_pool)),
           "replay_dev": len(dev_pool), "total": len(rows),
           "train": sum(1 for r in rows if r["split"] == "train"), "dev": sum(1 for r in rows if r["split"] == "dev"),
           "sha256_rows": hashlib.sha256((out / "sft_rows.jsonl").read_bytes()).hexdigest()}
    (out / "S1_SFT_MANIFEST.json").write_text(json.dumps(man, indent=1), encoding="utf-8")
    print(json.dumps(man, indent=1))


if __name__ == "__main__":
    main()
