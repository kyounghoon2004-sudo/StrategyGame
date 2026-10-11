"""Deterministic repair of observed Brain outputs into SFT TARGET candidates.

A repaired text is only a CANDIDATE: it enters the dataset only after the
real production path (tools/contract_sft_harness.gd) passes it, it is exactly
one JSON object, and every plan-coherence predicate (reward_contract P1-P11)
holds. Repairs keep the model's own strategy wherever possible; they fix
format and contract violations, not tactics.

Syntax: fence/prose strip, bounded greedy edit search for bracket/comma
defects (stray ']' / '}' / missing ','), truncation auto-close, duplicate-key
merge ('phases' arrays concatenated, others last-wins as Godot does).
Semantic (each maps to an observed validator/coherence code):
  VA_UNKNOWN_UNIT, VA_RICH_SUPPORT, VA_RICH_ROLE, VA_BRANCH, VA_COND,
  VA_MISSION_TASK/AREA/ZONE, VA_MISSIONS, VA_PHASES, VA_TRANSITION,
  VP_DUP_PHASE, coherence P2-P11 (reserve+mission, double assignment, ...).
"""
from __future__ import annotations

import json
import re
from typing import Any, Dict, List, Optional, Tuple

TASKS = ["HOLD", "ADVANCE", "FIX", "ATTACK", "FLANK", "RECON", "RESERVE", "WITHDRAW", "EXECUTE"]
AREAS = ["NORTH", "CENTER", "SOUTH", "WEST", "EAST", "ANY"]
TRIGGERS = ["MISSION_BLOCKED", "MISSION_COMPLETE", "FORCE_STRENGTH_BELOW", "ENEMY_COMMITMENT_HIGH",
            "ENEMY_CLASS_DETECTED", "HQ_THREATENED", "LOCAL_ADVANTAGE_HIGH", "OBJECTIVE_EXPOSED",
            "TURNS_ELAPSED", "TARGET_DESTROYED", "REGION_OCCUPIED", "REGION_REACHED", "ALWAYS", "NEVER"]
COND_PARAMS = ["mission_id", "fraction", "region", "threshold", "class", "turns", "since", "unit_id",
               "side", "ratio"]
FAIL_ACTIONS = ["HOLD", "ADVANCE", "EMERGENCY"]
THEN_ACTIONS = ["REQUEST_REVIEW", "HOLD_PHASE", "RELEASE_RESERVE", "NOTE_ONLY"]
TASK_ALIASES = {"DEFEND": "HOLD", "GUARD": "HOLD", "PROTECT": "HOLD", "SCOUT": "RECON",
                "RECONNAISSANCE": "RECON", "ASSAULT": "ATTACK", "STRIKE": "ATTACK", "PIN": "FIX",
                "SCREEN": "HOLD", "MOVE": "ADVANCE", "RETREAT": "WITHDRAW", "SUPPORT": "EXECUTE",
                "ENCIRCLE": "FLANK", "PURSUE": "ATTACK", "EXPLOIT": "ATTACK", "DELAY": "HOLD"}
MAX_PHASES, MAX_MISSIONS, MAX_CONDS, MAX_BRANCHES = 4, 4, 4, 3


# ----------------------------------------------------------------------
# syntax
# ----------------------------------------------------------------------
def _loads_merge(text: str) -> Any:
    def hook(pairs):
        out: Dict[str, Any] = {}
        for k, v in pairs:
            if k in out and k == "phases" and isinstance(out[k], list) and isinstance(v, list):
                out[k] = out[k] + v
            else:
                out[k] = v
        return out
    return json.loads(text, object_pairs_hook=hook)


def _err(text: str) -> Tuple[bool, int, str]:
    try:
        json.loads(text)
        return True, len(text), ""
    except json.JSONDecodeError as e:
        return False, e.pos, e.msg


def _autoclose(text: str) -> Optional[str]:
    """Close a truncated document at the last complete value boundary."""
    stack: List[str] = []
    in_str = esc = False
    last_ok = -1
    last_stack: List[str] = []
    for i, ch in enumerate(text):
        if in_str:
            if esc:
                esc = False
            elif ch == "\\":
                esc = True
            elif ch == '"':
                in_str = False
            continue
        if ch == '"':
            in_str = True
        elif ch in "{[":
            stack.append("}" if ch == "{" else "]")
        elif ch in "}]":
            if not stack:
                break
            stack.pop()
            last_ok, last_stack = i, list(stack)
            if not stack:
                return text[:i + 1]
        elif ch == ",":
            last_ok, last_stack = i - 1, list(stack)
    if last_ok < 0 or not last_stack:
        return None
    return text[:last_ok + 1].rstrip().rstrip(",") + "".join(reversed(last_stack))


def repair_syntax(raw: str, max_edits: int = 8) -> Tuple[Optional[Any], List[str]]:
    notes: List[str] = []
    t = raw.strip()
    m = re.search(r"```(?:json)?\s*\n(.*?)```", t, re.S)
    if m:
        t = m.group(1).strip()
        notes.append("strip_fence")
    if t and t[0] != "{" and "{" in t:
        t = t[t.index("{"):]
        notes.append("strip_leading_prose")
    for _ in range(max_edits):
        ok, pos, msg = _err(t)
        if ok:
            return _loads_merge(t), notes
        cands = []
        if msg.startswith("Extra data"):
            # root closed early or trailing junk: try dropping a closer
            # before pos (continue the document) or cutting the tail.
            for back in range(1, 4):
                j = pos - back
                if j >= 0 and t[j] in "]}":
                    cands.append((t[:j] + t[j + 1:], f"drop_closer@{j}"))
            cands.append((t[:pos].rstrip(), "cut_trailing"))
        else:
            for e_txt, e_note in ((t[:pos] + t[pos + 1:], "del"), (t[:pos - 1] + t[pos:], "del-1"),
                                  (t[:pos] + "," + t[pos:], "ins,"), (t[:pos] + "}" + t[pos:], "ins}"),
                                  (t[:pos] + "]" + t[pos:], "ins]"), (t[:pos] + "}," + t[pos:], "ins},"),
                                  (t[:pos] + "]," + t[pos:], "ins],")):
                cands.append((e_txt, f"{e_note}@{pos}"))
        best = None
        for c, note in cands:
            cok, cpos, _ = _err(c)
            score = (1 if cok else 0, cpos if not cok else 1 << 30)
            if cok or cpos > pos:
                if best is None or score > best[0]:
                    best = (score, c, note)
        if best is None:
            break
        t = best[1]
        notes.append(best[2])
    ok, _, _ = _err(t)
    if ok:
        return _loads_merge(t), notes
    closed = _autoclose(t)
    if closed is not None:
        ok, _, _ = _err(closed)
        if ok:
            notes.append("autoclose_truncated")
            return _loads_merge(closed), notes
    return None, notes + ["syntax_unrepairable"]


# ----------------------------------------------------------------------
# semantic
# ----------------------------------------------------------------------
def _u(v: Any) -> str:
    return str(v if v is not None else "").strip().upper()


def _fix_conds(v: Any, notes: List[str], where: str) -> List[Any]:
    if v is None:
        return []
    if isinstance(v, str):
        v = [v]
    if not isinstance(v, list):
        notes.append(f"drop_conds_nonlist:{where}")
        return []
    out = []
    for e in v:
        if isinstance(e, str) and _u(e) in TRIGGERS:
            out.append(_u(e))
        elif isinstance(e, dict):
            name = _u(e.get("when", e.get("trigger", "")))
            if name not in TRIGGERS:
                notes.append(f"drop_cond_unknown:{where}:{name[:24]}")
                continue
            c = {"when": name}
            params = e.get("params") if isinstance(e.get("params"), dict) else e
            for k in COND_PARAMS:
                if k in params:
                    c[k] = params[k]
            out.append(c)
        else:
            notes.append(f"drop_cond_bad:{where}")
    if len(out) > MAX_CONDS:
        notes.append(f"trim_conds:{where}")
    return out[:MAX_CONDS]


def _units(v: Any, roster: set, notes: List[str], where: str) -> List[str]:
    out = []
    for u in (v if isinstance(v, list) else []):
        uid = _u(u)
        if not uid:
            continue
        if roster and uid not in roster:
            notes.append(f"drop_unknown_unit:{where}:{uid}")
            continue
        if uid not in out:
            out.append(uid)
    return out


def repair_semantics(doc: Dict[str, Any], roster: List[str]) -> Tuple[Dict[str, Any], List[str]]:
    notes: List[str] = []
    R = {_u(x) for x in roster}
    d = dict(doc)
    for k in ("final_objective",):  # legacy spelling -> compact
        if "objective" not in d and k in d:
            d["objective"] = d.pop(k)
            notes.append("objective_from_final_objective")
    if not str(d.get("objective", "")).strip():
        d["objective"] = str(d.get("end_state") or "Destroy the enemy HQ.")
        notes.append("objective_filled")
    phases = [p for p in (d.get("phases") if isinstance(d.get("phases"), list) else []) if isinstance(p, dict)]
    if len(phases) > MAX_PHASES:
        notes.append("trim_phases")
        phases = phases[:MAX_PHASES]
    new_phases = []
    for i, p in enumerate(phases):
        p = dict(p)
        where = f"P{i + 1}"
        groups = p.get("groups") if isinstance(p.get("groups"), dict) else {}
        seen_g: set = set()
        ng = {}
        for gname, gu in groups.items():
            us = [u for u in _units(gu, R, notes, where + "/group") if u not in seen_g]
            if len(us) < len(_units(gu, R, [], "")):
                notes.append(f"P11_dedupe_group:{where}")
            seen_g.update(us)
            ng[str(gname)[:32]] = us
        if "groups" in p:
            p["groups"] = ng
        ms = [m for m in (p.get("missions") if isinstance(p.get("missions"), list) else []) if isinstance(m, dict)]
        assigned: set = set()
        nms = []
        for k, m in enumerate(ms):
            m = dict(m)
            mw = f"{where}/M{k + 1}"
            task = _u(m.get("task", ""))
            if task and task not in TASKS:
                m["task"] = TASK_ALIASES.get(task, "EXECUTE")
                notes.append(f"task_map:{mw}:{task[:16]}->{m['task']}")
            if "area" in m and _u(m.get("area")) not in AREAS:
                notes.append(f"area_any:{mw}")
                m["area"] = "ANY"
            if "zone" in m and _u(m.get("zone")) not in AREAS:
                notes.append(f"drop_zone:{mw}")
                m.pop("zone")
            us = _units(m.get("units"), R, notes, mw)
            dup = [u for u in us if u in assigned]
            if dup:
                notes.append(f"P6_dedupe_units:{mw}:{','.join(dup)}")
                us = [u for u in us if u not in assigned]
            if not us and _units(m.get("units"), R, [], ""):
                notes.append(f"drop_empty_mission:{mw}")
                continue
            assigned.update(us)
            m["units"] = us
            for ck in ("win", "stop"):
                if ck in m:
                    m[ck] = _fix_conds(m[ck], notes, f"{mw}/{ck}")
            if isinstance(m.get("roles"), dict):
                roles = {kk: vv for kk, vv in m["roles"].items() if _u(kk) in us}
                if len(roles) != len(m["roles"]):
                    notes.append(f"drop_roles_outside:{mw}")
                m["roles"] = roles
            if isinstance(m.get("support"), list):
                sup = [s for s in m["support"] if isinstance(s, dict)
                       and _u(s.get("from")) in us and _u(s.get("to")) in us]
                if len(sup) != len(m["support"]):
                    notes.append(f"drop_support_outside:{mw}")
                m["support"] = sup
            if isinstance(m.get("prefer"), dict) and isinstance(m["prefer"].get("units"), list):
                pass  # preferences may name enemy units; not validated
            nms.append(m)
        if not nms:
            notes.append(f"drop_empty_phase:{where}")
            continue
        if len(nms) > MAX_MISSIONS:
            notes.append(f"trim_missions:{where}")
            nms = nms[:MAX_MISSIONS]
        p["missions"] = nms
        for ck in ("entry", "win", "lose", "abort", "release"):
            if ck in p:
                p[ck] = _fix_conds(p[ck], notes, f"{where}/{ck}")
        wins = {json.dumps(c, sort_keys=True) for c in p.get("win", [])}
        for ck in ("lose", "abort"):
            if ck in p and any(json.dumps(c, sort_keys=True) in wins for c in p[ck]):
                p[ck] = [c for c in p[ck] if json.dumps(c, sort_keys=True) not in wins]
                notes.append(f"P10_drop_contradiction:{where}/{ck}")
        for mm in nms:
            mwin = {json.dumps(c, sort_keys=True) for c in mm.get("win", [])}
            if "stop" in mm and any(json.dumps(c, sort_keys=True) in mwin for c in mm["stop"]):
                mm["stop"] = [c for c in mm["stop"] if json.dumps(c, sort_keys=True) not in mwin]
                notes.append(f"P10_drop_contradiction:{where}/mission")
        if "reserve" in p:
            res = _units(p.get("reserve"), R, notes, where + "/reserve")
            clash = [u for u in res if u in assigned]
            if clash:
                notes.append(f"P7_unreserve_assigned:{where}:{','.join(clash)}")
                res = [u for u in res if u not in assigned]
            p["reserve"] = res
        if not p.get("reserve") and p.get("release"):
            notes.append(f"P8_drop_release:{where}")
            p["release"] = []
        of = _u(p.get("on_fail", "HOLD")) or "HOLD"
        if of not in FAIL_ACTIONS:
            notes.append(f"on_fail_hold:{where}")
            p["on_fail"] = "HOLD"
        new_phases.append(p)
    # phase ids: unique, P1..Pn in order; remap 'next' references.
    old_ids = [_u(p.get("id", p.get("phase_id", ""))) for p in new_phases]
    remap = {}
    for i, p in enumerate(new_phases):
        nid = f"P{i + 1}"
        if old_ids[i] and old_ids[i] not in remap:
            remap[old_ids[i]] = nid
        if old_ids[i] != nid:
            notes.append(f"renumber:{old_ids[i] or '-'}->{nid}")
        p.pop("phase_id", None)
        p["id"] = nid
    n = len(new_phases)
    for i, p in enumerate(new_phases):
        nxt = _u(p.get("next", ""))
        if nxt in ("-", "HOLD", "END"):
            pass
        elif nxt == "":
            if i == n - 1:
                p["next"] = "END"
                notes.append("P4_last_next_end")
        else:
            tgt = remap.get(nxt)
            if tgt is None or int(tgt[1:]) <= i + 1:
                p["next"] = "END" if i == n - 1 else ""
                notes.append(f"P2P3_fix_next:P{i + 1}:{nxt}")
            else:
                p["next"] = tgt
    # mission refs (P5): M1 / P1M1 / m01 -> M0k when resolvable, else drop.
    for i, p in enumerate(new_phases):
        k = len(p["missions"])

        def fix(c, scope_k):
            if isinstance(c, dict) and "mission_id" in c:
                mid = _u(c["mission_id"])
                mm = re.search(r"M0*(\d+)$", mid)
                if mm and 1 <= int(mm.group(1)) <= scope_k:
                    good = f"M{int(mm.group(1)):02d}"
                    if good != mid:
                        notes.append(f"P5_fix_ref:{mid}->{good}")
                    c["mission_id"] = good
                else:
                    notes.append(f"P5_drop_ref:{mid}")
                    c.pop("mission_id")
            return c
        for m in p["missions"]:
            for ck in ("win", "stop"):
                m[ck] = [fix(c, k) for c in m.get(ck, [])] if ck in m else m.get(ck)
                if m[ck] is None:
                    m.pop(ck)
        for ck in ("entry", "win", "lose", "abort", "release"):
            if ck in p:
                p[ck] = [fix(c, k) for c in p[ck]]
    d["phases"] = new_phases
    kmax = max((len(p["missions"]) for p in new_phases), default=0)
    if "abort" in d:
        d["abort"] = [c for c in _fix_conds(d["abort"], notes, "plan_abort")]
        for c in d["abort"]:
            if isinstance(c, dict) and "mission_id" in c:
                mm = re.search(r"M0*(\d+)$", _u(c["mission_id"]))
                if mm and 1 <= int(mm.group(1)) <= kmax:
                    c["mission_id"] = f"M{int(mm.group(1)):02d}"
                else:
                    c.pop("mission_id")
                    notes.append("P5_drop_ref:plan_abort")
    any_reserve = any(p.get("reserve") for p in new_phases)
    if isinstance(d.get("branches"), list):
        nb = []
        for j, b in enumerate(d["branches"]):
            if not isinstance(b, dict):
                notes.append(f"drop_branch_bad:{j + 1}")
                continue
            b = dict(b)
            w = b.get("when")
            conds = _fix_conds([w] if isinstance(w, (dict, str)) else [], notes, f"branch{j + 1}")
            if not conds:
                notes.append(f"drop_branch_nowhen:{j + 1}")
                continue
            c0 = conds[0]
            if isinstance(c0, dict) and "mission_id" in c0:
                mm = re.search(r"M0*(\d+)$", _u(c0["mission_id"]))
                if mm and 1 <= int(mm.group(1)) <= kmax:
                    c0["mission_id"] = f"M{int(mm.group(1)):02d}"
                else:
                    c0.pop("mission_id")
                    notes.append(f"P5_drop_ref:branch{j + 1}")
            b["when"] = c0
            th = _u(b.get("then", "REQUEST_REVIEW")) or "REQUEST_REVIEW"
            if th not in THEN_ACTIONS or (th == "RELEASE_RESERVE" and not any_reserve):
                notes.append(f"branch_then_review:{j + 1}")
                th = "REQUEST_REVIEW"
            b["then"] = th
            nb.append(b)
        if len(nb) > MAX_BRANCHES:
            notes.append("trim_branches")
        d["branches"] = nb[:MAX_BRANCHES]
    return d, notes


def dumps(doc: Dict[str, Any]) -> str:
    return json.dumps(doc, ensure_ascii=False, separators=(",", ":"))


def repair(raw: str, roster: List[str]) -> Tuple[Optional[str], List[str]]:
    doc, notes = repair_syntax(raw)
    if not isinstance(doc, dict):
        return None, notes + (["root_not_object"] if doc is not None else [])
    fixed, snotes = repair_semantics(doc, roster)
    if not fixed.get("phases"):
        return None, notes + snotes + ["no_phases_left"]
    return dumps(fixed), notes + snotes
