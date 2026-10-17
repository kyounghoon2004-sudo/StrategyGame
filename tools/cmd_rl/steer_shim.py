"""Prompt shim (2026-10-12, user): sits between the game and the RED proxy and edits the prompt only; no game or
policy code changes.  Three independent features:

  --steer FILE          the text of FILE (if non-empty) is appended to the last user message of every request
  --stall               append a STATE CHECK block: facts about own units that made no progress for 3 turns
                        (computed from the request packet: order, position, history, enemy positions)
  --retry-empty-t1 N    turn 1 answered with empty orders -> ask again, up to N times (an opening needs orders)

Requests are logged to <steer dir>/shim.jsonl (turn, applied, retries, the appended text).

  python -m tools.cmd_rl.steer_shim --port 8171 --target http://127.0.0.1:8122 --steer <dir>/steer.txt --stall
"""
from __future__ import annotations

import argparse
import json
import re
import time
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

NL = chr(10)
ORD_RE = re.compile(r"^(?:ATTACK|MOVE|RAID)")
MOVE_RE = re.compile(r"^t(\d+) (\S+) move (\S+)>(\S+)")
ATK_RE = re.compile(r"^t(\d+) (\S+) attack (\S+): dealt (\d+) took (\d+)")
NEIGH = ((1, 0), (-1, 0), (0, 1), (0, -1), (1, -1), (-1, 1))


UNIT_RE = re.compile(r"^(\S+) (-?\d+),(-?\d+) (\d+)")


def _conversation(messages):
    """Positions of own units per turn and own attack results, read from the user messages of the conversation
    (the packet's history holds only what the enemy did; own moves are only in earlier turn messages)."""
    pos, atk = {}, {}
    for m in messages or []:
        if m.get("role") != "user" or not isinstance(m.get("content"), str):
            continue
        try:
            d = json.loads(m["content"])
        except ValueError:
            continue
        t = d.get("turn")
        if t is None:
            continue
        for u in d.get("my_units") or []:
            if isinstance(u, str):
                x = UNIT_RE.match(u)
                if x:
                    pos.setdefault(x.group(1), {})[int(t)] = (int(x.group(2)), int(x.group(3)))
            elif isinstance(u, dict) and "q" in u:
                pos.setdefault(u["id"], {})[int(t)] = (u["q"], u["r"])
        for e in d.get("events") or []:
            x = ATK_RE.match(e)
            if x:
                atk.setdefault(x.group(2), {})[int(x.group(1))] = (int(x.group(4)), int(x.group(5)))
    return pos, atk


def stall_block(st, messages=None, n_idle=3):
    """Own units with a moving/attacking order that stood on the same hex and killed no soldiers for n_idle turns."""
    turn = int(st.get("turn") or 0)
    if turn <= n_idle:
        return ""
    mine = st.get("my_units") or []
    foes = st.get("enemy_units") or []
    occupied = {(u["q"], u["r"]) for u in mine + foes if "q" in u}
    enemy = {u["id"]: u for u in foes}
    hq = next((u for u in foes if u.get("class") == "HQ"), None)
    pos, atk = _conversation(messages)
    for u in mine:
        pos.setdefault(u["id"], {})[turn] = (u["q"], u["r"])
    lines, ok = [], 0
    for u in mine:
        order = str(u.get("order") or "")
        if u.get("class") == "HQ" or not ORD_RE.match(order):
            continue
        track = [pos.get(u["id"], {}).get(t) for t in range(turn - n_idle, turn + 1)]
        if any(p is None for p in track):
            ok += 1  # not enough history to say
            continue
        moved = len(set(track)) > 1
        dealt = took = 0
        for t in range(turn - n_idle, turn):
            e = atk.get(u["id"], {}).get(t)
            if e:
                dealt += e[0]
                took += e[1]
        if moved or dealt > 0:
            ok += 1
            continue
        if order.startswith("MOVE"):  # on its destination = a finished order
            dest = order.split(" ", 1)[1] if " " in order else ""
            if dest == "MY_HQ":
                h = next((x for x in mine if x.get("class") == "HQ"), None)
                ok += 1 if h and (u["q"], u["r"]) == (h["q"], h["r"]) else 0
                if h and (u["q"], u["r"]) == (h["q"], h["r"]):
                    continue
            elif re.match(r"^-?\d+,-?\d+$", dest) and (u["q"], u["r"]) == tuple(int(x) for x in dest.split(",")):
                ok += 1
                continue
        tid = order.split(" ", 1)[1] if " " in order else ""
        tgt = hq if tid == "ENEMY_HQ" else enemy.get(tid)
        extra = ""
        if tgt is not None and "q" in tgt:
            free = sum(1 for dq, dr in NEIGH if (tgt["q"] + dq, tgt["r"] + dr) not in occupied)
            extra = "; %s at %d,%d%s; free hexes next to it: %d" % (
                tgt["id"], tgt["q"], tgt["r"], (" fortified %s" % tgt["fortified"]) if tgt.get("fortified") else "", free)
        elif tid:
            extra = "; target %s not in view" % tid
        lines.append("%s order %s: same hex and no soldiers killed in the last %d turns (attacks dealt %d, took %d)%s"
                     % (u["id"], order, n_idle, dealt, took, extra))
    if not lines:
        return ""
    head = "STATE CHECK (turn %d): %d own units made no progress, %d did." % (turn, len(lines), ok)
    return head + NL + "- " + (NL + "- ").join(lines)



VS_RE = re.compile(r"(\S+) eta (\d+) dealt (\d+)-(\d+) taken (\d+)-(\d+)")


def aid_block(st):
    """Facts, computed from the packet: per own unit the targets it can hit now or after one move with the game's own
    expected damage dealt/taken, the enemy units sorted by remaining soldiers, which of them are fortified (inert)."""
    mine = st.get("my_units") or []
    foes = st.get("enemy_units") or []
    lines = []
    for u in mine:
        if not isinstance(u, dict):
            continue
        opts = []
        for part in u.get("vs") or []:
            m = VS_RE.search(part)
            if m:
                dl = (int(m.group(3)) + int(m.group(4))) / 2
                tk = (int(m.group(5)) + int(m.group(6))) / 2
                if dl > 1:
                    opts.append((int(m.group(2)), -(dl - 0.5 * tk), m.group(1), dl, tk))
        opts.sort()
        if opts:
            lines.append("%s: " % u["id"] + "; ".join("%s %s +%d/-%d" % (o[2], "now" if o[0] == 0 else "after 1 move", o[3], o[4])
                                                   for o in opts[:3]))
    if not lines and not foes:
        return ""
    en = []
    for e in foes:
        if isinstance(e, dict):
            en.append("%s %s,%s %s%s" % (e.get("id"), e.get("q"), e.get("r"), e.get("troops"),
                                         " FORTIFIED(cannot attack)" if e.get("fortified") else ""))
    return ("TACTICAL AID (computed from the same state): best targets per unit (expected soldiers dealt/taken):" + NL +
            NL.join(lines) + NL + "Enemy by position/soldiers: " + "; ".join(en))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=8171)
    ap.add_argument("--target", default="http://127.0.0.1:8122")
    ap.add_argument("--steer", required=True)
    ap.add_argument("--stall", action="store_true")
    ap.add_argument("--aid", action="store_true", help="append the TACTICAL AID block (best targets per unit, enemy list)")
    ap.add_argument("--retry-empty-t1", type=int, default=0)
    a = ap.parse_args()
    steer = Path(a.steer)
    log = steer.parent / "shim.jsonl"

    class H(BaseHTTPRequestHandler):
        def log_message(self, *x):  # noqa: D401
            pass

        def do_POST(self):  # noqa: N802
            raw = self.rfile.read(int(self.headers.get("Content-Length") or 0))
            note = ""
            try:
                note = steer.read_text(encoding="utf-8").strip() if steer.exists() else ""
            except OSError:
                note = ""
            body, applied, turn = raw, False, None
            try:
                d = json.loads(raw)
                st = d.get("state") if isinstance(d.get("state"), dict) else {}
                turn = st.get("turn")
                add = note
                if a.stall and st:
                    blk = stall_block(st, d.get("messages"))
                    if blk:
                        add = (note + NL * 2 + blk).strip()
                if a.aid and st:
                    blk = aid_block(st)
                    if blk:
                        add = (add + NL * 2 + blk).strip()
                if add:
                    for m in reversed(d.get("messages") or []):
                        if m.get("role") == "user" and isinstance(m.get("content"), str):
                            m["content"] = m["content"] + NL * 2 + add
                            applied = True
                            break
                    body = json.dumps(d, ensure_ascii=False).encode("utf-8")
                note = add
            except ValueError:
                pass
            hdr = {k: v for k, v in self.headers.items() if k.lower() not in ("host", "content-length")}
            retries = 0
            while True:
                req = urllib.request.Request(a.target + self.path, data=body, headers=hdr, method="POST")
                try:
                    with urllib.request.urlopen(req, timeout=3600) as r:
                        out, code = r.read(), r.status
                except Exception as e:  # noqa: BLE001
                    out, code = json.dumps({"error": str(e)}).encode(), 502
                if not (a.retry_empty_t1 and turn == 1 and retries < a.retry_empty_t1 and code == 200):
                    break
                try:
                    txt = json.loads(out)["choices"][0]["message"]["content"].split("</think>")[-1].strip()
                    empty = not json.loads(txt).get("orders")
                except Exception:  # noqa: BLE001
                    empty = False
                if not empty:
                    break
                retries += 1
            try:
                with open(log, "a", encoding="utf-8") as fh:
                    fh.write(json.dumps({"ts": time.time(), "applied": applied, "turn": turn, "retries": retries,
                                         "note": note[:700]}) + NL)
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
