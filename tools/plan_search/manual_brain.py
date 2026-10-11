"""MANUAL BRAIN helper: show the oldest unanswered parked request compactly; answer it.

  python -m tools.plan_search.manual_brain show <dir>          # condensed view of the pending request
  python -m tools.plan_search.manual_brain full <dir>          # dump the full pending packet to <dir>/pending_full.json
  python -m tools.plan_search.manual_brain answer <dir> <file|json>
"""
import json
import sys
from pathlib import Path


def pending(d: Path):
    for f in sorted(d.glob("req_*.json")):
        if not (d / f.name.replace("req_", "resp_").replace(".json", ".txt")).exists():
            return f
    return None


def mline(m):
    return "%s %s%s pri=%s" % (m.get("task"), m.get("area"), (" vs " + m["vs"]) if m.get("vs") else "", m.get("priority", ""))


def show(d: Path):
    f = pending(d)
    if f is None:
        print("no pending request")
        return
    r = json.loads(f.read_text(encoding="utf-8"))
    pk = json.loads(r["messages"][-1]["content"])
    print("== %s %s turn=%s retry=%s" % (f.name, r["request"], r["turn"], r["retry"]))
    cs = pk.get("compact_state") or {}
    print("RED:", "; ".join("%s %s (%s,%s) %s" % (u["unit_id"], u["class"], u["q"], u["r"], u.get("soldiers")) for u in cs.get("friendly_units", [])))
    print("BLUE:", "; ".join("%s %s (%s,%s) %s" % (e["unit_id"], e["class"], e["q"], e["r"], e.get("troop_estimate")) for e in cs.get("known_enemy_units", [])))
    tr = pk.get("review_trigger") or {}
    if tr:
        print("TRIGGER:", tr.get("trigger"), "|", str(tr.get("reason", ""))[:200], "| also_due:", tr.get("also_due"))
    pl = pk.get("plan_live") or {}
    if pl:
        print("PHASE:", pl.get("current_phase_id"), "| missions:", "; ".join("%s %s %s %s units=%s" % (s["mission_id"], s["task"], s["area"], s["status"], s.get("units")) for s in pl.get("mission_statuses", [])))
    for ph in (pk.get("plan_authoring") or {}).get("phases", []):
        print("  PLAN %s: %s" % (ph.get("id"), " | ".join(mline(m) for m in ph.get("missions", []))))
    ff = (pk.get("force_feedback") or {}).get("units", [])
    for u in ff:
        print("  HAND %s m=%s %s role=%s eng=%s :: %s" % (u["unit_id"], u["mission_id"], u["task"], u.get("role"), u.get("engagement"), ", ".join(u.get("recent_actions", []))))
    ev = pk.get("events_since_review") or []
    kinds = {}
    for e in ev:
        kinds[e.get("kind")] = kinds.get(e.get("kind"), 0) + 1
    if ev:
        print("EVENTS:", kinds)
    if pk.get("replan_context"):
        print("REPLAN_CONTEXT:", json.dumps(pk["replan_context"].get("since_last_plan"), ensure_ascii=False))


def main():
    cmd, d = sys.argv[1], Path(sys.argv[2])
    if cmd == "show":
        show(d)
    elif cmd == "full":
        f = pending(d)
        r = json.loads(f.read_text(encoding="utf-8"))
        (d / "pending_full.json").write_text(json.dumps({"system": r["messages"][0]["content"],
                                                         "packet": json.loads(r["messages"][-1]["content"])},
                                                        ensure_ascii=False, indent=1), encoding="utf-8")
        print("wrote", d / "pending_full.json")
    elif cmd == "answer":
        f = pending(d)
        src = sys.argv[3]
        txt = Path(src).read_text(encoding="utf-8") if Path(src).exists() else src
        json.loads(txt)
        (d / f.name.replace("req_", "resp_").replace(".json", ".txt")).write_text(txt, encoding="utf-8")
        print("answered", f.name)


if __name__ == "__main__":
    main()
