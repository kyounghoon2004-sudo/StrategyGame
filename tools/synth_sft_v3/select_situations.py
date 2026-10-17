"""CPU-only measured state selection and non-overlapping author assignments.

Writes source situations and compact battle evidence, never synthetic answers.
Authoring remains separately gated on replay exactness.
"""
from __future__ import annotations

import collections
import contextlib
import io
import json
import math
import re

from tools.synth_sft_v3.grind_bank import OUT, digest
from tools.synth_sft_v3.view import dist, parse_now, show

QUOTAS = {"late_contested": 480, "inter_adv_tactical": 420,
          "first_contact_postkill": 180, "large_adv_opening": 120}


def read_jl(path):
    return [json.loads(line) for line in path.read_text(encoding="utf-8").splitlines() if line.strip()]


def features(row):
    op, my, en = parse_now(row)
    red = {uid: u for uid, u in my.items() if u["cls"] != "HQ"}
    blue = {uid: u for uid, u in en.items() if u["cls"] != "HQ"}
    initial_blue = sum(u["class"] != "HQ" for u in op["enemy_units"])
    killed = initial_blue - len(blue)
    need = math.ceil(initial_blue * .7)
    contact = min((dist(a["pos"], b["pos"]) for a in red.values() for b in blue.values()), default=99)
    stale = [uid for uid, order in row["standing_orders"].items()
             if uid in red and isinstance(order, dict) and order.get("do") in ("ATTACK", "RAID")
             and order.get("target", "").startswith("B_") and order["target"] not in en]
    threatened = [uid for uid, u in blue.items() if re.search(r"eta_my_hq\s+[012](?:\s|$)", u["extra"])]
    damaged = [uid for uid, u in red.items() if u["sol"] < u["start"] * .35]
    fortified = [uid for uid, u in blue.items() if u["fort"] > 0]
    cavalry_reach = [(rid, bid) for rid, a in red.items() if a["cls"] == "CAVALRY"
                    for bid, b in blue.items() if b["cls"] in ("ARCHER", "SCOUT") and dist(a["pos"], b["pos"]) <= 6]
    return {"kills_so_far": killed, "kills_required": need, "kills_remaining": need - killed,
            "min_nonHQ_distance": contact, "stale_target_own_units": stale,
            "damaged_own_units": damaged, "fortified_live_enemies": fortified,
            "visible_HQ_threats": threatened, "cavalry_reachable_archer_scout_pairs": cavalry_reach,
            "eligible": bool(red and blue and killed < need),
            "score": len(stale) * 3 + bool(damaged) * 2 + bool(fortified) * 2 + bool(threatened) * 2
                     + bool(cavalry_reach) * 2 + (2 if contact <= 3 else 1 if contact <= 6 else 0)}


def balanced_pick(pool, count, taken, feats, spacing=2):
    """Round-robin real games, ranked by observed opportunities within a game."""
    grouped = collections.defaultdict(list)
    for row in pool:
        if row["id"] not in taken:
            grouped[row["game"]].append(row)
    for rows in grouped.values():
        rows.sort(key=lambda r: (-feats[r["id"]]["score"], r["turn"], r["id"]))
    games = sorted(grouped, key=lambda g: (grouped[g][0]["tier"], grouped[g][0]["style"], grouped[g][0]["army_size"], g))
    picked, turns = [], collections.defaultdict(list)
    while len(picked) < count:
        progress = False
        for game in games:
            candidates = grouped[game]
            index = next((i for i, r in enumerate(candidates)
                          if all(abs(r["turn"] - t) >= spacing for t in turns[game])), None)
            if index is None:
                continue
            row = candidates.pop(index)
            picked.append(row)
            turns[game].append(row["turn"])
            taken.add(row["id"])
            progress = True
            if len(picked) == count:
                break
        if not progress:
            break
    return picked


def main():
    grind = read_jl(OUT / "situations_grind.jsonl")
    late = read_jl(OUT / "situations_late_v3.jsonl")
    all_rows = grind + late
    bank = json.loads((OUT / "bank_grind.json").read_text(encoding="utf-8"))
    bank.update(json.loads((OUT / "bank_late_v3.json").read_text(encoding="utf-8")))
    (OUT / "bank_all_v3.json").write_text(json.dumps(bank, ensure_ascii=False, indent=1), encoding="utf-8")
    with (OUT / "situations_all_v3.jsonl").open("w", encoding="utf-8", newline="\n") as stream:
        for row in all_rows:
            stream.write(json.dumps(row, ensure_ascii=False) + "\n")
    feats, errors = {}, []
    for row in all_rows:
        try:
            feats[row["id"]] = features(row)
        except (KeyError, ValueError, TypeError, IndexError) as exc:
            errors.append({"id": row["id"], "reason": str(exc)})
    previous = {}
    for row in sorted(grind, key=lambda r: (r["game"], r["turn"])):
        f = feats.get(row["id"])
        if not f:
            continue
        prev = previous.get(row["game"])
        f["first_contact"] = bool(prev and prev["min_nonHQ_distance"] > 3 and f["min_nonHQ_distance"] <= 3)
        f["postkill"] = bool(prev and f["kills_so_far"] > prev["kills_so_far"])
        previous[row["game"]] = f
    eligible = [r for r in grind if feats.get(r["id"], {}).get("eligible")]
    taken, groups = set(), {}
    stalled = [r for r in late if feats.get(r["id"], {}).get("eligible") and r["turn"] >= 30]
    groups["late_contested"] = list(stalled)
    taken.update(r["id"] for r in stalled)
    late_pool = [r for r in eligible if r["turn"] >= 30]
    strong_late = [r for r in late_pool if r["tier"] in ("INTER", "ADV")]
    groups["late_contested"] += balanced_pick(strong_late, QUOTAS["late_contested"] - len(stalled), taken, feats)
    if len(groups["late_contested"]) < QUOTAS["late_contested"]:
        groups["late_contested"] += balanced_pick(late_pool, QUOTAS["late_contested"] - len(groups["late_contested"]), taken, feats)
    tactical = [r for r in eligible if 1 < r["turn"] < 30 and r["tier"] in ("INTER", "ADV")
                and feats[r["id"]]["min_nonHQ_distance"] <= 5]
    # Reserve genuinely observed contact/kill-transition rows for their primary group.
    nontransition = [r for r in tactical if not feats[r["id"]]["first_contact"] and not feats[r["id"]]["postkill"]]
    groups["inter_adv_tactical"] = balanced_pick(nontransition, QUOTAS["inter_adv_tactical"], taken, feats)
    transitions = [r for r in eligible if 1 < r["turn"] < 30
                   and (feats[r["id"]]["first_contact"] or feats[r["id"]]["postkill"])]
    groups["first_contact_postkill"] = balanced_pick(transitions, QUOTAS["first_contact_postkill"], taken, feats)
    openings = [r for r in eligible if r["turn"] == 1 and (r["army_size"] >= 12 or r["tier"] == "ADV")]
    groups["large_adv_opening"] = balanced_pick(openings, QUOTAS["large_adv_opening"], taken, feats, spacing=1)
    primary = {r["id"]: category for category, rows in groups.items() for r in rows}
    selected = [r for category in QUOTAS for r in groups[category]]
    assert len(selected) == len(taken) == len(primary)
    assignments = OUT / "assignments"
    assignments.mkdir(exist_ok=True)
    # 4 late batches x120, 3 tactical x140, 3 contact/opening batches x100.
    chunks = [groups["late_contested"][i:i + 120] for i in range(0, len(groups["late_contested"]), 120)]
    chunks += [groups["inter_adv_tactical"][i:i + 140] for i in range(0, len(groups["inter_adv_tactical"]), 140)]
    tail = groups["first_contact_postkill"] + groups["large_adv_opening"]
    chunks += [tail[i:i + 100] for i in range(0, len(tail), 100)]
    files = []
    for index, chunk in enumerate(chunks, 1):
        path = assignments / f"v3_{index:02d}.jsonl"
        with path.open("w", encoding="utf-8", newline="\n") as stream:
            for row in chunk:
                capture = io.StringIO()
                with contextlib.redirect_stdout(capture):
                    show(row)
                stream.write(json.dumps({"sid": row["id"], "primary_category": primary[row["id"]],
                                         "observed_features": feats[row["id"]], "situation": row,
                                         "compact_view": capture.getvalue()}, ensure_ascii=False) + "\n")
        files.append({"file": str(path), "situations": len(chunk), "sha256": digest(path),
                      "by_tier": dict(collections.Counter(r["tier"] for r in chunk)),
                      "by_primary_category": dict(collections.Counter(primary[r["id"]] for r in chunk)),
                      "ids": [r["id"] for r in chunk]})
    manifest = {"stage": "SELECTION_ONLY_REPLAY_GATE_REQUIRED_BEFORE_AUTHORING", "target_situations": sum(QUOTAS.values()),
                "selected_situations": len(selected), "selected_games": len({r["game"] for r in selected}),
                "quotas": QUOTAS, "actual_primary_counts": {c: len(r) for c, r in groups.items()},
                "eligible_T1_large_or_ADV": len(openings), "included_original_empty_stalls": len(stalled),
                "by_tier": dict(collections.Counter(r["tier"] for r in selected)),
                "by_phase": dict(collections.Counter("T1" if r["turn"] == 1 else "T2-10" if r["turn"] <= 10
                                                       else "T11-30" if r["turn"] <= 30 else "T31+" for r in selected)),
                "invalid_state_exclusions": errors, "excluded_terminal_already_won": sum(not f["eligible"] for f in feats.values()),
                "nonoverlap_checked": True, "answer_candidates_written": 0, "assignments": files,
                "guidance_evidence": "PATTERNS_V3.md measured stale target, damaged withdrawal, focus, fortification and cavalry matchups; features are observations, not tactical grades",
                "minimum_variants_per_situation": 2, "recommended_variants_per_situation": 3,
                "original_prompts_unchanged": True}
    (OUT / "selection_manifest.json").write_text(json.dumps(manifest, ensure_ascii=False, indent=2), encoding="utf-8")
    print(json.dumps({k: v for k, v in manifest.items() if k != "assignments"}, ensure_ascii=False))


if __name__ == "__main__":
    main()
