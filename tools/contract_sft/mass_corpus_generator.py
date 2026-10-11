"""Mass Corpus Generator for Godot VictoryPlan V1.
Generates 5 materially different, contract-compliant candidate plans for each of the first 8 scenarios
from train_gen.json (seeds 0-7), validates them via Godot production harness + reward_contract P1-P11,
and writes the verified JSONL corpus to artifacts/contract_sft_v1/dataset/mass_corpus_v1.jsonl.
"""
from __future__ import annotations

import json
from pathlib import Path
from typing import Any, Dict, List

from tools.contract_sft import harness as H
from tools.training_supervisor import reward_contract as RC

PROJ = Path(r"D:\Game development\Demon slayer\StrategyGame")
TRAIN_GEN = PROJ / "artifacts" / "contract_sft_v1" / "prompts" / "train_gen.json"
OUT_JSONL = PROJ / "artifacts" / "contract_sft_v1" / "dataset" / "mass_corpus_v1.jsonl"


def create_all_plans() -> List[Dict[str, Any]]:
    rows = []

    # =========================================================================
    # SCENARIO 0: csft_s00000 (RED, survive_turns)
    # Friendly non-HQ: R_ARC_1, R_CAV_1, R_CON_1, R_INF_1, R_INF_2, R_SCT_1, R_SIE_1, R_SPE_1, R_SPE_2
    # Known enemy: []
    # =========================================================================
    s0 = "csft_s00000"

    # S0 V1: Direct Aggressive Pressure
    p0_v1 = {
        "objective": "Preemptively seize the center and south axes to break opposing forces before they consolidate.",
        "cadence": 3,
        "doctrine": [0.8, 0.6, 0.8, 0.7, 0.2, 0.3],
        "phases": [
            {
                "id": "P1",
                "name": "PREEMPTIVE CENTER STRIKE",
                "purpose": "Aggressively push center and south avenues to crush forward hostiles.",
                "missions": [
                    {
                        "task": "ATTACK",
                        "area": "CENTER",
                        "units": ["R_INF_1", "R_INF_2", "R_SPE_2", "R_SIE_1"],
                        "vs": "INFANTRY",
                        "win": [{"when": "TURNS_ELAPSED", "turns": 3, "since": 1}],
                        "stop": [{"when": "HQ_THREATENED"}],
                        "preserve": False
                    },
                    {
                        "task": "ADVANCE",
                        "area": "SOUTH",
                        "units": ["R_CON_1", "R_SPE_1"],
                        "vs": "ANY",
                        "win": [{"when": "TURNS_ELAPSED", "turns": 3, "since": 1}],
                        "stop": [{"when": "FORCE_STRENGTH_BELOW", "fraction": 0.5}],
                        "preserve": False
                    },
                    {
                        "task": "ATTACK",
                        "area": "CENTER",
                        "units": ["R_CAV_1", "R_ARC_1", "R_SCT_1"],
                        "vs": "CAVALRY",
                        "win": [{"when": "TURNS_ELAPSED", "turns": 3, "since": 1}],
                        "stop": [{"when": "HQ_THREATENED"}],
                        "preserve": False
                    }
                ],
                "win": [{"when": "TURNS_ELAPSED", "turns": 3, "since": 1}],
                "lose": [{"when": "FORCE_STRENGTH_BELOW", "fraction": 0.4}],
                "abort": [{"when": "HQ_THREATENED"}],
                "next": "P2",
                "on_fail": "EMERGENCY"
            },
            {
                "id": "P2",
                "name": "DECISIVE BREAKTHROUGH",
                "purpose": "Shatter broken enemy formations and secure victory.",
                "missions": [
                    {
                        "task": "ATTACK",
                        "area": "CENTER",
                        "units": ["R_INF_1", "R_INF_2", "R_SPE_1", "R_SPE_2", "R_SIE_1", "R_CON_1"],
                        "vs": "ANY",
                        "win": [{"when": "TURNS_ELAPSED", "turns": 4, "since": 1}],
                        "stop": [{"when": "HQ_THREATENED"}],
                        "preserve": False
                    },
                    {
                        "task": "FLANK",
                        "area": "SOUTH",
                        "units": ["R_CAV_1", "R_ARC_1", "R_SCT_1"],
                        "vs": "ANY",
                        "win": [{"when": "TURNS_ELAPSED", "turns": 4, "since": 1}],
                        "stop": [{"when": "HQ_THREATENED"}],
                        "preserve": False
                    }
                ],
                "win": [{"when": "TURNS_ELAPSED", "turns": 4, "since": 1}],
                "lose": [{"when": "FORCE_STRENGTH_BELOW", "fraction": 0.3}],
                "abort": [{"when": "HQ_THREATENED"}],
                "next": "END",
                "on_fail": "HOLD"
            }
        ],
        "abort": [{"when": "FORCE_STRENGTH_BELOW", "fraction": 0.25}]
    }

    # S0 V2: Positional Fix and Flank
    p0_v2 = {
        "objective": "Pin enemy vanguard in center while sweeping the southern flank with mobile forces.",
        "cadence": 4,
        "doctrine": [0.6, 0.5, 0.5, 0.6, 0.5, 0.6],
        "phases": [
            {
                "id": "P1",
                "name": "CENTER ANCHOR & SOUTH PROBE",
                "purpose": "Fix the enemy in center with heavy infantry and scout the south.",
                "missions": [
                    {
                        "task": "FIX",
                        "area": "CENTER",
                        "units": ["R_INF_1", "R_INF_2", "R_SPE_2", "R_SIE_1"],
                        "vs": "INFANTRY",
                        "win": [{"when": "TURNS_ELAPSED", "turns": 3, "since": 1}],
                        "stop": [{"when": "HQ_THREATENED"}],
                        "preserve": True
                    },
                    {
                        "task": "ADVANCE",
                        "area": "SOUTH",
                        "units": ["R_SPE_1", "R_CON_1", "R_SCT_1"],
                        "vs": "ANY",
                        "win": [{"when": "TURNS_ELAPSED", "turns": 3, "since": 1}],
                        "stop": [{"when": "FORCE_STRENGTH_BELOW", "fraction": 0.45}],
                        "preserve": True
                    }
                ],
                "reserve": ["R_CAV_1", "R_ARC_1"],
                "release": [{"when": "ENEMY_CLASS_DETECTED", "class": "INFANTRY", "region": "CENTER"}],
                "win": [{"when": "TURNS_ELAPSED", "turns": 3, "since": 1}],
                "lose": [{"when": "FORCE_STRENGTH_BELOW", "fraction": 0.4}],
                "abort": [{"when": "HQ_THREATENED"}],
                "next": "P2",
                "on_fail": "HOLD"
            },
            {
                "id": "P2",
                "name": "SOUTHERN FLANK ASSAULT",
                "purpose": "Deploy mobile reserve into southern flank while holding center line.",
                "missions": [
                    {
                        "task": "HOLD",
                        "area": "CENTER",
                        "units": ["R_INF_1", "R_INF_2", "R_SPE_2", "R_SIE_1"],
                        "vs": "INFANTRY",
                        "win": [{"when": "TURNS_ELAPSED", "turns": 4, "since": 1}],
                        "stop": [{"when": "HQ_THREATENED"}],
                        "preserve": True
                    },
                    {
                        "task": "FLANK",
                        "area": "SOUTH",
                        "units": ["R_CAV_1", "R_ARC_1", "R_SPE_1", "R_CON_1", "R_SCT_1"],
                        "vs": "ANY",
                        "win": [{"when": "TURNS_ELAPSED", "turns": 4, "since": 1}],
                        "stop": [{"when": "HQ_THREATENED"}],
                        "preserve": False
                    }
                ],
                "win": [{"when": "TURNS_ELAPSED", "turns": 4, "since": 1}],
                "lose": [{"when": "FORCE_STRENGTH_BELOW", "fraction": 0.35}],
                "abort": [{"when": "HQ_THREATENED"}],
                "next": "END",
                "on_fail": "EMERGENCY"
            }
        ],
        "abort": [{"when": "FORCE_STRENGTH_BELOW", "fraction": 0.25}],
        "branches": [
            {
                "id": "B1",
                "if": "Heavy enemy cavalry spotted center",
                "when": {"when": "ENEMY_CLASS_DETECTED", "class": "CAVALRY", "region": "CENTER"},
                "then": "RELEASE_RESERVE"
            }
        ]
    }

    # S0 V3: Reconnaissance & Conditional Commitment
    p0_v3 = {
        "objective": "Screen approach corridors with recon and commit forces conditionally based on detected classes.",
        "cadence": 3,
        "doctrine": [0.4, 0.4, 0.5, 0.4, 0.8, 0.7],
        "phases": [
            {
                "id": "P1",
                "name": "RECON & SCREENING",
                "purpose": "Scout southern and central axes while main formations hold prepared lines.",
                "missions": [
                    {
                        "task": "RECON",
                        "area": "SOUTH",
                        "units": ["R_SCT_1", "R_CAV_1"],
                        "vs": "ANY",
                        "win": [{"when": "TURNS_ELAPSED", "turns": 2, "since": 1}],
                        "stop": [{"when": "FORCE_STRENGTH_BELOW", "fraction": 0.6}],
                        "preserve": True
                    },
                    {
                        "task": "HOLD",
                        "area": "CENTER",
                        "units": ["R_INF_1", "R_INF_2", "R_ARC_1", "R_SIE_1"],
                        "vs": "ANY",
                        "win": [{"when": "TURNS_ELAPSED", "turns": 2, "since": 1}],
                        "stop": [{"when": "HQ_THREATENED"}],
                        "preserve": True
                    },
                    {
                        "task": "HOLD",
                        "area": "SOUTH",
                        "units": ["R_SPE_1", "R_CON_1"],
                        "vs": "ANY",
                        "win": [{"when": "TURNS_ELAPSED", "turns": 2, "since": 1}],
                        "stop": [{"when": "HQ_THREATENED"}],
                        "preserve": True
                    }
                ],
                "reserve": ["R_SPE_2"],
                "release": [{"when": "ENEMY_CLASS_DETECTED", "class": "CAVALRY", "region": "CENTER"}],
                "win": [{"when": "TURNS_ELAPSED", "turns": 2, "since": 1}],
                "lose": [{"when": "FORCE_STRENGTH_BELOW", "fraction": 0.5}],
                "abort": [{"when": "HQ_THREATENED"}],
                "next": "P2",
                "on_fail": "HOLD"
            },
            {
                "id": "P2",
                "name": "TARGETED ENGAGEMENT",
                "purpose": "Engage detected enemy elements with tailored counters.",
                "missions": [
                    {
                        "task": "ATTACK",
                        "area": "CENTER",
                        "units": ["R_INF_1", "R_INF_2", "R_SPE_2", "R_ARC_1", "R_SIE_1"],
                        "vs": "INFANTRY",
                        "win": [{"when": "TURNS_ELAPSED", "turns": 4, "since": 1}],
                        "stop": [{"when": "HQ_THREATENED"}],
                        "preserve": True
                    },
                    {
                        "task": "ADVANCE",
                        "area": "SOUTH",
                        "units": ["R_SPE_1", "R_CON_1", "R_CAV_1", "R_SCT_1"],
                        "vs": "ANY",
                        "win": [{"when": "TURNS_ELAPSED", "turns": 4, "since": 1}],
                        "stop": [{"when": "HQ_THREATENED"}],
                        "preserve": True
                    }
                ],
                "win": [{"when": "TURNS_ELAPSED", "turns": 4, "since": 1}],
                "lose": [{"when": "FORCE_STRENGTH_BELOW", "fraction": 0.4}],
                "abort": [{"when": "HQ_THREATENED"}],
                "next": "END",
                "on_fail": "HOLD"
            }
        ],
        "abort": [{"when": "FORCE_STRENGTH_BELOW", "fraction": 0.3}],
        "branches": [
            {
                "id": "B1",
                "if": "Heavy spear wall encountered center",
                "when": {"when": "ENEMY_CLASS_DETECTED", "class": "SPEARMAN", "region": "CENTER"},
                "then": "REQUEST_REVIEW"
            }
        ]
    }

    # S0 V4: Defensive Attrition & Clock-Surrender
    p0_v4 = {
        "objective": "Fortify central and southern approaches to absorb enemy charges and survive the turn limit.",
        "cadence": 5,
        "doctrine": [0.2, 0.3, 0.3, 0.2, 0.9, 0.4],
        "phases": [
            {
                "id": "P1",
                "name": "PERIMETER FORTIFICATION",
                "purpose": "Anchor center with spearmen and siege while south guards rear approach.",
                "missions": [
                    {
                        "task": "HOLD",
                        "area": "CENTER",
                        "units": ["R_SPE_2", "R_INF_1", "R_INF_2", "R_SIE_1", "R_ARC_1"],
                        "vs": "ANY",
                        "win": [{"when": "TURNS_ELAPSED", "turns": 5, "since": 1}],
                        "stop": [{"when": "HQ_THREATENED"}],
                        "preserve": True
                    },
                    {
                        "task": "HOLD",
                        "area": "SOUTH",
                        "units": ["R_SPE_1", "R_CON_1", "R_SCT_1"],
                        "vs": "ANY",
                        "win": [{"when": "TURNS_ELAPSED", "turns": 5, "since": 1}],
                        "stop": [{"when": "HQ_THREATENED"}],
                        "preserve": True
                    }
                ],
                "reserve": ["R_CAV_1"],
                "release": [{"when": "HQ_THREATENED"}],
                "win": [{"when": "TURNS_ELAPSED", "turns": 5, "since": 1}],
                "lose": [{"when": "FORCE_STRENGTH_BELOW", "fraction": 0.45}],
                "abort": [{"when": "HQ_THREATENED"}],
                "next": "P2",
                "on_fail": "EMERGENCY"
            },
            {
                "id": "P2",
                "name": "FINAL PERIMETER HOLD",
                "purpose": "Maintain impenetrable defensive perimeter until battle clock expires.",
                "missions": [
                    {
                        "task": "HOLD",
                        "area": "CENTER",
                        "units": ["R_SPE_2", "R_INF_1", "R_INF_2", "R_SIE_1", "R_ARC_1", "R_CAV_1"],
                        "vs": "ANY",
                        "win": [{"when": "TURNS_ELAPSED", "turns": 10, "since": 1}],
                        "stop": [{"when": "HQ_THREATENED"}],
                        "preserve": True
                    },
                    {
                        "task": "HOLD",
                        "area": "SOUTH",
                        "units": ["R_SPE_1", "R_CON_1", "R_SCT_1"],
                        "vs": "ANY",
                        "win": [{"when": "TURNS_ELAPSED", "turns": 10, "since": 1}],
                        "stop": [{"when": "HQ_THREATENED"}],
                        "preserve": True
                    }
                ],
                "win": [{"when": "TURNS_ELAPSED", "turns": 10, "since": 1}],
                "lose": [{"when": "FORCE_STRENGTH_BELOW", "fraction": 0.35}],
                "abort": [{"when": "HQ_THREATENED"}],
                "next": "END",
                "on_fail": "EMERGENCY"
            }
        ],
        "abort": [{"when": "FORCE_STRENGTH_BELOW", "fraction": 0.25}],
        "branches": [
            {
                "id": "B1",
                "if": "HQ threatened directly",
                "when": {"when": "HQ_THREATENED"},
                "then": "RELEASE_RESERVE"
            }
        ]
    }

    # S0 V5: Reserve-Heavy Staged Echelon
    p0_v5 = {
        "objective": "Deploy vanguard to fix enemy attention, releasing heavy reserve to crush opposing center.",
        "cadence": 3,
        "doctrine": [0.6, 0.5, 0.6, 0.6, 0.9, 0.3],
        "phases": [
            {
                "id": "P1",
                "name": "VANGUARD SCREEN",
                "purpose": "Initial skirmish line engages hostile vanguard while reserves remain held.",
                "missions": [
                    {
                        "task": "ADVANCE",
                        "area": "CENTER",
                        "units": ["R_INF_1", "R_ARC_1", "R_SIE_1"],
                        "vs": "INFANTRY",
                        "win": [{"when": "TURNS_ELAPSED", "turns": 2, "since": 1}],
                        "stop": [{"when": "FORCE_STRENGTH_BELOW", "fraction": 0.5}],
                        "preserve": True
                    },
                    {
                        "task": "FIX",
                        "area": "SOUTH",
                        "units": ["R_CON_1", "R_SPE_1", "R_SCT_1"],
                        "vs": "ANY",
                        "win": [{"when": "TURNS_ELAPSED", "turns": 2, "since": 1}],
                        "stop": [{"when": "FORCE_STRENGTH_BELOW", "fraction": 0.5}],
                        "preserve": True
                    }
                ],
                "reserve": ["R_CAV_1", "R_INF_2", "R_SPE_2"],
                "release": [{"when": "TURNS_ELAPSED", "turns": 2, "since": 1}],
                "win": [{"when": "TURNS_ELAPSED", "turns": 2, "since": 1}],
                "lose": [{"when": "FORCE_STRENGTH_BELOW", "fraction": 0.45}],
                "abort": [{"when": "HQ_THREATENED"}],
                "next": "P2",
                "on_fail": "HOLD"
            },
            {
                "id": "P2",
                "name": "RESERVE COMMITMENT",
                "purpose": "Commit reserve cavalry and spearmen to deliver crushing central blow.",
                "missions": [
                    {
                        "task": "ATTACK",
                        "area": "CENTER",
                        "units": ["R_CAV_1", "R_INF_2", "R_SPE_2", "R_INF_1", "R_ARC_1", "R_SIE_1"],
                        "vs": "ANY",
                        "win": [{"when": "TURNS_ELAPSED", "turns": 5, "since": 1}],
                        "stop": [{"when": "HQ_THREATENED"}],
                        "preserve": False
                    },
                    {
                        "task": "HOLD",
                        "area": "SOUTH",
                        "units": ["R_CON_1", "R_SPE_1", "R_SCT_1"],
                        "vs": "ANY",
                        "win": [{"when": "TURNS_ELAPSED", "turns": 5, "since": 1}],
                        "stop": [{"when": "HQ_THREATENED"}],
                        "preserve": True
                    }
                ],
                "win": [{"when": "TURNS_ELAPSED", "turns": 5, "since": 1}],
                "lose": [{"when": "FORCE_STRENGTH_BELOW", "fraction": 0.35}],
                "abort": [{"when": "HQ_THREATENED"}],
                "next": "END",
                "on_fail": "EMERGENCY"
            }
        ],
        "abort": [{"when": "FORCE_STRENGTH_BELOW", "fraction": 0.25}],
        "branches": [
            {
                "id": "B1",
                "if": "Frontline breached early",
                "when": {"when": "FORCE_STRENGTH_BELOW", "fraction": 0.55},
                "then": "RELEASE_RESERVE"
            }
        ]
    }

    for vid, p in [("V1", p0_v1), ("V2", p0_v2), ("V3", p0_v3), ("V4", p0_v4), ("V5", p0_v5)]:
        rows.append({"scenario_id": s0, "variant_id": vid, "plan": p})

    # =========================================================================
    # SCENARIO 1: csft_s00001 (BLUE, survive_turns)
    # Friendly non-HQ: B_ARC_1, B_CAV_1, B_CAV_2, B_INF_1, B_INF_2, B_SCT_1, B_SPE_1, B_SPE_2
    # Known enemy: []
    # =========================================================================
    s1 = "csft_s00001"

    # S1 V1: Direct Aggressive Pressure
    p1_v1 = {
        "objective": "Launch immediate high-tempo cavalry-infantry assault from north and center to neutralize threat.",
        "cadence": 3,
        "doctrine": [0.85, 0.7, 0.8, 0.8, 0.2, 0.2],
        "phases": [
            {
                "id": "P1",
                "name": "NORTH-CENTER CHARGE",
                "purpose": "Cavalry wings strike aggressively to disrupt enemy front.",
                "missions": [
                    {
                        "task": "ATTACK",
                        "area": "NORTH",
                        "units": ["B_CAV_1", "B_ARC_1"],
                        "vs": "ANY",
                        "win": [{"when": "TURNS_ELAPSED", "turns": 3, "since": 1}],
                        "stop": [{"when": "HQ_THREATENED"}],
                        "preserve": False
                    },
                    {
                        "task": "ATTACK",
                        "area": "CENTER",
                        "units": ["B_CAV_2", "B_INF_1", "B_INF_2", "B_SPE_1", "B_SPE_2", "B_SCT_1"],
                        "vs": "INFANTRY",
                        "win": [{"when": "TURNS_ELAPSED", "turns": 3, "since": 1}],
                        "stop": [{"when": "HQ_THREATENED"}],
                        "preserve": False
                    }
                ],
                "win": [{"when": "TURNS_ELAPSED", "turns": 3, "since": 1}],
                "lose": [{"when": "FORCE_STRENGTH_BELOW", "fraction": 0.4}],
                "abort": [{"when": "HQ_THREATENED"}],
                "next": "P2",
                "on_fail": "EMERGENCY"
            },
            {
                "id": "P2",
                "name": "ROUT AND PURSUIT",
                "purpose": "Collapse opposing forces across all sectors.",
                "missions": [
                    {
                        "task": "ATTACK",
                        "area": "ANY",
                        "units": ["B_CAV_1", "B_CAV_2", "B_ARC_1", "B_INF_1", "B_INF_2", "B_SPE_1", "B_SPE_2", "B_SCT_1"],
                        "vs": "ANY",
                        "win": [{"when": "TURNS_ELAPSED", "turns": 5, "since": 1}],
                        "stop": [{"when": "HQ_THREATENED"}],
                        "preserve": False
                    }
                ],
                "win": [{"when": "TURNS_ELAPSED", "turns": 5, "since": 1}],
                "lose": [{"when": "FORCE_STRENGTH_BELOW", "fraction": 0.3}],
                "abort": [{"when": "HQ_THREATENED"}],
                "next": "END",
                "on_fail": "HOLD"
            }
        ],
        "abort": [{"when": "FORCE_STRENGTH_BELOW", "fraction": 0.25}]
    }

    # S1 V2: Positional Fix and Flank
    p1_v2 = {
        "objective": "Anchor center corridor with spear-infantry phalanx while north cavalry envelopes enemy flank.",
        "cadence": 4,
        "doctrine": [0.6, 0.5, 0.6, 0.6, 0.5, 0.7],
        "phases": [
            {
                "id": "P1",
                "name": "CENTER FIXATION & NORTH SWEEP",
                "purpose": "Engage enemy center firmly while flanking force maneuvers via north.",
                "missions": [
                    {
                        "task": "FIX",
                        "area": "CENTER",
                        "units": ["B_INF_1", "B_INF_2", "B_SPE_1", "B_SPE_2"],
                        "vs": "INFANTRY",
                        "win": [{"when": "TURNS_ELAPSED", "turns": 3, "since": 1}],
                        "stop": [{"when": "HQ_THREATENED"}],
                        "preserve": True
                    },
                    {
                        "task": "FLANK",
                        "area": "NORTH",
                        "units": ["B_CAV_1", "B_CAV_2", "B_ARC_1", "B_SCT_1"],
                        "vs": "ANY",
                        "win": [{"when": "TURNS_ELAPSED", "turns": 3, "since": 1}],
                        "stop": [{"when": "FORCE_STRENGTH_BELOW", "fraction": 0.5}],
                        "preserve": False
                    }
                ],
                "win": [{"when": "TURNS_ELAPSED", "turns": 3, "since": 1}],
                "lose": [{"when": "FORCE_STRENGTH_BELOW", "fraction": 0.4}],
                "abort": [{"when": "HQ_THREATENED"}],
                "next": "P2",
                "on_fail": "HOLD"
            },
            {
                "id": "P2",
                "name": "CONVERGENT HAMMER AND ANVIL",
                "purpose": "Crush trapped center forces between anvil and mobile hammer.",
                "missions": [
                    {
                        "task": "ATTACK",
                        "area": "CENTER",
                        "units": ["B_INF_1", "B_INF_2", "B_SPE_1", "B_SPE_2"],
                        "vs": "INFANTRY",
                        "win": [{"when": "TURNS_ELAPSED", "turns": 5, "since": 1}],
                        "stop": [{"when": "HQ_THREATENED"}],
                        "preserve": False
                    },
                    {
                        "task": "ATTACK",
                        "area": "CENTER",
                        "units": ["B_CAV_1", "B_CAV_2", "B_ARC_1", "B_SCT_1"],
                        "vs": "ANY",
                        "win": [{"when": "TURNS_ELAPSED", "turns": 5, "since": 1}],
                        "stop": [{"when": "HQ_THREATENED"}],
                        "preserve": False
                    }
                ],
                "win": [{"when": "TURNS_ELAPSED", "turns": 5, "since": 1}],
                "lose": [{"when": "FORCE_STRENGTH_BELOW", "fraction": 0.35}],
                "abort": [{"when": "HQ_THREATENED"}],
                "next": "END",
                "on_fail": "EMERGENCY"
            }
        ],
        "abort": [{"when": "FORCE_STRENGTH_BELOW", "fraction": 0.25}]
    }

    # S1 V3: Reconnaissance & Ambush Screen
    p1_v3 = {
        "objective": "Scout lines of advance in center and north before committing main formations.",
        "cadence": 3,
        "doctrine": [0.4, 0.4, 0.5, 0.4, 0.7, 0.8],
        "phases": [
            {
                "id": "P1",
                "name": "RECONNAISSANCE SCREEN",
                "purpose": "Deploy scout and horse to spot hostiles while infantry digs in.",
                "missions": [
                    {
                        "task": "RECON",
                        "area": "CENTER",
                        "units": ["B_SCT_1", "B_CAV_2"],
                        "vs": "ANY",
                        "win": [{"when": "TURNS_ELAPSED", "turns": 2, "since": 1}],
                        "stop": [{"when": "FORCE_STRENGTH_BELOW", "fraction": 0.6}],
                        "preserve": True
                    },
                    {
                        "task": "HOLD",
                        "area": "NORTH",
                        "units": ["B_ARC_1", "B_CAV_1"],
                        "vs": "ANY",
                        "win": [{"when": "TURNS_ELAPSED", "turns": 2, "since": 1}],
                        "stop": [{"when": "HQ_THREATENED"}],
                        "preserve": True
                    },
                    {
                        "task": "HOLD",
                        "area": "CENTER",
                        "units": ["B_INF_1", "B_INF_2", "B_SPE_1", "B_SPE_2"],
                        "vs": "ANY",
                        "win": [{"when": "TURNS_ELAPSED", "turns": 2, "since": 1}],
                        "stop": [{"when": "HQ_THREATENED"}],
                        "preserve": True
                    }
                ],
                "win": [{"when": "TURNS_ELAPSED", "turns": 2, "since": 1}],
                "lose": [{"when": "FORCE_STRENGTH_BELOW", "fraction": 0.5}],
                "abort": [{"when": "HQ_THREATENED"}],
                "next": "P2",
                "on_fail": "HOLD"
            },
            {
                "id": "P2",
                "name": "OPPORTUNITY ADVANCE",
                "purpose": "Push into discovered enemy weak points.",
                "missions": [
                    {
                        "task": "ADVANCE",
                        "area": "NORTH",
                        "units": ["B_CAV_1", "B_ARC_1"],
                        "vs": "ANY",
                        "win": [{"when": "TURNS_ELAPSED", "turns": 4, "since": 1}],
                        "stop": [{"when": "HQ_THREATENED"}],
                        "preserve": True
                    },
                    {
                        "task": "ATTACK",
                        "area": "CENTER",
                        "units": ["B_INF_1", "B_INF_2", "B_SPE_1", "B_SPE_2", "B_CAV_2", "B_SCT_1"],
                        "vs": "INFANTRY",
                        "win": [{"when": "TURNS_ELAPSED", "turns": 4, "since": 1}],
                        "stop": [{"when": "HQ_THREATENED"}],
                        "preserve": False
                    }
                ],
                "win": [{"when": "TURNS_ELAPSED", "turns": 4, "since": 1}],
                "lose": [{"when": "FORCE_STRENGTH_BELOW", "fraction": 0.4}],
                "abort": [{"when": "HQ_THREATENED"}],
                "next": "END",
                "on_fail": "HOLD"
            }
        ],
        "abort": [{"when": "FORCE_STRENGTH_BELOW", "fraction": 0.3}],
        "branches": [
            {
                "id": "B1",
                "if": "Heavy enemy cavalry in north sector",
                "when": {"when": "ENEMY_CLASS_DETECTED", "class": "CAVALRY", "region": "NORTH"},
                "then": "REQUEST_REVIEW"
            }
        ]
    }

    # S1 V4: Defensive Attrition
    p1_v4 = {
        "objective": "Form tight defensive perimeter around North HQ to outlast enemy assault waves.",
        "cadence": 5,
        "doctrine": [0.2, 0.2, 0.3, 0.2, 0.9, 0.3],
        "phases": [
            {
                "id": "P1",
                "name": "PERIMETER SHIELD",
                "purpose": "Lock down north and center corridors with spear-infantry blocks.",
                "missions": [
                    {
                        "task": "HOLD",
                        "area": "NORTH",
                        "units": ["B_ARC_1", "B_SPE_1", "B_INF_1"],
                        "vs": "ANY",
                        "win": [{"when": "TURNS_ELAPSED", "turns": 4, "since": 1}],
                        "stop": [{"when": "HQ_THREATENED"}],
                        "preserve": True
                    },
                    {
                        "task": "HOLD",
                        "area": "CENTER",
                        "units": ["B_SPE_2", "B_INF_2", "B_SCT_1"],
                        "vs": "ANY",
                        "win": [{"when": "TURNS_ELAPSED", "turns": 4, "since": 1}],
                        "stop": [{"when": "HQ_THREATENED"}],
                        "preserve": True
                    }
                ],
                "reserve": ["B_CAV_1", "B_CAV_2"],
                "release": [{"when": "HQ_THREATENED"}],
                "win": [{"when": "TURNS_ELAPSED", "turns": 4, "since": 1}],
                "lose": [{"when": "FORCE_STRENGTH_BELOW", "fraction": 0.45}],
                "abort": [{"when": "HQ_THREATENED"}],
                "next": "P2",
                "on_fail": "EMERGENCY"
            },
            {
                "id": "P2",
                "name": "EXTENDED DEFENSE TO CLOCK",
                "purpose": "Absorb remaining hostile attacks until turn limit ends battle.",
                "missions": [
                    {
                        "task": "HOLD",
                        "area": "NORTH",
                        "units": ["B_ARC_1", "B_SPE_1", "B_INF_1", "B_CAV_1"],
                        "vs": "ANY",
                        "win": [{"when": "TURNS_ELAPSED", "turns": 10, "since": 1}],
                        "stop": [{"when": "HQ_THREATENED"}],
                        "preserve": True
                    },
                    {
                        "task": "HOLD",
                        "area": "CENTER",
                        "units": ["B_SPE_2", "B_INF_2", "B_SCT_1", "B_CAV_2"],
                        "vs": "ANY",
                        "win": [{"when": "TURNS_ELAPSED", "turns": 10, "since": 1}],
                        "stop": [{"when": "HQ_THREATENED"}],
                        "preserve": True
                    }
                ],
                "win": [{"when": "TURNS_ELAPSED", "turns": 10, "since": 1}],
                "lose": [{"when": "FORCE_STRENGTH_BELOW", "fraction": 0.35}],
                "abort": [{"when": "HQ_THREATENED"}],
                "next": "END",
                "on_fail": "EMERGENCY"
            }
        ],
        "abort": [{"when": "FORCE_STRENGTH_BELOW", "fraction": 0.25}],
        "branches": [
            {
                "id": "B1",
                "if": "HQ under imminent threat",
                "when": {"when": "HQ_THREATENED"},
                "then": "RELEASE_RESERVE"
            }
        ]
    }

    # S1 V5: Reserve-Heavy Staged Echelon
    p1_v5 = {
        "objective": "Engage enemy lines with spear vanguard; release cavalry reserves on timed counterattack.",
        "cadence": 3,
        "doctrine": [0.6, 0.5, 0.6, 0.6, 0.85, 0.3],
        "phases": [
            {
                "id": "P1",
                "name": "INITIAL CONTACT",
                "purpose": "Hold center and north contact with frontline formations while cavalry stays ready.",
                "missions": [
                    {
                        "task": "FIX",
                        "area": "CENTER",
                        "units": ["B_INF_1", "B_SPE_1", "B_SPE_2", "B_SCT_1"],
                        "vs": "INFANTRY",
                        "win": [{"when": "TURNS_ELAPSED", "turns": 2, "since": 1}],
                        "stop": [{"when": "FORCE_STRENGTH_BELOW", "fraction": 0.5}],
                        "preserve": True
                    },
                    {
                        "task": "ADVANCE",
                        "area": "NORTH",
                        "units": ["B_INF_2", "B_ARC_1"],
                        "vs": "ANY",
                        "win": [{"when": "TURNS_ELAPSED", "turns": 2, "since": 1}],
                        "stop": [{"when": "FORCE_STRENGTH_BELOW", "fraction": 0.5}],
                        "preserve": True
                    }
                ],
                "reserve": ["B_CAV_1", "B_CAV_2"],
                "release": [{"when": "TURNS_ELAPSED", "turns": 2, "since": 1}],
                "win": [{"when": "TURNS_ELAPSED", "turns": 2, "since": 1}],
                "lose": [{"when": "FORCE_STRENGTH_BELOW", "fraction": 0.45}],
                "abort": [{"when": "HQ_THREATENED"}],
                "next": "P2",
                "on_fail": "HOLD"
            },
            {
                "id": "P2",
                "name": "RESERVE SHOCK ASSAULT",
                "purpose": "Deploy paired cavalry wings into enemy flanks to shatter resistance.",
                "missions": [
                    {
                        "task": "ATTACK",
                        "area": "CENTER",
                        "units": ["B_CAV_2", "B_INF_1", "B_SPE_1", "B_SPE_2", "B_SCT_1"],
                        "vs": "ANY",
                        "win": [{"when": "TURNS_ELAPSED", "turns": 5, "since": 1}],
                        "stop": [{"when": "HQ_THREATENED"}],
                        "preserve": False
                    },
                    {
                        "task": "ATTACK",
                        "area": "NORTH",
                        "units": ["B_CAV_1", "B_INF_2", "B_ARC_1"],
                        "vs": "ANY",
                        "win": [{"when": "TURNS_ELAPSED", "turns": 5, "since": 1}],
                        "stop": [{"when": "HQ_THREATENED"}],
                        "preserve": False
                    }
                ],
                "win": [{"when": "TURNS_ELAPSED", "turns": 5, "since": 1}],
                "lose": [{"when": "FORCE_STRENGTH_BELOW", "fraction": 0.35}],
                "abort": [{"when": "HQ_THREATENED"}],
                "next": "END",
                "on_fail": "HOLD"
            }
        ],
        "abort": [{"when": "FORCE_STRENGTH_BELOW", "fraction": 0.25}],
        "branches": [
            {
                "id": "B1",
                "if": "Frontline taking heavy damage early",
                "when": {"when": "FORCE_STRENGTH_BELOW", "fraction": 0.55},
                "then": "RELEASE_RESERVE"
            }
        ]
    }

    for vid, p in [("V1", p1_v1), ("V2", p1_v2), ("V3", p1_v3), ("V4", p1_v4), ("V5", p1_v5)]:
        rows.append({"scenario_id": s1, "variant_id": vid, "plan": p})

    # =========================================================================
    # SCENARIO 2: csft_s00002 (RED, destroy_all_red -> destroy blue)
    # Friendly non-HQ: R_INF_1, R_INF_2, R_INF_3, R_SCT_1
    # Known enemy: []
    # =========================================================================
    s2 = "csft_s00002"

    # S2 V1: Concentrated Infantry Phalanx
    p2_v1 = {
        "objective": "Advance in unified infantry column behind scout lead to locate and destroy enemy force.",
        "cadence": 3,
        "doctrine": [0.8, 0.6, 0.7, 0.7, 0.2, 0.2],
        "phases": [
            {
                "id": "P1",
                "name": "PHALANX ADVANCE",
                "purpose": "Push central axis in dense formation led by scout reconnaissance.",
                "missions": [
                    {
                        "task": "ADVANCE",
                        "area": "CENTER",
                        "units": ["R_SCT_1"],
                        "vs": "ANY",
                        "win": [{"when": "TURNS_ELAPSED", "turns": 2, "since": 1}],
                        "stop": [{"when": "FORCE_STRENGTH_BELOW", "fraction": 0.6}],
                        "preserve": True
                    },
                    {
                        "task": "ATTACK",
                        "area": "CENTER",
                        "units": ["R_INF_1", "R_INF_2", "R_INF_3"],
                        "vs": "INFANTRY",
                        "win": [{"when": "TURNS_ELAPSED", "turns": 3, "since": 1}],
                        "stop": [{"when": "HQ_THREATENED"}],
                        "preserve": False
                    }
                ],
                "win": [{"when": "TURNS_ELAPSED", "turns": 3, "since": 1}],
                "lose": [{"when": "FORCE_STRENGTH_BELOW", "fraction": 0.45}],
                "abort": [{"when": "HQ_THREATENED"}],
                "next": "P2",
                "on_fail": "EMERGENCY"
            },
            {
                "id": "P2",
                "name": "DECISIVE CLOSE COMBAT",
                "purpose": "Assault located hostile elements with all available regiments.",
                "missions": [
                    {
                        "task": "ATTACK",
                        "area": "CENTER",
                        "units": ["R_INF_1", "R_INF_2", "R_INF_3", "R_SCT_1"],
                        "vs": "ANY",
                        "win": [{"when": "TURNS_ELAPSED", "turns": 5, "since": 1}],
                        "stop": [{"when": "HQ_THREATENED"}],
                        "preserve": False
                    }
                ],
                "win": [{"when": "TURNS_ELAPSED", "turns": 5, "since": 1}],
                "lose": [{"when": "FORCE_STRENGTH_BELOW", "fraction": 0.3}],
                "abort": [{"when": "HQ_THREATENED"}],
                "next": "END",
                "on_fail": "HOLD"
            }
        ],
        "abort": [{"when": "FORCE_STRENGTH_BELOW", "fraction": 0.25}]
    }

    # S2 V2: Pincer Advance (Fix & Flank)
    p2_v2 = {
        "objective": "Fix enemy center with two infantry units while third unit maneuvers around flank.",
        "cadence": 4,
        "doctrine": [0.6, 0.5, 0.6, 0.6, 0.4, 0.6],
        "phases": [
            {
                "id": "P1",
                "name": "PIN AND ENVELOP",
                "purpose": "Frontal infantry fixes hostile attention while scout and INF_3 execute envelopment.",
                "missions": [
                    {
                        "task": "FIX",
                        "area": "CENTER",
                        "units": ["R_INF_1", "R_INF_2"],
                        "vs": "INFANTRY",
                        "win": [{"when": "TURNS_ELAPSED", "turns": 3, "since": 1}],
                        "stop": [{"when": "HQ_THREATENED"}],
                        "preserve": True
                    },
                    {
                        "task": "FLANK",
                        "area": "NORTH",
                        "units": ["R_INF_3", "R_SCT_1"],
                        "vs": "ANY",
                        "win": [{"when": "TURNS_ELAPSED", "turns": 3, "since": 1}],
                        "stop": [{"when": "FORCE_STRENGTH_BELOW", "fraction": 0.5}],
                        "preserve": False
                    }
                ],
                "win": [{"when": "TURNS_ELAPSED", "turns": 3, "since": 1}],
                "lose": [{"when": "FORCE_STRENGTH_BELOW", "fraction": 0.4}],
                "abort": [{"when": "HQ_THREATENED"}],
                "next": "P2",
                "on_fail": "HOLD"
            },
            {
                "id": "P2",
                "name": "COLLAPSE OPPOSITION",
                "purpose": "Close the trap from both directions to eliminate hostiles.",
                "missions": [
                    {
                        "task": "ATTACK",
                        "area": "CENTER",
                        "units": ["R_INF_1", "R_INF_2", "R_INF_3", "R_SCT_1"],
                        "vs": "ANY",
                        "win": [{"when": "TURNS_ELAPSED", "turns": 6, "since": 1}],
                        "stop": [{"when": "HQ_THREATENED"}],
                        "preserve": False
                    }
                ],
                "win": [{"when": "TURNS_ELAPSED", "turns": 6, "since": 1}],
                "lose": [{"when": "FORCE_STRENGTH_BELOW", "fraction": 0.3}],
                "abort": [{"when": "HQ_THREATENED"}],
                "next": "END",
                "on_fail": "EMERGENCY"
            }
        ],
        "abort": [{"when": "FORCE_STRENGTH_BELOW", "fraction": 0.25}]
    }

    # S2 V3: Recon First & Conditional Advance
    p2_v3 = {
        "objective": "Scout probes ahead to locate enemy formation while infantry holds defensive perimeter.",
        "cadence": 3,
        "doctrine": [0.4, 0.4, 0.5, 0.4, 0.7, 0.7],
        "phases": [
            {
                "id": "P1",
                "name": "PROBING CONTACT",
                "purpose": "Deploy scout to unmask center while infantry holds defensive line.",
                "missions": [
                    {
                        "task": "RECON",
                        "area": "CENTER",
                        "units": ["R_SCT_1"],
                        "vs": "ANY",
                        "win": [{"when": "TURNS_ELAPSED", "turns": 2, "since": 1}],
                        "stop": [{"when": "FORCE_STRENGTH_BELOW", "fraction": 0.6}],
                        "preserve": True
                    },
                    {
                        "task": "HOLD",
                        "area": "CENTER",
                        "units": ["R_INF_1", "R_INF_2", "R_INF_3"],
                        "vs": "ANY",
                        "win": [{"when": "TURNS_ELAPSED", "turns": 2, "since": 1}],
                        "stop": [{"when": "HQ_THREATENED"}],
                        "preserve": True
                    }
                ],
                "win": [{"when": "TURNS_ELAPSED", "turns": 2, "since": 1}],
                "lose": [{"when": "FORCE_STRENGTH_BELOW", "fraction": 0.5}],
                "abort": [{"when": "HQ_THREATENED"}],
                "next": "P2",
                "on_fail": "HOLD"
            },
            {
                "id": "P2",
                "name": "COORDINATED STRIKE",
                "purpose": "Advance with full force against discovered enemy position.",
                "missions": [
                    {
                        "task": "ATTACK",
                        "area": "CENTER",
                        "units": ["R_INF_1", "R_INF_2", "R_INF_3", "R_SCT_1"],
                        "vs": "INFANTRY",
                        "win": [{"when": "TURNS_ELAPSED", "turns": 5, "since": 1}],
                        "stop": [{"when": "HQ_THREATENED"}],
                        "preserve": False
                    }
                ],
                "win": [{"when": "TURNS_ELAPSED", "turns": 5, "since": 1}],
                "lose": [{"when": "FORCE_STRENGTH_BELOW", "fraction": 0.35}],
                "abort": [{"when": "HQ_THREATENED"}],
                "next": "END",
                "on_fail": "EMERGENCY"
            }
        ],
        "abort": [{"when": "FORCE_STRENGTH_BELOW", "fraction": 0.25}],
        "branches": [
            {
                "id": "B1",
                "if": "Hostile cavalry detected center",
                "when": {"when": "ENEMY_CLASS_DETECTED", "class": "CAVALRY", "region": "CENTER"},
                "then": "REQUEST_REVIEW"
            }
        ]
    }

    # S2 V4: Defensive Bait & Counterattack
    p2_v4 = {
        "objective": "Bait enemy into attacking fortified center infantry, then launch counter-assault.",
        "cadence": 4,
        "doctrine": [0.3, 0.3, 0.4, 0.3, 0.8, 0.5],
        "phases": [
            {
                "id": "P1",
                "name": "BAIT AND DEFEND",
                "purpose": "Anchor center position and entice enemy attack.",
                "missions": [
                    {
                        "task": "HOLD",
                        "area": "CENTER",
                        "units": ["R_INF_1", "R_INF_2", "R_SCT_1"],
                        "vs": "ANY",
                        "win": [{"when": "TURNS_ELAPSED", "turns": 3, "since": 1}],
                        "stop": [{"when": "HQ_THREATENED"}],
                        "preserve": True
                    }
                ],
                "reserve": ["R_INF_3"],
                "release": [{"when": "TURNS_ELAPSED", "turns": 3, "since": 1}],
                "win": [{"when": "TURNS_ELAPSED", "turns": 3, "since": 1}],
                "lose": [{"when": "FORCE_STRENGTH_BELOW", "fraction": 0.45}],
                "abort": [{"when": "HQ_THREATENED"}],
                "next": "P2",
                "on_fail": "EMERGENCY"
            },
            {
                "id": "P2",
                "name": "COUNTER-OFFENSIVE",
                "purpose": "Release fresh reserve infantry to lead decisive counter-blow.",
                "missions": [
                    {
                        "task": "ATTACK",
                        "area": "CENTER",
                        "units": ["R_INF_3", "R_INF_1", "R_INF_2", "R_SCT_1"],
                        "vs": "ANY",
                        "win": [{"when": "TURNS_ELAPSED", "turns": 6, "since": 1}],
                        "stop": [{"when": "HQ_THREATENED"}],
                        "preserve": False
                    }
                ],
                "win": [{"when": "TURNS_ELAPSED", "turns": 6, "since": 1}],
                "lose": [{"when": "FORCE_STRENGTH_BELOW", "fraction": 0.3}],
                "abort": [{"when": "HQ_THREATENED"}],
                "next": "END",
                "on_fail": "HOLD"
            }
        ],
        "abort": [{"when": "FORCE_STRENGTH_BELOW", "fraction": 0.25}],
        "branches": [
            {
                "id": "B1",
                "if": "Frontline pressured prematurely",
                "when": {"when": "FORCE_STRENGTH_BELOW", "fraction": 0.6},
                "then": "RELEASE_RESERVE"
            }
        ]
    }

    # S2 V5: Reserve-Heavy Staged Commitment
    p2_v5 = {
        "objective": "Advance with vanguard infantry while holding reserve for decisive commitment.",
        "cadence": 3,
        "doctrine": [0.6, 0.5, 0.6, 0.6, 0.8, 0.3],
        "phases": [
            {
                "id": "P1",
                "name": "INITIAL ADVANCE",
                "purpose": "Vanguard presses forward while reserve stays in ready position.",
                "missions": [
                    {
                        "task": "ADVANCE",
                        "area": "CENTER",
                        "units": ["R_INF_1", "R_INF_2", "R_SCT_1"],
                        "vs": "INFANTRY",
                        "win": [{"when": "TURNS_ELAPSED", "turns": 2, "since": 1}],
                        "stop": [{"when": "FORCE_STRENGTH_BELOW", "fraction": 0.5}],
                        "preserve": True
                    }
                ],
                "reserve": ["R_INF_3"],
                "release": [{"when": "TURNS_ELAPSED", "turns": 2, "since": 1}],
                "win": [{"when": "TURNS_ELAPSED", "turns": 2, "since": 1}],
                "lose": [{"when": "FORCE_STRENGTH_BELOW", "fraction": 0.45}],
                "abort": [{"when": "HQ_THREATENED"}],
                "next": "P2",
                "on_fail": "HOLD"
            },
            {
                "id": "P2",
                "name": "MAIN BODY SURGE",
                "purpose": "Commit reserve infantry into center assault.",
                "missions": [
                    {
                        "task": "ATTACK",
                        "area": "CENTER",
                        "units": ["R_INF_1", "R_INF_2", "R_INF_3", "R_SCT_1"],
                        "vs": "ANY",
                        "win": [{"when": "TURNS_ELAPSED", "turns": 5, "since": 1}],
                        "stop": [{"when": "HQ_THREATENED"}],
                        "preserve": False
                    }
                ],
                "win": [{"when": "TURNS_ELAPSED", "turns": 5, "since": 1}],
                "lose": [{"when": "FORCE_STRENGTH_BELOW", "fraction": 0.3}],
                "abort": [{"when": "HQ_THREATENED"}],
                "next": "END",
                "on_fail": "HOLD"
            }
        ],
        "abort": [{"when": "FORCE_STRENGTH_BELOW", "fraction": 0.25}],
        "branches": [
            {
                "id": "B1",
                "if": "Vanguard heavily engaged",
                "when": {"when": "FORCE_STRENGTH_BELOW", "fraction": 0.55},
                "then": "RELEASE_RESERVE"
            }
        ]
    }

    for vid, p in [("V1", p2_v1), ("V2", p2_v2), ("V3", p2_v3), ("V4", p2_v4), ("V5", p2_v5)]:
        rows.append({"scenario_id": s2, "variant_id": vid, "plan": p})

    # =========================================================================
    # SCENARIO 3: csft_s00003 (BLUE, destroy_all_red)
    # Friendly non-HQ: B_INF_1, B_INF_2, B_SCT_1, B_SPE_1, B_SPE_2
    # Known enemy: R_CAV_1 (CENTER)
    # =========================================================================
    s3 = "csft_s00003"

    # S3 V1: Spearman Counter-Charge (Direct Pressure)
    p3_v1 = {
        "objective": "Lead with spearmen to impale visible enemy cavalry R_CAV_1 and roll up enemy center.",
        "cadence": 3,
        "doctrine": [0.85, 0.6, 0.8, 0.7, 0.2, 0.2],
        "phases": [
            {
                "id": "P1",
                "name": "SPEAR ASSAULT ON CAVALRY",
                "purpose": "Spearmen aggressively attack visible R_CAV_1 while infantry supports.",
                "missions": [
                    {
                        "task": "ATTACK",
                        "area": "CENTER",
                        "units": ["B_SPE_1", "B_SPE_2"],
                        "vs": "CAVALRY",
                        "win": [{"when": "TARGET_DESTROYED", "unit_id": "R_CAV_1"}],
                        "stop": [{"when": "HQ_THREATENED"}],
                        "preserve": False
                    },
                    {
                        "task": "ADVANCE",
                        "area": "CENTER",
                        "units": ["B_INF_1", "B_INF_2", "B_SCT_1"],
                        "vs": "INFANTRY",
                        "win": [{"when": "TURNS_ELAPSED", "turns": 3, "since": 1}],
                        "stop": [{"when": "HQ_THREATENED"}],
                        "preserve": False
                    }
                ],
                "win": [{"when": "TARGET_DESTROYED", "unit_id": "R_CAV_1"}],
                "lose": [{"when": "FORCE_STRENGTH_BELOW", "fraction": 0.45}],
                "abort": [{"when": "HQ_THREATENED"}],
                "next": "P2",
                "on_fail": "EMERGENCY"
            },
            {
                "id": "P2",
                "name": "EXPLOIT BREAKTHROUGH",
                "purpose": "Overrun remaining enemy positions once cavalry screen is destroyed.",
                "missions": [
                    {
                        "task": "ATTACK",
                        "area": "CENTER",
                        "units": ["B_INF_1", "B_INF_2", "B_SPE_1", "B_SPE_2", "B_SCT_1"],
                        "vs": "ANY",
                        "win": [{"when": "TURNS_ELAPSED", "turns": 5, "since": 1}],
                        "stop": [{"when": "HQ_THREATENED"}],
                        "preserve": False
                    }
                ],
                "win": [{"when": "TURNS_ELAPSED", "turns": 5, "since": 1}],
                "lose": [{"when": "FORCE_STRENGTH_BELOW", "fraction": 0.3}],
                "abort": [{"when": "HQ_THREATENED"}],
                "next": "END",
                "on_fail": "HOLD"
            }
        ],
        "abort": [{"when": "FORCE_STRENGTH_BELOW", "fraction": 0.25}]
    }

    # S3 V2: Spear Anchor & Infantry Envelopment (Fix & Flank)
    p3_v2 = {
        "objective": "Pin R_CAV_1 with spearmen in center while infantry outflanks to the north.",
        "cadence": 4,
        "doctrine": [0.6, 0.5, 0.6, 0.6, 0.4, 0.7],
        "phases": [
            {
                "id": "P1",
                "name": "FIX CAVALRY & NORTH FLANK",
                "purpose": "Spearmen fix R_CAV_1 while infantry sweeps north to strike enemy flank.",
                "missions": [
                    {
                        "task": "FIX",
                        "area": "CENTER",
                        "units": ["B_SPE_1", "B_SPE_2"],
                        "vs": "CAVALRY",
                        "win": [{"when": "TURNS_ELAPSED", "turns": 3, "since": 1}],
                        "stop": [{"when": "HQ_THREATENED"}],
                        "preserve": True
                    },
                    {
                        "task": "FLANK",
                        "area": "NORTH",
                        "units": ["B_INF_1", "B_INF_2", "B_SCT_1"],
                        "vs": "ANY",
                        "win": [{"when": "TURNS_ELAPSED", "turns": 3, "since": 1}],
                        "stop": [{"when": "FORCE_STRENGTH_BELOW", "fraction": 0.5}],
                        "preserve": False
                    }
                ],
                "win": [{"when": "TURNS_ELAPSED", "turns": 3, "since": 1}],
                "lose": [{"when": "FORCE_STRENGTH_BELOW", "fraction": 0.4}],
                "abort": [{"when": "HQ_THREATENED"}],
                "next": "P2",
                "on_fail": "HOLD"
            },
            {
                "id": "P2",
                "name": "CONVERGENT ANVIL CRUSH",
                "purpose": "Collapse opposing forces between spearmen and flanking infantry.",
                "missions": [
                    {
                        "task": "ATTACK",
                        "area": "CENTER",
                        "units": ["B_SPE_1", "B_SPE_2", "B_INF_1", "B_INF_2", "B_SCT_1"],
                        "vs": "ANY",
                        "win": [{"when": "TURNS_ELAPSED", "turns": 5, "since": 1}],
                        "stop": [{"when": "HQ_THREATENED"}],
                        "preserve": False
                    }
                ],
                "win": [{"when": "TURNS_ELAPSED", "turns": 5, "since": 1}],
                "lose": [{"when": "FORCE_STRENGTH_BELOW", "fraction": 0.3}],
                "abort": [{"when": "HQ_THREATENED"}],
                "next": "END",
                "on_fail": "EMERGENCY"
            }
        ],
        "abort": [{"when": "FORCE_STRENGTH_BELOW", "fraction": 0.25}]
    }

    # S3 V3: Recon Beyond Cavalry
    p3_v3 = {
        "objective": "Screen R_CAV_1 with spear line while scout slips past to expose enemy command.",
        "cadence": 3,
        "doctrine": [0.4, 0.4, 0.5, 0.4, 0.7, 0.8],
        "phases": [
            {
                "id": "P1",
                "name": "SCREEN & PROBE",
                "purpose": "Spearmen shield formation while scout infiltrates behind R_CAV_1.",
                "missions": [
                    {
                        "task": "FIX",
                        "area": "CENTER",
                        "units": ["B_SPE_1", "B_SPE_2"],
                        "vs": "CAVALRY",
                        "win": [{"when": "TURNS_ELAPSED", "turns": 2, "since": 1}],
                        "stop": [{"when": "HQ_THREATENED"}],
                        "preserve": True
                    },
                    {
                        "task": "RECON",
                        "area": "NORTH",
                        "units": ["B_SCT_1"],
                        "vs": "ANY",
                        "win": [{"when": "TURNS_ELAPSED", "turns": 2, "since": 1}],
                        "stop": [{"when": "FORCE_STRENGTH_BELOW", "fraction": 0.6}],
                        "preserve": True
                    },
                    {
                        "task": "HOLD",
                        "area": "CENTER",
                        "units": ["B_INF_1", "B_INF_2"],
                        "vs": "ANY",
                        "win": [{"when": "TURNS_ELAPSED", "turns": 2, "since": 1}],
                        "stop": [{"when": "HQ_THREATENED"}],
                        "preserve": True
                    }
                ],
                "win": [{"when": "TURNS_ELAPSED", "turns": 2, "since": 1}],
                "lose": [{"when": "FORCE_STRENGTH_BELOW", "fraction": 0.45}],
                "abort": [{"when": "HQ_THREATENED"}],
                "next": "P2",
                "on_fail": "HOLD"
            },
            {
                "id": "P2",
                "name": "PENETRATION ATTACK",
                "purpose": "Drive into exposed enemy positions discovered by recon.",
                "missions": [
                    {
                        "task": "ATTACK",
                        "area": "CENTER",
                        "units": ["B_SPE_1", "B_SPE_2", "B_INF_1", "B_INF_2", "B_SCT_1"],
                        "vs": "ANY",
                        "win": [{"when": "TURNS_ELAPSED", "turns": 5, "since": 1}],
                        "stop": [{"when": "HQ_THREATENED"}],
                        "preserve": False
                    }
                ],
                "win": [{"when": "TURNS_ELAPSED", "turns": 5, "since": 1}],
                "lose": [{"when": "FORCE_STRENGTH_BELOW", "fraction": 0.35}],
                "abort": [{"when": "HQ_THREATENED"}],
                "next": "END",
                "on_fail": "HOLD"
            }
        ],
        "abort": [{"when": "FORCE_STRENGTH_BELOW", "fraction": 0.25}],
        "branches": [
            {
                "id": "B1",
                "if": "R_CAV_1 retreats",
                "when": {"when": "TARGET_DESTROYED", "unit_id": "R_CAV_1"},
                "then": "REQUEST_REVIEW"
            }
        ]
    }

    # S3 V4: Defensive Trap Against Cavalry
    p3_v4 = {
        "objective": "Entice R_CAV_1 into charging braced spearmen in center, then destroy with counterattack.",
        "cadence": 4,
        "doctrine": [0.3, 0.3, 0.4, 0.3, 0.85, 0.6],
        "phases": [
            {
                "id": "P1",
                "name": "BRACED SPEAR WALL",
                "purpose": "Spearmen hold center line to absorb and impale charging cavalry.",
                "missions": [
                    {
                        "task": "HOLD",
                        "area": "CENTER",
                        "units": ["B_SPE_1", "B_SPE_2", "B_SCT_1"],
                        "vs": "CAVALRY",
                        "win": [{"when": "TARGET_DESTROYED", "unit_id": "R_CAV_1"}],
                        "stop": [{"when": "HQ_THREATENED"}],
                        "preserve": True
                    }
                ],
                "reserve": ["B_INF_1", "B_INF_2"],
                "release": [{"when": "TARGET_DESTROYED", "unit_id": "R_CAV_1"}],
                "win": [{"when": "TARGET_DESTROYED", "unit_id": "R_CAV_1"}],
                "lose": [{"when": "FORCE_STRENGTH_BELOW", "fraction": 0.45}],
                "abort": [{"when": "HQ_THREATENED"}],
                "next": "P2",
                "on_fail": "EMERGENCY"
            },
            {
                "id": "P2",
                "name": "COUNTER-ASSAULT",
                "purpose": "Unleash fresh infantry to sweep broken enemy formations.",
                "missions": [
                    {
                        "task": "ATTACK",
                        "area": "CENTER",
                        "units": ["B_INF_1", "B_INF_2", "B_SPE_1", "B_SPE_2", "B_SCT_1"],
                        "vs": "ANY",
                        "win": [{"when": "TURNS_ELAPSED", "turns": 6, "since": 1}],
                        "stop": [{"when": "HQ_THREATENED"}],
                        "preserve": False
                    }
                ],
                "win": [{"when": "TURNS_ELAPSED", "turns": 6, "since": 1}],
                "lose": [{"when": "FORCE_STRENGTH_BELOW", "fraction": 0.3}],
                "abort": [{"when": "HQ_THREATENED"}],
                "next": "END",
                "on_fail": "HOLD"
            }
        ],
        "abort": [{"when": "FORCE_STRENGTH_BELOW", "fraction": 0.25}],
        "branches": [
            {
                "id": "B1",
                "if": "Spear line heavily pressed",
                "when": {"when": "FORCE_STRENGTH_BELOW", "fraction": 0.6},
                "then": "RELEASE_RESERVE"
            }
        ]
    }

    # S3 V5: Reserve-Heavy Staged Commitment
    p3_v5 = {
        "objective": "Advance spearguard against R_CAV_1 while keeping infantry in reserve for second wave.",
        "cadence": 3,
        "doctrine": [0.6, 0.5, 0.6, 0.6, 0.9, 0.3],
        "phases": [
            {
                "id": "P1",
                "name": "SPEAR ENGAGEMENT",
                "purpose": "Engage R_CAV_1 with spear vanguard and scout screening.",
                "missions": [
                    {
                        "task": "ATTACK",
                        "area": "CENTER",
                        "units": ["B_SPE_1", "B_SPE_2", "B_SCT_1"],
                        "vs": "CAVALRY",
                        "win": [{"when": "TURNS_ELAPSED", "turns": 2, "since": 1}],
                        "stop": [{"when": "FORCE_STRENGTH_BELOW", "fraction": 0.5}],
                        "preserve": True
                    }
                ],
                "reserve": ["B_INF_1", "B_INF_2"],
                "release": [{"when": "TURNS_ELAPSED", "turns": 2, "since": 1}],
                "win": [{"when": "TURNS_ELAPSED", "turns": 2, "since": 1}],
                "lose": [{"when": "FORCE_STRENGTH_BELOW", "fraction": 0.45}],
                "abort": [{"when": "HQ_THREATENED"}],
                "next": "P2",
                "on_fail": "HOLD"
            },
            {
                "id": "P2",
                "name": "SECOND WAVE COMMITMENT",
                "purpose": "Commit reserve infantry alongside spearmen for total victory.",
                "missions": [
                    {
                        "task": "ATTACK",
                        "area": "CENTER",
                        "units": ["B_INF_1", "B_INF_2", "B_SPE_1", "B_SPE_2", "B_SCT_1"],
                        "vs": "ANY",
                        "win": [{"when": "TURNS_ELAPSED", "turns": 5, "since": 1}],
                        "stop": [{"when": "HQ_THREATENED"}],
                        "preserve": False
                    }
                ],
                "win": [{"when": "TURNS_ELAPSED", "turns": 5, "since": 1}],
                "lose": [{"when": "FORCE_STRENGTH_BELOW", "fraction": 0.3}],
                "abort": [{"when": "HQ_THREATENED"}],
                "next": "END",
                "on_fail": "EMERGENCY"
            }
        ],
        "abort": [{"when": "FORCE_STRENGTH_BELOW", "fraction": 0.25}],
        "branches": [
            {
                "id": "B1",
                "if": "Spearmen require urgent reinforcement",
                "when": {"when": "FORCE_STRENGTH_BELOW", "fraction": 0.55},
                "then": "RELEASE_RESERVE"
            }
        ]
    }

    for vid, p in [("V1", p3_v1), ("V2", p3_v2), ("V3", p3_v3), ("V4", p3_v4), ("V5", p3_v5)]:
        rows.append({"scenario_id": s3, "variant_id": vid, "plan": p})

    # =========================================================================
    # SCENARIO 4: csft_s00004 (RED, destroy_all_red)
    # Friendly non-HQ: R_ARC_1, R_ARC_2, R_CAV_1, R_CAV_2, R_INF_1, R_SCT_1, R_SIE_1, R_SPE_1
    # Known enemy: B_ARC_1, B_INF_1, B_SCT_1, B_SPE_1 (all CENTER)
    # =========================================================================
    s4 = "csft_s00004"

    # S4 V1: Combined Arms Center Breakthrough (Direct Pressure)
    p4_v1 = {
        "objective": "Concentrate siege, archers, and heavy cavalry to smash the visible enemy center group.",
        "cadence": 3,
        "doctrine": [0.85, 0.7, 0.8, 0.8, 0.2, 0.2],
        "phases": [
            {
                "id": "P1",
                "name": "BOMBARDMENT & CAVALRY CHARGE",
                "purpose": "Softly bombard center and charge cavalry into B_ARC_1 and B_INF_1.",
                "missions": [
                    {
                        "task": "ATTACK",
                        "area": "CENTER",
                        "units": ["R_ARC_1", "R_ARC_2", "R_SIE_1"],
                        "vs": "INFANTRY",
                        "win": [{"when": "TURNS_ELAPSED", "turns": 2, "since": 1}],
                        "stop": [{"when": "HQ_THREATENED"}],
                        "preserve": True
                    },
                    {
                        "task": "ATTACK",
                        "area": "CENTER",
                        "units": ["R_CAV_1", "R_CAV_2", "R_INF_1", "R_SPE_1", "R_SCT_1"],
                        "vs": "ARCHER",
                        "win": [{"when": "TARGET_DESTROYED", "unit_id": "B_ARC_1"}],
                        "stop": [{"when": "HQ_THREATENED"}],
                        "preserve": False
                    }
                ],
                "win": [{"when": "TARGET_DESTROYED", "unit_id": "B_ARC_1"}],
                "lose": [{"when": "FORCE_STRENGTH_BELOW", "fraction": 0.45}],
                "abort": [{"when": "HQ_THREATENED"}],
                "next": "P2",
                "on_fail": "EMERGENCY"
            },
            {
                "id": "P2",
                "name": "TOTAL ANNIHILATION",
                "purpose": "Overrun remaining enemy spearmen and infantry in center.",
                "missions": [
                    {
                        "task": "ATTACK",
                        "area": "CENTER",
                        "units": ["R_CAV_1", "R_CAV_2", "R_INF_1", "R_SPE_1", "R_ARC_1", "R_ARC_2", "R_SIE_1", "R_SCT_1"],
                        "vs": "ANY",
                        "win": [{"when": "TURNS_ELAPSED", "turns": 5, "since": 1}],
                        "stop": [{"when": "HQ_THREATENED"}],
                        "preserve": False
                    }
                ],
                "win": [{"when": "TURNS_ELAPSED", "turns": 5, "since": 1}],
                "lose": [{"when": "FORCE_STRENGTH_BELOW", "fraction": 0.3}],
                "abort": [{"when": "HQ_THREATENED"}],
                "next": "END",
                "on_fail": "HOLD"
            }
        ],
        "abort": [{"when": "FORCE_STRENGTH_BELOW", "fraction": 0.25}]
    }

    # S4 V2: Double Flank Envelopment
    p4_v2 = {
        "objective": "Fix enemy center with siege and infantry while cavalry pair envelops from south and north.",
        "cadence": 4,
        "doctrine": [0.65, 0.5, 0.65, 0.7, 0.4, 0.7],
        "phases": [
            {
                "id": "P1",
                "name": "CENTER PIN & DUAL WING FLANK",
                "purpose": "Pin center with ranged-infantry base while cavalry sweeps wings.",
                "missions": [
                    {
                        "task": "FIX",
                        "area": "CENTER",
                        "units": ["R_INF_1", "R_SPE_1", "R_SIE_1", "R_ARC_1"],
                        "vs": "INFANTRY",
                        "win": [{"when": "TURNS_ELAPSED", "turns": 3, "since": 1}],
                        "stop": [{"when": "HQ_THREATENED"}],
                        "preserve": True
                    },
                    {
                        "task": "FLANK",
                        "area": "SOUTH",
                        "units": ["R_CAV_2", "R_SCT_1"],
                        "vs": "ARCHER",
                        "win": [{"when": "TURNS_ELAPSED", "turns": 3, "since": 1}],
                        "stop": [{"when": "FORCE_STRENGTH_BELOW", "fraction": 0.5}],
                        "preserve": False
                    },
                    {
                        "task": "FLANK",
                        "area": "NORTH",
                        "units": ["R_CAV_1", "R_ARC_2"],
                        "vs": "ANY",
                        "win": [{"when": "TURNS_ELAPSED", "turns": 3, "since": 1}],
                        "stop": [{"when": "FORCE_STRENGTH_BELOW", "fraction": 0.5}],
                        "preserve": False
                    }
                ],
                "win": [{"when": "TURNS_ELAPSED", "turns": 3, "since": 1}],
                "lose": [{"when": "FORCE_STRENGTH_BELOW", "fraction": 0.4}],
                "abort": [{"when": "HQ_THREATENED"}],
                "next": "P2",
                "on_fail": "HOLD"
            },
            {
                "id": "P2",
                "name": "COLLAPSE WINGS ON CENTER",
                "purpose": "Execute simultaneous strike from both wings onto pinned enemy cluster.",
                "missions": [
                    {
                        "task": "ATTACK",
                        "area": "CENTER",
                        "units": ["R_CAV_1", "R_CAV_2", "R_INF_1", "R_SPE_1", "R_ARC_1", "R_ARC_2", "R_SIE_1", "R_SCT_1"],
                        "vs": "ANY",
                        "win": [{"when": "TURNS_ELAPSED", "turns": 5, "since": 1}],
                        "stop": [{"when": "HQ_THREATENED"}],
                        "preserve": False
                    }
                ],
                "win": [{"when": "TURNS_ELAPSED", "turns": 5, "since": 1}],
                "lose": [{"when": "FORCE_STRENGTH_BELOW", "fraction": 0.3}],
                "abort": [{"when": "HQ_THREATENED"}],
                "next": "END",
                "on_fail": "EMERGENCY"
            }
        ],
        "abort": [{"when": "FORCE_STRENGTH_BELOW", "fraction": 0.25}]
    }

    # S4 V3: Ranged Attrition & Standoff
    p4_v3 = {
        "objective": "Batter known hostile formations from distance with siege and archers before moving in.",
        "cadence": 3,
        "doctrine": [0.4, 0.4, 0.5, 0.4, 0.7, 0.7],
        "phases": [
            {
                "id": "P1",
                "name": "STANDOFF BOMBARDMENT",
                "purpose": "Archers and siege soften B_INF_1 and B_SPE_1 while spearman and cavalry screen.",
                "missions": [
                    {
                        "task": "ATTACK",
                        "area": "CENTER",
                        "units": ["R_SIE_1", "R_ARC_1", "R_ARC_2"],
                        "vs": "INFANTRY",
                        "win": [{"when": "TURNS_ELAPSED", "turns": 3, "since": 1}],
                        "stop": [{"when": "HQ_THREATENED"}],
                        "preserve": True
                    },
                    {
                        "task": "HOLD",
                        "area": "CENTER",
                        "units": ["R_SPE_1", "R_INF_1"],
                        "vs": "CAVALRY",
                        "win": [{"when": "TURNS_ELAPSED", "turns": 3, "since": 1}],
                        "stop": [{"when": "HQ_THREATENED"}],
                        "preserve": True
                    },
                    {
                        "task": "RECON",
                        "area": "SOUTH",
                        "units": ["R_CAV_1", "R_CAV_2", "R_SCT_1"],
                        "vs": "ANY",
                        "win": [{"when": "TURNS_ELAPSED", "turns": 3, "since": 1}],
                        "stop": [{"when": "FORCE_STRENGTH_BELOW", "fraction": 0.5}],
                        "preserve": True
                    }
                ],
                "win": [{"when": "TURNS_ELAPSED", "turns": 3, "since": 1}],
                "lose": [{"when": "FORCE_STRENGTH_BELOW", "fraction": 0.45}],
                "abort": [{"when": "HQ_THREATENED"}],
                "next": "P2",
                "on_fail": "HOLD"
            },
            {
                "id": "P2",
                "name": "ADVANCE OVER WEAKENED ENEMY",
                "purpose": "Move frontline forward to finish off depleted enemy units.",
                "missions": [
                    {
                        "task": "ATTACK",
                        "area": "CENTER",
                        "units": ["R_INF_1", "R_SPE_1", "R_CAV_1", "R_CAV_2", "R_ARC_1", "R_ARC_2", "R_SIE_1", "R_SCT_1"],
                        "vs": "ANY",
                        "win": [{"when": "TURNS_ELAPSED", "turns": 5, "since": 1}],
                        "stop": [{"when": "HQ_THREATENED"}],
                        "preserve": False
                    }
                ],
                "win": [{"when": "TURNS_ELAPSED", "turns": 5, "since": 1}],
                "lose": [{"when": "FORCE_STRENGTH_BELOW", "fraction": 0.3}],
                "abort": [{"when": "HQ_THREATENED"}],
                "next": "END",
                "on_fail": "HOLD"
            }
        ],
        "abort": [{"when": "FORCE_STRENGTH_BELOW", "fraction": 0.25}],
        "branches": [
            {
                "id": "B1",
                "if": "Hostile cavalry charges siege line",
                "when": {"when": "ENEMY_CLASS_DETECTED", "class": "CAVALRY", "region": "CENTER"},
                "then": "REQUEST_REVIEW"
            }
        ]
    }

    # S4 V4: Entrenched Defense & Counterattack
    p4_v4 = {
        "objective": "Fortify around center position, absorb enemy advance, and deliver crushing counter-assault.",
        "cadence": 4,
        "doctrine": [0.3, 0.3, 0.4, 0.3, 0.85, 0.5],
        "phases": [
            {
                "id": "P1",
                "name": "DEFENSIVE FORTIFICATION",
                "purpose": "Hold center spear-infantry line with archer backing while keeping cavalry in reserve.",
                "missions": [
                    {
                        "task": "HOLD",
                        "area": "CENTER",
                        "units": ["R_SPE_1", "R_INF_1", "R_ARC_1", "R_ARC_2", "R_SIE_1", "R_SCT_1"],
                        "vs": "ANY",
                        "win": [{"when": "TURNS_ELAPSED", "turns": 3, "since": 1}],
                        "stop": [{"when": "HQ_THREATENED"}],
                        "preserve": True
                    }
                ],
                "reserve": ["R_CAV_1", "R_CAV_2"],
                "release": [{"when": "TURNS_ELAPSED", "turns": 3, "since": 1}],
                "win": [{"when": "TURNS_ELAPSED", "turns": 3, "since": 1}],
                "lose": [{"when": "FORCE_STRENGTH_BELOW", "fraction": 0.45}],
                "abort": [{"when": "HQ_THREATENED"}],
                "next": "P2",
                "on_fail": "EMERGENCY"
            },
            {
                "id": "P2",
                "name": "MOUNTED COUNTERATTACK",
                "purpose": "Release fresh cavalry wings into disrupted enemy attackers.",
                "missions": [
                    {
                        "task": "ATTACK",
                        "area": "CENTER",
                        "units": ["R_CAV_1", "R_CAV_2", "R_INF_1", "R_SPE_1", "R_ARC_1", "R_ARC_2", "R_SIE_1", "R_SCT_1"],
                        "vs": "ANY",
                        "win": [{"when": "TURNS_ELAPSED", "turns": 6, "since": 1}],
                        "stop": [{"when": "HQ_THREATENED"}],
                        "preserve": False
                    }
                ],
                "win": [{"when": "TURNS_ELAPSED", "turns": 6, "since": 1}],
                "lose": [{"when": "FORCE_STRENGTH_BELOW", "fraction": 0.3}],
                "abort": [{"when": "HQ_THREATENED"}],
                "next": "END",
                "on_fail": "HOLD"
            }
        ],
        "abort": [{"when": "FORCE_STRENGTH_BELOW", "fraction": 0.25}],
        "branches": [
            {
                "id": "B1",
                "if": "Frontline taking excessive casualties",
                "when": {"when": "FORCE_STRENGTH_BELOW", "fraction": 0.55},
                "then": "RELEASE_RESERVE"
            }
        ]
    }

    # S4 V5: Reserve Shock Deployment
    p4_v5 = {
        "objective": "Advance infantry and siege to pin enemy center; hold paired cavalry in reserve for flank strike.",
        "cadence": 3,
        "doctrine": [0.65, 0.5, 0.65, 0.7, 0.9, 0.3],
        "phases": [
            {
                "id": "P1",
                "name": "FIXING ASSAULT",
                "purpose": "Frontline units engage B_INF_1 and B_SPE_1 in center while holding cavalry reserve.",
                "missions": [
                    {
                        "task": "FIX",
                        "area": "CENTER",
                        "units": ["R_INF_1", "R_SPE_1", "R_SIE_1", "R_ARC_1", "R_ARC_2", "R_SCT_1"],
                        "vs": "INFANTRY",
                        "win": [{"when": "TURNS_ELAPSED", "turns": 2, "since": 1}],
                        "stop": [{"when": "FORCE_STRENGTH_BELOW", "fraction": 0.5}],
                        "preserve": True
                    }
                ],
                "reserve": ["R_CAV_1", "R_CAV_2"],
                "release": [{"when": "TURNS_ELAPSED", "turns": 2, "since": 1}],
                "win": [{"when": "TURNS_ELAPSED", "turns": 2, "since": 1}],
                "lose": [{"when": "FORCE_STRENGTH_BELOW", "fraction": 0.45}],
                "abort": [{"when": "HQ_THREATENED"}],
                "next": "P2",
                "on_fail": "HOLD"
            },
            {
                "id": "P2",
                "name": "DECISIVE CHARGE",
                "purpose": "Unleash cavalry reserves directly into vulnerable archer and scout positions.",
                "missions": [
                    {
                        "task": "ATTACK",
                        "area": "CENTER",
                        "units": ["R_CAV_1", "R_CAV_2", "R_INF_1", "R_SPE_1", "R_ARC_1", "R_ARC_2", "R_SIE_1", "R_SCT_1"],
                        "vs": "ARCHER",
                        "win": [{"when": "TURNS_ELAPSED", "turns": 5, "since": 1}],
                        "stop": [{"when": "HQ_THREATENED"}],
                        "preserve": False
                    }
                ],
                "win": [{"when": "TURNS_ELAPSED", "turns": 5, "since": 1}],
                "lose": [{"when": "FORCE_STRENGTH_BELOW", "fraction": 0.3}],
                "abort": [{"when": "HQ_THREATENED"}],
                "next": "END",
                "on_fail": "EMERGENCY"
            }
        ],
        "abort": [{"when": "FORCE_STRENGTH_BELOW", "fraction": 0.25}],
        "branches": [
            {
                "id": "B1",
                "if": "Early enemy collapse detected",
                "when": {"when": "TARGET_DESTROYED", "unit_id": "B_INF_1"},
                "then": "RELEASE_RESERVE"
            }
        ]
    }

    for vid, p in [("V1", p4_v1), ("V2", p4_v2), ("V3", p4_v3), ("V4", p4_v4), ("V5", p4_v5)]:
        rows.append({"scenario_id": s4, "variant_id": vid, "plan": p})

    # =========================================================================
    # SCENARIO 5: csft_s00005 (BLUE, destroy_all_red)
    # Friendly non-HQ: B_CAV_1, B_CAV_2, B_CAV_3, B_INF_1, B_INF_2, B_INF_3, B_SCT_1, B_SPE_1, B_SPE_2
    # Known enemy: R_ARC_1, R_CAV_1, R_CAV_2, R_CAV_3, R_INF_1, R_INF_3
    # =========================================================================
    s5 = "csft_s00005"

    # S5 V1: Direct Aggressive Pressure (Counter-Cavalry Blitz)
    p5_v1 = {
        "objective": "Lead with spearmen in center to break opposing cavalry while friendly horse hits R_ARC_1.",
        "cadence": 3,
        "doctrine": [0.85, 0.7, 0.8, 0.8, 0.2, 0.2],
        "phases": [
            {
                "id": "P1",
                "name": "CAVALRY INTERCEPTION",
                "purpose": "Spearmen spearhead center against enemy cavalry while cavalry sweeps north.",
                "missions": [
                    {
                        "task": "ATTACK",
                        "area": "CENTER",
                        "units": ["B_SPE_1", "B_SPE_2", "B_INF_3", "B_SCT_1"],
                        "vs": "CAVALRY",
                        "win": [{"when": "TURNS_ELAPSED", "turns": 3, "since": 1}],
                        "stop": [{"when": "HQ_THREATENED"}],
                        "preserve": False
                    },
                    {
                        "task": "ATTACK",
                        "area": "NORTH",
                        "units": ["B_CAV_1", "B_CAV_2", "B_CAV_3", "B_INF_1", "B_INF_2"],
                        "vs": "INFANTRY",
                        "win": [{"when": "TURNS_ELAPSED", "turns": 3, "since": 1}],
                        "stop": [{"when": "HQ_THREATENED"}],
                        "preserve": False
                    }
                ],
                "win": [{"when": "TURNS_ELAPSED", "turns": 3, "since": 1}],
                "lose": [{"when": "FORCE_STRENGTH_BELOW", "fraction": 0.45}],
                "abort": [{"when": "HQ_THREATENED"}],
                "next": "P2",
                "on_fail": "EMERGENCY"
            },
            {
                "id": "P2",
                "name": "TOTAL CONVERGENCE",
                "purpose": "Converge all forces to eliminate remaining enemy infantry and archers.",
                "missions": [
                    {
                        "task": "ATTACK",
                        "area": "CENTER",
                        "units": ["B_CAV_1", "B_CAV_2", "B_CAV_3", "B_INF_1", "B_INF_2", "B_INF_3", "B_SPE_1", "B_SPE_2", "B_SCT_1"],
                        "vs": "ANY",
                        "win": [{"when": "TURNS_ELAPSED", "turns": 5, "since": 1}],
                        "stop": [{"when": "HQ_THREATENED"}],
                        "preserve": False
                    }
                ],
                "win": [{"when": "TURNS_ELAPSED", "turns": 5, "since": 1}],
                "lose": [{"when": "FORCE_STRENGTH_BELOW", "fraction": 0.3}],
                "abort": [{"when": "HQ_THREATENED"}],
                "next": "END",
                "on_fail": "HOLD"
            }
        ],
        "abort": [{"when": "FORCE_STRENGTH_BELOW", "fraction": 0.25}]
    }

    # S5 V2: Center Anchor with North Flank Envelopment
    p5_v2 = {
        "objective": "Lock enemy center with spearmen and infantry while triple cavalry sweeps North flank.",
        "cadence": 4,
        "doctrine": [0.65, 0.5, 0.65, 0.7, 0.4, 0.7],
        "phases": [
            {
                "id": "P1",
                "name": "SPEAR ANCHOR & CAVALRY SWEEP",
                "purpose": "Spearmen fix enemy cavalry center while cavalry mass sweeps around north wing.",
                "missions": [
                    {
                        "task": "FIX",
                        "area": "CENTER",
                        "units": ["B_SPE_1", "B_SPE_2", "B_INF_3"],
                        "vs": "CAVALRY",
                        "win": [{"when": "TURNS_ELAPSED", "turns": 3, "since": 1}],
                        "stop": [{"when": "HQ_THREATENED"}],
                        "preserve": True
                    },
                    {
                        "task": "FLANK",
                        "area": "NORTH",
                        "units": ["B_CAV_1", "B_CAV_2", "B_CAV_3", "B_INF_1", "B_INF_2", "B_SCT_1"],
                        "vs": "INFANTRY",
                        "win": [{"when": "TURNS_ELAPSED", "turns": 3, "since": 1}],
                        "stop": [{"when": "FORCE_STRENGTH_BELOW", "fraction": 0.5}],
                        "preserve": False
                    }
                ],
                "win": [{"when": "TURNS_ELAPSED", "turns": 3, "since": 1}],
                "lose": [{"when": "FORCE_STRENGTH_BELOW", "fraction": 0.4}],
                "abort": [{"when": "HQ_THREATENED"}],
                "next": "P2",
                "on_fail": "HOLD"
            },
            {
                "id": "P2",
                "name": "REAR ENVELOPMENT",
                "purpose": "Cavalry crashes into enemy rear archer R_ARC_1 and breaks center.",
                "missions": [
                    {
                        "task": "ATTACK",
                        "area": "CENTER",
                        "units": ["B_CAV_1", "B_CAV_2", "B_CAV_3", "B_INF_1", "B_INF_2", "B_INF_3", "B_SPE_1", "B_SPE_2", "B_SCT_1"],
                        "vs": "ANY",
                        "win": [{"when": "TURNS_ELAPSED", "turns": 5, "since": 1}],
                        "stop": [{"when": "HQ_THREATENED"}],
                        "preserve": False
                    }
                ],
                "win": [{"when": "TURNS_ELAPSED", "turns": 5, "since": 1}],
                "lose": [{"when": "FORCE_STRENGTH_BELOW", "fraction": 0.3}],
                "abort": [{"when": "HQ_THREATENED"}],
                "next": "END",
                "on_fail": "EMERGENCY"
            }
        ],
        "abort": [{"when": "FORCE_STRENGTH_BELOW", "fraction": 0.25}]
    }

    # S5 V3: Recon & Delaying Actions
    p5_v3 = {
        "objective": "Screen enemy cavalry moves with scout and light cavalry before committing main battle group.",
        "cadence": 3,
        "doctrine": [0.4, 0.4, 0.5, 0.4, 0.7, 0.8],
        "phases": [
            {
                "id": "P1",
                "name": "CAVALRY SCREENING",
                "purpose": "Screen center and north corridors to monitor enemy cavalry concentration.",
                "missions": [
                    {
                        "task": "RECON",
                        "area": "CENTER",
                        "units": ["B_SCT_1", "B_CAV_1"],
                        "vs": "CAVALRY",
                        "win": [{"when": "TURNS_ELAPSED", "turns": 2, "since": 1}],
                        "stop": [{"when": "FORCE_STRENGTH_BELOW", "fraction": 0.6}],
                        "preserve": True
                    },
                    {
                        "task": "HOLD",
                        "area": "CENTER",
                        "units": ["B_SPE_1", "B_SPE_2", "B_INF_3"],
                        "vs": "CAVALRY",
                        "win": [{"when": "TURNS_ELAPSED", "turns": 2, "since": 1}],
                        "stop": [{"when": "HQ_THREATENED"}],
                        "preserve": True
                    },
                    {
                        "task": "HOLD",
                        "area": "NORTH",
                        "units": ["B_INF_1", "B_INF_2", "B_CAV_2", "B_CAV_3"],
                        "vs": "ANY",
                        "win": [{"when": "TURNS_ELAPSED", "turns": 2, "since": 1}],
                        "stop": [{"when": "HQ_THREATENED"}],
                        "preserve": True
                    }
                ],
                "win": [{"when": "TURNS_ELAPSED", "turns": 2, "since": 1}],
                "lose": [{"when": "FORCE_STRENGTH_BELOW", "fraction": 0.45}],
                "abort": [{"when": "HQ_THREATENED"}],
                "next": "P2",
                "on_fail": "HOLD"
            },
            {
                "id": "P2",
                "name": "COORDINATED COUNTER-STRIKE",
                "purpose": "Advance full army once enemy disposition is confirmed.",
                "missions": [
                    {
                        "task": "ATTACK",
                        "area": "CENTER",
                        "units": ["B_SPE_1", "B_SPE_2", "B_INF_1", "B_INF_2", "B_INF_3", "B_CAV_1", "B_CAV_2", "B_CAV_3", "B_SCT_1"],
                        "vs": "ANY",
                        "win": [{"when": "TURNS_ELAPSED", "turns": 5, "since": 1}],
                        "stop": [{"when": "HQ_THREATENED"}],
                        "preserve": False
                    }
                ],
                "win": [{"when": "TURNS_ELAPSED", "turns": 5, "since": 1}],
                "lose": [{"when": "FORCE_STRENGTH_BELOW", "fraction": 0.3}],
                "abort": [{"when": "HQ_THREATENED"}],
                "next": "END",
                "on_fail": "HOLD"
            }
        ],
        "abort": [{"when": "FORCE_STRENGTH_BELOW", "fraction": 0.25}],
        "branches": [
            {
                "id": "B1",
                "if": "Enemy cavalry surges North",
                "when": {"when": "ENEMY_CLASS_DETECTED", "class": "CAVALRY", "region": "NORTH"},
                "then": "REQUEST_REVIEW"
            }
        ]
    }

    # S5 V4: Anti-Cavalry Defensive Wall
    p5_v4 = {
        "objective": "Form unyielding spear-infantry defensive wall to break enemy cavalry charges, then counter.",
        "cadence": 4,
        "doctrine": [0.3, 0.3, 0.4, 0.3, 0.85, 0.5],
        "phases": [
            {
                "id": "P1",
                "name": "BRACED SPEAR WALL",
                "purpose": "Lock center and north avenues against opposing cavalry thrusts.",
                "missions": [
                    {
                        "task": "HOLD",
                        "area": "CENTER",
                        "units": ["B_SPE_1", "B_SPE_2", "B_INF_3", "B_SCT_1"],
                        "vs": "CAVALRY",
                        "win": [{"when": "TURNS_ELAPSED", "turns": 3, "since": 1}],
                        "stop": [{"when": "HQ_THREATENED"}],
                        "preserve": True
                    },
                    {
                        "task": "HOLD",
                        "area": "NORTH",
                        "units": ["B_INF_1", "B_INF_2"],
                        "vs": "INFANTRY",
                        "win": [{"when": "TURNS_ELAPSED", "turns": 3, "since": 1}],
                        "stop": [{"when": "HQ_THREATENED"}],
                        "preserve": True
                    }
                ],
                "reserve": ["B_CAV_1", "B_CAV_2", "B_CAV_3"],
                "release": [{"when": "TURNS_ELAPSED", "turns": 3, "since": 1}],
                "win": [{"when": "TURNS_ELAPSED", "turns": 3, "since": 1}],
                "lose": [{"when": "FORCE_STRENGTH_BELOW", "fraction": 0.45}],
                "abort": [{"when": "HQ_THREATENED"}],
                "next": "P2",
                "on_fail": "EMERGENCY"
            },
            {
                "id": "P2",
                "name": "DECISIVE CAVALRY COUNTER-CHARGE",
                "purpose": "Release triple cavalry reserve to shatter depleted enemy horse and infantry.",
                "missions": [
                    {
                        "task": "ATTACK",
                        "area": "CENTER",
                        "units": ["B_CAV_1", "B_CAV_2", "B_CAV_3", "B_SPE_1", "B_SPE_2", "B_INF_1", "B_INF_2", "B_INF_3", "B_SCT_1"],
                        "vs": "ANY",
                        "win": [{"when": "TURNS_ELAPSED", "turns": 6, "since": 1}],
                        "stop": [{"when": "HQ_THREATENED"}],
                        "preserve": False
                    }
                ],
                "win": [{"when": "TURNS_ELAPSED", "turns": 6, "since": 1}],
                "lose": [{"when": "FORCE_STRENGTH_BELOW", "fraction": 0.3}],
                "abort": [{"when": "HQ_THREATENED"}],
                "next": "END",
                "on_fail": "HOLD"
            }
        ],
        "abort": [{"when": "FORCE_STRENGTH_BELOW", "fraction": 0.25}],
        "branches": [
            {
                "id": "B1",
                "if": "Frontline taking excessive pressure",
                "when": {"when": "FORCE_STRENGTH_BELOW", "fraction": 0.55},
                "then": "RELEASE_RESERVE"
            }
        ]
    }

    # S5 V5: Reserve-Heavy Staged Echelon
    p5_v5 = {
        "objective": "Advance spear-infantry front to engage enemy lines; hold triple cavalry reserve for decisive flank.",
        "cadence": 3,
        "doctrine": [0.65, 0.5, 0.65, 0.7, 0.9, 0.3],
        "phases": [
            {
                "id": "P1",
                "name": "INFANTRY ENGAGEMENT",
                "purpose": "Hold enemy cavalry in place with spearmen and infantry while reserves stand by.",
                "missions": [
                    {
                        "task": "FIX",
                        "area": "CENTER",
                        "units": ["B_SPE_1", "B_SPE_2", "B_INF_3", "B_SCT_1"],
                        "vs": "CAVALRY",
                        "win": [{"when": "TURNS_ELAPSED", "turns": 2, "since": 1}],
                        "stop": [{"when": "FORCE_STRENGTH_BELOW", "fraction": 0.5}],
                        "preserve": True
                    },
                    {
                        "task": "ADVANCE",
                        "area": "NORTH",
                        "units": ["B_INF_1", "B_INF_2"],
                        "vs": "INFANTRY",
                        "win": [{"when": "TURNS_ELAPSED", "turns": 2, "since": 1}],
                        "stop": [{"when": "FORCE_STRENGTH_BELOW", "fraction": 0.5}],
                        "preserve": True
                    }
                ],
                "reserve": ["B_CAV_1", "B_CAV_2", "B_CAV_3"],
                "release": [{"when": "TURNS_ELAPSED", "turns": 2, "since": 1}],
                "win": [{"when": "TURNS_ELAPSED", "turns": 2, "since": 1}],
                "lose": [{"when": "FORCE_STRENGTH_BELOW", "fraction": 0.45}],
                "abort": [{"when": "HQ_THREATENED"}],
                "next": "P2",
                "on_fail": "HOLD"
            },
            {
                "id": "P2",
                "name": "TRIPLE CAVALRY SURGE",
                "purpose": "Commit all 3 cavalry units to envelop and overrun enemy formations.",
                "missions": [
                    {
                        "task": "ATTACK",
                        "area": "CENTER",
                        "units": ["B_CAV_1", "B_CAV_2", "B_CAV_3", "B_SPE_1", "B_SPE_2", "B_INF_1", "B_INF_2", "B_INF_3", "B_SCT_1"],
                        "vs": "ANY",
                        "win": [{"when": "TURNS_ELAPSED", "turns": 5, "since": 1}],
                        "stop": [{"when": "HQ_THREATENED"}],
                        "preserve": False
                    }
                ],
                "win": [{"when": "TURNS_ELAPSED", "turns": 5, "since": 1}],
                "lose": [{"when": "FORCE_STRENGTH_BELOW", "fraction": 0.3}],
                "abort": [{"when": "HQ_THREATENED"}],
                "next": "END",
                "on_fail": "EMERGENCY"
            }
        ],
        "abort": [{"when": "FORCE_STRENGTH_BELOW", "fraction": 0.25}],
        "branches": [
            {
                "id": "B1",
                "if": "Frontline infantry heavily pressured",
                "when": {"when": "FORCE_STRENGTH_BELOW", "fraction": 0.55},
                "then": "RELEASE_RESERVE"
            }
        ]
    }

    for vid, p in [("V1", p5_v1), ("V2", p5_v2), ("V3", p5_v3), ("V4", p5_v4), ("V5", p5_v5)]:
        rows.append({"scenario_id": s5, "variant_id": vid, "plan": p})

    # =========================================================================
    # SCENARIO 6: csft_s00006 (RED, survive_turns)
    # Friendly non-HQ: R_ARC_1, R_CAV_1, R_CAV_2, R_INF_1, R_SPE_1
    # Known enemy: []
    # =========================================================================
    s6 = "csft_s00006"

    # S6 V1: Mobile Preemptive Aggression
    p6_v1 = {
        "objective": "Launch mobile strike into center with double cavalry to disrupt approaching hostiles.",
        "cadence": 3,
        "doctrine": [0.85, 0.7, 0.8, 0.8, 0.2, 0.2],
        "phases": [
            {
                "id": "P1",
                "name": "CAVALRY INTERDICTION",
                "purpose": "Strike into center with paired cavalry backed by infantry and archer.",
                "missions": [
                    {
                        "task": "ATTACK",
                        "area": "CENTER",
                        "units": ["R_CAV_1", "R_CAV_2"],
                        "vs": "ANY",
                        "win": [{"when": "TURNS_ELAPSED", "turns": 3, "since": 1}],
                        "stop": [{"when": "HQ_THREATENED"}],
                        "preserve": False
                    },
                    {
                        "task": "ADVANCE",
                        "area": "CENTER",
                        "units": ["R_INF_1", "R_SPE_1", "R_ARC_1"],
                        "vs": "INFANTRY",
                        "win": [{"when": "TURNS_ELAPSED", "turns": 3, "since": 1}],
                        "stop": [{"when": "HQ_THREATENED"}],
                        "preserve": False
                    }
                ],
                "win": [{"when": "TURNS_ELAPSED", "turns": 3, "since": 1}],
                "lose": [{"when": "FORCE_STRENGTH_BELOW", "fraction": 0.45}],
                "abort": [{"when": "HQ_THREATENED"}],
                "next": "P2",
                "on_fail": "EMERGENCY"
            },
            {
                "id": "P2",
                "name": "DECISIVE ENGAGEMENT",
                "purpose": "Finish disrupted enemy formations to guarantee battle survival.",
                "missions": [
                    {
                        "task": "ATTACK",
                        "area": "CENTER",
                        "units": ["R_CAV_1", "R_CAV_2", "R_INF_1", "R_SPE_1", "R_ARC_1"],
                        "vs": "ANY",
                        "win": [{"when": "TURNS_ELAPSED", "turns": 6, "since": 1}],
                        "stop": [{"when": "HQ_THREATENED"}],
                        "preserve": False
                    }
                ],
                "win": [{"when": "TURNS_ELAPSED", "turns": 6, "since": 1}],
                "lose": [{"when": "FORCE_STRENGTH_BELOW", "fraction": 0.3}],
                "abort": [{"when": "HQ_THREATENED"}],
                "next": "END",
                "on_fail": "HOLD"
            }
        ],
        "abort": [{"when": "FORCE_STRENGTH_BELOW", "fraction": 0.25}]
    }

    # S6 V2: Center Anchor with Cavalry Outflank
    p6_v2 = {
        "objective": "Hold center with spear-infantry anchor while cavalry pair sweeps northern wing.",
        "cadence": 4,
        "doctrine": [0.65, 0.5, 0.65, 0.7, 0.4, 0.6],
        "phases": [
            {
                "id": "P1",
                "name": "CENTER ANCHOR & WING SWEEP",
                "purpose": "Spear and infantry pin hostiles in center while cavalry outflanks.",
                "missions": [
                    {
                        "task": "FIX",
                        "area": "CENTER",
                        "units": ["R_INF_1", "R_SPE_1", "R_ARC_1"],
                        "vs": "INFANTRY",
                        "win": [{"when": "TURNS_ELAPSED", "turns": 3, "since": 1}],
                        "stop": [{"when": "HQ_THREATENED"}],
                        "preserve": True
                    },
                    {
                        "task": "FLANK",
                        "area": "NORTH",
                        "units": ["R_CAV_1", "R_CAV_2"],
                        "vs": "ANY",
                        "win": [{"when": "TURNS_ELAPSED", "turns": 3, "since": 1}],
                        "stop": [{"when": "FORCE_STRENGTH_BELOW", "fraction": 0.5}],
                        "preserve": False
                    }
                ],
                "win": [{"when": "TURNS_ELAPSED", "turns": 3, "since": 1}],
                "lose": [{"when": "FORCE_STRENGTH_BELOW", "fraction": 0.4}],
                "abort": [{"when": "HQ_THREATENED"}],
                "next": "P2",
                "on_fail": "HOLD"
            },
            {
                "id": "P2",
                "name": "HAMMER AND ANVIL PINCH",
                "purpose": "Collapse opposing center between spear line and returning cavalry.",
                "missions": [
                    {
                        "task": "ATTACK",
                        "area": "CENTER",
                        "units": ["R_INF_1", "R_SPE_1", "R_ARC_1", "R_CAV_1", "R_CAV_2"],
                        "vs": "ANY",
                        "win": [{"when": "TURNS_ELAPSED", "turns": 6, "since": 1}],
                        "stop": [{"when": "HQ_THREATENED"}],
                        "preserve": False
                    }
                ],
                "win": [{"when": "TURNS_ELAPSED", "turns": 6, "since": 1}],
                "lose": [{"when": "FORCE_STRENGTH_BELOW", "fraction": 0.3}],
                "abort": [{"when": "HQ_THREATENED"}],
                "next": "END",
                "on_fail": "EMERGENCY"
            }
        ],
        "abort": [{"when": "FORCE_STRENGTH_BELOW", "fraction": 0.25}]
    }

    # S6 V3: Recon & Delaying Actions
    p6_v3 = {
        "objective": "Screen with light cavalry probe, then fall back to draw enemy into prepared defenses.",
        "cadence": 3,
        "doctrine": [0.4, 0.4, 0.5, 0.4, 0.7, 0.8],
        "phases": [
            {
                "id": "P1",
                "name": "PROBING SCREEN",
                "purpose": "Deploy single cavalry to scout ahead while main body holds defensive ground.",
                "missions": [
                    {
                        "task": "RECON",
                        "area": "CENTER",
                        "units": ["R_CAV_1"],
                        "vs": "ANY",
                        "win": [{"when": "TURNS_ELAPSED", "turns": 2, "since": 1}],
                        "stop": [{"when": "FORCE_STRENGTH_BELOW", "fraction": 0.6}],
                        "preserve": True
                    },
                    {
                        "task": "HOLD",
                        "area": "CENTER",
                        "units": ["R_INF_1", "R_SPE_1", "R_ARC_1", "R_CAV_2"],
                        "vs": "ANY",
                        "win": [{"when": "TURNS_ELAPSED", "turns": 2, "since": 1}],
                        "stop": [{"when": "HQ_THREATENED"}],
                        "preserve": True
                    }
                ],
                "win": [{"when": "TURNS_ELAPSED", "turns": 2, "since": 1}],
                "lose": [{"when": "FORCE_STRENGTH_BELOW", "fraction": 0.45}],
                "abort": [{"when": "HQ_THREATENED"}],
                "next": "P2",
                "on_fail": "HOLD"
            },
            {
                "id": "P2",
                "name": "ENGAGEMENT ON PREPARED GROUND",
                "purpose": "Engage overextended enemy formations with all ready troops.",
                "missions": [
                    {
                        "task": "ATTACK",
                        "area": "CENTER",
                        "units": ["R_INF_1", "R_SPE_1", "R_ARC_1", "R_CAV_1", "R_CAV_2"],
                        "vs": "ANY",
                        "win": [{"when": "TURNS_ELAPSED", "turns": 5, "since": 1}],
                        "stop": [{"when": "HQ_THREATENED"}],
                        "preserve": False
                    }
                ],
                "win": [{"when": "TURNS_ELAPSED", "turns": 5, "since": 1}],
                "lose": [{"when": "FORCE_STRENGTH_BELOW", "fraction": 0.35}],
                "abort": [{"when": "HQ_THREATENED"}],
                "next": "END",
                "on_fail": "HOLD"
            }
        ],
        "abort": [{"when": "FORCE_STRENGTH_BELOW", "fraction": 0.25}],
        "branches": [
            {
                "id": "B1",
                "if": "Heavy hostile cavalry detected",
                "when": {"when": "ENEMY_CLASS_DETECTED", "class": "CAVALRY", "region": "CENTER"},
                "then": "REQUEST_REVIEW"
            }
        ]
    }

    # S6 V4: Fortress Defense to Clock Expiration
    p6_v4 = {
        "objective": "Form tight defensive redoubt around HQ to survive until maximum turn limit.",
        "cadence": 5,
        "doctrine": [0.2, 0.2, 0.3, 0.2, 0.9, 0.3],
        "phases": [
            {
                "id": "P1",
                "name": "REDOUBT SHIELD",
                "purpose": "Form interlocking defensive perimeter with spearmen, infantry, and archers.",
                "missions": [
                    {
                        "task": "HOLD",
                        "area": "CENTER",
                        "units": ["R_SPE_1", "R_INF_1", "R_ARC_1"],
                        "vs": "ANY",
                        "win": [{"when": "TURNS_ELAPSED", "turns": 5, "since": 1}],
                        "stop": [{"when": "HQ_THREATENED"}],
                        "preserve": True
                    }
                ],
                "reserve": ["R_CAV_1", "R_CAV_2"],
                "release": [{"when": "HQ_THREATENED"}],
                "win": [{"when": "TURNS_ELAPSED", "turns": 5, "since": 1}],
                "lose": [{"when": "FORCE_STRENGTH_BELOW", "fraction": 0.45}],
                "abort": [{"when": "HQ_THREATENED"}],
                "next": "P2",
                "on_fail": "EMERGENCY"
            },
            {
                "id": "P2",
                "name": "FINAL STAND TO CLOCK",
                "purpose": "Maintain defensive hold until the turn limit delivers victory.",
                "missions": [
                    {
                        "task": "HOLD",
                        "area": "CENTER",
                        "units": ["R_SPE_1", "R_INF_1", "R_ARC_1", "R_CAV_1", "R_CAV_2"],
                        "vs": "ANY",
                        "win": [{"when": "TURNS_ELAPSED", "turns": 12, "since": 1}],
                        "stop": [{"when": "HQ_THREATENED"}],
                        "preserve": True
                    }
                ],
                "win": [{"when": "TURNS_ELAPSED", "turns": 12, "since": 1}],
                "lose": [{"when": "FORCE_STRENGTH_BELOW", "fraction": 0.35}],
                "abort": [{"when": "HQ_THREATENED"}],
                "next": "END",
                "on_fail": "EMERGENCY"
            }
        ],
        "abort": [{"when": "FORCE_STRENGTH_BELOW", "fraction": 0.25}],
        "branches": [
            {
                "id": "B1",
                "if": "HQ directly threatened",
                "when": {"when": "HQ_THREATENED"},
                "then": "RELEASE_RESERVE"
            }
        ]
    }

    # S6 V5: Reserve-Heavy Staged Commitment
    p6_v5 = {
        "objective": "Engage frontline with spear and archer screen; hold double cavalry in reserve for counterattack.",
        "cadence": 3,
        "doctrine": [0.65, 0.5, 0.65, 0.7, 0.9, 0.3],
        "phases": [
            {
                "id": "P1",
                "name": "VANGUARD DEFENSE",
                "purpose": "Anchor center with infantry and spearmen while holding cavalry wings back.",
                "missions": [
                    {
                        "task": "HOLD",
                        "area": "CENTER",
                        "units": ["R_INF_1", "R_SPE_1", "R_ARC_1"],
                        "vs": "ANY",
                        "win": [{"when": "TURNS_ELAPSED", "turns": 3, "since": 1}],
                        "stop": [{"when": "FORCE_STRENGTH_BELOW", "fraction": 0.5}],
                        "preserve": True
                    }
                ],
                "reserve": ["R_CAV_1", "R_CAV_2"],
                "release": [{"when": "TURNS_ELAPSED", "turns": 3, "since": 1}],
                "win": [{"when": "TURNS_ELAPSED", "turns": 3, "since": 1}],
                "lose": [{"when": "FORCE_STRENGTH_BELOW", "fraction": 0.45}],
                "abort": [{"when": "HQ_THREATENED"}],
                "next": "P2",
                "on_fail": "HOLD"
            },
            {
                "id": "P2",
                "name": "CAVALRY COUNTER-BLOW",
                "purpose": "Commit cavalry reserve to rout committed enemy troops.",
                "missions": [
                    {
                        "task": "ATTACK",
                        "area": "CENTER",
                        "units": ["R_CAV_1", "R_CAV_2", "R_INF_1", "R_SPE_1", "R_ARC_1"],
                        "vs": "ANY",
                        "win": [{"when": "TURNS_ELAPSED", "turns": 6, "since": 1}],
                        "stop": [{"when": "HQ_THREATENED"}],
                        "preserve": False
                    }
                ],
                "win": [{"when": "TURNS_ELAPSED", "turns": 6, "since": 1}],
                "lose": [{"when": "FORCE_STRENGTH_BELOW", "fraction": 0.3}],
                "abort": [{"when": "HQ_THREATENED"}],
                "next": "END",
                "on_fail": "EMERGENCY"
            }
        ],
        "abort": [{"when": "FORCE_STRENGTH_BELOW", "fraction": 0.25}],
        "branches": [
            {
                "id": "B1",
                "if": "Vanguard taking critical damage",
                "when": {"when": "FORCE_STRENGTH_BELOW", "fraction": 0.55},
                "then": "RELEASE_RESERVE"
            }
        ]
    }

    for vid, p in [("V1", p6_v1), ("V2", p6_v2), ("V3", p6_v3), ("V4", p6_v4), ("V5", p6_v5)]:
        rows.append({"scenario_id": s6, "variant_id": vid, "plan": p})

    # =========================================================================
    # SCENARIO 7: csft_s00007 (BLUE, destroy_all_red)
    # Friendly non-HQ: B_CAV_1, B_CAV_2, B_CAV_3, B_CON_1, B_INF_1, B_INF_2, B_SCT_1
    # Known enemy: []
    # =========================================================================
    s7 = "csft_s00007"

    # S7 V1: Triple Cavalry Blitz (Direct Pressure)
    p7_v1 = {
        "objective": "Execute immediate mass cavalry breakthrough through center supported by infantry push.",
        "cadence": 3,
        "doctrine": [0.9, 0.7, 0.85, 0.8, 0.15, 0.2],
        "phases": [
            {
                "id": "P1",
                "name": "CAVALRY BLITZ",
                "purpose": "All 3 cavalry units charge through center to shatter enemy vanguard.",
                "missions": [
                    {
                        "task": "ATTACK",
                        "area": "CENTER",
                        "units": ["B_CAV_1", "B_CAV_2", "B_CAV_3"],
                        "vs": "ANY",
                        "win": [{"when": "TURNS_ELAPSED", "turns": 3, "since": 1}],
                        "stop": [{"when": "HQ_THREATENED"}],
                        "preserve": False
                    },
                    {
                        "task": "ADVANCE",
                        "area": "CENTER",
                        "units": ["B_INF_1", "B_INF_2", "B_CON_1", "B_SCT_1"],
                        "vs": "INFANTRY",
                        "win": [{"when": "TURNS_ELAPSED", "turns": 3, "since": 1}],
                        "stop": [{"when": "HQ_THREATENED"}],
                        "preserve": False
                    }
                ],
                "win": [{"when": "TURNS_ELAPSED", "turns": 3, "since": 1}],
                "lose": [{"when": "FORCE_STRENGTH_BELOW", "fraction": 0.45}],
                "abort": [{"when": "HQ_THREATENED"}],
                "next": "P2",
                "on_fail": "EMERGENCY"
            },
            {
                "id": "P2",
                "name": "OVERRUN DEFENSES",
                "purpose": "Collapse opposing forces across center sector.",
                "missions": [
                    {
                        "task": "ATTACK",
                        "area": "CENTER",
                        "units": ["B_CAV_1", "B_CAV_2", "B_CAV_3", "B_INF_1", "B_INF_2", "B_CON_1", "B_SCT_1"],
                        "vs": "ANY",
                        "win": [{"when": "TURNS_ELAPSED", "turns": 5, "since": 1}],
                        "stop": [{"when": "HQ_THREATENED"}],
                        "preserve": False
                    }
                ],
                "win": [{"when": "TURNS_ELAPSED", "turns": 5, "since": 1}],
                "lose": [{"when": "FORCE_STRENGTH_BELOW", "fraction": 0.3}],
                "abort": [{"when": "HQ_THREATENED"}],
                "next": "END",
                "on_fail": "HOLD"
            }
        ],
        "abort": [{"when": "FORCE_STRENGTH_BELOW", "fraction": 0.25}]
    }

    # S7 V2: Center Fix & Pincer Cavalry Flank
    p7_v2 = {
        "objective": "Fix enemy front with infantry and conscripts while cavalry splits into north and south pincers.",
        "cadence": 4,
        "doctrine": [0.7, 0.5, 0.7, 0.7, 0.3, 0.7],
        "phases": [
            {
                "id": "P1",
                "name": "CENTER FIX & DUAL CAVALRY FLANKS",
                "purpose": "Infantry anchors center while cavalry envelops from both wings.",
                "missions": [
                    {
                        "task": "FIX",
                        "area": "CENTER",
                        "units": ["B_INF_1", "B_INF_2", "B_CON_1"],
                        "vs": "INFANTRY",
                        "win": [{"when": "TURNS_ELAPSED", "turns": 3, "since": 1}],
                        "stop": [{"when": "HQ_THREATENED"}],
                        "preserve": True
                    },
                    {
                        "task": "FLANK",
                        "area": "NORTH",
                        "units": ["B_CAV_1", "B_CAV_2"],
                        "vs": "ANY",
                        "win": [{"when": "TURNS_ELAPSED", "turns": 3, "since": 1}],
                        "stop": [{"when": "FORCE_STRENGTH_BELOW", "fraction": 0.5}],
                        "preserve": False
                    },
                    {
                        "task": "FLANK",
                        "area": "SOUTH",
                        "units": ["B_CAV_3", "B_SCT_1"],
                        "vs": "ANY",
                        "win": [{"when": "TURNS_ELAPSED", "turns": 3, "since": 1}],
                        "stop": [{"when": "FORCE_STRENGTH_BELOW", "fraction": 0.5}],
                        "preserve": False
                    }
                ],
                "win": [{"when": "TURNS_ELAPSED", "turns": 3, "since": 1}],
                "lose": [{"when": "FORCE_STRENGTH_BELOW", "fraction": 0.4}],
                "abort": [{"when": "HQ_THREATENED"}],
                "next": "P2",
                "on_fail": "HOLD"
            },
            {
                "id": "P2",
                "name": "CONVERGENT PINCER CRUSH",
                "purpose": "Crush trapped enemy between center line and both mounted wings.",
                "missions": [
                    {
                        "task": "ATTACK",
                        "area": "CENTER",
                        "units": ["B_CAV_1", "B_CAV_2", "B_CAV_3", "B_INF_1", "B_INF_2", "B_CON_1", "B_SCT_1"],
                        "vs": "ANY",
                        "win": [{"when": "TURNS_ELAPSED", "turns": 5, "since": 1}],
                        "stop": [{"when": "HQ_THREATENED"}],
                        "preserve": False
                    }
                ],
                "win": [{"when": "TURNS_ELAPSED", "turns": 5, "since": 1}],
                "lose": [{"when": "FORCE_STRENGTH_BELOW", "fraction": 0.3}],
                "abort": [{"when": "HQ_THREATENED"}],
                "next": "END",
                "on_fail": "EMERGENCY"
            }
        ],
        "abort": [{"when": "FORCE_STRENGTH_BELOW", "fraction": 0.25}]
    }

    # S7 V3: Recon First & Mobile Pursuit
    p7_v3 = {
        "objective": "Scout center with SCT_1 and CAV_3, then commit remaining cavalry once hostiles located.",
        "cadence": 3,
        "doctrine": [0.5, 0.4, 0.6, 0.5, 0.6, 0.8],
        "phases": [
            {
                "id": "P1",
                "name": "RECON PROBE",
                "purpose": "Probe forward with fast units while infantry maintains defensive screen.",
                "missions": [
                    {
                        "task": "RECON",
                        "area": "CENTER",
                        "units": ["B_SCT_1", "B_CAV_3"],
                        "vs": "ANY",
                        "win": [{"when": "TURNS_ELAPSED", "turns": 2, "since": 1}],
                        "stop": [{"when": "FORCE_STRENGTH_BELOW", "fraction": 0.6}],
                        "preserve": True
                    },
                    {
                        "task": "HOLD",
                        "area": "CENTER",
                        "units": ["B_INF_1", "B_INF_2", "B_CON_1"],
                        "vs": "ANY",
                        "win": [{"when": "TURNS_ELAPSED", "turns": 2, "since": 1}],
                        "stop": [{"when": "HQ_THREATENED"}],
                        "preserve": True
                    },
                    {
                        "task": "HOLD",
                        "area": "NORTH",
                        "units": ["B_CAV_1", "B_CAV_2"],
                        "vs": "ANY",
                        "win": [{"when": "TURNS_ELAPSED", "turns": 2, "since": 1}],
                        "stop": [{"when": "HQ_THREATENED"}],
                        "preserve": True
                    }
                ],
                "win": [{"when": "TURNS_ELAPSED", "turns": 2, "since": 1}],
                "lose": [{"when": "FORCE_STRENGTH_BELOW", "fraction": 0.45}],
                "abort": [{"when": "HQ_THREATENED"}],
                "next": "P2",
                "on_fail": "HOLD"
            },
            {
                "id": "P2",
                "name": "TARGETED CAVALRY PURSUIT",
                "purpose": "Assault located hostile elements with all available regiments.",
                "missions": [
                    {
                        "task": "ATTACK",
                        "area": "CENTER",
                        "units": ["B_CAV_1", "B_CAV_2", "B_CAV_3", "B_INF_1", "B_INF_2", "B_CON_1", "B_SCT_1"],
                        "vs": "ANY",
                        "win": [{"when": "TURNS_ELAPSED", "turns": 5, "since": 1}],
                        "stop": [{"when": "HQ_THREATENED"}],
                        "preserve": False
                    }
                ],
                "win": [{"when": "TURNS_ELAPSED", "turns": 5, "since": 1}],
                "lose": [{"when": "FORCE_STRENGTH_BELOW", "fraction": 0.3}],
                "abort": [{"when": "HQ_THREATENED"}],
                "next": "END",
                "on_fail": "HOLD"
            }
        ],
        "abort": [{"when": "FORCE_STRENGTH_BELOW", "fraction": 0.25}],
        "branches": [
            {
                "id": "B1",
                "if": "Heavy spearmen discovered in center",
                "when": {"when": "ENEMY_CLASS_DETECTED", "class": "SPEARMAN", "region": "CENTER"},
                "then": "REQUEST_REVIEW"
            }
        ]
    }

    # S7 V4: Defensive Perimeter & Counterattack
    p7_v4 = {
        "objective": "Form center shield with infantry and conscripts, absorb attack, then counter with cavalry.",
        "cadence": 4,
        "doctrine": [0.35, 0.3, 0.4, 0.3, 0.85, 0.5],
        "phases": [
            {
                "id": "P1",
                "name": "INFANTRY SCREEN",
                "purpose": "Anchor center with infantry and conscripts while holding full cavalry force in reserve.",
                "missions": [
                    {
                        "task": "HOLD",
                        "area": "CENTER",
                        "units": ["B_INF_1", "B_INF_2", "B_CON_1", "B_SCT_1"],
                        "vs": "ANY",
                        "win": [{"when": "TURNS_ELAPSED", "turns": 3, "since": 1}],
                        "stop": [{"when": "HQ_THREATENED"}],
                        "preserve": True
                    }
                ],
                "reserve": ["B_CAV_1", "B_CAV_2", "B_CAV_3"],
                "release": [{"when": "TURNS_ELAPSED", "turns": 3, "since": 1}],
                "win": [{"when": "TURNS_ELAPSED", "turns": 3, "since": 1}],
                "lose": [{"when": "FORCE_STRENGTH_BELOW", "fraction": 0.45}],
                "abort": [{"when": "HQ_THREATENED"}],
                "next": "P2",
                "on_fail": "EMERGENCY"
            },
            {
                "id": "P2",
                "name": "CAVALRY COUNTER-OFFENSIVE",
                "purpose": "Release fresh cavalry reserve to smash enemy forces engaged with our center.",
                "missions": [
                    {
                        "task": "ATTACK",
                        "area": "CENTER",
                        "units": ["B_CAV_1", "B_CAV_2", "B_CAV_3", "B_INF_1", "B_INF_2", "B_CON_1", "B_SCT_1"],
                        "vs": "ANY",
                        "win": [{"when": "TURNS_ELAPSED", "turns": 6, "since": 1}],
                        "stop": [{"when": "HQ_THREATENED"}],
                        "preserve": False
                    }
                ],
                "win": [{"when": "TURNS_ELAPSED", "turns": 6, "since": 1}],
                "lose": [{"when": "FORCE_STRENGTH_BELOW", "fraction": 0.3}],
                "abort": [{"when": "HQ_THREATENED"}],
                "next": "END",
                "on_fail": "HOLD"
            }
        ],
        "abort": [{"when": "FORCE_STRENGTH_BELOW", "fraction": 0.25}],
        "branches": [
            {
                "id": "B1",
                "if": "Frontline infantry heavily pressured",
                "when": {"when": "FORCE_STRENGTH_BELOW", "fraction": 0.55},
                "then": "RELEASE_RESERVE"
            }
        ]
    }

    # S7 V5: Reserve-Heavy Staged Commitment
    p7_v5 = {
        "objective": "Advance conscripts and infantry as vanguard; hold triple cavalry reserve for decisive flank surge.",
        "cadence": 3,
        "doctrine": [0.65, 0.5, 0.65, 0.7, 0.9, 0.3],
        "phases": [
            {
                "id": "P1",
                "name": "VANGUARD ADVANCE",
                "purpose": "Conscripts and infantry make initial contact in center while cavalry is held.",
                "missions": [
                    {
                        "task": "ADVANCE",
                        "area": "CENTER",
                        "units": ["B_CON_1", "B_INF_1", "B_INF_2", "B_SCT_1"],
                        "vs": "INFANTRY",
                        "win": [{"when": "TURNS_ELAPSED", "turns": 2, "since": 1}],
                        "stop": [{"when": "FORCE_STRENGTH_BELOW", "fraction": 0.5}],
                        "preserve": True
                    }
                ],
                "reserve": ["B_CAV_1", "B_CAV_2", "B_CAV_3"],
                "release": [{"when": "TURNS_ELAPSED", "turns": 2, "since": 1}],
                "win": [{"when": "TURNS_ELAPSED", "turns": 2, "since": 1}],
                "lose": [{"when": "FORCE_STRENGTH_BELOW", "fraction": 0.45}],
                "abort": [{"when": "HQ_THREATENED"}],
                "next": "P2",
                "on_fail": "HOLD"
            },
            {
                "id": "P2",
                "name": "RESERVE CAVALRY SURGE",
                "purpose": "Commit all 3 reserve cavalry units to exploit breach created by vanguard.",
                "missions": [
                    {
                        "task": "ATTACK",
                        "area": "CENTER",
                        "units": ["B_CAV_1", "B_CAV_2", "B_CAV_3", "B_CON_1", "B_INF_1", "B_INF_2", "B_SCT_1"],
                        "vs": "ANY",
                        "win": [{"when": "TURNS_ELAPSED", "turns": 5, "since": 1}],
                        "stop": [{"when": "HQ_THREATENED"}],
                        "preserve": False
                    }
                ],
                "win": [{"when": "TURNS_ELAPSED", "turns": 5, "since": 1}],
                "lose": [{"when": "FORCE_STRENGTH_BELOW", "fraction": 0.3}],
                "abort": [{"when": "HQ_THREATENED"}],
                "next": "END",
                "on_fail": "EMERGENCY"
            }
        ],
        "abort": [{"when": "FORCE_STRENGTH_BELOW", "fraction": 0.25}],
        "branches": [
            {
                "id": "B1",
                "if": "Vanguard taking heavy casualties early",
                "when": {"when": "FORCE_STRENGTH_BELOW", "fraction": 0.55},
                "then": "RELEASE_RESERVE"
            }
        ]
    }

    for vid, p in [("V1", p7_v1), ("V2", p7_v2), ("V3", p7_v3), ("V4", p7_v4), ("V5", p7_v5)]:
        rows.append({"scenario_id": s7, "variant_id": vid, "plan": p})

    return rows


def main() -> int:
    prompts_raw = json.loads(TRAIN_GEN.read_text(encoding="utf-8"))[:8]
    prompt_by_scen = {p["scenario"]["scenario_id"]: p for p in prompts_raw}

    rows = create_all_plans()
    print(f"Total candidate rows generated: {len(rows)}")

    # 1. Local Python P1-P11 coherence check
    coherence_failures = []
    for r in rows:
        sc_id = r["scenario_id"]
        vid = r["variant_id"]
        plan = r["plan"]
        plan_text = json.dumps(plan)
        doc, dups, err = RC._parse_direct(plan_text)
        if not isinstance(doc, dict):
            coherence_failures.append((sc_id, vid, f"Not direct JSON: {err}"))
            continue
        coh = RC.coherence_check(doc, dups.paths)
        if coh:
            coherence_failures.append((sc_id, vid, f"Coherence: {coh}"))

    if coherence_failures:
        print(f"FAILED local coherence checks: {len(coherence_failures)}")
        for sc_id, vid, err in coherence_failures:
            print(f"  {sc_id} {vid}: {err}")
        return 1
    print("ALL 40 rows PASSED local P1-P11 coherence checks!")

    # 2. Production Godot validation via harness
    items_to_validate = []
    for r in rows:
        sc_id = r["scenario_id"]
        vid = r["variant_id"]
        p_obj = prompt_by_scen[sc_id]
        items_to_validate.append({
            "id": f"{sc_id}_{vid}",
            "text": json.dumps(r["plan"]),
            "scenario": p_obj["scenario"]
        })

    print("Running Godot production validation harness...")
    results = H.validate(items_to_validate)
    godot_failures = []
    for item, res in zip(items_to_validate, results):
        if not (res["production_pass"] and res["strict_first_pass"] and res["plan_coherent"]):
            godot_failures.append((item["id"], res["category"], res.get("validator_detail") or res.get("fault_detail")))

    if godot_failures:
        print(f"FAILED Godot production validation: {len(godot_failures)}")
        for cid, cat, detail in godot_failures:
            print(f"  {cid}: cat={cat} detail={detail}")
        return 2

    print("ALL 40 rows PASSED Godot production validation (strict_first_pass=True, production_pass=True, plan_coherent=True)!")

    # 3. Write strictly formatted JSONL
    OUT_JSONL.parent.mkdir(parents=True, exist_ok=True)
    with open(OUT_JSONL, "w", encoding="utf-8") as f:
        for r in rows:
            line = json.dumps(r, ensure_ascii=False, separators=(",", ":"))
            f.write(line + "\n")

    print(f"Successfully wrote {len(rows)} verified JSONL lines to {OUT_JSONL}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
