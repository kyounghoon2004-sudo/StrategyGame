"""HAND B fixed-plan PROBE worker (probe-only; production worker untouched).

Wraps tools/laya/worker.py: original frozen Laya serves every side NOT in
--hand_b_sides exactly as in production; for the Hand B side(s) each /decide
is rendered with tools/hand_b/common.py and scored by the Hand B checkpoint.
Hand B needs a Hand A order; Hand A does not exist yet, so the probe passes an
explicit per-mission order table (--orders JSON {mission_id: [task, dir]}) =
a hand-authored Hand A stand-in. No Brain area token is converted inside
Hand B. Attach from Godot with LAYA_URL=http://127.0.0.1:<port>.

  <laya venv python> tools/hand_b/probe_worker.py --port 11452 --hand_b <ckpt|NONE> --orders '{...}' \
      --center 0,0 [--hand_b_sides red]
"""
import argparse, importlib.util, json, math, os, sys, time
from http.server import ThreadingHTTPServer

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import common as C

spec = importlib.util.spec_from_file_location("laya_worker", os.path.join(HERE, "..", "laya", "worker.py"))
W = importlib.util.module_from_spec(spec)
spec.loader.exec_module(W)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=11452)
    ap.add_argument("--hand_b", required=True, help="Hand B checkpoint dir, or NONE = original Laya with Hand B rendering off")
    ap.add_argument("--orders", required=True)
    ap.add_argument("--center", default="0,0")
    ap.add_argument("--hand_b_sides", default="red")
    ap.add_argument("--log", default="")
    a = ap.parse_args()
    orders = json.loads(a.orders)
    cq, cr = [int(x) for x in a.center.split(",")]
    bounds = {"q_min": cq - 1, "q_max": cq + 1, "r_min": cr - 1, "r_max": cr + 1}  # frame uses the centre only
    sides = set(a.hand_b_sides.split(","))
    agent, info = W.load_agent(W.DEFAULT_MODEL_DIR, "cuda", W.OP_MAX_LEN, W.OP_HEAD_MAX_LEN)
    dec = W.LayaDecider(agent, info, W.DEFAULT_MODEL_DIR, "cuda", a.log or None)
    hb = None
    if a.hand_b != "NONE":
        import laya
        hb = laya.load(a.hand_b, device="cuda")
        hb.cfg["max_len"], hb.cfg["head_max_len"] = W.OP_MAX_LEN, W.OP_HEAD_MAX_LEN
        hb.model.eval()
    orig = dec.decide_request
    probe_log = open(a.log + ".handb.jsonl", "a") if a.log else None

    def decide(req):
        if hb is None or req.get("side") not in sides:
            return orig(req)
        t0 = time.perf_counter()
        az = req["authorized_state"]
        u = dict(az["unit"]); u.setdefault("id", req["unit_id"])
        mid = str((az.get("unit_mission") or {}).get("mission_id", "M00"))
        task, rdir = orders.get(mid, ["HOLD", "ANY"])
        order = {"task": task, "relative_direction": rdir, "intent": C.TASK_INTENTS.get(task, "")}
        state = {"side": req["side"], "bounds": bounds, "ledger": az["knowledge"]["ledger"], "turn": req.get("turn", 1)}
        ctx = C.build_ctx(state, u)
        cands = req["candidates"]
        opts = C.render_options(u, cands, ctx)
        keys = W.option_keys(len(opts))
        qs = {"action": {"type": "choice", "instructions": C.HAND_B_INSTRUCTIONS, "criteria": dict(zip(keys, opts))}}
        st = C.render_state(order, u, ctx, req.get("turn", 1))
        with dec._lock:
            res = hb.predict(st, qs)
        ans = res["answers"]["action"]
        probs = ans["probabilities"]
        k2c = {k: c["candidate_id"] for k, c in zip(keys, cands)}
        sel = k2c[ans["choice"]]
        options = sorted([{"key": k, "candidate_id": k2c[k], "prob": round(float(probs.get(k, 0.0)), 4)} for k in keys], key=lambda o: -o["prob"])
        if probe_log:
            probe_log.write(json.dumps({"turn": req.get("turn"), "unit": req["unit_id"], "mission": mid, "order": order,
                                        "selected": sel, "top5": options[:5], "n": len(cands), "state": st}) + "\n"); probe_log.flush()
        return {"ok": True, "schema_version": W.RESPONSE_VERSION, "selected_key": ans["choice"], "selected_candidate_id": sel,
                "confidence": ans.get("confidence"), "action": ans.get("action", {}), "options": options,
                "top5": [{"candidate_id": o["candidate_id"], "prob": o["prob"]} for o in options[:5]],
                "latency_ms": {"total": round((time.perf_counter() - t0) * 1000, 1)}, "hand_b_probe": True,
                "identity": dec.identity()}

    dec.decide_request = decide
    srv = ThreadingHTTPServer(("127.0.0.1", a.port), W.make_handler(dec, None, None, None))
    srv.daemon_threads = True
    print("[hand-b-probe] READY port=%d hand_b=%s sides=%s orders=%s" % (a.port, a.hand_b, sorted(sides), orders), flush=True)
    srv.serve_forever()


if __name__ == "__main__":
    main()
