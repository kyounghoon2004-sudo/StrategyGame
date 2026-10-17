"""CPU-only comparison of original late states and already completed V3 branches."""
from __future__ import annotations
import json
from pathlib import Path

from tools.synth_sft_v3.grind_bank import OUT


def difference(expected, actual, path="$", limit=8):
    if type(expected) is not type(actual):
        return [{"path": path, "expected": expected, "actual": actual}]
    if isinstance(expected, dict):
        found = []
        for key in sorted(set(expected) | set(actual)):
            if key not in expected or key not in actual:
                found.append({"path": path + "." + str(key), "expected": expected.get(key), "actual": actual.get(key)})
            else:
                found.extend(difference(expected[key], actual[key], path + "." + str(key), limit))
            if len(found) >= limit:
                return found[:limit]
        return found
    if isinstance(expected, list):
        found = []
        if len(expected) != len(actual):
            found.append({"path": path + ".length", "expected": len(expected), "actual": len(actual)})
        for index, (left, right) in enumerate(zip(expected, actual)):
            found.extend(difference(left, right, path + f"[{index}]", limit))
            if len(found) >= limit:
                break
        return found[:limit]
    return [] if expected == actual else [{"path": path, "expected": expected, "actual": actual}]


def snapshot(record, turn, side):
    return next((s for s in record["record"]["snapshots"] if s.get("turn") == turn and s.get("to_act") == side), None)


def unit_map(snap):
    return {unit[0]: unit[1:] for unit in snap["units"]} if snap else {}


def main():
    batch = OUT / "xcheck" / "v3_01_b000"
    late = {r["id"]: r for r in (json.loads(l) for l in (OUT / "situations_late_v3.jsonl").read_text(encoding="utf-8").splitlines() if l.strip())}
    bank = json.loads((OUT / "bank_late_v3.json").read_text(encoding="utf-8"))
    branches = {r["id"]: r for r in (json.loads(l) for l in (batch / "branches.jsonl").read_text(encoding="utf-8").splitlines() if l.strip())}
    samples = []
    for request_file in sorted((batch / "requests").glob("*.json")):
        branch_id = request_file.stem
        branch = branches.get(branch_id)
        if not branch:
            continue
        sid = f"{branch['game']}__t{branch['turn']}"
        if sid not in late:
            continue
        original = late[sid]
        actual = json.loads(request_file.read_text(encoding="utf-8"))
        expected = original["messages"]
        if expected == actual:
            continue
        ef = next((i for i, (e, a) in enumerate(zip(expected, actual)) if e != a), None)
        eu = [m["content"] for m in expected if m["role"] == "user"]
        au = [m["content"] for m in actual if m["role"] == "user"]
        source_record = json.loads(Path(bank[branch["game"]]["game_file"]).read_text(encoding="utf-8"))
        record_path = batch / "games" / (branch_id + ".json")
        replay = json.loads(record_path.read_text(encoding="utf-8")) if record_path.exists() else None
        entry = {"branch": branch_id, "sid": sid, "source_record": bank[branch["game"]]["game_file"],
                 "branch_request": str(request_file), "original_message_count": len(expected), "replay_message_count": len(actual),
                 "first_raw_message_difference_index": ef,
                 "opening_semantic_differences": difference(json.loads(eu[0]), json.loads(au[0])),
                 "current_semantic_differences": difference(json.loads(eu[-1]), json.loads(au[-1])),
                 "source_episode": source_record["episode"]}
        if replay:
            initial_src = unit_map(snapshot(source_record, 1, "blue"))
            initial_replay = unit_map(snapshot(replay, 1, "blue"))
            entry.update({"replay_episode": replay["episode"], "record_rules_equal": source_record["record"]["rules"] == replay["record"]["rules"],
                          "initial_physical_state_equal": initial_src == initial_replay,
                          "initial_unit_differences": difference(initial_src, initial_replay),
                          "source_initial_soldiers": source_record["soldiers_start"], "replay_initial_soldiers": replay["soldiers_start"],
                          "branch_T_RED_state_differences": difference(unit_map(snapshot(source_record, branch["turn"], "red")),
                                                                      unit_map(snapshot(replay, branch["turn"], "red")))})
        samples.append(entry)
    report = {"diagnosis": "PHYSICAL_ROSTER_AND_DEPLOYMENT_MISMATCH_BEFORE_T1",
              "source_roster_sizes": "6,7,8,9,10,11,12,13,14,15,16",
              "source_command_evidence": "artifacts/brain_pipeline_v1/sft_mix_v3b/run.sh:27-29",
              "branch_effective_roster_sizes": "army_size-army_size",
              "code_evidence": ["watch_llm_vs_utility.gd:125-129 chooses spread only when sizes includes hyphen",
                                "watch_llm_vs_utility.gd:152-170 consumes different allowed-size RNG draw",
                                "step2r_battlefield_shell.gd:947-954 selects spread vs stock count layout"],
              "proposed_fix": "V3 per-bank roster_sizes override using exact original comma list; retain grind N-N settings. Exact late source replay/prompt checks required before retrying candidates.",
              "mismatched_existing_request_count": len(samples), "samples": samples,
              "runtime_changes": "none", "engine_launches": 0,
              "source_step150_note": "ALT original step150 run.sh is unavailable; its three original initial armies and slots equal all nine v3b snapshots using the evidenced comma-list option."}
    (OUT / "late_replay_diagnostic.json").write_text(json.dumps(report, indent=2, ensure_ascii=False), encoding="utf-8")
    print(json.dumps({k: v for k, v in report.items() if k != "samples"}, ensure_ascii=False))


if __name__ == "__main__":
    main()
