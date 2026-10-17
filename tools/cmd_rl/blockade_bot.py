"""Scripted BLUE for the manual-dir BLUE proxy (spar.py --manual): ring the own HQ with units, fortify them, then
answer {} every turn.  Many games at once: requests are told apart by the file, each carries its own state.
  python -m tools.cmd_rl.blockade_bot --dir <out>/manual
"""
import argparse
import json
import time
from pathlib import Path

RING = {"B_INF_2": [-19, 0], "B_INF_1": [-19, -1], "B_SPE_1": [-20, 1], "B_SPE_2": [-21, 1],
        "B_CAV_1": [-20, -1], "B_CAV_2": [-21, 0], "B_ARC_1": [-22, 0], "B_ARC_2": [-22, 1]}
FORT = ["B_INF_1", "B_INF_2", "B_SPE_1", "B_SPE_2", "B_CAV_1", "B_CAV_2"]


def answer(d):
    t = int(d.get("turn") or 0)
    if t == 1:
        ids = {u["id"] for u in d.get("my_units", [])}
        hq = next((u for u in d.get("my_units", []) if u["id"] == "B_HQ_1"), None)
        orders = {"B_HQ_1": {"do": "FORTIFY"}}
        for uid, hx in RING.items():
            if uid in ids:
                orders[uid] = {"do": "MOVE", "to": hx}
        return {"orders": orders, "plan": "Block every hex next to my HQ, fortify, hold."} if hq else {"orders": {}}
    if t == 7:
        return {"orders": {u: {"do": "FORTIFY"} for u in FORT}}
    return {"orders": {}}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dir", required=True)
    a = ap.parse_args()
    d = Path(a.dir)
    done = set()
    while not (d.parent / "BOT_STOP").exists():
        for f in sorted(d.glob("req_*.json")):
            n = f.stem.split("_")[1]
            r = d / ("resp_%s.txt" % n)
            if n in done or r.exists():
                continue
            try:
                req = json.loads(f.read_text(encoding="utf-8"))
                st = json.loads(req["messages"][-1]["content"])
            except Exception:  # noqa: BLE001
                continue
            r.write_text(json.dumps(answer(st)), encoding="utf-8")
            done.add(n)
        time.sleep(0.5)


if __name__ == "__main__":
    main()
