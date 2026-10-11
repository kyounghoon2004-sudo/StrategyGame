"""HAND B v2 shared core: frame, deterministic fog-honest scorer, renderer.

Hand B consumes HAND A orders: {task, relative_direction, intent}.
relative_direction in FORWARD|BACK|LEFT|RIGHT|CENTER|ANY is authoritative for
movement. Frame (per side): forward = own HQ -> map centre (both are known to
the acting side); left = forward rotated to the left-hand side (screen coords,
+y down). Nothing here reads hidden truth: only the side's own ledger
(own_forces, visible foes, last-known contacts) and the enumerated candidates.
Scores are deterministic (no RNG). accepted = score >= best - EPS; every
accepted candidate shares target mass equally.
"""
from __future__ import annotations

import math

SQ3 = math.sqrt(3.0)
EPS = 0.35
NEG = -1e9
TASKS = ["ADVANCE", "FIX", "ATTACK", "FLANK", "RECON", "RESERVE", "HOLD", "WITHDRAW", "EXECUTE"]
DIRS = ["FORWARD", "BACK", "LEFT", "RIGHT", "CENTER", "ANY"]
ALLOWED_DIRS = {
    "ADVANCE": ["FORWARD", "LEFT", "RIGHT", "CENTER", "ANY"],
    "FIX": ["FORWARD", "LEFT", "RIGHT", "CENTER"],
    "ATTACK": ["FORWARD", "LEFT", "RIGHT", "CENTER", "ANY"],
    "FLANK": ["LEFT", "RIGHT"],
    "RECON": ["FORWARD", "LEFT", "RIGHT", "ANY"],
    "RESERVE": ["CENTER", "ANY", "BACK"],
    "HOLD": ["ANY", "CENTER"],
    "WITHDRAW": ["BACK"],
}
STATIONARY = ("WAIT", "FORTIFY", "REST")
RANGE = {"archer": 3}
VISION = {"scout": 4}
# EXECUTE: the supplied intent is the only behavioural cue. (text, behaviour, dir)
EXECUTE_INTENTS = [
    ("Press forward along the axis and close with the enemy.", "ADVANCE", "FORWARD"),
    ("Push ahead on your line; keep moving toward the enemy side.", "ADVANCE", "FORWARD"),
    ("Pull back and preserve the force.", "WITHDRAW", "BACK"),
    ("Break contact and fall back toward our lines.", "WITHDRAW", "BACK"),
    ("Pin the enemy in front of you; keep contact without committing.", "FIX", "FORWARD"),
    ("Hold the enemy in place by staying in contact.", "FIX", "FORWARD"),
    ("Destroy the nearest enemy formation.", "ATTACK", "ANY"),
    ("Strike any enemy you can reach.", "ATTACK", "ANY"),
    ("Swing around the left side.", "FLANK", "LEFT"),
    ("Work around on your right side.", "FLANK", "RIGHT"),
    ("Swing wide to your right.", "FLANK", "RIGHT"),
    ("Stay back as a ready reserve.", "RESERVE", "ANY"),
    ("Keep out of the fight behind the line until called.", "RESERVE", "ANY"),
    ("Hold this ground.", "HOLD", "ANY"),
    ("Do not move; defend where you stand.", "HOLD", "ANY"),
    ("Scout ahead and find the enemy.", "RECON", "FORWARD"),
    ("Look around the left for enemy movement.", "RECON", "LEFT"),
]
TASK_INTENTS = {
    "ADVANCE": "Advance along the ordered direction.",
    "FIX": "Establish and keep contact; pin the enemy.",
    "ATTACK": "Attack enemy formations.",
    "FLANK": "Move around the ordered side, then approach.",
    "RECON": "Find the enemy; extend what we can see.",
    "RESERVE": "Stay behind the line, uncommitted.",
    "HOLD": "Hold position.",
    "WITHDRAW": "Fall back and increase separation.",
}


# ----------------------------------------------------------------- geometry
def px(q, r):
    return (SQ3 * q + SQ3 / 2.0 * r, 1.5 * r)


def hdist(a, b):
    (q1, r1), (q2, r2) = a, b
    return (abs(q1 - q2) + abs(q1 + r1 - q2 - r2) + abs(r1 - r2)) // 2


def frame(own_hq, bounds):
    cq = (bounds["q_min"] + bounds["q_max"]) / 2.0
    cr = (bounds["r_min"] + bounds["r_max"]) / 2.0
    hx, hy = px(*own_hq)
    cx, cy = px(cq, cr)
    dx, dy = cx - hx, cy - hy
    m = math.hypot(dx, dy) or 1.0
    f = (dx / m, dy / m)
    return f, (f[1], -f[0])  # forward, left


def rel(frm, to, fr):
    """(forward, left) displacement from frm to to, in hex units."""
    (f, l) = fr
    ax, ay = px(*frm)
    bx, by = px(*to)
    dx, dy = bx - ax, by - ay
    return ((dx * f[0] + dy * f[1]) / SQ3, (dx * l[0] + dy * l[1]) / SQ3)


def dir_vec(d):
    return {"FORWARD": (1, 0), "BACK": (-1, 0), "LEFT": (0, 1), "RIGHT": (0, -1)}.get(d)


# ------------------------------------------------------------------ context
def foes_of(ledger, side):
    return ledger.get("observed_blue_forces" if side == "red" else "current_enemy_observations", []) or []


def lastknown_of(ledger, side):
    return ledger.get("last_known_blue_contacts" if side == "red" else "last_known_enemy_contacts", []) or []


def pos(e):
    return (int(e.get("q", 0)), int(e.get("r", 0)))


def ctx_from(state, unit):
    """Everything the scorer/renderer may use. state: extractor side record."""
    led = state["ledger"]
    side = state["side"]
    own = [o for o in (led.get("own_forces", []) or [])]
    hq = next((pos(o) for o in own if str(o.get("class", "")) == "hq"), None)
    if hq is None:
        hq = pos(unit)
    fr = frame(hq, state["bounds"])
    V = [pos(e) for e in foes_of(led, side)]
    LK = [pos(e) for e in lastknown_of(led, side) if pos(e) not in V]
    field = [o for o in own if str(o.get("class", "")) != "hq"]
    fwd_coord = lambda p: rel(hq, p, fr)[0]
    line = sum(fwd_coord(pos(o)) for o in field) / max(1, len(field))
    return {"side": side, "fr": fr, "hq": hq, "V": V, "LK": LK, "own": own, "line": line,
            "fwd_coord": fwd_coord, "lat_coord": lambda p: rel(hq, p, fr)[1], "bounds": state["bounds"]}


# ------------------------------------------------------------------- scorer
def cand_pos(c, unit):
    if c["action_type"] == "MOVE":
        return (int(c["destination"][0]), int(c["destination"][1]))
    return pos(unit)


def dmin(p, pts):
    return min((hdist(p, x) for x in pts), default=None)


def adj(p, V):
    return sum(1 for x in V if hdist(p, x) <= 1)


def recon_gain(p, ctx, radius):
    b = ctx["bounds"]
    seen = set()
    for o in ctx["own"]:
        rr = VISION.get(str(o.get("class", "")), 2)
        oq, orr = pos(o)
        for dq in range(-rr, rr + 1):
            for dr in range(max(-rr, -dq - rr), min(rr, -dq + rr) + 1):
                seen.add((oq + dq, orr + dr))
    g = 0
    for dq in range(-radius, radius + 1):
        for dr in range(max(-radius, -dq - radius), min(radius, -dq + radius) + 1):
            h = (p[0] + dq, p[1] + dr)
            if b["q_min"] <= h[0] <= b["q_max"] and b["r_min"] <= h[1] <= b["r_max"] and h not in seen:
                g += 1
    return g


def score_all(task, rdir, unit, cands, ctx):
    """Deterministic score per candidate (NEG = never accepted)."""
    cls = str(unit.get("class", "")).lower()
    ranged = cls in RANGE
    rng = RANGE.get(cls, 1)
    up = pos(unit)
    V, LK, fr = ctx["V"], ctx["LK"], ctx["fr"]
    threat = V if V else LK
    d0 = dmin(up, V)
    attacks = [c for c in cands if c["action_type"] == "ATTACK"]
    out = []
    for c in cands:
        t = c["action_type"]
        p = cand_pos(c, unit)
        dF, dL = rel(up, p, fr)
        moved = hdist(up, p)
        s = NEG
        if t in ("ASSAULT", "DISMANTLE", "ENTER_GARRISON"):
            out.append(NEG)
            continue
        if task == "HOLD":
            if t in STATIONARY:
                s = 1.0
            elif t == "MOVE":
                s = -float(moved)
        elif task == "RESERVE":
            if t in ("MOVE",) + STATIONARY:
                ahead_lim = ctx["line"] - (3.0 if rdir == "BACK" else 1.0)
                fa, f0 = ctx["fwd_coord"](p), ctx["fwd_coord"](up)
                if d0 is not None and d0 <= 2:  # threatened: open distance
                    s = min(dmin(p, V), 4) - 0.2 * moved
                elif f0 > ahead_lim + 0.5:  # ahead of where a reserve belongs
                    s = -max(0.0, fa - ahead_lim) - 0.3 * moved
                else:
                    s = 1.0 if t in STATIONARY else -0.5 * moved
                if rdir == "CENTER" and t == "MOVE":
                    s -= 0.25 * max(0.0, abs(ctx["lat_coord"](p)) - abs(ctx["lat_coord"](up)))
        elif task == "WITHDRAW":
            if t in ("MOVE",) + STATIONARY:
                s = -dF - 2.0 * adj(p, V)
                if threat:
                    s += max(-2.0, min(3.0, dmin(p, threat) - dmin(up, threat)))
        elif task == "FLANK":
            side = dir_vec(rdir)
            if t in ("MOVE",) + STATIONARY:
                lat = dL * side[1]
                s = 1.5 * lat + 0.5 * dF - 3.0 * adj(p, V)
        elif task == "RECON":
            if t in ("MOVE",) + STATIONARY:
                g = recon_gain(p, ctx, VISION.get(cls, 2)) if t == "MOVE" else 0
                dv = dir_vec(rdir) or (1, 0)
                s = g / (3.0 * VISION.get(cls, 2)) + 0.3 * (dF * dv[0] + dL * dv[1]) - 3.0 * adj(p, V)
        elif task in ("ADVANCE", "FIX", "ATTACK"):
            dv = dir_vec(rdir) or (1, 0)
            along = dF * dv[0] + dL * dv[1]
            perp = abs(dL * dv[0] - dF * dv[1])
            if rdir == "CENTER":
                along = 0.5 * dF + (abs(ctx["lat_coord"](up)) - abs(ctx["lat_coord"](p)))
                perp = 0.0
            if task == "ADVANCE":
                if t == "MOVE" or t in STATIONARY:
                    s = along - 0.25 * perp - (3.0 * adj(p, V) if ranged else 0.0)
                    if t in STATIONARY:
                        s = min(s, 0.0)
            elif task == "FIX":
                if t == "MOVE" or t in STATIONARY:
                    if V:
                        da = dmin(p, V)
                        if ranged:
                            s = -2.0 * max(0, 2 - da) - max(0, da - rng)
                            if t in ("WAIT", "FORTIFY") and 2 <= d0 <= rng:
                                s += 0.5
                        else:
                            if d0 <= 2:
                                s = 1.0 if t in ("WAIT", "FORTIFY") else -abs(da - 1.5) - 0.5 * moved
                            else:
                                s = -max(0, da - 2) + 0.2 * along
                    else:
                        s = min(along, 2.0) - 0.5 * perp
                        if t in STATIONARY:
                            s = min(s, 0.0)
            else:  # ATTACK
                if attacks:
                    if t == "ATTACK":
                        s = 3.0 + float(c.get("matchup_mult", 1.0))
                        if ranged and d0 is not None and d0 <= 1:
                            s = 2.0 + 0.5 * float(c.get("matchup_mult", 1.0))
                    elif ranged and d0 is not None and d0 <= 1 and t == "MOVE":
                        da = dmin(p, V)
                        s = (4.5 - 0.2 * moved) if 2 <= da <= rng else NEG
                elif t == "MOVE" or t in STATIONARY:
                    if V:
                        da = dmin(p, V)
                        s = (-da if not ranged else -max(0, da - rng) - 2.0 * max(0, 2 - da)) + 0.1 * along
                    elif LK:
                        s = -dmin(p, LK) / 2.0 + 0.1 * along
                    else:
                        s = along
                    if t in STATIONARY:
                        s = min(s, s - 0.01)
        out.append(s)
    return out


def accepted_ids(task, rdir, unit, cands, ctx):
    sc = score_all(task, rdir, unit, cands, ctx)
    best = max(sc) if sc else NEG
    if best <= NEG / 2:
        return [], sc
    return [c["candidate_id"] for c, s in zip(cands, sc) if s >= best - EPS], sc


def behaviour(order):
    """EXECUTE resolves to the behaviour its intent encodes."""
    return order.get("behaviour_task", order["task"]), order.get("behaviour_dir", order["relative_direction"])


# ----------------------------------------------------------------- renderer
HAND_B_INSTRUCTIONS = "Carry out the Hand A order for this unit: choose exactly one legal action."


def _r(v):
    return "%+d" % int(round(v))


def render_options(unit, cands, ctx):
    up = pos(unit)
    out = []
    for c in cands:
        t = c["action_type"]
        txt = str(c.get("option_text", t))
        if t == "MOVE":
            f, l = rel(up, cand_pos(c, unit), ctx["fr"])
            txt = "%s rel F%s L%s" % (txt.split(" ")[0] + " " + txt.split(" ")[1], _r(f), _r(l))
            txt += " " + str(c.get("terrain", ""))
        elif t == "ATTACK":
            tp = (int(c.get("target_q", 0)), int(c.get("target_r", 0)))
            f, l = rel(up, tp, ctx["fr"])
            txt = "%s rel F%s L%s d%d" % (txt, _r(f), _r(l), hdist(up, tp))
        out.append(txt.strip())
    return out


def render_state(order, unit, ctx, turn):
    up = pos(unit)
    cls = str(unit.get("class", "")).upper()
    lines = ["HAND B UNIT ORDER",
             "ORDER task=%s dir=%s intent=%s" % (order["task"], order["relative_direction"], order.get("intent", "")[:140]),
             "FRAME rel F=hexes toward enemy side (+) or own rear (-); L=hexes to own left (+) or right (-)",
             "UNIT %s %s troops=%d/%d mp=%.1f range=%d turn=%d" % (unit["id"], cls, int(unit.get("soldier_count", 0)),
                                                                     int(unit.get("max_count", 0)), float(unit.get("remaining_mp", 0)),
                                                                     RANGE.get(cls.lower(), 1), turn),
             "LINE ahead=%s lat=%s" % (_r(ctx["fwd_coord"](up) - ctx["line"]), _r(ctx["lat_coord"](up)))]
    for o in ctx["own"]:
        if str(o.get("id", "")) == unit["id"]:
            continue
        f, l = rel(up, pos(o), ctx["fr"])
        lines.append("OWN %s %s F%s L%s d%d" % (o.get("id", "?"), str(o.get("class", "?")).upper(), _r(f), _r(l), hdist(up, pos(o))))
    led = ctx["_ledger"]
    for e in foes_of(led, ctx["side"])[:12]:
        f, l = rel(up, pos(e), ctx["fr"])
        lines.append("FOE %s %s F%s L%s d%d %s" % (e.get("id", "?"), str(e.get("class", "?")).upper(), _r(f), _r(l),
                                                  hdist(up, pos(e)), e.get("troop_text", e.get("troop_estimate", "?"))))
    for e in lastknown_of(led, ctx["side"])[:6]:
        f, l = rel(up, pos(e), ctx["fr"])
        lines.append("LAST %s %s F%s L%s d%d" % (e.get("id", "?"), str(e.get("class", "?")).upper(), _r(f), _r(l), hdist(up, pos(e))))
    return "\n".join(lines)


def build_ctx(state, unit):
    ctx = ctx_from(state, unit)
    ctx["_ledger"] = state["ledger"]
    return ctx
