"""Canonical admission of the external CSFT5 adversarial package.

  python -m tools.contract_sft.admit_csft5

Package: CSFTDataLab/CSFT5_PREP (600 training candidates + 128 sealed
prompt-only challenge cases), hand-authored from the contract; prompts are
NOT production-builder output. Canonicalization (never trust the authored
prompt text):
  1. derive a real sim scenario from the authored packet: exact friendly ids /
     classes / q,r / soldiers; enemies at their authored positions (strength
     from troop_estimate); a conventional hidden enemy HQ_1 if none authored;
     bounds covering all coordinates; mission type + turn limit.
  2. the PRODUCTION packet builder (tools/contract_sft_harness.gd) rebuilds
     the prompt; the rebuilt friendly roster must equal the authored roster
     (ids + classes) or the row is rejected (ROSTER_NOT_REPRODUCIBLE).
     Visibility is whatever production fog yields -- production truth wins.
  3. training rows: target (serialized compactly, unchanged) must pass the
     full gate against the REBUILT prompt: real Godot production strict
     first-pass, exactly one JSON object, strict authoring schema, coherence
     P1-P11, whole-text friendly authorization, enemy ids fog-visible (or the
     conventional enemy HQ_1), <= 1100 tokens; roster signature not in
     held-out / sealed OOD.
  VICTORY_REVIEW rows: excluded (this harness has no canonical review-path
  gate; the measured contract is VICTORY_INITIAL).
  Challenge: INITIAL cases rebuilt the same way into a sealed eval prompt set
  (prompts/csft5_challenge.json); never used for training.
Outputs: intake/CSFT5_admission_v1.jsonl (+ AUDIT), prompts/csft5_train_rebuilt.json,
prompts/csft5_challenge.json (+ CSFT5_CHALLENGE_SEAL.json).
"""
from __future__ import annotations

import collections
import hashlib
import json
from pathlib import Path

from tools.contract_sft import harness as H
from tools.contract_sft import scenarios as S
from tools.contract_sft import schema_strict as SS
from tools.contract_sft.build_dataset_csft3 import gate

ROOT = Path(r"D:\Game development\Demon slayer\StrategyGame\artifacts\contract_sft_v1")
PKG = Path(r"D:\Game development\Demon slayer\CSFTDataLab\CSFT5_PREP")
TRAIN_SHA = "cac4c05cfc9bcffa2146d916b30a0990a4e2b6005b7130c2e9fd8b629a19c4de"
CHAL_SHA = "afc228caed8a2e2905adfad8d2a6eab56f5c4b7884d21430a7979efbd6af6bd9"
TROOPS = {"small": 150, "medium": 300, "large": 450}


def sha(t) -> str:
    return hashlib.sha256((t if isinstance(t, str) else json.dumps(t, sort_keys=True)).encode("utf-8")).hexdigest()


def spec_from_packet(pk: dict, sid: str) -> dict:
    side = pk["acting_side"].lower()
    own, foe = ("red", "blue") if side == "red" else ("blue", "red")
    cs = pk["compact_state"]
    fr = [{"id": u["unit_id"], "class": u["class"].lower(), "faction": own, "q": int(u["q"]), "r": int(u["r"]),
           "soldiers": int(u.get("soldiers", 300))} for u in cs["friendly_units"]]
    en = [{"id": u["unit_id"], "class": u["class"].lower(), "faction": foe, "q": int(u["q"]), "r": int(u["r"]),
           "soldiers": TROOPS.get(str(u.get("troop_estimate", "")).lower(), 300)} for u in cs["known_enemy_units"]]
    used = {(u["q"], u["r"]) for u in fr + en}
    qs = [u["q"] for u in fr + en] or [0]
    rs = [u["r"] for u in fr + en] or [0]
    fq = sum(u["q"] for u in fr) / max(1, len(fr))
    if not any(u["class"] == "hq" for u in en):  # conventional hidden enemy HQ, far from friendlies
        hq = {"id": ("B" if own == "red" else "R") + "_HQ_1", "class": "hq", "faction": foe,
              "q": int(min(qs) - 6 if fq >= 0 else max(qs) + 6), "r": 0, "soldiers": 300}
        while (hq["q"], hq["r"]) in used:
            hq["r"] += 1
        en.append(hq)
        qs.append(hq["q"])
    b = {"q_min": min(qs) - 2, "q_max": max(qs) + 2, "r_min": min(rs) - 2, "r_max": max(rs) + 2}
    m = pk.get("mission", {})
    red, blue = (fr, en) if own == "red" else (en, fr)
    return {"scenario_id": sid, "side": side, "seed": int(sha(sid)[:6], 16) % 100000, "red_forces": red,
            "blue_forces": blue, "primary_objective": m.get("type", "destroy_all_red"),
            "turn_limit": max(1, int(m.get("turn_limit", 12) or 12)), "bounds": b}


def _hexd(a, b):
    dq, dr = a[0] - b[0], a[1] - b[1]
    return (abs(dq) + abs(dr) + abs(dq + dr)) // 2


def spec_visibility_faithful(pk: dict, sid: str) -> dict:
    """v2: same roster/classes/strengths; authored current_visible enemies are
    placed 1-2 hexes from a friendly (preferring the enemy's authored region)
    so production fog reports them; every other enemy (stale / hidden /
    anonymous) is placed >= 10 hexes from all friendlies so it stays hidden.
    Anonymous contacts get an unused hidden id (never shown in the prompt)."""
    s = spec_from_packet(dict(pk, compact_state=dict(pk["compact_state"], known_enemy_units=[
        u for u in pk["compact_state"]["known_enemy_units"] if u.get("unit_id")])), sid)
    own = s["side"]
    fr = s["red_forces"] if own == "red" else s["blue_forces"]
    en = s["blue_forces"] if own == "red" else s["red_forces"]
    foe = "B" if own == "red" else "R"
    authored = {u["unit_id"]: u for u in pk["compact_state"]["known_enemy_units"] if u.get("unit_id")}
    freg = {u["unit_id"]: u.get("region") for u in pk["compact_state"]["friendly_units"]}
    for k, u in enumerate([u for u in pk["compact_state"]["known_enemy_units"] if not u.get("unit_id")]):
        tag = {"cavalry": "CAV", "archer": "ARC", "infantry": "INF", "spearman": "SPE", "scout": "SCT",
               "siege": "SIE", "conscript": "CON"}.get(u["class"].lower(), "INF")
        en.append({"id": f"{foe}_{tag}_{90 + k}", "class": u["class"].lower(), "faction": en[0]["faction"] if en else
                   ("blue" if own == "red" else "red"), "q": 0, "r": 0, "soldiers": 300})
    occupied = {(u["q"], u["r"]) for u in fr}
    fq = sum(u["q"] for u in fr) / max(1, len(fr))
    far_q = int(min(u["q"] for u in fr) - 12) if fq >= 0 else int(max(u["q"] for u in fr) + 12)
    ring = [(1, 0), (1, -1), (0, -1), (-1, 0), (-1, 1), (0, 1), (2, 0), (2, -1), (2, -2), (1, -2), (0, -2),
            (-1, -1), (-2, 0), (-2, 1), (-2, 2), (-1, 2), (0, 2), (1, 1)]
    hr = 0
    for e in en:
        a = authored.get(e["id"])
        if a is not None and a.get("contact_state") == "current_visible":
            cands = sorted(fr, key=lambda f: (0 if freg.get(f["id"]) == a.get("region") else 1,
                                              _hexd((f["q"], f["r"]), (a["q"], a["r"]))))
            placed = False
            for f in cands:
                for dq, dr in ring:
                    pos = (f["q"] + dq, f["r"] + dr)
                    if pos not in occupied:
                        e["q"], e["r"] = pos
                        occupied.add(pos)
                        placed = True
                        break
                if placed:
                    break
        else:
            while (far_q, hr) in occupied:
                hr += 1
            e["q"], e["r"] = far_q, hr
            occupied.add((far_q, hr))
            hr += 1
    qs = [u["q"] for u in fr + en]
    rs = [u["r"] for u in fr + en]
    s["bounds"] = {"q_min": min(qs) - 2, "q_max": max(qs) + 2, "r_min": min(rs) - 2, "r_max": max(rs) + 2}
    return s


MODE = {"faithful": False}


def rebuild(rows, key):
    mk = spec_visibility_faithful if MODE["faithful"] else spec_from_packet
    specs = [mk(r["scenario"], "csft5_" + r[key]) for r in rows]
    built = H.build_prompts(specs)
    out = []
    for r, s, b in zip(rows, specs, built):
        rec = {"id": r[key], "spec": s, "built": b, "codes": []}
        if b.get("error"):
            rec["codes"].append("SIM_REJECTED:" + str(b["error"])[:80])
        else:
            pk = json.loads(b["messages"][1]["content"])
            got = {(u["unit_id"], u["class"]) for u in pk["compact_state"]["friendly_units"]}
            want = {(u["unit_id"], u["class"]) for u in r["scenario"]["compact_state"]["friendly_units"]}
            if got != want:
                rec["codes"].append("ROSTER_NOT_REPRODUCIBLE")
            av = {u["unit_id"] for u in r["scenario"]["compact_state"]["known_enemy_units"]
                  if u.get("contact_state") == "current_visible"}
            pv = {u["unit_id"] for u in pk["compact_state"]["known_enemy_units"]}
            rec["authored_visible"], rec["production_visible"] = sorted(av), sorted(pv)
            if MODE["faithful"] and av != pv:
                rec["codes"].append("VISIBILITY_NOT_REPRODUCIBLE")
        out.append(rec)
    return out


def main() -> int:
    import argparse
    ap = argparse.ArgumentParser()
    ap.add_argument("--visibility-faithful", action="store_true")
    MODE["faithful"] = ap.parse_args().visibility_faithful
    V = "v2" if MODE["faithful"] else "v1"
    from transformers import AutoTokenizer
    tok = AutoTokenizer.from_pretrained(r"D:\StrategyAI\models\Qwen3-8B")
    tf, cf = PKG / "csft5_training_candidates.jsonl", PKG / "csft5_challenge_128.jsonl"
    assert hashlib.sha256(tf.read_bytes()).hexdigest() == TRAIN_SHA, "training package hash mismatch"
    assert hashlib.sha256(cf.read_bytes()).hexdigest() == CHAL_SHA, "challenge package hash mismatch"
    train = [json.loads(l) for l in open(tf, encoding="utf-8")]
    chal = [json.loads(l) for l in open(cf, encoding="utf-8")]
    chal_prompt_sha = {sha(c["prompt"]) for c in chal}
    assert not any(sha(t["prompt"]) in chal_prompt_sha for t in train), "challenge prompt found in training package"
    banned = {p["roster_signature"] for n in ("heldout", "ood_hidden")
              for p in json.loads((ROOT / "prompts" / f"{n}.json").read_text(encoding="utf-8"))}
    audit = []
    init = []
    for t in train:
        if t["request_type"] != "VICTORY_INITIAL":
            audit.append({"row_id": t["row_id"], "family": t["family"], "admitted": False,
                          "codes": ["REVIEW_ROW_NO_CANONICAL_INITIAL_GATE"]})
        elif not t.get("eligible_for_admission"):
            audit.append({"row_id": t["row_id"], "family": t["family"], "admitted": False, "codes": ["NOT_ELIGIBLE"]})
        else:
            init.append(t)
    rb = rebuild(init, "row_id")
    items, prompts, pend = [], {}, []
    for t, rec in zip(init, rb):
        if rec["codes"]:
            audit.append({"row_id": t["row_id"], "family": t["family"], "admitted": False, "codes": rec["codes"]})
            continue
        b, s = rec["built"], rec["spec"]
        p = {"prompt_id": f"C5T{V}_" + t["row_id"], "split": "csft5_train_rebuilt", "side": b["side"],
             "messages": b["messages"], "scenario": s, "roster": b["roster"],
             "roster_signature": S.roster_signature(s), "sha256": sha(b["messages"]), "family": t["family"],
             "pair_group_id": t.get("pair_group_id")}
        if p["roster_signature"] in banned:
            audit.append({"row_id": t["row_id"], "family": t["family"], "admitted": False, "codes": ["EVAL_ROSTER_COLLISION"]})
            continue
        target = json.dumps(t["target"], ensure_ascii=False, separators=(",", ":"))
        sc = SS.audit(t["target"])
        pend.append((t, p, target, sc, rec))
        items.append({"id": t["row_id"], "text": target, "prompt": p})
    res = gate(items, {}, tok)
    rows = []
    for (t, p, target, sc, rec), (codes, v) in zip(pend, res):
        codes = list(codes) + ["SCHEMA:" + c for c in sc]
        ok = not codes
        audit.append({"row_id": t["row_id"], "family": t["family"], "admitted": ok, "codes": codes,
                      "authored_visible": rec["authored_visible"], "production_visible": rec["production_visible"]})
        if ok:
            prompts[p["prompt_id"]] = p
            rows.append({"row_id": f"CSFT5{V}:" + t["row_id"], "source": "CSFT5_ADV", "split": "train",
                         "prompt_id": p["prompt_id"], "target": target, "target_sha256": sha(target),
                         "family": t["family"], "pair_group_id": t.get("pair_group_id"),
                         "coverage_tags": t.get("coverage_tags")})
    # Sealed challenge (INITIAL only), rebuilt the same way; no targets exist.
    cinit = [c for c in chal if c["scenario"].get("request") == "VICTORY_INITIAL"]
    crb = rebuild(cinit, "challenge_id")
    cprompts, cexcl = [], []
    for c, rec in zip(cinit, crb):
        if rec["codes"]:
            cexcl.append({"challenge_id": c["challenge_id"], "codes": rec["codes"]})
            continue
        b, s = rec["built"], rec["spec"]
        cprompts.append({"prompt_id": f"C5C{V}_" + c["challenge_id"], "split": "csft5_challenge", "side": b["side"],
                         "messages": b["messages"], "scenario": s, "roster": b["roster"],
                         "roster_signature": S.roster_signature(s), "sha256": sha(b["messages"]),
                         "family": c["family"], "coverage_tags": c.get("coverage_tags"),
                         "authored_visible": rec["authored_visible"], "production_visible": rec["production_visible"],
                         "n_known_enemies": len(rec["production_visible"])})
    tr_sha = {p["sha256"] for p in prompts.values()}
    assert not any(p["sha256"] in tr_sha for p in cprompts), "challenge rebuilt prompt equals a training prompt"
    (ROOT / "intake").mkdir(exist_ok=True)
    with open(ROOT / "intake" / f"CSFT5_admission_{V}.jsonl", "w", encoding="utf-8") as f:
        for r in rows:
            f.write(json.dumps(r, ensure_ascii=False) + "\n")
    (ROOT / "prompts" / f"csft5_train_rebuilt_{V}.json").write_text(json.dumps(list(prompts.values()), ensure_ascii=False),
                                                               encoding="utf-8")
    (ROOT / "prompts" / f"csft5_challenge_{V}.json").write_text(json.dumps(cprompts, ensure_ascii=False), encoding="utf-8")
    fam_in = collections.Counter(t["family"] for t in train)
    fam_ok = collections.Counter(r["family"] for r in rows)
    code_counts = collections.Counter(c.split(":")[0] + (":" + c.split(":")[1] if c.startswith(("PRODUCTION", "SCHEMA")) else "")
                                      for a in audit if not a["admitted"] for c in a["codes"])
    vis_drift = sum(1 for a in audit if a.get("authored_visible") is not None
                    and set(a["authored_visible"]) != set(a["production_visible"]))
    seal = {"challenge_package_sha256": CHAL_SHA, "initial_cases": len(cinit), "review_cases_excluded": len(chal) - len(cinit),
            "rebuilt": len(cprompts), "rebuild_rejected": cexcl,
            "rebuilt_file_sha256": hashlib.sha256((ROOT / "prompts" / f"csft5_challenge_{V}.json").read_bytes()).hexdigest(),
            "visibility_drift_cases": sum(1 for p in cprompts if set(p["authored_visible"]) != set(p["production_visible"])),
            "rule": "never used for training; evaluated once per candidate"}
    (ROOT / "prompts" / f"CSFT5_CHALLENGE_SEAL_{V}.json").write_text(json.dumps(seal, indent=1), encoding="utf-8")
    man = {"version": f"CSFT5_ADMISSION_{V.upper()}", "package_training_sha256": TRAIN_SHA, "candidates": len(train),
           "review_rows_excluded": sum(1 for t in train if t["request_type"] != "VICTORY_INITIAL"),
           "initial_rows": len(init), "admitted": len(rows), "rejected": len(audit) - len(rows),
           "reject_code_counts": dict(code_counts.most_common()),
           "admitted_by_family": {f: f"{fam_ok[f]}/{fam_in[f]}" for f in sorted(fam_in)},
           "admitted_sides": dict(collections.Counter(prompts[r["prompt_id"]]["side"] for r in rows)),
           "visibility_drift_rows (authored vs production fog)": vis_drift,
           "challenge": {k: v for k, v in seal.items() if k != "rebuild_rejected"},
           "admission_sha256": hashlib.sha256((ROOT / "intake" / f"CSFT5_admission_{V}.jsonl").read_bytes()).hexdigest()}
    (ROOT / "intake" / f"CSFT5_admission_{V}_AUDIT.json").write_text(json.dumps({"manifest": man, "rows": audit}, indent=1),
                                                                    encoding="utf-8")
    print(json.dumps(man, indent=1))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
