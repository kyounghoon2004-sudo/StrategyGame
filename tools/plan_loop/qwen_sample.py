"""Qwen-sampled candidates for the same-state branches (2026-10-12): the plausible alternatives the policy itself would
give at the situation (temperature 0.8, no thinking), validated against the state (own units / live targets / verbs),
deduplicated, the recorded answer kept as the control.  Output = branch jobs for tools.synth_sft_v2.branch (after=live).

  python -m tools.plan_loop.qwen_sample --situations <qwen_cont jobs.situations.json> --n 8 --keep 4 --rollouts 4 --out <jobs.jsonl>
"""
from __future__ import annotations

import argparse
import concurrent.futures
import hashlib
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
EV = ROOT / "artifacts" / "brain_pipeline_v1" / "plan_loop_v1" / "evaldata_v1"
sys.path.insert(0, str(EV))
sys.path.insert(0, str(ROOT))


def main():
    from tools.plan_search.cloud_brain import local_command
    ap = argparse.ArgumentParser()
    ap.add_argument("--situations", required=True)
    ap.add_argument("--n", type=int, default=8)
    ap.add_argument("--keep", type=int, default=4)
    ap.add_argument("--rollouts", type=int, default=4)
    ap.add_argument("--temperature", type=float, default=0.8)
    ap.add_argument("--url", default="http://127.0.0.1:8000/v1/chat/completions")
    ap.add_argument("--out", required=True)
    a = ap.parse_args()
    from variants import legal  # evaldata_v1/variants.py (answer legality against the state)

    spec = {}
    for line in (EV / "branches.jsonl").read_text(encoding="utf-8").splitlines():
        b = json.loads(line)
        spec[b["id"]] = b
    sits = [s["situation"] for s in json.loads(Path(a.situations).read_text(encoding="utf-8"))]
    jobs_out, report = [], []

    def sample(sit):
        req = json.loads((EV / "source_requests" / ("%s.json" % sit)).read_text(encoding="utf-8"))
        outs = []
        for _ in range(a.n):
            try:
                text, _m = local_command(req["messages"], url=a.url, model="policy", no_think=True,
                                         answer_tokens=2000, temperature=a.temperature, timeout_s=600)
            except Exception as e:  # noqa: BLE001
                text = ""
            outs.append(text or "")
        return sit, req, outs

    with concurrent.futures.ThreadPoolExecutor(8) as ex:
        results = list(ex.map(sample, sits))
    for sit, req, outs in results:
        rec_id = "%s_recorded" % sit
        if rec_id not in spec:
            continue
        rec = spec[rec_id]
        seen = {hashlib.sha256(rec["answer"].encode()).hexdigest()}
        kept, bad = [], 0
        for t in outs:
            try:
                obj = legal(t, req["state"], req["messages"][0]["content"])
            except Exception:  # noqa: BLE001
                bad += 1
                continue
            if not obj["orders"]:
                continue
            canon = json.dumps(obj, sort_keys=True)
            h = hashlib.sha256(canon.encode()).hexdigest()
            if h in seen:
                continue
            seen.add(h)
            kept.append(json.dumps(obj, ensure_ascii=False))
            if len(kept) >= a.keep:
                break
        cands = [(rec_id, rec, "recorded")] + [("%s_qs%d" % (sit, i), dict(rec, id="%s_qs%d" % (sit, i), answer=t,
                                                                          variant="qwen_sample", provenance="qwen_sample"), "qwen_sample")
                                                for i, t in enumerate(kept)]
        for cid, b, var in cands:
            for r in range(a.rollouts):
                bb = dict(b)
                bb["id"] = "%s__q%d" % (cid, r)
                bb["after"] = "live"
                bb["parent_id"] = cid
                bb["variant"] = var
                bb["situation"] = sit
                jobs_out.append(bb)
        report.append({"situation": sit, "samples": len(outs), "illegal": bad, "kept": len(kept)})
    Path(a.out).write_text("".join(json.dumps(b) + "\n" for b in jobs_out), encoding="utf-8")
    Path(a.out).with_suffix(".sample_report.json").write_text(json.dumps(report, indent=1), encoding="utf-8")
    print("situations %d, branches %d, kept per situation %s" % (len(report), len(jobs_out),
          sorted({r["kept"] for r in report})))


if __name__ == "__main__":
    main()
