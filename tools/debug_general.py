#!/usr/bin/env python3
"""Agent-as-General debug CLI: service RED General requests without any provider key.

The headless harness (scripts/cloud2/cloud2_debug_agent_entry.gd) writes
General requests as JSON and parks; this tool inspects them and submits
KEEP / ADJUST / REPLAN responses through the SAME canonical contract the
cloud provider path uses. Godot validates and executes identically.

Roles (information boundary):
  GENERAL      (default): sees ONLY the RED-authorized request packet.
  ORCHESTRATOR (--truth / orchestrator-truth): may see world-truth sidecars
               for scenario setup and evaluation. Any truth display is logged
               to truth_access.log; a BLIND_GENERAL run that logged truth
               access is classified CONTAMINATED, never blind evidence.

Typical loop:
  debug_general.py start --scenario HQ_CRITICAL --blindness BLIND_GENERAL --turns 8 --review-every 2
  debug_general.py pending --dir <run>
  debug_general.py show <request_id> --dir <run>
  debug_general.py template <request_id> --dir <run> --decision KEEP > resp.json
  debug_general.py respond <request_id> --dir <run> --file resp.json
  debug_general.py wait --dir <run> --since <request_id>
  ... repeat ...
  debug_general.py status --dir <run>
"""
import argparse
import datetime
import json
import os
import subprocess
import sys
import time

PROJ = r"D:\Game development\Demon slayer\StrategyGame"
DEFAULT_GODOT = r"C:\Users\kyoun\AppData\Local\Programs\Godot\Godot_v4.2.2-stable_win64_console.exe"
ARTIFACT_ROOT = os.path.join(PROJ, "artifacts", "agent_general_debug_harness_v0")
RUNS_ROOT = os.path.join(ARTIFACT_ROOT, "runs")
ENTRY = "res://scripts/cloud2/cloud2_debug_agent_entry.gd"
PROTOCOL = "debug_agent_protocol_v1"


def die(msg, code=2):
    print(f"error: {msg}", file=sys.stderr)
    sys.exit(code)


def load_json(path):
    with open(path, "r", encoding="utf-8") as f:
        return json.load(f)


def safe_load(path, default=None):
    # The harness rewrites status/pending atomically; a read racing the
    # rename must retry, never crash the CLI.
    for _ in range(5):
        try:
            return load_json(path)
        except Exception:
            time.sleep(0.2)
    return default if default is not None else {}


def atomic_write(path, text):
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        f.write(text)
    os.replace(tmp, path)


def run_config(run_dir):
    p = os.path.join(run_dir, "run.json")
    if not os.path.isfile(p):
        die(f"no run.json in {run_dir} (is the harness running?)")
    return load_json(p)


def blindness_of(run_dir):
    try:
        return str(run_config(run_dir).get("blindness", "SYSTEM_DEBUG")).upper()
    except SystemExit:
        raise
    except Exception:
        return "SYSTEM_DEBUG"


def log_truth_access(run_dir, request_id, role):
    line = json.dumps({"event": "TRUTH_DISPLAYED", "request_id": request_id,
                       "role": role, "at": datetime.datetime.now().isoformat(timespec="seconds")})
    with open(os.path.join(run_dir, "truth_access.log"), "a", encoding="utf-8") as f:
        f.write(line + "\n")


# ---- start ----

def cmd_start(a):
    godot = a.godot or os.environ.get("GODOT_EXE", DEFAULT_GODOT)
    if not os.path.isfile(godot):
        die(f"Godot console binary not found: {godot}")
    stamp = datetime.datetime.now().strftime("%Y%m%d_%H%M%S")
    run_id = a.run_id or f"dbg_{a.scenario.lower()}_{stamp}"
    run_dir = os.path.abspath(os.path.join(a.runs_root, run_id))
    os.makedirs(run_dir, exist_ok=True)
    log_path = os.path.join(run_dir, "harness.log")
    cmd = [godot, "--headless", "--path", a.project, "-s", ENTRY, "--",
           f"--scenario={a.scenario}", f"--run-dir={run_dir}", f"--run-id={run_id}",
           f"--blindness={a.blindness}", f"--turns={a.turns}",
           f"--review-every={a.review_every}", f"--timeout-sec={a.timeout_sec}",
           f"--blue={a.blue}"]
    env = dict(os.environ)
    env["JEV_SHADOW_ENABLE"] = "0"  # harness: deterministic, JEV authority WITHHELD
    logf = open(log_path, "w", encoding="utf-8")
    proc = subprocess.Popen(cmd, cwd=a.project, stdout=logf, stderr=subprocess.STDOUT, env=env)
    print(json.dumps({"run_id": run_id, "run_dir": run_dir, "pid": proc.pid,
                      "log": log_path, "scenario": a.scenario,
                      "blindness": a.blindness.upper()}, indent=2))
    print(f"harness starting (pid={proc.pid}); use `pending --dir \"{run_dir}\"` to watch for requests.")


# ---- pending / status / audit ----

def cmd_pending(a):
    run_dir = a.dir
    pend = load_json(os.path.join(run_dir, "pending.json")) if os.path.isfile(os.path.join(run_dir, "pending.json")) else {}
    status = load_json(os.path.join(run_dir, "status.json")) if os.path.isfile(os.path.join(run_dir, "status.json")) else {}
    req_id = pend.get("request_id")
    out = {"run_dir": run_dir, "phase": status.get("phase"), "turn": status.get("turn"),
           "pending_request": req_id, "kind": status.get("kind"),
           "trigger": status.get("trigger"), "plan_version": status.get("plan_version")}
    print(json.dumps(out, indent=2))
    if req_id:
        print(f"next: show {req_id} --dir \"{run_dir}\"")


def cmd_status(a):
    run_dir = a.dir
    cfg = run_config(run_dir)
    status = load_json(os.path.join(run_dir, "status.json")) if os.path.isfile(os.path.join(run_dir, "status.json")) else {}
    battle = load_json(os.path.join(run_dir, "battle.json")) if os.path.isfile(os.path.join(run_dir, "battle.json")) else {}
    audit_path = os.path.join(run_dir, "audit.jsonl")
    events = {}
    if os.path.isfile(audit_path):
        with open(audit_path, encoding="utf-8") as f:
            for line in f:
                try:
                    e = json.loads(line).get("event", "?")
                    events[e] = events.get(e, 0) + 1
                except Exception:
                    pass
    contaminated = os.path.isfile(os.path.join(run_dir, "truth_access.log"))
    print(json.dumps({"run_id": cfg.get("run_id"), "scenario": cfg.get("scenario_id"),
                      "backend": cfg.get("backend"), "blindness": cfg.get("blindness"),
                      "phase": status.get("phase"), "turn": status.get("turn"),
                      "pending_request": status.get("pending_request"),
                      "classification": battle.get("classification") or status.get("classification"),
                      "truth_access_logged": contaminated,
                      "decisions": battle.get("decisions"),
                      "rejected_responses": battle.get("rejected_responses"),
                      "provider_calls": battle.get("provider_calls", 0),
                      "audit_events": events, "outcome": battle.get("outcome")}, indent=2))


def cmd_audit(a):
    path = os.path.join(a.dir, "audit.jsonl")
    if not os.path.isfile(path):
        die(f"no audit log yet in {a.dir}")
    with open(path, encoding="utf-8") as f:
        lines = f.readlines()
    for line in lines[-a.tail:]:
        print(line.rstrip("\n"))


def cmd_wait(a):
    run_dir = a.dir
    deadline = time.time() + a.timeout
    last = a.since
    while time.time() < deadline:
        bpath = os.path.join(run_dir, "battle.json")
        if os.path.isfile(bpath):
            b = safe_load(bpath, {})
            print(json.dumps({"done": True, "outcome": b.get("outcome"),
                              "classification": b.get("classification"),
                              "decisions": b.get("decisions")}, indent=2))
            return
        ppath = os.path.join(run_dir, "pending.json")
        cur = safe_load(ppath, {}).get("request_id") if os.path.isfile(ppath) else None
        if cur and cur != last:
            print(json.dumps({"done": False, "pending_request": cur,
                              "message": f"new request parked: {cur}"}, indent=2))
            return
        time.sleep(2.0)
    die(f"timed out after {a.timeout}s waiting for a new request or battle end.", code=3)


def cmd_stop(a):
    atomic_write(os.path.join(a.dir, "control.json"), json.dumps({"stop": True}))
    print(json.dumps({"run_dir": a.dir, "stop": True,
                      "note": "harness will stop at the next poll boundary (<=1s while parked)."}))


# ---- show (GENERAL view: authorized packet only) ----

def _fmt_units(rows):
    return [f"{u.get('unit_id')} {u.get('class','?').upper()} @({u.get('q')},{u.get('r')}) "
            f"{u.get('region','?')} {u.get('status','?')} sold={u.get('soldiers','?')} "
            f"atk={u.get('can_attack', False)}" for u in rows]


def _fmt_enemies(rows):
    return [f"{e.get('unit_id')} {e.get('class','?').upper()} @({e.get('q')},{e.get('r')}) "
            f"{e.get('region','?')} {e.get('contact_state','?')} est={e.get('troop_estimate','?')}" for e in rows]


def cmd_show(a):
    run_dir = a.dir
    if a.truth and blindness_of(run_dir) != "SYSTEM_DEBUG":
        die("refused: --truth is General-forbidden in BLIND_GENERAL mode. "
            "Use orchestrator-truth (logs access; run becomes CONTAMINATED).")
    req_path = os.path.join(run_dir, "requests", f"request_{a.request_id}.json")
    if not os.path.isfile(req_path):
        die(f"no such request: {a.request_id}")
    env = load_json(req_path)
    packet = env.get("packet", {})
    menu = env.get("menu", {})
    state = packet.get("compact_state", {})
    plan = packet.get("current_plan", {})
    missions = [f"{m.get('mission_id')} {m.get('task')} {m.get('area')} "
                f"units={m.get('units', m.get('assigned_units'))} status={m.get('status')}"
                for m in plan.get("missions", [])] if plan else ["(no current plan)"]
    groups = []
    for g in menu.get("groups", []):
        opts = [f"{o.get('id')} [{o.get('label')}]" for o in g.get("options", [])]
        groups.append(f"{g.get('id')} [{g.get('family')}] units={g.get('unit_ids')} "
                      f"regions={g.get('regions')} sold={g.get('soldiers')} :: {' | '.join(opts)}")
    view = {"request_id": env.get("request_id"), "kind": env.get("kind"),
            "turn": env.get("turn"), "snapshot_id": env.get("snapshot_id"),
            "backend": env.get("backend"), "blindness": env.get("blindness"),
            "trigger": packet.get("review_trigger", packet.get("request", "")),
            "previous_plan_version": env.get("previous_plan_version"),
            "event_kinds": env.get("event_kinds"), "event_count": env.get("event_count"),
            "mission": packet.get("mission"),
            "friendly_units": _fmt_units(state.get("friendly_units", [])),
            "known_enemy_units": _fmt_enemies(state.get("known_enemy_units", [])),
            "force_summary": state.get("force_summary"),
            "current_plan_missions": missions,
            "current_plan_concept": plan.get("concept") if plan else None,
            "current_plan_doctrine": plan.get("doctrine") if plan else None,
            "baseline_choices": packet.get("baseline_choices"),
            "has_baseline": packet.get("has_baseline"),
            "menu_groups": groups,
            "review_conditions": plan.get("review_conditions") if plan else None,
            "events_since_review": packet.get("events_since_review", [])[:8],
            "observation_scope": env.get("observation_scope")}
    if a.json:
        print(json.dumps(view, indent=2))
    else:
        print(f"=== GENERAL REQUEST {view['request_id']} ({view['kind']}) turn={view['turn']} ===")
        print(f"backend={view['backend']} blindness={view['blindness']} snapshot={view['snapshot_id']}")
        print(f"trigger={json.dumps(view['trigger'])} prev_plan_v={view['previous_plan_version']}")
        print(f"events: kinds={view['event_kinds']} count={view['event_count']}")
        print(f"\n-- RED friendly ({len(view['friendly_units'])}) --")
        print("\n".join(view["friendly_units"]) or "(none)")
        print(f"\n-- known BLUE ({len(view['known_enemy_units'])}) --")
        print("\n".join(view["known_enemy_units"]) or "(none)")
        print(f"\nforce_summary={json.dumps(view['force_summary'])}")
        print("\n-- current plan missions --")
        print("\n".join(view["current_plan_missions"]))
        print(f"\nconcept={json.dumps(view['current_plan_concept'])}")
        print(f"doctrine={json.dumps(view['current_plan_doctrine'])}")
        print(f"baseline={json.dumps(view['baseline_choices'])} has_baseline={view['has_baseline']}")
        print("\n-- coordination menu (choose ONLY these IDs) --")
        print("\n".join(view["menu_groups"]) or "(no menu)")
        print(f"\n{view['observation_scope']}")
    if a.truth:
        log_truth_access(run_dir, a.request_id, "general+truth(SYSTEM_DEBUG)")
        print_truth(run_dir, a.request_id)


def print_truth(run_dir, request_id):
    tpath = os.path.join(run_dir, "truth", f"truth_{request_id}.json")
    if not os.path.isfile(tpath):
        die(f"no truth sidecar for {request_id}")
    t = load_json(tpath)
    print("\n=== WORLD TRUTH (ORCHESTRATOR ONLY -- NON_BLIND) ===")
    for u in t.get("world_truth", {}).get("units", []):
        print(f"{u.get('unit_id')} {u.get('faction','?').upper()} {u.get('class','?')} "
              f"@({u.get('q')},{u.get('r')}) sold={u.get('soldiers')}")


def cmd_orchestrator_truth(a):
    log_truth_access(a.dir, a.request_id, "orchestrator")
    print_truth(a.dir, a.request_id)
    print("\n[logged to truth_access.log — a BLIND_GENERAL run showing this is CONTAMINATED]")


# ---- template / respond ----

def cmd_template(a):
    run_dir = a.dir
    env = load_json(os.path.join(run_dir, "requests", f"request_{a.request_id}.json"))
    kind = env.get("kind")
    menu = env.get("menu", {})
    snap = env.get("snapshot_id", "")
    decision = (a.decision or ("INITIAL" if kind == "INITIAL" else "KEEP")).upper()
    if kind == "INITIAL" or decision == "REPLAN":
        asn = []
        for g in menu.get("groups", []):
            first = (g.get("options", [{}])[0]).get("id", "")
            asn.append({"group": g.get("id"), "choice": first})
        doc = {"concept": "FIX_AND_FLANK", "main_effort": "CENTER",
               "doctrine_profile": {"aggression": "STANDARD", "tempo": "STANDARD",
                                    "risk": "BALANCED", "reserve": "STANDARD",
                                    "pursuit": "STANDARD"},
               "assignments": asn, "review_horizon": 4, "snapshot_id": snap}
        if decision == "REPLAN":
            doc = {"decision": "REPLAN", **doc}
    elif decision == "KEEP":
        doc = {"decision": "KEEP", "snapshot_id": snap}
    elif decision == "ADJUST":
        ch = []
        for g in menu.get("groups", [])[:1]:
            opts = g.get("options", [])
            pick = opts[1] if len(opts) > 1 else opts[0]
            ch.append({"group": g.get("id"), "choice": pick.get("id")})
        doc = {"decision": "ADJUST", "changes": ch, "snapshot_id": snap}
    else:
        die(f"unknown decision template: {decision}")
    print(json.dumps(doc, indent=2))


def cmd_respond(a):
    run_dir = a.dir
    cfg = run_config(run_dir)
    pend_path = os.path.join(run_dir, "pending.json")
    pend = load_json(pend_path).get("request_id") if os.path.isfile(pend_path) else None
    if pend != a.request_id:
        die(f"request {a.request_id} is not pending (pending={pend}).")
    out_path = os.path.join(run_dir, "responses", f"response_{a.request_id}.json")
    if os.path.isfile(out_path):
        die(f"a response for {a.request_id} already exists (harness has not consumed it yet).")
    if a.keep:
        env = load_json(os.path.join(run_dir, "requests", f"request_{a.request_id}.json"))
        if env.get("kind") != "REVIEW":
            die("--keep is only valid for REVIEW requests (this one is INITIAL).")
        doc = {"decision": "KEEP", "snapshot_id": env.get("snapshot_id", "")}
    elif a.file:
        with open(a.file, encoding="utf-8") as f:
            doc = json.load(f)
    elif a.decision_json:
        doc = json.loads(a.decision_json)
    else:
        die("nothing to submit: use --keep, --file, or --decision-json.")
    envelope = {"protocol": PROTOCOL, "request_id": a.request_id,
                "response_text": json.dumps(doc),
                "submitted_by": "debug_agent", "role": "GENERAL",
                "blindness": cfg.get("blindness"),
                "submitted_at": datetime.datetime.now().isoformat(timespec="seconds")}
    atomic_write(out_path, json.dumps(envelope, indent=2))
    print(json.dumps({"submitted": a.request_id, "path": out_path,
                      "chars": len(envelope["response_text"])}))


def cmd_list_runs(a):
    root = a.runs_root
    if not os.path.isdir(root):
        print("(no runs yet)")
        return
    for name in sorted(os.listdir(root)):
        rd = os.path.join(root, name)
        if not os.path.isdir(rd):
            continue
        try:
            cfg = load_json(os.path.join(rd, "run.json"))
            st = load_json(os.path.join(rd, "status.json")) if os.path.isfile(os.path.join(rd, "status.json")) else {}
            print(f"{name} scenario={cfg.get('scenario_id')} blindness={cfg.get('blindness')} "
                  f"phase={st.get('phase')} pending={st.get('pending_request')}")
        except Exception as e:
            print(f"{name} (unreadable: {e})")


def build_parser():
    p = argparse.ArgumentParser(description="Agent-as-General debug CLI (no provider key).")
    sub = p.add_subparsers(dest="cmd", required=True)

    s = sub.add_parser("start", help="launch a headless DEBUG_AGENT battle")
    s.add_argument("--scenario", required=True)
    s.add_argument("--blindness", default="SYSTEM_DEBUG")
    s.add_argument("--turns", type=int, default=8)
    s.add_argument("--review-every", type=int, default=2)
    s.add_argument("--timeout-sec", type=float, default=1800.0)
    s.add_argument("--blue", default="")
    s.add_argument("--run-id", default="")
    s.add_argument("--runs-root", default=RUNS_ROOT)
    s.add_argument("--project", default=PROJ)
    s.add_argument("--godot", default="")

    s = sub.add_parser("pending", help="show the currently parked request")
    s.add_argument("--dir", required=True)

    s = sub.add_parser("show", help="show a General request (authorized packet only)")
    s.add_argument("request_id")
    s.add_argument("--dir", required=True)
    s.add_argument("--json", action="store_true")
    s.add_argument("--truth", action="store_true",
                   help="also show world truth (SYSTEM_DEBUG runs only; logged)")

    s = sub.add_parser("orchestrator-truth", help="orchestrator role: show world truth (always logged)")
    s.add_argument("request_id")
    s.add_argument("--dir", required=True)

    s = sub.add_parser("template", help="print a fill-in response template from the live menu")
    s.add_argument("request_id")
    s.add_argument("--dir", required=True)
    s.add_argument("--decision", default="", help="KEEP|ADJUST|REPLAN|INITIAL")

    s = sub.add_parser("respond", help="submit a General response")
    s.add_argument("request_id")
    s.add_argument("--dir", required=True)
    s.add_argument("--keep", action="store_true")
    s.add_argument("--file", default="")
    s.add_argument("--decision-json", default="")

    s = sub.add_parser("wait", help="wait for a new request or battle end")
    s.add_argument("--dir", required=True)
    s.add_argument("--since", default="")
    s.add_argument("--timeout", type=float, default=1700.0)

    s = sub.add_parser("status", help="run status summary")
    s.add_argument("--dir", required=True)

    s = sub.add_parser("audit", help="print the audit log")
    s.add_argument("--dir", required=True)
    s.add_argument("--tail", type=int, default=50)

    s = sub.add_parser("stop", help="request graceful termination")
    s.add_argument("--dir", required=True)

    s = sub.add_parser("list-runs", help="list debug runs")
    s.add_argument("--runs-root", default=RUNS_ROOT)
    return p


def main():
    try:
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")
        sys.stderr.reconfigure(encoding="utf-8", errors="replace")
    except Exception:
        pass
    a = build_parser().parse_args()
    fn = {"start": cmd_start, "pending": cmd_pending, "show": cmd_show,
          "orchestrator-truth": cmd_orchestrator_truth, "template": cmd_template,
          "respond": cmd_respond, "wait": cmd_wait, "status": cmd_status,
          "audit": cmd_audit, "stop": cmd_stop, "list-runs": cmd_list_runs}[a.cmd]
    fn(a)


if __name__ == "__main__":
    main()
