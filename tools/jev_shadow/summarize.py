"""Gate summary builders: run files, determinism comparison, telemetry summary.

Reads DET evidence + shadow telemetry JSONL under the shadow artifact root and
writes SHADOW_OFF_RUN.json, SHADOW_ON_RUN.json, DETERMINISM_COMPARISON.json,
SHADOW_SUMMARY.json, and SHADOW_DECISION.json.
"""

from __future__ import annotations

import collections
import hashlib
import json
import os
import statistics
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
STRATEGY_ROOT = os.path.abspath(os.path.join(HERE, os.pardir, os.pardir))
if STRATEGY_ROOT not in sys.path:
    sys.path.insert(0, STRATEGY_ROOT)

ARTIFACT_ROOT = os.path.join(STRATEGY_ROOT, "artifacts", "jev_godot_shadow_v0")


def _load(path: str):
    with open(path, encoding="utf-8") as f:
        return json.load(f)


def _sha256_file(path: str) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def _canon(obj) -> str:
    return json.dumps(obj, sort_keys=True, separators=(",", ":"))


def build_run_file(evidence_name: str, run_name: str) -> dict:
    return build_run_file_at(os.path.join(ARTIFACT_ROOT, evidence_name),
                             run_name, evidence_name)


def build_run_file_at(ev_path: str, run_name: str,
                      evidence_name: str | None = None) -> dict:
    # Single-launch harness adds a "jev_shadow" ownership section to the
    # evidence payload (pids/ports differ per leg by design). The evidence
    # digest excludes it so OFF-vs-ON compares authoritative content only;
    # the section itself is asserted separately by the single-launch gate.
    ev = _load(ev_path)
    scrubbed = {k: v for k, v in ev.items() if k != "jev_shadow"}
    scrub_sha = hashlib.sha256(_canon(scrubbed).encode()).hexdigest()
    run: dict = {
        "run": run_name,
        "evidence_file": evidence_name or os.path.basename(ev_path),
        "evidence_sha256": scrub_sha,
        "evidence_file_sha256": _sha256_file(ev_path),
        "jev_shadow": ev.get("jev_shadow", {}),
        "suite": ev.get("suite"),
        "internal_determinism": ev.get("determinism"),
        "verdict": ev.get("verdict"),
        "policies": {},
    }
    for policy, key in (("stationary", "turns_primary"),
                        ("advance", "turns_secondary")):
        turns = ev.get(key, [])
        fp_chain = [str(t.get("fingerprint_post", "")) for t in turns]
        selections = []
        orders = []
        casualties: dict[str, int] = collections.Counter()
        destroyed: list[str] = []
        statuses = []
        for t in turns:
            for u in t.get("red", []):
                selections.append({
                    "turn": t.get("turn"), "unit_id": u.get("unit_id"),
                    "class": u.get("class"),
                    "mission_task": u.get("mission_task"),
                    "selected": u.get("selected"),
                    "resolved_command": _canon(u.get("resolved_command", {})),
                    "executed_action": u.get("executed_action"),
                })
            for o in t.get("orders", []):
                orders.append({"turn": t.get("turn"),
                               "mission_id": o.get("mission_id"),
                               "order": _canon(o.get("order", {})),
                               "exec_status": o.get("exec_status")})
                for k, v in (o.get("casualties", {}) or {}).items():
                    casualties[k] += int(v)
                destroyed.extend(o.get("destroyed", []) or [])
            statuses.append({"turn": t.get("turn"),
                             "statuses": _canon(t.get("statuses", []))})
        run["policies"][policy] = {
            "turns": len(turns),
            "fingerprint_chain": fp_chain,
            "fingerprint_chain_sha256": hashlib.sha256(
                _canon(fp_chain).encode()).hexdigest(),
            "selections": selections,
            "orders": orders,
            "casualties": dict(sorted(casualties.items())),
            "destroyed": sorted(destroyed),
            "mission_statuses": statuses,
        }
    return run


def compare_runs(off: dict, on: dict) -> dict:
    cats: dict[str, dict] = {}

    def cat(name: str, a, b) -> None:
        cats[name] = {"equal": a == b}

    cat("evidence_sha256", off["evidence_sha256"], on["evidence_sha256"])
    cat("internal_determinism", off["internal_determinism"],
        on["internal_determinism"])
    cat("verdict", off["verdict"], on["verdict"])
    for policy in ("stationary", "advance"):
        a, b = off["policies"][policy], on["policies"][policy]
        cat(f"{policy}.turn_count", a["turns"], b["turns"])
        cat(f"{policy}.fingerprint_chain", a["fingerprint_chain_sha256"],
            b["fingerprint_chain_sha256"])
        cat(f"{policy}.baseline_selections", a["selections"], b["selections"])
        cat(f"{policy}.executed_orders", a["orders"], b["orders"])
        cat(f"{policy}.casualties", a["casualties"], b["casualties"])
        cat(f"{policy}.destroyed", a["destroyed"], b["destroyed"])
        cat(f"{policy}.mission_statuses", a["mission_statuses"],
            b["mission_statuses"])
    equal = all(v["equal"] for v in cats.values())
    return {"categories": cats, "all_equal": equal,
            "mismatches": sorted(k for k, v in cats.items() if not v["equal"])}


def _load_telemetry(name: str) -> list[dict]:
    path = os.path.join(ARTIFACT_ROOT, name)
    if not os.path.isfile(path):
        return []
    with open(path, encoding="utf-8") as f:
        return [json.loads(line) for line in f if line.strip()]


def _pct(num: float, den: float):
    return round(100.0 * num / den, 2) if den else 0.0


def _latency_stats(vals: list[float]) -> dict:
    if not vals:
        return {"n": 0}
    s = sorted(vals)
    n = len(s)
    pick = lambda q: s[min(n - 1, int(q * n))]
    return {"n": n, "mean": round(statistics.mean(s), 3),
            "min": round(s[0], 3), "max": round(s[-1], 3),
            "p50": round(pick(0.50), 3), "p95": round(pick(0.95), 3),
            "p99": round(pick(0.99), 3)}


def summarize_telemetry(names: list[str]) -> dict:
    recs: list[dict] = []
    for name in names:
        recs.extend(_load_telemetry(name))
    dec = [r for r in recs if r.get("record_type") == "decision"]
    exe = [r for r in recs if r.get("record_type") == "exec"]
    turns = [r for r in recs if r.get("record_type") == "turn"]
    ok = [r for r in dec if r.get("shadow_status") == "OK"]
    allill = [r for r in dec if r.get("shadow_status") == "ALL_ILLEGAL"]
    notelig = [r for r in dec if r.get("shadow_status") == "NOT_ELIGIBLE"]
    errors = [r for r in dec if r.get("shadow_status") not in
              ("OK", "NOT_ELIGIBLE", "ALL_ILLEGAL")]
    eligible_infer = [r for r in dec if r.get("eligible") is True and
                      r.get("shadow_status") in ("OK", "ALL_ILLEGAL")]
    illegal_selected = [r for r in ok
                        if not (r.get("jev", {}).get("legal_mask", [False] * 6)
                                [r.get("jev", {}).get("selected_slot", -1)]
                                if 0 <= r.get("jev", {}).get("selected_slot", -1) < 6
                                else False)]
    agree = [r for r in ok if r.get("agreement_mapped") is True]
    agree_n = [r for r in ok if r.get("agreement_mapped") is False]
    agree_na = [r for r in ok if r.get("agreement_mapped") is None]
    by_class: dict[str, dict] = {}
    for cls in sorted({r.get("unit_class") for r in ok}):
        sub = [r for r in ok if r.get("unit_class") == cls]
        by_class[cls] = {"n": len(sub), "agree": sum(
            1 for r in sub if r.get("agreement_mapped") is True),
            "agreement_pct": _pct(sum(1 for r in sub
                                      if r.get("agreement_mapped") is True),
                                  sum(1 for r in sub
                                      if r.get("agreement_mapped") is not None))}
    by_task: dict[str, dict] = {}
    for task in sorted({(r.get("mission") or {}).get("task", "?") for r in ok}):
        sub = [r for r in ok if (r.get("mission") or {}).get("task") == task]
        by_task[task] = {"n": len(sub), "agree": sum(
            1 for r in sub if r.get("agreement_mapped") is True),
            "agreement_pct": _pct(sum(1 for r in sub
                                      if r.get("agreement_mapped") is True),
                                  sum(1 for r in sub
                                      if r.get("agreement_mapped") is not None))}
    jev_dist = dict(sorted(collections.Counter(
        (r.get("jev", {}).get("selected_skill") or "?") for r in ok).items()))
    base_dist = dict(sorted(collections.Counter(
        r.get("baseline_option_id", "?") for r in ok).items()))
    exec_keys = {(e.get("run_id"), e.get("turn"), e.get("unit_id")) for e in exe}
    joined = sum(1 for r in dec
                 if (r.get("run_id"), r.get("turn"), r.get("actor_id")) in exec_keys)
    client_lat = [float(r["latency_ms"]["client"]) for r in ok
                  if isinstance(r.get("latency_ms"), dict)
                  and "client" in r["latency_ms"]]
    server_lat = [float(r["latency_ms"]["server_total"]) for r in ok
                  if isinstance(r.get("latency_ms"), dict)
                  and "server_total" in r["latency_ms"]]
    fwd_lat = [float(r["latency_ms"]["server_forward"]) for r in ok
               if isinstance(r.get("latency_ms"), dict)
               and "server_forward" in r["latency_ms"]]
    return {
        "telemetry_files": names,
        "records": len(recs),
        "decisions": len(dec),
        "exec_records": len(exe),
        "turn_records": len(turns),
        "eligible_decisions": len(
            [r for r in dec if r.get("eligible") is True]),
        "successful_inferences": len(eligible_infer),
        "status_counts": dict(sorted(collections.Counter(
            r.get("shadow_status", "?") for r in dec).items())),
        "shadow_errors": len(errors),
        "error_samples": [r.get("shadow_error", "")[:160] for r in errors[:5]],
        "not_eligible": len(notelig),
        "all_illegal": len(allill),
        "illegal_selected_slots": len(illegal_selected),
        "agreement": {"compared": len(agree) + len(agree_n),
                      "agree": len(agree), "disagree": len(agree_n),
                      "na": len(agree_na),
                      "agreement_pct": _pct(len(agree), len(agree) + len(agree_n))},
        "per_class_agreement": by_class,
        "per_task_agreement": by_task,
        "jev_skill_distribution": jev_dist,
        "baseline_option_distribution": base_dist,
        "exec_join_rate_pct": _pct(joined, len(dec)),
        "latency_client_ms": _latency_stats(client_lat),
        "latency_server_total_ms": _latency_stats(server_lat),
        "latency_server_forward_ms": _latency_stats(fwd_lat),
    }


def main() -> int:
    off = build_run_file("DET_EVIDENCE_OFF.json", "shadow-off")
    on = build_run_file("DET_EVIDENCE_ON.json", "shadow-on")
    with open(os.path.join(ARTIFACT_ROOT, "SHADOW_OFF_RUN.json"), "w",
              encoding="utf-8") as f:
        json.dump(off, f, indent=1)
    with open(os.path.join(ARTIFACT_ROOT, "SHADOW_ON_RUN.json"), "w",
              encoding="utf-8") as f:
        json.dump(on, f, indent=1)
    comp = compare_runs(off, on)
    # leg C: worker-down fail-open digests must match OFF as well
    down = build_run_file("DET_EVIDENCE_DOWN.json", "shadow-on-worker-down")
    comp_down = compare_runs(off, down)
    scout_path = os.path.join(ARTIFACT_ROOT, "DET_EVIDENCE_SCOUT.json")
    scout = _load(scout_path) if os.path.isfile(scout_path) else {}
    comparison = {
        "legs": {
            "A_off_vs_B_on": comp,
            "C_off_vs_down": comp_down,
        },
        "scout_variant": {
            "evidence_sha256": _sha256_file(scout_path) if scout else None,
            "internal_determinism": (scout.get("determinism") if scout else None),
            "verdict": (scout.get("verdict") if scout else None),
            "note": "separate forces (one scout); not compared for equality, "
                    "proves live scout coverage + battle health",
        },
        "all_equal": comp["all_equal"] and comp_down["all_equal"],
    }
    with open(os.path.join(ARTIFACT_ROOT, "DETERMINISM_COMPARISON.json"), "w",
              encoding="utf-8") as f:
        json.dump(comparison, f, indent=1)

    summary = {
        "combined": summarize_telemetry(
            ["SHADOW_TELEMETRY.jsonl", "SHADOW_TELEMETRY_SCOUT.jsonl"]),
        "main": summarize_telemetry(["SHADOW_TELEMETRY.jsonl"]),
        "scout": summarize_telemetry(["SHADOW_TELEMETRY_SCOUT.jsonl"]),
        "down": summarize_telemetry(["SHADOW_TELEMETRY_DOWN.jsonl"]),
        "coverage_note": "DET evidence holds 480 red decision rows per "
                         "invocation (10 units x 16 turns x 3 battles); "
                         "telemetry holds one decision record per row "
                         "(480/480) plus exec + turn records.",
    }
    with open(os.path.join(ARTIFACT_ROOT, "SHADOW_SUMMARY.json"), "w",
              encoding="utf-8") as f:
        json.dump(summary, f, indent=1)

    checks: dict[str, bool] = {}
    checks["off_on_identical"] = comp["all_equal"]
    checks["down_identical"] = comp_down["all_equal"]
    checks["zero_shadow_errors_main"] = summary["main"]["shadow_errors"] == 0
    checks["zero_illegal_selected"] = summary["combined"]["illegal_selected_slots"] == 0
    checks["full_coverage_main"] = summary["main"]["decisions"] == 480
    checks["all_classes_live"] = set(summary["combined"]["per_class_agreement"]) == {
        "INFANTRY", "SPEARMAN", "CAVALRY", "ARCHER", "SCOUT"}
    checks["hq_classified_not_eligible"] = summary["combined"]["not_eligible"] > 0
    checks["exec_join_complete"] = summary["combined"]["exec_join_rate_pct"] == 100.0
    warnings: list[str] = []
    p95 = summary["combined"]["latency_client_ms"].get("p95", 0)
    if p95 > 1500:
        warnings.append(f"client p95 latency {p95}ms exceeds 1500ms bound")
    decision = {
        "gate": "Godot JEV Shadow Integration (SHADOW ONLY)",
        "checks": checks,
        "warnings": warnings,
        "candidate": "jev-policy-v0.6.0-mission1",
        "candidate_authority": "WITHHELD",
        "shadow_integration": "PASS" if all(checks.values()) else "FAIL",
        "note": "Integration PASS does not promote the candidate; tactical "
                "quality remains poor per the prior gate (mean -174.7 vs "
                "Simple +22.0). Authority stays WITHHELD.",
    }
    with open(os.path.join(ARTIFACT_ROOT, "SHADOW_DECISION.json"), "w",
              encoding="utf-8") as f:
        json.dump(decision, f, indent=1)
    print(f"[summarize] off==on: {comp['all_equal']} "
          f"off==down: {comp_down['all_equal']} "
          f"decisions={summary['combined']['decisions']} "
          f"errors={summary['combined']['shadow_errors']} "
          f"agree={summary['combined']['agreement']['agreement_pct']}% "
          f"decision={decision['shadow_integration']}")
    return 0 if all(checks.values()) else 1


if __name__ == "__main__":
    raise SystemExit(main())
