"""BRAIN_VLLM_PHASE1 — quality parity harness (NF4-HF vs vLLM FP8), S0B adapter.

  python -m tools.brain_vllm.parity jobs  --out-dir artifacts/brain_pipeline_v1/vllm/parity
  python -m tools.brain_vllm.parity score --vllm-open <gen.json> --hf-open <gen.json>
         --vllm-review <gen.json> --hf-review <gen.json> --out <PARITY.json> [--drift <drift.json>]
         [--prompts-open <prompts_open.json>] [--prompts-review <prompts_review.json>]

Opening plans: >=150 DEV prompts (all s0b dev + first N s0c dev in file order),
2 samples each per backend; strict first-pass validity via
tools.contract_sft.harness.validate (production Godot INITIAL path);
gate: vLLM >= HF - 3 percentage points.
Decision fields (P1 FIX area, P1 FLANK prefer.classes, FIX vs): TV distance <= 0.15.

Reviews: every captured VICTORY_REVIEW prompt (rl_vs_utility_v0), 8 samples each;
JSON-object parse rate gate: vLLM >= HF; decision distribution reported side by side.

Never writes into corpus / capture artifact dirs.
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

S0B = ROOT / "artifacts" / "contextual_brain_s0b"
S0C = ROOT / "artifacts" / "contextual_brain_s0c_corpus"
RLV = ROOT / "artifacts" / "rl_vs_utility_v0"
VLLM_DIR = ROOT / "artifacts" / "brain_pipeline_v1" / "vllm"


def _rows(dir_: Path):
    return [json.loads(l) for l in open(dir_ / "sft_rows.jsonl", encoding="utf-8") if l.strip()]


def _norm(x):
    return "None" if x is None else str(x)


def dec_fields(text: str) -> dict:
    """P1 FIX area, P1 FLANK prefer.classes[0], FIX vs (corpus decisions() fields)."""
    try:
        doc = json.loads(text.strip())
        direct = isinstance(doc, dict)
    except ValueError:
        direct = False
    if not direct:
        return {"P1_FIX_area": "UNPARSEABLE", "P1_FLANK_classes": "UNPARSEABLE", "FIX_vs": "UNPARSEABLE"}
    ph = doc.get("phases") or []
    ms = ((ph[0] if ph and isinstance(ph[0], dict) else {}) or {}).get("missions") or []
    ms = [m for m in ms if isinstance(m, dict)]
    fix = next((m for m in ms if str(m.get("task", "")).upper() == "FIX"), ms[0] if ms else {})
    flank = next((m for m in ms if str(m.get("task", "")).upper() == "FLANK"), None)
    return {"P1_FIX_area": _norm(fix.get("area")),
            "P1_FLANK_classes": _norm(((flank or {}).get("prefer") or {}).get("classes", [None])[0]) if flank else "None",
            "FIX_vs": _norm(fix.get("vs"))}


def tv_distance(p: dict, q: dict) -> float:
    cats = set(p) | set(q)
    tp = sum(p.values()) or 1
    tq = sum(q.values()) or 1
    return round(0.5 * sum(abs(p.get(c, 0) / tp - q.get(c, 0) / tq) for c in sorted(cats)), 4)


def dist(values) -> dict:
    d = {}
    for v in values:
        d[v] = d.get(v, 0) + 1
    return dict(sorted(d.items(), key=lambda kv: -kv[1]))


def cmd_jobs(a) -> int:
    out_dir = Path(a.out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)
    specs = json.loads((VLLM_DIR / "specs_replay.json").read_text(encoding="utf-8"))
    prompts_open = []
    for name, dir_, pfile, n in (("s0b", S0B, "s0b_prompts.json", a.n_s0b),
                                 ("s0c", S0C, "s0c_prompts.json", a.n_s0c)):
        dev = [r for r in _rows(dir_) if r["split"] == "dev"][:n]
        pm = {p["prompt_id"]: p["messages"] for p in
              json.loads((dir_ / pfile).read_text(encoding="utf-8"))}
        for r in dev:
            pid = r["prompt_id"]
            prompts_open.append({"prompt_id": pid, "corpus": name, "messages": pm[pid],
                                 "scenario": specs["corpora"][name][pid]})
        print(f"[parity] {name}: {len(dev)} dev prompts")
    jobs_open = []
    for i, p in enumerate(prompts_open):
        for k in range(a.samples):
            jobs_open.append({"job_id": f"op_{p['prompt_id']}_k{k}", "prompt_id": p["prompt_id"],
                              "messages": p["messages"], "seed": 900000 + i * a.samples + k})
    review_prompts = []
    for f in sorted(RLV.glob("*/calls.jsonl")):
        stem = f.parent.name
        for j, line in enumerate(open(f, encoding="utf-8")):
            r = json.loads(line)
            if r.get("request") == "VICTORY_REVIEW":
                review_prompts.append({"prompt_id": f"rv_{stem}_{j}", "messages": r["messages"],
                                       "tag": r.get("tag"), "window": r.get("window"),
                                       "turn": r.get("turn"), "trigger": r.get("trigger")})
    jobs_review = []
    for i, p in enumerate(review_prompts):
        for k in range(a.review_samples):
            jobs_review.append({"job_id": f"rv_{i:02d}_k{k}", "prompt_id": p["prompt_id"],
                                "messages": p["messages"], "seed": 950000 + i * a.review_samples + k})
    (out_dir / "prompts_open.json").write_text(json.dumps(prompts_open), encoding="utf-8")
    (out_dir / "jobs_open.json").write_text(json.dumps(jobs_open), encoding="utf-8")
    (out_dir / "prompts_review.json").write_text(json.dumps(review_prompts), encoding="utf-8")
    (out_dir / "jobs_review.json").write_text(json.dumps(jobs_review), encoding="utf-8")
    drift_jobs = [{"job_id": f"drift_{i:02d}", "prompt_id": p["prompt_id"], "messages": p["messages"],
                   "seed": 990000 + i} for i, p in enumerate(prompts_open[: a.n_drift])]
    (out_dir / "drift_jobs.json").write_text(json.dumps(drift_jobs), encoding="utf-8")
    print(f"[parity] wrote {out_dir}: open prompts={len(prompts_open)} jobs={len(jobs_open)}; "
          f"review prompts={len(review_prompts)} jobs={len(jobs_review)}; drift jobs={len(drift_jobs)}")
    return 0


def _load_gen(p: str):
    g = json.loads(Path(p).read_text(encoding="utf-8"))
    assert g.get("complete", False), f"{p}: incomplete"
    return g, {r["job_id"]: r for r in g["rows"]}


def cmd_score(a) -> int:
    from tools.contract_sft import harness as H
    from tools.training_supervisor import reward_contract as RC

    out_dir = Path(a.prompts_open).parent if a.prompts_open else VLLM_DIR / "parity"
    prompts_open = {p["prompt_id"]: p for p in json.loads(Path(a.prompts_open).read_text(encoding="utf-8"))}
    prompts_review = {p["prompt_id"]: p for p in json.loads(Path(a.prompts_review).read_text(encoding="utf-8"))}
    gen_v, rows_v = _load_gen(a.vllm_open)
    gen_h, rows_h = _load_gen(a.hf_open)
    assert set(rows_v) == set(rows_h), "job sets differ"
    order = [j["job_id"] for j in json.loads((out_dir / "jobs_open.json").read_text(encoding="utf-8"))]

    report = {"generated": time.strftime("%Y-%m-%dT%H:%M:%S"),
              "opening_plans": {}, "reviews": {}}

    # ---------------- opening plans
    res = {}
    for tag, rows in (("vllm", rows_v), ("hf", rows_h)):
        items = [{"id": jid, "text": rows[jid]["text"],
                  "scenario": prompts_open[rows[jid]["prompt_id"]]["scenario"]} for jid in order]
        t0 = time.time()
        per = H.validate(items)  # production Godot INITIAL path, batched 150
        s = H.summarize(per)
        res[tag] = {"summary": s, "per": per, "wall_validate_s": round(time.time() - t0, 1),
                    "gen": {"label": (gen_v if tag == "vllm" else gen_h)["label"],
                            "backend": (gen_v if tag == "vllm" else gen_h).get("backend", "hf_nf4"),
                            "load_s": (gen_v if tag == "vllm" else gen_h)["load_s"],
                            "memory": (gen_v if tag == "vllm" else gen_h)["memory"]}}
        hit = sum(1 for r in per if rows[r["id"]]["hit_token_cap"])
        res[tag]["hit_token_cap"] = hit
    v_rate = res["vllm"]["summary"]["strict_first_pass"]["rate"]
    h_rate = res["hf"]["summary"]["strict_first_pass"]["rate"]
    gate_strict = v_rate >= h_rate - 0.03

    fields = ["P1_FIX_area", "P1_FLANK_classes", "FIX_vs"]
    dists = {tag: {f: dist(dec_fields(rows[jid]["text"])[f] for jid in order) for f in fields}
             for tag, rows in (("vllm", rows_v), ("hf", rows_h))}
    tvs = {f: tv_distance(dists["vllm"][f], dists["hf"][f]) for f in fields}
    gate_tv = all(v <= 0.15 for v in tvs.values())

    report["opening_plans"] = {
        "n_prompts": len(prompts_open), "samples_per_prompt": len(order) // max(1, len(prompts_open)),
        "n_samples_per_backend": len(order),
        "corpora": {"s0b_dev": sum(1 for p in prompts_open.values() if p["corpus"] == "s0b"),
                    "s0c_dev": sum(1 for p in prompts_open.values() if p["corpus"] == "s0c")},
        "vllm": {"strict_first_pass": res["vllm"]["summary"]["strict_first_pass"],
                 "json_extractable": res["vllm"]["summary"]["json_extractable"],
                 "no_extra_text": res["vllm"]["summary"]["no_extra_text"],
                 "validator_pass": res["vllm"]["summary"]["validator_pass"],
                 "plan_coherent": res["vllm"]["summary"]["plan_coherent"],
                 "categories": res["vllm"]["summary"]["categories"], "hit_token_cap": res["vllm"]["hit_token_cap"],
                 "gen": res["vllm"]["gen"], "validate_wall_s": res["vllm"]["wall_validate_s"]},
        "hf": {"strict_first_pass": res["hf"]["summary"]["strict_first_pass"],
               "json_extractable": res["hf"]["summary"]["json_extractable"],
               "no_extra_text": res["hf"]["summary"]["no_extra_text"],
               "validator_pass": res["hf"]["summary"]["validator_pass"],
               "plan_coherent": res["hf"]["summary"]["plan_coherent"],
               "categories": res["hf"]["summary"]["categories"], "hit_token_cap": res["hf"]["hit_token_cap"],
               "gen": res["hf"]["gen"], "validate_wall_s": res["hf"]["wall_validate_s"]},
        "gate_strict_first_pass": {"vllm": v_rate, "hf": h_rate, "delta_pp": round((v_rate - h_rate) * 100, 2),
                                   "required": "vllm >= hf - 3pp", "pass": bool(gate_strict)},
        "decision_fields": {"distributions": dists, "tv_distance": tvs,
                            "required": "each <= 0.15", "pass": bool(gate_tv)}}
    for tag in ("vllm", "hf"):
        Path(out_dir / f"scored_open_{tag}.jsonl").write_text(
            "\n".join(json.dumps(r, ensure_ascii=False) for r in res[tag]["per"]) + "\n", encoding="utf-8")

    # ---------------- reviews
    gen_vr, rows_vr = _load_gen(a.vllm_review)
    gen_hr, rows_hr = _load_gen(a.hf_review)
    assert set(rows_vr) == set(rows_hr)
    rev = {}
    for tag, rows in (("vllm", rows_vr), ("hf", rows_hr)):
        parses, decs = [], []
        for jid in sorted(rows):
            doc, dups, err = RC._parse_direct(rows[jid]["text"])
            ok = isinstance(doc, dict)
            parses.append(ok)
            if ok:
                decs.append(str(doc.get("decision")))
        rev[tag] = {"parse_rate": round(sum(parses) / len(parses), 4), "n_samples": len(parses),
                    "decisions": dist(decs) if decs else {},
                    "decisions_parsed_only": True}
    gate_rev = rev["vllm"]["parse_rate"] >= rev["hf"]["parse_rate"]
    report["reviews"] = {
        "n_prompts": len(prompts_review), "samples_per_prompt": len(rows_vr) // max(1, len(prompts_review)),
        "vllm": {**rev["vllm"], "gen": {"label": gen_vr["label"], "backend": gen_vr.get("backend", "hf_nf4")}},
        "hf": {**rev["hf"], "gen": {"label": gen_hr["label"], "backend": gen_hr.get("backend", "hf_nf4")}},
        "gate_parse_rate": {"vllm": rev["vllm"]["parse_rate"], "hf": rev["hf"]["parse_rate"],
                            "required": "vllm >= hf", "pass": bool(gate_rev)}}

    if a.drift:
        report["drift"] = json.loads(Path(a.drift).read_text(encoding="utf-8"))

    gates = {"opening_strict_first_pass": bool(gate_strict), "opening_decision_tv": bool(gate_tv),
             "reviews_parse_rate": bool(gate_rev)}
    report["gates_all_pass"] = all(gates.values())
    report["gates"] = gates
    p = Path(a.out)
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_text(json.dumps(report, indent=1), encoding="utf-8")
    print(json.dumps({"gates": gates, "strict": report["opening_plans"]["gate_strict_first_pass"],
                      "tv": tvs, "reviews": report["reviews"]["gate_parse_rate"]}, indent=1))
    print(f"[parity] wrote {p}")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)
    j = sub.add_parser("jobs")
    j.add_argument("--out-dir", default=str(VLLM_DIR / "parity"))
    j.add_argument("--n-s0b", type=int, default=84)
    j.add_argument("--n-s0c", type=int, default=66)
    j.add_argument("--samples", type=int, default=2)
    j.add_argument("--review-samples", type=int, default=8)
    j.add_argument("--n-drift", type=int, default=40)
    s = sub.add_parser("score")
    s.add_argument("--vllm-open", required=True)
    s.add_argument("--hf-open", required=True)
    s.add_argument("--vllm-review", required=True)
    s.add_argument("--hf-review", required=True)
    s.add_argument("--out", default=str(VLLM_DIR / "PARITY.json"))
    s.add_argument("--drift", default="")
    s.add_argument("--prompts-open", default=str(VLLM_DIR / "parity" / "prompts_open.json"))
    s.add_argument("--prompts-review", default=str(VLLM_DIR / "parity" / "prompts_review.json"))
    a = ap.parse_args()
    return cmd_jobs(a) if a.cmd == "jobs" else cmd_score(a)


if __name__ == "__main__":
    raise SystemExit(main())
