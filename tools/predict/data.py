"""Samples for the prediction model (2026-10-08) from game records (rl_arena "record": unit snapshots at the start of
every phase and both sides' executed actions).

One sample = one side about to act. The board is seen from that side ("own" / "enemy"; BLUE's view is point-mirrored
so own is always on the same half). Labels, all taken from what really happened:
  action  per own unit: HOLD / FORTIFY / OTHER / MOVE in one of 6 directions / ATTACK (+ which enemy)
  outcome per unit: share of its soldiers lost during this side's phase, destroyed or not
  intent  per enemy unit: the first own unit it attacks during its next INTENT_TURNS turns (or none)
  value   this side's result: win / draw / loss
"""
from __future__ import annotations

import glob
import hashlib
import json
from pathlib import Path

CLASSES = ["cavalry", "infantry", "spearman", "archer", "scout", "hq"]
ACT = ["HOLD", "FORTIFY", "OTHER", "MOVE0", "MOVE1", "MOVE2", "MOVE3", "MOVE4", "MOVE5", "ATTACK"]
AXIAL = [(1, 0), (1, -1), (0, -1), (-1, 0), (-1, 1), (0, 1)]
INTENT_TURNS = 5
LLM_WEIGHT = 1.0  # games with an LLM side drawn this many times as often (train --llm-weight; 2026-10-09)
GX_DRAW_WEIGHT = 0.6  # GX-vs-GX draws, sampled less (0.3 on 2026-10-08 made win probabilities overconfident; 0.6 on 10-09)
# Per-game balance (2026-10-08): a draw runs the full 81 turns (~160 phases) and swamped the decisive games; a game's
# phases are sampled with probability min(1, game weight x PHASES_PER_GAME / its phases).
PHASES_PER_GAME = 40
FEAT = 24  # 6 classes, own, q, r, to own HQ (2), to enemy HQ (2), soldiers share, soldiers, fieldworks, turn, LLM, code,
#            + this game's rules for the unit's class: movement, attack, defense, range, rules known
RULE_CLASS = {"spearman": "spear"}
USER_DIR = Path.home() / "AppData" / "Roaming" / "Godot" / "app_userdata" / "[unnamed project]"


def game_rules(g: dict) -> dict | None:
    """The rules this game really ran with: the record's own copy (since 2026-10-08), else the overlay file the game
    wrote (user://watch, only when its episode id matches and the family is not "fixed": a fixed game's id does not
    identify its rules), else None (unknown)."""
    r = (g.get("record") or {}).get("rules")
    if r:
        return r
    ep = g.get("episode") or {}
    sp, eid = str(ep.get("spec_path", "")), str(ep.get("episode_id", ""))
    if not sp.startswith("user://") or eid.startswith("sbxF_"):
        return None
    f = USER_DIR / sp.replace("user://", "")
    try:
        o = json.loads(f.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return None
    return o.get("rules") if o.get("episode_id") == eid else None


def _rule_feats(rules: dict | None, cls: str) -> list:
    if not rules:
        return [0.0, 0.0, 0.0, 0.0, 0.0]
    k = RULE_CLASS.get(cls, cls)
    st = (rules.get("class_stats") or {}).get(k, {})
    return [float((rules.get("base_mp") or {}).get(k, 0)) / 5, float(st.get("attack", 0)) / 20,
            float(st.get("defense", 0)) / 20, float(st.get("range", 0)) / 3, 1.0]
MAX_UNITS = 32  # random rosters: up to 16 per side


def hexd(a, b) -> int:
    dq, dr = a[0] - b[0], a[1] - b[1]
    return (abs(dq) + abs(dr) + abs(dq + dr)) // 2


def _dir(dq: int, dr: int) -> int:
    # the axial direction closest to the displacement (cube dot product)
    x, z = dq, dr
    y = -x - z
    best, bi = -1e9, 0
    for i, (aq, ar) in enumerate(AXIAL):
        ax, az = aq, ar
        ay = -ax - az
        d = x * ax + y * ay + z * az
        if d > best:
            best, bi = d, i
    return bi


def game_samples(rec: dict, outcome: str, actor: dict | None = None, act_ok: bool = True, rules: dict | None = None) -> list:
    """actor = {"red": "gx" | "llm" | "code", "blue": ...}: who played each side (a feature, so the action head can
    tell a GX move from an LLM or code-policy move). act_ok = False: no action labels (a replay that did not end
    like the original)."""
    actor = actor or {"red": "gx", "blue": "gx"}
    snaps = [s for s in rec.get("snapshots", []) if s.get("to_act")]
    if not snaps:
        return []
    acts = {side: rec.get("actions", {}).get(side, []) for side in ("red", "blue")}
    by_turn = {side: {} for side in acts}
    for side, lst in acts.items():
        for e in lst:
            by_turn[side].setdefault(int(e.get("turn", 0)), []).append(e)
    seen, out = set(), []
    for i, s in enumerate(snaps):
        side, t = s["to_act"], int(s["turn"])
        if (side, t) in seen or i + 1 >= len(snaps):
            continue
        seen.add((side, t))
        foe = "blue" if side == "red" else "red"
        mirror = -1 if side == "blue" else 1
        units = [u for u in s["units"] if u[5] > 0][:MAX_UNITS]
        after = {u[0]: u[5] for u in snaps[i + 1]["units"]}
        ids = [u[0] for u in units]
        own_hq = next(((u[3], u[4]) for u in units if u[1] == side and u[2] == "hq"), (0, 0))
        foe_hq = next(((u[3], u[4]) for u in units if u[1] == foe and u[2] == "hq"), (0, 0))
        feats, pos, own = [], [], []
        for u in units:
            q, r = u[3] * mirror, u[4] * mirror
            cls = [1.0 if u[2] == c else 0.0 for c in CLASSES]
            is_own = u[1] == side
            feats.append(cls + [1.0 if is_own else 0.0, q / 20, r / 20,
                                (u[3] - own_hq[0]) * mirror / 20, (u[4] - own_hq[1]) * mirror / 20,
                                (u[3] - foe_hq[0]) * mirror / 20, (u[4] - foe_hq[1]) * mirror / 20,
                                u[5] / max(1, u[6]), u[5] / 500, u[7] / 180, t / 80,
                                1.0 if actor[u[1]] == "llm" else 0.0, 1.0 if actor[u[1]] == "code" else 0.0]
                         + _rule_feats(rules, u[2]))
            pos.append((u[3], u[4]))
            own.append(is_own)
        # action of each own unit this phase
        act, tgt = [], []
        evs = by_turn[side].get(t, [])
        for u in units:
            a, g = -100, -100  # -100 = no label (enemy unit)
            if u[1] == side and act_ok:
                mine = [e for e in evs if e.get("unit") == u[0]]
                atk = [e for e in mine if e.get("do") == "ATTACK" and e.get("target") in ids]
                mv = [e for e in mine if e.get("do") == "MOVE" and e.get("from") and e.get("to")]
                if atk:
                    a, g = ACT.index("ATTACK"), ids.index(atk[-1]["target"])
                elif any(e.get("do") == "FORTIFY" for e in mine):
                    a = ACT.index("FORTIFY")
                elif mv:
                    dq = (mv[-1]["to"][0] - mv[0]["from"][0]) * mirror
                    dr = (mv[-1]["to"][1] - mv[0]["from"][1]) * mirror
                    a = ACT.index("MOVE%d" % _dir(dq, dr)) if (dq or dr) else ACT.index("HOLD")
                elif mine:
                    a = ACT.index("OTHER")
                else:
                    a = ACT.index("HOLD")
            act.append(a)
            tgt.append(g)
        # outcome of this phase for every unit
        lost = [max(0.0, (u[5] - after.get(u[0], 0)) / max(1, u[5])) for u in units]
        dead = [1.0 if after.get(u[0], 0) <= 0 else 0.0 for u in units]
        # intent of each enemy unit: the first own unit it attacks in its next INTENT_TURNS turns
        t0 = t + 1 if side == "red" else t  # BLUE acts first in a round
        intent = []
        for u in units:
            v = -100
            if u[1] == foe:
                v = len(units)  # "none"
                for tt in range(t0, t0 + INTENT_TURNS):
                    hit = [e for e in by_turn[foe].get(tt, []) if e.get("unit") == u[0] and e.get("do") == "ATTACK"
                           and e.get("target") in ids and units[ids.index(e["target"])][1] == side]
                    if hit:
                        v = ids.index(hit[0]["target"])
                        break
            intent.append(v)
        win = {"RED_WIN": "red", "BLUE_WIN": "blue"}.get(outcome)
        value = 1 if win is None else (0 if win == side else 2)  # 0 win, 1 draw, 2 loss
        dist = [[min(15, hexd(a, b)) for b in pos] for a in pos]
        out.append({"feat": feats, "dist": dist, "own": own, "act": act, "tgt": tgt, "lost": lost, "dead": dead,
                    "intent": intent, "value": value, "turn": t, "side": side})
    return out


def load(dirs: list, holdout: float = 0.1) -> tuple[list, list, dict]:
    """dirs: collector out dirs. A replay dir (tools/predict/replay.py: <replay>/fort0|fort1) is recognised by the
    originals.json next to it: RED was an LLM there, and only replays that ended like the original keep action labels."""
    train, val, info = [], [], {"games": 0, "skipped": 0, "replay_mismatch": 0}
    for d in dirs:
        orig_f = Path(d).parent / "originals.json"
        orig = json.loads(orig_f.read_text(encoding="utf-8")) if orig_f.exists() else None
        res = {}
        if (Path(d) / "results.jsonl").exists():
            for line in (Path(d) / "results.jsonl").read_text(encoding="utf-8").splitlines():
                r = json.loads(line)
                res[r["game"]] = r
        modes = [r.get("mode", "gx_vs_gx") for r in res.values()]
        dir_mode = max(set(modes), key=modes.count) if modes else "gx_vs_gx"
        if not modes and "cmd_rl" in str(d):  # RL iteration dirs (no results.jsonl): the LLM commander played RED
            dir_mode = "gx_vs_cloud"
        for f in glob.glob(str(Path(d) / "games" / "*.json")):
            try:
                g = json.loads(Path(f).read_text(encoding="utf-8"))
            except (ValueError, OSError):
                continue
            name = Path(f).stem
            if g.get("strict_fault") or "INVALID" in str(g.get("driver_stage", "")):  # invalid games never train (user 2026-10-09)
                info["invalid"] = info.get("invalid", 0) + 1
                continue
            actor, act_ok, held = {"red": "gx", "blue": "gx"}, True, False
            mode = res.get(name, {}).get("mode", dir_mode)  # a game without a result row: the run's own mode
            if mode in ("gx_vs_cloud", "cloud_vs_cloud"):  # a commander (LLM) played RED; won or lost, all kept
                actor["red"] = "llm"
            if mode == "cloud_vs_cloud":
                actor["blue"] = "llm"
            if orig is not None:
                o, r = orig.get(name) or {}, res.get(name, {})
                actor["red"] = o.get("actor", "llm")
                held = bool(o.get("holdout"))  # a package's own hold-out stays out of training
                act_ok = bool(o) and o["kind"] == r.get("kind") and o["turn"] == r.get("turn") and o["units"] == r.get("units")
                info["replay_mismatch"] += not act_ok
            rules = game_rules(g)
            info["rules_known"] = info.get("rules_known", 0) + bool(rules)
            ss = game_samples(g.get("record") or {}, str(g.get("outcome", "")), actor, act_ok, rules)
            if not ss:
                info["skipped"] += 1
                continue
            info["games"] += 1
            gxgx_draw = actor == {"red": "gx", "blue": "gx"} and str(g.get("outcome", "")) not in ("RED_WIN", "BLUE_WIN")
            w = min(1.0, (GX_DRAW_WEIGHT if gxgx_draw else 1.0) * PHASES_PER_GAME / len(ss))
            if "llm" in actor.values():
                w *= LLM_WEIGHT  # above 1: drawn more than once per epoch
            tier = str(res.get(name, {}).get("tier", name.split("_")[0]))
            for x in ss:
                x["w"] = w
                if gxgx_draw and tier == "ADV":
                    x["vw"] = 0.0  # ADV GX-vs-GX is ~95% draws: no win/loss signal, kept for actions and outcomes
            (val if held or int(hashlib.sha256(name.encode()).hexdigest(), 16) % 1000 < holdout * 1000 else train).extend(ss)
    return train, val, info
