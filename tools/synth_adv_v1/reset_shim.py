"""Context-reset shim (2026-10-15, user): sits between the game and the RED proxy. On the given turns the conversation
history is dropped and the current state is presented as a fresh battle start (system prompt + one opening-format
user message, no current_plan), so the commander has to write a new plan and orders. Nothing else is changed.

  python -m tools.synth_adv_v1.reset_shim --port 8171 --target http://127.0.0.1:8120 --reset-turns 15,30,45 --log <dir>/shim.jsonl
"""
import argparse, json, time, urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

OPENING_KEYS = ["request", "map_radius", "class_stats", "matchups", "turn_limit", "history", "turn", "turns_left",
                "why_asked", "my_units", "enemy_units"]


def fresh_opening(st):
    d = {k: st[k] for k in OPENING_KEYS if k in st}
    d["why_asked"] = "start of battle"
    return json.dumps(d, ensure_ascii=False, separators=(",", ":"))


def reset_messages(messages, st, instruct=False):
    sysm = next((m for m in messages if m.get("role") == "system"), None)
    out = [sysm] if sysm else []
    content = fresh_opening(st)
    if instruct:  # R2: say it plainly - the previous plan is stale, write a different one
        cp = st.get("current_plan")
        old = str(cp.get("text") if isinstance(cp, dict) else (cp or "")).strip()
        note = ("PLAN REVIEW (turn %s): the battle is not won yet and your previous plan has not worked." % st.get("turn"))
        if old:
            note += " Previous plan: \"%s\"." % old[:300]
        note += (" Write a NEW plan now (key \"plan\", at most 300 chars) with a different approach: a different main target, "
                 "route or grouping, and give new orders for the units that should change.")
        content = content + "\n\n" + note
    out.append({"role": "user", "content": content})
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=8171)
    ap.add_argument("--target", default="http://127.0.0.1:8120")
    ap.add_argument("--reset-turns", default="15,30,45")
    ap.add_argument("--log", required=True)
    ap.add_argument("--instruct", action="store_true", help="add the PLAN REVIEW note (R2)")
    a = ap.parse_args()
    resets = {int(x) for x in a.reset_turns.split(",") if x.strip()}

    class H(BaseHTTPRequestHandler):
        def log_message(self, *x):
            pass

        def do_POST(self):  # noqa: N802
            raw = self.rfile.read(int(self.headers.get("Content-Length") or 0))
            body, turn, did = raw, None, False
            try:
                d = json.loads(raw)
                st = d.get("state") if isinstance(d.get("state"), dict) else {}
                turn = st.get("turn")
                if turn is not None and int(turn) in resets and st.get("my_units") is not None:
                    d["messages"] = reset_messages(d.get("messages") or [], st, a.instruct)
                    body, did = json.dumps(d, ensure_ascii=False).encode("utf-8"), True
            except ValueError:
                pass
            hdr = {k: v for k, v in self.headers.items() if k.lower() not in ("host", "content-length")}
            req = urllib.request.Request(a.target + self.path, data=body, headers=hdr, method="POST")
            try:
                with urllib.request.urlopen(req, timeout=3600) as r:
                    out, code = r.read(), r.status
            except Exception as e:  # noqa: BLE001
                out, code = json.dumps({"error": str(e)}).encode(), 502
            try:
                with open(a.log, "a", encoding="utf-8") as fh:
                    fh.write(json.dumps({"ts": time.time(), "turn": turn, "reset": did, "code": code}) + "\n")
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
