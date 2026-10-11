"""Shadow projector: Godot tactical facts -> ObservationBatchV0 tensors.

Mirrors python_sim.observation.projector.ObservationProjector semantics exactly
(same formulas, same fallbacks, same quirks), but consumes authorized Godot
facts instead of a sim Battle. Canonical definitions are IMPORTED, never
duplicated: layout offsets/dims, contract vocabularies, RING_MAJOR_OFFSETS,
terrain costs. Small pure helpers (axial math) are re-implemented and pinned
by cross-tests against the sim versions.

Documented deviations from the sim projector (all contract-pinned):
  D1 legal mask comes from Godot solver options via the slot map (runtime
     truth), not sim preflight.
  D2 enemy strength is unknown (Godot red knows only banded troop_text, no
     max_count); sim uses exact counts.
  D3 coverage explored set is visible UNION stale cells (red keeps no explored
     set); sim reads knowledge.explored.
  D4 out-of-patch rays for board_edge_free use the obs bounds rect; sim uses
     is_playable_hex + cell_data.
  D5 preserved sim quirk: hex visibility_state one-hot index = fog_state int
     directly (0/1/2), which inverts visible/unexplored labels. Training
     distribution parity requires preserving it; see the shadow contract.
"""

from __future__ import annotations

import math

import torch

from python_jev.constants import LEARNED_CLASSES, TokenKind
from python_jev.contracts import observation_layout as contract
from python_jev.contracts.hex_patch import RING_MAJOR_OFFSETS
from python_jev.layout import (
    ACTOR_FEATURE_DIM,
    ACTOR_GROUP_OFFSETS,
    ACTOR_MISSION_ROLES,
    CONTACT_MEMORY_HORIZON,
    ENEMY_VISIBLE_COUNT_REF,
    FRIENDLY_COUNT_REF,
    GLOBAL_FEATURE_DIM,
    GLOBAL_GROUP_OFFSETS,
    HEX_FEATURE_DIM,
    HEX_GROUP_OFFSETS,
    MAX_TRAVERSAL_COST,
    MISSION_FEATURE_DIM,
    MISSION_GROUP_OFFSETS,
    NUM_DIRECTION_BUCKETS,
    PATCH_NUM_CELLS,
    PATCH_RADIUS,
    STALE_CONTACT_COUNT_REF,
    TOKEN_CAPACITY,
    TOKEN_FEATURE_DIM,
    TOKEN_GROUP_OFFSETS,
)
from python_jev.observation import ObservationBatchV0
from python_sim.rules import terrain as terrain_rules
from tools.jev_shadow.missionmap import MissionMap
from tools.jev_shadow.schemas import SchemaMismatch
from tools.jev_shadow.slotmap import SlotMap

# --- canonical vocabulary aliases (contract-owned) ---------------------------
TERRAIN_VOCAB = contract.TERRAIN_VOCAB
READINESS_VOCAB = contract.READINESS_VOCAB
BLOCKING_VOCAB = contract.BLOCKING_VOCAB
OCCUPANCY_VOCAB = contract.OCCUPANCY_VOCAB
VIS_VOCAB = contract.KNOWLEDGE_STATE_VOCAB
ROUT_VOCAB = contract.ROUT_STATE_VOCAB
STANCE_VOCAB = contract.STANCE_VOCAB
MISSION_TYPES = contract.MISSION_TYPE_VOCAB
OBJECTIVE_TYPES = contract.OBJECTIVE_TYPE_VOCAB
OBJ_STATUS = contract.OBJECTIVE_STATUS_VOCAB
PHASES = contract.MISSION_PHASE_VOCAB
BATTLE_PHASES = contract.BATTLE_PHASE_VOCAB
POSSESSION = contract.POSSESSION_VOCAB

# Godot terrain int -> obs bucket. The contract map
# (TERRAIN_VOCAB_GODOT_ALIGNED) is inverted with later entries winning (so 6
# folds to ROAD, matching the sim), plus the sim's SWAMP/FORTRESS folds (ints
# 3/4 -> PLAINS) which the contract table does not list. Pinned by
# cross-test against the sim projector's own fold table.
_GODOT_TERRAIN_TO_OBS: dict[int, str] = {}
for _bucket, _ints in contract.TERRAIN_VOCAB_GODOT_ALIGNED.items():
    for _i in _ints:
        _GODOT_TERRAIN_TO_OBS[int(_i)] = _bucket
_GODOT_TERRAIN_TO_OBS[3] = "PLAINS"  # SWAMP: cost-class fold (sim parity)
_GODOT_TERRAIN_TO_OBS[4] = "PLAINS"  # FORTRESS: cost-class fold (sim parity)

_CLASS_NORM = {
    "infantry": "INFANTRY",
    "spearman": "SPEARMAN", "spearmen": "SPEARMAN", "spear": "SPEARMAN",
    "cavalry": "CAVALRY",
    "archer": "ARCHER", "archers": "ARCHER",
    "scout": "SCOUT", "scouts": "SCOUT",
}


def fold_godot_terrain(terrain_int: int) -> str:
    return _GODOT_TERRAIN_TO_OBS.get(int(terrain_int), "UNKNOWN")


def normalize_class(name: str) -> str | None:
    return _CLASS_NORM.get(str(name).strip().lower())


# --- pure axial helpers (mirror sim; pinned by cross-tests) ------------------
def onehot(width: int, index: int) -> list[float]:
    v = [0.0] * width
    if 0 <= index < width:
        v[index] = 1.0
    return v


def cat(table: tuple[str, ...], name: str) -> int:
    return table.index(name)


def axial_distance(dq: int, dr: int) -> int:
    ds = -dq - dr
    return (abs(dq) + abs(dr) + abs(ds)) // 2


def direction_bucket(dq: int, dr: int) -> int:
    if dq == 0 and dr == 0:
        return NUM_DIRECTION_BUCKETS - 1
    angle = math.degrees(math.atan2(dr, dq)) % 360.0
    return int(angle // 60.0) % 6


def dir_unit(dq: int, dr: int) -> tuple[float, float]:
    d = math.hypot(dq, dr)
    if d == 0.0:
        return (0.0, 0.0)
    return (dq / d, dr / d)


class ShadowProjection:
    """Dense lists in canonical layout order (batch size 1)."""

    def __init__(self, actor_features: list[float], tokens: list[list[float]],
                 token_pad: list[bool], hex_patch: list[list[float]],
                 mission_features: list[float], global_features: list[float],
                 legal_mask: list[bool], acting_class_idx: int,
                 mapping: dict) -> None:
        self.actor_features = actor_features
        self.tokens = tokens
        self.token_padding_mask = token_pad
        self.hex_patch = hex_patch
        self.mission_features = mission_features
        self.global_features = global_features
        self.legal_mask = legal_mask
        self.acting_class_idx = acting_class_idx
        self.mapping = mapping


class ShadowProjector:
    def __init__(self, slot_map: SlotMap, mission_map: MissionMap) -> None:
        self.slot_map = slot_map
        self.mission_map = mission_map

    # ------------------------------------------------------------- main entry
    def project(self, req: dict) -> ShadowProjection:
        actor = req["actor"]
        unit_class = str(req["unit_class"]).strip().upper()
        if unit_class not in LEARNED_CLASSES:
            raise SchemaMismatch(
                f"project: unit_class {unit_class!r} is not learned "
                f"(worker must classify NOT_JEV_ELIGIBLE before projecting)")
        turn = int(req["turn"])
        aq, ar = int(actor["q"]), int(actor["r"])
        bounds = req["ctx"]["bounds"]

        built = self.mission_map.build_context(req)
        mc = built["mission_context"]
        mapping = built["provenance"]

        # ---- token sets (authorized facts only) ---------------------------
        own = sorted(
            (u for u in req["friendlies"]
             if int(u["soldiers"]) > 0 and str(u["status"]) != "garrisoned"),
            key=lambda u: str(u["unit_id"]))
        visible = sorted(req["enemies_visible"], key=lambda u: str(u["unit_id"]))
        stale = sorted(req["stale"], key=lambda u: str(u["unit_id"]))

        tokens: list[list[float]] = []
        token_pad: list[bool] = []
        overflow = False

        def write_geometry(feats: list[float], dq: int, dr: int) -> None:
            dist = axial_distance(dq, dr)
            bucket = direction_bucket(dq, dr)
            offsets = TOKEN_GROUP_OFFSETS if len(feats) == TOKEN_FEATURE_DIM \
                else HEX_GROUP_OFFSETS
            o0 = offsets["rel_offset_dq_dr"][0]
            feats[o0] = dq / PATCH_RADIUS
            feats[o0 + 1] = dr / PATCH_RADIUS
            feats[offsets["hex_distance_ratio"][0]] = min(1.0, dist / PATCH_RADIUS)
            d0 = offsets["direction_bucket"][0]
            feats[d0:d0 + NUM_DIRECTION_BUCKETS] = onehot(NUM_DIRECTION_BUCKETS, bucket)

        def emit_friendly(u: dict) -> None:
            feats = [0.0] * TOKEN_FEATURE_DIM
            feats[TOKEN_GROUP_OFFSETS["relation_kind"][0] + int(TokenKind.FRIENDLY)] = 1.0
            cls = normalize_class(u.get("class", ""))
            cls_idx = LEARNED_CLASSES.index(cls) if cls in LEARNED_CLASSES \
                else len(LEARNED_CLASSES)
            feats[TOKEN_GROUP_OFFSETS["unit_class"][0] + cls_idx] = 1.0
            sc = int(u["soldiers"])
            ratio = min(1.0, sc / max(1, int(u["max_count"])))
            o0 = TOKEN_GROUP_OFFSETS["strength_ratio"][0]
            feats[o0], feats[o0 + 1] = ratio, 1.0
            acted = bool(u["has_acted"]) or str(u["status"]) == "routed"
            r0 = TOKEN_GROUP_OFFSETS["readiness"][0]
            feats[r0:r0 + 3] = onehot(3, cat(READINESS_VOCAB, "ACTED" if acted else "READY"))
            feats[TOKEN_GROUP_OFFSETS["readiness_known"][0]] = 1.0
            write_geometry(feats, int(u["q"]) - aq, int(u["r"]) - ar)
            a0 = TOKEN_GROUP_OFFSETS["age_ratio"][0]
            feats[a0], feats[a0 + 1] = 0.0, 0.0  # sim quirk: fresh age, known=0
            feats[TOKEN_GROUP_OFFSETS["uncertainty_radius_ratio"][0]] = 0.0
            m0 = TOKEN_GROUP_OFFSETS["mission_role"][0]
            feats[m0:m0 + len(ACTOR_MISSION_ROLES)] = onehot(
                len(ACTOR_MISSION_ROLES), cat(ACTOR_MISSION_ROLES, "UNKNOWN"))
            feats[TOKEN_GROUP_OFFSETS["mission_role_known"][0]] = 0.0
            tokens.append(feats)
            token_pad.append(False)

        def emit_enemy(u: dict) -> None:
            feats = [0.0] * TOKEN_FEATURE_DIM
            feats[TOKEN_GROUP_OFFSETS["relation_kind"][0] + int(TokenKind.ENEMY_VISIBLE)] = 1.0
            cls = normalize_class(u.get("class", ""))
            cls_idx = LEARNED_CLASSES.index(cls) if cls in LEARNED_CLASSES \
                else len(LEARNED_CLASSES)
            feats[TOKEN_GROUP_OFFSETS["unit_class"][0] + cls_idx] = 1.0
            # D2: strength unknown (banded troop_text only, no max_count).
            s0 = TOKEN_GROUP_OFFSETS["strength_ratio"][0]
            feats[s0], feats[s0 + 1] = 0.0, 0.0
            r0 = TOKEN_GROUP_OFFSETS["readiness"][0]
            feats[r0:r0 + 3] = onehot(3, cat(READINESS_VOCAB, "UNKNOWN"))
            feats[TOKEN_GROUP_OFFSETS["readiness_known"][0]] = 0.0
            write_geometry(feats, int(u["q"]) - aq, int(u["r"]) - ar)
            a0 = TOKEN_GROUP_OFFSETS["age_ratio"][0]
            feats[a0], feats[a0 + 1] = 0.0, 0.0
            feats[TOKEN_GROUP_OFFSETS["uncertainty_radius_ratio"][0]] = 0.0
            m0 = TOKEN_GROUP_OFFSETS["mission_role"][0]
            feats[m0:m0 + len(ACTOR_MISSION_ROLES)] = onehot(
                len(ACTOR_MISSION_ROLES), cat(ACTOR_MISSION_ROLES, "UNKNOWN"))
            feats[TOKEN_GROUP_OFFSETS["mission_role_known"][0]] = 0.0
            tokens.append(feats)
            token_pad.append(False)

        def emit_stale(s: dict) -> None:
            feats = [0.0] * TOKEN_FEATURE_DIM
            feats[TOKEN_GROUP_OFFSETS["relation_kind"][0] + int(TokenKind.STALE_CONTACT)] = 1.0
            cls = normalize_class(s.get("class", ""))
            cls_idx = LEARNED_CLASSES.index(cls) if cls in LEARNED_CLASSES \
                else len(LEARNED_CLASSES)
            feats[TOKEN_GROUP_OFFSETS["unit_class"][0] + cls_idx] = 1.0
            s0 = TOKEN_GROUP_OFFSETS["strength_ratio"][0]
            feats[s0], feats[s0 + 1] = 0.0, 0.0  # red has no combat-assessed approx
            r0 = TOKEN_GROUP_OFFSETS["readiness"][0]
            feats[r0:r0 + 3] = onehot(3, cat(READINESS_VOCAB, "UNKNOWN"))
            feats[TOKEN_GROUP_OFFSETS["readiness_known"][0]] = 0.0
            dq, dr = int(s["q"]) - aq, int(s["r"]) - ar
            write_geometry(feats, dq, dr)
            age = float(turn - int(s["last_seen_turn"]))
            a0 = TOKEN_GROUP_OFFSETS["age_ratio"][0]
            feats[a0] = min(1.0, max(0.0, age / CONTACT_MEMORY_HORIZON))
            feats[a0 + 1] = 1.0
            dist = axial_distance(dq, dr)
            feats[TOKEN_GROUP_OFFSETS["uncertainty_radius_ratio"][0]] = \
                min(1.0, 0.5 * (dist / PATCH_RADIUS) + 0.1)
            m0 = TOKEN_GROUP_OFFSETS["mission_role"][0]
            feats[m0:m0 + len(ACTOR_MISSION_ROLES)] = onehot(
                len(ACTOR_MISSION_ROLES), cat(ACTOR_MISSION_ROLES, "UNKNOWN"))
            feats[TOKEN_GROUP_OFFSETS["mission_role_known"][0]] = 0.0
            tokens.append(feats)
            token_pad.append(False)

        for u in own:
            if len(tokens) >= TOKEN_CAPACITY:
                overflow = True
                break
            emit_friendly(u)
        for u in visible:
            if len(tokens) >= TOKEN_CAPACITY:
                overflow = True
                break
            emit_enemy(u)
        for s in stale:
            if len(tokens) >= TOKEN_CAPACITY:
                overflow = True
                break
            emit_stale(s)
        while len(tokens) < TOKEN_CAPACITY:
            feats = [0.0] * TOKEN_FEATURE_DIM
            feats[TOKEN_GROUP_OFFSETS["relation_kind"][0] + int(TokenKind.PAD)] = 1.0
            tokens.append(feats)
            token_pad.append(True)

        # ---- hex patch ----------------------------------------------------
        cells = {(int(c["q"]), int(c["r"])): c for c in req["hex_cells"]}
        want = {(aq + dq, ar + dr) for dq, dr in RING_MAJOR_OFFSETS}
        if set(cells) != want:
            raise SchemaMismatch(
                f"hex_cells: must cover exactly the actor radius-5 diamond "
                f"(91 cells); missing={sorted(want - set(cells))[:4]} "
                f"extra={sorted(set(cells) - want)[:4]}")
        red_visible = set(req["red_visible_cells"])
        stale_cells = {f"{int(s['q'])},{int(s['r'])}" for s in stale}
        explored = set(red_visible) | stale_cells  # D3 lower bound
        obj_hex = req.get("objective_hex")
        obj_key = f"{obj_hex[0]},{obj_hex[1]}" if obj_hex else None
        hq_pos = req.get("hq_pos")
        hq_key = f"{hq_pos[0]},{hq_pos[1]}" if hq_pos else None
        friendly_at = {f"{int(u['q'])},{int(u['r'])}" for u in own}
        enemy_at = {f"{int(u['q'])},{int(u['r'])}" for u in visible}
        actor_cls_lower = str(actor["unit_class"]).strip().lower()

        hex_patch: list[list[float]] = []
        for dq, dr in RING_MAJOR_OFFSETS:
            feats = [0.0] * HEX_FEATURE_DIM
            write_geometry(feats, dq, dr)
            cq, cr = aq + dq, ar + dr
            key = f"{cq},{cr}"
            cell = cells[(cq, cr)]
            in_bounds = bool(cell["in_bounds"])
            if in_bounds:
                terrain_int = int(cell["terrain"])
                obs_terrain = fold_godot_terrain(terrain_int)
                cost = terrain_rules.get_terrain_cost(terrain_int, actor_cls_lower)
                impassable = terrain_int in (8, 9, 10) or terrain_int >= 99
            else:
                obs_terrain = "UNKNOWN"
                cost = 1.0
                impassable = True
            t0 = HEX_GROUP_OFFSETS["terrain"][0]
            feats[t0:t0 + 6] = onehot(6, cat(TERRAIN_VOCAB, obs_terrain))
            c0 = HEX_GROUP_OFFSETS["traversal_cost_ratio"][0]
            feats[c0] = min(1.0, (99.0 if impassable else cost) / MAX_TRAVERSAL_COST
                             if not impassable else 1.0)
            feats[c0 + 1] = 1.0 if in_bounds else 0.0
            b0 = HEX_GROUP_OFFSETS["blocking"][0]
            feats[b0:b0 + 3] = onehot(
                3, cat(BLOCKING_VOCAB, "BLOCKED" if impassable else "PASSABLE")) \
                if in_bounds else onehot(3, cat(BLOCKING_VOCAB, "UNKNOWN"))
            if not in_bounds:
                occ = "UNKNOWN"
            elif key in friendly_at:
                occ = "FRIENDLY"
            elif key in enemy_at:
                occ = "ENEMY_VISIBLE"
            elif key in stale_cells:
                occ = "STALE_MARKER"
            else:
                occ = "EMPTY"  # hidden enemies never leak as occupancy
            o0 = HEX_GROUP_OFFSETS["occupancy"][0]
            feats[o0:o0 + 5] = onehot(5, cat(OCCUPANCY_VOCAB, occ))
            # D5: fog_state int used DIRECTLY as the one-hot index (sim quirk).
            if not in_bounds:
                fog_idx = 0
            elif key in red_visible:
                fog_idx = 2
            elif key in explored or (obj_key is not None and key == obj_key):
                fog_idx = 1
            else:
                fog_idx = 0
            v0 = HEX_GROUP_OFFSETS["visibility_state"][0]
            feats[v0:v0 + 3] = onehot(3, fog_idx)
            feats[HEX_GROUP_OFFSETS["objective_marker"][0]] = \
                1.0 if (obj_key is not None and key == obj_key) else 0.0
            feats[HEX_GROUP_OFFSETS["objective_marker_known"][0]] = \
                1.0 if in_bounds else 0.0
            feats[HEX_GROUP_OFFSETS["hq_marker"][0]] = \
                1.0 if (hq_key is not None and key == hq_key) else 0.0
            feats[HEX_GROUP_OFFSETS["hq_marker_known"][0]] = 1.0 if in_bounds else 0.0
            hex_patch.append(feats)

        # ---- actor ----------------------------------------------------------
        actor_feats = [0.0] * ACTOR_FEATURE_DIM
        class_idx = LEARNED_CLASSES.index(unit_class)
        o0 = ACTOR_GROUP_OFFSETS["unit_class"][0]
        actor_feats[o0:o0 + len(LEARNED_CLASSES)] = onehot(len(LEARNED_CLASSES), class_idx)
        s_ratio = min(1.0, int(actor["soldiers"]) / max(1, int(actor["max_count"])))
        actor_feats[ACTOR_GROUP_OFFSETS["strength_ratio"][0]] = s_ratio
        actor_feats[ACTOR_GROUP_OFFSETS["strength_known"][0]] = 1.0
        base_mp = float(actor["base_mp"]) if float(actor["base_mp"]) > 0 else 1.0
        actor_feats[ACTOR_GROUP_OFFSETS["movement_remaining_ratio"][0]] = \
            min(1.0, max(0.0, float(actor["remaining_mp"]) / base_mp))
        actor_feats[ACTOR_GROUP_OFFSETS["movement_capacity_ratio"][0]] = 1.0
        actor_feats[ACTOR_GROUP_OFFSETS["movement_spent_ratio"][0]] = \
            min(1.0, float(actor["turn_move_cost_spent"]) / max(1e-9, float(actor["blue_limit"])))
        actor_feats[ACTOR_GROUP_OFFSETS["movement_available"][0]] = \
            1.0 if not bool(actor["action_ended"]) else 0.0
        actor_feats[ACTOR_GROUP_OFFSETS["movement_known"][0]] = 1.0
        actor_feats[ACTOR_GROUP_OFFSETS["attack_available"][0]] = \
            0.0 if (bool(actor["has_attacked"]) or bool(actor["action_ended"])) else 1.0
        actor_feats[ACTOR_GROUP_OFFSETS["attack_known"][0]] = 1.0
        rd0 = ACTOR_GROUP_OFFSETS["readiness"][0]
        actor_feats[rd0:rd0 + 3] = onehot(
            3, cat(READINESS_VOCAB, "ACTED" if bool(actor["action_ended"]) else "READY"))
        actor_feats[ACTOR_GROUP_OFFSETS["morale_ratio"][0]] = \
            min(1.0, float(actor["morale"]) / 100.0)
        actor_feats[ACTOR_GROUP_OFFSETS["morale_known"][0]] = 1.0
        actor_feats[ACTOR_GROUP_OFFSETS["morale_not_applicable"][0]] = 0.0
        actor_feats[ACTOR_GROUP_OFFSETS["cohesion_ratio"][0]] = 0.0
        actor_feats[ACTOR_GROUP_OFFSETS["cohesion_known"][0]] = 0.0
        actor_feats[ACTOR_GROUP_OFFSETS["cohesion_not_applicable"][0]] = 1.0
        r0 = ACTOR_GROUP_OFFSETS["rout_state"][0]
        actor_feats[r0:r0 + 5] = onehot(
            5, cat(ROUT_VOCAB, "ROUTING" if bool(actor["routed"]) else "NONE"))
        st0 = ACTOR_GROUP_OFFSETS["stance"][0]
        stance = "HOLD" if (bool(actor["defense_ready"]) and bool(actor["action_ended"])) else "NONE"
        actor_feats[st0:st0 + 7] = onehot(7, cat(STANCE_VOCAB, stance))
        obj_dir, obj_dist, obj_known = self._objective_vector(req, aq, ar)
        dx, dy = dir_unit(obj_dir[0], obj_dir[1])
        actor_feats[ACTOR_GROUP_OFFSETS["objective_dir_x"][0]] = dx
        actor_feats[ACTOR_GROUP_OFFSETS["objective_dir_y"][0]] = dy
        actor_feats[ACTOR_GROUP_OFFSETS["objective_distance_ratio"][0]] = \
            min(1.0, obj_dist / PATCH_RADIUS)
        actor_feats[ACTOR_GROUP_OFFSETS["objective_known"][0]] = 1.0 if obj_known else 0.0
        hq_dir, hq_dist, hq_known = self._hq_vector(req, aq, ar)
        hx, hy = dir_unit(hq_dir[0], hq_dir[1])
        actor_feats[ACTOR_GROUP_OFFSETS["hq_dir_x"][0]] = hx
        actor_feats[ACTOR_GROUP_OFFSETS["hq_dir_y"][0]] = hy
        actor_feats[ACTOR_GROUP_OFFSETS["hq_distance_ratio"][0]] = \
            min(1.0, hq_dist / PATCH_RADIUS)
        actor_feats[ACTOR_GROUP_OFFSETS["hq_known"][0]] = 1.0 if hq_known else 0.0
        free = self._board_edge_free(aq, ar, bounds)
        be0 = ACTOR_GROUP_OFFSETS["board_edge_free_nesw"][0]
        actor_feats[be0:be0 + 4] = free
        actor_feats[ACTOR_GROUP_OFFSETS["board_edge_known"][0]] = 1.0
        own_cell = cells[(aq, ar)]
        if bool(own_cell["in_bounds"]):
            own_obs = fold_godot_terrain(int(own_cell["terrain"]))
            own_cost = terrain_rules.get_terrain_cost(int(own_cell["terrain"]), actor_cls_lower)
        else:  # unreachable in practice (actors stand in-bounds); mirror sim shape
            own_obs, own_cost = "UNKNOWN", 1.0
        ct0 = ACTOR_GROUP_OFFSETS["cell_terrain"][0]
        actor_feats[ct0:ct0 + 6] = onehot(6, cat(TERRAIN_VOCAB, own_obs))
        actor_feats[ACTOR_GROUP_OFFSETS["cell_traversal_cost_ratio"][0]] = \
            min(1.0, own_cost / MAX_TRAVERSAL_COST)
        actor_feats[ACTOR_GROUP_OFFSETS["cell_traversal_known"][0]] = \
            1.0 if bool(own_cell["in_bounds"]) else 0.0
        cb0 = ACTOR_GROUP_OFFSETS["cell_blocking"][0]
        actor_feats[cb0:cb0 + 3] = onehot(
            3, cat(BLOCKING_VOCAB, "PASSABLE" if bool(own_cell["in_bounds"]) else "UNKNOWN"))
        co0 = ACTOR_GROUP_OFFSETS["cell_occupancy"][0]
        actor_feats[co0:co0 + 5] = onehot(5, cat(OCCUPANCY_VOCAB, "FRIENDLY"))
        cv0 = ACTOR_GROUP_OFFSETS["cell_visibility_state"][0]
        actor_feats[cv0:cv0 + 3] = onehot(3, cat(VIS_VOCAB, "VISIBLE"))

        # ---- mission (same code shape as the sim projector) -----------------
        mission_feats = [0.0] * MISSION_FEATURE_DIM
        mission_feats[MISSION_GROUP_OFFSETS["mission_type"][0]:
                      MISSION_GROUP_OFFSETS["mission_type"][0] + 6] = onehot(
            6, cat(MISSION_TYPES, str(mc.get("mission_type", "SEEK_BATTLE"))))
        mission_feats[MISSION_GROUP_OFFSETS["objective_type"][0]:
                      MISSION_GROUP_OFFSETS["objective_type"][0] + 5] = onehot(
            5, cat(OBJECTIVE_TYPES, str(mc.get("objective_type", "ENEMY_ARMY"))))
        mission_feats[MISSION_GROUP_OFFSETS["objective_status"][0]:
                      MISSION_GROUP_OFFSETS["objective_status"][0] + 5] = onehot(
            5, cat(OBJ_STATUS, str(mc.get("objective_status", "IN_PROGRESS"))))
        m_obj_dir = mc.get("objective_dir", obj_dir)
        m_dx, m_dy = dir_unit(int(m_obj_dir[0]), int(m_obj_dir[1]))
        mission_feats[MISSION_GROUP_OFFSETS["objective_dir_x"][0]] = m_dx
        mission_feats[MISSION_GROUP_OFFSETS["objective_dir_y"][0]] = m_dy
        mission_feats[MISSION_GROUP_OFFSETS["objective_distance_ratio"][0]] = \
            min(1.0, float(mc.get("objective_distance", obj_dist)) / PATCH_RADIUS)
        mission_feats[MISSION_GROUP_OFFSETS["objective_known"][0]] = \
            1.0 if mc.get("objective_known", obj_known) else 0.0
        mission_feats[MISSION_GROUP_OFFSETS["mission_phase"][0]:
                      MISSION_GROUP_OFFSETS["mission_phase"][0] + 5] = onehot(
            5, cat(PHASES, str(mc.get("mission_phase", "EARLY"))))
        mission_feats[MISSION_GROUP_OFFSETS["urgency_ratio"][0]] = float(mc.get("urgency", 0.5))
        mission_feats[MISSION_GROUP_OFFSETS["urgency_known"][0]] = \
            1.0 if mc.get("urgency_known", True) else 0.0
        doctrine = mc.get("doctrine", {})
        d0 = MISSION_GROUP_OFFSETS["doctrine_scalars"][0]
        for i, name in enumerate(("aggression", "caution", "cohesion_preservation",
                                 "initiative", "attrition_tolerance", "objective_priority")):
            mission_feats[d0 + i] = float(doctrine.get(name, 0.5))
        dk0 = MISSION_GROUP_OFFSETS["doctrine_known"][0]
        for i, name in enumerate(("aggression", "caution", "cohesion_preservation",
                                 "initiative", "attrition_tolerance", "objective_priority")):
            mission_feats[dk0 + i] = 1.0 if name in doctrine else 0.0
        role = str(mc.get("actor_mission_role", "PRIMARY"))
        a0m = MISSION_GROUP_OFFSETS["actor_mission_role"][0]
        mission_feats[a0m:a0m + len(ACTOR_MISSION_ROLES)] = onehot(
            len(ACTOR_MISSION_ROLES),
            cat(ACTOR_MISSION_ROLES, role if role in ACTOR_MISSION_ROLES else "UNKNOWN"))

        # ---- global summary (same code shape as the sim projector) ----------
        glob = [0.0] * GLOBAL_FEATURE_DIM
        turn_limit = int(req["turn_limit"])
        if turn_limit > 0:
            glob[GLOBAL_GROUP_OFFSETS["turn_progress_ratio"][0]] = \
                min(1.0, turn / turn_limit)
        glob[GLOBAL_GROUP_OFFSETS["battle_phase"][0]:
             GLOBAL_GROUP_OFFSETS["battle_phase"][0] + 4] = onehot(4, cat(BATTLE_PHASES, "MOVEMENT"))
        n_own = len(own)
        n_enemy = len(visible)
        n_stale = len(stale)
        glob[GLOBAL_GROUP_OFFSETS["friendly_count_ratio"][0]] = \
            min(1.0, n_own / FRIENDLY_COUNT_REF)
        glob[GLOBAL_GROUP_OFFSETS["friendly_count_overflow"][0]] = \
            1.0 if n_own > FRIENDLY_COUNT_REF else 0.0
        own_strength = sum(min(1.0, int(u["soldiers"]) / max(1, int(u["max_count"])))
                           for u in own)
        glob[GLOBAL_GROUP_OFFSETS["friendly_strength_ratio"][0]] = \
            own_strength / max(1.0, float(n_own))
        ready = sum(1 for u in own if not bool(u["has_acted"]))
        glob[GLOBAL_GROUP_OFFSETS["friendly_ready_ratio"][0]] = ready / max(1.0, float(n_own))
        glob[GLOBAL_GROUP_OFFSETS["friendly_acted_ratio"][0]] = \
            (n_own - ready) / max(1.0, float(n_own))
        glob[GLOBAL_GROUP_OFFSETS["visible_enemy_count_ratio"][0]] = \
            min(1.0, n_enemy / ENEMY_VISIBLE_COUNT_REF)
        glob[GLOBAL_GROUP_OFFSETS["visible_enemy_count_overflow"][0]] = \
            1.0 if n_enemy > ENEMY_VISIBLE_COUNT_REF else 0.0
        glob[GLOBAL_GROUP_OFFSETS["visible_enemy_strength_ratio"][0]] = 0.0  # D2
        glob[GLOBAL_GROUP_OFFSETS["stale_count_ratio"][0]] = \
            min(1.0, n_stale / STALE_CONTACT_COUNT_REF)
        glob[GLOBAL_GROUP_OFFSETS["stale_count_overflow"][0]] = \
            1.0 if n_stale > STALE_CONTACT_COUNT_REF else 0.0
        if n_stale:
            mean_age = sum(turn - int(s["last_seen_turn"]) for s in stale) / n_stale
            glob[GLOBAL_GROUP_OFFSETS["mean_contact_age_ratio"][0]] = \
                min(1.0, max(0.0, mean_age / CONTACT_MEMORY_HORIZON))
        glob[GLOBAL_GROUP_OFFSETS["own_hq_alive"][0]] = 1.0 if hq_pos else 0.0
        glob[GLOBAL_GROUP_OFFSETS["own_hq_known"][0]] = 1.0
        ehq = req["enemy_hq"]
        enemy_hq_known = bool(ehq["known"])
        glob[GLOBAL_GROUP_OFFSETS["enemy_hq_alive"][0]] = \
            1.0 if (enemy_hq_known and bool(ehq["alive"])) else 0.0
        glob[GLOBAL_GROUP_OFFSETS["enemy_hq_known"][0]] = 1.0 if enemy_hq_known else 0.0
        glob[GLOBAL_GROUP_OFFSETS["objective_possession"][0]:
             GLOBAL_GROUP_OFFSETS["objective_possession"][0] + 5] = onehot(
            5, cat(POSSESSION, str(mc.get("objective_possession", "CONTESTED"))))
        mission_progress = float(mc.get("mission_progress", 0.0))
        glob[GLOBAL_GROUP_OFFSETS["mission_progress_ratio"][0]] = \
            min(1.0, max(0.0, mission_progress))
        glob[GLOBAL_GROUP_OFFSETS["mission_progress_known"][0]] = \
            1.0 if mc.get("mission_progress_known", True) else 0.0
        total = max(1, (int(bounds["q_max"]) - int(bounds["q_min"]) + 1)
                    * (int(bounds["r_max"]) - int(bounds["r_min"]) + 1))
        vis_n = len(red_visible)
        expl_n = len(explored)
        glob[GLOBAL_GROUP_OFFSETS["coverage_visible_ratio"][0]] = vis_n / total
        glob[GLOBAL_GROUP_OFFSETS["coverage_explored_ratio"][0]] = expl_n / total
        glob[GLOBAL_GROUP_OFFSETS["coverage_unknown_ratio"][0]] = \
            max(0.0, 1.0 - expl_n / total)
        glob[GLOBAL_GROUP_OFFSETS["coverage_known"][0]] = 1.0
        if overflow:
            glob[GLOBAL_GROUP_OFFSETS["friendly_count_overflow"][0]] = 1.0
            glob[GLOBAL_GROUP_OFFSETS["friendly_count_ratio"][0]] = 1.0

        # ---- legality (D1: Godot runtime truth via the slot map) ------------
        legal = self.slot_map.jev_legal_from_godot(unit_class, req["godot_options"])

        return ShadowProjection(
            actor_features=actor_feats, tokens=tokens, token_pad=token_pad,
            hex_patch=hex_patch, mission_features=mission_feats,
            global_features=glob, legal_mask=legal,
            acting_class_idx=class_idx, mapping=mapping)

    # ---------------------------------------------------------------- helpers
    def _objective_vector(self, req: dict, aq: int, ar: int):
        target = req.get("objective_hex")
        if target:
            dq, dr = int(target[0]) - aq, int(target[1]) - ar
            return (dq, dr), axial_distance(dq, dr), True
        ehq = req.get("enemy_hq", {})
        if bool(ehq.get("known")) and bool(ehq.get("alive")):
            if not isinstance(ehq.get("q"), int) or not isinstance(ehq.get("r"), int):
                raise SchemaMismatch("enemy_hq: known HQ needs int q/r")
            dq, dr = int(ehq["q"]) - aq, int(ehq["r"]) - ar
            return (dq, dr), axial_distance(dq, dr), True
        return (0, -1), 5, False  # sim fallback quirk, mirrored

    def _hq_vector(self, req: dict, aq: int, ar: int):
        hq_pos = req.get("hq_pos")
        if hq_pos:
            if int(hq_pos[0]) == aq and int(hq_pos[1]) == ar:
                return (0, 0), 0, True
            dq, dr = int(hq_pos[0]) - aq, int(hq_pos[1]) - ar
            return (dq, dr), axial_distance(dq, dr), True
        return (0, 0), 0, False

    def _board_edge_free(self, q: int, r: int, bounds: dict) -> list[float]:
        # D4: bounds-rect membership instead of sim is_playable_hex+cell_data.
        total = []
        for dq, dr in ((0, -1), (1, 0), (0, 1), (-1, 0)):
            free = 0
            cq, cr = q, r
            for _ in range(5):
                cq += dq
                cr += dr
                if int(bounds["q_min"]) <= cq <= int(bounds["q_max"]) and \
                        int(bounds["r_min"]) <= cr <= int(bounds["r_max"]):
                    free += 1
                else:
                    break
            total.append(free / 5.0)
        return total

    def to_tensors(self, proj: ShadowProjection, req: dict) -> ObservationBatchV0:
        return ObservationBatchV0(
            actor_features=torch.tensor([proj.actor_features], dtype=torch.float32),
            tokens=torch.tensor([proj.tokens], dtype=torch.float32),
            token_padding_mask=torch.tensor([proj.token_padding_mask], dtype=torch.bool),
            hex_patch=torch.tensor([proj.hex_patch], dtype=torch.float32),
            hex_padding_mask=torch.zeros((1, PATCH_NUM_CELLS), dtype=torch.bool),
            mission_features=torch.tensor([proj.mission_features], dtype=torch.float32),
            global_features=torch.tensor([proj.global_features], dtype=torch.float32),
            legal_mask=torch.tensor([proj.legal_mask], dtype=torch.bool),
            acting_class_idx=torch.tensor([proj.acting_class_idx], dtype=torch.long),
            metadata={"projector": "tools.jev_shadow.project",
                      "request_id": str(req["request_id"]),
                      "decision_id": str(req["decision_id"])},
        )


__all__ = [
    "MISSION_TYPES",
    "ShadowProjection",
    "ShadowProjector",
    "axial_distance",
    "cat",
    "dir_unit",
    "direction_bucket",
    "fold_godot_terrain",
    "normalize_class",
    "onehot",
]
