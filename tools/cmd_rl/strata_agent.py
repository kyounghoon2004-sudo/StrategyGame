"""Strata as an AGENT on the HQ-ADV game (2026-10-13, user): the same conditions the human-in-the-loop player had.

 * the full rules text (messages[0] of the first request) in the system prompt,
 * a compact state view + a tactical aid (best targets per unit with the game's own expected damage dealt/taken),
 * macros: the model may let turns pass ("pass_turns": N, or "until_contact": true) like the auto loops did,
 * after every game a post-mortem (timeline of own/enemy soldiers per 5 turns, HQ fieldworks, key events, its own decisions)
   -> the model writes lessons + a plan, kept in notes.json and put in front of the next game,
 * the same seed again and again (the engine is deterministic) until a WIN, then the next seed.

The model answers JSON: {"thought": "...", "orders": {...}, "plan": "...", "pass_turns": N, "until_contact": bool}.

  python -m tools.cmd_rl.strata_agent --out <dir> --seeds 9900000:HARRIER:fixed,9900001:HARRIER:mild --max-games 6
"""
from __future__ import annotations

import argparse
import json
import re
import subprocess
import time
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
PY = "D:/StrategyAI/runtimes/qwen3_8b_rl_v0/.venv/Scripts/python.exe"
VS_RE = re.compile(r"(\S+) eta (\d+) dealt (\d+)-(\d+) taken (\d+)-(\d+)")


def chat(url, model, messages, max_tokens=3500, think=True, timeout=1800):
    body = {"model": model, "messages": messages, "max_tokens": max_tokens, "temperature": 0.6, "stream": False}
    if not think:
        body["chat_template_kwargs"] = {"enable_thinking": False}
    req = urllib.request.Request(url, data=json.dumps(body).encode(), headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        d = json.loads(r.read())
    return d["choices"][0]["message"].get("content") or ""


def parse_json(txt):
    txt = txt.split("</think>")[-1].strip()
    m = re.search(r"\{.*\}", txt, re.S)
    if not m:
        return None
    try:
        return json.loads(m.group(0))
    except ValueError:
        return None


def units(lst):
    """Own/enemy unit lines -> dicts (the first request has dicts, later ones strings)."""
    out = []
    for u in lst:
        if isinstance(u, dict):
            out.append({"id": u["id"], "cls": u["id"].split("_")[1], "q": u["q"], "r": u["r"],
                        "hp": u.get("soldiers", u.get("troops")), "order": u.get("order", ""),
                        "fort": u.get("fortified"), "vs": u.get("vs") or [], "eta": u.get("eta"), "next": u.get("can_strike_next")})
        else:
            m = re.match(r"^(\S+) (-?\d+),(-?\d+) (\d+(?:-\d+)?)( fort (\d+))?", u)
            if not m:
                continue
            out.append({"id": m.group(1), "cls": m.group(1).split("_")[1], "q": int(m.group(2)), "r": int(m.group(3)),
                        "hp": m.group(4), "fort": int(m.group(6)) if m.group(6) else None,
                        "vs": [p.strip() for p in u.split("|", 1)[1].split(";")] if "|" in u else [], "raw": u})
    return out


def hexd(a, b):
    dq, dr = a[0] - b[0], a[1] - b[1]
    return (abs(dq) + abs(dr) + abs(dq + dr)) // 2


def view(d):
    mine, foes = units(d["my_units"]), units(d["enemy_units"])
    L = ["TURN %d of %d (turns left %s)" % (d["turn"], d.get("turn_limit", 60), d.get("turns_left"))]
    L.append("YOUR UNITS (id class pos soldiers fortified order):")
    for u in mine:
        L.append("  %s %s (%d,%d) %s%s %s" % (u["id"], u["cls"], u["q"], u["r"], u["hp"],
                                             " FORT %s" % u["fort"] if u["fort"] else "", u.get("order") or ""))
    L.append("ENEMY (id class pos soldiers-band fortified):")
    hq = next((u for u in mine if u["cls"] == "HQ"), None)
    for u in foes:
        dist = hexd((u["q"], u["r"]), (hq["q"], hq["r"])) if hq else -1
        L.append("  %s %s (%d,%d) %s%s dist_to_my_HQ=%d" % (u["id"], u["cls"], u["q"], u["r"], u["hp"],
                                                           " FORTIFIED(cannot attack)" if u["fort"] else "", dist))
    ev = d.get("events") or []
    if ev:
        L.append("EVENTS SINCE YOUR LAST ANSWER (%d):" % len(ev))
        L += ["  " + e for e in ev[:40]]
    aid = []
    for u in mine:
        opts = []
        for part in u["vs"]:
            m = VS_RE.search(part) if isinstance(part, str) else None
            if m:
                dl, tk = (int(m.group(3)) + int(m.group(4))) / 2, (int(m.group(5)) + int(m.group(6))) / 2
                if dl > 1:
                    opts.append((int(m.group(2)), -(dl - 0.5 * tk), m.group(1), dl, tk))
        opts.sort()
        if opts:
            aid.append("  %s: %s" % (u["id"], "; ".join("%s %s +%d/-%d" % (o[2], "now" if o[0] == 0 else "after 1 move", o[3], o[4])
                                                         for o in opts[:3])))
    if aid:
        L.append("TACTICAL AID (best targets per unit, the game's own expected soldiers dealt/taken):")
        L += aid
    return "\n".join(L), mine, foes


def contact(mine, foes, radius=5):
    return any(hexd((a["q"], a["r"]), (b["q"], b["r"])) <= radius for a in mine for b in foes)


DOCTRINE = """KNOWN FACTS AND TACTICS (verified in earlier games on this scenario; follow them unless the state clearly says otherwise):
FACTS
- BLUE (GX ADV) attacks in a wave along the middle: first enemy cavalry/scouts reach your area around turn 9-14, the main body (infantry, spearmen, archers) around turn 14-20. It attacks the weakest reachable unit, and its units also FORTIFY in place at times.
- A fortified unit cannot move or attack (only counter-attacks melee): fortified BLUE units are inert. Do not waste turns on them; leave them behind.
- ATTACK moves the unit toward its target and out of position; a unit ordered to attack leaves its fieldworks. Only use ATTACK when a kill or a clearly good trade is in the TACTICAL AID. Archers (range 3) take no counter-attack: they are free damage.
- The BLUE HQ starts fortified (180). Each unit can fortify only once per game, so once its fieldworks are broken they never come back. Fieldworks absorb hits first; the rest reaches its soldiers, which never regenerate. So break the fieldworks with a concentrated attack, then keep hitting the soldiers. Cavalry arriving first and alone only wastes its soldiers on fieldworks.
- Distances: your HQ (20,0), BLUE HQ (-20,0), 40 hexes. Infantry/spearmen/archers move 2 hexes per turn (some families 1: read class_stats), cavalry 3: about 18 turns for infantry from your base. To have enough assault turns, the march must start by about turn 30.
TACTICS (the plan that won)
1. Turn 1: R_HQ_1 FORTIFY. Spearmen/infantry fortify in a compact block between the enemy and your HQ (west face around x=15-16, y=-3..3); archers one hex BEHIND the front line (x=17-18) so enemy melee cannot reach them; cavalry fortified in the gaps. Let the wave come; do not advance. Use archers on whatever enters range (eta 0).
2. Turn ~10-22: each turn pick the weakest/most damaged reachable enemy and focus ALL units that can hit it (see TACTICAL AID: sum the expected dealt until it exceeds the enemy's soldiers) - dead enemies do no damage. Keep fortified units fortified unless they secure a kill. Pull back archers that got exposed.
3. As soon as the mobile enemies are dead (about turn 22-30): march EVERY surviving combat unit to the BLUE HQ with ATTACK ENEMY_HQ (you may use pass_turns while marching). Keep the cavalry back (MOVE to about (-13,+-3)) until the infantry is within ~8 hexes of the HQ, then order the cavalry ATTACK ENEMY_HQ so everything arrives together. Leave R_HQ_1 fortified at home.
4. Do not chase fortified or retreating BLUE units; do not stop to kill the last stragglers if the march would start after turn ~30 (leave them to R_HQ_1)."""

SYSTEM_TAIL = """
You play the whole game by answering one JSON object per decision:
{"thought": "<=120 words of reasoning>",
 "orders": {"<unit id>": {"do": "ATTACK|MOVE|RAID|HOLD|FORTIFY", "target": "<enemy id|ENEMY_HQ>" or "to": [q,r]|"MY_HQ"|"ENEMY_HQ"}},
 "plan": "<=300 chars, only when your strategy changes>",
 "pass_turns": <0..15: let this many turns pass with orders standing, unless an enemy comes within 5 hexes or an enemy attack event happens>,
 "until_contact": <true|false: pass turns until first contact>}
"orders" lists only units whose order CHANGES; {} keeps every standing order. Orders persist. Reply with the JSON only."""


class Game:
    def __init__(self, a, seed, style, family, idx, notes):
        self.a, self.seed, self.style, self.family, self.idx = a, seed, style, family, idx
        self.dir = Path(a.out) / ("g%02d_s%d" % (idx, seed))
        self.dir.mkdir(parents=True, exist_ok=True)
        self.notes = notes
        self.timeline = []   # per request: (turn, own_sum, enemy_sum_mid, hq_line)
        self.decisions = []  # (turn, thought, orders, plan)
        self.system = None

    def start(self):
        cmd = [PY, "-m", "tools.cmd_rl.teacher_gx", "--games", "1", "--windows", "1", "--slot", str(self.a.slot),
               "--proxy-port", str(self.a.proxy_port), "--brain-port", str(self.a.brain_port), "--seed0", str(self.seed),
               "--style", self.style, "--family", self.family,
               "--manual-dir", str(self.dir / "manual"), "--out", str(self.dir)]
        self.proc = subprocess.Popen(cmd, cwd=str(ROOT), stdout=open(self.dir / "launcher.out", "w"), stderr=subprocess.STDOUT)

    def play(self):
        self.start()
        n, pass_left, until_contact, last = 1, 0, False, time.time()
        md = self.dir / "manual"
        while True:
            f = md / ("req_%04d.json" % n)
            if not f.exists():
                if time.time() - last > 240 or self.proc.poll() is not None and not f.exists() and n > 1:
                    break
                time.sleep(1)
                continue
            time.sleep(0.3)
            last = time.time()
            req = json.loads(f.read_text(encoding="utf-8"))
            if self.system is None:
                self.system = req["messages"][0]["content"] + chr(10) * 2 + DOCTRINE + chr(10) + SYSTEM_TAIL
            d = json.loads(req["messages"][-1]["content"])
            text, mine, foes = view(d)
            hq_e = next((u for u in foes if u["cls"] == "HQ"), None)
            self.timeline.append((d["turn"], sum(int(u["hp"]) for u in mine if str(u["hp"]).isdigit()),
                                  sum(sum(int(x) for x in str(u["hp"]).split("-")) / len(str(u["hp"]).split("-")) for u in foes
                                      if u["cls"] != "HQ"),
                                  "%s%s" % (hq_e["hp"], " fort %s" % hq_e["fort"] if hq_e and hq_e["fort"] else "") if hq_e else "gone",
                                  [e for e in (d.get("events") or []) if "destroyed" in e][:4]))
            enemy_acted = any((" attack " in e and e.split(" ")[1].startswith("B_")) for e in (d.get("events") or []))
            if d["turn"] > 1 and pass_left > 0 and not contact(mine, foes) and not enemy_acted:
                pass_left -= 1
                (md / ("resp_%04d.txt" % n)).write_text('{"orders": {}}', encoding="utf-8")
                n += 1
                continue
            if d["turn"] > 1 and until_contact and not contact(mine, foes) and not enemy_acted:
                (md / ("resp_%04d.txt" % n)).write_text('{"orders": {}}', encoding="utf-8")
                n += 1
                continue
            until_contact = False
            pass_left = 0
            msgs = [{"role": "system", "content": self.system},
                    {"role": "user", "content": (("LESSONS FROM YOUR PREVIOUS GAMES ON THIS SCENARIO:\n" + self.notes + "\n\n")
                                                 if self.notes else "") + text}]
            ans = None
            for _ in range(2):
                try:
                    ans = parse_json(chat(self.a.url, self.a.model, msgs, think=self.a.think))
                except Exception as e:  # noqa: BLE001
                    ans = None
                    print("chat error", str(e)[:150], flush=True)
                if ans is not None:
                    break
            ans = ans or {}
            orders = ans.get("orders") if isinstance(ans.get("orders"), dict) else {}
            body = {"orders": orders}
            if ans.get("plan"):
                body["plan"] = str(ans["plan"])[:300]
            (md / ("resp_%04d.txt" % n)).write_text(json.dumps(body), encoding="utf-8")
            self.decisions.append((d["turn"], str(ans.get("thought", ""))[:400], orders, ans.get("plan", "")))
            try:
                pass_left = max(0, min(15, int(ans.get("pass_turns") or 0)))
            except (TypeError, ValueError):
                pass_left = 0
            until_contact = bool(ans.get("until_contact"))
            print("g%d T%d decided %d orders; pass=%d until_contact=%s" % (self.idx, d["turn"], len(orders), pass_left, until_contact),
                  flush=True)
            if d["turn"] >= 60:
                break
            n += 1
        time.sleep(4)
        res = ""
        lg = self.dir / "teacher.log"
        if lg.exists():
            for line in lg.read_text(encoding="utf-8", errors="ignore").splitlines():
                if "[TEACHER] t_" in line:
                    res = line
        return res

    def stop(self):
        subprocess.run(["taskkill", "/PID", str(self.proc.pid), "/T", "/F"], capture_output=True)

    def postmortem_text(self, result):
        L = ["RESULT: " + result[-260:], "", "TIMELINE (turn: own soldiers excl HQ not shown / enemy mobile soldiers est / BLUE HQ):"]
        for t in self.timeline:
            if t[0] % 5 == 0 or t[0] <= 2 or t[4]:
                L.append("  T%d own_total=%d enemy_est=%d HQ=%s %s" % (t[0], t[1], t[2], t[3], ("destroyed: " + "; ".join(t[4])) if t[4] else ""))
        L.append("")
        L.append("YOUR DECISIONS (turn: thought | n orders | plan):")
        for t, th, od, pl in self.decisions:
            L.append("  T%d: %s | %d orders | %s" % (t, th[:160], len(od), (pl or "")[:100]))
        return "\n".join(L)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--url", default="http://127.0.0.1:8080/v1/chat/completions")
    ap.add_argument("--model", default="strata")
    ap.add_argument("--out", required=True)
    ap.add_argument("--seeds", default="9900000:HARRIER:fixed")
    ap.add_argument("--max-games", type=int, default=6)
    ap.add_argument("--rotate", action="store_true", help="next seed after every game (not only after a win)")
    ap.add_argument("--slot", type=int, default=5)
    ap.add_argument("--proxy-port", type=int, default=8125)
    ap.add_argument("--brain-port", type=int, default=8135)
    ap.add_argument("--think", action="store_true", help="server-side thinking (long, often cut at max_tokens); default: the model writes a short thought field")
    a = ap.parse_args()
    out = Path(a.out)
    out.mkdir(parents=True, exist_ok=True)
    seeds = [tuple(s.split(":")) for s in a.seeds.split(",")]
    notes_f = out / "notes.json"
    notes = json.loads(notes_f.read_text(encoding="utf-8")) if notes_f.exists() else []
    si, games = 0, 0
    while games < a.max_games and si < len(seeds):
        seed, style, family = int(seeds[si][0]), seeds[si][1], seeds[si][2]
        g = Game(a, seed, style, family, games + 1, (chr(10) * 2).join("[earlier game] %s" % n[:900] for n in notes[-2:]))
        print("=== game %d seed %d %s %s (notes: %d)" % (games + 1, seed, style, family, len(notes)), flush=True)
        try:
            res = g.play()
        finally:
            g.stop()
        games += 1
        print("RESULT", res[-220:], flush=True)
        won = "-> WIN" in res
        pm = g.postmortem_text(res)
        (g.dir / "postmortem_input.txt").write_text(pm, encoding="utf-8")
        try:
            lessons = chat(a.url, a.model, [
                {"role": "system", "content": "You are the RED commander of a hex wargame reviewing the game you just played. Be concrete and factual."},
                {"role": "user", "content": pm + "\n\nWrite (a) the 3-5 most important concrete causes of this result with numbers/turns, "
                                           "(b) mechanics of the game you learned, (c) a revised plan for the next game on the same seed "
                                           "(what to do differently, at which turns), checking each point against the KNOWN FACTS AND TACTICS in your instructions (do not contradict a verified fact). <=200 words."}],
                max_tokens=1500, think=False).split("</think>")[-1].strip()
        except Exception as e:  # noqa: BLE001
            lessons = "post-mortem failed: %s" % str(e)[:100]
        notes.append("%s\n%s" % (res[-140:], lessons))
        notes_f.write_text(json.dumps(notes, indent=1), encoding="utf-8")
        (g.dir / "lessons.txt").write_text(lessons, encoding="utf-8")
        if won or a.rotate:
            si = (si + 1) % len(seeds) if a.rotate else si + 1
            print("WIN -> next seed", flush=True)
    print("done", games, "games", flush=True)


if __name__ == "__main__":
    main()
