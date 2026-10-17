"""Read-only V2 late-collapse provenance -> exact prompts for V3 stalled states.

Copies no fabricated data: raw accepted calls supply both original messages and
answers, and original game snapshots prove completeness. Writes V3 only.
"""
from __future__ import annotations

import collections
import json
from pathlib import Path

from tools.synth_sft_v2.bank import overlay_of
from tools.synth_sft_v3.grind_bank import BP, OUT, decode_answer, digest

ALT_BP = Path("D:/d/Game development/Demon slayer/StrategyGame/artifacts/brain_pipeline_v1")
ORIGINAL_ROSTER_SIZES = "6,7,8,9,10,11,12,13,14,15,16"


def main():
    old = BP / "synth_sft_v2"
    bank_file = old / "late_bank_collapse.json"
    states_file = old / "late_states.jsonl"
    original_bank = json.loads(bank_file.read_text(encoding="utf-8"))
    states = [json.loads(l) for l in states_file.read_text(encoding="utf-8").splitlines() if l.strip()]
    selected = {s["id"] for s in states if s["mode"] == "collapse"}
    bank, situations, exclusions, calls_cache, sources = {}, [], [], {}, []
    for gid, old_b in original_bank.items():
        run, step = old_b["source"].split("/")
        candidates = [root / run / "smoke" / step / "collapse" for root in (BP, ALT_BP)]
        dirs = [p for p in candidates if (p / "raw" / "calls.jsonl").exists()]
        if len(dirs) != 1:
            exclusions.append({"game": gid, "reason": f"expected_one_exact_calls_source_found_{len(dirs)}"})
            continue
        folder = dirs[0]
        raw_file = folder / "raw" / "calls.jsonl"
        tag = gid.split("__collapse_", 1)[1]
        gf = folder / "games" / (tag + ".json")
        try:
            if raw_file not in calls_cache:
                calls_cache[raw_file] = [json.loads(l) for l in raw_file.read_text(encoding="utf-8").splitlines() if l.strip()]
                sources.append({"path": str(raw_file), "sha256": digest(raw_file)})
            calls = {str(c["turn"]): c for c in calls_cache[raw_file]
                     if c.get("tag") == tag and c.get("request") == "VICTORY_COMMAND" and c.get("served") == "LOCAL"}
            rec = json.loads(gf.read_text(encoding="utf-8"))
            turns = sorted(map(int, old_b["answers"]))
            expected = sorted({s["turn"] for s in rec["record"]["snapshots"] if s.get("to_act") == "red"})
            if turns != expected or turns != list(range(1, max(turns) + 1)):
                raise ValueError("incomplete_original_late_answer_sequence")
            if any(t not in calls or calls[t]["raw"] != a for t, a in old_b["answers"].items()):
                raise ValueError("missing_or_changed_original_accepted_calls")
            b = dict(old_b)
            invocation = BP / "sft_mix_v3b" / "run.sh"
            source_config = {
                "random_roster": True, "roster_sizes": ORIGINAL_ROSTER_SIZES,
                "source_invocation_file": str(invocation), "source_invocation_sha256": digest(invocation),
                "source_invocation_lines": [27, 29],
                "configuration_evidence": "source_run_script" if run == "sft_mix_v3b" else "inferred_from_identical_original_initial_armies_and_slots_across_checkpoints",
                "validation_status": "PENDING_EACH_SOURCE_ENGINE_REPLAY_AND_PROMPT_GATE",
                "layout_evidence": "original initial snapshots use stock count slots and SCO ids; sizes contains no hyphen",
            }
            b.update({"source": "qwen_late_stall", "source_run": old_b["source"], "game_file": str(gf),
                      "game_file_sha256": digest(gf), "overlay": overlay_of(gf), "units": rec["units"],
                      "hq": rec.get("hq"), "answer_final_turn": max(turns), "raw_calls_file": str(raw_file),
                      "engine_answers": dict(old_b["answers"]), "random_roster": True,
                      "roster_sizes": ORIGINAL_ROSTER_SIZES, "replay_configuration_provenance": source_config,
                      "original_episode": rec["episode"], "original_initial_units": rec["record"]["snapshots"][0]["units"]})
            bank[gid] = b
            orders, plan = {}, ""
            for t in turns:
                text = b["answers"][str(t)]
                answer = decode_answer(text)
                sid = f"{gid}__t{t}"
                if sid in selected:
                    msgs = calls[str(t)]["messages"]
                    users = [m["content"] for m in msgs if m["role"] == "user"]
                    opening = json.loads(users[0])
                    now = json.loads(users[-1]) if len(users) > 1 else None
                    alive = {x.split()[0] for x in now["my_units"]} if now else {u["id"] for u in opening["my_units"]}
                    situations.append({"id": sid, "game": gid, "turn": t, "tier": b["tier"],
                                       "style": b["style"], "family": b["family"], "army_size": b["army_size"],
                                       "seed": b["seed"], "mission": "collapse70", "source": "qwen_late_stall",
                                       "source_run": old_b["source"], "game_file": str(gf),
                                       "teacher_answer": text, "messages": msgs, "opening": users[0],
                                       "now": users[-1] if len(users) > 1 else "",
                                       "standing_orders": {uid: order for uid, order in orders.items() if uid in alive}, "standing_plan": plan,
                                       "original_answer_empty": not answer["orders"]})
                orders.update({str(uid).upper(): order for uid, order in (answer.get("orders") or {}).items() if isinstance(order, dict)})
                plan = str(answer.get("plan", "")).strip()[:400] or plan
        except (OSError, KeyError, ValueError, TypeError) as exc:
            bank.pop(gid, None)
            situations = [s for s in situations if s["game"] != gid]
            exclusions.append({"game": gid, "reason": f"{type(exc).__name__}: {exc}"})
    audit = {"original_bank_games": len(original_bank), "retained_games": len(bank),
             "requested_stalled_states": len(selected), "exact_stalled_situations": len(situations),
             "empty_answers": sum(s["original_answer_empty"] for s in situations),
             "by_tier": dict(collections.Counter(s["tier"] for s in situations)), "exclusions": exclusions,
             "missing_ids": sorted(selected - {s["id"] for s in situations}), "source_files": sources,
             "messages_source": "exact accepted LOCAL calls.jsonl messages, unchanged",
             "bank_sources": [{"path": str(p), "sha256": digest(p)} for p in (bank_file, states_file)]}
    (OUT / "bank_late_v3.json").write_text(json.dumps(bank, ensure_ascii=False, indent=1), encoding="utf-8")
    with (OUT / "situations_late_v3.jsonl").open("w", encoding="utf-8", newline="\n") as stream:
        for row in situations:
            stream.write(json.dumps(row, ensure_ascii=False) + "\n")
    (OUT / "late_provenance_audit.json").write_text(json.dumps(audit, indent=2), encoding="utf-8")
    print(json.dumps({k: v for k, v in audit.items() if k not in ("source_files", "bank_sources")}))


if __name__ == "__main__":
    main()
