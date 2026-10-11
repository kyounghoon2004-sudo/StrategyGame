"""CSFT5 human-benchmark report (read-only; observational).

  python -m tools.contract_sft.human_benchmark_report <session_dir>

Joins, per Brain call:
  server telemetry  <session>/calls.jsonl  (raw output, latency, packet turn/side/
                    request type, observational flags; written by brain_server)
  game verdict      <session>/game.log     ([CloudTurn] VICTORY_ATTEMPT lines =
                    the PRODUCTION parser/validator result: parse=<code>,
                    outcome=<READY|APPLIED|REJECTED|...>; VICTORY_PLAN_ADOPTED /
                    VICTORY_REVIEW_APPLIED lines = phase selected/executed)
Matching: kind (INITIAL/REVIEW) + turn + exact response length (final=<n>chars).
Nothing is repaired or re-judged here; the verdict is the game's.
Writes <session>/HUMAN_BENCHMARK_REPORT.json and prints a summary.
"""
from __future__ import annotations

import json
import re
import sys
from pathlib import Path

ATTEMPT = re.compile(r"\[CloudTurn\] VICTORY_ATTEMPT call=(\S+) kind=(\S+) turn=(\d+) req=(\S+) http=(\S+) "
                     r"lat=(\d+)ms finish=(\S+) final=(\d+)chars .*? parse=(\S+) decision=(\S+) outcome=(\S+)")
ADOPTED = re.compile(r"\[CloudTurn\] VICTORY_PLAN_ADOPTED v1 phases=(\d+) active=(\S+)")
REVIEW_APPLIED = re.compile(r"\[CloudTurn\] VICTORY_REVIEW_APPLIED decision=(\S+) rev=(\d+) phase=(\S+)")
FAILED = re.compile(r"\[CloudTurn\] VICTORY_INITIAL_FAILED call=(\S+) reason=(.*)")
OK_OUTCOMES = {"READY", "APPLIED", "KEPT", "ADOPTED", "STAGED"}


def main() -> int:
    d = Path(sys.argv[1])
    calls = [json.loads(l) for l in open(d / "calls.jsonl", encoding="utf-8")] if (d / "calls.jsonl").exists() else []
    calls = [c for c in calls if c.get("kind") == "BRAIN_CALL"]
    log = (d / "game.log").read_text(encoding="utf-8", errors="replace") if (d / "game.log").exists() else ""
    attempts, seen = [], set()
    for m in ATTEMPT.finditer(log):
        key = m.group(0)
        if key in seen:  # the game prints some attempt lines twice
            continue
        seen.add(key)
        attempts.append({"call": m.group(1), "kind": m.group(2), "turn": int(m.group(3)), "req": m.group(4),
                         "http": m.group(5), "latency_ms": int(m.group(6)), "finish": m.group(7),
                         "final_chars": int(m.group(8)), "parse": m.group(9), "decision": m.group(10),
                         "outcome": m.group(11)})
    phases = [{"event": "ADOPTED", "phases": int(m.group(1)), "active": m.group(2)} for m in ADOPTED.finditer(log)] + \
             [{"event": "REVIEW_APPLIED", "decision": m.group(1), "rev": int(m.group(2)), "phase": m.group(3)}
              for m in REVIEW_APPLIED.finditer(log)]
    fails = {m.group(1): m.group(2)[:300] for m in FAILED.finditer(log)}
    used = set()
    rows = []
    for c in calls:
        kind = "INITIAL" if c.get("request") == "VICTORY_INITIAL" else "REVIEW" if c.get("request") == "VICTORY_REVIEW" else c.get("request")
        match = None
        for i, a in enumerate(attempts):
            # the game logs background reviews as kind=REVIEW_BG
            akind = "REVIEW" if a["kind"].startswith("REVIEW") else a["kind"]
            if i not in used and akind == kind and a["turn"] == c.get("turn") and a["final_chars"] == c.get("raw_chars"):
                match = i
                break
        a = attempts[match] if match is not None else None
        if match is not None:
            used.add(match)
        parser_pass = None if a is None else a["parse"] != "VP_INVALID_JSON"
        validator_pass = None if a is None else (a["parse"] == "OK" and a["outcome"] in OK_OUTCOMES)
        rows.append({
            "call_seq": c["call_seq"], "turn": c.get("turn"), "side": c.get("side"), "request": c.get("request"),
            "plan_kind": "initial" if kind == "INITIAL" else "review" if kind == "REVIEW" else kind,
            "latency_s": c.get("latency_s"), "gen_tokens": c.get("gen_tokens"), "hit_token_cap": c.get("hit_token_cap"),
            "parser_pass": parser_pass, "validator_pass": validator_pass,
            "failure_reason": None if a is None or validator_pass else
            (fails.get(a["call"]) or f"parse={a['parse']} outcome={a['outcome']}"),
            "game_call_id": None if a is None else a["call"], "game_decision": None if a is None else a["decision"],
            "game_outcome": None if a is None else a["outcome"],
            "units_referenced": c.get("units_referenced"), "phases_declared": c.get("phases_declared"),
            "flags": {"json_syntax_failure": not c.get("json_exactly_one_object"),
                      "unknown_friendly_ids": c.get("unknown_friendly_ids"),
                      "system_example_id_copies": c.get("system_example_id_copies"),
                      "wrong_side_ids": c.get("wrong_side_ids"),
                      "hidden_enemy_ids": c.get("hidden_enemy_ids"),
                      "hidden_enemy_hq_ids": c.get("hidden_enemy_hq_ids"),
                      "invented_enum_task_trigger": c.get("invented_enum_task_trigger")},
            "raw_output": c.get("raw_output")})
    judged = [r for r in rows if r["validator_pass"] is not None]

    def cnt(pred):
        return sum(1 for r in rows if pred(r))
    summary = {
        "session": str(d), "brain_calls": len(rows), "joined_with_game_verdict": len(judged),
        "unjoined_calls": len(rows) - len(judged),
        "game_attempt_lines_unmatched": len(attempts) - len(used),
        "validator_pass": cnt(lambda r: r["validator_pass"] is True),
        "validator_fail (human-benchmark failures)": cnt(lambda r: r["validator_pass"] is False),
        "parser_fail": cnt(lambda r: r["parser_pass"] is False),
        "by_kind": {k: {"calls": cnt(lambda r, k=k: r["plan_kind"] == k),
                        "pass": cnt(lambda r, k=k: r["plan_kind"] == k and r["validator_pass"] is True)}
                    for k in sorted({r["plan_kind"] for r in rows})},
        "flags_any_call": {f: cnt(lambda r, f=f: bool(r["flags"][f])) for f in
                           ("json_syntax_failure", "unknown_friendly_ids", "system_example_id_copies", "wrong_side_ids",
                            "hidden_enemy_ids", "hidden_enemy_hq_ids", "invented_enum_task_trigger")},
        "token_cap_hits": cnt(lambda r: bool(r["hit_token_cap"])),
        "mean_latency_s": round(sum(r["latency_s"] or 0 for r in rows) / len(rows), 1) if rows else None,
        "phase_events": phases,
    }
    (d / "HUMAN_BENCHMARK_REPORT.json").write_text(json.dumps({"summary": summary, "calls": rows}, indent=1,
                                                              ensure_ascii=False), encoding="utf-8")
    print(json.dumps(summary, indent=1))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
