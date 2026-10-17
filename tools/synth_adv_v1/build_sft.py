"""Build the ADV SFT set: real winning rows + engine-verified synthetic survivors, verified plans attached.
  python -m tools.synth_adv_v1.build_sft
-> synth_adv_v1/sft_adv_v1_train.json, sft_adv_v1_val.json, sft_adv_v1_report.json
"""
import collections, glob, json, os
from tools.synth_adv_v1.bank_adv import BP, OUT

VAL_SEEDS = {"9970300", "9970311", "9970313", "9971011"}   # val = whole seeds (no lineage leak)
HOLDOUT = set(range(9980000, 9980032))


def jl(x):
    try:
        return json.loads(x) if isinstance(x, str) else x
    except ValueError:
        return {}


def main():
    plans = json.loads((OUT / "plans_verified.json").read_text(encoding="utf-8"))
    bank = json.loads((OUT / "bank_adv.json").read_text(encoding="utf-8"))
    src = {g: b["src_dir"] for g, b in bank.items()}
    cand = {x["sid"] + "__" + x["variant"]: x for x in map(json.loads, (OUT / "candidates.jsonl").read_text(encoding="utf-8").splitlines())}
    sit = {}
    for l in (OUT / "situations_adv.jsonl").read_text(encoding="utf-8").splitlines():
        r = json.loads(l); sit[r["id"]] = r
    res = {}
    for f in glob.glob(str(OUT / "full_t" / "out" / "games" / "*.json")):
        res[os.path.basename(f)[:-5]] = json.load(open(f, encoding="utf-8")).get("outcome")
    # synthetic survivors: one per situation, A-grade first
    best = {}
    for k, o in res.items():
        if "__ctrl" in k or o != "RED_WIN":
            continue
        sid = k.rsplit("__", 1)[0]
        a_grade = res.get(sid + "__ctrl0") not in (None, "RED_WIN")
        if sid not in best or (a_grade and not best[sid][1]):
            best[sid] = (k, a_grade)
    synth, replaced = [], set()
    for sid, (k, a_grade) in best.items():
        c, s = cand[k], sit[sid]
        ans = json.loads(c["answer"])
        pj = "synth|" + k
        if pj in plans:
            ans["plan"] = plans[pj]
        elif int(c["turn"]) > 1:
            ans.pop("plan", None)
        row = {"messages": s["messages"], "completion": json.dumps(ans, ensure_ascii=False), "game": s["game"], "turn": s["turn"],
               "seed": str(s["seed"]), "source": "synth_A" if a_grade else "synth_B", "mission": "hq"}
        synth.append(row); replaced.add((src[s["game"]], int(s["turn"])))
    real = []
    for l in open(BP / "real_sft" / "rows.jsonl", encoding="utf-8"):
        r = json.loads(l)
        key = (r["source_dir"], int(r["turn"]))
        if key in replaced:
            continue
        a = jl(r["response"])
        if not isinstance(a, dict):
            continue
        if "orders" not in a:  # a bare {} answer = "every order stands"
            a = {"orders": {}, **{k: v for k, v in a.items() if k == "plan"}}
        if not isinstance(a.get("orders"), dict):
            continue
        pj = "real|%s|%d" % (r["source_dir"], int(r["turn"]))
        if pj in plans:
            a = dict(a); a["plan"] = plans[pj]
        real.append({"messages": jl(r["messages"]) if isinstance(r["messages"], str) else r["messages"],
                     "completion": json.dumps(a, ensure_ascii=False), "game": r["source_dir"], "turn": int(r["turn"]),
                     "seed": str(r["seed"]), "source": "real", "mission": "hq"})
    allrows = real + synth
    assert not any(int(r["seed"]) in HOLDOUT for r in allrows), "holdout seed leaked"
    train = [r for r in allrows if r["seed"] not in VAL_SEEDS]
    # The tuned model already answers {} on ~31% of turns>=2 (baseline eval); the teacher games are 55% empty. Keep the
    # empties in the train set at EMPTY_FRAC so SFT does not push the empty rate up (seeded, spread over all turns).
    import random, sys
    frac = float(os.environ.get("EMPTY_FRAC", "0.25"))
    emp = [r for r in train if not json.loads(r["completion"]).get("orders")]
    act = [r for r in train if json.loads(r["completion"]).get("orders")]
    keep = int(len(act) * frac / (1 - frac))
    random.Random(5).shuffle(emp)
    train = act + emp[:keep]
    random.Random(6).shuffle(train)
    val = [r for r in allrows if r["seed"] in VAL_SEEDS]
    def stat(rows):
        n = len(rows); e = sum(1 for r in rows if not json.loads(r["completion"]).get("orders"))
        p = sum(1 for r in rows if json.loads(r["completion"]).get("plan"))
        return {"rows": n, "empty": e, "empty_pct": round(100 * e / max(1, n), 1), "with_plan": p,
                "plan_after_t1": sum(1 for r in rows if int(r["turn"]) > 1 and json.loads(r["completion"]).get("plan")),
                "games": len({r["game"] for r in rows}), "by_source": dict(collections.Counter(r["source"] for r in rows))}
    rep = {"train": stat(train), "val": stat(val), "replaced_real_rows": len(replaced)}
    (OUT / "sft_adv_v1_train.json").write_text(json.dumps(train, ensure_ascii=False), encoding="utf-8")
    (OUT / "sft_adv_v1_val.json").write_text(json.dumps(val, ensure_ascii=False), encoding="utf-8")
    (OUT / "sft_adv_v1_report.json").write_text(json.dumps(rep, indent=1), encoding="utf-8")
    print(json.dumps(rep, indent=1))


if __name__ == "__main__":
    main()
