"""R1 corrected held-out evaluation (Part D).

All models — old seed43 plus the three retrained seeds — are scored on the
SAME corrected v0.2 test shard under mask v0.2.0. Comparing an old model on
the old mask against a new model on the new mask is explicitly forbidden;
the shared shard hash is pinned in the report as proof.
"""

from __future__ import annotations

import torch

from python_jev.retrain.data_v2 import JevFullInfoDatasetV2, collate_jev
from python_jev.retrain.dataset_v2 import load_shard_v2

EPSILON_EXTRA = 0.01


def evaluate_corrected_heldout(models: dict, test_shard: str, device,
                               batch_size: int = 512) -> dict:
    """Offline metrics + epsilon detail for every model on one v0.2 shard."""
    from torch.utils.data import DataLoader

    from python_jev.feasibility.epsilon_audit import epsilon_rates
    from python_jev.training.evaluate import _gather_rows, evaluate_offline

    shard_hash = load_shard_v2(test_shard, verify=True)["shard_hash"]
    report: dict = {"test_shard": test_shard, "shard_hash": shard_hash,
                    "mask": "observation-safe-skill-mask-v0.2.0",
                    "models": {}}
    for name, model in models.items():
        off = evaluate_offline(model, test_shard, device,
                               batch_size=batch_size,
                               dataset_cls=JevFullInfoDatasetV2)
        ds = JevFullInfoDatasetV2(test_shard)
        loader = DataLoader(ds, batch_size=batch_size, shuffle=False,
                            collate_fn=collate_jev)
        rows = _gather_rows(model, loader, device)
        eps = epsilon_rates(rows, epsilons=(0.25, 0.05, 0.02, EPSILON_EXTRA, 0.005))
        report["models"][name] = {
            "aggregate": off["aggregate"],
            "per_class": off.get("per_class", {}),
            "per_profile": off.get("per_profile", {}),
            "epsilon_rates": eps,
        }
    return report


def audit_selected_invalid(model, device, jobs: list[tuple[str, int, str, bool]],
                           mask_fn, max_turns: int = 12,
                           max_states_per_scenario: int = 64) -> dict:
    """Mechanical INVALID rate of masked model selections on replayed states.

    Replays held-out collection states (test scenarios), selects with the
    corrected mask, and trial-executes the selection on a clone. Full-info
    preflight-legal selections must yield INVALID = 0.
    """
    import json as _json

    from python_jev.training.dataset_gen import _eligible_actor_ids
    from python_jev.training.inference import batch_from_projection, select_slot
    from python_jev.training.projection import project_for_training
    from python_jev.training.scenarios import generate_scenario, mission_context_for_side
    from python_sim.observation.projector import ObservationProjector
    from python_sim.policies import SimpleAttackElseAdvancePolicy
    from python_sim.sim.battle import Battle
    from python_sim.skills.context import MissionContext
    from python_sim.skills.registry import execute_skill

    driver = SimpleAttackElseAdvancePolicy()
    total = invalid = partial = skipped = 0
    per_class: dict[str, dict[str, int]] = {}
    for _split, index, profile, ood in jobs:
        scenario = generate_scenario(index, ood=ood)["scenario"]
        battle = Battle(_json.loads(_json.dumps(scenario)), profile,
                        seed=scenario["seed"])
        ctxs = {"blue": MissionContext(**mission_context_for_side(scenario, "blue")),
                "red": MissionContext(**mission_context_for_side(scenario, "red"))}
        projector = ObservationProjector(battle)
        n_states = 0
        for _turn in range(max_turns):
            if battle.evaluate_mission()["mission_status"] != "ongoing":
                break
            blue_ids, red_ids = _eligible_actor_ids(battle)
            for side, ids in (("blue", blue_ids), ("red", red_ids)):
                for actor_id in ids:
                    if n_states >= max_states_per_scenario:
                        break
                    u = battle.world.units.get(actor_id)
                    if u is None or u.soldier_count <= 0 or u.action_ended:
                        continue
                    if battle.evaluate_mission()["mission_status"] != "ongoing":
                        break
                    legal = [bool(x) for x in mask_fn(battle, actor_id, ctxs[side])]
                    if not any(legal):
                        skipped += 1
                        (driver.blue_action if side == "blue" else driver.red_action)(
                            battle, actor_id)
                        continue
                    proj = project_for_training(projector, side, actor_id, ctxs[side])
                    sel = select_slot(model, batch_from_projection(proj, legal), device)
                    slot = int(sel["selected_slot"][0])
                    env = execute_skill(battle.clone(), actor_id,
                                        str(u.unit_class).upper(), slot, ctxs[side])
                    total += 1
                    n_states += 1
                    cell = per_class.setdefault(str(u.unit_class).upper(),
                                                {"total": 0, "invalid": 0})
                    cell["total"] += 1
                    if env.get("status") == "INVALID":
                        invalid += 1
                        cell["invalid"] += 1
                    elif env.get("status") == "PARTIAL":
                        partial += 1
                    (driver.blue_action if side == "blue" else driver.red_action)(
                        battle, actor_id)
                if n_states >= max_states_per_scenario:
                    break
            battle.sim_end_turn()
    return {"states": total, "skipped_all_illegal": skipped,
            "invalid": invalid, "partial": partial,
            "invalid_rate": invalid / max(1, total),
            "partial_rate": partial / max(1, total),
            "per_class": per_class}


__all__ = ["EPSILON_EXTRA", "audit_selected_invalid", "evaluate_corrected_heldout"]
