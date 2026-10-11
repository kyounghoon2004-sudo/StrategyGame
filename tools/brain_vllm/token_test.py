"""BRAIN_VLLM_PHASE1 — token exactness proof (50 mixed prompts).

  python -m tools.brain_vllm.token_test --capture-dir <dir> [--shim http://127.0.0.1:8096]

Sends 50 mixed prompts (40 DEV opening plans + 10 captured reviews) through the
running shim, then reads back <capture-dir>/calls.jsonl and compares each stored
prompt_ids to G.load_tokenizer()(G.render_prompt(...)) recomputed on the Windows
side. Gate: 50/50 exact. Writes <capture-dir>/token_test.json.
"""
from __future__ import annotations

import argparse
import json
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

from tools.brain_vllm import common as C  # noqa: E402

VLLM_DIR = ROOT / "artifacts" / "brain_pipeline_v1" / "vllm"


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--capture-dir", required=True)
    ap.add_argument("--shim", default=C.SHIM_URL)
    ap.add_argument("--n-open", type=int, default=40)
    ap.add_argument("--n-review", type=int, default=10)
    a = ap.parse_args()
    cap = Path(a.capture_dir)
    cap.mkdir(parents=True, exist_ok=True)

    from tools.contract_sft import gpu_common as G
    tok = G.load_tokenizer()
    prompts_open = json.loads((VLLM_DIR / "parity" / "prompts_open.json").read_text(encoding="utf-8"))
    prompts_review = json.loads((VLLM_DIR / "parity" / "prompts_review.json").read_text(encoding="utf-8"))
    s0b = [p for p in prompts_open if p["corpus"] == "s0b"][: a.n_open // 2]
    s0c = [p for p in prompts_open if p["corpus"] == "s0c"][: a.n_open - len(s0b)]
    picks = s0b + s0c + prompts_review[: a.n_review]
    print(f"[token_test] sending {len(picks)} prompts ({len(s0b)}+{len(s0c)} open, {min(a.n_review, len(prompts_review))} review)")

    before = 0
    jl = cap / "calls.jsonl"
    if jl.exists():
        before = sum(1 for _ in open(jl, encoding="utf-8"))
    t0 = time.time()
    for i, p in enumerate(picks):
        code, body = C.http_json(a.shim + "/v1/chat/completions", {"messages": p["messages"]}, method="POST", timeout=900)
        if code != 200:
            raise SystemExit(f"prompt {i} shim http {code}: {str(body)[:300]}")
    rows = [json.loads(l) for l in open(jl, encoding="utf-8") if l.strip()][before:]
    assert len(rows) == len(picks), f"captured {len(rows)} rows for {len(picks)} prompts"

    bad = []
    for p, r in zip(picks, rows):
        want = tok(G.render_prompt(tok, p["messages"]), add_special_tokens=False)["input_ids"]
        if r.get("prompt_ids") != want:
            bad.append({"prompt_id": p["prompt_id"], "got_len": len(r.get("prompt_ids") or []),
                        "want_len": len(want), "first_diff": next(
                            (i for i, (x, y) in enumerate(zip(r.get("prompt_ids") or [], want)) if x != y), None)})
    res = {"n": len(picks), "exact": len(picks) - len(bad), "rate": round((len(picks) - len(bad)) / len(picks), 4),
           "pass": not bad, "mismatches": bad[:10], "wall_s": round(time.time() - t0, 1),
           "comp_ids_exact_flags": sorted({bool(r.get("comp_ids_exact", True)) for r in rows}),
           "at": time.strftime("%Y-%m-%dT%H:%M:%S")}
    (cap / "token_test.json").write_text(json.dumps(res, indent=1), encoding="utf-8")
    print(json.dumps(res, indent=1))
    return 0 if res["pass"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
