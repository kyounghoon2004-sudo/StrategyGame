"""Plan-revision cold probe (thinking OFF): previous plan + 'it did not work' (+ computed FACTS) -> new plan.
Scoring by code: format (NEW PLAN <= 300 chars), strategy actually changed, no false hex/rule claims, type-specific correctness."""
import json, re, sys, urllib.request, concurrent.futures as cf
from tools.ckpt_sweep.items import make_cold, RULES
from tools.ckpt_sweep.facts_probe import facts, ask

PRIORS = [
    ("all-in assault", "All units advance together and attack the enemy HQ directly; melee units in front, archers behind."),
    ("hold home", "Stay near my HQ in a defensive line, let the enemy come to me, then counter-attack."),
    ("flank", "Cavalry flanks around the enemy to hit the HQ from behind while the rest press forward."),
    ("grind army", "Wear down the enemy field units one by one first; go for the HQ only when few remain."),
]
FORMAT = ("Answer in exactly this format, nothing else:\nDIAGNOSIS: <one sentence: why did the previous plan fail>\n"
          "NEW PLAN: <at most 300 characters, a different strategy>\nORDERS: <which unit types do what, in order>")


def revision_prompt(it, k):
    name, plan = PRIORS[k % 4]
    base = it["prompt"].rsplit("\n\nExplain in a short paragraph", 1)[0]
    return name, (base + "\n\nYour previous plan was: \"" + plan + "\"\nFor the last 20 turns it produced nothing: 0 damage to the enemy HQ, 0 enemy units destroyed, 0 of my units lost. "
                  "It has failed and must be replaced.\n\n" + FORMAT)


def parse_sections(t):
    g = lambda k: (re.search(k + r":\s*(.+?)(?=\n[A-Z ]{4,}:|\Z)", t, re.S) or [None, ""])[1].strip()
    return g("DIAGNOSIS"), g("NEW PLAN"), g("ORDERS")


COORD = re.compile(r"\(\s*(-?\d+)\s*,\s*(-?\d+)\s*\)")


def score(text, it, prior_name):
    gt = it["truth"]; occ = {tuple(x) for x in gt["occupied"]}; hq = tuple(gt["hq"]); mine = {tuple(v) for v in gt["my_units"].values()}
    diag, plan, orders = parse_sections(text)
    t = text.lower()
    ff = sum(1 for m in re.finditer(r"(free|open|empty|vacant|unoccupied|gap)[^.\n]{0,60}", t)
             for c in COORD.finditer(m.group(0)) if (int(c.group(1)), int(c.group(2))) in (occ | mine | {hq}))
    fr = bool(re.search(r"(cannot|can't|unable to)[^.]{0,25}(shoot|fire|hit)[^.]{0,30}(over|through|past)|blocked by (the |your |friendly |own |enemy )", t))
    fmt = bool(plan) and len(plan) <= 300
    p = plan.lower()
    same = {"all-in assault": bool(re.search(r"(all|every)[^.]{0,30}(units?)?[^.]{0,30}(advance|attack|assault)[^.]{0,30}hq", p)) and not re.search(r"(breach|ring|break|clear|focus|archer|free hex|one (unit|defender))", p),
            "hold home": bool(re.search(r"(defensive|stay|hold)[^.]{0,40}(hq|home|line)", p)) and not re.search(r"(attack|breach|assault)", p),
            "flank": bool(re.search(r"flank", p)) and not re.search(r"(breach|ring|archer|free hex)", p),
            "grind army": bool(re.search(r"(wear down|grind|one by one)[^.]{0,40}(field|units|army)", p)) and not re.search(r"(ring|breach|archer|hq)", p)}[prior_name]
    changed = fmt and not same
    typ = gt["type"][0]; free = gt["free_adjacent"]
    arch = bool(re.search(r"archers?[^.]{0,90}\b(hq|headquarters)\b", t))
    blocked = bool(re.search(r"(surround|ring|all six|six hexes|completely|blocked|occupied|cannot reach|can.?t reach)", t))
    if typ == "A": ok = blocked and arch
    elif typ == "B": ok = blocked and bool(re.search(r"(move|advance|close|reposition|approach)[^.]{0,60}archer|archer[^.]{0,60}(move|advance|close|reposition|approach)|(break|breach|destroy|kill)[^.]{0,40}(ring|fortified|defender|guard)", t))
    elif typ == "C": ok = any(("(%d,%d)" % h) in text.replace(" ", "") for h in free)
    else: ok = not re.search(r"(completely|fully|all six)[^.]{0,30}(surround|block|occupied)", t)
    good = changed and ok and ff == 0 and not fr
    return {"fmt": fmt, "changed": changed, "type_ok": bool(ok), "false_free": ff > 0, "false_rule": fr, "good": bool(good)}


if __name__ == "__main__":
    items = make_cold(); jobs = [(m, it, i, f) for m in ("q35", "v3b_536") for i, it in enumerate(items) for f in (False, True)]
    def run(j):
        m, it, i, f = j
        name, p = revision_prompt(it, i)
        if f:
            p = p.replace("\n\n" + FORMAT, "\n\n" + facts(it) + "\n\n" + FORMAT)
        return {"model": m, "id": it["id"], "prior": name, "facts": f, "content": ask(m, p)}
    with cf.ThreadPoolExecutor(8) as ex:
        out = list(ex.map(run, jobs))
    P = "artifacts/brain_pipeline_v1/ckpt_sweep/revision_probe.jsonl"
    open(P, "w", encoding="utf-8").write("".join(json.dumps(o, ensure_ascii=False) + "\n" for o in out))
    its = {i["id"]: i for i in items}
    print("%-9s %-6s %4s | format ok | strategy changed | type-correct | false hex | false rule | GOOD" % ("model", "facts", "n"))
    for m in ("q35", "v3b_536"):
        for f in (False, True):
            v = [o for o in out if o["model"] == m and o["facts"] == f]; s = [score(o["content"], its[o["id"]], o["prior"]) for o in v]
            c = lambda k: sum(1 for x in s if x[k])
            print("%-9s %-6s %4d | %9d | %16d | %12d | %9d | %10d | %d" % (m, "yes" if f else "no", len(v), c("fmt"), c("changed"), c("type_ok"), c("false_free"), c("false_rule"), c("good")))
