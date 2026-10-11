#!/usr/bin/env python3
"""CommandIR v2 real-model probe: exact in-game Phase-1 context -> Ollama.
Uses byte-identical system prompt dumped from the game
(tools/.audit_phase1_ctx.json, refreshed via step7_audit_ctx.gd).
Writes tools/.audit_command_ir_live_raw.json for the in-engine
normalizer (tools/step7_command_ir_live_check.gd).

Generation mirrors shipped Phase-1 (greedy 0.0, 6144 budget).
"""
import json, os, sys, time
from concurrent.futures import ThreadPoolExecutor
import requests

PROJ = r"D:\Game development\Demon slayer\StrategyGame"
CTX_PATH = os.path.join(PROJ, "tools", ".audit_phase1_ctx.json")
OUT_PATH = os.path.join(PROJ, "tools", ".audit_command_ir_live_raw.json")
ENDPOINT = "http://127.0.0.1:11434/api/chat"
MODEL = "qwen38-jrell-mtp-256k:latest"

ROSTER = {
    "L2": [("B_CAV_1", "CAVALRY"), ("B_CAV_2", "CAVALRY"), ("B_CAV_3", "CAVALRY"),
           ("B_INF_4", "INFANTRY"), ("B_SCT_1", "SCOUT"), ("B_SCT_2", "SCOUT")],
    "L1": [("B_SCT_4", "SCOUT")],
    "C": [("B_ARC_1", "ARCHER"), ("B_ARC_2", "ARCHER"), ("B_ARC_3", "ARCHER"),
          ("B_ARC_5", "ARCHER"), ("B_CON_1", "CONSCRIPT"), ("B_CON_2", "CONSCRIPT"),
          ("B_CON_3", "CONSCRIPT"), ("B_CON_5", "CONSCRIPT"), ("B_INF_1", "INFANTRY"),
          ("B_INF_2", "INFANTRY"), ("B_INF_3", "INFANTRY"), ("B_INF_6", "INFANTRY"),
          ("B_SIG_1", "SIEGE"), ("B_SIG_2", "SIEGE"), ("B_SPE_1", "SPEARMAN"),
          ("B_SPE_2", "SPEARMAN"), ("B_SPE_3", "SPEARMAN"), ("B_SPE_5", "SPEARMAN"),
          ("B_SCT_5", "SCOUT")],
    "R1": [("B_INF_7", "INFANTRY")],
    "R2": [("B_CAV_4", "CAVALRY"), ("B_ARC_4", "ARCHER"), ("B_CON_4", "CONSCRIPT"),
           ("B_INF_5", "INFANTRY"), ("B_SCT_3", "SCOUT"), ("B_SPE_4", "SPEARMAN")],
}
WING = {"L2": "LEFT", "L1": "LEFT", "C": "CENTER", "R1": "RIGHT", "R2": "RIGHT"}
ORDER = ["L2", "L1", "C", "R1", "R2"]

def friendly_layout():
    out = []
    for cid in ORDER:
        counts, cav = {}, []
        for uid, cls in ROSTER[cid]:
            counts[cls] = counts.get(cls, 0) + 1
            if cls == "CAVALRY":
                cav.append(uid)
        cav.sort()
        out.append({"band": cid, "wing": WING[cid],
                    "extreme_left": cid == "L2", "extreme_right": cid == "R2",
                    "class_counts": counts, "cavalry_ids": cav})
    return out

# Coverage matrix (Step 1 B) + legacy fixtures (C) + sequence/contradiction.
COMMANDS = [
    ("live.single.whole", "전군 진격하라"),
    ("live.single.scout", "정찰병 깊게 정찰"),
    ("live.multi.scout_rest", "정찰병은 전진하고 나머지는 대기"),
    ("live.multi.wings", "좌익은 대기하고 우익은 전진"),
    ("live.multi.recon_main", "정찰병은 깊게 정찰하고 본대는 대기"),
    ("live.multi.inf_arch", "보병과 창병은 전진하고 궁병은 대기"),
    ("live.seq.inf", "보병은 먼저 전진하고 그다음 대기"),
    ("live.conflict.wing_cav", "좌익은 전진하고 기병은 대기"),
    ("live.legacy.cav_bare", "기병 전진"),
    ("live.legacy.excl", "정찰병 제외하고 전군 대기"),
    ("live.legacy.multiclass", "보병과 창병 둘 다 전진"),
    ("live.legacy.wing_cav", "좌익 기병 전진"),
]

def build_user_block(ctx, text):
    return {
        "player_message": text, "turn": 1,
        "capabilities": ctx["capabilities"],
        "deictic_reference": {},
        "friendly_layout": friendly_layout(),
        "selected_unit": {},
        "pending_clarification": {},
        "recent_history": [],
        "instruction": "Use capabilities + layout + pending to emit ONE command JSON with orders[] (one order per clause; one element for single orders). Whole-force words MUST become ALL_AVAILABLE, never a wing.",
    }

def call_one(ctx, system, item):
    tag, text = item
    user_block = build_user_block(ctx, text)
    t0 = time.time()
    try:
        r = requests.post(ENDPOINT, json={
            "model": MODEL,
            "messages": [{"role": "system", "content": system},
                         {"role": "user", "content": "PLAYER_MESSAGE_JSON:\n" + json.dumps(user_block, ensure_ascii=False)}],
            "options": {"temperature": 0.0, "num_predict": 6144, "num_ctx": 12288, "think": False},
            "format": "json", "stream": False,
        }, timeout=300)
        dt = (time.time() - t0) * 1000
        if r.status_code != 200:
            return {"tag": tag, "text": text, "ok": False, "error": "http %d" % r.status_code, "latency_ms": dt, "raw": ""}
        body = r.json()
        try:
            content = body["message"]["content"]
        except KeyError:
            content = json.dumps(body, ensure_ascii=False)[:500]
        return {"tag": tag, "text": text, "ok": True, "latency_ms": dt, "raw": content,
                "done_reason": body.get("done_reason", ""),
                "eval_count": body.get("eval_count", 0)}
    except Exception as e:
        return {"tag": tag, "text": text, "ok": False, "error": repr(e)[:200],
                "latency_ms": (time.time() - t0) * 1000, "raw": ""}

def main():
    workers = int(sys.argv[1]) if len(sys.argv) > 1 else 3
    with open(CTX_PATH, encoding="utf-8") as f:
        ctx = json.load(f)
    system = ctx["action_vocab"] + "\n\n" + ctx["scope_vocab"] + "\n\n" + ctx["intent_system"]
    print("CommandIR live probe: %d commands, %d workers, model %s" % (len(COMMANDS), workers, MODEL), flush=True)
    results = []
    with ThreadPoolExecutor(max_workers=workers) as ex:
        futs = [ex.submit(call_one, ctx, system, it) for it in COMMANDS]
        for fut in futs:
            res = fut.result()
            results.append(res)
            st = "OK %dms" % res.get("latency_ms", 0) if res.get("ok") else "ERR %s" % res.get("error", "?")
            print("  [%s] %s: %s" % (res["tag"], st, res["text"]), flush=True)
    order = {c[0]: i for i, c in enumerate(COMMANDS)}
    results.sort(key=lambda r: order.get(r["tag"], 999))
    with open(OUT_PATH, "w", encoding="utf-8") as f:
        json.dump({"model": MODEL, "results": results}, f, ensure_ascii=False)
    print("WROTE " + OUT_PATH + " (%d rows)" % len(results), flush=True)

if __name__ == "__main__":
    main()
