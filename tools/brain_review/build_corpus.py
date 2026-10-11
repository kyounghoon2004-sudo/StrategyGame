"""BUILD CORPUS — assemble artifacts/brain_pipeline_v1/review_corpus from harvested games.

Inputs (written by tools/brain_review/harvest.py):
  games/<gid>.json          per-game metadata + live match result
  games/_windows/wN.godot.log  full per-window game log (marker-split here)
  raw/reviews.jsonl         every VICTORY_REVIEW with the exact messages + teacher decision
  raw/calls.jsonl           every Brain/proxy call (raw outputs)

Row admission (per COLD_PROMPT_PHASE2_REVIEW_CORPUS.md):
  * teacher target present (teacher drops are reported by reason, never repaired);
  * packet has every v2 field (compact_state, force_feedback,
    mission_statuses[].units_source);
  * first-attempt VICTORY_REVIEW prompts only (repair retries excluded);
  * no duplicate prompts (sha256 of the exact messages);
  * game admitted: no brain_failures, outcome not INVALID/ABORTED/TIMEOUT;
  * TEACHER mode: the target was applied by the live game (game-log line
    VICTORY_ATTEMPT ... parse=OK ... outcome=KEPT|STAGED|APPLIED, decision
    equal to the target's). FAILED / REJECTED / STRICT rows are rejected;
  * MODEL mode: KEEP admitted; ADVANCE_PHASE admitted when next_phase_id
    exists in plan_authoring; AMEND_PLAN admitted only when it passes the
    headless dry run through production parse_review + vp_compute_review
    (tools/brain_review/dry_run.gd).
  * at most 25 rows per game (evenly spaced across the game).

Splits: dev = whole games, about 8% of rows (deterministic order by
sha256(game_id)); a game never spans splits.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(r"D:\Game development\Demon slayer\StrategyGame")
sys.path.insert(0, str(ROOT))

from tools.brain_review.review_teacher import decide, v2_ok  # noqa: E402
from tools.contextual_brain.rl_vs_utility import score, GODOT, S0B  # noqa: E402

OUT = ROOT / "artifacts" / "brain_pipeline_v1" / "review_corpus"
SCRATCH = OUT / "_scratch"

REQ_START = re.compile(r"\[CloudTurn\] VICTORY_REQUEST_START kind=REVIEW trigger=(\S+) turn=(\d+) req=(\S+) call=(\S+)")
ATTEMPT = re.compile(r"\[CloudTurn\] VICTORY_ATTEMPT call=(\S+) kind=REVIEW(?:\S*) turn=(\d+) req=(\S+) http=(\S+) "
                     r"lat=(\d+)ms finish=(\S+) final=(\d+)chars reasoning=\S+ usage=\S+ budget=(\d+) "
                     r"parse=(\S+) decision=(\S+) outcome=(\S+)")
WATCH_SEG = re.compile(r"^\[Watch\] START (\{.*\})\s*$", re.M)
STAGED_ADOPT = re.compile(r"\[CloudTurn\] VICTORY_PLAN_ADOPTED v(\d+) \(staged; decision=(\S+) ")
STAGED_BAD = re.compile(r"\[CloudTurn\] VICTORY staged rev (REJECTED|STALE)")
REVIEW_SYS_PREFIX = "You are the RED general reviewing"
MAX_ROWS_PER_GAME = 25
ACCEPT_OUTCOME = ("KEPT", "APPLIED", "STAGED")


def sha(obj) -> str:
    return hashlib.sha256(json.dumps(obj, sort_keys=True, ensure_ascii=False).encode("utf-8")).hexdigest()


def outcome_ok(outcome: str) -> bool:
    return outcome.startswith("KEPT") or outcome.startswith("APPLIED") or outcome in ("STAGED", "STAGED_ADOPTED")


def split_window_log(path: Path):
    """{game marker key: segment text} split on '[Watch] START {...}' lines."""
    text = path.read_text(encoding="utf-8", errors="replace")
    marks = list(WATCH_SEG.finditer(text))
    segs = []
    for i, m in enumerate(marks):
        end = marks[i + 1].start() if i + 1 < len(marks) else len(text)
        try:
            meta = json.loads(m.group(1))
        except ValueError:
            meta = {}
        segs.append({"meta": meta, "text": text[m.start():end]})
    return segs


def parse_segment(seg_text: str):
    starts = []   # (turn, trigger, req, call)
    attempts = []  # dicts
    for line in seg_text.splitlines():
        m = REQ_START.search(line)
        if m:
            starts.append({"turn": int(m.group(2)), "trigger": m.group(1), "req": m.group(3), "call": m.group(4)})
            continue
        m = ATTEMPT.search(line)
        if m:
            attempts.append({"call": m.group(1), "turn": int(m.group(2)), "req": m.group(3), "http": m.group(4),
                             "finish": m.group(6), "parse": m.group(9), "decision": m.group(10),
                             "outcome": m.group(11)})
    return starts, attempts


def dry_run(rows):
    """rows: [{row_id, packet, target}] -> {row_id: result} via production code in Godot."""
    if not rows:
        return {}
    SCRATCH.mkdir(parents=True, exist_ok=True)
    inp = SCRATCH / "dry_in.jsonl"
    outp = SCRATCH / "dry_out.jsonl"
    inp.write_text("\n".join(json.dumps(r, ensure_ascii=False) for r in rows), encoding="utf-8")
    outp.unlink(missing_ok=True)
    env = dict(os.environ, BRAIN_CONTRACT_MODE="unalloc_v1",
               DRYRUN_IN=str(inp), DRYRUN_OUT=str(outp))
    r = subprocess.run([GODOT, "--headless", "--path", str(ROOT), "-s", "res://tools/brain_review/dry_run.gd"],
                       env=env, capture_output=True, text=True, timeout=3600)
    if not outp.exists():
        raise SystemExit("dry-run harness produced no output (rc=%s)\n%s" % (r.returncode, r.stdout[-2000:]))
    return {x["row_id"]: x for x in (json.loads(l) for l in outp.read_text(encoding="utf-8").splitlines() if l.strip())}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--rows-min", type=int, default=1500)
    ap.add_argument("--games-min", type=int, default=120)
    a = ap.parse_args()

    games = {}
    for p in sorted((OUT / "games").glob("*.json")):
        if p.name == "index.jsonl" or p.name.endswith(".result.json"):
            continue
        meta = json.loads(p.read_text(encoding="utf-8"))
        if "game_id" not in meta:
            continue
        games[meta["game_id"]] = meta

    # ---- per-game window log segments + raw call logs
    segs_by_game = {}
    for wp in sorted((OUT / "games" / "_windows").glob("w*.godot.log")):
        win = wp.name.split(".")[0]
        for seg in split_window_log(wp):
            spec = str((seg["meta"].get("spec_path_abs") or ""))
            ep = str((seg["meta"].get("episode") or {}).get("episode_id", ""))
            gid = next((g for g, m in games.items()
                        if m["window"] == win and (m.get("episode_id") == ep or
                                                   (m.get("seed") and ("_%s_" % m["seed"]) in spec.replace("\\", "/")))),
                       None)
            if gid:
                segs_by_game.setdefault(gid, []).append(seg)

    calls = []
    reviews = []
    for name, bucket in (("calls.jsonl", calls), ("reviews.jsonl", reviews)):
        p = OUT / "raw" / name
        if p.exists():
            for line in p.read_text(encoding="utf-8").splitlines():
                if line.strip():
                    bucket.append(json.loads(line))

    # per-game raw call logs (deliverable: games/ per-game raw call logs)
    for gid, m in games.items():
        rows = [c for c in calls if c.get("tag") == gid or (c.get("window") == m["window"] and
                m["started_ts"] - 5 <= float(c.get("ts", 0)) <= m["ended_ts"] + 60)]
        with open(OUT / "games" / ("%s.calls.jsonl" % gid), "w", encoding="utf-8") as f:
            for c in rows:
                f.write(json.dumps(c, ensure_ascii=False) + "\n")

    rejected = []
    candidates = []
    seen_prompts = {}
    for row in sorted(reviews, key=lambda r: (str(r.get("tag")), float(r.get("ts", 0)))):
        gid = str(row.get("tag") or "")
        m = games.get(gid)
        msgs = row.get("messages") or []
        sys_txt = next((str(x.get("content", "")) for x in msgs if x.get("role") == "system"), "")
        if not sys_txt.startswith(REVIEW_SYS_PREFIX):
            rejected.append({"game_id": gid, "turn": row.get("turn"), "reason": "repair_retry_or_foreign_prompt"})
            continue
        pkt = None
        for x in msgs:
            if x.get("role") == "user" and str(x.get("content", "")).startswith("{"):
                try:
                    pkt = json.loads(x.get("content", ""))
                except ValueError:
                    pkt = None
                break
        if pkt is None:
            rejected.append({"game_id": gid, "turn": row.get("turn"), "reason": "unparseable_packet"})
            continue
        if not v2_ok(pkt):
            rejected.append({"game_id": gid, "turn": row.get("turn"), "reason": "missing_v2_field"})
            continue
        h = sha(msgs)
        if h in seen_prompts:
            rejected.append({"game_id": gid, "turn": row.get("turn"), "reason": "duplicate_prompt"})
            continue
        seen_prompts[h] = gid
        t = row.get("teacher") or {}
        if not t.get("target"):
            rejected.append({"game_id": gid, "turn": row.get("turn"), "reason": "teacher_drop:%s" % t.get("drop_reason")})
            continue
        if m is None:
            rejected.append({"game_id": gid, "turn": row.get("turn"), "reason": "no_game_metadata"})
            continue
        res = m.get("result") or {}
        bad_game = ("error" in res) or res.get("outcome") in ("INVALID", "ABORTED", "TIMEOUT") or \
            int(((res.get("brain") or {}).get("brain_failures", 0)) or 0) > 0
        if bad_game:
            rejected.append({"game_id": gid, "turn": row.get("turn"), "reason": "game_%s" % (res.get("outcome") or "error")})
            continue
        candidates.append({"row": row, "pkt": pkt, "target": t["target"], "rule": t.get("rule"),
                           "subkind": t.get("subkind"), "why": t.get("why"), "game": m})

    # ---- TEACHER-mode proof: game-log VICTORY_ATTEMPT join (ordered per turn)
    attempts_by_game = {}
    for gid in {c["game"]["game_id"] for c in candidates if c["game"]["mode"] == "TEACHER"}:
        seg_text = "\n".join(s["text"] for s in segs_by_game.get(gid, []))
        _starts, attempts = parse_segment(seg_text)
        per_turn = {}
        for x in attempts:
            per_turn.setdefault(x["turn"], []).append(x)
        attempts_by_game[gid] = per_turn
    consumed = {}
    admitted = []
    for c in candidates:
        m, row, tgt = c["game"], c["row"], c["target"]
        decision = str(tgt.get("decision"))
        if m["mode"] == "TEACHER":
            turn = int(row.get("turn") or 0)
            ats = attempts_by_game.get(m["game_id"], {}).get(turn, [])
            k = consumed.get((m["game_id"], turn), 0)
            consumed[(m["game_id"], turn)] = k + 1
            mine = ats[k] if k < len(ats) else None
            if mine is None or mine["decision"] != decision or mine["parse"] != "OK" or not outcome_ok(mine["outcome"]):
                rejected.append({"game_id": m["game_id"], "turn": row.get("turn"),
                                 "reason": "target_not_applied", "decision": decision,
                                 "seen": mine})
                continue
            c["proof"] = mine
            admitted.append(c)
        else:  # MODEL mode
            if decision == "KEEP":
                admitted.append(c)
            elif decision == "ADVANCE_PHASE":
                ids = [str(p.get("id", "")).upper() for p in ((c["pkt"].get("plan_authoring") or {}).get("phases") or [])]
                if str(tgt.get("next_phase_id", "")).upper() in ids:
                    admitted.append(c)
                else:
                    rejected.append({"game_id": m["game_id"], "turn": row.get("turn"),
                                     "reason": "advance_target_missing", "decision": decision})
            else:
                c["_needs_dry_run"] = True
                admitted.append(c)

    # ---- MODEL AMEND dry run through production parse_review + vp_compute_review
    need = [c for c in admitted if c.get("_needs_dry_run")]
    if need:
        res = dry_run([{"row_id": str(i), "packet": c["pkt"], "target": c["target"]} for i, c in enumerate(need)])
        kept = []
        for i, c in enumerate(need):
            r = res.get(str(i), {})
            if r.get("ok"):
                c["_dry_run"] = r
                kept.append(c)
            else:
                rejected.append({"game_id": c["game"]["game_id"], "turn": c["row"].get("turn"),
                                 "reason": "model_amend_dry_run_failed", "detail": r.get("code"),
                                 "decision": "AMEND_PLAN"})
        admitted = [c for c in admitted if not c.get("_needs_dry_run")] + kept

    # ---- cap 25 rows per game (evenly spaced over turn order)
    by_game = {}
    for c in admitted:
        by_game.setdefault(c["game"]["game_id"], []).append(c)
    trimmed = 0
    final = []
    for gid in sorted(by_game):
        rows = sorted(by_game[gid], key=lambda c: (int(c["row"].get("turn") or 0), float(c["row"].get("ts", 0))))
        if len(rows) > MAX_ROWS_PER_GAME:
            idx = sorted({min(len(rows) - 1, round(i * len(rows) / MAX_ROWS_PER_GAME)) for i in range(MAX_ROWS_PER_GAME)})
            picked = [rows[i] for i in idx]
            trimmed += len(rows) - len(picked)
            rows = picked
        final.extend(rows)

    # ---- splits: dev = whole games ~= 8% of rows
    order = sorted({c["game"]["game_id"] for c in final}, key=lambda g: hashlib.sha256(g.encode()).hexdigest())
    total = len(final)
    dev_games, dev_rows = set(), 0
    for gid in order:
        n = sum(1 for c in final if c["game"]["game_id"] == gid)
        if dev_rows + n <= max(1, round(0.08 * total)) or not dev_games:
            dev_games.add(gid)
            dev_rows += n
        if dev_rows >= 0.08 * total:
            break

    # ---- write rows + prompts
    final.sort(key=lambda c: (c["game"]["game_id"], int(c["row"].get("turn") or 0), float(c["row"].get("ts", 0))))
    prompts = []
    rows_out = []
    for i, c in enumerate(final):
        pid = "p%05d" % i
        m = c["game"]
        tgt = c["target"]
        prompts.append({"prompt_id": pid, "messages": c["row"]["messages"]})
        rows_out.append({
            "row_id": "r%05d" % i, "prompt_id": pid, "target": tgt,
            "split": "dev" if m["game_id"] in dev_games else "train",
            "decision": str(tgt.get("decision")), "subkind": c["subkind"], "rule": c["rule"],
            "trigger": c["row"].get("trigger"), "also_due": c["row"].get("also_due") or [],
            "turn": c["row"].get("turn"), "active_phase": c["row"].get("active_phase"),
            "game_id": m["game_id"], "window": m["window"], "mode": m["mode"],
            "episode_id": m.get("episode_id") or c["row"].get("episode_id"),
            "episode_spec_path": m.get("episode_spec_path") or c["row"].get("spec_path"),
            "gx_profile": m.get("gx_profile"), "family": m.get("family"), "seed": m.get("seed"),
        })
    rows_path = OUT / "review_rows.jsonl"
    prompts_path = OUT / "review_prompts.json"
    with open(rows_path, "w", encoding="utf-8") as f:
        for r in rows_out:
            f.write(json.dumps(r, ensure_ascii=False) + "\n")
    prompts_path.write_text(json.dumps(prompts, ensure_ascii=False), encoding="utf-8")

    # ---- gates
    # ---- gates & counts
    n = len(rows_out)
    per_game = {}
    for r in rows_out:
        per_game[r["game_id"]] = per_game.get(r["game_id"], 0) + 1

    def _is_p2plus(pid):
        mm = re.search(r"(\d+)", str(pid or ""))
        return (int(mm.group(1)) >= 2) if mm else str(pid) != "P1"

    decision_counts = {
        "KEEP": sum(1 for r in rows_out if r["decision"] == "KEEP"),
        "ADVANCE_PHASE": sum(1 for r in rows_out if r["decision"] == "ADVANCE_PHASE"),
        "AMEND_PLAN": sum(1 for r in rows_out if r["decision"] == "AMEND_PLAN"),
    }
    subkind_counts = {
        s: sum(1 for r in rows_out if r["subkind"] == s)
        for s in ("HQ_DEFENSE", "ENGAGE", "PULL_BACK", "HOLD_FIRE", "RETARGET", "UNSTALL", "PHASE_DONE", "PHASE_FAIL", "NONE")
    }
    source_coverage = {
        "active_phase": {
            "P1": sum(1 for r in rows_out if str(r["active_phase"]) == "P1"),
            "P2": sum(1 for r in rows_out if str(r["active_phase"]) == "P2"),
            "P3_plus": sum(1 for r in rows_out if _is_p2plus(r["active_phase"]) and str(r["active_phase"]) != "P2"),
        },
        "gx_tier": {t: sum(1 for r in rows_out if (r.get("gx_profile") or "").startswith("GX_%s_" % t)) for t in ("BASIC", "INTER", "ADV")},
        "gx_style": {s: sum(1 for r in rows_out if ("_%s" % s) in (r.get("gx_profile") or "")) for s in ("SPEARHEAD", "BULWARK", "OUTRIDER", "HARRIER")},
        "family": {f: sum(1 for r in rows_out if r["family"] == f) for f in ("mild", "broad")},
        "mode": {mo: sum(1 for r in rows_out if r["mode"] == mo) for mo in ("TEACHER", "MODEL")},
        "triggers": _count(rows_out, "trigger"),
        "rules": _count(rows_out, "rule"),
        "per_game": per_game,
    }

    gates = {
        "games_min": {"value": len(games), "ok": len(games) >= a.games_min, "want": ">= %d" % a.games_min},
        "rows_min": {"value": n, "ok": n >= a.rows_min, "want": ">= %d" % a.rows_min},
        "max_rows_per_game": {"value": max(per_game.values()) if per_game else 0, "ok": (max(per_game.values()) if per_game else 0) <= 25, "want": "<= 25"},
    }

    rej_counts = {}
    for r in rejected:
        rej_counts[r["reason"]] = rej_counts.get(r["reason"], 0) + 1

    manifest = {
        "total_games": len(games),
        "games_with_admitted_rows": len(per_game),
        "total_admitted_rows": n,
        "train_rows": sum(1 for r in rows_out if r["split"] == "train"),
        "dev_rows": sum(1 for r in rows_out if r["split"] == "dev"),
        "prompts": len(prompts),
        "decision_counts": decision_counts,
        "subkind_counts": subkind_counts,
        "source_coverage_counts": source_coverage,
        "gates": gates,
        "all_gates_pass": all(g["ok"] for g in gates.values()),
        "rejection_counts_by_reason": rej_counts,
        "rejected_total": len(rejected),
        "sha256": {
            "review_rows.jsonl": sha_file(rows_path),
            "review_prompts.json": sha_file(prompts_path),
        },
    }
    (OUT / "CORPUS_MANIFEST.json").write_text(json.dumps(manifest, indent=1, ensure_ascii=False), encoding="utf-8")
    (OUT / "rejected.json").write_text(json.dumps({"counts": rej_counts, "rows": rejected}, indent=1, ensure_ascii=False), encoding="utf-8")
    print(json.dumps({"rows": n, "games": len(games), "all_gates_pass": manifest["all_gates_pass"], "gates": gates, "rejected": rej_counts}, indent=1))


def _count(rows, key):
    out = {}
    for r in rows:
        out[str(r[key])] = out.get(str(r[key]), 0) + 1
    return dict(sorted(out.items()))


def sha_file(p: Path) -> str:
    return hashlib.sha256(p.read_bytes()).hexdigest()


if __name__ == "__main__":
    main()
