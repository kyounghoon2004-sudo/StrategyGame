"""Harness-Zero offline pipeline (user, 2026-10-15). Student = v3b_536 (thinking off, plain harness); reviewer = gemini-3.8-flash-low.
  python -m tools.synth_adv_v1.hz_pipeline screen            # stage 1: code flags on every harvested student turn
  python -m tools.synth_adv_v1.hz_pipeline review [--max N]  # stage 2: reviewer on flagged turns (+ a calibration sample of ok turns)
  python -m tools.synth_adv_v1.hz_pipeline build             # stage 3: code filters -> hz_rows.json (accepted responses)
Rules of the filter (benchmark: the reviewer over-corrects ok turns and leaves residual problems):
  - a turn the code does not flag keeps the STUDENT's own answer (pass), whatever the reviewer said;
  - flagged + reviewer pass -> dropped (a known-bad answer must not become a label);
  - flagged + replace -> kept only if valid, no residual problem by the same code analysis, <= MAX_CHANGED units changed,
    plan <= 300 chars with ids/numbers present in the packet.
"""
import argparse
import concurrent.futures as cf
import json
import random
import re
import time
from pathlib import Path

from tools.plan_search.cloud_brain import _run_agy
from tools.synth_adv_v1.hz_teacher_bench import analyse, review_prompt, parse_json, VERBS, QUOTA, user_text
from tools.synth_adv_v1.stall_shim import progress
from tools.synth_adv_v1.facts_shim import dist

ROOT = Path(__file__).resolve().parents[2]
HZ = ROOT / "artifacts" / "brain_pipeline_v1" / "synth_adv_v1" / "hz"
SOURCES = [("BASIC", HZ / "harvest_BASIC" / "captures" / "calls.jsonl"),
           ("INTER", HZ / "harvest_INTER" / "captures" / "calls.jsonl"),
           ("BLOCKADE", HZ / "harvest_blockade" / "captures" / "red" / "calls.jsonl")]
MODEL = "gemini-3.8-flash-low"
MAX_CHANGED = 6
MAX_AFTER_COMPLETE = 12
ID = re.compile(r"\b[RB]_[A-Z]{2,3}_\d+\b")


def student_turns():
    for src, path in SOURCES:
        last = {}
        for l in path.read_text(encoding="utf-8").splitlines():
            if not l.strip():
                continue
            c = json.loads(l)
            if c.get("request") == "VICTORY_COMMAND" and c.get("messages") and isinstance(c.get("state"), dict) and c.get("turn") is not None:
                last[(c.get("tag"), int(c["turn"]))] = c
        for (tag, turn), c in sorted(last.items(), key=lambda kv: (str(kv[0][0]), kv[0][1])):
            yield src, tag, turn, c


def flags_of(c, prop):
    st, turn = c["state"], int(c["turn"])
    orders = prop.get("orders") if isinstance(prop, dict) and isinstance(prop.get("orders"), dict) else None
    if orders is None:
        return ["unparsable_or_no_orders_key"]
    f = list(analyse(st, orders, prop.get("plan")))
    if turn == 1 and not prop.get("plan"):
        f.append("no_opening_plan")
    if turn >= 10 and not orders:
        prog, _ = progress(c["messages"], turn, 5)
        if prog < 40:
            f.append("idle_while_stalled")
    return f


def cmd_screen(a):
    rows = []
    for src, tag, turn, c in student_turns():
        prop = parse_json(c.get("raw"))
        fl = flags_of(c, prop)
        rows.append({"src": src, "tag": tag, "turn": turn, "flags": fl, "bad": bool(fl)})
    (HZ / "screen.jsonl").write_text("".join(json.dumps(r) + "\n" for r in rows), encoding="utf-8")
    import collections
    print("turns", len(rows), "flagged", sum(r["bad"] for r in rows))
    for src in ("BASIC", "INTER", "BLOCKADE"):
        v = [r for r in rows if r["src"] == src]
        print("  %-9s turns %4d flagged %4d (%.0f%%)  %s" % (src, len(v), sum(r["bad"] for r in v), 100 * sum(r["bad"] for r in v) / max(1, len(v)),
              dict(collections.Counter(x.split(":")[0] for r in v for x in r["flags"]).most_common(6))))


def cmd_review(a):
    rng = random.Random(11)
    scr = {(r["src"], r["tag"], r["turn"]): r for r in map(json.loads, (HZ / "screen.jsonl").read_text(encoding="utf-8").splitlines())}
    cand = []
    for src, tag, turn, c in student_turns():
        r = scr.get((src, tag, turn))
        if r is None:
            continue
        cand.append((r["bad"], src, tag, turn, c))
    bad = [x for x in cand if x[0]]
    ok = [x for x in cand if not x[0]]
    rng.shuffle(bad)
    rng.shuffle(ok)
    pick = bad[:a.max] + ok[:max(40, int(0.15 * min(len(bad), a.max)))]
    out = HZ / "reviews.jsonl"
    done = set()
    if out.exists():
        for l in out.read_text(encoding="utf-8").splitlines():
            if l.strip():
                j = json.loads(l)
                done.add((j["src"], j["tag"], j["turn"]))
    todo = [x for x in pick if (x[1], x[2], x[3]) not in done]
    print("to review", len(todo), "(already done %d; flagged pool %d, ok pool %d)" % (len(done), len(bad), len(ok)), flush=True)

    def run(x):
        isbad, src, tag, turn, c = x
        prop = parse_json(c.get("raw")) or {}
        t0 = time.time()
        try:
            text, usage, _, _ = _run_agy(MODEL, "", review_prompt(c, c["state"], prop), 300)
        except Exception as e:  # noqa: BLE001
            text, usage = "ERR " + str(e)[:200], {}
        return {"src": src, "tag": tag, "turn": turn, "bad": isbad, "answer": text, "s": round(time.time() - t0, 1),
                "tokens": {k: usage.get(k) for k in ("input_tokens", "output_tokens", "thinking_tokens")}}

    with cf.ThreadPoolExecutor(a.workers) as ex, open(out, "a", encoding="utf-8") as fh:
        for i, r in enumerate(ex.map(run, todo)):
            fh.write(json.dumps(r, ensure_ascii=False) + "\n")
            fh.flush()
            if i % 25 == 0:
                print(i, "reviewed", flush=True)


def plan_facts_ok(plan, st, orders):
    if not isinstance(plan, str) or len(plan) > 300 or QUOTA.search(plan):
        return False
    src = json.dumps(st, ensure_ascii=False) + json.dumps(orders, ensure_ascii=False)
    if any(x not in set(ID.findall(src)) for x in ID.findall(plan)):
        return False
    nums = set(re.findall(r"-?\d+", src)) | {str(st.get("turn"))}
    return all(n.lstrip("-") in {x.lstrip("-") for x in nums} for n in re.findall(r"-?\d+", ID.sub("", plan)))


def complete_orders(st, orders):
    """The reviewer's edit is minimal; units it left on a standing order that cannot work are fixed by rule (same facts):
    melee blocked at a full ring -> join the reviewer's focus target (else the weakest ring unit); archer in range -> ATTACK ENEMY_HQ;
    dead/unknown target -> nearest live ring unit."""
    mine = {u["id"]: u for u in st.get("my_units") or [] if isinstance(u, dict)}
    foes = {u["id"]: u for u in st.get("enemy_units") or [] if isinstance(u, dict)}
    ehq = next((u for u in foes.values() if u.get("class") == "HQ"), None)
    if not ehq:
        return orders, 0
    hq = (ehq["q"], ehq["r"])
    ringset = {(hq[0] + dq, hq[1] + dr) for dq, dr in [(1, 0), (-1, 0), (0, 1), (0, -1), (1, -1), (-1, 1)]}
    ring = [u for u in foes.values() if (u["q"], u["r"]) in ringset and u.get("class") != "HQ"]
    tgts = [o.get("target") for o in orders.values() if isinstance(o, dict) and o.get("do") == "ATTACK" and o.get("target") in foes
            and (foes[o["target"]]["q"], foes[o["target"]]["r"]) in ringset]
    focus = max(set(tgts), key=tgts.count) if tgts else (min(ring, key=lambda u: u.get("troops", u.get("hp", 0)))["id"] if ring else None)
    out = dict(orders)
    n = 0
    for _ in range(3):
        probs = analyse(st, out, None)
        if not probs:
            break
        for p in probs:
            kind, uid = p.split(":", 1)
            if uid in orders or uid not in mine:
                continue
            if kind == "archer_in_range_not_shooting_hq":
                out[uid] = {"do": "ATTACK", "target": "ENEMY_HQ"}
            elif focus:
                out[uid] = {"do": "ATTACK", "target": focus}
            else:
                out[uid] = {"do": "HOLD"}
            n += 1
    return out, n


def cmd_build(a):
    import collections
    turns = {(src, tag, turn): c for src, tag, turn, c in student_turns()}
    scr = {(r["src"], r["tag"], r["turn"]): r for r in map(json.loads, (HZ / "screen.jsonl").read_text(encoding="utf-8").splitlines())}
    rev = {}
    for l in (HZ / "reviews.jsonl").read_text(encoding="utf-8").splitlines():
        if l.strip():
            j = json.loads(l)
            rev[(j["src"], j["tag"], j["turn"])] = j
    rows, st = [], collections.Counter()
    for k, c in turns.items():
        prop = parse_json(c.get("raw")) or {}
        s = scr[k]
        r = rev.get(k)
        if not s["bad"]:
            # code sees nothing wrong: the student's own answer is the label (pass); keep a share to stay close to the student
            if isinstance(prop.get("orders"), dict):
                rows.append((k, c, prop, "pass_code_ok"))
                st["pass_code_ok"] += 1
            continue
        if r is None:
            st["flagged_not_reviewed"] += 1
            continue
        j = parse_json(r["answer"])
        if not isinstance(j, dict):
            st["review_unparsable"] += 1
            continue
        if str(j.get("decision", "")).lower() != "replace":
            st["flagged_reviewer_pass_dropped"] += 1
            continue
        resp = j.get("response") if isinstance(j.get("response"), dict) else {}
        orders = resp.get("orders")
        stt = c["state"]
        mine = {u["id"] for u in stt.get("my_units") or [] if isinstance(u, dict)}
        foes = {u["id"] for u in stt.get("enemy_units") or [] if isinstance(u, dict)}
        valid = isinstance(orders, dict) and orders and all(u in mine and isinstance(o, dict) and o.get("do") in VERBS and
                                                          (o.get("target") in (None, "ENEMY_HQ") or o.get("target") in foes)
                                                          for u, o in orders.items())
        if not valid:
            st["replace_invalid"] += 1
            continue
        if len(orders) > MAX_CHANGED:
            st["replace_too_big"] += 1
            continue
        orders, n_fix = complete_orders(stt, orders)
        if n_fix:
            st["completed_by_code"] += 1
        if len(orders) > MAX_AFTER_COMPLETE:
            st["replace_too_big"] += 1
            continue
        plan = resp.get("plan")
        if plan is not None and not plan_facts_ok(plan, stt, orders):
            plan = None
            st["plan_dropped_facts"] += 1
        residual = analyse(stt, orders, plan)
        if residual:
            st["replace_residual_problem"] += 1
            continue
        acc = {"orders": orders}
        if plan:
            acc["plan"] = plan
        rows.append((k, c, acc, "replaced_completed" if n_fix else "replaced"))
        st["replaced_kept"] += 1
    out = []
    for (src, tag, turn), c, resp, kind in rows:
        out.append({"messages": c["messages"], "completion": json.dumps(resp, ensure_ascii=False), "game": "%s|%s" % (src, tag),
                    "turn": turn, "source": "hz_" + kind, "mission": "hq",
                    "seed": re.sub(r".*_s(\d+)$", r"\1", str(tag))})
    (HZ / "hz_rows.json").write_text(json.dumps(out, ensure_ascii=False), encoding="utf-8")
    print(json.dumps(dict(st), indent=1))
    print("rows", len(out), dict(collections.Counter(r["source"] for r in out)))


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("stage", choices=["screen", "review", "build"])
    ap.add_argument("--max", type=int, default=700)
    ap.add_argument("--workers", type=int, default=8)
    a = ap.parse_args()
    {"screen": cmd_screen, "review": cmd_review, "build": cmd_build}[a.stage](a)
