"""Strict compact-authoring schema audit (training-data hygiene only).

Production silently IGNORES unknown/misplaced keys, so a target can pass the
real validator while carrying dead fields (e.g. a phase-level 'stop' or a
mission-level 'reserve') full of invented triggers or stale unit ids. Such
targets teach exactly the failures we are removing. This audit flags:
  UNKNOWN_KEY:<level>.<key>      key not in the victory_author_v1 contract
                                 (cloud2_victory_authoring.gd) at that level
  BAD_CONDITION:<path>           condition not a known trigger / {when,..}
It never modifies anything; builders exclude flagged rows.
"""
from __future__ import annotations

from typing import Any, List

from tools.contract_sft.repair import COND_PARAMS, TRIGGERS

ROOT_KEYS = {"objective", "end_state", "cadence", "doctrine", "phases", "abort", "branches", "hypotheses",
             "snapshot_id"}
PHASE_KEYS = {"id", "phase_id", "name", "purpose", "intent", "groups", "missions", "entry", "win", "lose",
              "abort", "next", "on_fail", "reserve", "release", "exploit", "priority"}
MISSION_KEYS = {"task", "area", "units", "vs", "target", "zone", "hold_fire", "pursue", "preserve", "spread",
                "win", "stop", "intent", "effects", "priority", "prefer", "roles", "coord", "limits", "support",
                "tag"}
BRANCH_KEYS = {"id", "branch_id", "name", "if", "if_text", "when", "then", "note"}
HYP_KEYS = {"h", "hypothesis", "conf", "confidence", "ev", "evidence"}
COND_KEYS = {"when", "trigger"} | set(COND_PARAMS)


def _cond(c: Any, path: str, out: List[str]) -> None:
    if isinstance(c, str):
        if c.strip().upper() not in TRIGGERS:
            out.append(f"BAD_CONDITION:{path}:{c[:24]}")
    elif isinstance(c, dict):
        name = str(c.get("when", c.get("trigger", ""))).strip().upper()
        if name not in TRIGGERS:
            out.append(f"BAD_CONDITION:{path}:{name[:24]}")
        for k in c:
            if k not in COND_KEYS:
                out.append(f"UNKNOWN_KEY:cond.{k}")
    else:
        out.append(f"BAD_CONDITION:{path}:type")


def _conds(v: Any, path: str, out: List[str]) -> None:
    if isinstance(v, list):
        for c in v:
            _cond(c, path, out)
    else:
        _cond(v, path, out)


HOISTABLE = PHASE_KEYS - MISSION_KEYS  # next, on_fail, reserve, release, lose, abort, exploit, ...


def hoist(doc: Any):
    """Move misplaced keys to where the author evidently meant them (never
    overwriting an existing key; conflicts are dropped and noted):
      mission-level phase keys -> their phase
      root-level phase keys    -> the last phase
      branch-level condition params -> inside the branch 'when' condition
    Returns (new_doc, notes). The result must be re-gated by the caller."""
    import copy
    d = copy.deepcopy(doc)
    notes: List[str] = []
    phases = [p for p in (d.get("phases") or []) if isinstance(p, dict)]
    for k in [k for k in list(d) if k in HOISTABLE and k not in ROOT_KEYS]:
        v = d.pop(k)
        if phases and k not in phases[-1]:
            phases[-1][k] = v
            notes.append(f"hoist_root_to_phase:{k}")
        else:
            notes.append(f"drop_root_conflict:{k}")
    for p in phases:
        for m in [m for m in (p.get("missions") or []) if isinstance(m, dict)]:
            for k in [k for k in list(m) if k in HOISTABLE]:
                v = m.pop(k)
                if k not in p:
                    p[k] = v
                    notes.append(f"hoist_mission_to_phase:{k}")
                else:
                    notes.append(f"drop_mission_conflict:{k}")
    for b in [b for b in (d.get("branches") or []) if isinstance(b, dict)]:
        extra = {k: b.pop(k) for k in list(b) if k in COND_PARAMS}
        if extra:
            w = b.get("when")
            w = {"when": w} if isinstance(w, str) else (dict(w) if isinstance(w, dict) else None)
            if w is not None:
                for k, v in extra.items():
                    w.setdefault(k, v)
                b["when"] = w
                notes.append("branch_params_into_when")
    return d, notes


def audit(doc: Any) -> List[str]:
    out: List[str] = []
    if not isinstance(doc, dict):
        return ["ROOT_NOT_OBJECT"]
    for k in doc:
        if k not in ROOT_KEYS:
            out.append(f"UNKNOWN_KEY:root.{k}")
    if "abort" in doc:
        _conds(doc["abort"], "root.abort", out)
    for i, p in enumerate(doc.get("phases") or []):
        if not isinstance(p, dict):
            out.append("PHASE_NOT_OBJECT")
            continue
        for k in p:
            if k not in PHASE_KEYS:
                out.append(f"UNKNOWN_KEY:phase.{k}")
        for ck in ("entry", "win", "lose", "abort", "release"):
            if ck in p:
                _conds(p[ck], f"phase.{ck}", out)
        for m in p.get("missions") or []:
            if not isinstance(m, dict):
                out.append("MISSION_NOT_OBJECT")
                continue
            for k in m:
                if k not in MISSION_KEYS:
                    out.append(f"UNKNOWN_KEY:mission.{k}")
            for ck in ("win", "stop"):
                if ck in m:
                    _conds(m[ck], f"mission.{ck}", out)
    for b in doc.get("branches") or []:
        if isinstance(b, dict):
            for k in b:
                if k not in BRANCH_KEYS:
                    out.append(f"UNKNOWN_KEY:branch.{k}")
            if "when" in b:
                _cond(b["when"], "branch.when", out)
    for h in doc.get("hypotheses") or []:
        if isinstance(h, dict):
            for k in h:
                if k not in HYP_KEYS:
                    out.append(f"UNKNOWN_KEY:hypothesis.{k}")
    return out
