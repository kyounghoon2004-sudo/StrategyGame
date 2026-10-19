"""Teacher-game SFT set (2026-10-19, user: train on the collected teacher games to see if the data is sufficient and good).
Source = what the student would see and what the game recorded: inbox/req_NNNN.json (messages after the relay shim, no AID) and
resp_NNNN.txt (= the assistant message the next request carries). Never bridge.jsonl content (AID, forecasts, "FOLLOW THE PLAN").
One multi-turn row per stretch of turns whose requests extend each other (a relay starts a new stretch); a dropped turn ends a
stretch and the next one starts after it, so it is history only, never a target.
Kept: strata WIN games g020+ not in EXCLUDED_regen.json, blockade import WIN games with plan_switch_rule=true (MANIFEST.json).
Dropped turns: bridge fallback / plan_too_long, retry requests, old-rule answers that talk about re-digging, failed format checks.
Old-rule games (strata g020-g106): the FORTIFY sentence of the system prompt is replaced by the new rule's sentence (exactly once).
Holdout: about 10% of the games of each tier, chosen by game (never by turn).
  python -m tools.synth_adv_v1.build_teacher_sft --out <dir> [--keep-plan-lag]
"""
import argparse, glob, hashlib, json, os, re
from collections import Counter, defaultdict

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..")
SYN = os.path.join(ROOT, "artifacts", "brain_pipeline_v1", "synth_adv_v1")
STRATA = os.path.join(SYN, "teacher_play", "strata")
BLOCKADE = os.path.join(SYN, "blockade_import_2026-10-19")
OLD_FORT = "While the order stands it digs in again whenever its fieldworks are destroyed."
NEW_FORT = ("Each unit can fortify only ONCE per game: when its fieldworks are destroyed or left, they are gone for good and it "
            "cannot dig in again.")
REDIG = re.compile(r"rebuil|re-?dig|digs? in again|regenerat", re.I)
AID_MARKS = ("SIEGE TIMING", "FOLLOW THE STANDING PLAN", "THINK BRIEFLY", "Fieldworks damage accumulates")
RESULT = re.compile(r"^\S+ \S+ (g(\d+)_(\w+?)_hist\w+) .*?(\{.*)$")


def results(d):
    out = {}
    for l in open(os.path.join(d, "results.log"), encoding="utf-8"):
        m = RESULT.match(l.rstrip("\n"))
        if m:
            try:
                out[m.group(1)] = (int(m.group(2)), m.group(3), json.loads(m.group(4)).get("kind"))
            except ValueError:
                pass
    return out


def bridge_flags():
    bad = set()
    for l in open(os.path.join(STRATA, "bridge.jsonl"), encoding="utf-8"):
        r = json.loads(l)
        if r.get("fallback") or r.get("plan_too_long"):
            bad.add(os.path.normcase(os.path.abspath(r["req"])))
    return bad


def check(ans_txt, q, need_plan):
    """Code-only format checks of one answer; returns a reason or None."""
    try:
        a = json.loads(ans_txt)
    except ValueError:
        return "json"
    if not isinstance(a, dict) or not isinstance(a.get("orders", {}), dict):
        return "shape"
    p = a.get("plan")
    if p is not None and len(str(p)) > 300:
        return "plan>300"
    if need_plan and not str(p or "").strip():
        return "no plan on a plan turn"
    ids = {u.get("id") for u in (q.get("state") or {}).get("my_units", [])}
    if ids and any(k not in ids for k in a.get("orders", {})):
        return "unknown unit id"
    return None


def game_rows(gdir, tier, legacy, flagged, stats):
    I = os.path.join(gdir, "inbox")
    reqs = []
    for f in sorted(glob.glob(os.path.join(I, "req_*.json"))):
        q = json.load(open(f, encoding="utf-8"))
        r = f.replace("req_", "resp_").replace(".json", ".txt")
        reqs.append((f, q, open(r, encoding="utf-8").read().strip() if os.path.exists(r) else None))
    for _, q, _ in reqs:
        s = json.dumps(q["messages"], ensure_ascii=False)
        assert not any(m in s for m in AID_MARKS), "AID text in a student request: " + gdir
    rows, seg = [], None  # seg = [first_target, last (q, resp)]

    def close():
        if seg and seg[1] is not None:
            q, resp = seg[1]
            rows.append({"multi": True, "messages": q["messages"] + [{"role": "assistant", "content": resp}],
                         "first_target": seg[0]})

    prev = None
    for f, q, resp in reqs:
        msgs = q["messages"]
        cont = (prev is not None and seg is not None and len(msgs) == len(prev[0]["messages"]) + 2
                and msgs[:len(prev[0]["messages"])] == prev[0]["messages"] and msgs[len(prev[0]["messages"])]["role"] == "assistant")
        start_turn = len(msgs) == 2  # turn 1 or a relay turn: a plan is required
        why = None
        if q.get("retry"):
            why = "retry"
        elif resp is None:
            why = "no resp"
        elif os.path.normcase(os.path.abspath(f)) in flagged:
            why = "bridge flag"
        elif legacy and REDIG.search(resp):
            why = "old-rule re-dig talk"
        else:
            why = check(resp, q, start_turn)
        if not cont:
            close()
            seg = [len(msgs), None]
        if why:
            stats["dropped_" + why] += 1
            close()
            seg = None  # the next request starts a new stretch; this answer stays history only
            prev = None
            continue
        if seg is None:
            seg = [len(msgs), None]
        seg[1] = (q, resp)
        stats["turns"] += 1
        a = json.loads(resp)
        stats["plan_turns"] += bool(str(a.get("plan") or "").strip())
        stats["empty_orders"] += not a.get("orders")
        prev = (q, resp)
    close()
    if legacy:
        for r in rows:
            s = r["messages"][0]["content"]
            assert r["messages"][0]["role"] == "system" and s.count(OLD_FORT) == 1, "old FORTIFY sentence not found once: " + gdir
            r["messages"][0] = dict(r["messages"][0], content=s.replace(OLD_FORT, NEW_FORT))
    else:
        for r in rows:
            assert NEW_FORT.split(":")[0] in r["messages"][0]["content"], "new FORTIFY sentence missing: " + gdir
    for r in rows:
        r["meta"] = {"game": os.path.relpath(gdir, SYN).replace("\\", "/"), "tier": tier, "rule": "legacy" if legacy else "once"}
    return rows


def holdout(name):
    return int(hashlib.md5(name.encode()).hexdigest(), 16) % 10 == 0


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", required=True)
    ap.add_argument("--keep-plan-lag", action="store_true", help="also keep blockade games with plan_switch_rule=false")
    a = ap.parse_args()
    excluded = set(json.load(open(os.path.join(STRATA, "EXCLUDED_regen.json"), encoding="utf-8")))
    flagged = bridge_flags()
    games = []  # (dir, tier, legacy)
    for g, (no, tier, kind) in sorted(results(STRATA).items(), key=lambda kv: kv[1][0]):
        if no >= 20 and kind == "WIN" and g not in excluded:
            games.append((os.path.join(STRATA, g), tier, no <= 106))
    man = json.load(open(os.path.join(BLOCKADE, "MANIFEST.json"), encoding="utf-8"))
    lag = 0
    for x in man["games"]:
        if not x["plan_switch_rule"] and not a.keep_plan_lag:
            lag += 1
            continue
        games.append((os.path.join(BLOCKADE, "teacher_play", x["name"], x["game"]), "BLOCKADE", False))
    stats = defaultdict(Counter)
    split = {"train": [], "val": []}
    ngames = defaultdict(Counter)
    for gdir, tier, legacy in games:
        rows = game_rows(gdir, tier, legacy, flagged, stats[tier])
        part = "val" if holdout(os.path.relpath(gdir, SYN)) else "train"
        split[part] += rows
        ngames[tier][part] += 1
    os.makedirs(a.out, exist_ok=True)
    for part, rows in split.items():
        json.dump(rows, open(os.path.join(a.out, part + ".json"), "w", encoding="utf-8"), ensure_ascii=False)
    manifest = {"games": {t: dict(c) for t, c in ngames.items()}, "blockade_dropped_plan_lag": lag,
                "turn_stats": {t: dict(c) for t, c in stats.items()},
                "rows": {p: len(r) for p, r in split.items()}, "excluded_regen_games": len(excluded),
                "sources": {"strata": "teacher_play/strata g020+ WIN, not EXCLUDED_regen", "blockade": "blockade_import_2026-10-19"}}
    json.dump(manifest, open(os.path.join(a.out, "MANIFEST.json"), "w", encoding="utf-8"), indent=1)
    print(json.dumps(manifest, indent=1))


if __name__ == "__main__":
    main()
