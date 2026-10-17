"""Probe items for the checkpoint sweep: (A) code-generated HQ-blockade cold prompts with code-computed ground truth,
(B) recorded HQ-mission game packets (messages as the game sent them) scored by code."""
import json, random, re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
BP = ROOT / "artifacts" / "brain_pipeline_v1"
NB = [(1, 0), (-1, 0), (0, 1), (0, -1), (1, -1), (-1, 1)]
RULES = ("Rules of the game: the board is a hex grid. A unit can move a few hexes per turn, but no unit can enter or pass through a hex that "
         "holds another unit (friend or enemy). A melee attack needs the attacker to be on a hex directly next to its target; the defender strikes back. "
         "A ranged attack (archers, range 3) can hit a target 2 or 3 hexes away, is NOT blocked by units standing in between, and gets no counter-attack. "
         "A fortified unit has 180 points of earthworks that absorb damage before its soldiers are hurt. You win only by destroying the enemy HQ; "
         "you lose if your own HQ is destroyed.")


def dist(a, b):
    dq, dr = a[0] - b[0], a[1] - b[1]
    return (abs(dq) + abs(dr) + abs(dq + dr)) // 2


def nbrs(h):
    return [(h[0] + dq, h[1] + dr) for dq, dr in NB]


def make_cold(n_per_type=4, seed=11):
    rng = random.Random(seed)
    items = []
    names = {"INF": "infantry", "SPE": "spearmen", "CAV": "cavalry", "ARC": "archers", "SCT": "scout"}
    for typ in ("A_ring_archers_in_range", "B_ring_archers_far", "C_one_free_hex", "D_no_ring"):
        for k in range(n_per_type):
            side = rng.choice([-1, 1])
            hq = (side * rng.randint(18, 24), rng.randint(-3, 3))
            occupied = {}  # hex -> description
            ring = nbrs(hq)
            kinds = ["infantry", "cavalry", "spearmen", "infantry", "cavalry", "spearmen"]
            rng.shuffle(kinds)
            free = []
            if typ == "D_no_ring":
                guards = rng.sample(ring, 2)
                for g in guards:
                    occupied[g] = "enemy %s, fortified" % kinds.pop()
                free = [h for h in ring if h not in occupied]
            else:
                free_cnt = 1 if typ == "C_one_free_hex" else 0
                free = rng.sample(ring, free_cnt)
                for h in ring:
                    if h not in free:
                        occupied[h] = "enemy %s, fortified" % kinds.pop()
            behind = [h for h in {(x[0] + (x[0] - hq[0]), x[1] + (x[1] - hq[1])) for x in ring} if h not in ring and h != hq][:2]
            for h in behind:
                occupied[h] = "enemy archers, not fortified"
            # my units sit on the outside, toward my side
            toward = -side
            mine = {}
            def place(label, want_dist=None, tries=400):
                for _ in range(tries):
                    h = (hq[0] + toward * rng.randint(1, 5) + rng.randint(-2, 2), hq[1] + rng.randint(-4, 4))
                    d = dist(h, hq)
                    if h in occupied or h in mine.values() or h == hq or d < 2:
                        continue
                    if want_dist and not (want_dist[0] <= d <= want_dist[1]):
                        continue
                    mine[label] = h
                    return
                raise RuntimeError("placement failed")
            arch_d = (2, 3) if typ != "B_ring_archers_far" else (6, 8)
            place("archers1", arch_d); place("archers2", arch_d)
            for lab in ("cavalry1", "cavalry2", "infantry1", "infantry2", "spearmen1", "spearmen2", "scout1"):
                place(lab, (2, 6))
            gt = {"type": typ, "hq": hq, "free_adjacent": free, "occupied": [list(h) for h in occupied],
                  "my_units": {k: list(v) for k, v in mine.items()},
                  "archers_in_range_now": [k for k, v in mine.items() if k.startswith("archers") and 2 <= dist(v, hq) <= 3],
                  "ring_full": len(free) == 0 and typ != "D_no_ring"}
            ring_txt = "; ".join("(%d,%d) %s" % (h[0], h[1], occupied[h]) if h in occupied else "(%d,%d) EMPTY" % h for h in ring)
            beh = "; ".join("(%d,%d) %s" % (h[0], h[1], occupied[h]) for h in behind)
            mu = "; ".join("%s at (%d,%d)" % (k.rstrip("12"), v[0], v[1]) if False else "%s%s at (%d,%d)" % (k[:-1] if k[-1] in "12" else k, "", v[0], v[1]) for k, v in mine.items())
            prompt = ("Concrete state, turn 30 of 60. Coordinates are (q,r) on a hex grid; two hexes are neighbours if they differ by (1,0), (-1,0), (0,1), (0,-1), (1,-1) or (-1,1).\n"
                      "Enemy HQ at (%d,%d), 150-250 soldiers left, 54 points of earthworks. The six hexes touching it: %s. Other enemy units: %s.\n"
                      "My units: %s. All are ordered 'attack the enemy HQ'. The units have not damaged the HQ for many turns.\n\n" % (hq[0], hq[1], ring_txt, beh, mu)
                      + RULES + "\n\nExplain in a short paragraph (1) what, if anything, is stopping my attack on the HQ, and (2) which of my units should do what, in what order, to destroy the HQ.")
            items.append({"id": "cold_%s_%d" % (typ[0], k), "kind": "cold", "prompt": prompt, "truth": gt})
    return items


def make_packets(n=12, seed=5):
    rows = [json.loads(l) for l in (BP / "synth_adv_v1" / "situations_adv.jsonl").read_text(encoding="utf-8").splitlines()]
    rng = random.Random(seed)
    pool = [r for r in rows if 6 <= r["turn"] <= 50 and r["turn"] % 2 == 0]
    by = {}
    for r in pool:
        by.setdefault(r["game"], []).append(r)
    games = sorted(by)
    rng.shuffle(games)
    items = []
    for g in games[:n]:
        r = rng.choice(by[g])
        last = [m["content"] for m in r["messages"] if m["role"] == "user"][-1]
        items.append({"id": "pkt_%s_t%d" % (g, r["turn"]), "kind": "packet", "messages": r["messages"],
                      "mine": sorted(set(re.findall(r"R_[A-Z]{2,3}_\d+", last))), "foes": sorted(set(re.findall(r"B_[A-Z]{2,3}_\d+", last)))})
    return items


if __name__ == "__main__":
    c = make_cold(); p = make_packets()
    print(len(c), len(p)); print(c[0]["prompt"]); print(json.dumps(c[0]["truth"]))
    print(c[4]["truth"]["archers_in_range_now"], c[8]["truth"]["free_adjacent"], c[12]["truth"]["free_adjacent"])
