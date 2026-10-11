"""External corpus intake gate (CONTRACT_SFT_V1 Round-2). No training.

  python -m tools.contract_sft.intake_external <corpus.jsonl> --source B03R1

Each row {scenario_id, variant_id, plan} is resolved to the EXACT existing
production prompt in prompts/train_gen.json and converted to intake form
{prompt_id, messages, target} where target = compact serialization of the
raw plan object (the Brain answer; no wrapper). The admission gate re-runs
independently; nothing is repaired:
  - target is exactly one JSON object
  - real Godot production INITIAL path PASS first try (0 retry/fallback)
  - plan coherence P1-P11 PASS
  - friendly authorization: every own-side unit id is in the packet roster
  - enemy authorization: every enemy-side unit id is in the packet's
    known_enemy_units (fog-visible contacts)
Failures are excluded with exact codes. Output is a versioned intake
artifact under intake/, NOT merged into any training dataset.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import re
from pathlib import Path

from tools.contract_sft import harness as H

ROOT = Path(r"D:\Game development\Demon slayer\StrategyGame\artifacts\contract_sft_v1")
UID = re.compile(r"\b([RB])_[A-Z]{2,3}_\d+\b")


def ids_in(text: str):
    return {m.group(0) for m in UID.finditer(text)}


def packet_ids(prompt):
    pk = json.loads(prompt["messages"][1]["content"])
    cs = pk.get("compact_state", {})
    friendly = {u["unit_id"] for u in cs.get("friendly_units", [])}
    enemy = {u["unit_id"] for u in cs.get("known_enemy_units", [])}
    return friendly, enemy, pk


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("corpus")
    ap.add_argument("--source", required=True)
    a = ap.parse_args()
    cpath = Path(a.corpus)
    raw_lines = cpath.read_text(encoding="utf-8").splitlines()
    prompts = {p["scenario"]["scenario_id"]: p
               for p in json.loads((ROOT / "prompts" / "train_gen.json").read_text(encoding="utf-8"))}
    rows, items = [], []
    for ln, line in enumerate(raw_lines, 1):
        r = json.loads(line)
        p = prompts.get(r["scenario_id"])
        rec = {"intake_id": f"{a.source}_{r['scenario_id']}_{r['variant_id']}", "line": ln,
               "scenario_id": r["scenario_id"], "variant_id": r["variant_id"],
               "source_row_sha256": hashlib.sha256(line.encode("utf-8")).hexdigest()}
        if p is None:
            rec.update(admitted=False, reject_codes=["NO_MATCHING_PRODUCTION_PROMPT"])
            rows.append(rec)
            continue
        target = json.dumps(r["plan"], ensure_ascii=False, separators=(",", ":"))
        rec.update(prompt_id=p["prompt_id"], prompt_sha256=p["sha256"], side=p["side"], target=target,
                   target_sha256=hashlib.sha256(target.encode("utf-8")).hexdigest())
        rows.append(rec)
        items.append({"id": rec["intake_id"], "text": target, "scenario": p["scenario"]})
    ver = {v["id"]: v for v in H.validate(items)}
    for rec in rows:
        if "target" not in rec:
            continue
        v = ver[rec["intake_id"]]
        p = prompts[rec["scenario_id"]]
        friendly, enemy, _ = packet_ids(p)
        own = "R" if p["side"] == "RED" else "B"
        used = ids_in(rec["target"])
        bad_friend = sorted(u for u in used if u[0] == own and u not in friendly)
        bad_enemy = sorted(u for u in used if u[0] != own and u not in enemy)
        codes = []
        if not v["no_extra_text"]:
            codes.append("NOT_EXACTLY_ONE_JSON_OBJECT")
        if not v["production_pass"]:
            codes.append("PRODUCTION:" + (v["fault"] or v["validator_code"] or v["parse_code"] or "FAIL"))
        if v["retries"] != 0 or v["general_calls"] != 1:
            codes.append("RETRY_OR_EXTRA_CALL")
        if not v["plan_coherent"]:
            codes += ["COHERENCE:" + c for c in (v["coherence_violations"] or ["UNVERIFIED"])]
        if bad_friend:
            codes.append("UNAUTHORIZED_FRIENDLY:" + ",".join(bad_friend))
        if bad_enemy:
            codes.append("UNAUTHORIZED_ENEMY:" + ",".join(bad_enemy))
        rec.update(admitted=not codes, reject_codes=codes,
                   gate={"production_pass": v["production_pass"], "strict_first_pass": v["strict_first_pass"],
                         "plan_coherent": v["plan_coherent"], "retries": v["retries"],
                         "friendly_ids_used": sorted(u for u in used if u[0] == own),
                         "enemy_ids_used": sorted(u for u in used if u[0] != own)})
    out = ROOT / "intake"
    out.mkdir(exist_ok=True)
    tag = f"{a.source}_intake_v1"
    with open(out / f"{tag}.jsonl", "w", encoding="utf-8") as f:
        for rec in rows:
            if rec.get("admitted"):
                f.write(json.dumps({"prompt_id": rec["prompt_id"],
                                    "messages": prompts[rec["scenario_id"]]["messages"],
                                    "target": rec["target"],
                                    "provenance": {"source": a.source, "scenario_id": rec["scenario_id"],
                                                   "variant_id": rec["variant_id"],
                                                   "source_file": str(cpath), "source_line": rec["line"],
                                                   "source_row_sha256": rec["source_row_sha256"],
                                                   "target_sha256": rec["target_sha256"]}},
                                   ensure_ascii=False) + "\n")
    audit = {"version": tag, "source": a.source, "source_file": str(cpath),
             "source_file_sha256": hashlib.sha256(cpath.read_bytes()).hexdigest(),
             "rows": len(rows), "admitted": sum(1 for r in rows if r.get("admitted")),
             "rejected": [{k: r[k] for k in ("intake_id", "reject_codes")} for r in rows if not r.get("admitted")],
             "merged_into_training": False, "per_row": rows}
    (out / f"{tag}_AUDIT.json").write_text(json.dumps(audit, indent=1, ensure_ascii=False), encoding="utf-8")
    print(json.dumps({k: audit[k] for k in ("version", "rows", "admitted", "rejected")}, indent=1)[:3000])
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
