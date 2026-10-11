"""BRAIN_VLLM_PHASE1 — REDUCED-SCOPE quality scoring (operator instruction 2026-10-01).

The HF-NF4 baseline was stopped at 112/300 open rows (GPU freed for other work);
HF reviews and the drift run were skipped. No generation happens here — only
validation of rows that already exist:

  python -m tools.brain_vllm.score_partial --out <PARTIAL_PARITY.json>

1. Strict first-pass validity (harness.validate, production Godot INITIAL path)
   of the 300 existing vLLM opening plans (all of vllm_open.json).
2. Same metric on the 112 recorded HF rows, restricted to the 112 COMMON
   job_ids (identical prompts) for the apples-to-apples delta, plus the
   decision-field TV distances on those common jobs.
3. JSON-object parse rate + decision distribution of the 88 existing vLLM
   reviews, vs the recorded HF review raws in artifacts/rl_vs_utility_v0.
Writes PARTIAL_PARITY.json (NOT PARITY.json: the full a/b/c gate battery was
scoped out by the operator; this file says exactly what it compared).
"""
from __future__ import annotations

import argparse
import glob
import json
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

from tools.brain_vllm.parity import dec_fields, dist, tv_distance  # noqa: E402

VLLM_DIR = ROOT / "artifacts" / "brain_pipeline_v1" / "vllm"
RLV = ROOT / "artifacts" / "rl_vs_utility_v0"


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default=str(VLLM_DIR / "PARTIAL_PARITY.json"))
    ap.add_argument("--vllm-open", default=str(VLLM_DIR / "raw" / "vllm_open.json"))
    ap.add_argument("--hf-open", default=str(VLLM_DIR / "raw" / "hf_open.json"))
    ap.add_argument("--vllm-review", default=str(VLLM_DIR / "raw" / "vllm_review.json"))
    ap.add_argument("--prompts-open", default=str(VLLM_DIR / "parity" / "prompts_open.json"))
    a = ap.parse_args()

    from tools.contract_sft import harness as H
    from tools.training_supervisor import reward_contract as RC

    prompts_open = {p["prompt_id"]: p for p in json.loads(Path(a.prompts_open).read_text(encoding="utf-8"))}
    gen_v = json.loads(Path(a.vllm_open).read_text(encoding="utf-8"))
    gen_h = json.loads(Path(a.hf_open).read_text(encoding="utf-8"))
    rows_v = {r["job_id"]: r for r in gen_v["rows"]}
    rows_h = {r["job_id"]: r for r in gen_h["rows"]}
    common = sorted(set(rows_v) & set(rows_h))
    print(f"[score_partial] vllm rows={len(rows_v)} hf rows={len(rows_h)} common={len(common)}", flush=True)
    assert len(rows_v) == 300 and gen_v.get("complete"), "vllm_open must be the complete 300-row file"
    assert len(common) == len(rows_h) and common, "HF rows must be a subset of vLLM job_ids"

    rep: dict = {"generated": time.strftime("%Y-%m-%dT%H:%M:%S"),
                 "scope": "REDUCED (operator 2026-10-01): HF baseline stopped at "
                 f"{len(rows_h)}/300 open rows; no HF reviews, no drift; no regeneration",
                 "vllm_open_file": a.vllm_open, "hf_open_file": a.hf_open}

    def items(rows, jids):
        return [{"id": j, "text": rows[j]["text"],
                 "scenario": prompts_open[rows[j]["prompt_id"]]["scenario"]} for j in jids]

    # 1. all 300 vLLM opening plans
    t0 = time.time()
    per_v = H.validate(items(rows_v, sorted(rows_v)))
    rep["vllm_open_all300"] = {"summary": H.summarize(per_v),
                               "hit_token_cap": sum(1 for j in sorted(rows_v) if rows_v[j]["hit_token_cap"]),
                               "validate_wall_s": round(time.time() - t0, 1)}
    # 2. common-job apples-to-apples (112)
    res = {}
    for tag, rows in (("vllm", rows_v), ("hf", rows_h)):
        t0 = time.time()
        per = H.validate(items(rows, common))
        res[tag] = {"summary": H.summarize(per), "wall_validate_s": round(time.time() - t0, 1)}
    v_rate = res["vllm"]["summary"]["strict_first_pass"]["rate"]
    h_rate = res["hf"]["summary"]["strict_first_pass"]["rate"]
    fields = ["P1_FIX_area", "P1_FLANK_classes", "FIX_vs"]
    dists = {tag: {f: dist(dec_fields(rows[j]["text"])[f] for j in common) for f in fields}
             for tag, rows in (("vllm", rows_v), ("hf", rows_h))}
    tvs = {f: tv_distance(dists["vllm"][f], dists["hf"][f]) for f in fields}
    rep["opening_common112"] = {
        "n_common_jobs": len(common),
        "vllm_strict_first_pass": res["vllm"]["summary"]["strict_first_pass"],
        "hf_strict_first_pass": res["hf"]["summary"]["strict_first_pass"],
        "delta_pp": round((v_rate - h_rate) * 100, 2),
        "gate_reference_vllm_ge_hf_minus_3pp": bool(v_rate >= h_rate - 0.03),
        "decision_fields": {"distributions": dists, "tv_distance": tvs,
                            "gate_reference_each_le_0.15": bool(all(v <= 0.15 for v in tvs.values()))}}

    # 3. reviews: 88 vLLM vs RECORDED HF review raws (rl_vs_utility_v0 captures)
    gen_vr = json.loads(Path(a.vllm_review).read_text(encoding="utf-8"))
    assert gen_vr.get("complete") and len(gen_vr["rows"]) == 88
    hf_raws = []
    for f in sorted(glob.glob(str(RLV / "*" / "calls.jsonl"))):
        for line in open(f, encoding="utf-8"):
            try:
                r = json.loads(line)
            except ValueError:
                continue
            if r.get("request") == "VICTORY_REVIEW" and r.get("raw"):
                hf_raws.append(r["raw"])

    def rev_stats(texts):
        parses, decs = [], []
        for t in texts:
            try:
                doc = json.loads(t.strip())
                ok = isinstance(doc, dict)
            except ValueError:
                ok, doc = False, None
            parses.append(ok)
            if ok:
                decs.append(str(doc.get("decision")))
        return {"n": len(texts), "parse_rate": round(sum(parses) / len(parses), 4) if parses else None,
                "decisions": dist(decs)}

    v_rev = rev_stats([r["text"] for r in gen_vr["rows"]])
    h_rev = rev_stats(hf_raws)
    rep["reviews"] = {
        "vllm_88": v_rev, "recorded_hf_captures": {**h_rev, "n": len(hf_raws)},
        "gate_reference_vllm_parse_ge_hf": bool(v_rev["parse_rate"] >= (h_rev["parse_rate"] or 0)),
        "note": "recorded HF reviews are live-capture raws (different prompts), not the 11 parity prompts"}

    rep["verdict_reference"] = {
        "opening_strict_ge_hf_minus_3pp": rep["opening_common112"]["gate_reference_vllm_ge_hf_minus_3pp"],
        "opening_decision_tv_le_0.15": rep["opening_common112"]["decision_fields"]["gate_reference_each_le_0.15"],
        "reviews_parse_ge_recorded_hf": rep["reviews"]["gate_reference_vllm_parse_ge_hf"]}
    Path(a.out).write_text(json.dumps(rep, indent=1), encoding="utf-8")
    print(json.dumps({"vllm300_strict": rep["vllm_open_all300"]["summary"]["strict_first_pass"],
                      "common112": {"vllm": v_rate, "hf": h_rate,
                                    "delta_pp": rep["opening_common112"]["delta_pp"]},
                      "tv": tvs, "reviews": {"vllm": v_rev["parse_rate"], "hf_recorded": h_rev["parse_rate"]}}, indent=1))
    print(f"[score_partial] wrote {a.out}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
