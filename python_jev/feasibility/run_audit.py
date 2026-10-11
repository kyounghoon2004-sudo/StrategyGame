"""Run the Part A failure audit and write artifacts/jev_feasibility_v0/failure_audit/.

Usage (from the project root):
    python -m python_jev.feasibility.run_audit
"""

from __future__ import annotations

import hashlib
import json
import os

import torch

from python_jev.feasibility.audit import (
    AUDIT_VERSION,
    audit_closed_loop,
    audit_collection,
    audit_exam,
    summarize,
    write_jsonl,
)
from python_jev.model import JevPolicyV0
from python_jev.training.checkpoint import load_checkpoint
from python_jev.training.dataset_gen import ood_plan, split_plan

CHECKPOINT = os.path.join("artifacts", "jev_training_v0", "checkpoints", "seed43.pt")
OUT_DIR = os.path.join("artifacts", "jev_feasibility_v0", "failure_audit")


def _device() -> str:
    # F0 runs inference on CPU by default: this workstation's GPU is shared
    # with Unreal/Godot editors, under which CUDA device transfers have been
    # observed to wedge indefinitely. Override with F0_DEVICE=cuda.
    import os as _os

    want = _os.environ.get("F0_DEVICE", "cpu")
    if want == "cuda" and torch.cuda.is_available():
        return "cuda"
    return "cpu"


def main(out_dir: str = OUT_DIR, checkpoint: str = CHECKPOINT) -> dict:
    device = _device()
    print(f"device={device} checkpoint={checkpoint}", flush=True)
    model = JevPolicyV0().to(device)
    meta = load_checkpoint(checkpoint, model)
    model.eval()
    print(f"loaded {meta.get('model_version')} seed={meta.get('seed')} "
          f"epoch={meta.get('best_epoch')}", flush=True)

    plan = split_plan(192)
    iid_jobs = [(plan[i]["split"], i, plan[i]["profile"], False) for i in range(192)]
    ood = ood_plan(48)
    ood_jobs = [(ood[i]["split"], i, ood[i]["profile"], True) for i in range(48)]
    bench_jobs = ([("test", i, plan[i]["profile"], False)
                   for i in sorted(j for j in range(192) if plan[j]["split"] == "test")[:12]]
                  + [("generalization_test", i, ood[i]["profile"], True)
                     for i in list(range(0, 48, 4))[:12]])

    print("source 1/4: IID collection replay (192 scenarios)", flush=True)
    iid_rows = audit_collection(model, device, iid_jobs, "collection_iid")
    print(f"  rows={len(iid_rows)}", flush=True)
    print("source 2/4: OOD collection replay (48 scenarios)", flush=True)
    ood_rows = audit_collection(model, device, ood_jobs, "collection_ood")
    print(f"  rows={len(ood_rows)}", flush=True)
    print("source 3/4: tactical exam (60 cases)", flush=True)
    exam_rows = audit_exam(model, device)
    print(f"  rows={len(exam_rows)}", flush=True)
    print("source 4/4: closed-loop trajectories (24 scenarios x 3 baselines x swap)",
          flush=True)
    loop_rows = audit_closed_loop(model, device, bench_jobs)
    print(f"  rows={len(loop_rows)}", flush=True)

    all_rows = iid_rows + ood_rows + exam_rows + loop_rows
    summary = summarize(all_rows)
    summary["checkpoint"] = os.path.abspath(checkpoint)
    summary["by_source_detail"] = {s: summarize([r for r in all_rows if r["source"] == s])
                                   for s in sorted({r["source"] for r in all_rows})}

    # Envelope-parity corpus: behavior fingerprint for the later executor
    # refactor (Part B must reproduce these digests bit-identically).
    parity = hashlib.sha256("\n".join(
        sorted(f"{r['source']}|{r['decision_key']}|{r['skill_class']}|{r['slot']}|"
               f"{r['envelope_digest']}" for r in all_rows)).encode("utf-8")).hexdigest()
    summary["envelope_parity_sha256"] = parity

    os.makedirs(out_dir, exist_ok=True)
    write_jsonl(os.path.join(out_dir, "audit_rows.jsonl"), all_rows)
    with open(os.path.join(out_dir, "audit_summary.json"), "w") as f:
        json.dump(summary, f, indent=1, sort_keys=True)
    print(f"wrote {len(all_rows)} rows -> {out_dir} parity={parity[:16]}...", flush=True)
    print(json.dumps({k: summary[k] for k in (
        "rows", "mask_legal_rows", "mask_legal_by_bucket", "mask_legal_invalid_rate",
        "selected_invalid_rate", "nonsuccess_by_failure_class")}, indent=1))
    return summary


if __name__ == "__main__":
    main()
