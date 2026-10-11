"""BUILD CORPUS v2 — review corpus relabeled with REVIEW TEACHER v2 (lead QA, 2026-10-01).

Differences from build_corpus.py (v1):
  * pools several harvest dirs (each with games/, games/_windows/, raw/reviews.jsonl);
  * every review is RELABELED with the current teacher (review_teacher.decide);
  * validity: a TEACHER-mode row keeps the live proof only when the live-served label equals the new label
    (VICTORY_ATTEMPT parse=OK + accepted outcome); every other non-KEEP label must pass the production
    dry run (parse_review + vp_compute_review, tools/brain_review/dry_run.gd); ADVANCE also needs an existing
    next_phase_id; KEEP is always contract-valid;
  * MODEL-mode games that ended INVALID keep the reviews BEFORE the faulting turn (valid situations);
  * gates report v2 subkinds (R2c PUSH_HQ / CONSOLIDATE included).

  python -m tools.brain_review.build_corpus_v2 --sources <dir> [<dir> ...] --out <dir> [--rows-min 1500]
"""
from __future__ import annotations

import argparse
import hashlib
import json
import sys
from pathlib import Path

ROOT = Path(r"D:\Game development\Demon slayer\StrategyGame")
sys.path.insert(0, str(ROOT))

from tools.brain_review import build_corpus as B  # noqa: E402
from tools.brain_review.review_teacher import decide, v2_ok  # noqa: E402

MAX_ROWS_PER_GAME = 25
MAX_PER_SUBKIND = 6
SUBKINDS = ("HQ_DEFENSE", "PHASE_DONE", "PHASE_FAIL", "PUSH_HQ", "CONSOLIDATE", "ENGAGE", "PULL_BACK",
            "HOLD_FIRE", "RETARGET", "UNSTALL", "NONE")


def load_source(src: Path):
    games = {}
    for p in sorted((src / "games").glob("*.json")):
        if p.name.endswith(".result.json") or p.name.endswith(".calls.jsonl"):
            continue
        meta = json.loads(p.read_text(encoding="utf-8"))
        if "game_id" in meta:
            meta["_src"] = src.name
            games[(src.name, meta["game_id"])] = meta
    segs = {}
    for wp in sorted((src / "games" / "_windows").glob("w*.godot.log")):
        win = wp.name.split(".")[0]
        for seg in B.split_window_log(wp):
            spec = str(seg["meta"].get("spec_path_abs") or "").replace("\\", "/")
            ep = str((seg["meta"].get("episode") or {}).get("episode_id", ""))
            for key, m in games.items():
                if m["window"] == win and (m.get("episode_id") == ep or ("_%s_" % m.get("seed")) in spec):
                    segs.setdefault(key, []).append(seg)
                    break
    reviews = []
    p = src / "raw" / "reviews.jsonl"
    if p.exists():
        for line in p.read_text(encoding="utf-8").splitlines():
            if line.strip():
                r = json.loads(line)
                r["_src"] = src.name
                reviews.append(r)
    return games, segs, reviews


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--sources", nargs="+", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--rows-min", type=int, default=1500)
    a = ap.parse_args()
    out = Path(a.out)
    out.mkdir(parents=True, exist_ok=True)
    B.SCRATCH = out / "_scratch"

    games, segs, reviews = {}, {}, []
    for s in a.sources:
        g, sg, rv = load_source(Path(s))
        games.update(g)
        segs.update(sg)
        reviews.extend(rv)

    rejected, cands, seen = [], [], set()
    for row in sorted(reviews, key=lambda r: (r["_src"], str(r.get("tag")), float(r.get("ts", 0)))):
        key = (row["_src"], str(row.get("tag") or ""))
        m = games.get(key)
        msgs = row.get("messages") or []
        rj = lambda reason, **kw: rejected.append({"src": key[0], "game_id": key[1], "turn": row.get("turn"), "reason": reason, **kw})  # noqa: E731
        sys_txt = next((str(x.get("content", "")) for x in msgs if x.get("role") == "system"), "")
        if not sys_txt.startswith(B.REVIEW_SYS_PREFIX):
            rj("repair_retry_or_foreign_prompt")
            continue
        try:
            pkt = json.loads(next(str(x.get("content", "")) for x in msgs if x.get("role") == "user"))
        except (StopIteration, ValueError):
            rj("unparseable_packet")
            continue
        if not v2_ok(pkt):
            rj("missing_v2_field")
            continue
        h = B.sha(msgs)
        if h in seen:
            rj("duplicate_prompt")
            continue
        seen.add(h)
        if m is None:
            rj("no_game_metadata")
            continue
        res = m.get("result") or {}
        outcome = res.get("outcome")
        if "error" in res or outcome in ("ABORTED", "TIMEOUT") or int((res.get("brain") or {}).get("brain_failures", 0) or 0) > 0:
            rj("game_%s" % (outcome or "error"))
            continue
        if outcome == "INVALID":
            fault_turn = int((res.get("strict_fault") or {}).get("turn", 0) or 0)
            if int(row.get("turn") or 0) >= fault_turn:
                rj("at_or_after_strict_fault")
                continue
        t = decide(pkt)
        if not t.get("target"):
            rj("teacher_drop:%s" % t.get("drop_reason"))
            continue
        cands.append({"row": row, "pkt": pkt, "t": t, "game": m, "key": key})

    # TEACHER-mode live proof (only where the live label == the v2 label)
    attempts = {}
    for c in cands:
        if c["game"]["mode"] == "TEACHER" and c["key"] not in attempts:
            text = "\n".join(s["text"] for s in segs.get(c["key"], []))
            per_turn = {}
            for x in B.parse_segment(text)[1]:
                per_turn.setdefault(x["turn"], []).append(x)
            attempts[c["key"]] = per_turn
    consumed, admitted, need = {}, [], []
    for c in cands:
        tgt, row = c["t"]["target"], c["row"]
        dec = str(tgt["decision"])
        live = (row.get("teacher") or {}).get("target")
        if c["game"]["mode"] == "TEACHER":
            turn = int(row.get("turn") or 0)
            k = consumed.get((c["key"], turn), 0)
            consumed[(c["key"], turn)] = k + 1
            ats = attempts.get(c["key"], {}).get(turn, [])
            mine = ats[k] if k < len(ats) else None
            if live == tgt and mine and mine["decision"] == dec and mine["parse"] == "OK" and B.outcome_ok(mine["outcome"]):
                c["proof"] = "live"
                admitted.append(c)
                continue
        if dec == "KEEP":
            c["proof"] = "keep"
            admitted.append(c)
        elif dec == "ADVANCE_PHASE":
            ids = [str(p.get("id", "")).upper() for p in (c["pkt"].get("plan_authoring") or {}).get("phases") or []]
            if str(tgt.get("next_phase_id", "")).upper() in ids:
                need.append(c)  # still dry-run: the production path must accept the transition
            else:
                rejected.append({"src": c["key"][0], "game_id": c["key"][1], "turn": row.get("turn"), "reason": "advance_target_missing"})
        else:
            need.append(c)
    if need:
        res = B.dry_run([{"row_id": str(i), "packet": c["pkt"], "target": c["t"]["target"]} for i, c in enumerate(need)])
        for i, c in enumerate(need):
            r = res.get(str(i), {})
            if r.get("ok"):
                c["proof"] = "dry_run"
                admitted.append(c)
            else:
                rejected.append({"src": c["key"][0], "game_id": c["key"][1], "turn": c["row"].get("turn"),
                                 "reason": "dry_run_failed", "detail": r.get("code"), "decision": c["t"]["target"]["decision"]})

    # cap per game (evenly spaced over turn order)
    by_game = {}
    for c in admitted:
        by_game.setdefault(c["key"], []).append(c)
    final = []
    for key in sorted(by_game):
        rows = sorted(by_game[key], key=lambda c: (int(c["row"].get("turn") or 0), float(c["row"].get("ts", 0))))
        # at most MAX_PER_SUBKIND rows of the same teacher outcome per game (evenly spaced): one long game
        # must not repeat the same lesson 20 times
        by_sub = {}
        for c in rows:
            by_sub.setdefault(c["t"]["subkind"], []).append(c)
        keep = set()
        for sub, cs in by_sub.items():
            if len(cs) > MAX_PER_SUBKIND:
                cs = [cs[min(len(cs) - 1, round(i * len(cs) / MAX_PER_SUBKIND))] for i in range(MAX_PER_SUBKIND)]
            keep.update(id(c) for c in cs)
        rows = [c for c in rows if id(c) in keep]
        if len(rows) > MAX_ROWS_PER_GAME:
            idx = sorted({min(len(rows) - 1, round(i * len(rows) / MAX_ROWS_PER_GAME)) for i in range(MAX_ROWS_PER_GAME)})
            rows = [rows[i] for i in idx]
        final.extend(rows)

    # splits: dev = whole games ~8%
    gids = sorted({c["key"] for c in final}, key=lambda k: hashlib.sha256(("%s/%s" % k).encode()).hexdigest())
    dev, dev_n = set(), 0
    for k in gids:
        if dev_n >= 0.08 * len(final):
            break
        dev.add(k)
        dev_n += sum(1 for c in final if c["key"] == k)

    prompts, rows_out = [], []
    for i, c in enumerate(sorted(final, key=lambda c: (c["key"], int(c["row"].get("turn") or 0), float(c["row"].get("ts", 0))))):
        m, tgt, row = c["game"], c["t"]["target"], c["row"]
        pid = "p%05d" % i
        prompts.append({"prompt_id": pid, "messages": row["messages"]})
        rows_out.append({"row_id": "r%05d" % i, "prompt_id": pid, "target": tgt,
                         "split": "dev" if c["key"] in dev else "train",
                         "decision": tgt["decision"], "subkind": c["t"]["subkind"], "rule": c["t"]["rule"],
                         "proof": c["proof"], "trigger": row.get("trigger"), "also_due": row.get("also_due") or [],
                         "turn": row.get("turn"), "active_phase": row.get("active_phase"),
                         "source": c["key"][0], "game_id": c["key"][1], "window": m["window"], "mode": m["mode"],
                         "episode_id": m.get("episode_id"), "gx_profile": m.get("gx_profile"),
                         "family": m.get("family"), "seed": m.get("seed")})
    (out / "review_rows.jsonl").write_text("".join(json.dumps(r, ensure_ascii=False) + "\n" for r in rows_out), encoding="utf-8")
    (out / "review_prompts.json").write_text(json.dumps(prompts, ensure_ascii=False), encoding="utf-8")

    n = len(rows_out)
    cnt = lambda f: {k: sum(1 for r in rows_out if f(r) == k) for k in sorted({f(r) for r in rows_out})}  # noqa: E731
    rej = {}
    for r in rejected:
        rej[r["reason"]] = rej.get(r["reason"], 0) + 1
    manifest = {
        "teacher": "review_teacher v2", "sources": [str(s) for s in a.sources], "rows": n,
        "train": sum(1 for r in rows_out if r["split"] == "train"), "dev": sum(1 for r in rows_out if r["split"] == "dev"),
        "games_with_rows": len(by_game), "decisions": cnt(lambda r: r["decision"]),
        "subkinds": {s: sum(1 for r in rows_out if r["subkind"] == s) for s in SUBKINDS},
        "proof": cnt(lambda r: r["proof"]), "mode": cnt(lambda r: r["mode"]),
        "tier": cnt(lambda r: (r.get("gx_profile") or "?").split("_")[1] if r.get("gx_profile") else "?"),
        "family": cnt(lambda r: r["family"]), "active_phase": cnt(lambda r: str(r["active_phase"])),
        "rows_min_ok": n >= a.rows_min, "rejected": rej,
        "sha256": {"review_rows.jsonl": B.sha_file(out / "review_rows.jsonl"),
                   "review_prompts.json": B.sha_file(out / "review_prompts.json")},
    }
    (out / "CORPUS_MANIFEST.json").write_text(json.dumps(manifest, indent=1, ensure_ascii=False), encoding="utf-8")
    (out / "rejected.json").write_text(json.dumps(rejected, indent=1, ensure_ascii=False), encoding="utf-8")
    print(json.dumps({k: manifest[k] for k in ("rows", "train", "dev", "decisions", "subkinds", "proof", "mode", "rejected")}, indent=1))


if __name__ == "__main__":
    main()
