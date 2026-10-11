"""Loopback OpenAI-compatible stub for the Brain-vs-Utility scene smoke.

The connection probe succeeds. Every actual plan deliberately returns invalid
JSON, so the real Cloud2 parser, error log, autonomous HOLD and RED handoff run.
No model is invoked by this test helper.
"""

import json
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


def valid_initial():
    north = ["B_CAV_1", "B_CAV_2", "B_SCT_1", "B_INF_1"]
    center = ["B_HQ_1", "B_INF_2", "B_ARC_1", "B_SPE_1"]
    south = ["B_ARC_2", "B_SPE_2"]
    missions = [
        {"task": "ADVANCE", "area": "NORTH", "units": north, "vs": "INFANTRY"},
        {"task": "HOLD", "area": "CENTER", "units": center, "vs": "CAVALRY"},
        {"task": "ADVANCE", "area": "SOUTH", "units": south, "vs": "INFANTRY"},
    ]
    phases = [
        {"id": "P1", "name": "Approach", "purpose": "Establish contact.",
         "intent": "Advance on both flanks while holding the center.",
         "groups": {"North": north, "Center": center, "South": south},
         "missions": missions,
         "win": [{"when": "TURNS_ELAPSED", "turns": 3, "since": 1}],
         "lose": [{"when": "FORCE_STRENGTH_BELOW", "fraction": 0.4}],
         "abort": ["HQ_THREATENED"], "next": "P2", "on_fail": "HOLD",
         "reserve": [], "release": [], "exploit": "Pressure visible weak points."},
        {"id": "P2", "name": "Attack", "purpose": "Destroy the RED HQ.",
         "intent": "Attack with supported formations.",
         "groups": {"North": north, "Center": center, "South": south},
         "missions": missions,
         "win": [{"when": "TURNS_ELAPSED", "turns": 6, "since": 1}],
         "next": "END"},
    ]
    return {"objective": "Destroy the RED HQ.", "end_state": "RED HQ destroyed.",
            "cadence": 4, "doctrine": [0.6, 0.5, 0.6, 0.6, 0.7, 0.2],
            "phases": phases}


class Handler(BaseHTTPRequestHandler):
    def do_POST(self):
        length = int(self.headers.get("Content-Length", "0"))
        request = json.loads(self.rfile.read(length) or b"{}")
        probe = int(request.get("max_tokens", 0)) <= 32
        valid = len(sys.argv) > 2 and sys.argv[2] == "valid"
        content = "OK" if probe else (json.dumps(valid_initial()) if valid else "{")
        response = {
            "model": request.get("model", "utility-brain-stub"),
            "choices": [{"index": 0, "finish_reason": "stop",
                         "message": {"role": "assistant", "content": content}}],
        }
        encoded = json.dumps(response).encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(encoded)))
        self.end_headers()
        self.wfile.write(encoded)
        print("PROBE" if probe else ("VALID_INITIAL" if valid else "INVALID_INITIAL_OR_REVIEW"), flush=True)

    def log_message(self, _format, *_args):
        pass


if __name__ == "__main__":
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 11435
    ThreadingHTTPServer(("127.0.0.1", port), Handler).serve_forever()
