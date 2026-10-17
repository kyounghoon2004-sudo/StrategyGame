"""Hybrid router (user, 2026-10-15): think only when needed, with a large soft budget.
  - turn 1                                  -> THINK proxy (opening plan)
  - turn >= MIN_TURN, >= GAP turns after the last thinking turn, and little progress in the last WINDOW turns -> THINK proxy,
    with a PLAN REVIEW note (current plan + what the last turns achieved; keep it or replace it)
  - every other turn                        -> FAST proxy (thinking off)
Every request also gets the FACTS block. The think proxy runs with a large budget (budget forcing = the soft stop: thinking is
closed and the model writes its answer), the fast proxy with thinking off.
"""
import argparse
import hashlib
import json
import time
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

from tools.synth_adv_v1.facts_shim import facts_block
from tools.synth_adv_v1.stall_shim import progress


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=8171)
    ap.add_argument("--fast", default="http://127.0.0.1:8120")
    ap.add_argument("--think", default="http://127.0.0.1:8124")
    ap.add_argument("--log", required=True)
    ap.add_argument("--min-turn", type=int, default=12)
    ap.add_argument("--gap", type=int, default=8)
    ap.add_argument("--window", type=int, default=5)
    ap.add_argument("--min-progress", type=float, default=40)
    a = ap.parse_args()
    S = {}

    class H(BaseHTTPRequestHandler):
        def log_message(self, *x):
            pass

        def do_POST(self):  # noqa: N802
            raw = self.rfile.read(int(self.headers.get("Content-Length") or 0))
            body, mode, why, turn, prog = raw, "fast", "", None, None
            try:
                d = json.loads(raw)
                st = d.get("state") if isinstance(d.get("state"), dict) else {}
                turn = int(st.get("turn") or 0)
                fu = next((m.get("content") for m in d.get("messages") or [] if m.get("role") == "user"), "") or ""
                key = hashlib.sha1(fu.encode("utf-8")).hexdigest()[:12]
                g = S.setdefault(key, {"last_think": -99})
                if turn < g["last_think"]:
                    g["last_think"] = -99
                note = ""
                if turn == 1:
                    mode, why = "think", "opening plan"
                elif turn >= a.min_turn and turn - g["last_think"] >= a.gap and st.get("my_units") is not None:
                    prog, n = progress(d.get("messages") or [], turn, a.window)
                    if prog < a.min_progress:
                        mode, why = "think", "no progress"
                        cp = st.get("current_plan")
                        old = str(cp.get("text") if isinstance(cp, dict) else (cp or "")).strip()
                        note = "PLAN REVIEW (turn %d): over the last %d turns your attacks made little progress (damage dealt %.0f, %d attacks)." % (
                            turn, a.window, prog, n)
                        if old:
                            note += ' Your current plan: "%s".' % old[:300]
                        note += (" If the facts below show the plan still fits, keep it and only adjust orders; if they show it cannot work, "
                                 'write a new plan (key "plan") with a different approach and new orders.')
                if mode == "think":
                    g["last_think"] = turn
                blk = facts_block(st) if st else ""
                add = "\n\n".join(x for x in (note, blk) if x)
                if add:
                    for m in reversed(d.get("messages") or []):
                        if m.get("role") == "user" and isinstance(m.get("content"), str):
                            m["content"] += "\n\n" + add
                            break
                    body = json.dumps(d, ensure_ascii=False).encode("utf-8")
            except ValueError:
                pass
            target = a.think if mode == "think" else a.fast
            hdr = {k: v for k, v in self.headers.items() if k.lower() not in ("host", "content-length")}
            t0 = time.time()
            req = urllib.request.Request(target + self.path, data=body, headers=hdr, method="POST")
            try:
                with urllib.request.urlopen(req, timeout=3600) as r:
                    out, code = r.read(), r.status
            except Exception as e:  # noqa: BLE001
                out, code = json.dumps({"error": str(e)}).encode(), 502
            try:
                with open(a.log, "a", encoding="utf-8") as fh:
                    fh.write(json.dumps({"ts": time.time(), "turn": turn, "mode": mode, "why": why, "progress": prog,
                                         "s": round(time.time() - t0, 1), "code": code}) + "\n")
            except OSError:
                pass
            self.send_response(code)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(out)))
            self.end_headers()
            self.wfile.write(out)

    ThreadingHTTPServer(("127.0.0.1", a.port), H).serve_forever()


if __name__ == "__main__":
    main()
