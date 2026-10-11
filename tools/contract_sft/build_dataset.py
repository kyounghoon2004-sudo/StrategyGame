"""Build the versioned CONTRACT_SFT_V1 SFT dataset (CPU + Godot only).

Sources (all real project artifacts):
  rl_rollout        marathon rollout completions (prompt A RED), iter 1..117
  rl_eval           marathon eval completions, candidate AND champion,
                    RED (prompt A) and BLUE (eval mirror), iter 1..116
  sft_gen_T0086     T0086 raw samples on the 128 train_gen scenarios
Every ORIGINAL is validated through the production path first (failure code
kept as provenance). Every candidate target is: repaired (repair.py) ->
production-validated (tools/contract_sft_harness.gd) -> must be
strict_first_pass (production PASS, raw text is exactly one JSON object)
AND plan_coherent (reward_contract P1-P11) AND <= TARGET_MAX_TOKENS.
Grades: A original already valid (target = original text verbatim)
        B format/contract repairs only (strategy structure untouched)
        C repair dropped/reassigned missions/phases or closed a truncated
          plan -> EXCLUDED (would shift strategy, not just the contract)

  python -m tools.contract_sft.build_dataset
"""
from __future__ import annotations

import collections
import glob
import hashlib
import json
import os
import random
import re
from pathlib import Path
from typing import Any, Dict, List

from tools.contract_sft import harness as H
from tools.contract_sft import repair as RP

PROJ = Path(r"D:\Game development\Demon slayer\StrategyGame")
ITERS = PROJ / "artifacts" / "training_marathon_v1" / "iterations"
ROOT = PROJ / "artifacts" / "contract_sft_v1"
DATASET_VERSION = "CONTRACT_SFT_V1_DATASET_R1"  # R2 via --round 2
TARGET_MAX_TOKENS = 1100
STRUCTURAL = ("drop_empty_mission", "drop_empty_phase", "trim_missions", "trim_phases",
              "no_phases_left", "P6_dedupe_units", "autoclose_truncated")
CAPS = {"A_RED": 130, "A_BLUE": 70}
ROUND2 = {"version": "CONTRACT_SFT_V1_DATASET_R2", "caps": {"A_RED": 90, "A_BLUE": 50},
          "prompt_sets": ("train_gen", "train_gen2"), "dir": "dataset_r2"}
DEV_PROMPTS = 12
SEED = 20260926
GEN_GLOB = "train_gen_*.json"


def sha(t: str) -> str:
    return hashlib.sha256(t.encode("utf-8")).hexdigest()


def _policy_of(adapter_path) -> str:
    m = re.search(r"candidate_(T\d{4})", str(adapter_path or ""))
    return m.group(1) if m else "B0"


def collect_history(prompts: Dict[str, Any]) -> List[Dict[str, Any]]:
    items, seen = [], set()
    for d in sorted(ITERS.glob("iteration_*")):
        it = int(d.name.split("_")[1])
        man = d / "rollout" / "rollout_manifest.json"
        pol = "?"
        if man.exists():
            try:
                pol = _policy_of(json.loads(man.read_text(encoding="utf-8")).get("champion_adapter"))
            except ValueError:
                pass
        for f in sorted((d / "rollout").glob("group*_s*.txt")):
            t = f.read_text(encoding="utf-8")
            if sha(t) in seen:
                continue
            seen.add(sha(t))
            items.append({"hid": f"rl_it{it:03d}_{f.stem}", "text": t, "prompt_id": "A_RED",
                          "source": {"kind": "rl_rollout", "path": str(f.relative_to(PROJ)),
                                     "iteration": it, "policy": pol}})
        for f in sorted((d / "eval").glob("T*_*_*.txt")) + sorted((d / "eval").glob("B0_*_*.txt")):
            m = re.match(r"(T\d{4}|B0)_(RED|BLUE)_(\d+)$", f.stem)
            if not m:
                continue
            t = f.read_text(encoding="utf-8")
            if sha(t) in seen:
                continue
            seen.add(sha(t))
            items.append({"hid": f"ev_it{it:03d}_{f.stem}", "text": t, "prompt_id": f"A_{m.group(2)}",
                          "source": {"kind": "rl_eval", "path": str(f.relative_to(PROJ)),
                                     "iteration": it, "policy": m.group(1)}})
    return items


def collect_gen(prompts: Dict[str, Any]) -> List[Dict[str, Any]]:
    items = []
    for f in sorted((ROOT / "gen").glob(GEN_GLOB)):
        g = json.loads(f.read_text(encoding="utf-8"))
        for r in g["rows"]:
            items.append({"hid": f"gen_{r['job_id']}", "text": r["text"], "prompt_id": r["prompt_id"],
                          "gen_tokens": r["gen_tokens"], "hit_token_cap": r["hit_token_cap"],
                          "source": {"kind": f"sft_gen_{g['label']}", "path": str(f.relative_to(PROJ)),
                                     "policy": g["label"], "seed": r["seed"],
                                     "batch_seed": r["batch_seed"]}})
    return items


def process(items: List[Dict[str, Any]], prompts: Dict[str, Any], tok) -> List[Dict[str, Any]]:
    orig = H.validate([{"id": x["hid"], "text": x["text"], "scenario": prompts[x["prompt_id"]]["scenario"]}
                       for x in items])
    cand = []
    for x, o in zip(items, orig):
        x["original"] = {"category": o["category"], "strict_first_pass": o["strict_first_pass"],
                         "plan_coherent": o["plan_coherent"], "production_pass": o["production_pass"],
                         "code": o["fault"] or o["validator_code"] or o["parse_code"],
                         "detail": (o["fault_detail"] or o["validator_detail"] or o["parse_detail"])[:220],
                         "coherence_violations": o["coherence_violations"]}
        if o["strict_first_pass"] and o["plan_coherent"]:
            x["target"], x["repair_notes"], x["grade"] = x["text"], [], "A"
        else:
            t, notes = RP.repair(x["text"], prompts[x["prompt_id"]]["roster"])
            x["target"], x["repair_notes"] = t, notes
            x["grade"] = None if t is None else ("C" if any(n.split(":")[0].split("@")[0] in STRUCTURAL
                                                            for n in notes) else "B")
        if x["target"] is not None:
            cand.append(x)
    ver = H.validate([{"id": x["hid"], "text": x["target"], "scenario": prompts[x["prompt_id"]]["scenario"]}
                      for x in cand])
    for x, v in zip(cand, ver):
        x["validation"] = {"production_pass": v["production_pass"], "strict_first_pass": v["strict_first_pass"],
                           "plan_coherent": v["plan_coherent"], "category": v["category"],
                           "coherence_violations": v["coherence_violations"]}
        x["target_tokens"] = len(tok(x["target"], add_special_tokens=False)["input_ids"])
        x["eligible"] = bool(v["strict_first_pass"] and v["plan_coherent"] and x["grade"] in ("A", "B")
                             and x["target_tokens"] <= TARGET_MAX_TOKENS)
    return items


def select(items: List[Dict[str, Any]]) -> List[Dict[str, Any]]:
    rng = random.Random(SEED)
    ok = [x for x in items if x.get("eligible")]
    by_sha: Dict[str, Dict[str, Any]] = {}
    for x in ok:  # target dedupe (first occurrence wins, deterministic order)
        by_sha.setdefault(sha(x["prompt_id"] + "\x00" + x["target"]), x)
    ok = list(by_sha.values())
    out = []
    for pid, cap in CAPS.items():
        pool = [x for x in ok if x["prompt_id"] == pid]
        # Stratify by ORIGINAL failure category so rare failure modes are kept
        # (not just easy historical rows): round-robin over categories.
        buckets = collections.defaultdict(list)
        for x in pool:
            buckets[x["original"]["category"]].append(x)
        for b in buckets.values():
            rng.shuffle(b)
        keys = sorted(buckets, key=lambda k: (len(buckets[k]), k))
        picked = []
        while len(picked) < cap and any(buckets[k] for k in keys):
            for k in keys:
                if buckets[k] and len(picked) < cap:
                    picked.append(buckets[k].pop())
        out += picked
    out += [x for x in ok if not x["prompt_id"].startswith("A_")]
    return out


def main() -> int:
    global DATASET_VERSION, CAPS, GEN_GLOB
    import argparse
    ap = argparse.ArgumentParser()
    ap.add_argument("--round", type=int, default=1, choices=[1, 2])
    rnd = ap.parse_args().round
    prompt_sets, ds_name = ("train_gen",), "dataset"
    GEN_GLOB = "train_gen_*.json"
    if rnd == 2:
        DATASET_VERSION, CAPS = ROUND2["version"], ROUND2["caps"]
        prompt_sets, ds_name, GEN_GLOB = ROUND2["prompt_sets"], ROUND2["dir"], "train_gen*.json"
    from transformers import AutoTokenizer
    tok = AutoTokenizer.from_pretrained(r"D:\StrategyAI\models\Qwen3-8B")
    prompts: Dict[str, Any] = {}
    for name in prompt_sets + ("rl_A", "heldout"):
        for p in json.loads((ROOT / "prompts" / f"{name}.json").read_text(encoding="utf-8")):
            prompts[p["prompt_id"]] = p
    held_ids = {p for p, v in prompts.items() if v["split"] == "heldout"}
    items = collect_history(prompts) + collect_gen(prompts)
    assert not any(x["prompt_id"] in held_ids for x in items), "held-out prompt leaked into sources"
    print(f"sources: {collections.Counter(x['source']['kind'] for x in items)}")
    items = process(items, prompts, tok)
    rows = select(items)
    rng = random.Random(SEED)
    gen_pids = sorted({x["prompt_id"] for x in rows if not x["prompt_id"].startswith("A_")})
    dev_pids = set(rng.sample(gen_pids, min(DEV_PROMPTS, len(gen_pids))))
    out_rows = []
    for x in rows:
        out_rows.append({"row_id": x["hid"], "split": "dev" if x["prompt_id"] in dev_pids else "train",
                         "prompt_id": x["prompt_id"], "prompt_sha256": prompts[x["prompt_id"]]["sha256"],
                         "target": x["target"], "target_sha256": sha(x["target"]),
                         "target_tokens": x["target_tokens"], "grade": x["grade"], "source": x["source"],
                         "original": x["original"], "repair_notes": x["repair_notes"],
                         "validation": x["validation"]})
    out_rows.sort(key=lambda r: r["row_id"])
    dsdir = ROOT / ds_name
    dsdir.mkdir(parents=True, exist_ok=True)
    with open(dsdir / "sft_rows.jsonl", "w", encoding="utf-8") as f:
        for r in out_rows:
            f.write(json.dumps(r, ensure_ascii=False) + "\n")
    # Full audit trail of every source item (including rejected ones).
    with open(dsdir / "source_audit.jsonl", "w", encoding="utf-8") as f:
        for x in items:
            f.write(json.dumps({k: x.get(k) for k in ("hid", "prompt_id", "source", "original", "grade",
                                                     "repair_notes", "validation", "target_tokens",
                                                     "eligible")}, ensure_ascii=False) + "\n")
    tr = [r for r in out_rows if r["split"] == "train"]
    stats = {
        "version": DATASET_VERSION,
        "sources_total": len(items),
        "sources_by_kind": dict(collections.Counter(x["source"]["kind"] for x in items)),
        "original_category_all_sources": dict(collections.Counter(x["original"]["category"] for x in items)
                                              .most_common()),
        "original_strict_first_pass_rate_all_sources": round(
            sum(1 for x in items if x["original"]["strict_first_pass"]) / len(items), 4),
        "eligible_candidates": sum(1 for x in items if x.get("eligible")),
        "grade_counts_all": dict(collections.Counter(str(x.get("grade")) for x in items)),
        "excluded_grade_C": sum(1 for x in items if x.get("grade") == "C"),
        "rows": len(out_rows), "train_rows": len(tr), "dev_rows": len(out_rows) - len(tr),
        "rows_by_prompt_group": dict(collections.Counter(
            ("A_RED" if r["prompt_id"] == "A_RED" else "A_BLUE" if r["prompt_id"] == "A_BLUE"
             else "generated") for r in out_rows)),
        "distinct_prompts": len({r["prompt_id"] for r in out_rows}),
        "rows_by_grade": dict(collections.Counter(r["grade"] for r in out_rows)),
        "rows_by_original_category": dict(collections.Counter(r["original"]["category"] for r in out_rows)
                                          .most_common()),
        "rows_fixing_reserve_mission": sum(1 for r in out_rows if any(n.startswith("P7_")
                                                                      for n in r["repair_notes"])),
        "repair_note_counts_in_rows": dict(collections.Counter(
            n.split(":")[0].split("@")[0] for r in out_rows for n in r["repair_notes"]).most_common()),
        "target_tokens": {"max": max(r["target_tokens"] for r in out_rows),
                          "mean": round(sum(r["target_tokens"] for r in out_rows) / len(out_rows), 1)},
        "all_targets_production_valid": all(r["validation"]["strict_first_pass"] and
                                            r["validation"]["plan_coherent"] for r in out_rows),
        "heldout_prompts_in_rows": sum(1 for r in out_rows if r["prompt_id"] in held_ids),
        "sft_rows_sha256": hashlib.sha256((dsdir / "sft_rows.jsonl").read_bytes()).hexdigest(),
    }
    (dsdir / "DATASET_MANIFEST.json").write_text(json.dumps(stats, indent=1), encoding="utf-8")
    print(json.dumps(stats, indent=1))
    assert stats["all_targets_production_valid"] and stats["heldout_prompts_in_rows"] == 0
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
