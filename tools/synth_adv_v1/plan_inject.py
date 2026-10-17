"""Engine test of a teacher plan (user, 2026-10-16): can the student carry out the teacher's plan, and does it win?

For one lost relay3 game and one relay turn T: the game is replayed with the same seed / bot, the student's own recorded
answers are served for turns 1..T-1 (no model call), then at turn T the relay prompt the student saw is sent to the model
together with the teacher's plan; the model writes the orders, and the plan in the answer is set to the teacher's plan.
From T+1 on the student (v3b_536, thinking off) plays the game to the end with the short relay context (system, relay prompt
of T, the answer at T, the turns after T); no further relays, so the teacher's plan stays the standing plan.
Replay check: the state at T must equal the recorded one (state_match) and the rebuilt relay prompt must equal the recorded
one (prompt_match); a row without both is not a valid test.

  python -m tools.synth_adv_v1.plan_inject --jobs <jobs.jsonl> --out relay3/inject_g2 --slot 6
  jobs.jsonl rows: {"id": "...", "game": "c1/BASIC_histno/t_BASIC_OUTRIDER_s9993012", "turn": 10, "plan": "REVISE: ..."}
"""
import argparse
import collections
import glob
import json
import os
import subprocess
import threading
import time
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

from tools.synth_adv_v1.hz_pipeline import HZ
from tools.synth_adv_v1.relay_shim import carry_messages, relay_messages

ROOT = HZ.parents[3]
PY = "D:/StrategyAI/runtimes/qwen3_8b_rl_v0/.venv/Scripts/python.exe"
STAND = '{"orders": {}}'


def recorded(game):
    """turn -> content the game received in the original run; plus the relay record at every relay turn."""
    cyc, arm, tag = game.split("/")
    d = HZ.parent / "relay3" / cyc / arm
    ans, by_win = {}, collections.defaultdict(list)
    for cf in glob.glob(str(d / "captures" / "red" / "calls.jsonl")) + glob.glob(str(d / "captures" / "calls.jsonl")):
        for line in open(cf, encoding="utf-8"):
            c = json.loads(line)
            if c.get("request") != "VICTORY_COMMAND" or not c.get("tag"):
                continue
            by_win[c.get("window")].append((c["ts"], c["tag"]))
            if c["tag"] == tag and c.get("turn") is not None and c.get("raw") is not None:
                ans.setdefault(int(c["turn"]), c["raw"])
    relays = {}
    for line in open(HZ.parent / "relay3" / cyc / (arm + "_relays.jsonl"), encoding="utf-8"):
        r = json.loads(line)
        prior = [x for x in by_win.get(r.get("window"), []) if x[0] <= r["ts"]]
        if prior and max(prior)[1] == tag:
            relays[int(r["turn"])] = r
            ans[int(r["turn"])] = r.get("response") or STAND  # relay turns: what the shim returned to the game
    meta = None
    gl = d / "games.jsonl"
    for line in open(gl, encoding="utf-8"):
        g = json.loads(line)
        if (g.get("tag") or "MANUAL_s%s" % g.get("seed")) == tag:
            meta = g
    return ans, relays, meta


def norm(st):
    return json.dumps(st, sort_keys=True)


def serve(port, job, ans, relay_T, target, log_path):
    T, plan = int(job["turn"]), job["plan"]
    hist = relay_T.get("history") == "yes"
    box = {"carry": None, "state_match": None, "prompt_match": None, "missing": 0, "t_orders": None}
    lock = threading.Lock()

    def jlog(row):
        with lock, open(log_path, "a", encoding="utf-8") as fh:
            fh.write(json.dumps(row, ensure_ascii=False) + "\n")

    class H(BaseHTTPRequestHandler):
        def log_message(self, *x):
            pass

        def reply(self, code, out):
            self.send_response(code)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(out)))
            self.end_headers()
            self.wfile.write(out)

        def forward(self, d):
            hdr = {k: v for k, v in self.headers.items() if k.lower() not in ("host", "content-length")}
            req = urllib.request.Request(target + self.path, data=json.dumps(d, ensure_ascii=False).encode("utf-8"),
                                         headers=hdr, method="POST")
            with urllib.request.urlopen(req, timeout=3600) as r:
                return json.loads(r.read())

        def do_POST(self):  # noqa: N802
            raw = self.rfile.read(int(self.headers.get("Content-Length") or 0))
            d = json.loads(raw)
            st = d.get("state") if isinstance(d.get("state"), dict) else {}
            t = int(st["turn"]) if st.get("turn") is not None else None
            msgs = d.get("messages") or []
            try:
                if t is None or t < T:
                    content = ans.get(t, STAND) if t is not None else STAND
                    if t is not None and t not in ans:
                        box["missing"] += 1
                    resp = {"choices": [{"message": {"role": "assistant", "content": content}}]}
                    jlog({"turn": t, "mode": "replay"})
                elif t == T:
                    box["state_match"] = norm(st) == norm(relay_T["state"])
                    rm = relay_messages(msgs, st, hist)
                    box["prompt_match"] = rm[-1]["content"] == relay_T["relay_messages"][-1]["content"]
                    inj = [dict(m) for m in rm]
                    inj[-1]["content"] += ("\n\nYour plan for the rest of this battle is already decided: \"%s\"\nReply with ONE JSON "
                                           "object: \"plan\" (copy that plan exactly) and \"orders\" (the orders that start it now)."
                                           % plan)
                    if isinstance(job.get("orders"), dict):  # the teacher wrote the orders at T too: no model call at T
                        got, orders = None, job["orders"]
                        resp = {"choices": [{"message": {"role": "assistant", "content": ""}}]}
                    else:
                        d["messages"] = inj
                        resp = self.forward(d)
                        got = resp["choices"][0]["message"].get("content") or ""
                        try:
                            o = json.loads(got.split("</think>")[-1].strip())
                            orders = o.get("orders") if isinstance(o, dict) and isinstance(o.get("orders"), dict) else {}
                        except ValueError:
                            orders = {}
                    content = json.dumps({"plan": plan, "orders": orders}, ensure_ascii=False)
                    resp["choices"][0]["message"]["content"] = content
                    box["t_orders"] = orders
                    box["carry"] = {"turn": T, "prompt": rm[-1], "answer": content}
                    jlog({"turn": t, "mode": "inject", "state_match": box["state_match"], "prompt_match": box["prompt_match"],
                          "model_raw": got, "sent": content})
                else:
                    d["messages"] = carry_messages(msgs, box["carry"])
                    resp = self.forward(d)
                    jlog({"turn": t, "mode": "carry", "n_in": len(msgs), "n_out": len(d["messages"]),
                          "answer": resp["choices"][0]["message"].get("content")})
                self.reply(200, json.dumps(resp, ensure_ascii=False).encode("utf-8"))
            except Exception as e:  # noqa: BLE001
                jlog({"turn": t, "mode": "error", "err": repr(e)[:300]})
                self.reply(200, json.dumps({"choices": [{"message": {"role": "assistant", "content": STAND}}]}).encode())

    srv = ThreadingHTTPServer(("127.0.0.1", port), H)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    return srv, box


def play(job, out, slot):
    game = job["game"]
    cyc, arm, tag = game.split("/")
    ans, relays, meta = recorded(game)
    T = int(job["turn"])
    if T not in relays or meta is None:
        return {"error": "no relay record at T or no game meta"}
    jd = out / job["id"]
    jd.mkdir(parents=True, exist_ok=False)
    sp, proxy, brain = 8180 + slot, 8190 + slot, 8195 + slot
    srv, box = serve(sp, job, ans, relays[T], "http://127.0.0.1:%d" % proxy, str(jd / "shim.jsonl"))
    env = dict(os.environ, MSYS_NO_PATHCONV="1", PYTHONIOENCODING="utf-8")
    cmd_url = "http://127.0.0.1:%d/v1/chat/completions" % sp
    bot = None
    if arm.startswith("blockade"):
        man = jd / "manual"
        man.mkdir()
        bot = subprocess.Popen([PY, "-m", "tools.cmd_rl.blockade_bot", "--dir", str(man)], cwd=str(ROOT),
                               stdout=subprocess.DEVNULL, stderr=subprocess.STDOUT)
        env.update({"SPAR_MODEL": "v3b_536", "SPAR_THINK_PORT": str(8210 + slot), "SPAR_THINK_BUDGET": "9000",
                    "SPAR_RED_PORT": str(proxy)})
        cmd = [PY, "-m", "tools.synth_adv_v1.spar_relay", "--manual", "--per-model", "1", "--slot", str(slot),
               "--red-port", str(proxy), "--red-brain-port", str(brain), "--blue-port0", str(8150 + slot),
               "--seed0", str(meta["seed"]), "--cmd-url", cmd_url, "--out", str(jd)]
    else:
        cmd = [PY, "-m", "tools.cmd_rl.teacher_gx", "--tier", arm.split("_")[0], "--games", "1", "--windows", "1",
               "--seed0", str(meta["seed"]), "--style", meta["style"], "--family", meta["family"], "--slot", str(slot),
               "--proxy-port", str(proxy), "--brain-port", str(brain), "--url", "http://127.0.0.1:8010/v1/chat/completions",
               "--model", "v3b_536", "--cmd-url", cmd_url, "--out", str(jd)]
    g0 = time.time()
    with open(jd / "run.log", "w", encoding="utf-8") as fh:
        rc = subprocess.call(cmd, cwd=str(ROOT), env=env, stdout=fh, stderr=subprocess.STDOUT)
    if bot:
        bot.kill()
    srv.shutdown()
    srv.server_close()
    g = {}
    gl = jd / "games.jsonl"
    if gl.exists():
        g = json.loads(gl.read_text(encoding="utf-8").splitlines()[-1])
    orig_hq = (meta.get("hq") or {}).get("blue", {}).get("end") if meta.get("hq") else meta.get("hq_end")
    new_hq = (g.get("hq") or {}).get("blue", {}).get("end") if g.get("hq") else g.get("hq_end")
    return {"rc": rc, "s": round(time.time() - g0), "state_match": box["state_match"], "prompt_match": box["prompt_match"],
            "replay_missing": box["missing"], "t_orders": box["t_orders"],
            "orig": {"outcome": meta.get("kind") or meta.get("outcome"), "turn": meta.get("turn"), "blue_hq_end": orig_hq,
                     "units": meta.get("units")},
            "new": {"outcome": g.get("kind") or g.get("outcome"), "turn": g.get("turn"), "blue_hq_end": new_hq,
                    "units": g.get("units")}}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--jobs", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--slot", type=int, default=6)
    a = ap.parse_args()
    out = HZ.parent / a.out
    out.mkdir(parents=True, exist_ok=True)
    resf = out / "results.jsonl"
    done = {json.loads(x)["id"] for x in resf.read_text(encoding="utf-8").splitlines() if x.strip()} if resf.exists() else set()
    for line in open(a.jobs, encoding="utf-8"):
        if not line.strip():
            continue
        job = json.loads(line)
        if job["id"] in done:
            continue
        r = play(job, out, a.slot)
        row = {"id": job["id"], "game": job["game"], "turn": job["turn"], "plan": job["plan"], **r}
        with open(resf, "a", encoding="utf-8") as fh:
            fh.write(json.dumps(row, ensure_ascii=False) + "\n")
        print(time.strftime("%H:%M:%S"), job["id"], "match=%s/%s" % (r.get("state_match"), r.get("prompt_match")),
              "orig=%s new=%s" % ((r.get("orig") or {}).get("outcome"), (r.get("new") or {}).get("outcome")),
              r.get("error") or "", flush=True)


if __name__ == "__main__":
    main()
