"""A local LLM server plays RED in a teacher_play inbox (2026-10-17, user: Strata with thinking on, one game to judge quality).
Pure relay, no game logic: every open request's "messages" (exactly what the student sees: system rules + short relay
context) is sent to the model; the JSON object in the model's answer (thinking stripped) becomes resp_NNNN.txt.
A reply without a parsable JSON object is asked again once (with the error); a second failure is logged and answered with
{"orders": {}} so the game goes on, and is marked in bridge.jsonl (that game must not be used for training).
Options (teacher side only; the student prompt in the req file is unchanged):
  --aid           append the code-computed AID (teacher_aid.py) and a short "think briefly" note to the last message
  --think-on plan thinking only on turn 1, relay turns, every 5th turn (plan check) and right after a unit loss
  --think-budget  cap a thinking call; if it gave no answer, force one with thinking off from the analysis so far
  python -m tools.synth_adv_v1.teacher_play_llm --name strata --effort low --aid --think-on plan --think-budget 3500
"""
import argparse, glob, json, os, re, time, urllib.request

from tools.synth_adv_v1.teacher_aid import aid_text

BASE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "artifacts", "brain_pipeline_v1", "synth_adv_v1",
                    "teacher_play")


def chat(a, messages, effort=None, max_tokens=None):
    effort = a.effort if effort is None else effort
    body = {"model": a.model, "messages": messages, "max_tokens": max_tokens or a.max_tokens, "temperature": 0.6, "stream": False}
    if effort != "off":
        body["reasoning_effort"] = effort
    else:
        body["chat_template_kwargs"] = {"enable_thinking": False}
    req = urllib.request.Request(a.url, data=json.dumps(body).encode("utf-8"), headers={"Content-Type": "application/json"})
    t0 = time.time()
    with urllib.request.urlopen(req, timeout=1800) as r:
        d = json.loads(r.read())
    m = d["choices"][0]["message"]
    return (m.get("content") or ""), (m.get("reasoning_content") or m.get("reasoning") or ""), time.time() - t0, d.get("usage")


def extract(txt):
    txt = txt.split("</think>")[-1].strip()
    txt = re.sub(r"^```(?:json)?\s*|\s*```$", "", txt.strip())
    i, j = txt.find("{"), txt.rfind("}")
    if i < 0 or j <= i:
        raise ValueError("no JSON object in the answer")
    body = txt[i:j + 1]
    try:
        o = json.loads(body)
    except ValueError:
        miss = body.count("{") - body.count("}")  # Strata sometimes drops the final closing brace(s)
        if miss <= 0 or miss > 2:
            raise
        o = json.loads(body + "}" * miss)
    if not isinstance(o, dict) or not isinstance(o.get("orders", {}), dict):
        raise ValueError("answer is not {\"orders\": {...}}")
    o.setdefault("orders", {})
    return o


def prepare(a, q, prev_ids):
    """-> (messages to send, effort, row fields, ids of my units now)."""
    msgs = q["messages"]
    st = q.get("state") or {}
    turn = int(q.get("turn") or 0)
    last = str(msgs[-1].get("content") or "")
    prev = prev_ids if isinstance(prev_ids, dict) else {}
    ids = {u.get("id") for u in st.get("my_units") or [] if isinstance(u, dict)}
    lost = sorted(prev["ids"] - ids) if prev.get("ids") else []
    relay = last.startswith('{"request"')
    # MY HQ THREAT (user, 2026-10-17): a BLUE unit can strike my HQ within 2 turns, or my HQ lost soldiers/fieldworks
    # since the last request -> an extra plan turn; on all other non-relay turns no plan (REVISE) is accepted.
    mhq = next((u for u in st.get("my_units") or [] if isinstance(u, dict) and u.get("class") == "HQ"), None)
    hq_now = (int(mhq.get("soldiers") or 0), int(mhq.get("fortified") or 0)) if mhq else None
    near = sorted("%s eta %s" % (u["id"], u["eta_strike_my_hq"]) for u in st.get("enemy_units") or []
                  if isinstance(u, dict) and u.get("class") != "HQ" and u.get("eta_strike_my_hq") is not None
                  and int(u["eta_strike_my_hq"]) <= 2)
    hit = bool(prev.get("hq") and hq_now and (hq_now[0] < prev["hq"][0] or hq_now[1] < prev["hq"][1]))
    sysp = next((m.get("content") for m in msgs if m.get("role") == "system"), None)
    from tools.synth_adv_v1.teacher_aid import is_collapse, collapse_share
    nb = sum(1 for u in st.get("enemy_units") or [] if isinstance(u, dict) and u.get("class") != "HQ")
    nr = sum(1 for u in st.get("my_units") or [] if isinstance(u, dict) and u.get("class") != "HQ")
    start = {"blue": nb, "red": nr} if (turn == 1 or not prev.get("start")) else prev["start"]
    if is_collapse(sysp):  # collapse: the threat is my losses nearing the rout share (at most 2 more losses allowed)
        import math
        allowed = math.ceil(collapse_share(sysp) * start["red"]) - (start["red"] - nr) - 1
        near, hit = (["only %d more losses allowed before I am routed" % max(allowed, 0)] if allowed <= 2 else []), False
    threat_now = bool(near) or hit
    threat = threat_now and not prev.get("threat")  # only the turn the threat appears (user, 2026-10-17)
    plan_turn = relay or turn == 1 or threat or (a.think_on == "plan" and (turn % 5 == 0 or bool(lost)))
    think_turn = a.think_on in ("all", "short") or plan_turn
    row = {"turn": turn, "think": think_turn, "plan_turn": plan_turn, "relay": relay, "lost": lost,
           "threat": {"near": near, "hq_hit": hit} if threat else None}
    if a.aid:
        note = aid_text(st, targets=plan_turn, system=sysp, start=start)
        if plan_turn:
            if relay or turn == 1:
                why = "RELAY / start of battle: write the plan for this board."
            elif threat:
                facts = []
                if near and "losses" in near[0]:
                    facts += near
                elif near:
                    facts.append("BLUE units that can strike my HQ within 2 turns: " + ", ".join(near))
                if hit:
                    facts.append("my HQ lost soldiers or fieldworks since last turn")
                why = ("THREAT (turn %d): %s. Decide whether the standing plan still fits: keep it or write a new "
                       "\"plan\"." % (turn, "; ".join(facts)))
            else:
                why = ("PLAN CHECK (turn %d): is the standing plan still on schedule? Keep it, or write a new \"plan\" if it is "
                       "failing." % turn)
            note += ("\n\n" + why + " THINK BRIEFLY: the AID numbers are exact - do not recompute distances, eta, combat "
                     "previews or unit lists. Decide, then reply with the JSON object at once.")
        else:
            note += ("\n\nFOLLOW THE STANDING PLAN. This turn: give orders only for units whose order must change to carry out "
                     "the standing plan (an order stands until replaced; {} keeps every order). Do not write a \"plan\" this turn. "
                     "Think very briefly, then reply with the JSON object.")
        msgs = msgs[:-1] + [dict(msgs[-1], content=last + "\n\n" + note)]
        row["aid_chars"] = len(note)
    eff = (a.effort_plan or a.effort) if plan_turn else (a.effort if think_turn else "off")
    return msgs, eff, row, {"ids": ids, "hq": hq_now, "threat": threat_now, "start": start}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--name", required=True)
    ap.add_argument("--url", default="http://127.0.0.1:8080/v1/chat/completions")
    ap.add_argument("--model", default="strata")
    ap.add_argument("--effort", default="high", choices=["off", "low", "medium", "high"])
    ap.add_argument("--max-tokens", type=int, default=12000)
    ap.add_argument("--aid", action="store_true")
    ap.add_argument("--think-on", default="all", choices=["all", "plan", "short"],
                    help="short: plan turns = turn 1 + relays, other turns think with --think-budget-other")
    ap.add_argument("--think-budget", type=int, default=0)
    ap.add_argument("--effort-plan", default="", choices=["", "low", "medium", "high"], help="effort on plan turns (default --effort)")
    ap.add_argument("--think-budget-other", type=int, default=0, help="thinking cap on non-plan turns (short mode)")
    ap.add_argument("--stop-after-turn", type=int, default=0, help="test: exit after answering this turn")
    a = ap.parse_args()
    d = os.path.join(BASE, a.name)
    log = os.path.join(d, "bridge.jsonl")
    prev_ids = None
    while True:
        inbox = open(os.path.join(d, "CURRENT.txt"), encoding="utf-8").read().strip()
        if inbox.startswith("none"):
            break
        reqs = sorted(glob.glob(os.path.join(inbox, "req_*.json")))
        todo = [f for f in reqs if not os.path.exists(f.replace("req_", "resp_").replace(".json", ".txt"))]
        if not todo:
            time.sleep(1)
            continue
        f = todo[0]
        try:
            q = json.load(open(f, encoding="utf-8"))
        except ValueError:
            time.sleep(0.5)
            continue
        msgs, effort, extra, prev_ids = prepare(a, q, prev_ids)
        row = {"ts": time.time(), "req": f, **extra}
        ans, err, usable = None, None, None
        for attempt in range(3):
            budget = None
            if effort != "off":
                budget = (a.think_budget if extra["plan_turn"] else (a.think_budget_other or a.think_budget)) or None
            content, think, s, usage = chat(a, msgs, effort=effort, max_tokens=budget)
            rec = {"s": round(s, 1), "usage": usage, "think_chars": len(think), "think": think[:20000], "content": content[:4000]}
            if budget and not content.strip():  # budget forcing: answer now from the analysis so far, thinking off
                rec["forced"] = True
                row.setdefault("attempts", []).append(rec)
                need = ("{\"plan\": \"<at most 300 characters>\", \"orders\": {...}} - this turn MUST include the plan"
                        if extra["plan_turn"] else "{\"orders\": {...}} plus \"plan\" only if the standing plan is failing")
                msgs2 = msgs + [{"role": "user", "content": "Your analysis so far (last part):\n" + think[-2500:] +
                                 "\n\nStop analysing. Reply now with ONE JSON object only: " + need + "."}]
                content, think, s, usage = chat(a, msgs2, effort="off", max_tokens=1500)
                rec = {"s": round(s, 1), "usage": usage, "think_chars": 0, "content": content[:4000], "forced_answer": True}
            row.setdefault("attempts", []).append(rec)
            try:
                ans = extract(content)
                p = str(ans.get("plan") or "")
                if extra["plan_turn"] and not p.strip():
                    raise ValueError("this is a plan turn: the answer must include \"plan\"")
                if len(p) > 300:
                    usable = ans  # parsable, only too long: kept as a last resort instead of empty orders
                    raise ValueError("the plan has %d characters; at most 300" % len(p))
                break
            except ValueError as e:
                ans = None
                err = str(e)
                msgs = msgs + [{"role": "assistant", "content": content},
                               {"role": "user", "content": "Your reply could not be used (%s). Reply with ONE JSON object only: "
                                                           "{\"orders\": {...}} plus \"plan\" when needed." % err}]
                effort = "off"
        if ans is not None and not extra["plan_turn"] and ans.get("plan"):
            row["plan_dropped"] = str(ans.pop("plan"))[:300]  # REVISE only on plan turns (relay / turn 1 / my HQ threat)
        if ans is None and usable is not None:
            ans = usable
            row["plan_too_long"] = len(str(usable.get("plan") or ""))  # this turn is excluded from training
        if ans is None:
            ans = {"orders": {}}
            row["fallback"] = err
        out = f.replace("req_", "resp_").replace(".json", ".txt")
        with open(out + ".tmp", "w", encoding="utf-8") as fh:
            fh.write(json.dumps(ans, ensure_ascii=False))
        os.replace(out + ".tmp", out)
        row["answer"] = ans
        with open(log, "a", encoding="utf-8") as fh:
            fh.write(json.dumps(row, ensure_ascii=False) + "\n")
        if a.stop_after_turn and row["turn"] >= a.stop_after_turn:
            break
    print("stopped")


if __name__ == "__main__":
    main()
