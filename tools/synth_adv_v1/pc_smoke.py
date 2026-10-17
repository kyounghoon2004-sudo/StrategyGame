import json, sys, time, random, concurrent.futures as cf, urllib.request
from tools.synth_adv_v1.plan_check_shim import CUE
PC = "D:/Game development/Demon slayer/StrategyGame/artifacts/brain_pipeline_v1/synth_adv_v1/pc/"
rows = [json.loads(l) for f in ("checks_BASIC.jsonl", "checks_blockade.jsonl") for l in open(PC + f, encoding="utf-8")]
random.Random(2).shuffle(rows)
rows = rows[:8]
THINK = sys.argv[1] == "think"
def ask(r):
    msgs = r["orig_messages"]
    lu = json.loads(msgs[-1]["content"]); lu["plan_check"] = CUE
    m = msgs[:-1] + [dict(msgs[-1], content=json.dumps(lu, ensure_ascii=False, separators=(",", ":")))]
    body = {"model": "v3b_536", "messages": m, "max_tokens": 9000 if THINK else 1500, "temperature": 0.6,
            "chat_template_kwargs": {"enable_thinking": THINK}}
    t0 = time.time()
    req = urllib.request.Request("http://127.0.0.1:8010/v1/chat/completions", json.dumps(body).encode(), {"Content-Type": "application/json"})
    out = json.loads(urllib.request.urlopen(req, timeout=900).read())["choices"][0]["message"]
    txt = out.get("content") or ""
    th = out.get("reasoning_content") or out.get("reasoning") or ""
    try: plan = json.loads(txt).get("plan")
    except Exception: plan = None
    return r["turn"], r["why"], round(time.time() - t0), len(th), plan, txt[:100]
with cf.ThreadPoolExecutor(8) as ex:
    for x in ex.map(ask, rows): print(x)
