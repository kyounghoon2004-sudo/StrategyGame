"""Code-computed AID for a teacher model (2026-10-17, user): the numbers a model otherwise re-derives in its thinking (eta /
arrival turns, the game's own combat previews, HQ siege timing, threats to my HQ, HQ ring occupancy, the standing plan),
computed from the request's "state". Facts only, no tactics advice. Given to the TEACHER only; the student prompt is unchanged.
Reuses the combat-preview parsing of tools/cmd_rl/strata_agent2.py (TACTICAL AID), without its DOCTRINE.
"""
import re

VS_RE = re.compile(r"(\S+) eta (\d+) dealt (\d+)-(\d+) taken (\d+)-(\d+)(?: fw (\d+))?")


def hexd(a, b):
    dq, dr = a[0] - b[0], a[1] - b[1]
    return (abs(dq) + abs(dr) + abs(dq + dr)) // 2


def nbrs(q, r):
    return [(q + 1, r), (q - 1, r), (q, r + 1), (q, r - 1), (q + 1, r - 1), (q - 1, r + 1)]


RULE_KEYS = ("counter-attack", "ranged attack", "only CAVALRY may move on", "one unit per hex", "fieldworks of 180 HP",
             "only ONCE per game", "Units act one at a time")
# confirmed in the game code by the user (2026-10-17); not in the student's system prompt wording
ENGINE_NOTE = ("Fieldworks damage accumulates attack by attack within a turn; once the fieldworks reach 0, the remaining attacks "
               "of that turn hit the soldiers directly.")


def rule_quotes(system):
    """Sentences of the system prompt (verbatim) about the mechanics models keep re-deriving or doubting."""
    if not system:
        return []
    sents = re.split(r"(?<=[.:])\s+(?=[A-Z\"(-])", " ".join(system.split()))
    return [s for s in sents if any(k in s for k in RULE_KEYS)]


def is_collapse(system):
    return bool(system) and "units other than the HQ" in system


def collapse_share(system):
    m = re.search(r"destroy (\d+)% of BLUE's units", system or "")
    return int(m.group(1)) / 100.0 if m else 0.6


def aid_collapse(st, system, start=None, targets=True):
    """Collapse games (win = destroy the stated share of BLUE's non-HQ units): kill progress, loss margin, previews, threats."""
    import math
    turn, limit = int(st.get("turn") or 0), int(st.get("turn_limit") or 60)
    mine = [u for u in st.get("my_units") or [] if isinstance(u, dict) and "q" in u]
    foes = [u for u in st.get("enemy_units") or [] if isinstance(u, dict) and "q" in u]
    share = collapse_share(system)
    nb = sum(1 for u in foes if u.get("class") != "HQ")
    nr = sum(1 for u in mine if u.get("class") != "HQ")
    sb, sr = (start or {}).get("blue", nb), (start or {}).get("red", nr)
    need_b, need_r = math.ceil(share * sb), math.ceil(share * sr)
    L = ["AID (computed by code from this request's own numbers; exact - do not recompute them):",
         "turn %d of %d, %d turns left" % (turn, limit, limit - turn + 1)]
    cp = st.get("current_plan")
    if isinstance(cp, dict) and cp.get("text"):
        L.append("standing plan (since turn %s): %s" % (cp.get("since_turn"), cp["text"]))
    L.append("WIN PROGRESS: BLUE non-HQ units destroyed %d of %d; you win at %d (need %d more). YOUR LOSSES: %d of %d non-HQ "
             "units; you lose at %d (%d more losses allowed)." % (sb - nb, sb, need_b, max(0, need_b - (sb - nb)), sr - nr, sr,
                                                                 need_r, max(0, need_r - (sr - nr) - 1)))
    rq = rule_quotes(system)
    win = [x for x in re.split(r"(?<=[.:])\s+(?=[A-Z\"(-])", " ".join((system or "").split()))
           if x.startswith(("WIN:", "LOSE:", "An HQ is an ordinary unit"))]
    L.append("YOUR HQ DOES NOT COUNT in this battle: losing it neither ends the battle nor counts toward your losses. Do NOT "
             "plan to protect, guard or fortify your HQ; use it as one more combat unit. Only BLUE's non-HQ units you destroy "
             "win the battle, only your non-HQ units you lose can lose it.")
    if win or rq:
        L.append("RULES (quoted from your rules): " + " ".join(win + rq) + " " + ENGINE_NOTE)
    L.append("MY UNITS: id class (q,r) soldiers/start order | best 3 targets from the game's preview (eta, soldiers dealt/taken, "
             "fw = fieldworks damage):")
    for u in mine:
        opts = []
        for part in u.get("vs") or []:
            m = VS_RE.search(str(part))
            if not m:
                continue
            e, et, d0, d1, t0, t1, fw = m.group(1), int(m.group(2)), int(m.group(3)), int(m.group(4)), int(m.group(5)), int(
                m.group(6)), int(m.group(7) or 0)
            opts.append((et, -((d0 + d1) / 2 - 0.5 * (t0 + t1) / 2 + fw * 0.2), "%s eta%d +%d-%d/-%d-%d%s" % (
                e, et, d0, d1, t0, t1, " fw%d" % fw if fw else "")))
        opts.sort()
        L.append("  %s %s (%d,%d) %s/%s %s | %s" % (u["id"], u.get("class"), u["q"], u["r"], u.get("soldiers"), u.get("start"),
                                                   u.get("order") or "no order",
                                                   ("; ".join(o[2] for o in opts[:3]) or "-") if targets else "targets: see the turn message"))
    nexts = ["%s -> %s" % (u["id"], ",".join(u["can_strike_next"])) for u in foes if u.get("can_strike_next")]
    L.append("BLUE units that can attack one of mine next turn: %s" % ("; ".join(nexts) or "none"))
    L.append("BLUE units: " + "; ".join("%s %s (%d,%d) %s%s" % (u["id"], u.get("class"), u["q"], u["r"], u.get("troops"),
                                                                 " fort %s" % u["fortified"] if u.get("fortified") else "")
                                         for u in foes))
    return "\n".join(L)


def aid_text(st, targets=True, system=None, start=None):
    """targets=False drops the best-targets column (non-plan turns: it pulled a model toward chasing units).
    system = the request's system prompt: its mechanics sentences are quoted verbatim (no new rules).
    A collapse game (system prompt: win by destroying BLUE's units other than the HQ) gets aid_collapse instead."""
    if is_collapse(system):
        return aid_collapse(st, system, start=start, targets=targets)
    turn = int(st.get("turn") or 0)
    limit = int(st.get("turn_limit") or 60)
    mine = [u for u in st.get("my_units") or [] if isinstance(u, dict) and "q" in u]
    foes = [u for u in st.get("enemy_units") or [] if isinstance(u, dict) and "q" in u]
    if not mine:
        return ""
    ehq = next((u for u in foes if u.get("class") == "HQ"), None)
    mhq = next((u for u in mine if u.get("class") == "HQ"), None)
    L = ["AID (computed by code from this request's own numbers; exact - do not recompute them):",
         "turn %d of %d, %d turns left" % (turn, limit, limit - turn + 1)]
    arr = sorted((turn + int((u.get("eta") or {})["strike_enemy_hq"]), u["id"]) for u in mine
                 if u.get("class") != "HQ" and (u.get("eta") or {}).get("strike_enemy_hq") is not None)
    if arr:
        L.append("ARRIVAL TURN in strike range of the BLUE HQ (at current orders and speed, path permitting): " +
                 ", ".join("%s t%d" % (i, t) for t, i in arr))
    rq = rule_quotes(system)
    if rq:
        L.append("RULES THAT DECIDE A SIEGE (quoted from your rules): " + " ".join(rq) + " " + ENGINE_NOTE)
    cp = st.get("current_plan")
    if isinstance(cp, dict) and cp.get("text"):
        L.append("standing plan (since turn %s): %s" % (cp.get("since_turn"), cp["text"]))
    if ehq:
        hq = (ehq["q"], ehq["r"])
        where = {(u["q"], u["r"]): u["id"] for u in mine + foes}
        ring = nbrs(*hq)
        held_b = [where[h] for h in ring if h in where and where[h].startswith("B_")]
        held_r = [where[h] for h in ring if h in where and where[h].startswith("R_")]
        L.append("BLUE HQ %s at (%d,%d): troops %s, fieldworks %s. Ring of 6: %d BLUE (%s), %d RED (%s), %d free." % (
            ehq["id"], hq[0], hq[1], ehq.get("troops"), ehq.get("fortified") or 0, len(held_b), ",".join(held_b) or "-",
            len(held_r), ",".join(held_r) or "-", 6 - len(held_b) - len(held_r)))
    L.append("MY UNITS: id class (q,r) soldiers/start order | arrives in strike range of BLUE HQ at turn | HQ preview | best 3 "
             "targets from the game's preview (eta, soldiers dealt/taken, fw = fieldworks damage):")
    sched = []
    for u in mine:
        if u.get("class") == "HQ":
            L.append("  %s HQ (%d,%d) %s fort %s" % (u["id"], u["q"], u["r"], u.get("soldiers"), u.get("fortified") or 0))
            continue
        eta = (u.get("eta") or {}).get("strike_enemy_hq")
        arr = turn + int(eta) if eta is not None else None
        opts, hqp = [], ""
        for part in u.get("vs") or []:
            m = VS_RE.search(str(part))
            if not m:
                continue
            e, et, d0, d1, t0, t1, fw = m.group(1), int(m.group(2)), int(m.group(3)), int(m.group(4)), int(m.group(5)), int(
                m.group(6)), int(m.group(7) or 0)
            if e.startswith("B_HQ"):
                hqp = "HQ: fw %d/hit, dealt %d-%d, taken %d-%d" % (fw, d0, d1, t0, t1)
                if arr is not None:
                    sched.append((arr, u["id"], fw))
                continue
            opts.append((et, -((d0 + d1) / 2 - 0.5 * (t0 + t1) / 2 + fw * 0.2), "%s eta%d +%d-%d/-%d-%d%s" % (
                e, et, d0, d1, t0, t1, " fw%d" % fw if fw else "")))
        opts.sort()
        L.append("  %s %s (%d,%d) %s/%s %s | HQ by t%s | %s | %s" % (
            u["id"], u.get("class"), u["q"], u["r"], u.get("soldiers"), u.get("start"), u.get("order") or "no order",
            arr if arr is not None else "?", hqp or "HQ: no preview",
            ("; ".join(o[2] for o in opts[:3]) or "-") if targets else "targets: see the turn message"))
    if ehq and sched:
        sched.sort()
        fw0 = int(ehq.get("fortified") or 0)
        acc, cum, cuts = [], 0, []
        for t in range(turn, limit + 1):
            per = sum(f for a, _, f in sched if a <= t)
            if per:
                cum += per
                if not cuts and cum >= fw0:
                    cuts.append(t)
        arrivals = ", ".join("%s t%d" % (i, a) for a, i, _ in sched)
        L.append("SIEGE TIMING (each unit attacking the BLUE HQ every turn from its arrival, fieldworks %d): "
                 "arrivals %s; fieldworks gone by turn %s." % (fw0, arrivals, cuts[0] if cuts else "never before the limit"))
    if targets:  # plan turns only: the multi-turn siege estimate (tools/synth_adv_v1/siege_calc.py, validated 574/574 hits)
        try:
            from tools.synth_adv_v1.siege_calc import siege_text
            sx = siege_text(st)
            if sx:
                L.append(sx)
        except Exception:  # noqa: BLE001  the AID must never break a request
            pass
    threats = [u for u in foes if u.get("class") != "HQ" and u.get("eta_strike_my_hq") is not None and int(u["eta_strike_my_hq"]) <= 8]
    nexts = ["%s -> %s" % (u["id"], ",".join(u["can_strike_next"])) for u in foes if u.get("can_strike_next")]
    L.append("THREAT TO MY HQ (BLUE units that can strike it within 8 turns): %s" % (
        ", ".join("%s t%d" % (u["id"], turn + int(u["eta_strike_my_hq"])) for u in threats) or "none"))
    L.append("BLUE units that can attack one of mine next turn: %s" % ("; ".join(nexts) or "none"))
    L.append("BLUE units: " + "; ".join("%s (%d,%d) %s%s" % (u["id"], u["q"], u["r"], u.get("troops"),
                                                              " fort %s" % u["fortified"] if u.get("fortified") else "")
                                         for u in foes if u.get("class") != "HQ"))
    return "\n".join(L)
