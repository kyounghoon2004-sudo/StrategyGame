"""Option E (2026-10-06): retrieve won-game decisions from situations like the current one and show them to the Brain
as reference examples. Generic: situation features only (turn, forces, threat distances), no mission or GX style.
Source: deepseek-v4.1-flash calls of the games it won (cmd_collect v3 / v4_fort / v6_fewerloss). Examples from the
same seed as the current game are never used."""
from __future__ import annotations

import json
import re
from pathlib import Path

from tools.plan_search.cloud_brain import extract_orders

B = Path(__file__).resolve().parents[2] / "artifacts" / "brain_pipeline_v1"
RUNS = ("cmd_collect_v3", "cmd_collect_v4_fort", "cmd_collect_v6_fewerloss")
SCALE = {"turns_left": 20, "my_units": 2, "enemy_units": 2, "my_soldiers": 600, "enemy_troops": 600,
         "enemy_eta_my_hq": 3, "my_eta_enemy_hq": 3, "enemy_fortified": 2, "my_hq_soldiers": 100}
_INDEX: list | None = None


def _mid(band) -> float:
    nums = [float(x) for x in re.findall(r"\d+", str(band or ""))][:2]
    return sum(nums) / len(nums) if nums else 0.0


def _seed(tag: str) -> str:
    m = re.search(r"_s(\d+)$", tag or "")
    return m.group(1) if m else ""


def features(pk: dict) -> dict:
    mine = [m for m in pk.get("my_units", []) if m.get("class") != "HQ"]
    foes = [f for f in pk.get("enemy_units", []) if f.get("class") != "HQ"]
    my_hq = next((m for m in pk.get("my_units", []) if m.get("class") == "HQ"), {})
    return {
        "turns_left": float(pk.get("turns_left") or 0),
        "my_units": float(len(mine)),
        "enemy_units": float(len(foes)),
        "my_soldiers": float(sum(int(m.get("soldiers") or 0) for m in mine)),
        "enemy_troops": float(sum(_mid(f.get("troops")) for f in foes)),
        "enemy_eta_my_hq": float(min([f.get("eta_strike_my_hq", 30) for f in foes] or [30])),
        "my_eta_enemy_hq": float(min([(m.get("eta") or {}).get("strike_enemy_hq", 30) for m in mine] or [30])),
        "enemy_fortified": float(sum(1 for f in foes if f.get("fortified"))),
        "my_hq_soldiers": float(my_hq.get("soldiers") or 0),
    }


def _index() -> list:
    global _INDEX
    if _INDEX is None:
        _INDEX = []
        for run in RUNS:
            won = set()
            for line in (B / run / "results.jsonl").read_text(encoding="utf-8").splitlines():
                r = json.loads(line)
                if r.get("kind") == "WIN":
                    won.add(r["game"])
            for line in (B / run / "raw" / "calls.jsonl").read_text(encoding="utf-8").splitlines():
                c = json.loads(line)
                if c.get("request") != "VICTORY_COMMAND" or c.get("tag") not in won or not c.get("raw"):
                    continue
                if (c.get("cloud") or {}).get("skipped"):
                    continue
                doc = extract_orders(c["raw"])
                try:
                    pk = json.loads(c["messages"][-1]["content"])
                except ValueError:
                    continue
                if doc is None or not pk.get("my_units"):
                    continue
                _INDEX.append({"seed": _seed(c["tag"]), "f": features(pk), "doc": doc})
    return _INDEX


def _describe(f: dict) -> str:
    return ("%d turns left; RED %d units, %d soldiers (HQ %d); BLUE %d units, ~%d troops, %d fortified; "
            "nearest BLUE strike on your HQ in %d turns; your nearest strike on BLUE HQ in %d turns"
            % (f["turns_left"], f["my_units"], f["my_soldiers"], f["my_hq_soldiers"], f["enemy_units"],
               f["enemy_troops"], f["enemy_fortified"], f["enemy_eta_my_hq"], f["my_eta_enemy_hq"]))


def examples_block(packet_json: str, tag: str, k: int = 2) -> str:
    try:
        pk = json.loads(packet_json)
    except ValueError:
        return ""
    cur = features(pk)
    seed = _seed(tag)
    rows = [r for r in _index() if not (seed and r["seed"] == seed)]
    rows.sort(key=lambda r: sum(abs(r["f"][key] - cur[key]) / SCALE[key] for key in SCALE))
    out = []
    for i, r in enumerate(rows[:k], 1):
        d = r["doc"]
        out.append("Example %d (a won battle) -- situation: %s\n  plan: %s\n  orders: %s" % (
            i, _describe(r["f"]), d.get("plan", ""), json.dumps(d.get("orders", {}), ensure_ascii=False)))
    if not out:
        return ""
    return ("=== REFERENCE: decisions from won battles in similar situations (other maps and armies; unit ids differ; "
            "use them as ideas, not as orders) ===\n" + "\n".join(out) + "\n\n")
