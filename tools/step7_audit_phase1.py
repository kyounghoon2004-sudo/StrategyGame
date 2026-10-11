#!/usr/bin/env python3
"""Phase-1 real-model audit: exact in-game context -> Ollama -> raw intents.

Uses byte-identical system prompt + capabilities dumped from the game
(tools/.audit_phase1_ctx.json) and the real roster layout from the
canonical scene probe. Writes tools/.audit_phase1_raw.json for the
in-engine validator (tools/step7_audit_intent_batch.gd).

Generation options mirror the shipped game config (Phase-1 pins greedy
decoding; see Step7OllamaConfig).
"""
import json, os, sys, time
from concurrent.futures import ThreadPoolExecutor
import requests

PROJ = r"D:\Game development\Demon slayer\StrategyGame"
CTX_PATH = os.path.join(PROJ, "tools", ".audit_phase1_ctx.json")
OUT_PATH = os.path.join(PROJ, "tools", ".audit_phase1_raw.json")
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

PENDING_CAV = {"command_id": "cmd-0001", "original_text": "기병 전진",
    "action": "ADVANCE", "scope_type": "WING_CLASS", "class": "CAVALRY",
    "region": "", "unit_id": "", "missing": ["region"],
    "question": "어느 기병대를 말씀하십니까? 좌익, 우익 중 지정해 주십시오.",
    "wings": ["LEFT", "RIGHT"], "state_version": 0, "fingerprint": "x",
    "turn": 1, "config_identity": "y"}

COMMANDS = [
    ("whole_advance_1", "전군 진격", None, None),
    ("whole_advance_2", "모두 앞으로", None, None),
    ("whole_hold", "전군 대기", None, None),
    ("whole_retreat", "전군 후퇴", None, None),
    ("cav_bare", "기병 전진", None, None),
    ("cav_both", "기병 양쪽 다 전진", None, None),
    ("cav_left_push", "좌익 기병 밀어", None, None),
    ("cav_left_v2", "좌익의 기병 전진", None, None),
    ("cav_left_v3", "왼쪽 기병 전진", None, None),
    ("cav_extreme_deep", "극좌익 기병 깊게 보내", None, None),
    ("cav_flank", "기병 우회", None, None),
    ("cav_hold", "기병 대기", None, None),
    ("inf_center", "중앙 보병 진격", None, None),
    ("inf_line", "보병은 전열 유지하면서 전진", None, None),
    ("inf_bare", "보병 전진", None, None),
    ("inf_regroup", "보병 재배치", None, None),
    ("arc_forward", "궁병 앞으로", None, None),
    ("arc_cautious", "궁병은 너무 노출되지 않게 이동", None, None),
    ("arc_bare", "궁병 전진", None, None),
    ("arc_hold", "궁병 대기", None, None),
    ("spe_right", "우익 창병 전진", None, None),
    ("spe_deny", "창병으로 기병 접근 막아", None, None),
    ("spe_bare", "창병 전진", None, None),
    ("sct_deep", "정찰병 깊게 정찰", None, None),
    ("sct_forward", "정찰대를 앞으로 보내", None, None),
    ("sct_check", "정찰병으로 앞쪽 확인해", None, None),
    ("sct_bare", "정찰병 전진", None, None),
    ("sct_recon_left", "좌익 정찰병 정찰", None, None),
    ("sie_forward", "공성대 전진", None, None),
    ("sie_safe", "공성대는 안전하게 따라와", None, None),
    ("sie_follow", "공성대 따라와", None, None),
    ("con_follow", "징집병 따라와", None, None),
    ("sie_bare", "공성병 전진", None, None),
    ("con_safe", "징집병 안전하게 전진", None, None),
    ("con_bare", "징집병 전진", None, None),
    ("hold_both", "양쪽 대기", None, None),
    ("recon_both", "양쪽 정찰", None, None),
    ("ret_left", "좌익 철수", None, None),
    ("multi_inf_spe", "보병과 창병 둘 다 전진", None, None),
    ("deictic", "이 부대 앞으로", None,
     {"id": "B_CAV_2", "class": "CAVALRY", "faction": "blue", "cluster": "L2"}),
    ("both_answer", "둘다", PENDING_CAV, None),
    ("both_answer_2", "양쪽 다", PENDING_CAV, None),
    ("left_answer", "좌익", PENDING_CAV, None),
    ("prev_do", "그렇게 해", None, None),
    ("prev_do2", "아까 말한 대로 해", None, None),
    ("advice", "지금 전황이 어때", None, None),
    ("advice_which", "어떤 기동이 좋을까", None, None),
    ("vague", "음...", None, None),
    ("vague2", "저기 저거 해줘", None, None),
    ("nonsense", "김치찌개 먹고 싶다", None, None),
    ("hq", "지휘부 전진", None, None),
    ("sup", "보급대 전진", None, None),
    ("protect", "보병으로 궁병 보호해", None, None),
    ("screen", "정찰병으로 엄호 전개해", None, None),
    ("regroup", "전군 재집결", None, None),
    ("ast_hold_diff", "정찰병 제외하고 전군 대기", None, None),
    ("comp_scout", "정찰병은 전진하고 나머지는 대기", None, None),
    ("comp_cav_inf", "기병은 전진하고 보병은 대기", None, None),
    ("comp_wings", "좌익은 대기하고 우익은 전진", None, None),
    ("comp_inf_arch", "보병과 창병은 전진하고 궁병은 대기", None, None),
    ("comp_recon_main", "정찰병은 깊게 정찰하고 본대는 대기", None, None),
    ("comp_arch_rest", "궁병은 대기하고 나머지는 전진", None, None),
    ("ast_adv_union", "보병과 창병 전진", None, None),
    ("ast_adv_intersect", "좌익 기병 전진", None, None),
]

def build_user_block(ctx, tag, text, pending, selected):
    return {
        "player_message": text, "turn": 1,
        "capabilities": ctx["capabilities"],
        "deictic_reference": {},
        "friendly_layout": friendly_layout(),
        "selected_unit": selected or {},
        "pending_clarification": pending or {},
        "recent_history": [],
        "instruction": "Use capabilities + layout + pending to emit ONE command JSON with orders[] (one order per clause; one element for single orders). Whole-force words (전군/전부대/모두/전체) MUST become ALL_AVAILABLE, never a wing.",
    }

def call_one(ctx, system, item):
    tag, text, pending, selected = item
    user_block = build_user_block(ctx, tag, text, pending, selected)
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
            return {"tag": tag, "text": text, "ok": False,
                    "error": "http %d" % r.status_code, "latency_ms": dt, "raw": ""}
        body = r.json()
        content = ""
        try:
            content = body["message"]["content"]
        except KeyError:
            content = json.dumps(body, ensure_ascii=False)[:500]
        think = body.get("message", {}).get("thinking") or ""
        return {"tag": tag, "text": text, "ok": True, "latency_ms": dt, "raw": content,
                "thinking_len": len(think), "done_reason": body.get("done_reason", ""),
                "prompt_eval_count": body.get("prompt_eval_count", 0),
                "eval_count": body.get("eval_count", 0)}
    except Exception as e:
        return {"tag": tag, "text": text, "ok": False, "error": repr(e)[:200],
                "latency_ms": (time.time() - t0) * 1000, "raw": ""}

def main():
    workers = int(sys.argv[1]) if len(sys.argv) > 1 else 4
    only = sys.argv[2].split(",") if len(sys.argv) > 2 else None
    with open(CTX_PATH, encoding="utf-8") as f:
        ctx = json.load(f)
    system = ctx["action_vocab"] + "\n\n" + ctx["scope_vocab"] + "\n\n" + ctx["intent_system"]
    items = [c for c in COMMANDS if (only is None or c[0] in only)]
    print("Phase-1 matrix: %d commands, %d workers, model %s" % (len(items), workers, MODEL), flush=True)
    results = []
    with ThreadPoolExecutor(max_workers=workers) as ex:
        futs = [ex.submit(call_one, ctx, system, it) for it in items]
        for fut in futs:
            res = fut.result()
            results.append(res)
            st = "OK %dms" % res.get("latency_ms", 0) if res.get("ok") else "ERR %s" % res.get("error", "?")
            print("  [%s] %s: %s" % (res["tag"], st, res["text"]), flush=True)
    order = {}
    for idx, c in enumerate(COMMANDS):
        order[c[0]] = idx
    results.sort(key=lambda r: order.get(r["tag"], 999))
    # Merge into any existing file so single-tag diagnostic runs never
    # clobber the full matrix.
    merged = {}
    if os.path.exists(OUT_PATH):
        try:
            prev = json.load(open(OUT_PATH, encoding="utf-8"))
            for r in prev.get("results", []):
                merged[r["tag"]] = r
        except Exception:
            pass
    for r in results:
        merged[r["tag"]] = r
    results = [merged[c[0]] for c in COMMANDS if c[0] in merged]
    with open(OUT_PATH, "w", encoding="utf-8") as f:
        json.dump({"model": MODEL, "results": results}, f, ensure_ascii=False)
    print("WROTE " + OUT_PATH + " (%d rows)" % len(results), flush=True)

if __name__ == "__main__":
    main()
