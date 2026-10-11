"""CSFT3 dataset: CSFT2 dataset (preserved, unchanged) + Round-3 targeted rows.

  python -m tools.contract_sft.build_dataset_csft3

Round-3 source: CSFT2 on-policy samples (gen/train_gen3_CSFT2.json) on the
train_gen3 families (no_cav / no_inf2 / thin / sparse / base) + prompt-A
self-samples (new seeds). Per sample:
  grade A  raw output already passes every gate (kept verbatim)
  grade B  repair.py output (format/contract only) passes every gate
  C/None   excluded (structural change or unrepairable)
Gates (all mechanical): real Godot production strict first-pass; exactly one
JSON object; coherence P1-P11; WHOLE-TEXT friendly authorization (every own
id anywhere, incl. prose/prefer/misplaced keys, is in the packet roster);
enemy ids are fog-visible or the conventional enemy HQ_1; every trigger-like
token in a condition slot is a known trigger (covered by production);
target <= 1100 tokens.
Plus one ID-remap copy per accepted train_gen3 row (production rebuild of the
remapped scenario, same gates). The sealed OOD set is never read.
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
from tools.contract_sft.augment_remap import make_map, remap_spec, sub
from tools.contract_sft.build_dataset import STRUCTURAL

ROOT = Path(r"D:\Game development\Demon slayer\StrategyGame\artifacts\contract_sft_v1")
UID = re.compile(r"\b[RB]_[A-Z]{2,3}_\d+\b")
VERSION = "CONTRACT_SFT_V1_DATASET_CSFT3"
MAX_TOK = 1100


def sha(t) -> str:
    return hashlib.sha256((t if isinstance(t, str) else json.dumps(t, sort_keys=True)).encode("utf-8")).hexdigest()


def auth_codes(prompt, text):
    pk = json.loads(prompt["messages"][1]["content"])
    own = prompt["side"][0]
    roster = {u["unit_id"] for u in pk["compact_state"]["friendly_units"]}
    vis = {u["unit_id"] for u in pk["compact_state"]["known_enemy_units"]}
    ids = set(UID.findall(text))
    codes = []
    bad_f = sorted(u for u in ids if u[0] == own and u not in roster)
    bad_e = sorted(u for u in ids if u[0] != own and u not in vis and not u.endswith("_HQ_1"))
    if bad_f:
        codes.append("UNAUTHORIZED_FRIENDLY:" + ",".join(bad_f))
    if bad_e:
        codes.append("UNAUTHORIZED_ENEMY:" + ",".join(bad_e))
    return codes


def gate(items, P, tok):
    """items: [{id, text, prompt_id|prompt}] -> per item list of reject codes."""
    res = H.validate([{"id": x["id"], "text": x["text"], "scenario": (x.get("prompt") or P[x["prompt_id"]])["scenario"]}
                      for x in items])
    out = []
    for x, v in zip(items, res):
        p = x.get("prompt") or P[x["prompt_id"]]
        c = []
        if not v["strict_first_pass"]:
            c.append("PRODUCTION:" + v["category"])
        if not v["plan_coherent"]:
            c.append("COHERENCE")
        c += auth_codes(p, x["text"])
        if len(tok(x["text"], add_special_tokens=False)["input_ids"]) > MAX_TOK:
            c.append("TOO_LONG")
        out.append((c, v))
    return out


def main() -> int:
    from transformers import AutoTokenizer
    tok = AutoTokenizer.from_pretrained(r"D:\StrategyAI\models\Qwen3-8B")
    P = {}
    for n in ("train_gen3", "rl_A"):
        for p in json.loads((ROOT / "prompts" / f"{n}.json").read_text(encoding="utf-8")):
            P[p["prompt_id"]] = p
    sealed = {p["prompt_id"] for p in json.loads((ROOT / "prompts" / "heldout.json").read_text(encoding="utf-8"))}
    # Exclusion-only read of roster signatures (held-out + sealed OOD) so a
    # remapped roster can never coincide with an evaluation roster. No OOD
    # prompt, target or output is used for anything else.
    banned_sigs = {p["roster_signature"] for n in ("heldout", "ood_hidden")
                   for p in json.loads((ROOT / "prompts" / f"{n}.json").read_text(encoding="utf-8"))}
    gen = json.loads((ROOT / "gen" / "train_gen3_CSFT2.json").read_text(encoding="utf-8"))
    samples = [{"id": "r3:" + r["job_id"], "prompt_id": r["prompt_id"], "text": r["text"],
                "gen_tokens": r["gen_tokens"], "cap": r["hit_token_cap"]} for r in gen["rows"]]
    assert not any(s["prompt_id"] in sealed for s in samples)
    raw_gate = gate(samples, P, tok)
    accepted, audit, cands = [], [], []
    for s, (codes, v) in zip(samples, raw_gate):
        s["raw_category"], s["raw_codes"] = v["category"], codes
        if not codes:
            s.update(grade="A", target=s["text"], notes=[])
            accepted.append(s)
            continue
        t, notes = RP.repair(s["text"], P[s["prompt_id"]]["roster"])
        g = None if t is None else ("C" if any(n.split(":")[0].split("@")[0] in STRUCTURAL for n in notes) else "B")
        s.update(grade=g, target=t, notes=notes)
        if g == "B":
            cands.append(s)
        else:
            audit.append({"id": s["id"], "raw_category": v["category"], "raw_codes": codes, "grade": g})
    for s, (codes, v) in zip(cands, gate([{"id": c["id"], "text": c["target"], "prompt_id": c["prompt_id"]}
                                          for c in cands], P, tok)):
        if codes:
            audit.append({"id": s["id"], "raw_category": s["raw_category"], "grade": "B_REJECTED", "codes": codes})
        else:
            accepted.append(s)
    # One ID-remap copy per accepted train_gen3 row (production rebuild).
    remap = []
    for s in accepted:
        p = P[s["prompt_id"]]
        if p["split"] != "train_gen3":
            continue
        rng = random.Random(int(sha(s["id"])[:12], 16))
        own = p["side"][0]
        pk = json.loads(p["messages"][1]["content"])
        visible = [u["unit_id"] for u in pk["compact_state"]["known_enemy_units"]]
        fmap = make_map(p["roster"], rng, need_high=True)
        used = set(UID.findall(s["target"]))
        enemy_side = "blue_forces" if own == "R" else "red_forces"
        all_enemy = [u["id"] for u in p["scenario"][enemy_side]]
        emap = make_map(all_enemy, rng, need_high=False) if any(u in visible for u in used if u[0] != own) else {}
        # keep the conventional enemy HQ id fixed (hidden references stay valid)
        emap = {k: (k if k.endswith("_HQ_1") else v) for k, v in emap.items()}
        if len(set(emap.values())) != len(emap):
            continue
        spec = remap_spec(p["scenario"], fmap, emap)
        spec["scenario_id"] = f"{p['scenario']['scenario_id']}_r3aug{sha(s['id'])[:8]}"
        if S.roster_signature(spec) in banned_sigs:
            continue
        remap.append({"id": "r3aug:" + s["id"][3:], "src": s["id"], "spec": spec, "side": p["side"],
                      "target": sub(s["target"], {**fmap, **emap}), "fmap": fmap, "emap": emap,
                      "inv_ok": sub(sub(s["target"], {**fmap, **emap}), {v: k for k, v in {**fmap, **emap}.items()})
                      == s["target"]})
    built = H.build_prompts([r["spec"] for r in remap])
    rm_items = []
    for r, b in zip(remap, built):
        if b.get("error") or not r["inv_ok"]:
            continue
        r["prompt"] = {"prompt_id": "AUG3_" + sha(b["messages"])[:16], "split": "augment_r3", "side": r["side"],
                       "messages": b["messages"], "scenario": r["spec"],
                       "roster": b["roster"], "roster_signature": S.roster_signature(r["spec"]),
                       "sha256": sha(b["messages"])}
        rm_items.append(r)
    rm_ok = []
    for r, (codes, v) in zip(rm_items, gate([{"id": r["id"], "text": r["target"], "prompt": r["prompt"]}
                                             for r in rm_items], P, tok)):
        if not codes:
            rm_ok.append(r)
    # Assemble: CSFT2 rows unchanged + round-3 rows.
    base = [json.loads(l) for l in open(ROOT / "dataset_csft2" / "sft_rows.jsonl", encoding="utf-8")]
    rows = list(base)
    for s in accepted:
        rows.append({"row_id": s["id"], "source": f"R3_SELF_{s['grade']}", "split": "train",
                     "prompt_id": s["prompt_id"], "target": s["target"], "target_sha256": sha(s["target"]),
                     "raw_category": s["raw_category"], "repair_notes": s["notes"]})
    aug_prompts = []
    for r in rm_ok:
        aug_prompts.append(r["prompt"])
        rows.append({"row_id": r["id"], "source": "R3_REMAP", "split": "train", "prompt_id": r["prompt"]["prompt_id"],
                     "target": r["target"], "target_sha256": sha(r["target"]), "src_id": r["src"],
                     "friendly_map": r["fmap"], "enemy_map": r["emap"]})
    out = ROOT / "dataset_csft3"
    out.mkdir(exist_ok=True)
    (out / "r3_augment_prompts.json").write_text(json.dumps(aug_prompts, ensure_ascii=False), encoding="utf-8")
    with open(out / "sft_rows.jsonl", "w", encoding="utf-8") as f:
        for r in rows:
            f.write(json.dumps(r, ensure_ascii=False) + "\n")
    new = [r for r in rows if r["source"].startswith("R3")]
    fam = collections.Counter(P[r["prompt_id"]].get("family", "rl_A") for r in new if r["prompt_id"] in P)
    man = {"version": VERSION, "rows": len(rows), "train_rows": sum(1 for r in rows if r["split"] == "train"),
           "dev_rows": sum(1 for r in rows if r["split"] == "dev"), "csft2_rows_preserved": len(base),
           "csft2_rows_sha256": hashlib.sha256((ROOT / "dataset_csft2" / "sft_rows.jsonl").read_bytes()).hexdigest(),
           "r3_samples": len(samples),
           "r3_raw_category": dict(collections.Counter(s["raw_category"] for s in samples).most_common()),
           "r3_raw_gate_pass (grade A)": sum(1 for s in accepted if s["grade"] == "A"),
           "r3_repaired_accepted (grade B)": sum(1 for s in accepted if s["grade"] == "B"),
           "r3_excluded": len(audit), "r3_excluded_by": dict(collections.Counter(str(a["grade"]) for a in audit)),
           "r3_remap_accepted": len(rm_ok), "r3_self_rows_by_family": dict(fam),
           "r3_prompt_A_rows": sum(1 for s in accepted if s["prompt_id"].startswith("A_")),
           "sealed_ood_usage": "roster signatures read ONLY to exclude collisions; no OOD prompt/output used", "heldout_prompts_in_rows": 0,
           "sft_rows_sha256": hashlib.sha256((out / "sft_rows.jsonl").read_bytes()).hexdigest()}
    (out / "DATASET_MANIFEST.json").write_text(json.dumps(man, indent=1), encoding="utf-8")
    (out / "r3_exclusions.json").write_text(json.dumps(audit, indent=1), encoding="utf-8")
    print(json.dumps(man, indent=1))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
