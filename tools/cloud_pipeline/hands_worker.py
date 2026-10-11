"""CLOUD FULL PIPELINE V0 — frozen Hand A + Hand B inference worker.

One owned localhost process (spawned by Godot through LayaLauncher's
HANDS_AB profile). Loads BOTH frozen Laya checkpoints once, inference only:

  Hand A  artifacts/laya_hand_a_v1/run1/checkpoints/best   (TERSE full-FT best)
  Hand B  artifacts/laya_hand_b_v1/run1/final

  GET  /health    identity handshake (both weight sha256, renderers, eval/no_grad)
  POST /hand_a    per-unit operational order chain for every ready RED unit:
                  mission -> role -> direction -> depth -> engagement (greedy,
                  each conditioned on the previous picks exactly as in training)
  POST /decide    Hand B: ONE candidate from the Godot-enumerated legal set of
                  ONE unit, under that unit's Hand A order
  POST /shutdown  token-authenticated owned shutdown

Rendering is the TRAINING renderers, imported (never copied) and sha-pinned:
Hand A = run1 hand_a_render.py, Hand B = tools/hand_b/common.py. Nothing here
chooses, repairs or substitutes an action: errors are returned, never masked.
"""
from __future__ import annotations

import argparse
import hashlib
import importlib.util
import json
import os
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))


def _load_module(name: str, path: str):
    spec = importlib.util.spec_from_file_location(name, path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


# Shared worker plumbing (option keys, parent watch, log emit, sha256).
W = _load_module("laya_worker", os.path.join(ROOT, "tools", "laya", "worker.py"))

SERVICE = "hands-ab-worker"
PROTOCOL_VERSION = "hands-ab-protocol-v0"
HAND_A_DIR = os.path.join(ROOT, "artifacts", "laya_hand_a_v1", "run1", "checkpoints", "best")
HAND_B_DIR = os.path.join(ROOT, "artifacts", "laya_hand_b_v1", "run1", "final")
HAND_A_SHA = "0bf9324be4220fa845555c32e64dd089d74cb578d5e19913b37b90a1c67fd719"
HAND_B_SHA = "4ef88372aeb55fdbd6f5c471c6a0fafa2d3f5c9cdd37f5ae373b0cf0a2693ca9"
HAND_A_RENDER = os.path.join(ROOT, "artifacts", "laya_hand_a_v1", "run1", "hand_a_render.py")
HAND_A_RENDER_SHA = "89e061556b5c5e1106fb5e0fd9c086d5d1b5da8b379c7ab05fa52c00b6481260"
HAND_B_RENDER = os.path.join(ROOT, "tools", "hand_b", "common.py")
HAND_B_RENDER_SHA = "a47c8c4094d94251d71d21774236628c0684987f2cbf9f17f9692cb31e09baea"
# Training sequence budgets of both checkpoints (train_full_v1.py / train_hand_b.py).
MAX_LEN, HEAD_MAX_LEN = 2048, 1024
HAND_A_DECISIONS = ("mission_assignment", "role", "relative_direction", "depth", "engagement")
DEFAULT_LOG_DIR = os.path.join(ROOT, "artifacts", "cloud_full_pipeline_v0", "runtime_logs")
MAX_BODY_BYTES = 8 << 20


def _sha(path: str) -> str:
    return W._sha256_file(path).lower()


def _check_sha(path: str, want: str, what: str) -> None:
    got = _sha(path)
    if got != want:
        raise W.WorkerRefused("%s sha256 mismatch: got %s want %s" % (what, got[:16], want[:16]))


_check_sha(HAND_A_RENDER, HAND_A_RENDER_SHA, "Hand A renderer")
_check_sha(HAND_B_RENDER, HAND_B_RENDER_SHA, "Hand B renderer")
RA = _load_module("hand_a_render", HAND_A_RENDER)
RB = _load_module("hand_b_common", HAND_B_RENDER)


# ------------------------------------------------------------ compass areas
# The Brain authors compass areas (NORTH/SOUTH/EAST/WEST/CENTER/ANY, Godot's
# Step7 region classifier). Hand A was trained on own-HQ-relative areas. A
# compass area becomes the relative direction in which that region's anchor
# hex lies from own HQ, measured with the TRAINING renderer's own frame and
# _rel (exactly how the renderer places any unit). CENTER / ANY pass through.
def _region_anchor(area: str, bounds: dict):
    q_min, q_max = float(bounds["q_min"]), float(bounds["q_max"])
    qc = (q_min + q_max) / 2.0
    if "min_vertical" in bounds and "max_vertical" in bounds:
        v_min, v_max = float(bounds["min_vertical"]), float(bounds["max_vertical"])
    else:  # Step7 logical vertical = 2r + q
        v_min = 2.0 * float(bounds["r_min"]) + q_min
        v_max = 2.0 * float(bounds["r_max"]) + q_max
    vc = (v_min + v_max) / 2.0
    if area == "NORTH":  # t < 1/3 band; anchor at its middle (t = 1/6)
        v, q = v_min + (v_max - v_min) / 6.0, qc
    elif area == "SOUTH":
        v, q = v_min + 5.0 * (v_max - v_min) / 6.0, qc
    elif area == "WEST":  # norm_q < 1/3
        v, q = vc, q_min + (q_max - q_min) / 6.0
    elif area == "EAST":
        v, q = vc, q_min + 5.0 * (q_max - q_min) / 6.0
    else:
        return None
    return (q, (v - q) / 2.0)  # r from 2r + q = v


def compass_to_relative(area: str, hq, bounds: dict) -> str:
    a = str(area or "ANY").strip().upper()
    if a in ("CENTER", "ANY", "") or a in RA.DIRECTIONS:
        return a or "ANY"
    anchor = _region_anchor(a, bounds)
    if anchor is None:
        return "ANY"
    fr = RA._frame(hq, bounds)
    f, l = RA._rel(hq, anchor, fr)
    if abs(f) >= abs(l):
        return "FORWARD" if f >= 0 else "BACK"
    return "LEFT" if l > 0 else "RIGHT"


def brain_missions_for_hand_a(missions: list, hq, bounds: dict) -> list:
    out = []
    for m in missions:
        tc = str(m.get("target_class", m.get("vs", "")) or "").strip().upper()
        out.append({
            "mission_id": str(m["mission_id"]),
            "task": str(m["task"]).upper(),
            "area": compass_to_relative(str(m.get("area", "ANY")), hq, bounds),
            "brain_area": str(m.get("area", "ANY")).upper(),
            "intent": str(m.get("intent", "")),
            "target_class": tc,
            "priority": str(m.get("priority", "MEDIUM") or "MEDIUM").upper(),
            "preserve": bool(m.get("preserve", False)),
        })
    return out


# ------------------------------------------------------------------ models
def load_hand(path: str, want_sha: str, device: str, what: str):
    import torch
    if not os.path.exists(os.path.join(path, "model.safetensors")):
        raise W.WorkerRefused("%s checkpoint missing: %s" % (what, path))
    _check_sha(os.path.join(path, "model.safetensors"), want_sha, what + " weights")
    if device == "cuda" and not torch.cuda.is_available():
        raise W.WorkerRefused("CUDA requested but unavailable")
    import laya
    ag = laya.load(path, device=device)
    ag.cfg["max_len"], ag.cfg["head_max_len"] = MAX_LEN, HEAD_MAX_LEN
    ag.model.eval()
    for p in ag.model.parameters():
        p.requires_grad_(False)
    return ag


class Hands:
    def __init__(self, device: str, log_dir: str):
        import torch
        t0 = time.perf_counter()
        self.a = load_hand(HAND_A_DIR, HAND_A_SHA, device, "Hand A")
        self.b = load_hand(HAND_B_DIR, HAND_B_SHA, device, "Hand B")
        self.lock = threading.Lock()
        self.started = time.time()
        self.counts = {"hand_a_calls": 0, "hand_a_units": 0, "hand_b_calls": 0, "errors": 0}
        vram = torch.cuda.memory_allocated() / 1e9 if torch.cuda.is_available() else 0.0
        self.load_info = {"load_s": round(time.perf_counter() - t0, 2), "vram_gb": round(vram, 2)}
        os.makedirs(log_dir, exist_ok=True)
        stamp = time.strftime("%Y%m%d_%H%M%S")
        self.log_path = os.path.join(log_dir, "hands_%s_%d.jsonl" % (stamp, os.getpid()))

    def device(self) -> dict:
        return {"hand_a": str(self.a.device), "hand_b": str(self.b.device)}

    def identity(self) -> dict:
        return {
            "service": SERVICE, "protocol_version": PROTOCOL_VERSION,
            "hand_a_dir": HAND_A_DIR, "hand_a_sha256": HAND_A_SHA,
            "hand_b_dir": HAND_B_DIR, "hand_b_sha256": HAND_B_SHA,
            "hand_a_render_sha256": HAND_A_RENDER_SHA, "hand_b_render_sha256": HAND_B_RENDER_SHA,
            "max_len": int(self.a.cfg["max_len"]), "head_max_len": int(self.a.cfg["head_max_len"]),
            "device": self.device(),
            "eval": bool(not self.a.model.training and not self.b.model.training),
            "no_grad": bool(all(not p.requires_grad for p in self.a.model.parameters())
                            and all(not p.requires_grad for p in self.b.model.parameters())),
        }

    def log(self, kind: str, req: dict, resp: dict, provenance: dict = None) -> None:
        try:
            with open(self.log_path, "a", encoding="utf-8") as f:
                f.write(json.dumps({"t": time.time(), "kind": kind, "req": req, "resp": resp, **(provenance or {})}, ensure_ascii=False) + "\n")
        except OSError:
            pass

    # -------------------------------------------------------------- Hand A
    def hand_a(self, req: dict) -> dict:
        t0 = time.perf_counter()
        side = str(req["side"])
        bounds = req["bounds"]
        obs = req["observation"]
        own = obs.get("own_forces", []) or []
        hq = next((u for u in own if str(u.get("class", "")).lower() == "hq"), None)
        hq_pos = RA._pos(hq) if hq is not None else (0, 0)
        missions = brain_missions_for_hand_a(req["missions"], hq_pos, bounds)
        si = {"side": side, "turn": int(req.get("turn", 1)), "bounds": bounds,
              "observation": obs, "brain_missions": missions}
        units = []
        for uid in req["unit_ids"]:
            partial, probs = {}, {}
            for dec in HAND_A_DECISIONS:
                opts = RA.render_options(dec, si)
                vals = RA.option_values(dec, si)
                keys = W.option_keys(len(opts))
                st = RA.render_state(si, str(uid), partial)
                with self.lock:
                    res = self.a.predict(st, {dec: {"type": "choice", "instructions": RA.INSTRUCTIONS[dec],
                                                    "criteria": dict(zip(keys, opts))}})
                ans = res["answers"][dec]
                k2v = dict(zip(keys, vals))
                partial[dec] = k2v[ans["choice"]]
                probs[dec] = {k2v[k]: p for k, p in ans["probabilities"].items()}
            units.append({"unit_id": str(uid), **{d: partial[d] for d in HAND_A_DECISIONS}, "probs": probs})
        with self.lock:
            self.counts["hand_a_calls"] += 1
            self.counts["hand_a_units"] += len(units)
        return {"ok": True, "service": SERVICE, "units": units, "brain_missions": missions,
                "device": self.device(), "latency_ms": round((time.perf_counter() - t0) * 1000, 1)}

    # -------------------------------------------------------------- Hand B
    def hand_b(self, req: dict) -> dict:
        t0 = time.perf_counter()
        order_in = req.get("hand_a_order") or {}
        task = str(order_in.get("task", "")).upper()
        rdir = str(order_in.get("relative_direction", "")).upper()
        if task not in RB.TASKS or rdir not in RB.DIRS:
            return {"ok": False, "error": {"code": "HAND_B_BAD_ORDER", "detail": "task=%s dir=%s" % (task, rdir)}}
        # Hand B's trained order contract: canned per-task intent; EXECUTE is
        # the only task whose behaviour comes from free intent (the Brain's).
        intent = str(order_in.get("brain_intent", "")) if task == "EXECUTE" else RB.TASK_INTENTS[task]
        order = {"task": task, "relative_direction": rdir, "intent": intent}
        az = req["authorized_state"]
        u = dict(az["unit"])
        u.setdefault("id", req["unit_id"])
        state = {"side": req["side"], "bounds": req["bounds"], "ledger": az["knowledge"]["ledger"],
                 "turn": req.get("turn", 1)}
        ctx = RB.build_ctx(state, u)
        cands = req["candidates"]
        if len(cands) < 2:
            return {"ok": False, "error": {"code": "HAND_B_POOL_TOO_SMALL", "detail": str(len(cands))}}
        opts = RB.render_options(u, cands, ctx)
        keys = W.option_keys(len(opts))
        st = RB.render_state(order, u, ctx, req.get("turn", 1))
        with self.lock:
            res = self.b.predict(st, {"action": {"type": "choice", "instructions": RB.HAND_B_INSTRUCTIONS,
                                                 "criteria": dict(zip(keys, opts))}})
            self.counts["hand_b_calls"] += 1
        ans = res["answers"]["action"]
        k2c = {k: c["candidate_id"] for k, c in zip(keys, cands)}
        sel = k2c[ans["choice"]]
        ranked = sorted(({"candidate_id": k2c[k], "prob": float(p)} for k, p in ans["probabilities"].items()),
                        key=lambda o: -o["prob"])
        return {"ok": True, "schema_version": W.RESPONSE_VERSION, "service": SERVICE,
                "selected_key": ans["choice"], "selected_candidate_id": sel,
                "confidence": ans.get("confidence"), "top5": ranked[:5], "order": order,
                "state_text": st, "options_text": opts, "device": self.device(),
                "token_usage": {"input_tokens": int(res.get("usage", {}).get("input_tokens", 0))},
                "latency_ms": {"total": round((time.perf_counter() - t0) * 1000, 1)}}


def make_handler(h: Hands, token: str, parent_pid, log_file):
    class Handler(BaseHTTPRequestHandler):
        server_version = "HandsABWorker/0"

        def _send(self, obj: dict) -> None:
            blob = json.dumps(obj).encode("utf-8")
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(blob)))
            self.end_headers()
            self.wfile.write(blob)

        def do_GET(self) -> None:  # noqa: N802
            if self.path.split("?")[0] != "/health":
                self.send_response(404)
                self.end_headers()
                return
            self._send({"ok": True, "service": SERVICE, "status": "READY", "protocol_version": PROTOCOL_VERSION,
                        "pid": os.getpid(), "parent_pid": parent_pid, "identity": h.identity(),
                        "load": h.load_info, "uptime_s": time.time() - h.started, "counts": dict(h.counts),
                        "log_path": h.log_path})

        def do_POST(self) -> None:  # noqa: N802
            path = self.path.split("?")[0]
            try:
                length = int(self.headers.get("Content-Length", "0"))
            except ValueError:
                length = 0
            body = self.rfile.read(length) if 0 < length <= MAX_BODY_BYTES else b""
            if path == "/shutdown":
                try:
                    presented = str(json.loads(body.decode("utf-8") or "{}").get("token", ""))
                except (UnicodeDecodeError, json.JSONDecodeError, AttributeError):
                    presented = ""
                if not token or presented != token:
                    self._send({"ok": False, "error": {"code": "FORBIDDEN"}})
                    return
                self._send({"ok": True, "status": "SHUTTING_DOWN", "pid": os.getpid()})
                threading.Thread(target=self.server.shutdown, daemon=True).start()
                return
            if path not in ("/hand_a", "/decide"):
                self.send_response(404)
                self.end_headers()
                return
            kind = "HAND_A" if path == "/hand_a" else "HAND_B"
            req = {}
            try:
                req = json.loads(body.decode("utf-8"))
                resp = h.hand_a(req) if kind == "HAND_A" else h.hand_b(req)
            except Exception as e:  # noqa: BLE001 - surfaced to Godot as an explicit layer error
                with h.lock:
                    h.counts["errors"] += 1
                resp = {"ok": False, "error": {"code": "%s_EXCEPTION" % kind, "detail": "%s: %s" % (type(e).__name__, e)}}
            h.log(kind, req, resp, episode_provenance(self.headers))
            self._send(resp)

        def log_message(self, fmt: str, *args) -> None:
            if log_file:
                try:
                    with open(log_file, "a", encoding="utf-8") as f:
                        f.write("[hands-ab] " + fmt % args + "\n")
                except OSError:
                    pass

    return Handler


def episode_provenance(headers) -> dict:
    """Episode launch record sent by Godot (X-Episode-*); absent without an episode."""
    from urllib.parse import unquote
    eid = headers.get("X-Episode-Id")
    if not eid:
        return {}
    return {"episode_id": eid, "episode_spec_path": unquote(headers.get("X-Episode-Spec-Path", "")) or None}


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description="Frozen Hand A + Hand B worker (CLOUD FULL PIPELINE V0)")
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--port", type=int, default=11443)
    ap.add_argument("--device", default="cuda")
    ap.add_argument("--parent-pid", type=int, default=0)
    ap.add_argument("--shutdown-token", default="")
    ap.add_argument("--log-file", default="")
    ap.add_argument("--log-dir", default=DEFAULT_LOG_DIR)
    a = ap.parse_args(argv)
    log_file = a.log_file.strip() or None
    try:
        h = Hands(a.device, a.log_dir)
    except W.WorkerRefused as e:
        W._emit("[hands-ab] REFUSED: %s" % e, log_file)
        return 2
    srv = ThreadingHTTPServer((a.host, a.port), make_handler(h, a.shutdown_token.strip(), a.parent_pid or None, log_file))
    srv.daemon_threads = True
    W._emit("[hands-ab] READY hand_a=%s hand_b=%s device=%s load_s=%s vram_gb=%s port=%d pid=%d log=%s" % (
        HAND_A_SHA[:16], HAND_B_SHA[:16], h.device(), h.load_info["load_s"], h.load_info["vram_gb"],
        srv.server_address[1], os.getpid(), h.log_path), log_file)
    if a.parent_pid:
        threading.Thread(target=W._watch_parent, args=(srv, a.parent_pid), daemon=True).start()
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass
    W._emit("[hands-ab] stopped", log_file)
    return 0


if __name__ == "__main__":
    sys.exit(main())
