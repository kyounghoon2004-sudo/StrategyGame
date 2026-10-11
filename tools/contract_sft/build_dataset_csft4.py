"""CSFT4 dataset: CSFT3c (preserved unchanged) + Round-4 no_cav rows.

  python -m tools.contract_sft.build_dataset_csft4

Round-4 source: CSFT3 on-policy samples on train_gen4 (128 NEW no-cavalry
rosters, 96 RED / 32 BLUE) -- the only remaining CSFT3 failure family.
Per sample: grade A = raw passes strict schema + full gate; grade B =
repair.py -> schema_strict.hoist -> strict schema clean -> full gate
(format/contract edits only; STRUCTURAL notes -> excluded). One remap copy
per accepted row (production rebuild of the remapped scenario, same gates).
Full gate = real Godot production strict first-pass, exactly one JSON object,
coherence P1-P11, whole-text friendly authorization, enemy ids visible or
enemy HQ_1, <= 1100 tokens.
"""
from __future__ import annotations

import collections
import hashlib
import json
import random
import re
from pathlib import Path

from tools.contract_sft import harness as H
from tools.contract_sft import repair as RP
from tools.contract_sft import scenarios as S
from tools.contract_sft import schema_strict as SS
from tools.contract_sft.augment_remap import make_map, remap_spec, sub
from tools.contract_sft.build_dataset import STRUCTURAL
from tools.contract_sft.build_dataset_csft3 import gate

ROOT = Path(r"D:\Game development\Demon slayer\StrategyGame\artifacts\contract_sft_v1")
UID = re.compile(r"\b[RB]_[A-Z]{2,3}_\d+\b")
VERSION = "CONTRACT_SFT_V1_DATASET_CSFT4"


def sha(t) -> str:
    return hashlib.sha256((t if isinstance(t, str) else json.dumps(t, sort_keys=True)).encode("utf-8")).hexdigest()


def dumps(d):
    return json.dumps(d, ensure_ascii=False, separators=(",", ":"))


def main() -> int:
    from transformers import AutoTokenizer
    tok = AutoTokenizer.from_pretrained(r"D:\StrategyAI\models\Qwen3-8B")
    import argparse
    ap = argparse.ArgumentParser()
    ap.add_argument("--round", type=int, default=4)
    ap.add_argument("--policy", default="CSFT3")
    ap.add_argument("--base", default="dataset_csft3c")
    ap.add_argument("--out", default="")
    a = ap.parse_args()
    rnd = a.round
    P = {p["prompt_id"]: p for p in json.loads((ROOT / "prompts" / f"train_gen{rnd}.json").read_text(encoding="utf-8"))}
    banned = {p["roster_signature"] for n in ("heldout", "ood_hidden")
              for p in json.loads((ROOT / "prompts" / f"{n}.json").read_text(encoding="utf-8"))}
    gen = json.loads((ROOT / "gen" / f"train_gen{rnd}_{a.policy}.json").read_text(encoding="utf-8"))
    samples = [{"id": f"r{rnd}:" + r["job_id"], "prompt_id": r["prompt_id"], "text": r["text"]} for r in gen["rows"]]
    raw_res = gate(samples, P, tok)
    accepted, cands, audit = [], [], []
    for s, (codes, v) in zip(samples, raw_res):
        s["raw_category"] = v["category"]
        raw_schema = SS.audit(json.loads(s["text"])) if v["no_extra_text"] else ["NOT_DIRECT_JSON"]
        s["raw_unknown_ids"] = [c for c in codes if c.startswith("UNAUTHORIZED_FRIENDLY")]
        if not codes and not raw_schema:
            s.update(grade="A", target=s["text"], notes=[])
            accepted.append(s)
            continue
        t, notes = RP.repair(s["text"], P[s["prompt_id"]]["roster"])
        if t is None or any(n.split(":")[0].split("@")[0] in STRUCTURAL for n in notes):
            audit.append({"id": s["id"], "raw_category": v["category"], "why": "repair_failed_or_structural"})
            continue
        d, hn = SS.hoist(json.loads(t))
        if SS.audit(d):
            audit.append({"id": s["id"], "raw_category": v["category"], "why": "schema_after_hoist"})
            continue
        s.update(grade="B", target=dumps(d), notes=notes + hn)
        cands.append(s)
    for s, (codes, v) in zip(cands, gate([{"id": c["id"], "text": c["target"], "prompt_id": c["prompt_id"]}
                                          for c in cands], P, tok)):
        if codes:
            audit.append({"id": s["id"], "raw_category": s["raw_category"], "why": "gate:" + ";".join(codes)})
        else:
            accepted.append(s)
    remap = []
    for s in accepted:
        p = P[s["prompt_id"]]
        rng = random.Random(int(sha(s["id"])[:12], 16))
        own = p["side"][0]
        visible = [u["unit_id"] for u in json.loads(p["messages"][1]["content"])["compact_state"]["known_enemy_units"]]
        fmap = make_map(p["roster"], rng, need_high=True)
        used = set(UID.findall(s["target"]))
        all_enemy = [u["id"] for u in p["scenario"]["blue_forces" if own == "R" else "red_forces"]]
        emap = make_map(all_enemy, rng, need_high=False) if any(u in visible for u in used if u[0] != own) else {}
        emap = {k: (k if k.endswith("_HQ_1") else v) for k, v in emap.items()}
        if len(set(emap.values())) != len(emap):
            continue
        full = {**fmap, **emap}
        t = sub(s["target"], full)
        if sub(t, {v: k for k, v in full.items()}) != s["target"]:
            continue
        spec = remap_spec(p["scenario"], fmap, emap)
        spec["scenario_id"] = f"{p['scenario']['scenario_id']}_r{rnd}aug{sha(s['id'])[:8]}"
        if S.roster_signature(spec) in banned:
            continue
        remap.append({"id": f"r{rnd}aug:" + s["id"][3:], "src": s["id"], "spec": spec, "side": p["side"],
                      "target": t, "fmap": fmap, "emap": emap})
    built = H.build_prompts([r["spec"] for r in remap])
    items = []
    for r, b in zip(remap, built):
        if b.get("error"):
            continue
        r["prompt"] = {"prompt_id": f"AUG{rnd}_" + sha(b["messages"])[:16], "split": f"augment_r{rnd}", "side": r["side"],
                       "messages": b["messages"], "scenario": r["spec"], "roster": b["roster"],
                       "roster_signature": S.roster_signature(r["spec"]), "sha256": sha(b["messages"])}
        items.append(r)
    rm_ok = [r for r, (codes, _) in zip(items, gate([{"id": r["id"], "text": r["target"], "prompt": r["prompt"]}
                                                     for r in items], P, tok)) if not codes]
    base = [json.loads(l) for l in open(ROOT / a.base / "sft_rows.jsonl", encoding="utf-8")]
    rows = list(base)
    for s in accepted:
        rows.append({"row_id": s["id"], "source": f"R{rnd}_SELF_{s['grade']}", "split": "train", "prompt_id": s["prompt_id"],
                     "target": s["target"], "target_sha256": sha(s["target"]), "raw_category": s["raw_category"],
                     "repair_notes": s["notes"]})
    for r in rm_ok:
        rows.append({"row_id": r["id"], "source": f"R{rnd}_REMAP", "split": "train", "prompt_id": r["prompt"]["prompt_id"],
                     "target": r["target"], "target_sha256": sha(r["target"]), "src_id": r["src"],
                     "friendly_map": r["fmap"], "enemy_map": r["emap"]})
    assert all(not SS.audit(json.loads(r["target"])) for r in rows)
    out = ROOT / (a.out or f"dataset_csft{rnd}")
    out.mkdir(exist_ok=True)
    (out / f"r{rnd}_augment_prompts.json").write_text(json.dumps([r["prompt"] for r in rm_ok], ensure_ascii=False),
                                                 encoding="utf-8")
    with open(out / "sft_rows.jsonl", "w", encoding="utf-8") as f:
        for r in rows:
            f.write(json.dumps(r, ensure_ascii=False) + "\n")
    man = {"version": f"CONTRACT_SFT_V1_DATASET_CSFT{rnd}", "base": a.base, "rows": len(rows), "train_rows": sum(r["split"] == "train" for r in rows),
           "dev_rows": sum(r["split"] == "dev" for r in rows), "base_rows_preserved": len(base),
           "base_sha256": hashlib.sha256((ROOT / a.base / "sft_rows.jsonl").read_bytes()).hexdigest(),
           "r_samples": len(samples),
           "r_raw_category": dict(collections.Counter(s["raw_category"] for s in samples)),
           "r_raw_cav1_copies": sum(1 for s in samples if any("CAV_1" in c for c in s["raw_unknown_ids"])),
           "r_grade_A": sum(s["grade"] == "A" for s in accepted), "r_grade_B": sum(s["grade"] == "B" for s in accepted),
           "r_excluded": len(audit), "r_remap_accepted": len(rm_ok),
           "all_rows_schema_strict_clean": True,
           "sealed_ood_usage": "roster signatures read ONLY to exclude collisions",
           "sft_rows_sha256": hashlib.sha256((out / "sft_rows.jsonl").read_bytes()).hexdigest()}
    (out / "DATASET_MANIFEST.json").write_text(json.dumps(man, indent=1), encoding="utf-8")
    (out / f"r{rnd}_exclusions.json").write_text(json.dumps(audit, indent=1), encoding="utf-8")
    print(json.dumps(man, indent=1))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
