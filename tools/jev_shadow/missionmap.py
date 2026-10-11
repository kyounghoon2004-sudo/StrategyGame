"""Godot mission/doctrine -> training mission context (jev-shadow-missionmap-v1).

Single authority: JEV_SHADOW_MISSION_MAP.json + the frozen training intent
vectors in artifacts/jev_mission_data_v1/MISSION_FAMILIES.json. Builds the
mission_context dict consumed by the shadow projector (same keys the sim
projector consumes, so encoding stays identical downstream).
"""

from __future__ import annotations

import json
import os

from tools.jev_shadow import SHADOW_MISSIONMAP_VERSION

HERE = os.path.dirname(os.path.abspath(__file__))
STRATEGY_ROOT = os.path.abspath(os.path.join(HERE, os.pardir, os.pardir))
DEFAULT_MAP_PATH = os.path.join(
    STRATEGY_ROOT, "artifacts", "jev_godot_shadow_v0",
    "JEV_SHADOW_MISSION_MAP.json")
DEFAULT_INTENTS_PATH = os.path.join(
    STRATEGY_ROOT, "artifacts", "jev_mission_data_v1",
    "MISSION_FAMILIES.json")


class MissionMapError(ValueError):
    """Raised for unmappable mission/doctrine facts."""


def _clamp01(v: float) -> float:
    return min(1.0, max(0.0, float(v)))


class MissionMap:
    def __init__(self, path: str = DEFAULT_MAP_PATH,
                 intents_path: str = DEFAULT_INTENTS_PATH) -> None:
        with open(path, encoding="utf-8") as f:
            doc = json.load(f)
        if doc.get("mission_map_version") != SHADOW_MISSIONMAP_VERSION:
            raise MissionMapError(
                f"mission_map_version {doc.get('mission_map_version')!r} != "
                f"{SHADOW_MISSIONMAP_VERSION!r}")
        with open(intents_path, encoding="utf-8") as f:
            intents_doc = json.load(f)
        self.doc = doc
        self.intents = {i["name"]: i for i in intents_doc["intents"]}
        self.task_to_intent = doc["godot_task_to_intent"]
        # every mapped intent must exist in the frozen training families
        for task, row in self.task_to_intent.items():
            if row["intent"] not in self.intents:
                raise MissionMapError(
                    f"task {task}: intent {row['intent']!r} not in MISSION_FAMILIES")

    def build_context(self, req: dict) -> dict:
        """Build the sim-compatible mission_context dict + mapping provenance."""
        mission = req["mission"]
        doctrine = req["doctrine"]
        ctx = req["ctx"]
        turn = int(req["turn"])
        turn_limit = int(req["turn_limit"])

        task = str(mission["task"]).strip().upper()
        row = self.task_to_intent.get(task)
        if row is None:
            raise MissionMapError(f"unknown Godot mission task {task!r}")
        intent = self.intents[row["intent"]]
        mission_type = row["mission_type"]
        role = row["role"]

        # objective type from the Godot objective kind
        obj = mission.get("objective", {}) or {}
        kind = str(obj.get("kind", "NONE")).strip().upper()
        obj_map = self.doc["godot_objective_to_objective_type"]
        if kind == "ZONE":
            zone = str(obj.get("zone", "")).strip().upper()
            objective_type = obj_map["ZONE_HQ"] if zone == "HQ" else obj_map["ZONE_OTHER"]
        else:
            if kind not in obj_map:
                raise MissionMapError(f"unknown Godot objective kind {kind!r}")
            objective_type = obj_map[kind]

        status = str(mission.get("status", "ACTIVE")).strip().upper()
        status_map = self.doc["godot_status_to_objective_status"]
        if status not in status_map:
            raise MissionMapError(f"unknown Godot mission status {status!r}")
        objective_status = status_map[status]

        # doctrine: five live-mapped axes + objective_priority intent default
        live = {k: _clamp01(doctrine[k]) for k in (
            "aggression", "risk_tolerance", "tempo", "pursuit",
            "reserve_discipline", "deception")}
        intent_doctrine = intent["doctrine"]
        doctrine_out = {
            "aggression": live["aggression"],
            "caution": 1.0 - live["risk_tolerance"],
            "cohesion_preservation": live["reserve_discipline"],
            "initiative": live["tempo"],
            "attrition_tolerance": live["risk_tolerance"],
            "objective_priority": _clamp01(intent_doctrine["objective_priority"]),
        }
        doctrine_sources = {
            "aggression": "live",
            "caution": "live:1-risk_tolerance",
            "cohesion_preservation": "live:reserve_discipline",
            "initiative": "live:tempo",
            "attrition_tolerance": "live:risk_tolerance",
            "objective_priority": f"intent_default:{row['intent']}",
        }

        # mission phase buckets mirror sim _mission_phase exactly
        eff_limit = turn_limit if turn_limit > 0 else 10
        frac = turn / max(1, eff_limit)
        if frac <= 0.33:
            phase = "EARLY"
        elif frac <= 0.66:
            phase = "MID"
        else:
            phase = "LATE"

        # objective geometry: production mission_point target hex (facts), with
        # the sim _objective_vector fallback chain applied in the projector.
        target_hex = req.get("objective_hex")

        # possession / progress per the frozen status-derived rules
        if kind in ("ENEMY_FORMATION", "FORMATION_CLASS"):
            possession = "ENEMY"
        elif kind in ("REGION", "ZONE"):
            possession = "CONTESTED"
        else:
            possession = "UNKNOWN"
        if status == "PROGRESSING":
            progress, progress_known = 0.5, True
        elif status == "SUCCESS":
            progress, progress_known = 1.0, True
        else:
            progress, progress_known = 0.0, True

        mc = {
            "mission_type": mission_type,
            "objective_type": objective_type,
            "objective_status": objective_status,
            "mission_phase": phase,
            "urgency": _clamp01(ctx["urgency"]),
            "urgency_known": True,
            "doctrine": doctrine_out,
            "actor_mission_role": role,
            "target_hex": list(target_hex) if target_hex else None,
            "objective_possession": possession,
            "mission_progress": progress,
            "mission_progress_known": progress_known,
        }
        provenance = {
            "intent_mapped": row["intent"],
            "mission_type": mission_type,
            "actor_role": role,
            "godot_task": task,
            "doctrine_sources": doctrine_sources,
            "deception_dropped": True,
            "objective_type": objective_type,
            "objective_status": objective_status,
            "mission_phase": phase,
            "objective_possession": possession,
        }
        return {"mission_context": mc, "provenance": provenance}


__all__ = ["DEFAULT_INTENTS_PATH", "DEFAULT_MAP_PATH", "MissionMap",
           "MissionMapError"]
