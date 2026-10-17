"""ADV-win bank (2026-10-14): the real RED_WIN games vs ADV GX (HQ mission) in tools.synth_sft_v2.bank shape.

Answers = what the proxy actually received (captures/calls.jsonl VICTORY_COMMAND 'raw', last record per turn).
  python -m tools.synth_adv_v1.bank_adv
"""
import csv, json
from pathlib import Path
from tools.synth_sft_v2.bank import overlay_of

ROOT = Path(__file__).resolve().parents[2]
BP = ROOT / "artifacts" / "brain_pipeline_v1"
OUT = BP / "synth_adv_v1"
SKIP = {"sft_wins/s9971004_a3"}  # response files differ from the served responses


def main():
    rows = list(csv.DictReader(open(BP / "head_audit" / "games_audit.csv", encoding="utf-8")))
    bank, drop = {}, {}
    for r in rows:
        if r["tree"] not in ("agent_d", "sft_wins") or r["outcome"] != "RED_WIN" or r["status"] != "OK":
            continue
        d = r["dir"]
        if d in SKIP or r["strict_fault"] not in ("{}", ""):
            drop[d] = "skip/strict"; continue
        gdir = BP / d
        gfs = list((gdir / "games").glob("*.json"))
        if len(gfs) != 1:
            drop[d] = "game files %d" % len(gfs); continue
        rec = json.loads(gfs[0].read_text(encoding="utf-8"))
        ans = {}
        for l in (gdir / "captures" / "calls.jsonl").read_text(encoding="utf-8").splitlines():
            if not l.strip():
                continue
            c = json.loads(l)
            if c.get("request") == "VICTORY_COMMAND" and c.get("raw") is not None:
                ans[str(int(c["turn"]))] = c["raw"]
        t = int(rec["turn"])
        need = [str(i) for i in range(1, int(r["n_resp"]) + 1)]
        if any(k not in ans for k in need):
            drop[d] = "missing turns"; continue
        ep = rec["episode"]
        tag = d.replace("/", "__")
        bank[tag] = {"game": tag, "seed": int(r["seed"]), "tier": "ADV", "style": r["gx"].split("_")[-1],
                     "family": ep.get("family", "fixed"), "army_size": 10, "game_file": str(gfs[0]),
                     "overlay": overlay_of(gfs[0]), "outcome": rec["outcome"], "turn": t,
                     "win_turn": t, "last_turn_win": t >= 61, "src_dir": d, "answers": {k: ans[k] for k in need}}
    OUT.mkdir(exist_ok=True)
    (OUT / "bank_adv.json").write_text(json.dumps(bank, indent=1), encoding="utf-8")
    print("games", len(bank), "dropped", drop, "with overlay", sum(1 for v in bank.values() if v["overlay"]))
    for v in bank.values():
        print(v["game"], v["style"], v["family"], v["turn"], len(v["answers"]), bool(v["overlay"]))


if __name__ == "__main__":
    main()
