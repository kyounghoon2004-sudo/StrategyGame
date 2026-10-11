"""ValueTargetV0 — frozen scalar tactical value (value-target-v0.1.0).

Activation of the documented flip point: a frozen coefficient set now exists,
so scalar Q[6] is exported for full-information profiles. Partial-information
profiles remain permanently FORBIDDEN (fog oracle guard unchanged).

Frozen formula (acting-faction-relative, branch-start-relative):

    Q = 16*T + 4*M + 2*O + E

    T in {-1,0,+1}  TerminalOutcomeV0 (terminal.py)
    M in [-1,+1]    MissionProgressV0 branch delta (mission_progress.py)
    O in [-1,+1]    ObjectiveProgressV0 branch delta (objective_progress.py)
    E in [-1,+1]    branch-start casualty exchange (branch_snapshot.py)

No other raw outcome field gets direct weight. In particular these get ZERO
direct weight (documented no-double-counting):
- own_hq_alive / enemy_hq_alive: HQ terminal effects are already in T.
- own_strength_ratio / enemy_visible_strength_ratio: casualty state is in E
  (and these raw ratios are scenario-start-based blue-centric facts, kept for
  traceability only).
- horizon_steps: the horizon is a rollout budget, not reward.

Terminal dominance (exact bounds, verified by test):
    non-terminal: T=0  -> Q in [-7,+7]  (4*M + 2*O + E extremes)
    victory:      T=+1 -> Q in [+9,+23] (16 - 7 floor)
    defeat:       T=-1 -> Q in [-23,-9] (16 - 7 ceiling)
Thus every victory > every non-terminal state > every defeat.

Fog rule (unchanged): Q may be evaluated/exported ONLY for DEV_FLAT_ALL_INFO
and TERRAIN_FULL_INFO. Partial-information Q (a hidden-truth oracle) raises
ValueTargetBlocked and is rejected by the dataset validator.
"""

from __future__ import annotations

import hashlib
import json

from python_sim.rollout.branch_snapshot import casualty_exchange
from python_sim.rollout.mission_progress import (
    mission_delta,
    mission_progress,
    mission_view_from_battle,
)
from python_sim.rollout.objective_progress import (
    objective_delta,
    objective_progress,
    objective_view_from_battle,
)
from python_sim.rollout.terminal import describe_terminal
from python_sim.sim.battle import SCENARIO_PROFILES

VALUE_TARGET_VERSION = "value-target-v0.1.0"

W_TERMINAL = 16.0
W_MISSION = 4.0
W_OBJECTIVE = 2.0
W_EXCHANGE = 1.0

# Exact dominance bounds (see module docstring proof).
NONTERMINAL_MAX = 7.0
NONTERMINAL_MIN = -7.0
VICTORY_MIN = 9.0
DEFEAT_MAX = -9.0

Q_EXPORT_STATUS = {
    "OK": "OK",
    "BLOCKED_NO_VALUE_TARGET_CONTRACT": "BLOCKED_NO_VALUE_TARGET_CONTRACT",
    "FORBIDDEN_PARTIAL_INFORMATION": "FORBIDDEN_PARTIAL_INFORMATION",
}

# Profiles where hidden WorldTruth can differ under an identical observation.
PARTIAL_INFORMATION_PROFILES = {
    name for name, flags in SCENARIO_PROFILES.items()
    if bool(flags.get("fog_stale_contacts", False))
}  # FLAT_FOG, TERRAIN_FOG, MORALE_COMBAT, FULL_PRODUCTION

# Profiles authorized for full-information Q evaluation/export.
FULL_INFORMATION_PROFILES = ("DEV_FLAT_ALL_INFO", "TERRAIN_FULL_INFO")

# Flip point resolved by this contract: a frozen ValueTargetV0 now exists.
VALUE_TARGET_CONTRACT_EXISTS = True


def content_hash() -> str:
    """Stable content hash of the frozen value-target contract."""
    canonical = json.dumps(
        {
            "version": VALUE_TARGET_VERSION,
            "formula": "Q=16*T+4*M+2*O+E",
            "ranges": {"T": [-1, 1], "M": [-1, 1], "O": [-1, 1], "E": [-1, 1]},
            "terminal": "terminal-outcome-v0.1.0",
            "mission": "mission-progress-v0.1.0",
            "objective": "objective-progress-v0.1.0",
            "snapshot": "branch-outcome-snapshot-v0.1.0",
        },
        sort_keys=True,
        separators=(",", ":"),
        ensure_ascii=True,
    )
    return hashlib.sha256(canonical.encode("utf-8")).hexdigest()


class ValueTargetBlocked(RuntimeError):
    """Raised when scalar Q export is attempted against the guard."""


def is_full_information(profile: str) -> bool:
    flags = SCENARIO_PROFILES.get(profile)
    if flags is None:
        raise KeyError(f"unknown profile {profile!r}")
    return not bool(flags.get("fog_stale_contacts", False))


def q_export_status(profile: str) -> str:
    """Canonical guard predicate (V0-14 / J1-16)."""
    if profile in PARTIAL_INFORMATION_PROFILES:
        return Q_EXPORT_STATUS["FORBIDDEN_PARTIAL_INFORMATION"]
    if not VALUE_TARGET_CONTRACT_EXISTS:
        return Q_EXPORT_STATUS["BLOCKED_NO_VALUE_TARGET_CONTRACT"]
    return Q_EXPORT_STATUS["OK"]


def assert_q_export_allowed(profile: str) -> None:
    """Guard call: raises on any forbidden scalar Q export."""
    status = q_export_status(profile)
    if status != Q_EXPORT_STATUS["OK"]:
        raise ValueTargetBlocked(
            f"scalar Q export forbidden for profile {profile!r}: {status} "
            f"(value-target contract version {VALUE_TARGET_VERSION})"
        )


def value_of(t: float, m: float, o: float, e: float) -> float:
    """Pure frozen formula Q = 16*T + 4*M + 2*O + E with range enforcement."""
    t = float(t)
    if t not in (-1.0, 0.0, 1.0):
        raise ValueError(f"T must be in {{-1,0,+1}}, got {t!r}")
    m = max(-1.0, min(1.0, float(m)))
    o = max(-1.0, min(1.0, float(o)))
    e = max(-1.0, min(1.0, float(e)))
    return W_TERMINAL * t + W_MISSION * m + W_OBJECTIVE * o + W_EXCHANGE * e


def derive_branch_terms(snapshot: dict, battle, acting_faction: str | None = None) -> dict:
    """Derive T/M/O/E (+ befores/afters) from a branch-start snapshot + post state.

    Pure function of (snapshot, post-state, faction): same inputs always yield
    identical output bytes (V0-15 determinism).
    """
    faction = str(acting_faction or snapshot["acting_faction"]).lower()
    if faction not in ("blue", "red"):
        raise ValueError(f"acting_faction must be blue|red, got {faction!r}")

    verdict = battle.evaluate_mission()
    term = describe_terminal(verdict["mission_status"], verdict["termination_reason"], faction)

    m_view = mission_view_from_battle(battle)
    p_after = float(mission_progress(m_view, faction))
    p_before = float(snapshot["mission_progress_before"])
    m = float(mission_delta(p_after, p_before))

    o_view = objective_view_from_battle(battle)
    o_after = float(objective_progress(o_view, faction, snapshot["relevant_objective_ids"]))
    o_before = float(snapshot["objective_progress_before"])
    o = float(objective_delta(o_after, o_before))

    cas = casualty_exchange(snapshot, battle, faction)
    q = float(value_of(term["T"], m, o, cas["E"]))

    return {
        "contract_version": VALUE_TARGET_VERSION,
        "contract_hash": content_hash()[:16],
        "acting_faction": faction,
        "T": int(term["T"]),
        "terminal_verdict": term["terminal_verdict"],
        "terminal_reason": term["terminal_reason"],
        "expired": bool(term["expired"]),
        "mission_progress_before": round(p_before, 6),
        "mission_progress_after": round(p_after, 6),
        "M": round(m, 6),
        "objective_progress_before": round(o_before, 6),
        "objective_progress_after": round(o_after, 6),
        "O": round(o, 6),
        "enemy_casualties_since_branch_start": cas["enemy_casualties_since_branch_start"],
        "friendly_casualties_since_branch_start": cas["friendly_casualties_since_branch_start"],
        "enemy_live_at_branch_start": cas["enemy_live_at_branch_start"],
        "friendly_live_at_branch_start": cas["friendly_live_at_branch_start"],
        "enemy_fraction": round(cas["enemy_fraction"], 6),
        "friendly_fraction": round(cas["friendly_fraction"], 6),
        "E": round(cas["E"], 6),
        "scalar_Q": round(q, 6),
    }


def derived_bytes(derived: dict) -> bytes:
    """Canonical bytes of a derived term record (determinism checks)."""
    return json.dumps(derived, sort_keys=True, separators=(",", ":"), ensure_ascii=True).encode("utf-8")


def compute_scalar_q(t: float, m: float, o: float, e: float, profile: str) -> float:
    """Guarded scalar Q: fog profiles raise; full-info profiles compute."""
    assert_q_export_allowed(profile)
    return float(value_of(t, m, o, e))


__all__ = [
    "DEFEAT_MAX",
    "FULL_INFORMATION_PROFILES",
    "NONTERMINAL_MAX",
    "NONTERMINAL_MIN",
    "PARTIAL_INFORMATION_PROFILES",
    "Q_EXPORT_STATUS",
    "VALUE_TARGET_CONTRACT_EXISTS",
    "VALUE_TARGET_VERSION",
    "VICTORY_MIN",
    "W_EXCHANGE",
    "W_MISSION",
    "W_OBJECTIVE",
    "W_TERMINAL",
    "ValueTargetBlocked",
    "assert_q_export_allowed",
    "compute_scalar_q",
    "content_hash",
    "derive_branch_terms",
    "derived_bytes",
    "is_full_information",
    "q_export_status",
    "value_of",
]
