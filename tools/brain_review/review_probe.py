"""SEALED REVIEW PROBE (lead-only; built BEFORE S1 exists). Seeds 300000-309999 only.

  build: from a sealed harvest dir (raw/reviews.jsonl) -> stratified probe set labeled by the CURRENT teacher
         python -m tools.brain_review.review_probe build --harvest <dir> --out <sealed dir> [--per-subkind 15]
  eval:  score a generation file (tools.brain_vllm.generate output on <sealed>/jobs.json)
         python -m tools.brain_review.review_probe eval --probe <sealed dir> --gen <gen.json> --label <name>

PRE-REGISTERED GATE for S1 (fixed 2026-10-01, before any S1 output exists):
  valid       production dry run (parse_review + vp_compute_review) accepts >= 0.95 of samples
  agree       decision type == teacher decision on >= 0.70 of samples (all subkinds pooled)
  phase_done  on PHASE_DONE items: ADVANCE_PHASE >= 0.85 and KEEP <= 0.10
  final_adv   on items whose active phase has NO next phase: ADVANCE_PHASE <= 0.03 (S0B's VP_NO_NEXT faults)
  hq_defense  on HQ_DEFENSE items: AMEND that sets an active mission to ATTACK in the HQ region >= 0.60
  lift        agree(S1) - agree(S0B) >= 0.30
"""
from __future__ import annotations

import argparse
import hashlib
import json
import random
import sys
from collections import Counter, defaultdict
from pathlib import Path

ROOT = Path(r"D:\Game development\Demon slayer\StrategyGame")
sys.path.insert(0, str(ROOT))

from tools.brain_review import build_corpus as B  # noqa: E402
from tools.brain_review.review_teacher import decide, Teacher  # noqa: E402

GATE = {"valid": 0.95, "agree": 0.70, "phase_done_adv": 0.85, "phase_done_keep": 0.10, "final_adv": 0.03,
        "hq_defense": 0.60, "lift": 0.30}


def _packet(msgs):
    return json.loads(next(m["content"] for m in msgs if m["role"] == "user"))


def cmd_build(a):
    out = Path(a.out)
    out.mkdir(parents=True, exist_ok=True)
    rows = [json.loads(l) for l in (Path(a.harvest) / "raw" / "reviews.jsonl").read_text(encoding="utf-8").splitlines() if l.strip()]
    seen, by_sub = set(), defaultdict(list)
    for r in rows:
        msgs = r.get("messages") or []
        if not msgs:
            continue
        h = B.sha(msgs)
        if h in seen:
            continue
        seen.add(h)
        pk = _packet(msgs)
        t = decide(pk)
        if not t["target"]:
            continue
        has_next = bool(Teacher(pk).resolve_next())
        by_sub[t["subkind"]].append({"messages": msgs, "teacher": t["target"], "subkind": t["subkind"], "rule": t["rule"],
                                     "has_next": has_next, "tag": r.get("tag"), "turn": r.get("turn"), "sha": h})
    rng = random.Random(20261001)
    items = []
    for sub in sorted(by_sub):
        pool = sorted(by_sub[sub], key=lambda x: x["sha"])
        rng.shuffle(pool)
        items.extend(pool[:a.per_subkind])
    for i, it in enumerate(items):
        it["probe_id"] = "rp%03d" % i
    jobs = [{"job_id": "%s_s%d" % (it["probe_id"], k), "prompt_id": it["probe_id"], "messages": it["messages"],
             "seed": 9100 + i * 10 + k} for i, it in enumerate(items) for k in range(a.samples)]
    (out / "PROBE.json").write_text(json.dumps(items, ensure_ascii=False), encoding="utf-8")
    (out / "jobs.json").write_text(json.dumps(jobs, ensure_ascii=False), encoding="utf-8")
    man = {"items": len(items), "samples_per_item": a.samples, "by_subkind": Counter(i["subkind"] for i in items),
           "final_phase_items": sum(1 for i in items if not i["has_next"]), "gate": GATE,
           "sha256_probe": hashlib.sha256((out / "PROBE.json").read_bytes()).hexdigest()}
    (out / "SEALED_MANIFEST.json").write_text(json.dumps(man, indent=1, default=dict), encoding="utf-8")
    print(json.dumps(man, indent=1, default=dict))


def _hq_attack(pk, target):
    """AMEND sets some active-phase mission to ATTACK in the own HQ region."""
    T = Teacher(pk)
    hq = next((u for u in T.friendlies.values() if str(u.get("class", "")).upper() == "HQ"), None)
    if hq is None or not isinstance(target, dict) or target.get("decision") != "AMEND_PLAN":
        return False
    region = str(hq.get("region", "")).upper()
    if "patch" in target and not target.get("phases"):
        from tools.brain_review.to_patch import apply_patch
        target = dict(target, phases=apply_patch(target, pk) or [])
    for ph in target.get("phases") or []:
        if str(ph.get("id", "")).upper() == T.active_id.upper():
            return any(str(m.get("task", "")).upper() == "ATTACK" and str(m.get("area", "")).upper() == region
                       for m in ph.get("missions") or [])
    return False


def cmd_eval(a):
    items = {it["probe_id"]: it for it in json.loads((Path(a.probe) / "PROBE.json").read_text(encoding="utf-8"))}
    gen = json.loads(Path(a.gen).read_text(encoding="utf-8"))
    rows = gen["rows"] if isinstance(gen, dict) else gen
    parsed, dry_in = [], []
    for i, r in enumerate(rows):
        it = items[r["prompt_id"]]
        try:  # raw completion must be exactly one JSON object (production parse runs in the dry run)
            doc = json.loads(r["text"].strip())
        except ValueError:
            doc = None
        ok_obj = isinstance(doc, dict) and "decision" in doc
        parsed.append({"it": it, "doc": doc if ok_obj else None})
        if ok_obj:
            dry_in.append({"row_id": str(i), "packet": _packet(it["messages"]), "target": doc})
    B.SCRATCH = Path(a.probe) / ("_scratch_%s" % a.label)
    dry = B.dry_run(dry_in) if dry_in else {}
    stats = defaultdict(Counter)
    for i, p in enumerate(parsed):
        it, doc = p["it"], p["doc"]
        s = stats[it["subkind"]]
        s["n"] += 1
        valid = doc is not None and dry.get(str(i), {}).get("ok", False)
        s["valid"] += int(valid)
        dec = doc.get("decision") if doc else "INVALID"
        s["dec_" + str(dec)] += 1
        s["agree"] += int(valid and dec == it["teacher"]["decision"])
        if not it["has_next"]:
            s["final_n"] += 1
            s["final_adv"] += int(dec == "ADVANCE_PHASE")
        if it["subkind"] == "HQ_DEFENSE":
            s["hq_attack"] += int(valid and _hq_attack(_packet(it["messages"]), doc))
    tot = Counter()
    for s in stats.values():
        tot.update(s)
    pd = stats.get("PHASE_DONE", Counter())
    hq = stats.get("HQ_DEFENSE", Counter())
    res = {"label": a.label, "n": tot["n"],
           "valid": round(tot["valid"] / max(1, tot["n"]), 3), "agree": round(tot["agree"] / max(1, tot["n"]), 3),
           "phase_done_adv": round(pd["dec_ADVANCE_PHASE"] / max(1, pd["n"]), 3),
           "phase_done_keep": round(pd["dec_KEEP"] / max(1, pd["n"]), 3),
           "final_adv": round(tot["final_adv"] / max(1, tot["final_n"]), 3),
           "hq_defense": round(hq["hq_attack"] / max(1, hq["n"]), 3),
           "by_subkind": {k: dict(v) for k, v in sorted(stats.items())}}
    (Path(a.probe) / ("RESULTS_%s.json" % a.label)).write_text(json.dumps(res, indent=1), encoding="utf-8")
    print(json.dumps({k: v for k, v in res.items() if k != "by_subkind"}, indent=1))


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)
    b = sub.add_parser("build")
    b.add_argument("--harvest", required=True)
    b.add_argument("--out", required=True)
    b.add_argument("--per-subkind", type=int, default=15)
    b.add_argument("--samples", type=int, default=4)
    e = sub.add_parser("eval")
    e.add_argument("--probe", required=True)
    e.add_argument("--gen", required=True)
    e.add_argument("--label", required=True)
    a = ap.parse_args()
    {"build": cmd_build, "eval": cmd_eval}[a.cmd](a)
