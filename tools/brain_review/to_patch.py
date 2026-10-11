"""Corpus v3: review corpus v2 with every AMEND_PLAN target rewritten as a compact patch (2026-10-02).

A teacher AMEND changes only task/area/vs/priority of missions; the patch lists exactly those changes
({"phase", "mission" (1-based), changed fields}). The game expands it onto the current compact plan
(cloud2_victory_response.gd expand_amend_patch). Every patched row must pass the production dry run.

  python -m tools.brain_review.to_patch --src <review_corpus_v2> --out <review_corpus_v3>
"""
from __future__ import annotations

import argparse
import json
import shutil
import sys
from pathlib import Path

ROOT = Path(r"D:\Game development\Demon slayer\StrategyGame")
sys.path.insert(0, str(ROOT))
from tools.brain_review import build_corpus as B  # noqa: E402

FIELDS = ("task", "area", "vs", "priority")


def to_patch(target: dict, packet: dict):
    old = (packet.get("plan_authoring") or {}).get("phases") or []
    new = target.get("phases") or []
    if [p.get("id") for p in old] != [p.get("id") for p in new]:
        return None
    entries = []
    for po, pn in zip(old, new):
        mo, mn = po.get("missions") or [], pn.get("missions") or []
        if len(mo) != len(mn):
            return None
        for k in set(po) | set(pn):  # nothing but missions may change
            if k != "missions" and po.get(k) != pn.get(k):
                return None
        for i, (a, b) in enumerate(zip(mo, mn)):
            if a == b:
                continue
            for k in set(a) | set(b):
                if k not in FIELDS and k not in ("target", "zone") and a.get(k) != b.get(k):
                    return None
            e = {"phase": pn.get("id"), "mission": i + 1}
            for k in FIELDS:
                if a.get(k) != b.get(k) and k in b:
                    e[k] = b[k]
            if len(e) > 2:
                entries.append(e)
    if not entries:
        return None
    return {"decision": "AMEND_PLAN", "reason": target.get("reason", ""), "patch": entries}


def apply_patch(target: dict, packet: dict):
    """Python mirror of cloud2_victory_response.gd expand_amend_patch: patch -> full compact phases (None if bad)."""
    import copy
    phases = copy.deepcopy((packet.get("plan_authoring") or {}).get("phases") or [])
    for e in target.get("patch") or []:
        ph = next((p for p in phases if str(p.get("id", "")).upper() == str(e.get("phase", "")).upper()), None)
        mv = e.get("mission", 0)
        try:
            idx = int(mv) - 1 if isinstance(mv, (int, float)) else int(str(mv).upper().lstrip("M")) - 1
        except ValueError:
            return None
        if ph is None or not (0 <= idx < len(ph.get("missions") or [])):
            return None
        m = ph["missions"][idx]
        for k in ("task", "area", "vs"):
            if k in e:
                m[k] = str(e[k]).upper()
        if "vs" in e:
            m.pop("target", None)
            m.pop("zone", None)
        if "priority" in e:
            m["priority"] = str(e["priority"]).lower()
    return phases


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--src", required=True)
    ap.add_argument("--out", required=True)
    a = ap.parse_args()
    src, out = Path(a.src), Path(a.out)
    out.mkdir(parents=True, exist_ok=True)
    rows = [json.loads(l) for l in (src / "review_rows.jsonl").read_text(encoding="utf-8").splitlines() if l.strip()]
    prompts = {p["prompt_id"]: p for p in json.loads((src / "review_prompts.json").read_text(encoding="utf-8"))}
    need, kept, dropped = [], [], []
    for r in rows:
        if r["decision"] != "AMEND_PLAN":
            kept.append(r)
            continue
        pk = json.loads(next(m["content"] for m in prompts[r["prompt_id"]]["messages"] if m["role"] == "user"))
        t = to_patch(r["target"], pk)
        if t is None:
            dropped.append({"row_id": r["row_id"], "reason": "not_patchable"})
            continue
        r = dict(r, target=t, proof="dry_run_patch")
        need.append((r, pk))
    B.SCRATCH = out / "_scratch"
    res = B.dry_run([{"row_id": r["row_id"], "packet": pk, "target": r["target"]} for r, pk in need])
    for r, _ in need:
        if res.get(r["row_id"], {}).get("ok"):
            kept.append(r)
        else:
            dropped.append({"row_id": r["row_id"], "reason": "dry_run_failed", "code": res.get(r["row_id"], {}).get("code")})
    kept.sort(key=lambda r: r["row_id"])
    (out / "review_rows.jsonl").write_text("".join(json.dumps(r, ensure_ascii=False) + "\n" for r in kept), encoding="utf-8")
    shutil.copy2(src / "review_prompts.json", out / "review_prompts.json")
    man = {"rows": len(kept), "amend_patched": sum(1 for r in kept if r["decision"] == "AMEND_PLAN"),
           "dropped": len(dropped), "dropped_reasons": {}}
    for d in dropped:
        man["dropped_reasons"][d["reason"] + ":" + str(d.get("code", ""))] = man["dropped_reasons"].get(d["reason"] + ":" + str(d.get("code", "")), 0) + 1
    (out / "CORPUS_MANIFEST.json").write_text(json.dumps(man, indent=1), encoding="utf-8")
    (out / "dropped.json").write_text(json.dumps(dropped, indent=1), encoding="utf-8")
    print(json.dumps(man, indent=1))


if __name__ == "__main__":
    main()
