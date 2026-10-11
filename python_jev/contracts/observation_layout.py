"""ObservationLayoutV0 — machine-readable frozen observation layout contract.

Schema revision 1 of obs-v0. This module is the single authority for the
byte-level field orders, categorical vocabularies, unknown/NA semantics,
normalization references, and the deterministic 91-hex index map that the
future Godot projector and Python simulator must both emit byte-for-byte.

Sources (precedence order):
  1. Notion "Production Observation Schema Freeze" (group semantics, masks,
     variable-N, normalization rules, radius-5/91 patch).
  2. Current authoritative Godot rules (terrain enum/costs, class baselines,
     combat stats, fog vision, turn phases — see RulesetV0 for citations).
  3. JevPolicyV0 implementation (python_jev/layout.py feature groups).

`python_jev.layout` remains the executable implementation of THIS manifest;
this module freezes the values machine-readably and pins the twin manifest
(`to_manifest()` / `content_hash()`) that datasets and checkpoints will record.
"""

from __future__ import annotations

import hashlib
import json

from python_jev import layout as impl

# ---------------------------------------------------------------------------
# Versioning
# ---------------------------------------------------------------------------
OBSERVATION_SCHEMA_VERSION = "obs-v0"
OBSERVATION_SCHEMA_REVISION = 1
LAYOUT_CONTRACT_VERSION = "observation-layout-v0.1.0"

# ---------------------------------------------------------------------------
# Frozen normalization reference constants
# ---------------------------------------------------------------------------
# MAX_TRAVERSAL_COST=3.0: Step3Config.TERRAIN_COSTS_STANDARD max non-impassable
#   cost is 3.0 (MOUNTAINS). Walls/stronghold interiors are 99 = impassable and
#   are represented by the blocking vocabulary, never as a cost of 33.0.
MAX_TRAVERSAL_COST = 3.0
# CONTACT_MEMORY_HORIZON=10: adapter-level memory horizon (turns). Godot's fog
#   freezes stale snapshots indefinitely until rediscovery or destruction, so
#   age is clipped at this horizon with age_known semantics intact.
CONTACT_MEMORY_HORIZON = 10.0
# Token count references: DEV default roster (SandboxRules.default_roster) is
#   10 units/side; step2r scenario shells deploy up to 16 formations/side.
FRIENDLY_COUNT_REF = 16.0
ENEMY_VISIBLE_COUNT_REF = 16.0
STALE_CONTACT_COUNT_REF = 8.0
TOKEN_CAPACITY = 24
UNKNOWN_NUMERIC_FILL = 0.0
NUM_DIRECTION_BUCKETS = 7
PATCH_RADIUS = 5
PATCH_NUM_CELLS = 91
LEGAL_MASK_DIM = 6

# ---------------------------------------------------------------------------
# Frozen vocabularies (index = one-hot slot). DO NOT reorder without a schema
# revision bump. GODOT-ALIGNED entries cite the authoritative enum.
# ---------------------------------------------------------------------------
UNIT_CLASS_VOCAB = ("INFANTRY", "SPEARMAN", "CAVALRY", "ARCHER", "SCOUT")
# Godot-aligned extra classes that can occupy world truth but are NOT learned
# actors and are NOT part of the token one-hot (token vocab has UNKNOWN only;
# non-learned classes are encoded as UNKNOWN + class_known=0 to the policy).
GODOT_EXTRA_CLASSES = ("SIEGE", "CONSCRIPT", "HQ", "SUPPLY")

RELATION_VOCAB = ("FRIENDLY", "ENEMY_VISIBLE", "STALE_CONTACT", "PAD")
KNOWLEDGE_STATE_VOCAB = ("VISIBLE", "REMEMBERED", "UNEXPLORED")
OCCUPANCY_VOCAB = ("EMPTY", "FRIENDLY", "ENEMY_VISIBLE", "STALE_MARKER", "UNKNOWN")
TERRAIN_VOCAB = ("PLAINS", "FOREST", "MOUNTAIN", "WATER", "ROAD", "UNKNOWN")
TERRAIN_VOCAB_GODOT_ALIGNED = {
    # obs token -> Godot HexCell.TerrainType ints folded into the bucket
    "PLAINS": (0, 5, 6),        # PLAINS, VILLAGE, ROAD handled separately
    "FOREST": (2,),
    "MOUNTAIN": (1, 13),        # MOUNTAINS, OUTER_MOUNTAIN
    "WATER": (7,),              # RIVER
    "ROAD": (6,),
    "UNKNOWN": (8, 9, 10, 11, 12),  # WALL + stronghold/capital interior/walls
}
# Godot HexCell.TerrainType enum, authoritative (scripts/core/hex_cell.gd).
GODOT_TERRAIN_ENUM = (
    "PLAINS", "MOUNTAINS", "FOREST", "SWAMP", "FORTRESS", "VILLAGE", "ROAD",
    "RIVER", "WALL", "STRONGHOLD_FOOTPRINT", "STRONGHOLD_WALL",
    "CAPITAL_FOOTPRINT", "CAPITAL_WALL", "OUTER_MOUNTAIN",
)

READINESS_VOCAB = ("READY", "ACTED", "UNKNOWN")
ROUT_STATE_VOCAB = ("NONE", "AT_RISK", "ROUTING", "UNKNOWN", "NA")
STANCE_VOCAB = ("NONE", "HOLD", "SCREEN", "RESERVE", "OTHER", "UNKNOWN", "NA")
BLOCKING_VOCAB = ("PASSABLE", "BLOCKED", "UNKNOWN")
MISSION_ROLE_VOCAB = ("PRIMARY", "SUPPORT", "RESERVE", "SCREEN", "RECON", "UNKNOWN", "NA")
MISSION_TYPE_VOCAB = ("SEEK_BATTLE", "HOLD_GROUND", "CAPTURE", "DEFEND", "RECON", "UNKNOWN")
OBJECTIVE_TYPE_VOCAB = ("ENEMY_ARMY", "ENEMY_HQ", "HEX_OBJECTIVE", "SURVIVE", "UNKNOWN")
OBJECTIVE_STATUS_VOCAB = ("UNDONE", "IN_PROGRESS", "ACHIEVED", "FAILED", "UNKNOWN")
MISSION_PHASE_VOCAB = ("EARLY", "MID", "LATE", "UNKNOWN", "NA")
BATTLE_PHASE_VOCAB = ("MOVEMENT", "COMBAT", "UNKNOWN", "NA")
POSSESSION_VOCAB = ("OURS", "ENEMY", "CONTESTED", "UNKNOWN", "NA")
ENGAGEMENT_POLICY_VOCAB = (
    # Doctrine engagement policy. "GREEN_ONLY/ORANGE_ALLOWED/RED_ALLOWED" are
    # Godot march-policy tiers (Step3Config.MarchPolicy) reused as doctrine
    # scalars; the vocabulary below is the observation-facing doctrine knob.
    "FREE_ENGAGEMENT", "PROBE_ONLY", "HOLD_FIRE", "UNKNOWN", "NA",
)

DOCTRINE_SCALAR_NAMES = (
    "aggression", "caution", "cohesion_preservation",
    "initiative", "attrition_tolerance", "objective_priority",
)

# ---------------------------------------------------------------------------
# Frozen feature groups (name, width) — mirror of python_jev/layout.py tables.
# The offsets are computed from these tables in both places.
# ---------------------------------------------------------------------------
TOKEN_FEATURE_GROUPS = impl.TOKEN_FEATURE_GROUPS
HEX_FEATURE_GROUPS = impl.HEX_FEATURE_GROUPS
ACTOR_FEATURE_GROUPS = impl.ACTOR_FEATURE_GROUPS
MISSION_FEATURE_GROUPS = impl.MISSION_FEATURE_GROUPS
GLOBAL_FEATURE_GROUPS = impl.GLOBAL_FEATURE_GROUPS

TOKEN_FEATURE_DIM = impl.TOKEN_FEATURE_DIM
HEX_FEATURE_DIM = impl.HEX_FEATURE_DIM
ACTOR_FEATURE_DIM = impl.ACTOR_FEATURE_DIM
MISSION_FEATURE_DIM = impl.MISSION_FEATURE_DIM
GLOBAL_FEATURE_DIM = impl.GLOBAL_FEATURE_DIM

# ---------------------------------------------------------------------------
# Unknown / NA / stale / absent / padding semantics (frozen encoding rules)
# ---------------------------------------------------------------------------
ENCODING_SEMANTICS = {
    "numeric_unknown": {
        "fill": UNKNOWN_NUMERIC_FILL,
        "known_bit": 0,
        "rule": "unknown numeric uses the neutral fill with known=0; a real zero always has known=1",
    },
    "categorical_unknown": {
        "rule": "dedicated UNKNOWN one-hot bucket inside the categorical group",
    },
    "categorical_not_applicable": {
        "rule": "dedicated NA one-hot bucket for groups that have one; groups "
                "without an NA bucket use UNKNOWN + the field's na_bit when present",
    },
    "stale_value": {
        "rule": "value = last legally retained fact, paired known=1 + stale=1 + age>0; "
                "never rewritten to a current fact",
    },
    "absent": {
        "rule": "no token is emitted at all (token sets are variable-N)",
    },
    "padding": {
        "rule": "padding slots exist only to fill TOKEN_CAPACITY; token_padding_mask=1; "
                "relation one-hot = PAD bucket; padding is never an observation",
    },
    "known_zero": {
        "rule": "faction is authorized to know the value is zero: value=0.0, known=1",
    },
}

# TOKEN_CAPACITY decision (quantitative reasoning, see R0 audit / handoff doc):
# 24 = 16 friendly (production scenario shells deploy up to 16 formations per
# side; DEV default roster is 10) + 8 stale-contact slots (STALE_CONTACT_COUNT_REF).
# Currently-visible enemies share the same token buffer under one relation
# field, so worst-case live entities (24 friendly + 16 visible enemy in a
# worst-case battle) would exceed 24 — the overflow rule then applies: a
# deterministic, non-tactical truncation policy plus the explicit overflow bit
# already present in the global summary group. Keeping a bounded 24-slot
# buffer (rather than an unbounded configurable one) preserves the frozen
# variable-N semantics with a hard, reviewable capacity; enlarging it later is
# a schema revision with a version bump, not a silent change.
TOKEN_CAPACITY_RATIONALE = (
    "24 = 16 friendly (production shells deploy up to 16 formations/side; "
    "DEV default roster 10) + 8 stale-contact slots (STALE_CONTACT_COUNT_REF). "
    "Visible enemies share the buffer with friendlies under one relation "
    "field; a worst-case 16v16 engagement with a full stale ledger exceeds 24 "
    "and triggers the frozen overflow rule (deterministic non-tactical rule + "
    "explicit overflow bit in the global summary), never a hidden-truth "
    "truncation. Raising the bound is a schema revision with a version bump."
)

# ---------------------------------------------------------------------------
# Deterministic 91-hex index map (see hex_patch.py for the freeze rationale)
# ---------------------------------------------------------------------------
HEX_INDEX_MAP = None  # populated lazily by python_jev.contracts.hex_patch

# ---------------------------------------------------------------------------
# Manifest
# ---------------------------------------------------------------------------
def hex_index_map() -> list[list[int]]:
    global HEX_INDEX_MAP
    if HEX_INDEX_MAP is None:
        from python_jev.contracts.hex_patch import hex_index_manifest
        HEX_INDEX_MAP = hex_index_manifest()
    return HEX_INDEX_MAP


def _vocab_block() -> dict:
    return {
        "unit_class": list(UNIT_CLASS_VOCAB),
        "relation_kind": list(RELATION_VOCAB),
        "knowledge_state": list(KNOWLEDGE_STATE_VOCAB),
        "occupancy": list(OCCUPANCY_VOCAB),
        "terrain": list(TERRAIN_VOCAB),
        "readiness": list(READINESS_VOCAB),
        "rout_state": list(ROUT_STATE_VOCAB),
        "stance": list(STANCE_VOCAB),
        "blocking": list(BLOCKING_VOCAB),
        "mission_role": list(MISSION_ROLE_VOCAB),
        "mission_type": list(MISSION_TYPE_VOCAB),
        "objective_type": list(OBJECTIVE_TYPE_VOCAB),
        "objective_status": list(OBJECTIVE_STATUS_VOCAB),
        "mission_phase": list(MISSION_PHASE_VOCAB),
        "battle_phase": list(BATTLE_PHASE_VOCAB),
        "objective_possession": list(POSSESSION_VOCAB),
        "engagement_policy": list(ENGAGEMENT_POLICY_VOCAB),
        "doctrine_scalars": list(DOCTRINE_SCALAR_NAMES),
    }


def _groups_block() -> dict:
    return {
        "actor": {"dim": ACTOR_FEATURE_DIM, "groups": [list(g) for g in ACTOR_FEATURE_GROUPS]},
        "tokens": {"dim": TOKEN_FEATURE_DIM, "groups": [list(g) for g in TOKEN_FEATURE_GROUPS]},
        "hex_patch": {"dim": HEX_FEATURE_DIM, "groups": [list(g) for g in HEX_FEATURE_GROUPS]},
        "mission": {"dim": MISSION_FEATURE_DIM, "groups": [list(g) for g in MISSION_FEATURE_GROUPS]},
        "global": {"dim": GLOBAL_FEATURE_DIM, "groups": [list(g) for g in GLOBAL_FEATURE_GROUPS]},
        "legal_mask": {"dim": LEGAL_MASK_DIM},
    }


def to_manifest() -> dict:
    """Machine-readable ObservationLayoutV0 manifest (JSON-serializable)."""
    return {
        "contract": "ObservationLayoutV0",
        "observation_schema_version": OBSERVATION_SCHEMA_VERSION,
        "observation_schema_revision": OBSERVATION_SCHEMA_REVISION,
        "layout_contract_version": LAYOUT_CONTRACT_VERSION,
        "feature_groups": _groups_block(),
        "vocabularies": _vocab_block(),
        "encoding_semantics": ENCODING_SEMANTICS,
        "mask_pairing": {
            "rule": "every optional numeric value v is emitted as (value, known) pair; "
                    "stale adds a stale bit; NA has its own bit/bucket; the five mask "
                    "families stay separate (field-known, stale, NA, padding, legality)",
            "separate_masks": ["field_known", "stale", "not_applicable", "token_padding", "skill_legality"],
        },
        "normalization": {
            "strength": "soldier_count / max_count clipped to [0,1], known bit preserved",
            "movement": "remaining_mp / base_mp, spent / blue_limit, capacity 1.0",
            "distance": "hex distance / PATCH_RADIUS (5), offsets / PATCH_RADIUS, clipped to [-1,1] / [0,1]",
            "terrain_cost": "cost / MAX_TRAVERSAL_COST (3.0); impassable uses blocking vocab, not cost",
            "contact_age": "age_turns / CONTACT_MEMORY_HORIZON (10.0), clipped",
            "counts": "count / {friendly:16, enemy_visible:16, stale:8} with overflow indicator bit",
            "turn_progress": "turn / mission turn_limit when known, else known=0",
            "rule": "frozen constants only; never batch/profile statistics; never WorldTruth statistics",
        },
        "local_hex_patch": {
            "radius": PATCH_RADIUS,
            "num_cells": PATCH_NUM_CELLS,
            "orientation": "flat-top axial (q,r), s=-q-r; Godot HexUtils.DIRECTIONS order",
            "index_map": hex_index_map(),
            "index_semantics": "slot index carries spatial meaning (frozen coordinate mapping); "
                               "unit token slot index carries NO semantics",
        },
        "capacity_constraints": {
            "token_capacity": TOKEN_CAPACITY,
            "token_capacity_rationale": TOKEN_CAPACITY_RATIONALE,
            "overflow_rule": "deterministic non-tactical rule required by the frozen contract; "
                             "never truncate by hidden distance/strength/score; emit overflow bit",
            "hex_patch": "fixed 91 cells; unknown cells stay present as unknown",
        },
        "permutation_principle": {
            "unit_tokens": "slot order is semantically irrelevant; pooling must be permutation-invariant",
            "hex_patch": "slot order IS spatial identity (frozen index map)",
        },
        "worldtruth_boundary": {
            "rule": "WorldTruth -> FactionKnowledge(side) -> JevObservation; the observation "
                    "tensor contract has no hidden-truth field and no side channel",
        },
    }


MANIFEST = to_manifest()


def content_hash() -> str:
    """Stable SHA-256 over the canonical manifest JSON (sort_keys, compact)."""
    payload = json.dumps(MANIFEST, sort_keys=True, separators=(",", ":"), ensure_ascii=True)
    return hashlib.sha256(payload.encode("utf-8")).hexdigest()


__all__ = [
    "CONTACT_MEMORY_HORIZON",
    "ENCODING_SEMANTICS",
    "FRIENDLY_COUNT_REF",
    "LAYOUT_CONTRACT_VERSION",
    "LEGAL_MASK_DIM",
    "MANIFEST",
    "MAX_TRAVERSAL_COST",
    "OBSERVATION_SCHEMA_REVISION",
    "OBSERVATION_SCHEMA_VERSION",
    "PATCH_NUM_CELLS",
    "PATCH_RADIUS",
    "STALE_CONTACT_COUNT_REF",
    "TOKEN_CAPACITY",
    "TOKEN_CAPACITY_RATIONALE",
    "TOKEN_CAPACITY_RATIONALE",
    "UNIT_CLASS_VOCAB",
    "content_hash",
    "hex_index_map",
    "to_manifest",
]
