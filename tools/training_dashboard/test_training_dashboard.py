#!/usr/bin/env python3
"""
Automated Verification Suite for Training Dashboard V1.
Covers TEST A through TEST G as required by Cold Prompt specification.
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
import time
import urllib.error
import urllib.request

PORT = 8124
BASE_URL = f"http://127.0.0.1:{PORT}"
SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
SERVER_SCRIPT = os.path.join(SCRIPT_DIR, "training_dashboard_server.py")
HTML_FILE = os.path.join(SCRIPT_DIR, "training_dashboard.html")
STRATEGY_DIR = os.path.abspath(os.path.join(SCRIPT_DIR, "..", ".."))
STATUS_JSON_PATH = os.path.join(STRATEGY_DIR, "artifacts", "training_runs", "current_run", "status.json")

CANARY_SECRET = "sk-CANARY-SECRET-998877665544332211-DO-NOT-PERSIST"


def make_request(path: str, data: dict = None, method: str = "GET") -> tuple[int, dict | str]:
    url = f"{BASE_URL}{path}"
    headers = {"Content-Type": "application/json"} if data else {}
    body = json.dumps(data).encode("utf-8") if data else None

    req = urllib.request.Request(url, data=body, headers=headers, method=method)
    try:
        with urllib.request.urlopen(req, timeout=5) as resp:
            content_type = resp.headers.get("Content-Type", "")
            raw = resp.read().decode("utf-8")
            if "application/json" in content_type:
                return resp.status, json.loads(raw)
            return resp.status, raw
    except urllib.error.HTTPError as e:
        raw = e.read().decode("utf-8")
        try:
            return e.code, json.loads(raw)
        except Exception:
            return e.code, raw
    except Exception as e:
        return 0, str(e)


def run_all_tests() -> dict:
    results = {
        "gate": "TRAINING_DASHBOARD_V1",
        "timestamp": time.strftime("%Y-%m-%dT%H:%M:%S"),
        "tests": {},
        "verdict": "FAIL"
    }

    print("=" * 60)
    print("STARTING TRAINING DASHBOARD V1 VERIFICATION")
    print("=" * 60)

    # 1. Start Server Process
    print("\n[SETUP] Starting supervisor server...")
    server_proc = subprocess.Popen(
        [sys.executable, SERVER_SCRIPT, "--port", str(PORT)],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        cwd=SCRIPT_DIR,
        text=True
    )

    # Wait for server to become responsive
    server_ready = False
    for i in range(15):
        time.sleep(0.5)
        status_code, resp = make_request("/api/status")
        if status_code == 200 and isinstance(resp, dict):
            server_ready = True
            print(f"[SETUP] Server ready at {BASE_URL} (attempt {i+1})")
            break

    if not server_ready:
        print("[SETUP] FAILED to start server!")
        server_proc.kill()
        results["tests"]["setup"] = {"status": "FAIL", "error": "Server failed to start"}
        return results

    try:
        # TEST A — SERVER
        print("\n--- TEST A: SERVER ---")
        status_code, html_resp = make_request("/")
        test_a_pass = (
            status_code == 200 and
            isinstance(html_resp, str) and
            "Strategy AI Training" in html_resp and
            "http://127.0.0.1:8124/" in html_resp
        )
        results["tests"]["TEST_A_SERVER"] = {
            "status": "PASS" if test_a_pass else "FAIL",
            "status_code": status_code,
            "contains_title": "Strategy AI Training" in html_resp
        }
        print(f"TEST A Result: {results['tests']['TEST_A_SERVER']['status']}")

        # TEST B — UI FIELDS
        print("\n--- TEST B: UI FIELDS ---")
        required_elements = [
            'id="provider"',
            'id="model"',
            'id="apiKey"',
            'type="password"',
            'id="durationHours"',
            'id="apiRefPct"',
            'id="btnStart"',
            'id="btnPause"',
            'id="btnResume"',
            'id="btnStop"',
            'id="matchesCompleted"',
            'id="elapsedTime"',
            'id="remainingTime"',
            'id="targetTime"',
            'PIPELINE NOT WIRED'
        ]
        missing_elements = [el for el in required_elements if el not in html_resp]
        test_b_pass = len(missing_elements) == 0
        results["tests"]["TEST_B_UI"] = {
            "status": "PASS" if test_b_pass else "FAIL",
            "checked_elements": len(required_elements),
            "missing_elements": missing_elements
        }
        print(f"TEST B Result: {results['tests']['TEST_B_UI']['status']} (missing: {missing_elements})")

        # TEST G — REAL BACKEND DISCOVERY (Checked before starting simulation)
        print("\n--- TEST G: REAL BACKEND DISCOVERY ---")
        status_code, real_start_resp = make_request("/api/start", {
            "provider": "opencode",
            "model": "deepseek-v4.1-flash",
            "api_key": "some-key",
            "duration_hours": 72,
            "api_reference_percent": 5,
            "simulation_mode": False
        }, method="POST")

        status_code_status, status_data = make_request("/api/status")
        backend_not_wired_visible = (
            "PIPELINE NOT WIRED" in html_resp and
            status_data.get("backend_wired") is False and
            status_data.get("backend_status") == "PIPELINE NOT WIRED"
        )
        real_start_rejected = (
            real_start_resp.get("ok") is False and
            "PIPELINE NOT WIRED" in real_start_resp.get("error", "")
        )

        test_g_pass = backend_not_wired_visible and real_start_rejected
        results["tests"]["TEST_G_REAL_BACKEND_DISCOVERY"] = {
            "status": "PASS" if test_g_pass else "FAIL",
            "backend_wired": status_data.get("backend_wired"),
            "backend_status": status_data.get("backend_status"),
            "real_start_rejected": real_start_rejected,
            "rejection_message": real_start_resp.get("error", "")
        }
        print(f"TEST G Result: {results['tests']['TEST_G_REAL_BACKEND_DISCOVERY']['status']}")
        print(f"  Backend wired: {status_data.get('backend_wired')}")
        print(f"  UI status text: {status_data.get('backend_status')}")
        print(f"  Rejection message: {real_start_resp.get('error')}")

        # TEST C — SECRET HYGIENE
        print("\n--- TEST C: SECRET HYGIENE ---")
        # Start a simulation run with CANARY_SECRET
        status_code, sim_start_resp = make_request("/api/start", {
            "provider": "opencode",
            "model": "deepseek-v4.1-flash",
            "api_key": CANARY_SECRET,
            "duration_hours": 0.01, # ~36 seconds
            "api_reference_percent": 10,
            "simulation_mode": True
        }, method="POST")

        # Check status JSON
        _, current_status = make_request("/api/status")
        status_json_str = json.dumps(current_status)

        # Check status.json on disk
        status_file_str = ""
        if os.path.exists(STATUS_JSON_PATH):
            with open(STATUS_JSON_PATH, "r", encoding="utf-8") as f:
                status_file_str = f.read()

        secret_in_status_api = CANARY_SECRET in status_json_str
        secret_in_disk_file = CANARY_SECRET in status_file_str
        secret_in_html = CANARY_SECRET in html_resp
        has_api_key_flag = current_status.get("config", {}).get("has_api_key") is True

        test_c_pass = (
            not secret_in_status_api and
            not secret_in_disk_file and
            not secret_in_html and
            has_api_key_flag
        )
        results["tests"]["TEST_C_SECRET"] = {
            "status": "PASS" if test_c_pass else "FAIL",
            "secret_leaked_in_api": secret_in_status_api,
            "secret_leaked_in_disk": secret_in_disk_file,
            "secret_leaked_in_html": secret_in_html,
            "has_api_key_boolean_set": has_api_key_flag
        }
        print(f"TEST C Result: {results['tests']['TEST_C_SECRET']['status']}")
        print(f"  Leaked in API: {secret_in_status_api}")
        print(f"  Leaked on disk: {secret_in_disk_file}")
        print(f"  Leaked in HTML: {secret_in_html}")
        print(f"  has_api_key flag: {has_api_key_flag}")

        # TEST D — TIMER
        print("\n--- TEST D: TIMER ---")
        time.sleep(2.0)
        _, t1_status = make_request("/api/status")
        time.sleep(2.0)
        _, t2_status = make_request("/api/status")

        elapsed_increments = t2_status["elapsed_seconds"] > t1_status["elapsed_seconds"]
        remaining_decrements = t2_status["remaining_seconds"] < t1_status["remaining_seconds"]
        target_consistent = abs(t2_status["target_seconds"] - (0.01 * 3600.0)) < 1.0

        test_d_pass = elapsed_increments and remaining_decrements and target_consistent
        results["tests"]["TEST_D_TIMER"] = {
            "status": "PASS" if test_d_pass else "FAIL",
            "elapsed_t1": t1_status["elapsed_seconds"],
            "elapsed_t2": t2_status["elapsed_seconds"],
            "remaining_t1": t1_status["remaining_seconds"],
            "remaining_t2": t2_status["remaining_seconds"],
            "target_seconds": t2_status["target_seconds"]
        }
        print(f"TEST D Result: {results['tests']['TEST_D_TIMER']['status']}")
        print(f"  Elapsed: {t1_status['elapsed_seconds']}s -> {t2_status['elapsed_seconds']}s")
        print(f"  Remaining: {t1_status['remaining_seconds']}s -> {t2_status['remaining_seconds']}s")

        # TEST E — MATCH COUNTER
        print("\n--- TEST E: MATCH COUNTER ---")
        print("  Waiting for simulated matches to complete...")
        initial_matches = t2_status.get("matches_completed", 0)
        matches_observed = initial_matches

        for _ in range(8):
            time.sleep(1.0)
            _, poll_status = make_request("/api/status")
            matches_observed = poll_status.get("matches_completed", 0)
            if matches_observed > initial_matches:
                break

        # Simulate browser refresh by fetching fresh status
        _, refreshed_status = make_request("/api/status")
        count_preserved = refreshed_status.get("matches_completed", 0) == matches_observed

        test_e_pass = (matches_observed >= 1) and count_preserved
        results["tests"]["TEST_E_MATCH_COUNTER"] = {
            "status": "PASS" if test_e_pass else "FAIL",
            "initial_matches": initial_matches,
            "matches_after_run": matches_observed,
            "matches_after_refresh": refreshed_status.get("matches_completed", 0),
            "wins": refreshed_status.get("wins"),
            "losses": refreshed_status.get("losses"),
            "draws": refreshed_status.get("draws"),
            "current_match": refreshed_status.get("current_match"),
            "current_mode": refreshed_status.get("current_mode"),
            "current_phase": refreshed_status.get("current_phase"),
            "brain_checkpoint": refreshed_status.get("brain_checkpoint"),
            "hands_checkpoint": refreshed_status.get("hands_checkpoint")
        }
        print(f"TEST E Result: {results['tests']['TEST_E_MATCH_COUNTER']['status']}")
        print(f"  Matches completed: {matches_observed}")
        print(f"  W/L/D: {refreshed_status.get('wins')}/{refreshed_status.get('losses')}/{refreshed_status.get('draws')}")
        print(f"  Checkpoints: Brain={refreshed_status.get('brain_checkpoint')}, Hands={refreshed_status.get('hands_checkpoint')}")

        # TEST F — CONTROL BUTTON SEMANTICS
        print("\n--- TEST F: CONTROL BUTTON SEMANTICS ---")
        # 1. State is currently RUNNING
        _, cur_st = make_request("/api/status")
        state_running = cur_st.get("state") == "RUNNING"

        # 2. Pause
        _, pause_res = make_request("/api/pause", method="POST")
        _, post_pause_st = make_request("/api/status")
        state_paused = post_pause_st.get("state") == "PAUSED"

        # Check that elapsed timer does not run away while paused
        p_elapsed1 = post_pause_st.get("elapsed_seconds", 0)
        time.sleep(1.0)
        _, post_pause_st2 = make_request("/api/status")
        p_elapsed2 = post_pause_st2.get("elapsed_seconds", 0)
        timer_paused = abs(p_elapsed2 - p_elapsed1) < 0.2

        # 3. Resume
        _, resume_res = make_request("/api/resume", method="POST")
        _, post_resume_st = make_request("/api/status")
        state_resumed = post_resume_st.get("state") == "RUNNING"

        # 4. Stop
        _, stop_res = make_request("/api/stop", method="POST")
        _, post_stop_st = make_request("/api/status")
        state_stopped = post_stop_st.get("state") == "STOPPED"

        test_f_pass = state_running and state_paused and timer_paused and state_resumed and state_stopped
        results["tests"]["TEST_F_CONTROL"] = {
            "status": "PASS" if test_f_pass else "FAIL",
            "running_verified": state_running,
            "paused_verified": state_paused,
            "timer_paused_verified": timer_paused,
            "resumed_verified": state_resumed,
            "stopped_verified": state_stopped
        }
        print(f"TEST F Result: {results['tests']['TEST_F_CONTROL']['status']}")
        print(f"  RUNNING -> {state_running}")
        print(f"  PAUSED -> {state_paused} (timer paused: {timer_paused})")
        print(f"  RESUMED -> {state_resumed}")
        print(f"  STOPPED -> {state_stopped}")

        # TEST H — PAUSED RE-START REJECTION
        print("\n--- TEST H: PAUSED RE-START REJECTION ---")
        make_request("/api/stop", method="POST")
        time.sleep(0.3)
        make_request("/api/start", {
            "provider": "opencode",
            "model": "deepseek-v4.1-flash",
            "api_key": "dummy-key",
            "duration_hours": 1.0,
            "api_reference_percent": 5,
            "simulation_mode": True
        }, method="POST")
        time.sleep(0.3)
        make_request("/api/pause", method="POST")
        time.sleep(0.2)
        paused_start_code, paused_start_res = make_request("/api/start", {
            "provider": "opencode",
            "model": "deepseek-v4.1-flash",
            "api_key": "dummy-key",
            "duration_hours": 1.0,
            "api_reference_percent": 5,
            "simulation_mode": True
        }, method="POST")
        make_request("/api/stop", method="POST")
        test_h_pass = paused_start_code == 400 and isinstance(paused_start_res, dict) and paused_start_res.get("ok") is False
        results["tests"]["TEST_H_PAUSED_RESTART_REJECTED"] = {
            "status": "PASS" if test_h_pass else "FAIL",
            "status_code": paused_start_code,
            "error_msg": paused_start_res.get("error") if isinstance(paused_start_res, dict) else str(paused_start_res)
        }
        print(f"TEST H Result: {results['tests']['TEST_H_PAUSED_RESTART_REJECTED']['status']}")

        # TEST I — API KEY VALIDATION
        print("\n--- TEST I: API KEY VALIDATION ---")
        make_request("/api/reset", method="POST")
        time.sleep(0.2)
        code_no_key, res_no_key = make_request("/api/start", {
            "provider": "opencode",
            "model": "deepseek-v4.1-flash",
            "api_key": "",
            "duration_hours": 1.0,
            "api_reference_percent": 5,
            "simulation_mode": True
        }, method="POST")
        ref_gt_zero_rejected = code_no_key == 400 and isinstance(res_no_key, dict) and "API Key is required" in res_no_key.get("error", "")

        code_zero_ref, res_zero_ref = make_request("/api/start", {
            "provider": "opencode",
            "model": "deepseek-v4.1-flash",
            "api_key": "",
            "duration_hours": 1.0,
            "api_reference_percent": 0,
            "simulation_mode": True
        }, method="POST")
        ref_zero_accepted = code_zero_ref == 200 and isinstance(res_zero_ref, dict) and res_zero_ref.get("ok") is True
        make_request("/api/stop", method="POST")
        time.sleep(0.2)

        test_i_pass = ref_gt_zero_rejected and ref_zero_accepted
        results["tests"]["TEST_I_API_KEY_VALIDATION"] = {
            "status": "PASS" if test_i_pass else "FAIL",
            "ref_gt_zero_rejected": ref_gt_zero_rejected,
            "ref_zero_accepted": ref_zero_accepted
        }
        print(f"TEST I Result: {results['tests']['TEST_I_API_KEY_VALIDATION']['status']}")

        # TEST J — BACKGROUND DURATION AUTO-STOP WITHOUT POLLING
        print("\n--- TEST J: BACKGROUND DURATION AUTO-STOP WITHOUT POLLING ---")
        make_request("/api/start", {
            "provider": "opencode",
            "model": "deepseek-v4.1-flash",
            "api_key": "test-key",
            "duration_hours": 0.0003,  # ~1.08 seconds
            "api_reference_percent": 0,
            "simulation_mode": True
        }, method="POST")
        # Sleep for 3.2 seconds WITHOUT calling /api/status so 1 match (~1.9s) completes and stops
        time.sleep(3.2)
        _, final_status = make_request("/api/status")
        stopped_automatically = final_status.get("state") == "STOPPED"
        elapsed_advanced = final_status.get("elapsed_seconds", 0) >= 1.0
        test_j_pass = stopped_automatically and elapsed_advanced
        results["tests"]["TEST_J_AUTO_STOP_WITHOUT_POLLING"] = {
            "status": "PASS" if test_j_pass else "FAIL",
            "stopped_automatically": stopped_automatically,
            "final_state": final_status.get("state"),
            "elapsed_seconds": final_status.get("elapsed_seconds")
        }
        print(f"TEST J Result: {results['tests']['TEST_J_AUTO_STOP_WITHOUT_POLLING']['status']}")
        print(f"  Stopped automatically: {stopped_automatically} (state: {final_status.get('state')})")
        print(f"  Elapsed: {final_status.get('elapsed_seconds')}s")

        # TEST CRASH / RESTART INTERRUPTED RECOVERY
        print("\n--- TEST EXTRA: CRASH / RESTART INTERRUPTED RECOVERY ---")
        make_request("/api/start", {
            "provider": "opencode",
            "model": "deepseek-v4.1-flash",
            "api_key": "recovery-canary-key",
            "duration_hours": 10.0,
            "api_reference_percent": 5,
            "simulation_mode": True
        }, method="POST")
        time.sleep(0.5)

        # Kill server to simulate crash
        server_proc.kill()
        server_proc.wait()

        # Restart server
        restart_proc = subprocess.Popen(
            [sys.executable, SERVER_SCRIPT, "--port", str(PORT)],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            cwd=SCRIPT_DIR,
            text=True
        )
        time.sleep(1.5)

        _, restart_status = make_request("/api/status")
        state_interrupted = restart_status.get("state") == "INTERRUPTED"
        key_cleared = restart_status.get("config", {}).get("has_api_key") is False

        results["tests"]["TEST_CRASH_RECOVERY"] = {
            "status": "PASS" if (state_interrupted and key_cleared) else "FAIL",
            "recovered_state": restart_status.get("state"),
            "api_key_cleared": key_cleared
        }
        print(f"Crash Recovery Result: {results['tests']['TEST_CRASH_RECOVERY']['status']}")
        print(f"  Recovered State: {restart_status.get('state')} (expected INTERRUPTED)")
        print(f"  API Key Cleared: {key_cleared}")

        # TEST K: RESUME INTERRUPTED RUN
        print("\n--- TEST K: RESUME INTERRUPTED RUN ---")
        res_code, resume_res = make_request("/api/resume", {
            "api_key": "resumed-canary-key"
        }, method="POST")
        time.sleep(0.5)
        _, resumed_status = make_request("/api/status")
        resume_success = (
            res_code == 200 and
            resumed_status.get("state") == "RUNNING"
        )
        make_request("/api/stop", method="POST")
        test_k_pass = resume_success
        results["tests"]["TEST_K_RESUME_INTERRUPTED"] = {
            "status": "PASS" if test_k_pass else "FAIL",
            "resumed_state": resumed_status.get("state"),
            "resumed_has_key": resumed_status.get("config", {}).get("has_api_key")
        }
        print(f"TEST K Result: {results['tests']['TEST_K_RESUME_INTERRUPTED']['status']}")

        # TEST L: BRAND NEW RUN INITIALIZES METRICS TO ZERO
        print("\n--- TEST L: NEW RUN INITIALIZES METRICS TO ZERO ---")
        make_request("/api/start", {
            "provider": "opencode",
            "model": "deepseek-v4.1-flash",
            "api_key": "fresh-key",
            "duration_hours": 1.0,
            "api_reference_percent": 0,
            "simulation_mode": True
        }, method="POST")
        time.sleep(0.3)
        _, fresh_status = make_request("/api/status")
        make_request("/api/stop", method="POST")
        new_run_clean = (
            fresh_status.get("matches_completed") == 0 and
            fresh_status.get("wins") == 0 and
            fresh_status.get("losses") == 0 and
            fresh_status.get("elapsed_seconds") < 1.0
        )
        test_l_pass = new_run_clean
        results["tests"]["TEST_L_NEW_RUN_METRICS_ZERO"] = {
            "status": "PASS" if test_l_pass else "FAIL",
            "matches_completed": fresh_status.get("matches_completed"),
            "elapsed_seconds": fresh_status.get("elapsed_seconds")
        }
        print(f"TEST L Result: {results['tests']['TEST_L_NEW_RUN_METRICS_ZERO']['status']}")

        # Stop restarted server cleanly
        restart_proc.kill()
        restart_proc.wait()

    finally:
        try:
            server_proc.kill()
        except Exception:
            pass

    # Overall Verdict
    all_tests_passed = all(
        t.get("status") == "PASS" for t in results["tests"].values()
    )
    results["verdict"] = "TRAINING_DASHBOARD_V1_PASS_WITH_BACKEND_UNWIRED" if all_tests_passed else "FAIL"

    print("\n" + "=" * 60)
    print(f"OVERALL VERDICT: {results['verdict']}")
    print("=" * 60)
    return results


if __name__ == "__main__":
    test_results = run_all_tests()
    out_dir = os.path.join(STRATEGY_DIR, "artifacts", "training_dashboard_v1")
    os.makedirs(out_dir, exist_ok=True)
    out_json = os.path.join(out_dir, "DASHBOARD_RESULTS.json")
    with open(out_json, "w", encoding="utf-8") as f:
        json.dump(test_results, f, indent=2)
    print(f"\nSaved test results to: {out_json}")
    if test_results["verdict"] != "TRAINING_DASHBOARD_V1_PASS_WITH_BACKEND_UNWIRED":
        sys.exit(1)
    sys.exit(0)
