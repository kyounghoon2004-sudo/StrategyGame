"""BRAIN_VLLM_PHASE1 — vLLM-backed Brain service (Windows-side shim).

Drop-in replacement for `python -m tools.contextual_brain.rl_vs_utility serve`:

  <RL venv python> -m tools.brain_vllm.service --adapter <dir> --session <token> --capture-dir <dir>
      [--gpu-mem-gb 13.5] [--port 8096] [--engine-url http://127.0.0.1:8000]

Same contract as serve:
  GET  /health, /identity          -> {ok, label:"RL_POLICY", model:"rl_policy", rl_session, adapter_dir,
                                       adapter_sha256, adapter_is_csft6:false, calls, memory}
  POST /v1/chat/completions        -> OpenAI chat shape; raw completion; finish_reason length/stop; usage
  POST /admin/tag, /admin/tags, /admin/shutdown
  capture: <capture-dir>/calls.jsonl (one row per real call, +prompt_ids/comp_ids) and the first
           VICTORY_INITIAL per tag -> <capture-dir>/<tag>.json

New (Phase 1):
  POST /admin/load_adapter {path}  -> hot-swap the served adapter (no base reload), reports new sha256
  POST /admin/sleep {level}        -> free GPU memory (target <= 1 GB) for a training phase
  POST /admin/wake                 -> wake the engine and re-attach the current adapter

The PROBE_TEXT health probe answers "OK" without generating, exactly like serve.
Rendering/tokenization is done HERE with tools.contract_sft.gpu_common (G);
the engine receives token ids only. Thinking stays off (non-thinking template
via G.render_prompt). No strip / repair / retry / fallback on completions.
"""
from __future__ import annotations

import argparse
import json
import os
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

from tools.brain_vllm import common as C  # noqa: E402


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--adapter", required=True)
    ap.add_argument("--session", required=True)
    ap.add_argument("--capture-dir", required=True)
    ap.add_argument("--gpu-mem-gb", type=float, default=C.GPU_MEM_GB_DEFAULT)
    ap.add_argument("--port", type=int, default=C.SHIM_PORT)
    ap.add_argument("--engine-url", default=C.ENGINE_URL)
    ap.add_argument("--ready-timeout", type=int, default=1500)
    a = ap.parse_args()

    from tools.contract_sft import gpu_common as G
    from tools.contract_sft.brain_server import PROBE_TEXT, packet_of

    cap_dir = Path(a.capture_dir)
    cap_dir.mkdir(parents=True, exist_ok=True)
    log = G.make_logger(cap_dir / "shim.log")
    log(f"[SHIM] adapter={a.adapter} session={a.session} engine={a.engine_url} gpu_mem_gb={a.gpu_mem_gb}")

    tok = G.load_tokenizer()
    MAX_NEW = int(G.SAMPLING["max_new_tokens"])

    st = {
        "ready": False, "status": "starting", "detail": "",
        "tag": None, "tag_map": {}, "calls": 0, "corrupted": False,
        "asleep": False, "adapter_dir": a.adapter, "adapter_sha256": None, "lora": None,
        "mem_peak_gib": 0.0, "mem_last_gib": None,
    }
    cap_lock = threading.Lock()
    state_lock = threading.Lock()

    # ---------------- memory sampler (whole-GPU view, cheap)
    def sampler():
        while True:
            mib = C.gpu_used_mib()
            if mib >= 0:
                with state_lock:
                    st["mem_last_gib"] = round(mib / 1024, 3)
                    st["mem_peak_gib"] = max(st["mem_peak_gib"], st["mem_last_gib"])
            time.sleep(5)

    threading.Thread(target=sampler, daemon=True).start()

    # ---------------- helpers
    def tag_for(headers):
        import re
        from urllib.parse import unquote
        m = re.search(r"_(w[0-9]+)[.]json$", unquote(headers.get("X-Episode-Spec-Path") or ""))
        win = m.group(1) if m else None
        with state_lock:
            return win, (st["tag_map"].get(win) if win else None) or st["tag"]

    def engine_completion(prompt_ids):
        payload = {"model": st["lora"] or "rl_policy", "prompt": list(prompt_ids), "max_tokens": MAX_NEW,
                   "temperature": float(G.SAMPLING["temperature"]), "top_p": float(G.SAMPLING["top_p"]),
                   "top_k": int(G.SAMPLING["top_k"]), "repetition_penalty": float(G.SAMPLING["repetition_penalty"]),
                   "return_token_ids": True}
        code, body = C.http_json(a.engine_url + "/v1/completions", payload, method="POST", timeout=1800)
        if code != 200 or not isinstance(body, dict):
            raise RuntimeError(f"engine completions http {code}: {str(body)[:500]}")
        ch = (body.get("choices") or [{}])[0]
        ids = ch.get("token_ids")
        finish = str(ch.get("finish_reason", ""))
        if ids is None:  # server without return_token_ids: reconstruct (flagged inexact in capture)
            ids = tok(ch.get("text", ""), add_special_tokens=False)["input_ids"]
            exact = False
        else:
            ids = [int(x) for x in ids]
            exact = True
        return ids, finish, exact

    def gen(messages):
        t0 = time.time()
        with state_lock:
            if st["asleep"]:
                raise RuntimeError("service is asleep (/admin/wake first)")
        text = G.render_prompt(tok, messages)
        p = tok(text, add_special_tokens=False)["input_ids"]
        ids, finish, exact = engine_completion(p)
        # HF serve returns the sampled ids INCLUDING the terminal EOS; vLLM omits it.
        if finish == "stop" and (not ids or ids[-1] != tok.eos_token_id):
            ids = ids + [int(tok.eos_token_id)]
        c = ids
        raw = tok.decode(c, skip_special_tokens=True)
        dt = round(time.time() - t0, 2)
        with state_lock:
            st["calls"] += 1
            n = st["calls"]
        log(f"[SHIM] call {n} prompt_tokens={len(p)} comp_tokens={len(c)} finish={finish} {dt}s exact={exact}")
        return raw, p, c, finish, exact, dt

    # ---------------- HTTP handler (mirrors rl_vs_utility.serve's handler)
    class H(BaseHTTPRequestHandler):
        # HTTP/1.0 like rl_vs_utility.serve (close per response; maximum client compatibility)
        def log_message(self, *x):
            pass

        def _json(self, code, obj):
            b = json.dumps(obj).encode("utf-8")
            self.send_response(code)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(b)))
            self.end_headers()
            self.wfile.write(b)

        def do_GET(self):
            with state_lock:
                ready, asleep = st["ready"], st["asleep"]
                ident = {"ok": bool(ready), "status": st["status"], "detail": st["detail"],
                         "label": "RL_POLICY", "model": "rl_policy", "rl_session": a.session,
                         "adapter_dir": st["adapter_dir"], "adapter_sha256": st["adapter_sha256"],
                         "adapter_is_csft6": False, "calls": st["calls"], "asleep": asleep,
                         "backend": "vllm_fp8", "engine": a.engine_url, "lora": st["lora"],
                         "memory": {"peak_device_vram_gib": st["mem_peak_gib"],
                                    "current_device_vram_gib": st["mem_last_gib"]}}
            if self.path in ("/health", "/identity"):
                self._json(200, ident)
            else:
                self._json(404, {})

        def do_POST(self):
            try:
                body = json.loads(self.rfile.read(int(self.headers.get("Content-Length", "0"))) or b"{}")
            except ValueError as e:
                self._json(400, {"error": str(e)})
                return
            if self.path == "/admin/tag":
                with state_lock:
                    st["tag"] = body.get("tag")
                self._json(200, {"ok": True})
                return
            if self.path == "/admin/tags":  # {window: tag}, e.g. {"w0": "g00012_0", ...}
                with state_lock:
                    st["tag_map"] = dict(body)
                self._json(200, {"ok": True})
                return
            if self.path == "/admin/load_adapter":
                try:
                    with state_lock:
                        cur = st["lora"]
                    r = C.load_lora_into_engine(body.get("path"), current_lora=cur, log=log)
                    with state_lock:
                        st["adapter_dir"] = body.get("path")
                        st["adapter_sha256"] = r["sha"]
                        st["lora"] = r["lora_name"]
                    self._json(200, {"ok": True, "adapter_dir": body.get("path"),
                                     "adapter_sha256": r["sha"], "lora": r["lora_name"], "load_s": r["load_s"]})
                except Exception as e:  # noqa: BLE001 - honest failure
                    log(f"[SHIM] load_adapter FAILED: {e}")
                    self._json(500, {"ok": False, "error": str(e)})
                return
            if self.path == "/admin/sleep":
                level = int(body.get("level", 2))
                t0 = time.time()
                try:
                    # vLLM 0.30's sleep mode retains ~2 GiB on the GPU by
                    # design (cumem pool + contexts for fast wake), which
                    # misses the <= 1 GB target. So sleep = level-N sleep
                    # (clean state) + a full engine stop: the service then
                    # holds ~0 GPU for the training phase. /admin/wake boots
                    # a fresh engine (warm compile caches) and re-attaches
                    # the current adapter. Both times are reported honestly.
                    r = C.engine_sleep(level)
                    C.engine_stop()
                    # wait until the engine port is actually down so the
                    # caller's post-sleep GPU reading is stable
                    t1 = time.time()
                    while C.engine_up(timeout=2) and time.time() - t1 < 120:
                        time.sleep(2)
                    # WSL GPU release lags port-down: wait for the reading
                    # to settle (stable within 50 MiB) up to 60 s
                    last = C.gpu_used_mib()
                    t2 = time.time()
                    while time.time() - t2 < 60:
                        time.sleep(3)
                        cur = C.gpu_used_mib()
                        if cur >= 0 and last >= 0 and abs(cur - last) <= 50:
                            last = cur
                            break
                        last = cur
                    sleep_s = round(time.time() - t0, 1)
                    with state_lock:
                        st["asleep"] = True
                    log(f"[SHIM] sleep level={level} + engine stopped in {sleep_s}s -> {r}")
                    self._json(200, {"ok": True, **r, "engine_stopped": True,
                                     "engine_down": not C.engine_up(timeout=2), "sleep_s": sleep_s})
                except Exception as e:  # noqa: BLE001
                    log(f"[SHIM] sleep FAILED: {e}")
                    self._json(500, {"ok": False, "error": str(e)})
                return
            if self.path == "/admin/wake":
                t0 = time.time()
                try:
                    # engine_start boots a fresh engine when stopped (warm
                    # caches), or wakes a sleeping one; then re-attach.
                    r = C.engine_start(a.gpu_mem_gb, log=log)
                    with state_lock:
                        cur_path, cur_lora = st["adapter_dir"], st["lora"]
                    lr = C.load_lora_into_engine(cur_path, current_lora=cur_lora, log=log)
                    with state_lock:
                        st["asleep"] = False
                        st["adapter_sha256"] = lr["sha"]
                        st["lora"] = lr["lora_name"]
                    wake_s = round(time.time() - t0, 1)
                    log(f"[SHIM] wake in {wake_s}s -> {r} lora={lr['lora_name']}")
                    self._json(200, {"ok": True, **r, "wake_s": wake_s,
                                     "adapter_sha256": lr["sha"], "lora": lr["lora_name"]})
                except Exception as e:  # noqa: BLE001
                    log(f"[SHIM] wake FAILED: {e}")
                    self._json(500, {"ok": False, "error": str(e)})
                return
            if self.path == "/admin/shutdown":
                self._json(200, {"ok": True})

                def _stop():
                    try:
                        C.engine_sleep(2)  # free GPU while this shim still holds the engine session
                        log("[SHIM] engine asleep (level 2) after shutdown request")
                    except Exception as e:  # noqa: BLE001
                        log(f"[SHIM] sleep-on-shutdown skipped: {e}")
                    try:
                        C.engine_stop()  # release the GPU fully (service -> ~0)
                        log("[SHIM] engine stopped after shutdown request")
                    except Exception as e:  # noqa: BLE001
                        log(f"[SHIM] stop-on-shutdown skipped: {e}")
                    srv.shutdown()
                    time.sleep(1)
                    log("[SHIM] exit")
                    os._exit(0)
                threading.Thread(target=_stop, daemon=True).start()
                return
            # anything else = one Brain call (same semantics as serve)
            msgs = body.get("messages") or []
            last = next((str(m.get("content", "")) for m in reversed(msgs)
                         if isinstance(m, dict) and m.get("role") == "user"), "")
            if last.strip() == PROBE_TEXT:  # connection test, not a Brain call
                self._json(200, {"id": f"rl-{st['calls']}", "object": "chat.completion", "model": "rl_policy",
                                 "choices": [{"index": 0, "message": {"role": "assistant", "content": "OK"},
                                              "finish_reason": "stop"}],
                                 "usage": {"prompt_tokens": 0, "completion_tokens": 0, "total_tokens": 0}})
                return
            try:
                raw, p, c, finish, exact, dt = gen(msgs)
            except Exception as e:  # noqa: BLE001 - transport-level failure, never a fabricated completion
                log(f"[SHIM] completion FAILED: {e}")
                self._json(502, {"error": f"{type(e).__name__}: {e}"})
                return
            pk = packet_of(msgs) or {}
            win, tag = tag_for(self.headers)
            if win and os.environ.get("RL_DEBUG_CORRUPT_WINDOW") == win and pk.get("request") == "VICTORY_REVIEW" \
                    and not st.get("corrupted"):
                with state_lock:
                    st["corrupted"] = True
                raw = '{"decision": "KEEP", "reason": "broken'
            with cap_lock:
                with open(cap_dir / "calls.jsonl", "a", encoding="utf-8") as cf:
                    cf.write(json.dumps({"tag": tag, "window": win, "request": pk.get("request"), "turn": pk.get("turn"),
                                         "trigger": (pk.get("review_trigger") or {}).get("trigger"),
                                         "messages": msgs, "raw": raw, "episode": self.headers.get("X-Episode-Id"),
                                         "prompt_ids": p, "comp_ids": c, "comp_ids_exact": exact,
                                         "finish_reason": finish, "wall_s": dt}) + "\n")
                f = cap_dir / f"{tag}.json"
                if tag and pk.get("request") == "VICTORY_INITIAL" and not f.exists():
                    f.write_text(json.dumps({"prompt_ids": p, "comp_ids": c, "text": raw,
                                             "has_context": "context" in pk,
                                             "episode": self.headers.get("X-Episode-Id")}), encoding="utf-8")
            n_len = len(c)
            self._json(200, {"id": f"rl-{st['calls']}", "object": "chat.completion", "model": "rl_policy",
                             "choices": [{"index": 0, "message": {"role": "assistant", "content": raw},
                                          "finish_reason": "length" if (finish == "length" or n_len >= MAX_NEW) else "stop"}],
                             "usage": {"prompt_tokens": len(p), "completion_tokens": n_len, "total_tokens": len(p) + n_len}})

    srv = ThreadingHTTPServer(("127.0.0.1", a.port), H)
    srv.daemon_threads = True
    srv.allow_reuse_address = True
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    log(f"[SHIM] listening http://127.0.0.1:{a.port} (starting engine ...)")

    # ---------------- engine bring-up + adapter attach
    try:
        st["status"] = "engine"
        e = C.engine_start(a.gpu_mem_gb, wait_s=a.ready_timeout, log=log)
        st["status"] = "adapter"
        r = C.load_lora_into_engine(a.adapter, current_lora=None, log=log)
        with state_lock:
            st["adapter_sha256"] = r["sha"]
            st["lora"] = r["lora_name"]
            st["ready"] = True
            st["status"] = "ready"
        log(f"[SHIM] READY label=RL_POLICY session={a.session} adapter_sha256={r['sha']} lora={r['lora_name']}")
    except Exception as e:  # noqa: BLE001
        with state_lock:
            st["status"] = "error"
            st["detail"] = f"{type(e).__name__}: {e}"
        log(f"[SHIM] STARTUP FAILED: {st['detail']}")

    try:
        while True:
            time.sleep(3600)
    except KeyboardInterrupt:
        pass
    log(f"[SHIM] stopped calls={st['calls']}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
