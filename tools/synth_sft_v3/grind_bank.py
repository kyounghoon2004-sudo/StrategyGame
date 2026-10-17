"""Gate A: reconstruct complete real grind wins without inventing terminal answers.

The engine's terminal turn is one later than the last RED commander decision in
these wins. Completeness is checked against every RED-to-act record snapshot and
the recorded COMMAND count, not by adding an answer after the battle is over.
Original harvest completion values are preserved verbatim.

python -m tools.synth_sft_v3.grind_bank
"""
from __future__ import annotations

import collections
import hashlib
import json
import re
from pathlib import Path

from tools.synth_sft_v2.bank import overlay_of

ROOT = Path(__file__).resolve().parents[2]
BP = ROOT / "artifacts" / "brain_pipeline_v1"
OUT = BP / "synth_sft_v3"
RUNS = ("seed_grind_v1", "seed_grind_v2_inter_adv")
NAME = re.compile(r"s(\d+)_(it\d+)_r(\d+)")


def digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def decode_answer(value):
    """Read the accepted answer after its recorded Qwen reasoning wrapper.

    This never changes the completion stored in the bank or situation. Extraction
    uses the same CPU-only parser used by the real commander collection.
    """
    if not isinstance(value, str):
        return value
    from tools.plan_search.cloud_brain import extract_orders
    text = value.split("</think>", 1)[-1] if "</think>" in value else value
    answer = extract_orders(text)
    if answer is None:
        raise ValueError("No accepted commander JSON in recorded completion")
    return answer


decoded = decode_answer


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    bank, exclusions, evidence, sources, call_cache, observed_anomalies = {}, [], [], [], {}, []
    input_rows = 0
    for run in RUNS:
        run_dir = BP / run
        harvest = run_dir / "harvest" / "sft_rows_wins.json"
        seed_file = run_dir / "seeds.json"
        rows = json.loads(harvest.read_text(encoding="utf-8"))
        seed_rows = json.loads(seed_file.read_text(encoding="utf-8"))
        seeds = {int(s["seed"]): s for s in seed_rows}
        if len(seeds) != len(seed_rows):
            raise ValueError(f"Duplicate seed metadata in {seed_file}")
        sources.extend({"path": str(p), "sha256": digest(p)} for p in (harvest, seed_file))
        input_rows += len(rows)
        groups = collections.defaultdict(list)
        for idx, row in enumerate(rows):
            groups[row["game"]].append((idx, row))
        for game, indexed in sorted(groups.items()):
            reasons = []
            match = NAME.fullmatch(game)
            if not match:
                exclusions.append({"game": game, "run": run, "reasons": ["invalid_game_name"]})
                continue
            seed_text, iteration, _ = match.groups()
            seed = int(seed_text)
            gf = run_dir / "seeds" / seed_text / iteration / "games" / (game + ".json")
            try:
                rec = json.loads(gf.read_text(encoding="utf-8"))
                meta = seeds[seed]
                captures = gf.parent.parent / "captures" / "calls.jsonl"
                if captures not in call_cache:
                    capture_rows = [json.loads(l) for l in captures.read_text(encoding="utf-8").splitlines() if l.strip()]
                    call_cache[captures] = {(c.get("tag"), int(c.get("turn") or 0)): c for c in capture_rows
                                            if c.get("request") == "VICTORY_COMMAND" and c.get("raw")
                                            and (c.get("local") or {}).get("completion")}
                    sources.append({"path": str(captures), "sha256": digest(captures)})
                snaps = rec["record"]["snapshots"]
                red_turns = sorted({s["turn"] for s in snaps if s.get("to_act") == "red"})
                turns = sorted(r["turn"] for _, r in indexed)
                final_turn = int(rec["turn"])
                if not turns or turns != list(range(1, max(turns) + 1)):
                    reasons.append("duplicate_or_missing_harvest_turns")
                if turns != red_turns:
                    reasons.append(f"harvest_turns_differ_from_RED_decisions: harvest={turns}, record={red_turns}")
                count = rec.get("brain", {}).get("decisions", {}).get("COMMAND")
                if count != len(turns):
                    reasons.append(f"record_COMMAND_count_mismatch: {count} != {len(turns)}")
                if rec.get("outcome") != "RED_WIN":
                    reasons.append(f"not_RED_WIN: {rec.get('outcome')}")
                if rec.get("strict_fault"):
                    reasons.append(f"strict_fault: {rec['strict_fault']}")
                if not snaps or not snaps[-1].get("final") or snaps[-1].get("turn") != final_turn:
                    reasons.append("missing_or_inconsistent_terminal_snapshot")
                if final_turn not in (max(turns), max(turns) + 1):
                    reasons.append("terminal_turn_not_adjacent_to_final_decision")
                for _, row in indexed:
                    call = call_cache[captures].get((game, row["turn"]))
                    if call is None:
                        reasons.append(f"missing_original_served_call_at_t{row['turn']}")
                        continue
                    if call["local"]["completion"] != row["completion"] or call["messages"] != row["messages"]:
                        reasons.append(f"capture_harvest_mismatch_at_t{row['turn']}")
                    if decode_answer(call["raw"]) != decode_answer(row["completion"]):
                        reasons.append(f"served_command_harvest_semantics_mismatch_at_t{row['turn']}")
                    answer = decoded(row["completion"])
                    wrapped = row["completion"]
                    if isinstance(wrapped, str):
                        body = wrapped.split("</think>", 1)[-1] if "</think>" in wrapped else wrapped
                        try:
                            json.loads(body)
                        except ValueError:
                            observed_anomalies.append({"game": game, "turn": row["turn"],
                                                       "kind": "original_completion_requires_accepted_parser_repair",
                                                       "capture_raw": call["raw"], "capture_raw_matches_decoder": True})
                    non_dictionary = [uid for uid, value in answer.get("orders", {}).items() if not isinstance(value, dict)]
                    if non_dictionary:
                        observed_anomalies.append({"game": game, "turn": row["turn"],
                                                   "kind": "served_non_dictionary_order_ignored_by_commander",
                                                   "keys": non_dictionary})
                    if not isinstance(answer, dict) or not isinstance(answer.get("orders"), dict):
                        reasons.append(f"invalid_completion_structure_at_t{row['turn']}")
                    if row.get("seed") != seed or row.get("mission") != "collapse70":
                        reasons.append(f"seed_or_mission_mismatch_at_t{row['turn']}")
                    msgs = row["messages"]
                    if not isinstance(msgs, list) or not msgs or not any(m.get("role") == "user" for m in msgs):
                        reasons.append(f"invalid_messages_at_t{row['turn']}")
                if game in bank:
                    reasons.append("duplicate_game_across_runs")
                if reasons:
                    exclusions.append({"game": game, "run": run, "reasons": reasons})
                    continue
                bank[game] = {
                    "game": game, "seed": seed, "tier": meta["tier"], "style": meta["style"],
                    "family": meta["family"], "army_size": int(meta["army"]),
                    "outcome": rec["outcome"], "turn": final_turn, "answer_final_turn": max(turns),
                    "answers": {str(r["turn"]): r["completion"] for _, r in sorted(indexed, key=lambda x: x[1]["turn"])},
                    "engine_answers": {str(r["turn"]): call_cache[captures][(game, r["turn"])]["raw"] for _, r in indexed},
                    "captures_file": str(captures),
                    "rows": {str(r["turn"]): [str(harvest.relative_to(BP)), i] for i, r in indexed},
                    "game_file": str(gf), "game_file_sha256": digest(gf),
                    "overlay": overlay_of(gf), "units": rec["units"],
                    "hq": rec.get("hq"), "source": "seed_grind", "source_run": run,
                    "completeness": "all_recorded_RED_commander_decisions",
                }
                evidence.append({"game": game, "tier": meta["tier"], "decision_count": len(turns),
                                 "first_answer_turn": min(turns), "last_answer_turn": max(turns),
                                 "terminal_turn": final_turn, "red_snapshot_turns_match": True,
                                 "command_count_match": True, "terminal_without_RED_decision": final_turn not in red_turns})
            except (OSError, ValueError, KeyError, TypeError) as exc:
                exclusions.append({"game": game, "run": run, "reasons": [f"{type(exc).__name__}: {exc}"]})
    audit = {
        "input_rows": input_rows, "retained_games": len(bank),
        "retained_rows": sum(len(b["answers"]) for b in bank.values()),
        "games_by_tier": dict(collections.Counter(b["tier"] for b in bank.values())),
        "rows_by_tier": dict(collections.Counter(b["tier"] for b in bank.values() for _ in b["answers"])),
        "exclusions": exclusions, "source_files": sources, "games": evidence,
        "terminal_note": "A terminal turn without a RED-to-act snapshot requires no commander answer. No missing turns are manufactured.",
        "served_calls_verified": sum(len(b["engine_answers"]) for b in bank.values()),
        "observed_original_answer_anomalies": observed_anomalies,
        "harvest_messages_and_completions_equal_captures": True,
        "replay_transport": "engine_answers contains verbatim capture raw actually served to Godot; answers remains verbatim harvest completion",
    }
    (OUT / "bank_grind.json").write_text(json.dumps(bank, ensure_ascii=False, indent=1), encoding="utf-8")
    (OUT / "bank_grind_audit.json").write_text(json.dumps(audit, ensure_ascii=False, indent=2), encoding="utf-8")
    print(json.dumps({k: v for k, v in audit.items() if k not in ("games", "source_files")}, ensure_ascii=False))


if __name__ == "__main__":
    main()
