"""Part H — continuation-policy sensitivity (continuation-sensitivity-v0.1.0).

Same frozen decision states, same six first skills; only the post-branch
continuation varies (SimpleAttackElseAdvance / RandomLegal / Hold, applied
to BOTH factions for a clean reading). Compares Q ranking, top-action
agreement, Spearman rank correlation, and mean |dQ| — overall, by class,
and by mission. No target changes, no ensembles.
"""

from __future__ import annotations

import json
import math
import os

SENSITIVITY_VERSION = "continuation-sensitivity-v0.1.0"
POLICIES = ("SimpleAttackElseAdvancePolicy", "RandomLegalPolicy", "HoldPolicy")
PAIRS = (("SimpleAttackElseAdvancePolicy", "RandomLegalPolicy"),
         ("SimpleAttackElseAdvancePolicy", "HoldPolicy"),
         ("RandomLegalPolicy", "HoldPolicy"))


def _ranks(values: list[float]) -> list[float]:
    order = sorted(range(len(values)), key=lambda i: values[i])
    ranks = [0.0] * len(values)
    i = 0
    while i < len(order):
        j = i
        while j + 1 < len(order) and values[order[j + 1]] == values[order[i]]:
            j += 1
        avg = (i + j) / 2.0 + 1.0
        for k in range(i, j + 1):
            ranks[order[k]] = avg
        i = j + 1
    return ranks


def _spearman(a: list[float], b: list[float]) -> float:
    n = len(a)
    if n < 2 or len(b) != n:
        return float("nan")
    ra, rb = _ranks(a), _ranks(b)
    ma, mb = sum(ra) / n, sum(rb) / n
    cov = sum((x - ma) * (y - mb) for x, y in zip(ra, rb))
    va = sum((x - ma) ** 2 for x in ra)
    vb = sum((y - mb) ** 2 for y in rb)
    if va <= 0 or vb <= 0:
        return float("nan")
    return cov / math.sqrt(va * vb)


def run_sensitivity(jobs: list[tuple[int, str, bool]], out_path: str,
                    max_states: int = 320, horizon: int = 8,
                    seed: int = 7, max_states_per_scenario: int = 24,
                    mask_fn=None, mask_tag: str = "old",
                    align_model=None, align_device: str = "cpu") -> dict:
    """Replay collection states; evaluate each under all 3 continuations.

    R1 hooks (additive): mask_fn overrides the legality mask inside every
    continuation engine (None keeps the frozen F0 path); align_model scores
    one frozen policy's top-1 selection against each continuation's top-Q
    action on the same states (None skips the alignment pass).
    """
    import json as _json

    from python_jev.training.dataset_gen import _eligible_actor_ids
    from python_jev.training.scenarios import generate_scenario, mission_context_for_side
    from python_sim.policies import SimpleAttackElseAdvancePolicy
    from python_sim.rollout.config import RolloutConfig
    from python_sim.rollout.engine import CounterfactualEngine
    from python_sim.sim.battle import Battle
    from python_sim.skills.context import MissionContext

    engines = {p: CounterfactualEngine(RolloutConfig(
        continuation_policy=p, red_policy=p, horizon_decisions=horizon, seed=seed))
        for p in POLICIES}
    driver = SimpleAttackElseAdvancePolicy()
    rows: list[dict] = []
    states = 0
    align_on = align_model is not None
    if align_on:
        from python_jev.training.inference import batch_from_projection, select_slot
        from python_jev.training.projection import project_for_training
        from python_sim.observation.projector import ObservationProjector
    for index, profile, ood in jobs:
        if states >= max_states:
            break
        n_this = 0
        gen = generate_scenario(index, ood=ood)
        scenario = gen["scenario"]
        mission = str(scenario["mission_contract"]["primary_objective"])
        battle = Battle(_json.loads(_json.dumps(scenario)), profile, seed=scenario["seed"])
        ctxs = {"blue": MissionContext(**mission_context_for_side(scenario, "blue")),
                "red": MissionContext(**mission_context_for_side(scenario, "red"))}
        projector = ObservationProjector(battle) if align_on else None
        for _turn in range(12):
            if (states >= max_states or n_this >= max_states_per_scenario
                    or battle.evaluate_mission()["mission_status"] != "ongoing"):
                break
            blue_ids, red_ids = _eligible_actor_ids(battle)
            for side, ids in (("blue", blue_ids), ("red", red_ids)):
                for actor_id in ids:
                    if states >= max_states or n_this >= max_states_per_scenario:
                        break
                    u = battle.world.units.get(actor_id)
                    if u is None or u.action_ended:
                        continue
                    evs = {p: engines[p].evaluate(battle, actor_id, ctxs[side],
                                                  mask_fn=mask_fn)
                           for p in POLICIES}
                    if not any(evs[POLICIES[0]].legal_mask):
                        (driver.blue_action if side == "blue" else driver.red_action)(
                            battle, actor_id)
                        continue
                    legal = [bool(x) for x in evs[POLICIES[0]].legal_mask]
                    qs = {p: [evs[p].branches[s].outcome_scalar for s in range(6)]
                          for p in POLICIES}
                    row = {
                        "actor_class": str(u.unit_class).upper(),
                        "mission": mission, "profile": profile, "side": side,
                        "legal": legal,
                        **{f"q_{p}": qs[p] for p in POLICIES},
                    }
                    if align_on:
                        proj = project_for_training(projector, side, actor_id, ctxs[side])
                        sel = select_slot(
                            align_model, batch_from_projection(proj, legal),
                            align_device)
                        row["model_sel"] = int(sel["selected_slot"][0])
                    rows.append(row)
                    states += 1
                    n_this += 1
                    (driver.blue_action if side == "blue" else driver.red_action)(battle, actor_id)
            battle.sim_end_turn()

    def compare(sub: list[dict], pa: str, pb: str) -> dict:
        agree = n = 0
        sp: list[float] = []
        dq: list[float] = []
        for r in sub:
            shared = [s for s in range(6) if r["legal"][s]]
            if not shared:
                continue
            n += 1
            qa, qb = r[f"q_{pa}"], r[f"q_{pb}"]
            topa = max(shared, key=lambda s: qa[s])
            topb = max(shared, key=lambda s: qb[s])
            agree += (topa == topb)
            dq.append(sum(abs(qb[s] - qa[s]) for s in shared) / len(shared))
            c = _spearman([qa[s] for s in shared], [qb[s] for s in shared])
            if not math.isnan(c):
                sp.append(c)
        return {"states": n,
                "top_action_agreement": agree / max(1, n),
                "spearman_mean": sum(sp) / len(sp) if sp else None,
                "spearman_n": len(sp),
                "mean_abs_dq": sum(dq) / len(dq) if dq else None}

    report = {"sensitivity_version": SENSITIVITY_VERSION, "states": len(rows),
              "horizon": horizon, "seed": seed, "mask": mask_tag,
              "overall": {f"{a}_vs_{b}": compare(rows, a, b) for a, b in PAIRS},
              "by_class": {}, "by_mission": {}}
    for c in sorted({r["actor_class"] for r in rows}):
        sub = [r for r in rows if r["actor_class"] == c]
        report["by_class"][c] = {f"{a}_vs_{b}": compare(sub, a, b) for a, b in PAIRS}
    for m in sorted({r["mission"] for r in rows}):
        sub = [r for r in rows if r["mission"] == m]
        report["by_mission"][m] = {f"{a}_vs_{b}": compare(sub, a, b) for a, b in PAIRS}
    if align_on:
        report["model_alignment"] = _model_alignment(rows)
        report["rows"] = rows
    os.makedirs(os.path.dirname(os.path.abspath(out_path)), exist_ok=True)
    with open(out_path, "w") as f:
        json.dump(report, f, indent=1, sort_keys=True)
    return report


def _model_alignment(rows: list[dict]) -> dict:
    """Frozen-policy top-1 agreement with each continuation's top-Q action."""
    out: dict[str, dict] = {}
    for p in POLICIES:
        agree = n = 0
        by_class: dict[str, list[int]] = {}
        for r in rows:
            if r.get("model_sel", -1) < 0:
                continue
            shared = [s for s in range(6) if r["legal"][s]]
            if not shared:
                continue
            n += 1
            top = max(shared, key=lambda s: r[f"q_{p}"][s])
            hit = 1 if r["model_sel"] == top else 0
            agree += hit
            by_class.setdefault(r["actor_class"], [0, 0])
            by_class[r["actor_class"]][0] += hit
            by_class[r["actor_class"]][1] += 1
        out[p] = {"states": n, "agreement": agree / max(1, n),
                  "by_class": {c: {"agreement": h / max(1, t), "states": t}
                               for c, (h, t) in sorted(by_class.items())}}
    return out


__all__ = ["PAIRS", "POLICIES", "SENSITIVITY_VERSION", "run_sensitivity"]
