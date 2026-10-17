"""Periodic PLAN CHECK shim (2026-10-15, user): Qwen plays normally with its full context; every EVERY turns (and when it has made
almost no progress) one key "plan_check" is added to the user message asking it to judge its standing plan: KEEP or REVISE,
with the reason, and write the plan for the rest of the battle. The original (cue-free) messages, the state and Qwen's answer are
logged: that is the raw material the teacher judges. Nothing else is changed.
  python -m tools.synth_adv_v1.plan_check_shim --port 8171 --target http://127.0.0.1:8120 --log <dir>/checks.jsonl
"""
import argparse, hashlib, json, time, urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from tools.synth_adv_v1.stall_shim import progress

CUE = ("PLAN CHECK: compare your standing plan with the board now. In \"plan\" (at most 300 chars) start with \"KEEP:\" and the "
       "reason if the plan still fits this board, or \"REVISE:\" and why it fails, then the plan for the rest of the battle "
       "(phases, who attacks what, a turn deadline). Orders as usual.")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=8171)
    ap.add_argument("--target", default="http://127.0.0.1:8120")
    ap.add_argument("--log", required=True)
    ap.add_argument("--every", type=int, default=10)
    ap.add_argument("--min-turn", type=int, default=8)
    ap.add_argument("--window", type=int, default=5)
    ap.add_argument("--min-progress", type=float, default=40)
    ap.add_argument("--gap", type=int, default=5)
    a = ap.parse_args()
    last = {}

    class H(BaseHTTPRequestHandler):
        def log_message(self, *x):
            pass

        def do_POST(self):  # noqa: N802
            raw = self.rfile.read(int(self.headers.get("Content-Length") or 0))
            body, rec = raw, None
            try:
                d = json.loads(raw)
                st = d.get("state") if isinstance(d.get("state"), dict) else {}
                turn = int(st.get("turn") or 0)
                msgs = d.get("messages") or []
                fu = next((m.get("content") for m in msgs if m.get("role") == "user"), "") or ""
                key = hashlib.sha1(fu.encode("utf-8")).hexdigest()[:12]
                if turn < last.get(key, -99):
                    last.pop(key, None)
                gap = turn - last.get(key, -99)
                if turn >= a.min_turn and st.get("my_units") is not None and gap >= a.gap:
                    prog, n = progress(msgs, turn, a.window)
                    why = "periodic" if turn % a.every == 0 else ("stall" if prog < a.min_progress else None)
                    if why:
                        lu = json.loads(msgs[-1]["content"])
                        lu["plan_check"] = CUE
                        rec = {"key": key, "turn": turn, "why": why, "progress": prog, "orig_messages": msgs, "state": st,
                               "extra": {k: v for k, v in d.items() if k not in ("messages", "state")}}
                        d["messages"] = msgs[:-1] + [dict(msgs[-1], content=json.dumps(lu, ensure_ascii=False, separators=(",", ":")))]
                        body = json.dumps(d, ensure_ascii=False).encode("utf-8")
                        last[key] = turn
            except (ValueError, KeyError, IndexError, TypeError):
                pass
            hdr = {k: v for k, v in self.headers.items() if k.lower() not in ("host", "content-length")}
            req = urllib.request.Request(a.target + self.path, data=body, headers=hdr, method="POST")
            try:
                with urllib.request.urlopen(req, timeout=3600) as r:
                    out, code = r.read(), r.status
            except Exception as e:  # noqa: BLE001
                out, code = json.dumps({"error": str(e)}).encode(), 502
            if rec is not None:
                try:
                    rec["response"] = json.loads(out)["choices"][0]["message"]["content"]
                except Exception:  # noqa: BLE001
                    rec["response"] = None
                rec["code"], rec["ts"] = code, time.time()
                with open(a.log, "a", encoding="utf-8") as fh:
                    fh.write(json.dumps(rec, ensure_ascii=False) + "\n")
            self.send_response(code)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(out)))
            self.end_headers()
            self.wfile.write(out)

    ThreadingHTTPServer(("127.0.0.1", a.port), H).serve_forever()


if __name__ == "__main__":
    main()
