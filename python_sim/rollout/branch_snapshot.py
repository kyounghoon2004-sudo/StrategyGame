"""BranchStartOutcomeSnapshotV0 — frozen counterfactual baseline (branch-outcome-snapshot-v0.1.0).

Counterfactual evaluation must capture a snapshot BEFORE executing the
candidate skill. The six branches of one decision state MUST share the exact
same baseline snapshot (captured once, reused for all six branches).

Snapshot contents (all authoritative, full-information target generation):
- acting faction total live soldiers at branch start
- enemy faction total live soldiers at branch start
- mission progress baseline (faction-relative P_mission at branch start)
- objective progress baseline (faction-relative P_objective at branch start)
- terminal state baseline (verdict / reason / expired / T at branch start)
- mission/objective relevant entity IDs (red formation IDs, Capital IDs)

Casualty exchange (frozen):
    enemy_fraction    = enemy_casualties_since_branch_start
                        / max(enemy_live_soldiers_at_branch_start, 1)
    friendly_fraction = friendly_casualties_since_branch_start
                        / max(friendly_live_soldiers_at_branch_start, 1)
    E = clip(enemy_fraction - friendly_fraction, -1, +1)

Branch-start totals are used — never scenario-start totals, never visible-only
counts. This is FULL-INFORMATION target generation (fog profiles can never
export Q; see ValueTargetV0).
"""

from __future__ import annotations

import hashlib
import json

from python_sim.rollout.mission_progress import mission_progress, mission_view_from_battle
from python_sim.rollout.objective_progress import (
    objective_progress,
    objective_view_from_battle,
    relevant_objective_ids,
)
from python_sim.rollout.terminal import describe_terminal

BRANCH_SNAPSHOT_VERSION = "branch-outcome-snapshot-v0.1.0"


def content_hash() -> str:
    """Stable content hash of the frozen branch-snapshot contract."""
    canonical = json.dumps(
        {
            "version": BRANCH_SNAPSHOT_VERSION,
            "casualty": "E=clip(enemy_frac-friendly_frac,-1,+1) over branch-start live totals",
            "baseline": "captured once before candidate skill; shared by all six branches",
        },
        sort_keys=True,
        separators=(",", ":"),
        ensure_ascii=True,
    )
    return hashlib.sha256(canonical.encode("utf-8")).hexdigest()


def _live_soldiers(battle, faction: str) -> int:
    return sum(
        int(u.soldier_count)
        for u in battle.world.units.values()
        if u.faction == faction and u.soldier_count > 0
    )


def _opponent(faction: str) -> str:
    return "red" if faction == "blue" else "blue"


def capture_branch_start(battle, acting_faction: str) -> dict:
    """Capture the branch-start baseline from the frozen decision state."""
    faction = str(acting_faction).lower()
    if faction not in ("blue", "red"):
        raise ValueError(f"acting_faction must be blue|red, got {acting_faction!r}")
    mission_view = mission_view_from_battle(battle)
    objective_view = objective_view_from_battle(battle)
    relevant_ids = relevant_objective_ids(objective_view)
    verdict = battle.evaluate_mission()
    red_ids = sorted(
        u.id for u in battle.world.units.values() if u.faction == "red" and u.soldier_count > 0
    )
    return {
        "contract_version": BRANCH_SNAPSHOT_VERSION,
        "contract_hash": content_hash()[:16],
        "acting_faction": faction,
        "blue_live_soldiers": int(_live_soldiers(battle, "blue")),
        "red_live_soldiers": int(_live_soldiers(battle, "red")),
        "mission_view": mission_view,
        "mission_progress_before": float(mission_progress(mission_view, faction)),
        "objective_view": objective_view,
        "relevant_objective_ids": list(relevant_ids),
        "objective_progress_before": float(objective_progress(objective_view, faction, relevant_ids)),
        "terminal_before": describe_terminal(
            verdict["mission_status"], verdict["termination_reason"], faction
        ),
        "red_formation_ids": red_ids,
    }


def live_soldiers_now(battle, faction: str) -> int:
    """Current total live soldiers for a faction (full information)."""
    return int(_live_soldiers(battle, str(faction).lower()))


def casualty_exchange(snapshot: dict, battle, acting_faction: str | None = None) -> dict:
    """Derive the branch-relative casualty term E from snapshot + post state."""
    faction = str(acting_faction or snapshot["acting_faction"]).lower()
    foe = _opponent(faction)
    foe_start = int(snapshot[f"{foe}_live_soldiers"])
    friend_start = int(snapshot[f"{faction}_live_soldiers"])
    foe_now = _live_soldiers(battle, foe)
    friend_now = _live_soldiers(battle, faction)
    foe_cas = max(0, foe_start - foe_now)
    friend_cas = max(0, friend_start - friend_now)
    foe_frac = foe_cas / float(max(foe_start, 1))
    friend_frac = friend_cas / float(max(friend_start, 1))
    e = max(-1.0, min(1.0, foe_frac - friend_frac))
    return {
        "enemy_casualties_since_branch_start": int(foe_cas),
        "friendly_casualties_since_branch_start": int(friend_cas),
        "enemy_live_at_branch_start": int(foe_start),
        "friendly_live_at_branch_start": int(friend_start),
        "enemy_live_now": int(foe_now),
        "friendly_live_now": int(friend_now),
        "enemy_fraction": float(foe_frac),
        "friendly_fraction": float(friend_frac),
        "E": float(e),
    }


def snapshot_bytes(snapshot: dict) -> bytes:
    """Canonical bytes of a snapshot (determinism / branch-equality checks)."""
    return json.dumps(snapshot, sort_keys=True, separators=(",", ":"), ensure_ascii=True).encode("utf-8")


__all__ = [
    "BRANCH_SNAPSHOT_VERSION",
    "capture_branch_start",
    "casualty_exchange",
    "content_hash",
    "live_soldiers_now",
    "snapshot_bytes",
]
