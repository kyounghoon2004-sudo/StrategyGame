"""Strict validation for jev-shadow-request-v1.

Every malformed request returns a structured SCHEMA_MISMATCH error; nothing
here guesses, fills, or coerces beyond exact type acceptance (bool is not int).
"""

from __future__ import annotations

from tools.jev_shadow import SHADOW_REQUEST_VERSION


class SchemaMismatch(ValueError):
    """Raised for any request that violates jev-shadow-request-v1."""


_REQUIRED_TOP = (
    "schema_version", "request_id", "battle_id", "decision_id", "turn",
    "snapshot_id", "faction", "actor", "unit_class", "mission", "doctrine",
    "ctx", "godot_options", "baseline", "planned_command", "friendlies",
    "enemies_visible", "stale", "hex_cells", "red_visible_cells",
    "objective_hex", "hq_pos", "enemy_hq", "turn_limit",
    "mission_evaluation",
)

_ACTOR_REQUIRED = (
    "unit_id", "unit_class", "q", "r", "soldiers", "max_count",
    "remaining_mp", "base_mp", "turn_move_cost_spent", "blue_limit",
    "can_attack", "has_attacked", "action_ended", "status", "morale",
    "routed", "garrisoned", "defense_ready", "formation",
)

_MISSION_REQUIRED = (
    "mission_id", "task", "area", "status", "objective", "engagement",
    "constraints", "activated_turn", "progress_turn",
)

_DOCTRINE_REQUIRED = (
    "aggression", "risk_tolerance", "tempo", "pursuit",
    "reserve_discipline", "deception",
)

_CTX_REQUIRED = (
    "turns_active", "urgency", "mission_status", "main_effort", "bounds",
)

_FRIENDLY_REQUIRED = (
    "unit_id", "class", "q", "r", "soldiers", "max_count", "has_acted",
    "status",
)

_ENEMY_REQUIRED = ("unit_id", "class", "q", "r", "last_seen_turn")
_STALE_REQUIRED = ("unit_id", "class", "q", "r", "last_seen_turn")
_CELL_REQUIRED = ("q", "r", "terrain", "in_bounds")
_OPTION_REQUIRED = ("slot", "option_id", "kind", "masked", "mask_reason")


def _is_int(v: object) -> bool:
    return isinstance(v, int) and not isinstance(v, bool)


def _is_num(v: object) -> bool:
    return (isinstance(v, (int, float)) and not isinstance(v, bool))


def _req(d: dict, key: str, where: str):
    if key not in d:
        raise SchemaMismatch(f"{where}: missing required key {key!r}")
    return d[key]


def _check_keys(d: dict, required: tuple[str, ...], where: str) -> None:
    if not isinstance(d, dict):
        raise SchemaMismatch(f"{where}: expected object, got {type(d).__name__}")
    for k in required:
        if k not in d:
            raise SchemaMismatch(f"{where}: missing required key {k!r}")


def validate_request(req: object) -> dict:
    """Validate and normalize a shadow request. Returns the request dict."""
    if not isinstance(req, dict):
        raise SchemaMismatch("top: expected JSON object")
    _check_keys(req, _REQUIRED_TOP, "top")
    if req["schema_version"] != SHADOW_REQUEST_VERSION:
        raise SchemaMismatch(
            f"top: schema_version {req['schema_version']!r} != {SHADOW_REQUEST_VERSION!r}")
    for k in ("request_id", "battle_id", "decision_id", "snapshot_id",
              "faction", "unit_class"):
        if not isinstance(req[k], str) or not req[k]:
            raise SchemaMismatch(f"top: {k} must be a non-empty string")
    if req["faction"] != "RED":
        raise SchemaMismatch(f"top: faction must be 'RED', got {req['faction']!r}")
    if not _is_int(req["turn"]):
        raise SchemaMismatch("top: turn must be int")
    if not _is_int(req["turn_limit"]):
        raise SchemaMismatch("top: turn_limit must be int")

    actor = _req(req, "actor", "top")
    _check_keys(actor, _ACTOR_REQUIRED, "actor")
    for k in ("unit_id", "unit_class", "status", "formation"):
        if not isinstance(actor[k], str):
            raise SchemaMismatch(f"actor: {k} must be string")
    for k in ("q", "r", "soldiers", "max_count"):
        if not _is_int(actor[k]):
            raise SchemaMismatch(f"actor: {k} must be int")
    for k in ("remaining_mp", "base_mp", "turn_move_cost_spent", "blue_limit",
              "morale"):
        if not _is_num(actor[k]):
            raise SchemaMismatch(f"actor: {k} must be numeric")
    for k in ("can_attack", "has_attacked", "action_ended", "routed",
              "garrisoned", "defense_ready"):
        if not isinstance(actor[k], bool):
            raise SchemaMismatch(f"actor: {k} must be bool")

    mission = _req(req, "mission", "top")
    _check_keys(mission, _MISSION_REQUIRED, "mission")
    for k in ("mission_id", "task", "area", "status"):
        if not isinstance(mission[k], str):
            raise SchemaMismatch(f"mission: {k} must be string")
    if not isinstance(mission["objective"], dict):
        raise SchemaMismatch("mission: objective must be object")
    for k in ("activated_turn", "progress_turn"):
        if not _is_int(mission[k]):
            raise SchemaMismatch(f"mission: {k} must be int")

    doctrine = _req(req, "doctrine", "top")
    _check_keys(doctrine, _DOCTRINE_REQUIRED, "doctrine")
    for k in _DOCTRINE_REQUIRED:
        if not _is_num(doctrine[k]):
            raise SchemaMismatch(f"doctrine: {k} must be numeric")

    ctx = _req(req, "ctx", "top")
    _check_keys(ctx, _CTX_REQUIRED, "ctx")
    if not _is_int(ctx["turns_active"]):
        raise SchemaMismatch("ctx: turns_active must be int")
    if not _is_num(ctx["urgency"]):
        raise SchemaMismatch("ctx: urgency must be numeric")
    if not isinstance(ctx["bounds"], dict):
        raise SchemaMismatch("ctx: bounds must be object")
    for k in ("q_min", "q_max", "r_min", "r_max"):
        if k not in ctx["bounds"] or not _is_int(ctx["bounds"][k]):
            raise SchemaMismatch(f"ctx.bounds: {k} must be int")

    opts = _req(req, "godot_options", "top")
    if not isinstance(opts, list) or len(opts) != 6:
        raise SchemaMismatch("godot_options: must be a 6-element array")
    for i, o in enumerate(opts):
        _check_keys(o, _OPTION_REQUIRED, f"godot_options[{i}]")
        if o["slot"] is not True and o["slot"] is not False and o["slot"] != i:
            raise SchemaMismatch(f"godot_options[{i}]: slot must equal index {i}")
        if not isinstance(o["option_id"], str) or not isinstance(o["kind"], str):
            raise SchemaMismatch(f"godot_options[{i}]: option_id/kind must be strings")
        if not isinstance(o["masked"], bool) or not isinstance(o["mask_reason"], str):
            raise SchemaMismatch(f"godot_options[{i}]: masked must be bool, mask_reason string")

    base = _req(req, "baseline", "top")
    if not isinstance(base, dict) or not _is_int(base.get("slot")) \
            or not isinstance(base.get("option_id"), str):
        raise SchemaMismatch("baseline: need {slot:int, option_id:string}")
    if not 0 <= base["slot"] < 6:
        raise SchemaMismatch("baseline: slot out of range [0,6)")

    if not isinstance(req["planned_command"], dict):
        raise SchemaMismatch("planned_command: must be object")

    for key, req_keys in (("friendlies", _FRIENDLY_REQUIRED),
                          ("enemies_visible", _ENEMY_REQUIRED),
                          ("stale", _STALE_REQUIRED)):
        arr = _req(req, key, "top")
        if not isinstance(arr, list):
            raise SchemaMismatch(f"{key}: must be array")
        for i, u in enumerate(arr):
            _check_keys(u, req_keys, f"{key}[{i}]")
            if not isinstance(u["unit_id"], str) or not isinstance(u["class"], str):
                raise SchemaMismatch(f"{key}[{i}]: unit_id/class must be strings")
            if not _is_int(u["q"]) or not _is_int(u["r"]):
                raise SchemaMismatch(f"{key}[{i}]: q/r must be int")
        if key == "friendlies":
            for i, u in enumerate(arr):
                if not _is_int(u["soldiers"]) or not _is_int(u["max_count"]):
                    raise SchemaMismatch(f"friendlies[{i}]: soldiers/max_count must be int")
                if not isinstance(u["has_acted"], bool) or not isinstance(u["status"], str):
                    raise SchemaMismatch(f"friendlies[{i}]: has_acted bool, status string")
        else:
            for i, u in enumerate(arr):
                if not _is_int(u["last_seen_turn"]):
                    raise SchemaMismatch(f"{key}[{i}]: last_seen_turn must be int")

    cells = _req(req, "hex_cells", "top")
    if not isinstance(cells, list) or len(cells) != 91:
        raise SchemaMismatch(
            f"hex_cells: must be exactly 91 entries, got {len(cells) if isinstance(cells, list) else type(cells).__name__}")
    for i, c in enumerate(cells):
        _check_keys(c, _CELL_REQUIRED, f"hex_cells[{i}]")
        if not _is_int(c["q"]) or not _is_int(c["r"]) or not _is_int(c["terrain"]):
            raise SchemaMismatch(f"hex_cells[{i}]: q/r/terrain must be int")
        if not isinstance(c["in_bounds"], bool):
            raise SchemaMismatch(f"hex_cells[{i}]: in_bounds must be bool")

    vis = _req(req, "red_visible_cells", "top")
    if not isinstance(vis, list) or any(not isinstance(v, str) for v in vis):
        raise SchemaMismatch("red_visible_cells: must be array of 'q,r' strings")
    for v in vis:
        parts = v.split(",")
        if len(parts) != 2:
            raise SchemaMismatch(f"red_visible_cells: bad key {v!r}")
        try:
            int(parts[0])
            int(parts[1])
        except ValueError:
            raise SchemaMismatch(f"red_visible_cells: bad key {v!r}")

    for k in ("objective_hex", "hq_pos"):
        v = _req(req, k, "top")
        if v is not None:
            if not isinstance(v, list) or len(v) != 2 \
                    or not _is_int(v[0]) or not _is_int(v[1]):
                raise SchemaMismatch(f"{k}: must be null or [q:int, r:int]")

    ehq = _req(req, "enemy_hq", "top")
    if not isinstance(ehq, dict) or not isinstance(ehq.get("known"), bool) \
            or not isinstance(ehq.get("alive"), bool):
        raise SchemaMismatch("enemy_hq: need {known:bool, alive:bool, ...}")

    mev = _req(req, "mission_evaluation", "top")
    if not isinstance(mev, dict):
        raise SchemaMismatch("mission_evaluation: must be object")

    return req


__all__ = ["SchemaMismatch", "validate_request"]
