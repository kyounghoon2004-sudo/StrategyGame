"""Facts shim (arm B, 2026-10-15): appends a code-computed FACTS block to the last user message of every RED request.
Nothing else is changed. The block states what the packet already implies but the 9B gets wrong without long thinking:
who stands on the hexes touching the enemy HQ, which units can hit the HQ now, which orders cannot execute.

  python -m tools.synth_adv_v1.facts_shim --port 8171 --target http://127.0.0.1:8120 --log <file>
"""
import argparse, json, re, time, urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

NB = [(1, 0), (-1, 0), (0, 1), (0, -1), (1, -1), (-1, 1)]


def dist(a, b):
    dq, dr = a[0] - b[0], a[1] - b[1]
    return (abs(dq) + abs(dr) + abs(dq + dr)) // 2


def facts_block(st):
    mine = [u for u in st.get("my_units") or [] if isinstance(u, dict) and "q" in u]
    foes = [u for u in st.get("enemy_units") or [] if isinstance(u, dict) and "q" in u]
    ehq = next((u for u in foes if u.get("class") == "HQ"), None)
    if not ehq:
        return ""
    stats = st.get("class_stats") or {}
    hq = (ehq["q"], ehq["r"])
    where = {(u["q"], u["r"]): u for u in mine + foes}
    ring = [(hq[0] + dq, hq[1] + dr) for dq, dr in NB]
    occ_e = [h for h in ring if h in where and where[h]["id"].startswith("B_")]
    occ_m = [h for h in ring if h in where and where[h]["id"].startswith("R_")]
    free = [h for h in ring if h not in where]
    L = ["FACTS (computed by the game, exact; turn %s):" % st.get("turn")]
    L.append("- The 6 hexes touching the enemy HQ at (%d,%d): %d held by enemy units%s, %d by my units, %d free%s." % (
        hq[0], hq[1], len(occ_e),
        " (%s)" % ", ".join("%s%s" % (where[h]["id"], " fortified" if where[h].get("fortified") else "") for h in occ_e) if occ_e else "",
        len(occ_m), len(free), (": " + ", ".join("(%d,%d)" % h for h in free)) if free else " - melee units cannot reach the HQ"))
    can, cant = [], []
    for u in mine:
        if u.get("class") == "HQ":
            continue
        rng = (stats.get(u.get("class")) or {}).get("range", 1)
        d = dist((u["q"], u["r"]), hq)
        if rng >= 2 and 2 <= d <= rng:
            can.append("%s (distance %d)" % (u["id"], d))
        elif rng >= 2:
            cant.append("%s (distance %d, needs 2-%d)" % (u["id"], d, rng))
    if can:
        L.append("- Ranged units that can hit the enemy HQ right now, over any units in between: " + ", ".join(can) + ".")
    if cant:
        L.append("- Ranged units too far/close to hit the HQ: " + ", ".join(cant) + ".")
    if not free:
        stuck = [u["id"] for u in mine if u.get("order", "") == "ATTACK ENEMY_HQ" and (stats.get(u.get("class")) or {}).get("range", 1) < 2]
        if stuck:
            L.append("- Melee units ordered ATTACK ENEMY_HQ that cannot execute it until a hex next to the HQ is freed: " + ", ".join(stuck) + ".")
    ring_e = [where[h] for h in occ_e]
    if ring_e:
        weak = sorted(ring_e, key=lambda u: (not u.get("fortified"), str(u.get("troops"))))
        L.append("- Units on the ring: " + "; ".join("%s at (%d,%d) %s%s" % (u["id"], u["q"], u["r"], u.get("troops"), ", fortified %s" % u["fortified"] if u.get("fortified") else "") for u in weak) + ".")
    mhq = next((u for u in mine if u.get("class") == "HQ"), None)
    if mhq:
        thr = [u["id"] for u in foes if u.get("class") != "HQ" and dist((u["q"], u["r"]), (mhq["q"], mhq["r"])) <= 2]
        L.append("- My HQ %s: %s soldiers, fortified %s; enemy units within 2 hexes of it: %s." % (mhq["id"], mhq.get("soldiers"), mhq.get("fortified", 0), ", ".join(thr) if thr else "none"))
    return "\n".join(L)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=8171)
    ap.add_argument("--target", default="http://127.0.0.1:8120")
    ap.add_argument("--log", required=True)
    a = ap.parse_args()

    class H(BaseHTTPRequestHandler):
        def log_message(self, *x):
            pass

        def do_POST(self):  # noqa: N802
            raw = self.rfile.read(int(self.headers.get("Content-Length") or 0))
            body, added = raw, 0
            try:
                d = json.loads(raw)
                st = d.get("state") if isinstance(d.get("state"), dict) else {}
                blk = facts_block(st) if st else ""
                if blk:
                    for m in reversed(d.get("messages") or []):
                        if m.get("role") == "user" and isinstance(m.get("content"), str):
                            m["content"] += "\n\n" + blk
                            added = len(blk)
                            break
                    body = json.dumps(d, ensure_ascii=False).encode("utf-8")
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
                    fh.write(json.dumps({"ts": time.time(), "added": added, "code": code}) + "\n")
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
