"""Stall-triggered plan review shim (R1, 2026-10-15). Between the game and the RED proxy. When RED has made almost no
progress for WINDOW turns (soldiers dealt + half the fieldworks damage < MIN_PROGRESS), the request is replaced by a fresh
battle-start prompt plus the PLAN REVIEW note (R2 wording); the original request and the answer are logged so the
answer can be trained under the ORIGINAL long-history prompt (context distillation). All other requests pass unchanged.

  python -m tools.synth_adv_v1.stall_shim --port 8171 --target http://127.0.0.1:8120 --log <dir>/triggers.jsonl
"""
import argparse, hashlib, json, re, time, urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from tools.synth_adv_v1.reset_shim import reset_messages

ATK = re.compile(r"^t(\d+) (R_\S+) attack (\S+): dealt (\d+) took (\d+)(?: fieldworks -(\d+))?")


def progress(messages, turn, window):
    """-> (progress, red_attack_events) over the last `window` turns, from the kept user messages of the conversation."""
    lo = turn - window + 1
    seen, prog, n = set(), 0.0, 0
    for m in messages:
        if m.get("role") != "user" or not isinstance(m.get("content"), str):
            continue
        try:
            d = json.loads(m["content"])
        except ValueError:
            continue
        for e in d.get("events") or []:
            x = ATK.match(e)
            if x and lo <= int(x.group(1)) <= turn and e not in seen:
                seen.add(e)
                n += 1
                prog += int(x.group(4)) + 0.5 * int(x.group(6) or 0)
    return prog, n


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=8171)
    ap.add_argument("--target", default="http://127.0.0.1:8120")
    ap.add_argument("--log", required=True)
    ap.add_argument("--min-turn", type=int, default=10)
    ap.add_argument("--window", type=int, default=5)
    ap.add_argument("--gap", type=int, default=6, help="min turns between two reviews of one game")
    ap.add_argument("--min-progress", type=float, default=40)
    a = ap.parse_args()
    last_rev = {}

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
                # the request carries no game id: the opening user message (full start state) identifies the game
                fu = next((m.get("content") for m in d.get("messages") or [] if m.get("role") == "user"), "") or ""
                key = hashlib.sha1(fu.encode("utf-8")).hexdigest()[:12]
                if turn < last_rev.get(key, -99):
                    last_rev.pop(key, None)
                if turn >= a.min_turn and st.get("my_units") is not None and turn - last_rev.get(key, -99) >= a.gap:
                    prog, n = progress(d.get("messages") or [], turn, a.window)
                    if prog < a.min_progress:
                        rec = {"key": key, "turn": turn, "progress": prog, "attacks": n,
                               "extra": {k: v for k, v in d.items() if k not in ("messages", "state")},
                               "orig_messages": d.get("messages"), "state": st}
                        d["messages"] = reset_messages(d.get("messages") or [], st, True)
                        body = json.dumps(d, ensure_ascii=False).encode("utf-8")
                        last_rev[key] = turn
            except ValueError:
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
