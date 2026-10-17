"""Relay shim (2026-10-16, user): inside ONE live game, on the reset turns the conversation is dropped and the board is presented as
a fresh battle start (reset_shim format) + the FACTS block, so a 'new' commander writes a new plan and carries the game on.
--history no : only the board (+FACTS).   --history yes : also the standing plan and a one-line result of the last 10 turns.
Logs every relay prompt/answer for the teacher.
--carry yes (default, true relay): after a relay turn T the same game window keeps the SHORT context until the next relay:
[system, relay prompt of T, the answer at T, then only the turn messages after T]. The game's own longer history (and its
battle digest of older turns) is not sent. Games are keyed by the X-Episode-Spec-Path window (fallback X-Episode-Id).
Every request is also logged (window, turn, messages in/out) to <log>.req.jsonl. Any shim error passes the request through.
  python -m tools.synth_adv_v1.relay_shim --port 8171 --target http://127.0.0.1:8120 --history yes --log <f>.jsonl
"""
import argparse, json, re, threading, time, urllib.parse, urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from tools.synth_adv_v1.reset_shim import fresh_opening
from tools.synth_adv_v1.facts_shim import facts_block

WIN_RE = re.compile(r"_(w[0-9]+)[.]json$")
TURN_RE = re.compile(r'\{"turn":(\d+)')
ATK = re.compile(r"^t(\d+) (R)_\S+ attack (\S+): dealt (\d+) took (\d+)(?: fieldworks -(\d+))?")
def note_for(st):
    if __import__("os").environ.get("RELAY_MODE") == "collapse":  # collapse games: win by destroying BLUE's non-HQ units
        return ("It is turn %s of %s. You win when BLUE has lost the share of its units other than the HQ that your rules state; "
                "an HQ is an ordinary unit in this battle. YOUR HQ DOES NOT COUNT: losing it neither ends the battle nor counts toward "
                "your losses, so never plan to protect or guard it; it is one more combat unit. Reply with ONE JSON object with BOTH keys: \"plan\" (required, at most "
                "300 chars: phases that name unit ids, a turn deadline per phase, what to do if a phase fails) and \"orders\" (the "
                "orders that start it)." % (st.get("turn"), st.get("turn_limit", 60)))
    hq = next((u for u in st.get("enemy_units") or [] if u.get("class") == "HQ"), None)
    hqs = ("BLUE HQ now: fortified %s, troops %s." % (hq.get("fortified"), hq.get("troops"))) if hq else ""
    return ("It is turn %s of %s. The ONLY way to win is to destroy the BLUE HQ; killing units matters only as a means to reach it, "
            "so never write kill quotas. %s Reply with ONE JSON object with BOTH keys: \"plan\" (required, at most 300 chars: phases that "
            "name unit ids, a turn deadline per phase, what to do if a phase fails) and \"orders\" (the orders that start it)."
            % (st.get("turn"), st.get("turn_limit", 60), hqs))


def last_window(messages, turn, w=10):
    seen, dealt, fw = set(), 0, 0
    for m in messages:
        if m.get("role") != "user":
            continue
        try:
            d = json.loads(m["content"])
        except (ValueError, TypeError):
            continue
        for e in d.get("events") or []:
            x = ATK.match(e)
            if x and turn - w < int(x.group(1)) <= turn and e not in seen:
                seen.add(e)
                dealt += int(x.group(4)); fw += int(x.group(6) or 0)
    return dealt, fw


def relay_messages(messages, st, history):
    sysm = next((m for m in messages if m.get("role") == "system"), None)
    out = [sysm] if sysm else []
    turn = st.get("turn")
    content = fresh_opening(st) + "\n\n" + note_for(st)
    if history:
        cp = st.get("current_plan")
        old = str(cp.get("text") if isinstance(cp, dict) else (cp or "")).strip()
        dealt, fw = last_window(messages, int(turn))
        content += ("\n\nYour standing plan so far: %s\nIn the last 10 turns RED dealt %d damage and stripped %d fieldworks. "
                    "Keeping the standing plan is a fully valid answer when it is still good: then start \"plan\" with \"KEEP:\" "
                    "and say why it still fits this board. Only if the board no longer fits it, start with \"REVISE:\" and write "
                    "the better plan. Do not change the plan just to change it."
                    % ('"%s"' % old[:300] if old else "none", dealt, fw))
    content += "\n\n" + facts_block(st)
    out.append({"role": "user", "content": content})
    return out


def game_key(headers):
    m = WIN_RE.search(urllib.parse.unquote(headers.get("X-Episode-Spec-Path") or ""))
    return m.group(1) if m else (headers.get("X-Episode-Id") or "_")


def msg_turn(m):
    """Turn of a game turn message (user role), None for the opening or anything else. Strips a leading battle digest."""
    x = TURN_RE.search(str(m.get("content") or ""))
    return int(x.group(1)) if x else None


def carry_messages(messages, relay):
    """True relay: system + relay prompt at T + answer at T + only the user/assistant pairs of turns after T."""
    sysm = next((m for m in messages if m.get("role") == "system"), None)
    T = relay["turn"]
    ans_T, tail, keep = relay.get("answer"), [], False
    for i, m in enumerate(messages):
        if m.get("role") == "user":
            t = msg_turn(m)
            if t == T and i + 1 < len(messages) and messages[i + 1].get("role") == "assistant":
                ans_T = messages[i + 1].get("content")  # the answer the game actually recorded
            keep = t is not None and t > T
            if keep:
                c = str(m.get("content") or "")
                j = c.find('{"turn":')
                tail.append({"role": "user", "content": c[j:] if j > 0 else c})  # drop the digest of pre-relay turns
        elif m.get("role") == "assistant" and keep:
            tail.append(m)
    if ans_T is None or not tail or tail[-1].get("role") != "user":
        raise ValueError("carry: cannot rebuild (answer at T missing or last message not a turn message)")
    out = [sysm] if sysm else []
    out += [relay["prompt"], {"role": "assistant", "content": ans_T}] + tail
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=8171)
    ap.add_argument("--target", default="http://127.0.0.1:8120")
    ap.add_argument("--reset-turns", default="10,20,30,40,50")
    ap.add_argument("--history", choices=["yes", "no"], default="no")
    ap.add_argument("--think-target", default="", help="relay turns go here (thinking ON proxy); other turns go to --target")
    ap.add_argument("--log", required=True)
    ap.add_argument("--carry", choices=["yes", "no"], default="yes", help="yes: keep the short relay context after T (true relay)")
    a = ap.parse_args()
    resets = {int(x) for x in a.reset_turns.split(",") if x.strip()}
    relays, lock = {}, threading.Lock()  # game window -> {"turn", "prompt", "answer"} of the latest relay

    def req_log(row):
        try:
            with lock, open(a.log + ".req.jsonl", "a", encoding="utf-8") as fh:
                fh.write(json.dumps(row, ensure_ascii=False) + "\n")
        except OSError:
            pass

    class H(BaseHTTPRequestHandler):
        def log_message(self, *x):
            pass

        def do_POST(self):  # noqa: N802
            raw = self.rfile.read(int(self.headers.get("Content-Length") or 0))
            body, rec, key, turn, n_in, n_out, mode, err = raw, None, game_key(self.headers), None, None, None, "pass", None
            try:
                d = json.loads(raw)
                st = d.get("state") if isinstance(d.get("state"), dict) else {}
                turn = int(st["turn"]) if st.get("turn") is not None else None
                msgs = d.get("messages") or []
                n_in = len(msgs)
                with lock:
                    cur = relays.get(key)
                    if cur is not None and (turn is None or turn <= cur["turn"]):
                        relays.pop(key, None); cur = None  # a new game started in this window
                if turn is not None and turn in resets and st.get("my_units") is not None:
                    rec = {"turn": turn, "window": key, "history": a.history, "state": st, "orig_messages": msgs}
                    d["messages"] = relay_messages(msgs, st, a.history == "yes")
                    rec["relay_messages"] = d["messages"]
                    with lock:
                        relays[key] = {"turn": turn, "prompt": d["messages"][-1], "answer": None}
                    mode = "relay"
                elif cur is not None and a.carry == "yes":
                    d["messages"] = carry_messages(msgs, cur)
                    mode = "carry"
                if mode != "pass":
                    body = json.dumps(d, ensure_ascii=False).encode("utf-8")
                    n_out = len(d["messages"])
            except Exception as e:  # noqa: BLE001  never break the game: send the original request
                body, rec, mode, err = raw, None, "error", repr(e)[:300]
            hdr = {k: v for k, v in self.headers.items() if k.lower() not in ("host", "content-length")}
            tgt = a.think_target if (rec is not None and a.think_target) else a.target
            req = urllib.request.Request(tgt + self.path, data=body, headers=hdr, method="POST")
            try:
                with urllib.request.urlopen(req, timeout=3600) as r:
                    out, code = r.read(), r.status
            except Exception as e:  # noqa: BLE001
                out, code = json.dumps({"error": str(e)}).encode(), 502
            req_log({"ts": time.time(), "window": key, "turn": turn, "mode": mode, "n_in": n_in, "n_out": n_out, "code": code,
                     "err": err})
            if rec is not None:
                try:
                    rec["response"] = json.loads(out)["choices"][0]["message"]["content"]
                except Exception:  # noqa: BLE001
                    rec["response"] = None
                with lock:
                    if key in relays and relays[key]["turn"] == rec["turn"]:
                        relays[key]["answer"] = rec["response"]
                rec["ts"] = time.time()
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
