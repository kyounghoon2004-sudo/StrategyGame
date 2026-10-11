"""CLI: python -m tools.training_observability <command>  (run from StrategyGame/)

  refresh          metrics + dataset + audit-prepare (live state files read once)
  metrics          TASK 1 only
  dataset          TASK 2 only  [--rebuild] [--no-historical]
  audit-prepare    TASK 3 seed registry / config / plan (CPU only, no execution)
  audit-report     stats + report from a results JSON  [--synthetic]
  audit-run        FUTURE live audit - currently refuses (AuditExecutionDisabled)
  dataset-cat      print records from the dataset
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

from . import audit_harness as A
from .config import Paths
from .dataset_builder import iter_dataset, run_dataset
from .marathon_scan import LiveSnapshot
from .metrics import run_metrics
from .safe_io import OutputWriter, ReadOnlySource


def _paths(ns) -> Paths:
    p = Paths()
    if ns.marathon_root:
        p.marathon_root = Path(ns.marathon_root)
    if ns.output_root:
        p.output_root = Path(ns.output_root)
    if ns.prompt_src:
        p.prompt_src = Path(ns.prompt_src)
    if ns.historical_root:
        p.historical_roots = {}
        for item in ns.historical_root:
            k, v = item.split("=", 1)
            p.historical_roots[k] = Path(v)
    return p


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(prog="python -m tools.training_observability")
    ap.add_argument("command", choices=["refresh", "metrics", "dataset", "audit-prepare",
                                        "audit-report", "audit-run", "dataset-cat"])
    ap.add_argument("--marathon-root")
    ap.add_argument("--output-root")
    ap.add_argument("--prompt-src")
    ap.add_argument("--historical-root", action="append", help="name=path (repeatable)")
    ap.add_argument("--rebuild", action="store_true")
    ap.add_argument("--no-historical", action="store_true")
    ap.add_argument("--no-live-state", action="store_true",
                    help="do not read MARATHON_STATE.json / CHAMPION_LINEAGE.json at all")
    ap.add_argument("--pairs", type=int, default=A.REGISTRY_DEFAULT_PAIRS)
    ap.add_argument("--games-per-opponent", type=int, default=16)
    ap.add_argument("--results")
    ap.add_argument("--audit-id")
    ap.add_argument("--champion")
    ap.add_argument("--synthetic", action="store_true")
    ap.add_argument("--config")
    ap.add_argument("--execute-live", action="store_true")
    ap.add_argument("--limit", type=int, default=3)
    ns = ap.parse_args(argv)
    paths = _paths(ns)
    src = ReadOnlySource()
    snap = LiveSnapshot(src, paths.marathon_root, enabled=not ns.no_live_state)

    if ns.command in ("refresh", "metrics"):
        doc = run_metrics(paths, src, snap)
        a = doc["aggregates"]
        print(json.dumps({"metrics": {"complete": a["iterations_complete"],
                                      "incomplete": [x["iteration"] for x in a["iterations_incomplete"]],
                                      "latest_champion": a["latest_champion"],
                                      "informative_ratio_cumulative": a["informative_ratio_cumulative"],
                                      "discrepancies": doc["lineage"]["discrepancies"]}}))
    if ns.command in ("refresh", "dataset"):
        man = run_dataset(paths, src, snap, rebuild=ns.rebuild, include_historical=not ns.no_historical)
        s = man["stats"]
        print(json.dumps({"dataset": {"records": s["n_records"], "rollout": s["n_rollout_samples"],
                                      "eval": s["n_eval_matches"], "incomplete": s["n_incomplete_records"],
                                      "issues": s["n_issues"], "added": man["last_build"]["records_added"]}}))
    if ns.command in ("refresh", "audit-prepare"):
        out = A.prepare_audit_assets(paths, src, snap, n_pairs=ns.pairs,
                                     games_per_opponent=ns.games_per_opponent)
        print(json.dumps({"audit_prepare": {"registry": out["registry"]["seed_range"],
                                            "verdict": out["registry"]["disjointness"]["verdict"],
                                            "champion": (out["config"]["champion"] or {}).get("id"),
                                            "opponents": [o["id"] for o in out["config"]["opponents"]],
                                            "planned_games": (out["plan"] or {}).get("n_games")}}))
    if ns.command == "audit-report":
        if not ns.results or not ns.audit_id:
            ap.error("audit-report needs --results and --audit-id")
        doc = json.loads(Path(ns.results).read_text(encoding="utf-8"))
        games = doc["games"] if isinstance(doc, dict) else doc
        synthetic = ns.synthetic or bool(isinstance(doc, dict) and doc.get("synthetic"))
        writer = OutputWriter(paths.output_root, paths.protected_roots)
        res = A.write_audit(writer, paths.audits_dir, ns.audit_id, games,
                            ns.champion or (doc.get("champion") if isinstance(doc, dict) else None), synthetic)
        print(json.dumps({"audit": ns.audit_id, "non_transitivity": res["non_transitivity"]["verdict"]}))
    if ns.command == "audit-run":
        if not ns.execute_live:
            print("audit-run requires --execute-live (and is DISABLED in this build).", file=sys.stderr)
            return 2
        try:
            A.LiveMatchExecutor().run({})
        except A.AuditExecutionDisabled as e:
            print(f"REFUSED: {e}", file=sys.stderr)
            return 3
    if ns.command == "dataset-cat":
        for i, r in enumerate(iter_dataset(paths.dataset_dir)):
            if i >= ns.limit:
                break
            print(json.dumps(r, ensure_ascii=False)[:2000])
    return 0


if __name__ == "__main__":
    sys.exit(main())
