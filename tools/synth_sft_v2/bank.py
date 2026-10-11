"""Synthetic commander SFT v2 (2026-10-09), step 1: the bank of real teacher wins.

For every winning game in the real SFT collection (artifacts/brain_pipeline_v1/sft_collect_v2/**/sft_rows.json):
its job (seed, tier, GX style, family, army size), the exact rule overlay it ran with, and its answers by turn. A game
is deterministic given these, so any of its situations can be played again in Godot and branched (branch.py).

  python -m tools.synth_sft_v2.bank        -> artifacts/brain_pipeline_v1/synth_sft_v2/bank.json
"""
from __future__ import annotations

import glob
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
COLL = ROOT / "artifacts" / "brain_pipeline_v1" / "sft_collect_v2"
OUT = ROOT / "artifacts" / "brain_pipeline_v1" / "synth_sft_v2"
USER_DIR = Path.home() / "AppData" / "Roaming" / "Godot" / "app_userdata" / "[unnamed project]"
ROW_FILES = ["sft_rows.json", "agy_gemini38_expand/sft_rows.json", "agy_gemini38_parallel/sft_rows.json",
             "opencode_spacebunny_expand/sft_rows.json", "opencode_step5_expand/sft_rows.json"]


def overlay_of(game_json: Path) -> str:
    """The rule overlay file the game ran with, if it is still there unchanged (same episode id)."""
    ep = json.loads(game_json.read_text(encoding="utf-8")).get("episode") or {}
    sp = str(ep.get("spec_path", ""))
    if not sp.startswith("user://"):
        return ""
    f = USER_DIR / sp.replace("user://", "")
    try:
        return str(f) if f.exists() and json.loads(f.read_text(encoding="utf-8")).get("episode_id") == ep.get("episode_id") else ""
    except ValueError:
        return ""


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    jobs, game_files = {}, {}
    # Explicit depths, no recursive glob: the collection's runtime copies hold junctions back into artifacts/.
    for depth in ("", "*", "*/*"):
        for gl in glob.glob(str(COLL / depth / "games.jsonl")):
            if "smoke" in gl:
                continue
            for line in Path(gl).read_text(encoding="utf-8").splitlines():
                if line.strip():
                    j = json.loads(line)
                    jobs.setdefault(j["game"], j)
            for gf in glob.glob(str(Path(gl).parent / "games" / "*.json")):
                game_files.setdefault(Path(gf).stem, Path(gf))
    rows = [(f, i, x) for f in ROW_FILES for i, x in enumerate(json.loads((COLL / f).read_text(encoding="utf-8")))]
    bank, missing = {}, []
    for f, i, x in rows:
        g = x["game"]
        if g not in bank:
            j, gf = jobs.get(g), game_files.get(g)
            if j is None or gf is None:
                missing.append(g)
                bank[g] = None
                continue
            rec = json.loads(gf.read_text(encoding="utf-8"))
            size = j.get("army_size") or (rec.get("units") or {}).get("red", {}).get("start")
            bank[g] = {"game": g, "seed": int(j["seed"]), "tier": j["tier"], "style": j["style"], "family": j["family"],
                       "army_size": int(size), "game_file": str(gf), "overlay": overlay_of(gf),
                       "outcome": rec.get("outcome"), "turn": rec.get("turn"), "units": rec.get("units"),
                       "teacher": x.get("teacher_model", j.get("teacher_model", "")), "answers": {}, "rows": {}}
        if bank[g] is None:
            continue
        bank[g]["answers"][str(x["turn"])] = x["completion"] if isinstance(x["completion"], str) else json.dumps(x["completion"])
        bank[g]["rows"][str(x["turn"])] = [f, i]
    bank = {k: v for k, v in bank.items() if v}
    (OUT / "bank.json").write_text(json.dumps(bank, indent=1), encoding="utf-8")
    print("games %d (missing job/game file: %s), with overlay %d, rows %d" % (
        len(bank), sorted(set(missing)), sum(1 for v in bank.values() if v["overlay"]), sum(len(v["answers"]) for v in bank.values())))


if __name__ == "__main__":
    main()
