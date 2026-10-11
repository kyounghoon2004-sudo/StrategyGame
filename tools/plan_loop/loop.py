"""Plan loop smoke (2026-10-09, user): plan -> evaluate -> better plan -> better result, HQ mission (RL v8 INTER games).

For one situation (a bank game, its turn T):
  1. control branch: the 9B's original answer at T, orders standing for H turns; also captures the exact messages at T
  2. the 9B (same adapter, thinking off) writes K candidate answers for those messages
  3. each candidate is played in Godot from T for H turns (orders standing); facts at T+H + predictor v5 P(RED win)
  4. the facts go back to the 9B appended to the turn message; it writes a revised answer, also played for H turns
  5. verification: the best answer at T, then the live 9B to the end of the game, vs the original game's result
Godot is the judge; the predictor's estimate is shown to the 9B as an estimate only, never used as a training label.

  python -m tools.plan_loop.loop <game> [--turn 1] [--k 4] [--horizon 8] [--out <dir>]   (vLLM must be up: policy)
"""
from __future__ import annotations

import argparse
import concurrent.futures
import json
import subprocess
import sys
from pathlib import Path

import torch
import torch.nn.functional as F

from tools.plan_search.cloud_brain import local_command

ROOT = Path(__file__).resolve().parents[2]
BP = ROOT / "artifacts" / "brain_pipeline_v1"
BANK = BP / "plan_loop_v1" / "bank_hq.json"
PRED = BP / "predict_v5" / "predictor_best.pt"
PY = sys.executable
URL = "http://127.0.0.1:8000/v1/chat/completions"


SLOT = 0  # --slot: arenas / Hands slot of this loop; ports 8120+slot / 8130+slot (two loops side by side)


def run_branches(rows: list, out: Path, windows: int) -> dict:
    """Play branch rows (tools/synth_sft_v2/branch.py --mode hq); returns {id: game json}."""
    out.mkdir(parents=True, exist_ok=True)
    bf = out / "branches.jsonl"
    bf.write_text("".join(json.dumps(r) + "\n" for r in rows), encoding="utf-8")
    with open(out / "branch.log", "w", encoding="utf-8") as log:
        subprocess.run([PY, "-m", "tools.synth_sft_v2.branch", str(bf), str(out), "--windows", str(min(windows, len(rows))),
                        "--mode", "hq", "--bank", str(BANK), "--slot", str(SLOT), "--proxy-port", str(8120 + SLOT),
                        "--brain-port", str(8130 + SLOT)], cwd=ROOT, stdout=log, stderr=subprocess.STDOUT, timeout=7200)
    res = {}
    for r in rows:
        gf = out / "games" / ("%s.json" % r["id"])
        res[r["id"]] = json.loads(gf.read_text(encoding="utf-8")) if gf.exists() else None
    return res


_model = None


def win_prob(g: dict) -> float:
    """Predictor v5: P(RED wins) at the last RED decision point of a branch record."""
    global _model
    import tools.predict.data as D
    from tools.predict.model import load
    from tools.predict.train import Packed, batch
    ss = [s for s in D.game_samples(g.get("record") or {}, "", {"red": "llm", "blue": "gx"}, True, D.game_rules(g))
          if s["side"] == "red"]
    if not ss:
        return float("nan")
    dev = torch.device("cuda" if torch.cuda.is_available() else "cpu")
    if _model is None:
        _model = load(str(PRED), len(ss[-1]["feat"][0]), dev)
        _model.eval()
    with torch.no_grad():
        feat, dist, own, mask, lab, lost, dead, value = batch(Packed([ss[-1]]), dev)
        return float(F.softmax(_model(feat, dist, own, mask)["value"].float(), -1)[0, 0])


def facts(g: dict) -> dict:
    u, hq = g.get("units") or {}, g.get("hq") or {}
    s0, s1 = g.get("soldiers_start") or {}, g.get("soldiers_end") or {}
    f = {"turn": g.get("turn"), "outcome": g.get("outcome"),
         "blue_hq": [hq.get("blue", {}).get("start"), hq.get("blue", {}).get("end")],
         "red_hq": [hq.get("red", {}).get("start"), hq.get("red", {}).get("end")],
         "blue_units": [u.get("blue", {}).get("start"), u.get("blue", {}).get("alive")],
         "red_units": [u.get("red", {}).get("start"), u.get("red", {}).get("alive")]}
    for side in ("blue", "red"):
        a, b = s0.get(side), s1.get(side)
        if a:
            f["%s_soldiers_lost_pct" % side] = round(100.0 * (a - (b or 0)) / a)
    f["p_win"] = round(win_prob(g), 3)
    return f


def score(f: dict) -> float:
    """Ranking only (Godot facts first): a decided game dominates, then HQ damage, losses, the estimate."""
    if f["outcome"] == "RED_WIN":
        return 100.0
    if f["outcome"] == "BLUE_WIN":
        return -100.0
    bh = (f["blue_hq"][0] or 300) - (f["blue_hq"][1] or 0)
    rh = (f["red_hq"][0] or 300) - (f["red_hq"][1] or 0)
    return bh / 30.0 - rh / 30.0 + (f.get("blue_soldiers_lost_pct", 0) - f.get("red_soldiers_lost_pct", 0)) / 10.0 + 10 * f["p_win"]


def empty(ans: str) -> bool:
    try:
        return not (json.loads(ans).get("orders") or {})
    except (ValueError, AttributeError):
        return True


def orders_text(ans: str) -> str:
    """The candidate's orders, compact (unit DO target/to), so the 9B sees what each candidate actually did."""
    try:
        od = json.loads(ans).get("orders") or {}
    except (ValueError, AttributeError):
        return "(unreadable)"
    parts = []
    for uid, o in od.items():
        o = o if isinstance(o, dict) else {}
        arg = o.get("target", o.get("to", ""))
        parts.append(("%s %s %s" % (uid, o.get("do", "?"), json.dumps(arg) if isinstance(arg, list) else arg)).strip())
    return "; ".join(parts) if parts else "(no orders: every unit holds)"


def gen(msgs: list, model: str, temperature: float, tries: int = 4) -> str:
    """One answer with orders; an empty answer ({"orders": {}}) is asked again, up to `tries` times."""
    ans = '{"orders": {}}'
    for _ in range(tries):
        ans = local_command(msgs, url=URL, model=model, no_think=True, answer_tokens=2000, temperature=temperature,
                            timeout_s=600)[0] or '{"orders": {}}'
        if not empty(ans):
            return ans
    return ans


def describe(i: int, ans: str, f: dict, h: int) -> str:
    try:
        plan = json.loads(ans).get("plan", "")
    except ValueError:
        plan = ""
    return ("Candidate %d%s\n  orders: %s\n  after %d turns BLUE HQ %s->%s, your HQ %s->%s; BLUE units %s->%s, yours %s->%s; BLUE lost %s%% "
            "of its soldiers, you lost %s%%%s; estimated chance you win from there: %.2f." % (
                i, (' (plan: "%s")' % plan) if plan else "", orders_text(ans), h, f["blue_hq"][0], f["blue_hq"][1], f["red_hq"][0], f["red_hq"][1],
                f["blue_units"][0], f["blue_units"][1], f["red_units"][0], f["red_units"][1], f.get("blue_soldiers_lost_pct"),
                f.get("red_soldiers_lost_pct"), {"RED_WIN": "; you WON", "BLUE_WIN": "; you LOST"}.get(f["outcome"], ""), f["p_win"]))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("game")
    ap.add_argument("--turn", default="1", help="a turn number, or 'contact' = the first turn either side attacked")
    ap.add_argument("--reps", type=int, default=1, help="full-game verifications per answer (the live 9B is random)")
    ap.add_argument("--k", type=int, default=4)
    ap.add_argument("--horizon", type=int, default=8)
    ap.add_argument("--model", default="policy")
    ap.add_argument("--out", default="")
    ap.add_argument("--slot", type=int, default=0)
    a = ap.parse_args()
    global SLOT
    SLOT = a.slot
    bank = json.loads(BANK.read_text(encoding="utf-8"))
    g = bank[a.game]
    if a.turn == "contact":
        rec = json.loads(Path(g["game_file"]).read_text(encoding="utf-8")).get("record") or {}
        a.turn = min([int(e.get("turn", 99)) for side in ("red", "blue") for e in (rec.get("actions") or {}).get(side, [])
                      if e.get("do") == "ATTACK"] or [1])
    a.turn = int(a.turn)
    out = Path(a.out) if a.out else BP / "plan_loop_v1" / "smoke" / ("%s_t%d" % (a.game, a.turn))
    out.mkdir(parents=True, exist_ok=True)
    rep = {"game": a.game, "turn": a.turn, "original": {k: g[k] for k in ("kind", "outcome", "turn", "units", "hq")}}
    T, H = a.turn, a.horizon
    orig = g["answers"].get(str(T), '{"orders": {}}')

    # 1. control + messages
    ctrl = run_branches([{"id": "ctrl", "game": a.game, "turn": T, "horizon": H, "answer": orig}], out / "s1_ctrl", 1)
    msgs = json.loads((out / "s1_ctrl" / "requests" / "ctrl.json").read_text(encoding="utf-8"))
    rep["control"] = {"answer": orig, "facts": facts(ctrl["ctrl"])}
    print("control", rep["control"]["facts"], flush=True)

    # 2. K candidates
    with concurrent.futures.ThreadPoolExecutor(a.k) as ex:
        cands = list(ex.map(lambda _: gen(msgs, a.model, 1.0), range(a.k)))
    # 3. play them
    res = run_branches([{"id": "c%d" % i, "game": a.game, "turn": T, "horizon": H, "answer": c} for i, c in enumerate(cands)],
                       out / "s3_cands", a.k)
    rep["candidates"] = [{"answer": c, "facts": facts(res["c%d" % i])} for i, c in enumerate(cands) if res["c%d" % i]]
    for i, c in enumerate(rep["candidates"]):
        print("cand", i, c["facts"], c["answer"][:200], flush=True)

    # 4. feedback -> revised answer
    lines = [describe(i + 1, c["answer"], c["facts"], H) for i, c in enumerate(rep["candidates"])]
    note = ("\n\nSIMULATION of candidate answers for this turn (each candidate's orders played in the game for the next %d turns, "
            "orders then kept standing; BLUE as in the real game):\n%s\nWrite your answer for this turn again (same JSON "
            "format). You may keep, combine or change the candidates." % (H, "\n".join(lines)))
    msgs2 = json.loads(json.dumps(msgs))
    msgs2[-1]["content"] += note
    rev = gen(msgs2, a.model, 0.6)
    rr = run_branches([{"id": "rev", "game": a.game, "turn": T, "horizon": H, "answer": rev}], out / "s4_rev", 1)
    rep["feedback"] = note
    rep["revised"] = {"answer": rev, "facts": facts(rr["rev"])}
    print("revised", rep["revised"]["facts"], rev[:300], flush=True)

    # 5. verify: the best answer at T, then the live 9B to the end; the original answer the same way (control)
    pool = [("control", orig, rep["control"]["facts"])] + [("cand%d" % i, c["answer"], c["facts"]) for i, c in enumerate(rep["candidates"])] \
        + [("revised", rev, rep["revised"]["facts"])]
    best = max(pool, key=lambda p: score(p[2]))
    rep["best"] = best[0]
    # every answer is verified to the end, so the predictor's ranking can be checked against real results
    ver = run_branches([{"id": "v_%s_r%d" % (name, k), "game": a.game, "turn": T, "horizon": 0, "answer": ans, "after": "live"}
                        for name, ans, _ in pool for k in range(a.reps)], out / "s5_verify", min(8, len(pool) * a.reps))
    rep["verify"] = {}
    for name, _, f in pool:
        runs = [ver.get("v_%s_r%d" % (name, k)) for k in range(a.reps)]
        rep["verify"][name] = {"p_win_at_T+H": f["p_win"], "score": round(score(f), 2),
                               "results": [{"outcome": v.get("outcome"), "turn": v.get("turn")} if v else {"outcome": None}
                                           for v in runs]}
    print("verify", best[0], rep["verify"], flush=True)
    (out / "report.json").write_text(json.dumps(rep, indent=1), encoding="utf-8")


if __name__ == "__main__":
    main()
