"""TASK 3 - future champion audit harness (IMPLEMENTED, NOT EXECUTED).

What exists and is safe to run now (CPU only, no model, no Godot, no lock):
  * held-out seed registry (reserved namespace, verified disjoint from every
    seed observed in marathon/historical artifacts and from the producer's
    projected train/eval seed streams)
  * audit config + plan (side-swapped seed pairs x opponents)
  * statistics + report from a results file (tested with SYNTHETIC fixtures)

What is deliberately NOT implemented here: live execution. LiveMatchExecutor
raises AuditExecutionDisabled. Future runtime protocol (documented contract):
  1. Audit runs BETWEEN marathon iterations, never parallel with rollout/
     train/eval: stop the marathon at an iteration boundary (runner's own
     STOP_REQUESTED mechanism), confirm MARATHON_STATE.current_phase is not
     ROLLOUT/TRAIN_BRAIN/EVAL and no marathon-owned process is alive.
  2. Acquire the EXISTING GPU lock D:\\StrategyAI\\locks\\training_marathon_v1.lock
     through the supervisor's own lock manager; hold it for the whole audit.
  3. Per policy: load base (+adapter), generate RED and BLUE plans for every
     registry seed with the locked eval sampling contract, unload; then run
     tools/rl_sym_eval.gd per game; write results to audits/<audit_id>/.
  4. Release the lock; resume the marathon.

Statistics (unit of analysis = side-swapped seed PAIR):
  game points for player A: WIN 1, DRAW 0.5, LOSS 0; score = W + 0.5 D
  pair score = sum over the two side-swapped games (0..2)
  score rate  = mean(pair score) / 2
  95% CI      = percentile bootstrap over complete pairs (fixed RNG seed)
  significant = CI excludes 0.5
  non-transitivity: directed edge A->B iff score rate(A vs B) > 0.5; a cycle
  is reported CYCLE only if every edge is significant, else UNRESOLVED.
"""
from __future__ import annotations

import hashlib
import json
import random
import re
from pathlib import Path
from statistics import mean, pstdev
from typing import Any, Dict, List, Optional, Tuple

from . import config as C
from .config import Paths
from .marathon_scan import LiveSnapshot
from .safe_io import OutputWriter, ReadOnlySource

REGISTRY_NAMESPACE = "AUDIT_HELDOUT_V1"
REGISTRY_BASE = 700_000_000
REGISTRY_DEFAULT_PAIRS = 64
BOOTSTRAP_RESAMPLES = 10_000
BOOTSTRAP_SEED = 20260925
POINTS = {"WIN": 1.0, "DRAW": 0.5, "LOSS": 0.0}
FLIP = {"WIN": "LOSS", "LOSS": "WIN", "DRAW": "DRAW"}


class AuditExecutionDisabled(RuntimeError):
    pass


# ----------------------------------------------------------------------------
# seeds
# ----------------------------------------------------------------------------
FILENAME_SEED_RES = [
    (re.compile(r"^group\d+_s(\d+)\.txt$"), "rollout_generation"),
    (re.compile(r"^rollout_.*g\d+s(\d+)(?:_in|_out)?\.json$"), "rollout_generation"),
    (re.compile(r"^eval_s(\d+)_m\d+(?:_in|_out)?\.json$"), "eval"),
    (re.compile(r"^\w+_(?:RED|BLUE)_(\d+)\.txt$"), "eval"),
]


def observed_seeds(src: ReadOnlySource, paths: Paths) -> Dict[str, Any]:
    """Collect seeds from FILE NAMES (directory listings only - safe for the
    in-progress iteration too) plus rollout episode seeds (= 1000 + generation
    seed, the producer rule; the _in.json files carry the same value)."""
    gen, ev = set(), set()
    dirs: List[Path] = []
    it_root = Path(paths.marathon_root) / "iterations"
    for name in src.listdir(it_root):
        if name.startswith("iteration_"):
            dirs += [it_root / name / "rollout", it_root / name / "eval"]
    for root in paths.historical_roots.values():
        dirs += [Path(root) / "raw", Path(root) / "raw" / "rollouts", Path(root) / "raw" / "eval"]
    for d in dirs:
        for n in src.listdir(d):
            for rx, kind in FILENAME_SEED_RES:
                m = rx.match(n)
                if m:
                    (gen if kind == "rollout_generation" else ev).add(int(m.group(1)))
                    break
    episode = {s + C.ROLLOUT_EPISODE_SEED_OFFSET for s in gen}
    allseeds = gen | ev | episode
    return {"rollout_generation": sorted(gen), "eval": sorted(ev), "rollout_episode": sorted(episode),
            "all": sorted(allseeds)}


def projected_stream_max(horizon_iterations: int) -> int:
    train_max = C.TRAIN_SEED_BASE + (horizon_iterations - 1) * C.TRAIN_SEED_STRIDE + C.MAX_GROUPS * 2 - 1
    eval_max = C.EVAL_SEED_BASE + (horizon_iterations - 1) * C.EVAL_SEED_STRIDE + 1
    return max(train_max + C.ROLLOUT_EPISODE_SEED_OFFSET, eval_max)


def safe_until_iteration(base: int) -> int:
    """Largest iteration N for which the producer's train/eval streams (and
    rollout episode seeds) stay strictly below the reserved base."""
    n_train = (base - 1 - C.ROLLOUT_EPISODE_SEED_OFFSET - C.TRAIN_SEED_BASE - (C.MAX_GROUPS * 2 - 1)) \
        // C.TRAIN_SEED_STRIDE + 1
    n_eval = (base - 1 - 1 - C.EVAL_SEED_BASE) // C.EVAL_SEED_STRIDE + 1
    return min(n_train, n_eval)


def build_seed_registry(observed: Dict[str, Any], n_pairs: int = REGISTRY_DEFAULT_PAIRS,
                        base: int = REGISTRY_BASE, horizon_iterations: int = 100_000) -> Dict[str, Any]:
    seeds = [base + i for i in range(1, n_pairs + 1)]
    overlap = sorted(set(seeds) & set(observed["all"]))
    proj_max = projected_stream_max(horizon_iterations)
    proj_overlap = proj_max >= seeds[0]
    reg = {
        "namespace": REGISTRY_NAMESPACE, "base": base,
        "seed_range": [seeds[0], seeds[-1]],
        "semantics": "each seed = one side-swapped PAIR: game A champion RED, game B champion BLUE; "
                     "seed used as generation seed and Godot match seed (same as marathon eval)",
        "pairs": [{"pair_id": f"P{i + 1:03d}", "seed": s} for i, s in enumerate(seeds)],
        "disjointness": {
            "observed_counts": {k: len(v) for k, v in observed.items()},
            "observed_min": min(observed["all"]) if observed["all"] else None,
            "observed_max": max(observed["all"]) if observed["all"] else None,
            "overlap_with_observed": overlap,
            "projected_stream_max_at_horizon": proj_max,
            "projection_horizon_iterations": horizon_iterations,
            "overlap_with_projected_streams": proj_overlap,
            "producer_streams_safe_until_iteration": safe_until_iteration(base),
            "verdict": "DISJOINT" if not overlap and not proj_overlap else "OVERLAP",
        },
        "registry_sha256": None,
    }
    reg["registry_sha256"] = hashlib.sha256(json.dumps(reg["pairs"]).encode()).hexdigest()
    if reg["disjointness"]["verdict"] != "DISJOINT":
        raise ValueError(f"held-out seeds not disjoint: {reg['disjointness']}")
    return reg


# ----------------------------------------------------------------------------
# config / plan
# ----------------------------------------------------------------------------
def default_config(lineage: Optional[dict], registry: dict, games_per_opponent: int = 16,
                   round_robin: bool = False) -> Dict[str, Any]:
    recs = (lineage or {}).get("records") or []
    champ = next((r for r in recs if r.get("status") == "CHAMPION"), None)
    milestones = [r for r in recs if r.get("status") == "HISTORICAL"]
    opponents = []
    for r in sorted(milestones, key=lambda r: r.get("iteration") or 0):
        opponents.append({"id": r["checkpoint_id"], "adapter_path": r.get("artifact_path"),
                          "role": "B0" if r["checkpoint_id"] == "B0" else "HISTORICAL_MILESTONE"})
    if not any(o["id"] == "B0" for o in opponents):
        opponents.insert(0, {"id": "B0", "adapter_path": None, "role": "B0"})
    return {"audit_config_version": 1,
            "champion": {"id": champ["checkpoint_id"], "adapter_path": champ.get("artifact_path")}
            if champ else None,
            "opponents": opponents, "games_per_opponent": games_per_opponent,
            "round_robin_between_opponents": round_robin,
            "seed_registry_sha256": registry["registry_sha256"],
            "sampling_contract": "same as marathon eval (temp 0.7/top_p 0.8/top_k 20/1280 tok/non-thinking, max_turns 6)",
            "execution": "BETWEEN_ITERATIONS_ONLY; uses existing GPU lock; NOT RUN BY THIS TASK"}


def build_plan(cfg: dict, registry: dict) -> Dict[str, Any]:
    g = int(cfg["games_per_opponent"])
    if g <= 0 or g % 2:
        raise ValueError("games_per_opponent must be a positive even number (side-swapped pairs)")
    n_pairs = g // 2
    if n_pairs > len(registry["pairs"]):
        raise ValueError(f"need {n_pairs} pairs, registry has {len(registry['pairs'])}")
    pairs = registry["pairs"][:n_pairs]
    champ = cfg["champion"]["id"]
    opp = [o["id"] for o in cfg["opponents"] if o["id"] != champ]
    matchups = [(champ, o) for o in opp]
    if cfg.get("round_robin_between_opponents"):
        matchups += [(a, b) for i, a in enumerate(opp) for b in opp[i + 1:]]
    games = []
    for a, b in matchups:
        for p in pairs:
            games.append({"game_id": f"{a}_vs_{b}_{p['pair_id']}_A", "player_a": a, "player_b": b,
                          "pair_id": p["pair_id"], "seed": p["seed"], "a_side": "RED"})
            games.append({"game_id": f"{a}_vs_{b}_{p['pair_id']}_B", "player_a": a, "player_b": b,
                          "pair_id": p["pair_id"], "seed": p["seed"], "a_side": "BLUE"})
    return {"champion": champ, "matchups": [list(m) for m in matchups], "n_games": len(games),
            "pairs_per_matchup": n_pairs, "games": games}


# ----------------------------------------------------------------------------
# statistics
# ----------------------------------------------------------------------------
def bootstrap_ci(pair_scores: List[float], resamples: int = BOOTSTRAP_RESAMPLES,
                 seed: int = BOOTSTRAP_SEED, alpha: float = 0.05) -> Tuple[Optional[float], Optional[float]]:
    """Percentile bootstrap CI of score rate (= mean pair score / 2)."""
    n = len(pair_scores)
    if n == 0:
        return None, None
    rng = random.Random(seed)
    means = []
    for _ in range(resamples):
        s = 0.0
        for _ in range(n):
            s += pair_scores[rng.randrange(n)]
        means.append(s / n / 2.0)
    means.sort()
    lo = means[int((alpha / 2) * resamples)]
    hi = means[min(resamples - 1, int((1 - alpha / 2) * resamples) - 1)]
    return round(lo, 6), round(hi, 6)


def _oriented(game: dict, a: str) -> Tuple[str, bool, bool, str]:
    """Return (outcome for a, strict a, strict b, a_side) for a game involving a."""
    if game["player_a"] == a:
        return game["outcome_a"], bool(game.get("strict_a")), bool(game.get("strict_b")), game["a_side"]
    return FLIP[game["outcome_a"]], bool(game.get("strict_b")), bool(game.get("strict_a")), \
        ("BLUE" if game["a_side"] == "RED" else "RED")


def matchup_stats(games: List[dict], a: str, b: str) -> Dict[str, Any]:
    gs = [g for g in games if {g["player_a"], g["player_b"]} == {a, b}]
    W = L = D = sa = sb = 0
    by_pair: Dict[str, Dict[str, str]] = {}
    for g in gs:
        o, s1, s2, side = _oriented(g, a)
        W += o == "WIN"
        L += o == "LOSS"
        D += o == "DRAW"
        sa += s1
        sb += s2
        by_pair.setdefault(g["pair_id"], {})[side] = o
    complete = {p: v for p, v in by_pair.items() if set(v) == {"RED", "BLUE"}}
    incomplete = sorted(p for p in by_pair if p not in complete)
    pair_scores = [POINTS[v["RED"]] + POINTS[v["BLUE"]] for _, v in sorted(complete.items())]
    shapes: Dict[str, int] = {}
    for _, v in sorted(complete.items()):
        k = "".join(sorted(x[0] for x in (v["RED"], v["BLUE"])))  # e.g. "DW", "LW"
        shapes[k] = shapes.get(k, 0) + 1
    n = len(gs)
    lo, hi = bootstrap_ci(pair_scores)
    rate = round(mean(pair_scores) / 2, 6) if pair_scores else None
    sig = None
    if lo is not None:
        sig = "A_BETTER" if lo > 0.5 else ("B_BETTER" if hi < 0.5 else "NOT_SIGNIFICANT")
    return {"a": a, "b": b, "games": n, "wins": W, "losses": L, "draws": D,
            "score": W + 0.5 * D, "score_rate_games": round((W + 0.5 * D) / n, 6) if n else None,
            "n_pairs_complete": len(pair_scores), "pairs_incomplete": incomplete,
            "pair_score_mean": round(mean(pair_scores), 6) if pair_scores else None,
            "pair_score_sd": round(pstdev(pair_scores), 6) if len(pair_scores) > 1 else None,
            "pair_shapes": shapes, "score_rate": rate, "ci95": [lo, hi], "significance": sig,
            "strict_failures_a": sa, "strict_failures_b": sb,
            "strict_failure_rate_per_game_a": round(sa / n, 6) if n else None,
            "strict_failure_rate_per_game_b": round(sb / n, 6) if n else None}


def simple_cycles(nodes: List[str], edges: Dict[str, set]) -> List[List[str]]:
    """All simple directed cycles of length >= 3, canonical (start at min node)."""
    idx = {n: i for i, n in enumerate(nodes)}
    out = []

    def dfs(start, cur, path, visited):
        for nx in sorted(edges.get(cur, ()), key=idx.get):
            if nx == start and len(path) >= 3:
                out.append(list(path))
            elif nx not in visited and idx[nx] > idx[start]:
                visited.add(nx)
                path.append(nx)
                dfs(start, nx, path, visited)
                path.pop()
                visited.discard(nx)

    for s in nodes:
        dfs(s, s, [s], {s})
    return out


def analyze(games: List[dict], champion: Optional[str] = None) -> Dict[str, Any]:
    for g in games:
        if g.get("outcome_a") not in POINTS:
            raise ValueError(f"bad outcome in {g.get('game_id')}: {g.get('outcome_a')}")
    players = sorted({g["player_a"] for g in games} | {g["player_b"] for g in games})
    if champion in players:
        players.remove(champion)
        players.insert(0, champion)
    matchups = {}
    for i, a in enumerate(players):
        for b in players[i + 1:]:
            st = matchup_stats(games, a, b)
            if st["games"]:
                matchups[f"{a}|{b}"] = st
    matrix: Dict[str, Dict[str, Any]] = {a: {} for a in players}
    edges: Dict[str, set] = {a: set() for a in players}
    sig_edges = set()
    for key, st in matchups.items():
        a, b = key.split("|")
        r = st["score_rate"]
        ci = st["ci95"]
        matrix[a][b] = {"score_rate": r, "ci95": ci, "significance": st["significance"]}
        matrix[b][a] = {"score_rate": None if r is None else round(1 - r, 6),
                        "ci95": [None if ci[1] is None else round(1 - ci[1], 6),
                                 None if ci[0] is None else round(1 - ci[0], 6)],
                        "significance": {"A_BETTER": "B_BETTER", "B_BETTER": "A_BETTER"}.get(
                            st["significance"], st["significance"])}
        if r is not None and r > 0.5:
            edges[a].add(b)
            if st["significance"] == "A_BETTER":
                sig_edges.add((a, b))
        elif r is not None and r < 0.5:
            edges[b].add(a)
            if st["significance"] == "B_BETTER":
                sig_edges.add((b, a))
    opp_edges = [k for k in matchups if champion not in k.split("|")] if champion else list(matchups)
    cycles = []
    for cyc in simple_cycles(players, edges):
        es = [(cyc[i], cyc[(i + 1) % len(cyc)]) for i in range(len(cyc))]
        cycles.append({"cycle": cyc + [cyc[0]],
                       "status": "CYCLE" if all(e in sig_edges for e in es) else "UNRESOLVED",
                       "non_significant_edges": [list(e) for e in es if e not in sig_edges]})
    if not opp_edges and champion:
        verdict = "NOT_TESTABLE (no opponent-vs-opponent games; enable round_robin_between_opponents)"
    elif any(c["status"] == "CYCLE" for c in cycles):
        verdict = "CYCLE"
    elif cycles:
        verdict = "UNRESOLVED"
    else:
        verdict = "NONE (point-estimate dominance graph is acyclic)"
    return {"players": players, "champion": champion, "matchups": matchups, "matrix": matrix,
            "non_transitivity": {"verdict": verdict, "cycles": cycles},
            "method": {"unit": "side-swapped seed pair", "ci": "percentile bootstrap over pairs",
                       "resamples": BOOTSTRAP_RESAMPLES, "rng_seed": BOOTSTRAP_SEED,
                       "score": "W + 0.5*D"}}


def render_report(result: dict, meta: dict) -> str:
    L = [f"# AUDIT REPORT - {meta.get('audit_id')}", ""]
    if meta.get("synthetic"):
        L += ["> **SYNTHETIC FIXTURE RESULTS - NOT A REAL AUDIT.**", ""]
    L += [f"- champion: {result['champion']}; players: {', '.join(result['players'])}",
          f"- method: {result['method']}", "",
          "## Champion vs opponent", "",
          "| A | B | games | W/L/D | score | pairs | score rate | 95% CI | sig | strict/game A | strict/game B |",
          "|---|---|---|---|---|---|---|---|---|---|---|"]
    for st in result["matchups"].values():
        L.append(f"| {st['a']} | {st['b']} | {st['games']} | {st['wins']}/{st['losses']}/{st['draws']} | "
                 f"{st['score']} | {st['n_pairs_complete']} | {st['score_rate']} | {st['ci95']} | "
                 f"{st['significance']} | {st['strict_failure_rate_per_game_a']} | "
                 f"{st['strict_failure_rate_per_game_b']} |")
    L += ["", "## Matrix (row score rate vs column)", ""]
    ps = result["players"]
    L.append("| | " + " | ".join(ps) + " |")
    L.append("|---" * (len(ps) + 1) + "|")
    for a in ps:
        cells = []
        for b in ps:
            c = result["matrix"][a].get(b)
            cells.append("-" if a == b else ("" if not c else f"{c['score_rate']}"
                                             f"{'*' if c['significance'] == 'A_BETTER' else ''}"))
        L.append(f"| {a} | " + " | ".join(cells) + " |")
    L += ["", "`*` = row significantly better (95% CI excludes 0.5).", "",
          f"## Non-transitivity: {result['non_transitivity']['verdict']}", ""]
    for c in result["non_transitivity"]["cycles"]:
        L.append(f"- {' -> '.join(c['cycle'])}: {c['status']} (non-significant edges: {c['non_significant_edges']})")
    incomplete = {k: v["pairs_incomplete"] for k, v in result["matchups"].items() if v["pairs_incomplete"]}
    if incomplete:
        L += ["", f"Incomplete pairs excluded from CI: {incomplete}"]
    return "\n".join(L) + "\n"


def write_audit(writer: OutputWriter, audits_dir: Path, audit_id: str, games: List[dict],
                champion: Optional[str], synthetic: bool) -> Dict[str, Any]:
    result = analyze(games, champion)
    meta = {"audit_id": audit_id, "synthetic": synthetic, "n_games": len(games)}
    out = Path(audits_dir) / audit_id
    writer.write_json(out / "AUDIT_RESULT.json", {"meta": meta, "result": result})
    writer.write_text(out / "AUDIT_REPORT.md", render_report(result, meta))
    return result


# ----------------------------------------------------------------------------
# executors
# ----------------------------------------------------------------------------
class LiveMatchExecutor:
    """Placeholder for the future GPU executor. Never loads a model, never
    touches Godot or the GPU lock in this task."""

    def __init__(self, *a, **k):
        pass

    def run(self, plan: dict):
        raise AuditExecutionDisabled(
            "Live audit execution is intentionally not implemented/enabled in this task. "
            "Future protocol: stop marathon at an iteration boundary, acquire the EXISTING GPU lock "
            f"{C.GPU_LOCK_PATH}, generate+play every planned game, release lock, resume marathon.")


def prepare_audit_assets(paths: Paths, src: Optional[ReadOnlySource] = None,
                         snapshot: Optional[LiveSnapshot] = None, n_pairs: int = REGISTRY_DEFAULT_PAIRS,
                         games_per_opponent: int = 16) -> Dict[str, Any]:
    """CPU-only: seed registry + template config + plan (no execution)."""
    src = src or ReadOnlySource()
    snapshot = snapshot or LiveSnapshot(src, paths.marathon_root)
    writer = OutputWriter(paths.output_root, paths.protected_roots)
    obs = observed_seeds(src, paths)
    reg = build_seed_registry(obs, n_pairs=n_pairs)
    cfg = default_config(snapshot.get("CHAMPION_LINEAGE.json"), reg, games_per_opponent)
    plan = build_plan(cfg, reg) if cfg["champion"] else None
    writer.write_json(paths.audits_dir / "seed_registry.json", reg)
    writer.write_json(paths.audits_dir / "audit_config.json", cfg)
    if plan:
        writer.write_json(paths.audits_dir / "AUDIT_PLAN.json", plan)
    return {"registry": reg, "config": cfg, "plan": plan}
