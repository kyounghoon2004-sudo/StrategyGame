"""CPU-only read-only pacing evidence from existing V3 branch result directories.

No process control, engine launch, training or runtime mutation.
"""
from __future__ import annotations
import collections
import json
import statistics
import sys
from pathlib import Path

from tools.synth_sft_v3.grind_bank import OUT


def describe(values):
    return {"n": len(values), "mean_s": round(statistics.mean(values), 4),
            "median_s": round(statistics.median(values), 4), "min_s": round(min(values), 4),
            "max_s": round(max(values), 4)} if values else {"n": 0}


def profile(folder):
    folder = Path(folder)
    calls_file = folder / "raw" / "calls.jsonl"
    calls = [json.loads(l) for l in calls_file.read_text(encoding="utf-8").splitlines() if l.strip()] if calls_file.exists() else []
    commands = collections.defaultdict(list)
    for c in calls:
        if c.get("request") == "VICTORY_COMMAND":
            commands[c.get("tag", "")].append(c)
    games = []
    for file in sorted((folder / "games").glob("*.json")):
        record = json.loads(file.read_text(encoding="utf-8"))
        events = sorted(commands[file.stem], key=lambda c: c["turn"])
        blue = record.get("record", {}).get("actions", {}).get("blue", [])
        red = record.get("record", {}).get("actions", {}).get("red", [])
        blue_attacks = sum(a.get("do") in ("ATTACK", "ASSAULT") for a in blue)
        cmd_delta = [b["ts"] - a["ts"] for a, b in zip(events, events[1:])]
        # Timer totals are source-code-derived lower-bound estimates, not profiler measurements.
        games.append({"game": file.stem, "outcome": record.get("outcome"), "turn": record.get("turn"),
                      "record_wall_s": record.get("wall_s"), "command_calls": len(events),
                      "inter_command_intervals": describe(cmd_delta), "blue_actions": len(blue), "red_actions": len(red),
                      "blue_attack_actions": blue_attacks,
                      "configured_fixed_action_wait_estimate_s": round(len(blue) * .08 + blue_attacks * .15 + len(red) * .02, 3),
                      "default_proxy_manual_poll_delay_estimate_s": round(len(events) * 1.3, 3)})
    req_response_times, ready_to_proxy_times = [], []
    command_lookup = {(c.get("tag"), c.get("turn")): c for c in calls if c.get("request") == "VICTORY_COMMAND"}
    for request in (folder / "manual").glob("req_*.json"):
        response = request.with_name(request.name.replace("req_", "resp_").replace(".json", ".txt"))
        if response.exists():
            req_response_times.append(response.stat().st_mtime - request.stat().st_mtime)
            request_data = json.loads(request.read_text(encoding="utf-8"))
            logged = command_lookup.get((request_data.get("tag"), request_data.get("turn")))
            if logged:
                ready_to_proxy_times.append(logged["ts"] - response.stat().st_mtime)
    return {"folder": str(folder.resolve()), "games": games,
            "manual_req_to_response_file_time": describe(req_response_times),
            "response_already_ready_to_proxy_completed_log_time": describe(ready_to_proxy_times),
            "filesystem_mtime_note": "These approximate local file readiness, not HTTP end-to-end latency."}


def main():
    args = sys.argv[1:] or [str(OUT / "replay_gate" / "production"), str(OUT / "replay_gate" / "frozen_wire")]
    result = {"method": "Existing V3 result records, request/response timestamps and immutable source timer configuration",
              "profiles": [profile(folder) for folder in args],
              "exactness_required": "Any scheduling change must pass exact replay for all three tier games before verification use."}
    target = OUT / "pacing_profile_v3.json"
    target.write_text(json.dumps(result, indent=2), encoding="utf-8")
    print(json.dumps(result, indent=2))


if __name__ == "__main__":
    main()
