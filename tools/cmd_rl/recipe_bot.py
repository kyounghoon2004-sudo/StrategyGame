"""The hand-found recipe as a fixed program (2026-10-13): plays one HQ-ADV game as RED through the manual-dir protocol.

 1. turn 1: block around the own HQ (infantry/spearmen/cavalry fortified, archers directly behind), HQ fortified.
 2. contact: focus fire on the weakest reachable enemy (the game's own expected damage), archers shoot from where they are.
 3. when no mobile enemy is left, or at turn MARCH_BY: everyone ATTACK ENEMY_HQ; cavalry waits west of the HQ until the
    leading infantry is within 8 hexes, then joins.
It is a test of "is there a recipe that works on every seed", not a learner.

  python -m tools.cmd_rl.recipe_bot --seed 9970000 --style SPEARHEAD --family fixed --slot 6 --out <dir>
"""
from __future__ import annotations

import argparse
import json
import re
import subprocess
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
PY = "D:/StrategyAI/runtimes/qwen3_8b_rl_v0/.venv/Scripts/python.exe"
VS = re.compile(r"(\S+) eta (\d+) dealt (\d+)-(\d+) taken (\d+)-(\d+)")
BLOCK = {"R_INF_2": (16, 0), "R_SPE_1": (15, 1), "R_INF_1": (16, -3), "R_SPE_2": (16, 3),
         "R_ARC_1": (17, -1), "R_ARC_2": (17, 2), "R_CAV_1": (16, -2), "R_CAV_2": (16, 2), "R_SCT_1": (19, -4)}
MARCH_BY = 30


def hexd(a, b):
    dq, dr = a[0] - b[0], a[1] - b[1]
    return (abs(dq) + abs(dr) + abs(dq + dr)) // 2


def parse(d):
    mine, foes = {}, {}
    for u in d["my_units"]:
        if isinstance(u, dict):
            mine[u["id"]] = {"pos": (u["q"], u["r"]), "hp": int(u["soldiers"]), "fort": False, "vs": u.get("vs") or []}
        else:
            m = re.match(r"^(\S+) (-?\d+),(-?\d+) (\d+)( fort (\d+))?", u)
            if m:
                mine[m.group(1)] = {"pos": (int(m.group(2)), int(m.group(3))), "hp": int(m.group(4)), "fort": bool(m.group(5)),
                                    "vs": [p.strip() for p in u.split("|", 1)[1].split(";")] if "|" in u else []}
    for e in d["enemy_units"]:
        if isinstance(e, dict):
            band = str(e.get("troops"))
            foes[e["id"]] = {"pos": (e["q"], e["r"]), "hp": sum(int(x) for x in band.split("-")) / len(band.split("-")),
                             "fort": bool(e.get("fortified"))}
        else:
            m = re.match(r"^(\S+) (-?\d+),(-?\d+) (\d+)(?:-(\d+))?( fort (\d+))?", e)
            if m:
                lo, hi = int(m.group(4)), int(m.group(5) or m.group(4))
                foes[m.group(1)] = {"pos": (int(m.group(2)), int(m.group(3))), "hp": (lo + hi) / 2, "fort": bool(m.group(6))}
    return mine, foes


def focus(mine, foes):
    """Greedy focus fire: weakest mobile enemy first, give it units until the expected damage covers its soldiers."""
    opts = {}
    for uid, u in mine.items():
        if uid == "R_HQ_1" or uid == "R_SCT_1":
            continue
        arc = "ARC" in uid
        for part in u["vs"]:
            m = VS.search(part) if isinstance(part, str) else None
            if not m:
                continue
            tgt, eta = m.group(1), int(m.group(2))
            dl, tk = (int(m.group(3)) + int(m.group(4))) / 2, (int(m.group(5)) + int(m.group(6))) / 2
            if dl <= 2 or tgt not in foes or foes[tgt]["fort"] and not arc:
                continue
            if eta > 1 or (arc and eta > 0):
                continue
            opts.setdefault(uid, []).append((tgt, eta, dl, tk))
    mobile = [t for t, e in foes.items() if not e["fort"] and not t.endswith("HQ_1")]
    assign = {}
    for t in sorted(mobile, key=lambda x: foes[x]["hp"]):
        need, got, cands = foes[t]["hp"] * 0.95, 0.0, []
        for uid, os_ in opts.items():
            if uid in assign:
                continue
            for (tt, eta, dl, tk) in os_:
                if tt == t and (tk <= 1.5 * dl or foes[t]["hp"] < 80):
                    cands.append((dl - 0.5 * tk - (8 if eta else 0), uid, dl))
                    break
        cands.sort(reverse=True)
        for _, uid, dl in cands:
            if got >= need:
                break
            assign[uid] = t
            got += dl
    return assign, mobile


class Bot:
    def __init__(self, a):
        self.a = a
        self.dir = Path(a.out)
        self.dir.mkdir(parents=True, exist_ok=True)
        self.fortified, self.marching, self.cav_sent = set(), False, False
        self.log = []

    def run(self):
        cmd = [PY, "-m", "tools.cmd_rl.teacher_gx", "--games", "1", "--windows", "1", "--slot", str(self.a.slot),
               "--proxy-port", str(8120 + self.a.slot), "--brain-port", str(8130 + self.a.slot), "--seed0", str(self.a.seed),
               "--style", self.a.style, "--family", self.a.family, "--manual-dir", str(self.dir / "manual"), "--out", str(self.dir)] + (["--show"] if self.a.show else [])
        proc = subprocess.Popen(cmd, cwd=str(ROOT), stdout=open(self.dir / "launcher.out", "w"), stderr=subprocess.STDOUT)
        n, last = 1, time.time()
        md = self.dir / "manual"
        try:
            while True:
                f = md / ("req_%04d.json" % n)
                if not f.exists():
                    if time.time() - last > 180:
                        break
                    time.sleep(1)
                    continue
                time.sleep(0.3)
                last = time.time()
                d = json.loads(json.loads(f.read_text(encoding="utf-8"))["messages"][-1]["content"])
                mine, foes = parse(d)
                orders = self.decide(d["turn"], mine, foes)
                body = {"orders": orders}
                if d["turn"] == 1:
                    body["plan"] = "Fortified block at my HQ, focus fire on the wave, then march everyone on the BLUE HQ together."
                (md / ("resp_%04d.txt" % n)).write_text(json.dumps(body), encoding="utf-8")
                if d["turn"] >= 60:
                    break
                n += 1
            time.sleep(5)
        finally:
            subprocess.run(["taskkill", "/PID", str(proc.pid), "/T", "/F"], capture_output=True)
        res = ""
        lg = self.dir / "teacher.log"
        if lg.exists():
            for line in lg.read_text(encoding="utf-8", errors="ignore").splitlines():
                if "[TEACHER] t_" in line:
                    res = line
        (self.dir / "result.txt").write_text(res + "\n" + "\n".join(self.log), encoding="utf-8")
        print(res, flush=True)

    def decide(self, t, mine, foes):
        orders = {}
        if t == 1:
            orders["R_HQ_1"] = {"do": "FORTIFY"}
            for uid in ("R_INF_2", "R_SPE_1"):
                if uid in mine:
                    orders[uid] = {"do": "FORTIFY"}
                    self.fortified.add(uid)
            for uid, pos in BLOCK.items():
                if uid not in ("R_INF_2", "R_SPE_1") and uid in mine:
                    orders[uid] = {"do": "MOVE", "to": list(pos)}
            return orders
        if not self.marching:
            for uid in ("R_INF_1", "R_SPE_2", "R_CAV_1", "R_CAV_2"):
                if uid in mine and uid not in self.fortified and mine[uid]["pos"] == BLOCK[uid] and not mine[uid]["fort"]:
                    orders[uid] = {"do": "FORTIFY"}
                    self.fortified.add(uid)
            assign, mobile = focus(mine, foes)
            for uid, tgt in assign.items():
                orders[uid] = {"do": "ATTACK", "target": tgt}
                self.fortified.discard(uid)
            if (t >= 12 and not mobile) or t >= MARCH_BY:
                self.marching = True
                self.log.append("march starts at turn %d (mobile enemies left: %s)" % (t, mobile))
        if self.marching:
            hq = foes.get("B_HQ_1")
            if not getattr(self, "march_issued", False):
                for uid in mine:
                    if uid in ("R_HQ_1", "R_SCT_1"):
                        continue
                    if "CAV" in uid:
                        orders[uid] = {"do": "MOVE", "to": [-13, -3 if uid.endswith("1") else 3]}
                    else:
                        orders[uid] = {"do": "ATTACK", "target": "ENEMY_HQ"}
                self.march_issued = True
            elif hq and not self.cav_sent:
                lead = min((hexd(u["pos"], hq["pos"]) for k, u in mine.items() if k.split("_")[1] in ("INF", "SPE")), default=99)
                if lead <= 8:
                    for uid in mine:
                        if "CAV" in uid:
                            orders[uid] = {"do": "ATTACK", "target": "ENEMY_HQ"}
                    self.cav_sent = True
                    self.log.append("cavalry joins at turn %d (lead %d from HQ)" % (t, lead))
        return orders


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--seed", type=int, required=True)
    ap.add_argument("--style", required=True)
    ap.add_argument("--family", required=True)
    ap.add_argument("--slot", type=int, required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--show", action="store_true")
    Bot(ap.parse_args()).run()


if __name__ == "__main__":
    main()
