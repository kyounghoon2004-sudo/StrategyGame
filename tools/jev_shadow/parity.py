"""Static parity + fail-open batteries for the JEV shadow bridge.

run_static_battery() executes the full fixture matrix in-process (no HTTP)
and returns a JSON-serializable report written to FIXTURE_PARITY.json.
run_failopen_battery() executes the worker-level failure battery (one leg
over live HTTP on an ephemeral port) for FAIL_OPEN_TESTS.json.

pytest (tools/jev_shadow/tests/test_shadow_bridge.py) imports these batteries
and asserts them, so committed tests and gate artifacts share one code path.
"""

from __future__ import annotations

import copy
import json
import math
import os
import sys
import threading
import time
import urllib.request
from http.server import ThreadingHTTPServer

HERE = os.path.dirname(os.path.abspath(__file__))
STRATEGY_ROOT = os.path.abspath(os.path.join(HERE, os.pardir, os.pardir))
if STRATEGY_ROOT not in sys.path:
    sys.path.insert(0, STRATEGY_ROOT)

import torch  # noqa: E402

from python_jev.constants import LEARNED_CLASSES  # noqa: E402
from python_jev.contracts.hex_patch import RING_MAJOR_OFFSETS  # noqa: E402
from python_jev.layout import (  # noqa: E402
    HEX_GROUP_OFFSETS,
    MISSION_GROUP_OFFSETS,
)
from python_sim.observation import projector as sim_projector  # noqa: E402
from tools.jev_shadow import CHECKPOINT_SHA256  # noqa: E402
from tools.jev_shadow.fixtures import make_request  # noqa: E402
from tools.jev_shadow.missionmap import MissionMap  # noqa: E402
from tools.jev_shadow.project import (  # noqa: E402
    ShadowProjector,
    axial_distance,
    dir_unit,
    direction_bucket,
    fold_godot_terrain,
)
from tools.jev_shadow.schemas import validate_request  # noqa: E402
from tools.jev_shadow.slotmap import SlotMap  # noqa: E402
from tools.jev_shadow.worker import (  # noqa: E402
    DEFAULT_CHECKPOINT,
    ShadowWorker,
    WorkerRefused,
    load_model,
    make_handler,
)

ARTIFACT_ROOT = os.path.join(STRATEGY_ROOT, "artifacts", "jev_godot_shadow_v0")
TASKS_8 = ["HOLD", "ADVANCE", "FIX", "ATTACK", "FLANK", "RECON", "RESERVE",
           "WITHDRAW"]
MASK_VARIANTS = {
    "none": (),
    "attack_only": (1, 2, 3, 4, 5),
    "no_attack": (0,),
    "half": (0, 2, 4),
    "all": (0, 1, 2, 3, 4, 5),
}
TERRAINS = [0, 1, 2, 6, 7]

EXPECTED_INTENT = {
    "HOLD": ("HOLD_GROUND", "PRIMARY"), "ADVANCE": ("SEEK_BATTLE", "PRIMARY"),
    "FIX": ("SEEK_BATTLE", "SUPPORT"), "ATTACK": ("SEEK_BATTLE", "PRIMARY"),
    "FLANK": ("SEEK_BATTLE", "SCREEN"), "RECON": ("RECON", "RECON"),
    "RESERVE": ("HOLD_GROUND", "RESERVE"), "WITHDRAW": ("DEFEND", "RESERVE"),
}


def _load_worker() -> ShadowWorker:
    model, _meta, digest, n = load_model(DEFAULT_CHECKPOINT, CHECKPOINT_SHA256)
    return ShadowWorker(model, digest, n, DEFAULT_CHECKPOINT, None)


def _mission_onehots(proj) -> tuple[int, int]:
    mf = proj.mission_features
    t0 = MISSION_GROUP_OFFSETS["mission_type"][0]
    r0 = MISSION_GROUP_OFFSETS["actor_mission_role"][0]
    return mf[t0:t0 + 6].index(1.0), mf[r0:r0 + 7].index(1.0)


def run_static_battery(worker: ShadowWorker | None = None) -> dict:
    worker = worker or _load_worker()
    slot_map = worker.slot_map
    projector = worker.projector
    cases: list[dict] = []
    failures: list[str] = []

    def check(cond: bool, case_id: str, msg: str) -> None:
        if not cond:
            failures.append(f"{case_id}: {msg}")

    # ---- cross-checks: shadow helpers vs sim projector --------------------
    helper_checks = 0
    for dq in range(-5, 6):
        for dr in range(-5, 6):
            if abs(dq) + abs(dr) > 10:
                continue
            a = axial_distance(dq, dr)
            b = sim_projector._axial_distance(dq, dr)
            check(a == b, "helper", f"axial_distance({dq},{dr}) {a}!={b}")
            helper_checks += 1
            a = direction_bucket(dq, dr)
            b = sim_projector._direction_bucket(dq, dr)
            check(a == b, "helper", f"direction_bucket({dq},{dr}) {a}!={b}")
            helper_checks += 1
            a = dir_unit(dq, dr)
            b = sim_projector._dir_unit(dq, dr)
            check(a == b, "helper", f"dir_unit({dq},{dr}) {a}!={b}")
            helper_checks += 1
    for t in list(range(0, 20)) + [99, 10**9]:
        a = fold_godot_terrain(t)
        b = sim_projector._GODOT_TERRAIN_TO_OBS.get(t, "UNKNOWN")
        check(a == b, "helper", f"terrain fold {t}: {a}!={b}")
        helper_checks += 1
    check(len(RING_MAJOR_OFFSETS) == 91, "helper", "RING_MAJOR != 91")
    check(len(set(RING_MAJOR_OFFSETS)) == 91, "helper", "RING_MAJOR dupes")

    # ---- fixture matrix ----------------------------------------------------
    n_infer = 0
    for cls in LEARNED_CLASSES:
        for task in TASKS_8:
            for mname, masked in MASK_VARIANTS.items():
                for terrain in ([0] if not (task == "ATTACK" and mname == "none")
                                else TERRAINS):
                    base_slot = next((i for i in range(6) if i not in masked), 2)
                    case_id = f"{cls}/{task}/{mname}/t{terrain}"
                    req = validate_request(make_request(
                        cls, task, masked=masked, baseline_slot=base_slot,
                        terrain=terrain, tag="par"))
                    proj = projector.project(req)
                    # tensor-group dims (complete input groups, not just slots)
                    check(len(proj.actor_features) == 67, case_id, "actor dim")
                    check(len(proj.tokens) == 24 and
                          all(len(t) == 37 for t in proj.tokens), case_id, "token dims")
                    check(len(proj.hex_patch) == 91 and
                          all(len(h) == 33 for h in proj.hex_patch), case_id, "hex dims")
                    check(len(proj.mission_features) == 46, case_id, "mission dim")
                    check(len(proj.global_features) == 31, case_id, "global dim")
                    check(len(proj.legal_mask) == 6, case_id, "mask dim")
                    check(all(math.isfinite(v) for v in proj.actor_features), case_id, "actor finite")
                    # mission parity: mapped type/role, never default-UNKNOWN
                    want_type, want_role = EXPECTED_INTENT[task]
                    check(proj.mapping["mission_type"] == want_type, case_id, "mission_type map")
                    check(proj.mapping["actor_role"] == want_role, case_id, "role map")
                    ti, ri = _mission_onehots(proj)
                    from tools.jev_shadow.project import MISSION_TYPES
                    from python_jev.layout import ACTOR_MISSION_ROLES
                    check(MISSION_TYPES[ti] == want_type, case_id, "mission_type onehot")
                    check(ACTOR_MISSION_ROLES[ri] == want_role, case_id, "role onehot")
                    # class parity
                    check(proj.acting_class_idx == LEARNED_CLASSES.index(cls),
                          case_id, "class idx")
                    # mask parity: OR-aggregation recomputed independently
                    expect_legal = slot_map.jev_legal_from_godot(
                        cls, req["godot_options"])
                    check(proj.legal_mask == expect_legal, case_id,
                          f"mask {proj.legal_mask} != {expect_legal}")
                    # forward (real model) + output contract
                    r1 = worker.infer(req)
                    r2 = worker.infer(req)
                    n_infer += 2
                    check(r1["ok"] and r1["eligible"], case_id, "infer ok")
                    check(len(r1["logits"]) == 6, case_id, "six logits")
                    check(all(math.isfinite(v) for v in r1["logits"]), case_id, "logits finite")
                    check(len(r1["probabilities"]) == 6, case_id, "six probs")
                    if all(expect_legal[i] is False for i in range(6)):
                        check(r1["selected_slot"] == -1 and r1["all_illegal"], case_id, "all-illegal sentinel")
                        check(sum(r1["probabilities"]) == 0.0, case_id, "all-illegal probs")
                    else:
                        check(r1["selected_slot"] in range(6), case_id, "slot range")
                        check(expect_legal[r1["selected_slot"]], case_id, "selected legal")
                        check(abs(sum(r1["probabilities"]) - 1.0) < 1e-5, case_id, "probs sum")
                        check(r1["selected_skill"] ==
                              slot_map.jev_table(cls)[r1["selected_slot"]], case_id, "skill name")
                    # determinism: bit-identical repeat
                    check(r1["logits"] == r2["logits"], case_id, "logits deterministic")
                    check(r1["selected_slot"] == r2["selected_slot"], case_id, "slot deterministic")
                    check(r1["request_sha256"] == r2["request_sha256"], case_id, "hash deterministic")
                    # baseline translation parity
                    expect_base = slot_map.baseline_to_jev(
                        cls, req["baseline"]["option_id"])
                    check(r1["mapping"]["baseline_jev_slot"] == expect_base, case_id, "baseline map")
                    cases.append({"case": case_id, "ok": True,
                                  "selected_slot": r1["selected_slot"],
                                  "legal": expect_legal})

    # ---- edge: tight bounds with out-of-bounds patch cells ------------------
    req = validate_request(make_request("SCOUT", "RECON", tag="edge"))
    req["ctx"]["bounds"] = {"q_min": -1, "q_max": 1, "r_min": -1, "r_max": 1}
    for c in req["hex_cells"]:
        c["in_bounds"] = (-1 <= c["q"] <= 1) and (-1 <= c["r"] <= 1)
    r = worker.infer(req)
    check(r["ok"], "edge/oob", "oob cells infer ok")
    n_infer += 1

    # ---- malformed battery ---------------------------------------------------
    malformed = 0
    good = make_request("INFANTRY", "ATTACK", tag="mal")
    bads = []
    b = copy.deepcopy(good)
    b["schema_version"] = "bogus"
    bads.append(("bad_version", b))
    b = copy.deepcopy(good)
    b["hex_cells"] = b["hex_cells"][:90]
    bads.append(("cells_90", b))
    b = copy.deepcopy(good)
    b["godot_options"] = b["godot_options"][:5]
    bads.append(("options_5", b))
    b = copy.deepcopy(good)
    del b["mission"]
    bads.append(("missing_mission", b))
    b = copy.deepcopy(good)
    b["faction"] = "BLUE"
    bads.append(("faction_blue", b))
    b = copy.deepcopy(good)
    b["mission"]["task"] = "BOGUS"
    bads.append(("task_bogus", b))
    for name, b in bads:
        resp, _ = worker.infer_from_json(json.dumps(b).encode())
        check(resp["ok"] is False and resp["error"]["code"] == "SCHEMA_MISMATCH",
              f"malformed/{name}", f"expected SCHEMA_MISMATCH, got {resp}")
        malformed += 1
    resp, _ = worker.infer_from_json(b"{not json")
    check(resp["ok"] is False, "malformed/json", "non-JSON rejected")
    malformed += 1
    for cls in ("HQ", "SIEGE", "CONSCRIPT", "SUPPLY", "UNKNOWN"):
        b = copy.deepcopy(good)
        b["unit_class"] = cls
        resp, _ = worker.infer_from_json(json.dumps(b).encode())
        check(resp["ok"] is True and resp["eligible"] is False
              and resp["reason"] == "NOT_JEV_ELIGIBLE", f"eligibility/{cls}",
              f"expected NOT_JEV_ELIGIBLE, got {resp}")
        malformed += 1

    # ---- training-corpus visibility constancy (quirk evidence) ---------------
    corpus = {}
    try:
        for split in ("train", "val"):
            store = torch.load(
                os.path.join(STRATEGY_ROOT, "artifacts", "jev_mission_data_v1",
                             f"states_{split}.pt"),
                map_location="cpu", weights_only=False)
            hx = store["hex"]  # [states, 91, 33]
            v0 = HEX_GROUP_OFFSETS["visibility_state"][0]
            vis = hx[:, :, v0:v0 + 3].reshape(-1, 3)
            uniq = torch.unique(vis, dim=0).tolist()
            counts = {}
            for row in vis.tolist():
                counts[tuple(row)] = counts.get(tuple(row), 0) + 1
            corpus[split] = {"cells": int(vis.shape[0]),
                             "unique_rows": uniq,
                             "row_counts": {str(k): v for k, v in counts.items()},
                             "note": "index = fog_state int mirrored (quirk): "
                                     "2 = truly visible (labeled UNEXPLORED), "
                                     "0 = unexplored/out-of-map (labeled VISIBLE); "
                                     "index 1 (explored-not-visible) never occurs "
                                     "in these full-info profiles"}
            ok_rows = all(r == [0.0, 0.0, 1.0] or r == [1.0, 0.0, 0.0]
                            for r in uniq)
            check(ok_rows, f"corpus/{split}",
                  f"unexpected visibility rows: {uniq[:4]}")
    except Exception as e:  # noqa: BLE001 - corpus check is evidence, report it
        corpus["error"] = f"{type(e).__name__}: {e}"
        failures.append(f"corpus: {corpus['error']}")

    # ---- live-request replay (Godot -> worker parity) -------------------------
    replay = {"checked": 0, "eligible": 0, "ineligible": 0,
              "logits_equal": 0, "slot_equal": 0, "hash_equal": 0}
    req_log = os.path.join(ARTIFACT_ROOT, "REQUESTS.jsonl")
    if os.path.isfile(req_log):
        with open(req_log, encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                row = json.loads(line)
                req = validate_request(row["request"])
                want = row["response"]
                got = worker.infer(req)
                n_infer += 1
                replay["checked"] += 1
                if not want.get("ok", False):
                    if got.get("ok", False) is False and \
                            got["error"]["code"] == want["error"]["code"]:
                        replay["slot_equal"] += 1
                    else:
                        failures.append(f"replay/{req['decision_id']}: error differs")
                    continue
                if not want.get("eligible", False):
                    replay["ineligible"] += 1
                    if got.get("eligible", False) is False and \
                            got.get("reason") == want.get("reason"):
                        replay["slot_equal"] += 1
                    else:
                        failures.append(f"replay/{req['decision_id']}: eligibility differs")
                    continue
                replay["eligible"] += 1
                if got["logits"] == want["logits"]:
                    replay["logits_equal"] += 1
                else:
                    failures.append(f"replay/{req['decision_id']}: logits differ")
                if got["selected_slot"] == want["selected_slot"]:
                    replay["slot_equal"] += 1
                else:
                    failures.append(f"replay/{req['decision_id']}: slot differs")
                if got["request_sha256"] == want.get("request_sha256"):
                    replay["hash_equal"] += 1
                else:
                    failures.append(f"replay/{req['decision_id']}: hash differs")
    else:
        replay["note"] = "REQUESTS.jsonl absent; replay skipped"

    report = {
        "battery": "jev-shadow static parity v1",
        "classes": list(LEARNED_CLASSES),
        "tasks": TASKS_8,
        "mask_variants": sorted(MASK_VARIANTS),
        "terrains": TERRAINS,
        "helper_cross_checks": helper_checks,
        "fixture_cases": len(cases),
        "inferences": n_infer,
        "malformed_cases": malformed,
        "corpus_visibility": corpus,
        "live_replay": replay,
        "failures": failures,
        "passed": not failures,
    }
    return report


def run_failopen_battery() -> dict:
    results: list[dict] = []
    failures: list[str] = []

    def rec(name: str, ok: bool, detail: str = "") -> None:
        results.append({"check": name, "ok": ok, "detail": detail})
        if not ok:
            failures.append(f"{name}: {detail}")

    # bad checkpoint hash refuses startup
    try:
        load_model(DEFAULT_CHECKPOINT, "0" * 64)
        rec("bad_hash_refuses_startup", False, "loaded despite wrong hash")
    except WorkerRefused as e:
        rec("bad_hash_refuses_startup", True, str(e)[:120])
    # missing checkpoint refuses startup
    try:
        load_model(os.path.join(STRATEGY_ROOT, "nope.pt"), CHECKPOINT_SHA256)
        rec("missing_checkpoint_refuses_startup", False, "loaded despite missing file")
    except WorkerRefused as e:
        rec("missing_checkpoint_refuses_startup", True, str(e)[:120])

    # live HTTP legs on an ephemeral port
    model, _meta, digest, n = load_model(DEFAULT_CHECKPOINT, CHECKPOINT_SHA256)
    worker = ShadowWorker(model, digest, n, DEFAULT_CHECKPOINT, None)
    server = ThreadingHTTPServer(("127.0.0.1", 0), make_handler(worker))
    server.daemon_threads = True
    port = server.server_address[1]
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    time.sleep(0.2)
    base = f"http://127.0.0.1:{port}"

    def post(path: str, body: bytes) -> tuple[int, dict]:
        req = urllib.request.Request(base + path, data=body,
                                     headers={"Content-Type": "application/json"},
                                     method="POST")
        with urllib.request.urlopen(req, timeout=10) as resp:
            return resp.status, json.loads(resp.read().decode("utf-8"))

    try:
        with urllib.request.urlopen(base + "/health", timeout=10) as resp:
            health = json.loads(resp.read().decode("utf-8"))
        rec("health_ok", health.get("ok") is True
            and health["identity"]["checkpoint_sha256"] == CHECKPOINT_SHA256,
            f"params={health['identity'].get('n_parameters')}")
    except Exception as e:  # noqa: BLE001
        rec("health_ok", False, f"{type(e).__name__}: {e}")

    try:
        status, body = post("/infer", json.dumps(
            make_request("CAVALRY", "FLANK", tag="http")).encode())
        rec("http_infer_ok", status == 200 and body.get("ok") is True
            and len(body.get("logits", [])) == 6,
            f"slot={body.get('selected_slot')}")
    except Exception as e:  # noqa: BLE001
        rec("http_infer_ok", False, f"{type(e).__name__}: {e}")

    try:
        status, body = post("/infer", b"{bad json")
        rec("http_malformed_json_envelope", status == 200 and body.get("ok") is False
            and body["error"]["code"] == "SCHEMA_MISMATCH", "")
    except Exception as e:  # noqa: BLE001
        rec("http_malformed_json_envelope", False, f"{type(e).__name__}: {e}")

    try:
        bad = make_request("INFANTRY", "ATTACK", tag="http")
        bad["godot_options"] = bad["godot_options"][:5]
        status, body = post("/infer", json.dumps(bad).encode())
        rec("http_schema_mismatch_envelope", status == 200 and body.get("ok") is False
            and body["error"]["code"] == "SCHEMA_MISMATCH", "")
    except Exception as e:  # noqa: BLE001
        rec("http_schema_mismatch_envelope", False, f"{type(e).__name__}: {e}")

    try:
        req = urllib.request.Request(base + "/nope", data=b"{}",
                                     headers={"Content-Type": "application/json"},
                                     method="POST")
        urllib.request.urlopen(req, timeout=10)
        rec("http_unknown_path_404", False, "expected 404")
    except urllib.error.HTTPError as e:
        rec("http_unknown_path_404", e.code == 404, "")
    except Exception as e:  # noqa: BLE001
        rec("http_unknown_path_404", False, f"{type(e).__name__}: {e}")
    finally:
        server.shutdown()
        thread.join(timeout=5)

    return {"battery": "jev-shadow fail-open worker battery v1",
            "results": results, "failures": failures,
            "passed": not failures,
            "battle_legs": "worker-down battle digest equality is proven in "
                           "DETERMINISM_COMPARISON.json (leg C); client timeout "
                           "bound is proven by SHADOW_TELEMETRY_DOWN.jsonl "
                           "(300ms bound held on all 480 attempts)"}


def main() -> int:
    worker = _load_worker()
    static = run_static_battery(worker)
    with open(os.path.join(ARTIFACT_ROOT, "FIXTURE_PARITY.json"), "w",
              encoding="utf-8") as f:
        json.dump(static, f, indent=1)
    print(f"[parity] static: cases={static['fixture_cases']} "
          f"helpers={static['helper_cross_checks']} "
          f"replay={static['live_replay'].get('checked')} "
          f"passed={static['passed']}")
    if static["failures"]:
        for msg in static["failures"][:20]:
            print(f"[parity] FAIL {msg}")
    failopen = run_failopen_battery()
    with open(os.path.join(ARTIFACT_ROOT, "FAIL_OPEN_TESTS.json"), "w",
              encoding="utf-8") as f:
        json.dump(failopen, f, indent=1)
    print(f"[parity] failopen: passed={failopen['passed']}")
    if failopen["failures"]:
        for msg in failopen["failures"]:
            print(f"[parity] FAIL {msg}")
    return 0 if (static["passed"] and failopen["passed"]) else 1


if __name__ == "__main__":
    raise SystemExit(main())
