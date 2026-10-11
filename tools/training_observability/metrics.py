"""TASK 1 - read-only, incremental training-metrics aggregator.

Outputs (under <output_root>/metrics/):
  TRAINING_METRICS.json  full per-iteration rows + aggregates
  iterations.csv         one row per COMPLETE iteration
  SUMMARY.md             human summary
  scan_cache.json        per-iteration cache keyed by ITERATION_RESULT stat
                         signature (completed iterations are immutable)

Missing evidence is never invented: the JSON value is null and
row["missing"][field] says NOT_RECORDED (producer did not persist it) or
NOT_RUN (phase never ran, e.g. SKIPPED_NO_SIGNAL has no train/eval).
"""
from __future__ import annotations

import csv
import io
import re
from datetime import datetime, timezone
from pathlib import Path
from statistics import mean
from typing import Any, Dict, List, Optional

from .config import Paths
from .marathon_scan import (IterationRef, LiveSnapshot, discover_iterations,
                            parse_phase_log, try_read_json)
from .safe_io import OutputWriter, ReadOnlySource

METRICS_SCHEMA_VERSION = 2  # 2: reward-contract (V1/V2) fields, additive
ROW_CACHE_VERSION = 2

CSV_FIELDS = [
    "iteration", "candidate", "champion_before", "champion_after", "decision",
    "rollout_status", "groups_attempted", "groups_informative", "informative_ratio",
    "optimizer_steps", "eval_wins", "eval_losses", "eval_draws", "eval_score",
    "eval_strict_failures", "rollout_reward_n", "rollout_reward_mean",
    "rollout_reward_min", "rollout_reward_max", "rollout_n_win", "rollout_n_loss",
    "rollout_n_draw", "eval_candidate_reward_mean", "rollout_duration_s",
    "rollout_group_wall_s_sum", "train_duration_s", "eval_duration_s",
    "iteration_duration_s", "vram_peak_train_gib", "vram_peak_phase_logs_gib",
    "min_free_ram_train_gib", "min_host_avail_phase_logs_gib", "guard_trips",
    "phase_restarts", "resumed",
    # appended (schema 2) - reward contract
    "reward_contract_version", "rollout_terminal_reward_mean", "rollout_total_reward_mean",
    "rollout_contract_valid_n", "rollout_plan_coherent_n", "rollout_strict_failure_n",
]

LOG_ERROR_RE = re.compile(r"^(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}),\d+ ERROR (.*)$")


def _parse_iso(s: Optional[str]) -> Optional[datetime]:
    if not s:
        return None
    try:
        return datetime.strptime(s, "%Y-%m-%dT%H:%M:%SZ")
    except ValueError:
        return None


def _ratio(a, b):
    return round(a / b, 6) if b else None


def build_row(src: ReadOnlySource, ref: IterationRef, issues: List[dict]) -> Dict[str, Any]:
    res = ref.result or {}
    summ = res.get("summaries") or {}
    missing: Dict[str, str] = {}
    d = ref.path
    decision = res.get("decision")
    skipped = decision == "SKIPPED_NO_SIGNAL"

    def section(key, rel):
        if isinstance(summ.get(key), dict):
            return summ[key], "ITERATION_RESULT.summaries"
        obj = try_read_json(src, d / rel, issues, f"iteration {ref.number} {key}") \
            if src.exists(d / rel) else None
        return (obj if isinstance(obj, dict) else None), rel

    roll, roll_src = section("rollout_manifest.json", "rollout/rollout_manifest.json")
    train, train_src = section("train_summary.json", "train/train_summary.json")
    ev, ev_src = section("eval_summary.json", "eval/eval_summary.json")

    row: Dict[str, Any] = {"iteration": ref.number, "status": "COMPLETE",
                           "candidate": res.get("candidate_id"),
                           "decision": decision,
                           "decision_reason": res.get("decision_reason"),
                           "champion_before": res.get("champion_before"),
                           "champion_before_source": "ITERATION_RESULT" if res.get("champion_before") else None,
                           "champion_after": res.get("champion_after"),
                           "resumed": bool(res.get("resumed", False)),
                           "sources": {"rollout": roll_src if roll else None,
                                       "train": train_src if train else None,
                                       "eval": ev_src if ev else None}}

    # --- rollout -------------------------------------------------------
    groups = (roll or {}).get("groups_attempted") or []
    row["rollout_status"] = (roll or {}).get("status")
    if roll is None:
        missing["rollout_status"] = "NOT_RECORDED"
    row["groups_attempted"] = (roll or {}).get("n_attempted", len(groups) if roll else None)
    row["groups_informative"] = (roll or {}).get("n_informative")
    if row["groups_informative"] is None and roll:
        row["groups_informative"] = sum(1 for g in groups if g.get("informative"))
    row["informative_ratio"] = _ratio(row["groups_informative"] or 0, row["groups_attempted"]) \
        if row["groups_attempted"] else None
    on_disk = [n for n in src.listdir(d / "rollout") if re.fullmatch(r"group\d+\.json", n)]
    row["group_files_on_disk"] = len(on_disk)
    if roll and row["groups_attempted"] != len(on_disk):
        issues.append({"kind": "GROUP_COUNT_MISMATCH", "path": str(d / "rollout"),
                       "context": f"iteration {ref.number}",
                       "detail": f"manifest n_attempted={row['groups_attempted']} group files={len(on_disk)}"})
    # group["rewards"] is the GRPO scalar under every reward contract. V1 has
    # no version field (scalar == terminal); V2 adds terminal_rewards and
    # per-sample reward_components. W/L/D always come from TERMINAL values.
    rewards = [r for g in groups for r in (g.get("rewards") or [])]
    terms = [t for g in groups for t in ((g.get("terminal_rewards") if "terminal_rewards" in g
                                          else g.get("rewards")) or [])]
    comps = [c for g in groups for c in (g.get("reward_components") or []) if isinstance(c, dict)]
    rcv = (roll or {}).get("reward_contract_version") or ("REWARD_CONTRACT_V1" if roll else None)
    row["reward_contract_version"] = rcv
    if rcv is None:
        missing["reward_contract_version"] = "NOT_RECORDED"
    row["rollout_reward_n"] = len(rewards) if roll else None
    row["rollout_reward_mean"] = round(mean(rewards), 6) if rewards else None
    row["rollout_reward_min"] = min(rewards) if rewards else None
    row["rollout_reward_max"] = max(rewards) if rewards else None
    row["rollout_total_reward_mean"] = row["rollout_reward_mean"]
    row["rollout_terminal_reward_mean"] = round(mean(terms), 6) if terms else None
    row["rollout_n_win"] = sum(1 for r in terms if r == 5) if roll else None
    row["rollout_n_loss"] = sum(1 for r in terms if r == -3) if roll else None
    row["rollout_n_draw"] = sum(1 for r in terms if r == -2) if roll else None
    v2_ok = bool(comps) and len(comps) == len(rewards)
    row["rollout_contract_valid_n"] = sum(1 for c in comps if c.get("contract_valid") is True) if v2_ok else None
    row["rollout_plan_coherent_n"] = sum(1 for c in comps if c.get("plan_coherent") is True) if v2_ok else None
    row["rollout_strict_failure_n"] = sum(1 for c in comps if c.get("strict_failure_type")) if v2_ok else None
    for k in ("rollout_contract_valid_n", "rollout_plan_coherent_n", "rollout_strict_failure_n"):
        if row[k] is None:
            missing[k] = "NOT_RECORDED_UNDER_V1" if rcv == "REWARD_CONTRACT_V1" else "NOT_RECORDED"
    walls = [g.get("wall_s") for g in groups if isinstance(g.get("wall_s"), (int, float))]
    row["rollout_group_wall_s_sum"] = round(sum(walls), 1) if walls else None
    row["train_seed_start"] = (roll or {}).get("train_seed_start")
    row["seeds_consumed"] = (roll or {}).get("seeds_consumed")

    # --- train ---------------------------------------------------------
    na_train = "NOT_RUN" if skipped else "NOT_RECORDED"
    row["train_status"] = (train or {}).get("status")
    row["optimizer_steps"] = (train or {}).get("optimizer_steps")
    row["vram_peak_train_gib"] = (train or {}).get("peak_device_vram_gib")
    row["min_free_ram_train_gib"] = (train or {}).get("minimum_available_system_ram_gib")
    for k in ("train_status", "optimizer_steps", "vram_peak_train_gib", "min_free_ram_train_gib"):
        if row[k] is None:
            missing[k] = na_train

    # --- eval ----------------------------------------------------------
    na_eval = "NOT_RUN" if skipped else "NOT_RECORDED"
    matches = (ev or {}).get("matches") or []
    row["eval_status"] = (ev or {}).get("status")
    row["eval_seeds"] = (ev or {}).get("eval_seeds")
    for k, sk in (("eval_wins", "wins"), ("eval_losses", "losses"),
                  ("eval_draws", "draws"), ("eval_strict_failures", "strict_failures")):
        row[k] = (ev or {}).get(sk)
        if row[k] is None:
            missing[k] = na_eval
    row["eval_score"] = (row["eval_wins"] + 0.5 * row["eval_draws"]) \
        if row["eval_wins"] is not None and row["eval_draws"] is not None else None
    row["eval_n_matches"] = len(matches) if ev else None
    codes: Dict[str, int] = {}
    for m in matches:
        if m.get("strict_failure_candidate") is True:
            side = (m.get("candidate_side") or "").lower()
            code = m.get(f"fault_{side}") or m.get("terminal_reason") or "UNKNOWN"
            codes[code] = codes.get(code, 0) + 1
    row["eval_strict_failure_codes"] = dict(sorted(codes.items())) if ev else None
    crew = [m.get("candidate_reward") for m in matches if isinstance(m.get("candidate_reward"), (int, float))]
    row["eval_candidate_reward_mean"] = round(mean(crew), 6) if crew else None
    if row["eval_candidate_reward_mean"] is None:
        missing["eval_candidate_reward_mean"] = na_eval
    for k in ("eval_status", "eval_score", "eval_n_matches", "eval_strict_failure_codes"):
        if row[k] is None:
            missing[k] = na_eval

    # --- durations / memory / guards from phase logs --------------------
    logs = {ph: parse_phase_log(src, d / ph / "phase.log") for ph in ("rollout", "train", "eval")}
    row["rollout_duration_s"] = logs["rollout"]["duration_s"]
    row["train_duration_s"] = logs["train"]["duration_s"]
    row["eval_duration_s"] = logs["eval"]["duration_s"]
    for ph in ("rollout", "train", "eval"):
        k = f"{ph}_duration_s"
        if row[k] is None:
            missing[k] = (na_train if ph == "train" else na_eval) if ph != "rollout" else "NOT_RECORDED"
    t0, t1 = _parse_iso(res.get("started_at")), _parse_iso(res.get("finished_at"))
    row["iteration_duration_s"] = int((t1 - t0).total_seconds()) if t0 and t1 else None
    if row["iteration_duration_s"] is None:
        missing["iteration_duration_s"] = "NOT_RECORDED"
    devs = [v["device_gib_max"] for v in logs.values() if v["device_gib_max"] is not None]
    hosts = [v["host_avail_gib_min"] for v in logs.values() if v["host_avail_gib_min"] is not None]
    if isinstance(row["vram_peak_train_gib"], (int, float)):
        devs.append(row["vram_peak_train_gib"])
    row["vram_peak_phase_logs_gib"] = max(devs) if devs else None
    row["min_host_avail_phase_logs_gib"] = min(hosts) if hosts else None
    for k in ("vram_peak_phase_logs_gib", "min_host_avail_phase_logs_gib"):
        if row[k] is None:
            missing[k] = "NOT_RECORDED"
    statuses = [(roll or {}).get("status"), (train or {}).get("status"), (ev or {}).get("status")]
    row["guard_trips"] = sum(v["guard_trips"] for v in logs.values()) + \
        sum(1 for s in statuses if s == "FAILED_MEMORY_GUARD")
    row["phase_restarts"] = sum(max(0, v["starts"] - 1) for v in logs.values())
    row["phase_fatal_lines"] = sum(v["fatal_lines"] for v in logs.values())
    row["missing"] = dict(sorted(missing.items()))
    return row


def scan_marathon_logs(src: ReadOnlySource, marathon_root: Path) -> Dict[str, Any]:
    """ERROR lines (marathon stops) across marathon.log and logs/*.log, deduped
    (worker err logs duplicate marathon.log lines)."""
    files = [marathon_root / "marathon.log"] + \
        [marathon_root / "logs" / n for n in src.listdir(marathon_root / "logs") if n.endswith(".log")]
    seen = {}
    guard_lines = 0
    for f in files:
        if not src.exists(f):
            continue
        try:
            text = src.read_text(f)
        except OSError:
            continue
        for line in text.splitlines():
            m = LOG_ERROR_RE.match(line)
            if m:
                seen.setdefault((m.group(1), m.group(2)), f.name)
            if "FAILED_MEMORY_GUARD" in line:
                guard_lines += 1
    stops = [{"at_local": k[0], "message": k[1], "first_seen_in": v}
             for k, v in sorted(seen.items())]
    return {"error_stops": stops, "memory_guard_log_lines": guard_lines,
            "files_scanned": [f.name for f in files if src.exists(f)]}


def reconstruct_lineage(rows: List[dict], lineage_file: Optional[dict],
                        state: Optional[dict]) -> Dict[str, Any]:
    chain = ["B0"]
    history = []
    discrepancies = []
    champ = "B0"
    for r in rows:
        before = r.get("champion_before")
        if before is None:
            r["champion_before"] = champ
            r["champion_before_source"] = "DERIVED_PREVIOUS_ITERATION_CHAMPION_AFTER"
        elif before != champ:
            discrepancies.append(f"iteration {r['iteration']}: champion_before={before} "
                                 f"but reconstructed champion={champ}")
            champ = before
        if r["decision"] == "PROMOTE":
            history.append({"iteration": r["iteration"], "promoted": r["candidate"],
                            "replaced": champ, "eval_wins": r.get("eval_wins"),
                            "eval_losses": r.get("eval_losses"), "eval_draws": r.get("eval_draws"),
                            "eval_strict_failures": r.get("eval_strict_failures"),
                            "reason": r.get("decision_reason")})
            champ = r["candidate"]
            chain.append(champ)
        if r.get("champion_after") != champ:
            discrepancies.append(f"iteration {r['iteration']}: champion_after={r.get('champion_after')} "
                                 f"but reconstructed champion={champ}")
            champ = r.get("champion_after") or champ
    out = {"chain": chain, "promotions": history, "reconstructed_champion": champ,
           "discrepancies": discrepancies}
    recs = (lineage_file or {}).get("records") if isinstance(lineage_file, dict) else None
    if isinstance(recs, list):
        champs = [x.get("checkpoint_id") for x in recs if x.get("status") == "CHAMPION"]
        hist = [x.get("checkpoint_id") for x in recs if x.get("status") == "HISTORICAL"]
        out["lineage_file"] = {"champion": champs, "historical": hist,
                               "n_records": len(recs)}
        # file lineage may be ahead of the last COMPLETE iteration only if an
        # iteration is mid-finalization; report, never repair.
        if champs != [champ]:
            discrepancies.append(f"CHAMPION_LINEAGE.json champion={champs} vs reconstructed {champ}")
        if set(hist) != set(chain[:-1]):
            discrepancies.append(f"CHAMPION_LINEAGE.json historical={sorted(hist)} vs chain {chain[:-1]}")
        parents = {x.get("checkpoint_id"): x.get("parent_champion_id") for x in recs}
        for i in range(1, len(chain)):
            if parents.get(chain[i]) != chain[i - 1]:
                discrepancies.append(f"lineage parent of {chain[i]} = {parents.get(chain[i])}, "
                                     f"expected {chain[i - 1]}")
    else:
        out["lineage_file"] = None
    if isinstance(state, dict):
        out["marathon_state_champion"] = state.get("champion_id")
        if state.get("champion_id") != champ:
            discrepancies.append(f"MARATHON_STATE champion_id={state.get('champion_id')} "
                                 f"vs reconstructed {champ}")
    return out


def aggregate_by_reward_contract(rows: List[dict]) -> Dict[str, Any]:
    """Per reward-contract version. Rates are over rollout samples; V1 did not
    persist contract/coherence/strict components (value null, not invented)."""
    out: Dict[str, Any] = {}
    for ver in sorted({r.get("reward_contract_version") for r in rows if r.get("reward_contract_version")}):
        rs = [r for r in rows if r.get("reward_contract_version") == ver]
        n = sum(r.get("rollout_reward_n") or 0 for r in rs)
        att = sum(r.get("groups_attempted") or 0 for r in rs)
        inf = sum(r.get("groups_informative") or 0 for r in rs)

        def wmean(k):
            num = [(r[k], r.get("rollout_reward_n") or 0) for r in rs if isinstance(r.get(k), (int, float))]
            den = sum(w for _, w in num)
            return round(sum(v * w for v, w in num) / den, 6) if den else None

        def rate(k):
            recorded = [r for r in rs if isinstance(r.get(k), int)]
            den = sum(r.get("rollout_reward_n") or 0 for r in recorded)
            return {"n": sum(r[k] for r in recorded), "of": den,
                    "rate": _ratio(sum(r[k] for r in recorded), den)} if recorded else None

        out[ver] = {"iterations": len(rs),
                    "iteration_range": [rs[0]["iteration"], rs[-1]["iteration"]],
                    "rollout_samples": n,
                    "mean_terminal_reward": wmean("rollout_terminal_reward_mean"),
                    "mean_total_reward": wmean("rollout_total_reward_mean"),
                    "contract_valid": rate("rollout_contract_valid_n"),
                    "plan_coherent": rate("rollout_plan_coherent_n"),
                    "strict_failure": rate("rollout_strict_failure_n"),
                    "rollout_win_loss_draw": [sum(r.get(k) or 0 for r in rs) for k in
                                              ("rollout_n_win", "rollout_n_loss", "rollout_n_draw")],
                    "groups_attempted": att, "groups_informative": inf,
                    "informative_ratio": _ratio(inf, att),
                    "decisions": {d: sum(1 for r in rs if r["decision"] == d)
                                  for d in sorted({r["decision"] for r in rs})}}
    return out


def aggregate(rows: List[dict], incomplete: List[IterationRef], lineage: dict,
              logs: dict, state: Optional[dict], n_dirs: int) -> Dict[str, Any]:
    dec: Dict[str, int] = {}
    for r in rows:
        dec[r["decision"]] = dec.get(r["decision"], 0) + 1
    att = sum(r["groups_attempted"] or 0 for r in rows)
    inf = sum(r["groups_informative"] or 0 for r in rows)
    last10 = rows[-10:]
    a10 = sum(r["groups_attempted"] or 0 for r in last10)
    i10 = sum(r["groups_informative"] or 0 for r in last10)

    def s(k):
        return sum(r[k] for r in rows if isinstance(r.get(k), (int, float)))

    def rng(k, fn):
        vals = [r[k] for r in rows if isinstance(r.get(k), (int, float))]
        return fn(vals) if vals else None

    all_rewards_n = s("rollout_reward_n")
    agg = {
        "iterations_discovered": n_dirs,
        "iterations_complete": len(rows),
        "iterations_incomplete": [{"iteration": r.number, "reason": r.reason,
                                   "subdirs_present": r.subdirs} for r in incomplete],
        "decisions": dict(sorted(dec.items())),
        "groups_attempted_total": att,
        "groups_informative_total": inf,
        "informative_ratio_cumulative": _ratio(inf, att),
        "informative_ratio_last10": _ratio(i10, a10),
        "informative_ratio_last10_window": [last10[0]["iteration"], last10[-1]["iteration"]] if last10 else None,
        "informative_ratio_latest": rows[-1]["informative_ratio"] if rows else None,
        "optimizer_steps_total": s("optimizer_steps"),
        "eval_wins_total": s("eval_wins"), "eval_losses_total": s("eval_losses"),
        "eval_draws_total": s("eval_draws"), "eval_strict_failures_total": s("eval_strict_failures"),
        "eval_matches_total": s("eval_n_matches"),
        "rollout_samples_total": all_rewards_n,
        "rollout_reward_mean_overall": round(sum((r["rollout_reward_mean"] or 0) * (r["rollout_reward_n"] or 0)
                                                 for r in rows) / all_rewards_n, 6) if all_rewards_n else None,
        "rollout_n_win_total": s("rollout_n_win"), "rollout_n_loss_total": s("rollout_n_loss"),
        "rollout_n_draw_total": s("rollout_n_draw"),
        "vram_peak_train_gib_max": rng("vram_peak_train_gib", max),
        "vram_peak_phase_logs_gib_max": rng("vram_peak_phase_logs_gib", max),
        "min_free_ram_train_gib_min": rng("min_free_ram_train_gib", min),
        "min_host_avail_phase_logs_gib_min": rng("min_host_avail_phase_logs_gib", min),
        "guard_trips_total": s("guard_trips") + logs.get("memory_guard_log_lines", 0),
        "marathon_error_stops": logs.get("error_stops", []),
        "mean_iteration_duration_s": round(mean([r["iteration_duration_s"] for r in rows
                                                 if r.get("iteration_duration_s")]), 1)
        if any(r.get("iteration_duration_s") for r in rows) else None,
        "latest_champion": lineage.get("reconstructed_champion"),
        "latest_complete_iteration": rows[-1]["iteration"] if rows else None,
        "by_reward_contract": aggregate_by_reward_contract(rows),
    }
    if isinstance(state, dict):
        snap = {k: state.get(k) for k in ("status", "current_iteration", "current_phase",
                                            "champion_id", "candidate_id", "last_heartbeat",
                                            "optimizer_steps_total", "wins", "losses", "draws",
                                            "strict_failures_total", "vram_peak_gib",
                                            "min_free_ram_gib")}
        agg["marathon_state_snapshot"] = snap
        cross = {}
        for ours, theirs in (("optimizer_steps_total", "optimizer_steps_total"),
                             ("eval_wins_total", "wins"), ("eval_losses_total", "losses"),
                             ("eval_draws_total", "draws"),
                             ("eval_strict_failures_total", "strict_failures_total")):
            cross[theirs] = {"from_iterations": agg[ours], "marathon_state": state.get(theirs),
                             "match": agg[ours] == state.get(theirs)}
        agg["cross_check_vs_marathon_state"] = cross
    else:
        agg["marathon_state_snapshot"] = None
    return agg


def _fmt(v, code=None):
    if v is None:
        return code or "NOT_RECORDED"
    if isinstance(v, bool):
        return "true" if v else "false"
    return v


def render_csv(rows: List[dict]) -> str:
    buf = io.StringIO()
    w = csv.writer(buf, lineterminator="\n")
    w.writerow(CSV_FIELDS)
    for r in rows:
        w.writerow([_fmt(r.get(k), r.get("missing", {}).get(k)) for k in CSV_FIELDS])
    return buf.getvalue()


def render_summary(doc: dict) -> str:
    a = doc["aggregates"]
    lin = doc["lineage"]
    L = ["# TRAINING METRICS SUMMARY", "",
         f"- source: `{doc['source_root']}` (read-only)",
         f"- generated_at: {doc['generated_at']}",
         f"- iterations discovered: {a['iterations_discovered']} "
         f"(complete {a['iterations_complete']}, incomplete {len(a['iterations_incomplete'])})",
         f"- decisions: {a['decisions']}",
         f"- latest champion: **{a['latest_champion']}** (chain {' -> '.join(lin['chain'])})",
         f"- informative/attempted groups: cumulative {a['groups_informative_total']}/"
         f"{a['groups_attempted_total']} = {a['informative_ratio_cumulative']}; "
         f"last 10 iterations {a['informative_ratio_last10']} "
         f"(window {a['informative_ratio_last10_window']}); latest {a['informative_ratio_latest']}",
         f"- optimizer steps total: {a['optimizer_steps_total']}",
         f"- eval W/L/D: {a['eval_wins_total']}/{a['eval_losses_total']}/{a['eval_draws_total']} "
         f"over {a['eval_matches_total']} matches; candidate strict failures {a['eval_strict_failures_total']}",
         f"- rollout samples {a['rollout_samples_total']}: WIN {a['rollout_n_win_total']} / "
         f"LOSS {a['rollout_n_loss_total']} / DRAW {a['rollout_n_draw_total']}; "
         f"mean reward {a['rollout_reward_mean_overall']}",
         f"- VRAM peak (train_summary) {a['vram_peak_train_gib_max']} GiB; "
         f"min free host RAM (train_summary) {a['min_free_ram_train_gib_min']} GiB; "
         f"phase-log min host_avail {a['min_host_avail_phase_logs_gib_min']} GiB",
         f"- memory guard trips: {a['guard_trips_total']}",
         f"- mean iteration duration: {a['mean_iteration_duration_s']} s", ""]
    if a.get("by_reward_contract"):
        L.append("## Reward contracts (training signal; eval/promotion never use shaped reward)")
        L.append("| contract | iterations | samples | mean terminal | mean total (GRPO) | contract-valid | "
                 "plan-coherent | strict failure | informative/attempted | W/L/D (rollout) |")
        L.append("|---|---|---|---|---|---|---|---|---|---|")

        def rt(x):
            return "not recorded" if x is None else f"{x['n']}/{x['of']} = {x['rate']}"
        for ver, b in a["by_reward_contract"].items():
            L.append(f"| {ver} | {b['iterations']} ({b['iteration_range'][0]}-{b['iteration_range'][1]}) | "
                     f"{b['rollout_samples']} | {b['mean_terminal_reward']} | {b['mean_total_reward']} | "
                     f"{rt(b['contract_valid'])} | {rt(b['plan_coherent'])} | {rt(b['strict_failure'])} | "
                     f"{b['groups_informative']}/{b['groups_attempted']} = {b['informative_ratio']} | "
                     f"{'/'.join(str(x) for x in b['rollout_win_loss_draw'])} |")
        L.append("")
    if a["iterations_incomplete"]:
        L.append("## Incomplete (skipped, not read)")
        for r in a["iterations_incomplete"]:
            L.append(f"- iteration {r['iteration']}: {r['reason']} subdirs={r['subdirs_present']}")
        L.append("")
    L.append("## Promotion history")
    for p in lin["promotions"]:
        L.append(f"- it {p['iteration']}: {p['replaced']} -> **{p['promoted']}** "
                 f"(W{p['eval_wins']}/L{p['eval_losses']}/D{p['eval_draws']}, strict {p['eval_strict_failures']})")
    L.append("")
    L.append("## Lineage discrepancies")
    L += [f"- {x}" for x in lin["discrepancies"]] or ["- none"]
    L.append("")
    if a.get("cross_check_vs_marathon_state"):
        L.append("## Cross-check vs MARATHON_STATE.json (single read)")
        for k, v in a["cross_check_vs_marathon_state"].items():
            L.append(f"- {k}: iterations={v['from_iterations']} state={v['marathon_state']} "
                     f"{'OK' if v['match'] else 'DIFF'}")
        L.append("")
    L.append("## Marathon error stops (marathon.log + logs/*.log, deduped)")
    L += [f"- {s['at_local']} {s['message']}" for s in a["marathon_error_stops"]] or ["- none"]
    L.append("")
    L.append("## Per-iteration")
    L.append("| it | cand | champ before->after | decision | att | inf | ratio | steps | W/L/D | strict | rollout mean R | dur s |")
    L.append("|---|---|---|---|---|---|---|---|---|---|---|---|")
    for r in doc["iterations"]:
        wld = "-" if r["eval_wins"] is None else f"{r['eval_wins']}/{r['eval_losses']}/{r['eval_draws']}"
        L.append(f"| {r['iteration']} | {r['candidate']} | {r['champion_before']}->{r['champion_after']} | "
                 f"{r['decision']} | {r['groups_attempted']} | {r['groups_informative']} | "
                 f"{r['informative_ratio']} | {_fmt(r['optimizer_steps'], r['missing'].get('optimizer_steps'))} | "
                 f"{wld} | {_fmt(r['eval_strict_failures'], r['missing'].get('eval_strict_failures'))} | "
                 f"{r['rollout_reward_mean']} | {_fmt(r['iteration_duration_s'], r['missing'].get('iteration_duration_s'))} |")
    L.append("")
    L.append("Field notes: durations of rollout/train/eval come from phase.log (last 'start' line to "
             "last line; local clock, no date). iteration_duration_s = finished_at - started_at "
             "(SKIPPED_NO_SIGNAL results do not record them). champion_before for SKIPPED iterations "
             "is DERIVED from the previous iteration's champion_after.")
    return "\n".join(L) + "\n"


def run_metrics(paths: Paths, src: Optional[ReadOnlySource] = None,
                snapshot: Optional[LiveSnapshot] = None, now: Optional[str] = None) -> Dict[str, Any]:
    src = src or ReadOnlySource()
    snapshot = snapshot or LiveSnapshot(src, paths.marathon_root)
    writer = OutputWriter(paths.output_root, paths.protected_roots)
    mdir = paths.metrics_dir
    cache = writer.read_own_json(mdir / "scan_cache.json", default={}) or {}
    if cache.get("version") != ROW_CACHE_VERSION:
        cache = {"version": ROW_CACHE_VERSION, "rows": {}}

    issues: List[dict] = []
    refs = discover_iterations(src, paths.marathon_root)
    rows, incomplete, reused = [], [], 0
    for ref in refs:
        if not ref.complete:
            incomplete.append(ref)
            continue
        sig = src.stat_sig(ref.path / "ITERATION_RESULT.json")
        c = cache["rows"].get(str(ref.number))
        if c and c.get("sig") == sig:
            rows.append(c["row"])
            issues += c.get("issues", [])
            reused += 1
            continue
        row_issues: List[dict] = []
        row = build_row(src, ref, row_issues)
        cache["rows"][str(ref.number)] = {"sig": sig, "row": row, "issues": row_issues}
        rows.append(row)
        issues += row_issues
    rows = [dict(r) for r in rows]  # lineage reconstruction annotates copies
    logs = scan_marathon_logs(src, paths.marathon_root)
    state = snapshot.get("MARATHON_STATE.json")
    lineage_file = snapshot.get("CHAMPION_LINEAGE.json")
    lineage = reconstruct_lineage(rows, lineage_file, state)
    agg = aggregate(rows, incomplete, lineage, logs, state, len(refs))
    doc = {"schema_version": METRICS_SCHEMA_VERSION,
           "generated_at": now or datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
           "source_root": str(paths.marathon_root),
           "completion_rule": "ITERATION_RESULT.json present, parseable, iteration matches dir, has decision",
           "live_state_read_errors": snapshot.errors,
           "aggregates": agg, "lineage": lineage, "issues": issues,
           "iterations": rows,
           "scan": {"rows_reused_from_cache": reused, "rows_built": len(rows) - reused}}
    writer.write_json(mdir / "scan_cache.json", cache)
    body = {k: v for k, v in doc.items() if k != "scan"}
    writer.write_json(mdir / "TRAINING_METRICS.json", body)
    writer.write_text(mdir / "iterations.csv", render_csv(rows))
    writer.write_text(mdir / "SUMMARY.md", render_summary(doc))
    return doc
