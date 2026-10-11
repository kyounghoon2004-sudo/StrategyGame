"""PolicyTargetV0 — frozen soft tactical preference targets (policy-target-v0.1.0).

Derives a SOFT six-way probability target from legal Q[6] so JevPolicyV0
learns tactical preference strength, not only winner identity.

Frozen procedure (per decision state):
  1. keep legal actions only (q_valid_mask)
  2. mean_q = mean(Q_legal); centered_i = Q_i - mean_q
  3. std over legal Q; if std > 1e-6: z = centered/std else z = 0
  4. clip z to [-3, +3]
  5. P_target(i) = softmax(z / temperature), temperature = 1.0
  6. illegal slots: P_target = 0 exactly; legal renormalized to sum to 1

Equal legal Q -> uniform over legal actions. No one-hot collapse.
"""

from __future__ import annotations

import hashlib
import json
import math

POLICY_TARGET_VERSION = "policy-target-v0.1.0"
POLICY_TARGET_TEMPERATURE = 1.0
POLICY_TARGET_STD_EPSILON = 1e-6
POLICY_TARGET_Z_CLIP = 3.0
POLICY_TARGET_NUM_SLOTS = 6


def content_hash() -> str:
    """Pin the frozen target semantics (version + constants + procedure id)."""
    payload = {
        "version": POLICY_TARGET_VERSION,
        "temperature": POLICY_TARGET_TEMPERATURE,
        "std_epsilon": POLICY_TARGET_STD_EPSILON,
        "z_clip": POLICY_TARGET_Z_CLIP,
        "num_slots": POLICY_TARGET_NUM_SLOTS,
        "procedure": "center-by-legal-mean/divide-by-legal-std-or-zero/clip-3/softmax-temp-1",
        "illegal": "probability-exactly-zero",
        "equal_q": "uniform-over-legal",
    }
    return hashlib.sha256(
        json.dumps(payload, sort_keys=True, separators=(",", ":")).encode("utf-8")
    ).hexdigest()


def soft_targets_from_q(
    q_values: list[float | None],
    q_valid_mask: list[bool],
    temperature: float = POLICY_TARGET_TEMPERATURE,
) -> list[float]:
    """Convert Q[6] + validity mask into a soft six-way target distribution.

    Equivalence rule: a slot contributes iff q_valid_mask is true AND its Q
    value is a finite number. All other slots receive exactly 0.0.
    """
    if len(q_values) != POLICY_TARGET_NUM_SLOTS or len(q_valid_mask) != POLICY_TARGET_NUM_SLOTS:
        raise ValueError("q_values and q_valid_mask must both have 6 entries")
    if not (temperature > 0.0) or not math.isfinite(temperature):
        raise ValueError(f"temperature must be positive finite, got {temperature!r}")

    legal_q: dict[int, float] = {}
    for slot in range(POLICY_TARGET_NUM_SLOTS):
        if q_valid_mask[slot]:
            qv = q_values[slot]
            if qv is None or not isinstance(qv, (int, float)) or not math.isfinite(qv):
                raise ValueError(
                    f"slot {slot}: q_valid is True but Q is not finite ({qv!r})"
                )
            legal_q[slot] = float(qv)

    targets = [0.0] * POLICY_TARGET_NUM_SLOTS
    if not legal_q:
        raise ValueError("no legal actions: cannot form a target distribution")

    qs = list(legal_q.values())
    mean_q = sum(qs) / len(qs)
    centered = {s: q - mean_q for s, q in legal_q.items()}
    if len(qs) > 1:
        var = sum((q - mean_q) ** 2 for q in qs) / len(qs)
        std = math.sqrt(max(var, 0.0))
    else:
        std = 0.0

    if std > POLICY_TARGET_STD_EPSILON:
        z = {s: c / std for s, c in centered.items()}
    else:
        z = {s: 0.0 for s in centered}
    z = {s: min(POLICY_TARGET_Z_CLIP, max(-POLICY_TARGET_Z_CLIP, v)) for s, v in z.items()}

    # softmax over legal slots only (temperature frozen at 1.0)
    mx = max(z.values())
    exps = {s: math.exp((v - mx) / temperature) for s, v in z.items()}
    total = sum(exps.values())
    for s, e in exps.items():
        targets[s] = e / total

    # exact renormalization of the legal mass (illegal stays exactly 0.0)
    mass = sum(targets[s] for s in legal_q)
    if mass <= 0.0 or not math.isfinite(mass):
        raise RuntimeError("soft-target legal mass is not positive finite")
    for s in legal_q:
        targets[s] /= mass
    return targets


def validate_targets(targets: list[float], q_valid_mask: list[bool]) -> list[str]:
    """Return human-readable problems (empty == valid)."""
    problems: list[str] = []
    if len(targets) != POLICY_TARGET_NUM_SLOTS or len(q_valid_mask) != POLICY_TARGET_NUM_SLOTS:
        return ["targets and q_valid_mask must both have 6 entries"]
    for s, p in enumerate(targets):
        if not isinstance(p, (int, float)) or not math.isfinite(p):
            problems.append(f"target[{s}] is not finite: {p!r}")
        elif p < 0.0:
            problems.append(f"target[{s}] is negative: {p!r}")
        elif not q_valid_mask[s] and p != 0.0:
            problems.append(f"target[{s}] illegal slot must be exactly 0, got {p!r}")
    legal_mass = sum(p for s, p in enumerate(targets) if q_valid_mask[s])
    if any(q_valid_mask) and not math.isclose(legal_mass, 1.0, rel_tol=1e-6, abs_tol=1e-6):
        problems.append(f"legal target mass must sum to 1, got {legal_mass!r}")
    return problems


__all__ = [
    "POLICY_TARGET_NUM_SLOTS",
    "POLICY_TARGET_STD_EPSILON",
    "POLICY_TARGET_TEMPERATURE",
    "POLICY_TARGET_VERSION",
    "POLICY_TARGET_Z_CLIP",
    "content_hash",
    "soft_targets_from_q",
    "validate_targets",
]
