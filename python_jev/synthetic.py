"""Synthetic observation factory for model-shape verification and tests.

This is NOT a battle simulator and NOT a dataset generator: it fabricates
schema-valid tensors directly, with no game rules, no WorldTruth, and no
rollouts. Its only purpose is to exercise the frozen tensor contract and the
untrained policy skeleton deterministically.

WorldTruth is deliberately absent. Where a test needs "differing hidden
truth", it passes differing values through the metadata dict, which the
forward contract never reads.
"""

from __future__ import annotations

import math

import torch

from python_jev.constants import (
    LEARNED_CLASSES,
    NUM_SKILL_SLOTS,
    PATCH_NUM_CELLS,
    PATCH_RADIUS,
    TokenKind,
)
from python_jev.layout import (
    ACTOR_FEATURE_DIM,
    ACTOR_GROUP_OFFSETS,
    CONTACT_MEMORY_HORIZON,
    GLOBAL_FEATURE_DIM,
    GLOBAL_GROUP_OFFSETS,
    HEX_FEATURE_DIM,
    HEX_GROUP_OFFSETS,
    MISSION_FEATURE_DIM,
    MISSION_GROUP_OFFSETS,
    TOKEN_CAPACITY,
    TOKEN_FEATURE_DIM,
    TOKEN_GROUP_OFFSETS,
    ACTOR_MISSION_ROLES,
)
from python_jev.observation import ObservationBatchV0

GEN = "python_jev.synthetic_factory_v0"

_TERRAIN = ("PLAINS", "FOREST", "MOUNTAIN", "WATER", "ROAD", "UNKNOWN")
_READINESS = ("READY", "ACTED", "UNKNOWN")
_BLOCKING = ("PASSABLE", "BLOCKED", "UNKNOWN")
_OCCUPANCY = ("EMPTY", "FRIENDLY", "ENEMY_VISIBLE", "STALE_MARKER", "UNKNOWN")
_VIS = ("VISIBLE", "REMEMBERED", "UNEXPLORED")
_ROUT = ("NONE", "AT_RISK", "ROUTING", "UNKNOWN", "NA")
_STANCE = ("NONE", "HOLD", "SCREEN", "RESERVE", "OTHER", "UNKNOWN", "NA")
_MISSION_TYPES = ("SEEK_BATTLE", "HOLD_GROUND", "CAPTURE", "DEFEND", "RECON", "UNKNOWN")
_OBJECTIVE_TYPES = ("ENEMY_ARMY", "ENEMY_HQ", "HEX_OBJECTIVE", "SURVIVE", "UNKNOWN")
_OBJ_STATUS = ("UNDONE", "IN_PROGRESS", "ACHIEVED", "FAILED", "UNKNOWN")
_PHASES = ("EARLY", "MID", "LATE", "UNKNOWN", "NA")
_BATTLE_PHASES = ("MOVEMENT", "COMBAT", "UNKNOWN", "NA")
_POSSESSION = ("OURS", "ENEMY", "CONTESTED", "UNKNOWN", "NA")


def _onehot(width: int, index: int) -> list[float]:
    v = [0.0] * width
    v[max(0, min(width - 1, index))] = 1.0
    return v


def _cat(name: str, table: tuple[str, ...]) -> int:
    return table.index(name)


def _axial_distance(dq: int, dr: int) -> int:
    ds = -dq - dr
    return (abs(dq) + abs(dr) + abs(ds)) // 2


def _direction_bucket(dq: int, dr: int) -> int:
    if dq == 0 and dr == 0:
        return 6  # center bucket
    angle = math.degrees(math.atan2(dr, dq)) % 360.0
    return int(angle // 60.0) % 6


def _dir_unit(dq: int, dr: int) -> tuple[float, float]:
    d = math.hypot(dq, dr)
    if d == 0.0:
        return (0.0, 0.0)
    return (dq / d, dr / d)


def _patch_offsets() -> list[tuple[int, int]]:
    """All 91 axial offsets within radius 5, actor cell first (deterministic)."""
    cells = [(0, 0)]
    r = PATCH_RADIUS
    for dq in range(-r, r + 1):
        for dr in range(max(-r, -dq - r), min(r, -dq + r) + 1):
            if (dq, dr) == (0, 0):
                continue
            cells.append((dq, dr))
    assert len(cells) == PATCH_NUM_CELLS, (len(cells), PATCH_NUM_CELLS)
    return cells


_PATCH_OFFSETS = _patch_offsets()


def make_observation_batch(
    batch_size: int,
    acting_class: str = "INFANTRY",
    num_friendly: int = 1,
    num_visible_enemies: int = 1,
    num_stale: int = 0,
    seed: int = 0,
    legal_mask: list[int] | None = None,
    worldtruth_metadata: dict[str, str] | None = None,
    device: torch.device | str = "cpu",
) -> ObservationBatchV0:
    """Deterministically fabricate one schema-valid observation batch.

    Token capacity is trimmed to the exact padded count requested, per the
    schema's variable-N semantics; production projectors emit TOKEN_CAPACITY.
    """
    if batch_size < 1:
        raise ValueError("batch_size must be >= 1")
    from python_jev.constants import assert_valid_class

    assert_valid_class(acting_class)
    class_idx = LEARNED_CLASSES.index(acting_class)
    g = torch.Generator(device="cpu").manual_seed(seed)

    # ---------------- tokens ----------------
    n_tokens = num_friendly + num_visible_enemies + num_stale
    if n_tokens > TOKEN_CAPACITY:
        raise ValueError(f"token request {n_tokens} exceeds frozen capacity {TOKEN_CAPACITY}")
    tokens = torch.zeros(batch_size, max(n_tokens, 0), TOKEN_FEATURE_DIM)
    token_pad = torch.ones(batch_size, max(n_tokens, 0), dtype=torch.bool)
    for b in range(batch_size):
        i = 0
        for kind, count in (
            (TokenKind.FRIENDLY, num_friendly),
            (TokenKind.ENEMY_VISIBLE, num_visible_enemies),
            (TokenKind.STALE_CONTACT, num_stale),
        ):
            for _ in range(count):
                dq = int(torch.randint(-5, 6, (1,), generator=g)) - 0
                dr = int(torch.randint(-5, 6, (1,), generator=g))
                dist = _axial_distance(dq, dr)
                bucket = _direction_bucket(dq, dr)
                relation = _onehot(len(TokenKind), int(kind))
                uclass = _onehot(len(LEARNED_CLASSES) + 1, int(torch.randint(0, len(LEARNED_CLASSES) + 1, (1,), generator=g)))
                strength = 0.0 if kind == TokenKind.STALE_CONTACT else float(torch.rand(1, generator=g))
                known = 0.0 if kind == TokenKind.STALE_CONTACT else 1.0
                readiness = _onehot(3, _cat("READY", _READINESS) if kind == TokenKind.FRIENDLY else _cat("UNKNOWN", _READINESS))
                r_known = 1.0 if kind == TokenKind.FRIENDLY else 0.0
                age = (float(torch.rand(1, generator=g)) * CONTACT_MEMORY_HORIZON / CONTACT_MEMORY_HORIZON
                       if kind == TokenKind.STALE_CONTACT else 0.0)
                a_known = 1.0 if kind == TokenKind.STALE_CONTACT else 0.0
                unc = (float(torch.rand(1, generator=g)) * 0.5 + 0.1
                       if kind == TokenKind.STALE_CONTACT else 0.0)
                role_idx = _cat("UNKNOWN", ACTOR_MISSION_ROLES)
                role_known = 0.0
                feats = (
                    relation
                    + uclass
                    + [strength, known]
                    + readiness
                    + [r_known]
                    + [dq / PATCH_RADIUS, dr / PATCH_RADIUS]
                    + [min(1.0, dist / PATCH_RADIUS)]
                    + _onehot(7, bucket)
                    + [age, a_known]
                    + [unc]
                    + _onehot(len(ACTOR_MISSION_ROLES), role_idx)
                    + [role_known]
                )
                tokens[b, i] = torch.tensor(feats)
                token_pad[b, i] = False
                i += 1

    # ---------------- hex patch ----------------
    hex_patch = torch.zeros(batch_size, PATCH_NUM_CELLS, HEX_FEATURE_DIM)
    hex_pad = torch.zeros(batch_size, PATCH_NUM_CELLS, dtype=torch.bool)
    for b in range(batch_size):
        for j, (dq, dr) in enumerate(_PATCH_OFFSETS):
            dist = _axial_distance(dq, dr)
            bucket = _direction_bucket(dq, dr)
            center = (dq == 0 and dr == 0)
            terrain = _onehot(6, _cat("PLAINS", _TERRAIN))
            tcost = 1.0 / 3.0
            t_known = 1.0
            blocking = _onehot(3, _cat("PASSABLE", _BLOCKING))
            occ = _onehot(5, _cat("EMPTY", _OCCUPANCY))
            vis = _onehot(3, _cat("VISIBLE", _VIS))
            feats = (
                [dq / PATCH_RADIUS, dr / PATCH_RADIUS]
                + [min(1.0, dist / PATCH_RADIUS)]
                + _onehot(7, bucket)
                + terrain + [tcost, t_known] + blocking + occ + vis
                + [0.0, 0.0]   # objective marker + known
                + [0.0, 0.0]   # HQ marker + known
            )
            hex_patch[b, j] = torch.tensor(feats)

    # ---------------- actor ----------------
    strength = 0.7 + 0.2 * float(torch.rand(1, generator=g))
    move_rem = float(torch.rand(1, generator=g))
    move_cap = 1.0
    actor = (
        _onehot(len(LEARNED_CLASSES), class_idx)
        + [strength, 1.0]
        + [move_rem, move_cap, 1.0 - move_rem, 1.0, 1.0]
        + [1.0, 1.0]                      # attack_available, attack_known
        + _onehot(3, _cat("READY", _READINESS))
        + [0.8, 1.0, 0.0]                 # morale ratio/known/NA
        + [0.9, 1.0, 0.0]                 # cohesion
        + _onehot(5, _cat("NONE", _ROUT))
        + _onehot(7, _cat("NONE", _STANCE))
        + [0.0, -1.0, 0.5, 1.0]           # objective dir (0,-1), dist 0.5, known
        + [0.0, 1.0, 0.3, 1.0]            # HQ dir/dist/known
        + [0.5, 0.5, 0.5, 0.5, 1.0]       # board edge N/E/S/W + known
        + _onehot(6, _cat("PLAINS", _TERRAIN))
        + [1.0 / 3.0, 1.0]
        + _onehot(3, _cat("PASSABLE", _BLOCKING))
        + _onehot(5, _cat("EMPTY", _OCCUPANCY))
        + _onehot(3, _cat("VISIBLE", _VIS))
    )
    assert len(actor) == ACTOR_FEATURE_DIM, (len(actor), ACTOR_FEATURE_DIM)

    # ---------------- mission ----------------
    mission = (
        _onehot(6, _cat("SEEK_BATTLE", _MISSION_TYPES))
        + _onehot(5, _cat("ENEMY_ARMY", _OBJECTIVE_TYPES))
        + _onehot(5, _cat("IN_PROGRESS", _OBJ_STATUS))
        + [0.0, -1.0, 0.5, 1.0]
        + _onehot(5, _cat("MID", _PHASES))
        + [0.6, 1.0]
        + [0.7, 0.3, 0.5, 0.6, 0.4, 0.8]
        + [1.0] * 6
        + _onehot(len(ACTOR_MISSION_ROLES), _cat("PRIMARY", ACTOR_MISSION_ROLES))
    )
    assert len(mission) == MISSION_FEATURE_DIM, (len(mission), MISSION_FEATURE_DIM)

    # ---------------- global ----------------
    n_friend = float(num_friendly)
    n_enemy = float(num_visible_enemies)
    n_stale_f = float(num_stale)
    global_feats = (
        [0.4]
        + _onehot(4, _cat("MOVEMENT", _BATTLE_PHASES))
        + [min(1.0, n_friend / 16.0), 0.0]
        + [0.8, 0.5, 0.5]
        + [min(1.0, n_enemy / 16.0), 0.0]
        + [0.6]
        + [min(1.0, n_stale_f / 8.0), 0.0]
        + [0.5 if num_stale else 0.0]
        + [1.0, 1.0, 0.0, 0.0]
        + _onehot(5, _cat("CONTESTED", _POSSESSION))
        + [0.3, 1.0]
        + [0.6, 0.8, 0.2, 1.0]
    )
    assert len(global_feats) == GLOBAL_FEATURE_DIM, (len(global_feats), GLOBAL_FEATURE_DIM)

    mask = torch.tensor(
        legal_mask if legal_mask is not None else [1] * NUM_SKILL_SLOTS,
        dtype=torch.bool,
    ).expand(batch_size, NUM_SKILL_SLOTS).contiguous()

    meta = {"generator": GEN}
    if worldtruth_metadata:
        meta.update(worldtruth_metadata)

    return ObservationBatchV0(
        actor_features=torch.tensor(actor, dtype=torch.float32).unsqueeze(0).expand(batch_size, -1).contiguous(),
        tokens=tokens,
        token_padding_mask=token_pad,
        hex_patch=hex_patch,
        hex_padding_mask=hex_pad,
        mission_features=torch.tensor(mission, dtype=torch.float32).unsqueeze(0).expand(batch_size, -1).contiguous(),
        global_features=torch.tensor(global_feats, dtype=torch.float32).unsqueeze(0).expand(batch_size, -1).contiguous(),
        legal_mask=mask,
        acting_class_idx=torch.full((batch_size,), class_idx, dtype=torch.long),
        metadata=meta,
    ).to(device, torch.float32)
