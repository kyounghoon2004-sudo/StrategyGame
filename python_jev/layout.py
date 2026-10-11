"""Frozen feature layouts for the Jev v0 observation tensor contract.

This module is the SCHEMA ADAPTER layer. The Notion "Production Observation
Schema Freeze" freezes the nine top-level observation groups, their semantics,
the mask taxonomy, variable-N handling, and normalization rules. It does not
freeze byte-level field orders or representation capacities; those adapter
decisions are isolated HERE so the rest of the package can consume named
feature groups without inventing game rules ad hoc.

Rules encoded by this module:
  - Every scalar is normalized against a FROZEN reference constant below
    (never batch statistics, never WorldTruth statistics).
  - Categoricals are one-hot with an explicit UNKNOWN / NA bucket.
  - Every optional numeric field carries an explicit known bit; unknown
    numerics use the neutral fill value together with known=0, so a real
    zero and an unknown value are never conflated.
  - Absolute map coordinates never appear; positions are actor-relative
    axial offsets, direction buckets, and bounded distance ratios.
"""

from __future__ import annotations

from python_jev.constants import (
    LEARNED_CLASSES,
    NUM_SKILL_SLOTS,
    PATCH_NUM_CELLS,
    PATCH_RADIUS,
    TokenKind,
)

# --------------------------------------------------------------------------
# Frozen normalization reference constants (adapter-level, versioned).
# These are production reference capacities/horizons, NOT batch statistics.
# Changing any of them is an observation-contract change (schema bump).
# --------------------------------------------------------------------------
MAX_TRAVERSAL_COST = 3.0            # frozen max terrain traversal cost
CONTACT_MEMORY_HORIZON = 10.0       # stale-contact age horizon (turns)
FRIENDLY_COUNT_REF = 16.0           # authorized roster reference capacity
ENEMY_VISIBLE_COUNT_REF = 16.0      # visible-enemy reference capacity
STALE_CONTACT_COUNT_REF = 8.0       # remembered-contact reference capacity
TOKEN_CAPACITY = 24                 # production token buffer capacity
UNKNOWN_NUMERIC_FILL = 0.0          # neutral fill; semantics live in known bits

# Direction buckets: six axial directions + the actor's own center cell.
NUM_DIRECTION_BUCKETS = 7

# Feature-group tables: (group name, width). Offsets are computed, so the
# group order and the derived dims can never drift apart.
FeatureGroup = tuple[str, int]


def _groups_dim(groups: tuple[FeatureGroup, ...]) -> int:
    return sum(width for _, width in groups)


def _group_offsets(groups: tuple[FeatureGroup, ...]) -> dict[str, tuple[int, int]]:
    offsets: dict[str, tuple[int, int]] = {}
    cursor = 0
    for name, width in groups:
        offsets[name] = (cursor, cursor + width)
        cursor += width
    return offsets


# --------------------------------------------------------------------------
# Unit / contact token layout (one shared schema for FRIENDLY,
# ENEMY_VISIBLE and STALE_CONTACT tokens, relation carried as a field).
# --------------------------------------------------------------------------
TOKEN_FEATURE_GROUPS: tuple[FeatureGroup, ...] = (
    ("relation_kind", len(TokenKind)),          # FRIENDLY/ENEMY_VISIBLE/STALE_CONTACT/PAD
    ("unit_class", len(LEARNED_CLASSES) + 1),   # 5 learned classes + UNKNOWN
    ("strength_ratio", 1),                      # normalized strength (0..1)
    ("strength_known", 1),                      # field-known bit
    ("readiness", 3),                           # READY / ACTED / UNKNOWN
    ("readiness_known", 1),
    ("rel_offset_dq_dr", 2),                    # actor-relative axial offset / PATCH_RADIUS
    ("hex_distance_ratio", 1),                  # hex distance / PATCH_RADIUS
    ("direction_bucket", NUM_DIRECTION_BUCKETS),
    ("age_ratio", 1),                           # observation age / CONTACT_MEMORY_HORIZON
    ("age_known", 1),
    ("uncertainty_radius_ratio", 1),            # location uncertainty / PATCH_RADIUS
    ("mission_role", 7),                        # PRIMARY/SUPPORT/RESERVE/SCREEN/RECON/UNKNOWN/NA
    ("mission_role_known", 1),
)
TOKEN_FEATURE_DIM = _groups_dim(TOKEN_FEATURE_GROUPS)
TOKEN_GROUP_OFFSETS = _group_offsets(TOKEN_FEATURE_GROUPS)

# --------------------------------------------------------------------------
# Local hex patch cell layout (radius-5 actor-centered patch, 91 cells).
# --------------------------------------------------------------------------
HEX_FEATURE_GROUPS: tuple[FeatureGroup, ...] = (
    ("rel_offset_dq_dr", 2),
    ("hex_distance_ratio", 1),
    ("direction_bucket", NUM_DIRECTION_BUCKETS),
    ("terrain", 6),                             # PLAINS/FOREST/MOUNTAIN/WATER/ROAD/UNKNOWN
    ("traversal_cost_ratio", 1),                # cost / MAX_TRAVERSAL_COST
    ("traversal_known", 1),
    ("blocking", 3),                            # PASSABLE / BLOCKED / UNKNOWN
    ("occupancy", 5),                           # EMPTY/FRIENDLY/ENEMY_VISIBLE/STALE_MARKER/UNKNOWN
    ("visibility_state", 3),                    # VISIBLE / REMEMBERED / UNEXPLORED
    ("objective_marker", 1),                    # known objective marker present
    ("objective_marker_known", 1),
    ("hq_marker", 1),                           # known HQ marker present
    ("hq_marker_known", 1),
)
HEX_FEATURE_DIM = _groups_dim(HEX_FEATURE_GROUPS)
HEX_GROUP_OFFSETS = _group_offsets(HEX_FEATURE_GROUPS)

# --------------------------------------------------------------------------
# Actor feature layout (own-side facts; actor-relative geometry only).
# --------------------------------------------------------------------------
ACTOR_FEATURE_GROUPS: tuple[FeatureGroup, ...] = (
    ("unit_class", len(LEARNED_CLASSES)),
    ("strength_ratio", 1),
    ("strength_known", 1),
    ("movement_remaining_ratio", 1),
    ("movement_capacity_ratio", 1),
    ("movement_spent_ratio", 1),
    ("movement_available", 1),
    ("movement_known", 1),
    ("attack_available", 1),
    ("attack_known", 1),
    ("readiness", 3),                           # READY / ACTED / UNKNOWN
    ("morale_ratio", 1),
    ("morale_known", 1),
    ("morale_not_applicable", 1),
    ("cohesion_ratio", 1),
    ("cohesion_known", 1),
    ("cohesion_not_applicable", 1),
    ("rout_state", 5),                          # NONE/AT_RISK/ROUTING/UNKNOWN/NA
    ("stance", 7),                              # NONE/HOLD/SCREEN/RESERVE/OTHER/UNKNOWN/NA
    ("objective_dir_x", 1),                     # actor-relative objective direction (unit vector)
    ("objective_dir_y", 1),
    ("objective_distance_ratio", 1),            # distance / PATCH_RADIUS, clipped
    ("objective_known", 1),
    ("hq_dir_x", 1),
    ("hq_dir_y", 1),
    ("hq_distance_ratio", 1),
    ("hq_known", 1),
    ("board_edge_free_nesw", 4),                # free space ratio toward N/E/S/W
    ("board_edge_known", 1),
    ("cell_terrain", 6),
    ("cell_traversal_cost_ratio", 1),
    ("cell_traversal_known", 1),
    ("cell_blocking", 3),
    ("cell_occupancy", 5),
    ("cell_visibility_state", 3),
)
ACTOR_FEATURE_DIM = _groups_dim(ACTOR_FEATURE_GROUPS)
ACTOR_GROUP_OFFSETS = _group_offsets(ACTOR_FEATURE_GROUPS)

# --------------------------------------------------------------------------
# Mission / doctrine layout (typed General intent; no prose enters here).
# --------------------------------------------------------------------------
ACTOR_MISSION_ROLES = ("PRIMARY", "SUPPORT", "RESERVE", "SCREEN", "RECON", "UNKNOWN", "NA")

MISSION_FEATURE_GROUPS: tuple[FeatureGroup, ...] = (
    ("mission_type", 6),                        # SEEK_BATTLE/HOLD_GROUND/CAPTURE/DEFEND/RECON/UNKNOWN
    ("objective_type", 5),                      # ENEMY_ARMY/ENEMY_HQ/HEX_OBJECTIVE/SURVIVE/UNKNOWN
    ("objective_status", 5),                    # UNDONE/IN_PROGRESS/ACHIEVED/FAILED/UNKNOWN
    ("objective_dir_x", 1),
    ("objective_dir_y", 1),
    ("objective_distance_ratio", 1),
    ("objective_known", 1),
    ("mission_phase", 5),                       # EARLY/MID/LATE/UNKNOWN/NA
    ("urgency_ratio", 1),
    ("urgency_known", 1),
    ("doctrine_scalars", 6),                    # aggression/caution/cohesion_preservation/
    #                                            initiative/attrition_tolerance/objective_priority
    ("doctrine_known", 6),
    ("actor_mission_role", len(ACTOR_MISSION_ROLES)),
)
MISSION_FEATURE_DIM = _groups_dim(MISSION_FEATURE_GROUPS)
MISSION_GROUP_OFFSETS = _group_offsets(MISSION_FEATURE_GROUPS)

# --------------------------------------------------------------------------
# Faction-authorized global summary layout (no hidden-roster statistics).
# --------------------------------------------------------------------------
GLOBAL_FEATURE_GROUPS: tuple[FeatureGroup, ...] = (
    ("turn_progress_ratio", 1),
    ("battle_phase", 4),                        # MOVEMENT/COMBAT/UNKNOWN/NA
    ("friendly_count_ratio", 1),                # count / FRIENDLY_COUNT_REF
    ("friendly_count_overflow", 1),
    ("friendly_strength_ratio", 1),
    ("friendly_ready_ratio", 1),
    ("friendly_acted_ratio", 1),
    ("visible_enemy_count_ratio", 1),           # count / ENEMY_VISIBLE_COUNT_REF
    ("visible_enemy_count_overflow", 1),
    ("visible_enemy_strength_ratio", 1),
    ("stale_count_ratio", 1),                   # count / STALE_CONTACT_COUNT_REF
    ("stale_count_overflow", 1),
    ("mean_contact_age_ratio", 1),
    ("own_hq_alive", 1),
    ("own_hq_known", 1),
    ("enemy_hq_alive", 1),                      # only if legally known
    ("enemy_hq_known", 1),
    ("objective_possession", 5),                # OURS/ENEMY/CONTESTED/UNKNOWN/NA
    ("mission_progress_ratio", 1),
    ("mission_progress_known", 1),
    ("coverage_visible_ratio", 1),              # authorized knowledge coverage
    ("coverage_explored_ratio", 1),
    ("coverage_unknown_ratio", 1),
    ("coverage_known", 1),
)
GLOBAL_FEATURE_DIM = _groups_dim(GLOBAL_FEATURE_GROUPS)
GLOBAL_GROUP_OFFSETS = _group_offsets(GLOBAL_FEATURE_GROUPS)

# Legality mask is consumed both as output constraint and, per the frozen
# contract, as input context. It has exactly NUM_SKILL_SLOTS bits.
LEGAL_MASK_DIM = NUM_SKILL_SLOTS

__all__ = [
    "ACTOR_FEATURE_DIM",
    "ACTOR_FEATURE_GROUPS",
    "ACTOR_GROUP_OFFSETS",
    "CONTACT_MEMORY_HORIZON",
    "ENEMY_VISIBLE_COUNT_REF",
    "FRIENDLY_COUNT_REF",
    "GLOBAL_FEATURE_DIM",
    "GLOBAL_FEATURE_GROUPS",
    "GLOBAL_GROUP_OFFSETS",
    "HEX_FEATURE_DIM",
    "HEX_FEATURE_GROUPS",
    "HEX_GROUP_OFFSETS",
    "LEGAL_MASK_DIM",
    "MAX_TRAVERSAL_COST",
    "MISSION_FEATURE_DIM",
    "MISSION_FEATURE_GROUPS",
    "MISSION_GROUP_OFFSETS",
    "PATCH_NUM_CELLS",
    "PATCH_RADIUS",
    "STALE_CONTACT_COUNT_REF",
    "TOKEN_CAPACITY",
    "TOKEN_FEATURE_DIM",
    "TOKEN_FEATURE_GROUPS",
    "TOKEN_GROUP_OFFSETS",
    "UNKNOWN_NUMERIC_FILL",
    "UNKNOWN_NUMERIC_FILL",
]
