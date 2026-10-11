"""Quick check of the SFT adapters (2026-10-06): after cmd_sft/SFT_V2_V3_DONE appears, serve each adapter on vLLM
(WSL) and play the first 3 BASIC games (fortify on, fresh packet per call = the cloud data format):
  v2 = answers only, thinking OFF;  v3 = short thinking + answer, thinking ON with a 1500-token budget.
Never trains and plays at the same time; vLLM is stopped at the end.

  python -m tools.cmd_rl.eval_sft_local
"""
from __future__ import annotations

import json
import subprocess
import time
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
B = ROOT / "artifacts" / "brain_pipeline_v1"
SFT = B / "cmd_sft"
RL = B / "cmd_rl"
WSL = ["wsl.exe", "-d", "Ubuntu-24.04", "--"]
PY = r"D:\StrategyAI\runtimes\qwen3_8b_rl_v0\.venv\Scripts\python.exe"
RUNS = [("cmd_sft_eval_v2", "sft_v2", ["--local-no-think"]),
        ("cmd_sft_eval_v3", "sft_v3_think", ["--local-think-budget", "1500"])]


def wsl_path(p: Path) -> str:
    s = str(p).replace("\\", "/")
    return "/mnt/" + s[0].lower() + s[2:]


def log(m):
    line = time.strftime("%m-%d %H:%M:%S ") + m
    print(line, flush=True)
    with open(SFT / "eval_sft_local.log", "a", encoding="utf-8") as f:
        f.write(line + "\n")


def vllm_up() -> bool:
    try:
        with urllib.request.urlopen("http://127.0.0.1:8000/v1/models", timeout=5) as r:
            return "policy" in [m["id"] for m in json.loads(r.read())["data"]]
    except Exception:  # noqa: BLE001
        return False


def vllm_stop():
    subprocess.run(WSL + ["bash", wsl_path(RL / "stop_vllm.sh")], capture_output=True, timeout=180)


def main():
    import argparse
    ap = argparse.ArgumentParser()
    ap.add_argument("--tier", default="BASIC")
    ap.add_argument("--suffix", default="")
    a = ap.parse_args()
    while not (SFT / "SFT_V2_V3_DONE").exists():
        time.sleep(60)
    for out, adapter, flags in RUNS:
        ad = SFT / "adapters" / adapter
        if not (ad / "adapter_model.safetensors").exists():
            log(f"[EVAL] {adapter}: no adapter, skipped")
            continue
        vllm_stop()
        subprocess.Popen(WSL + ["bash", wsl_path(RL / "run_vllm_q35_64k_lora.sh"), wsl_path(ad)],
                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        t0 = time.time()
        while not vllm_up():
            if time.time() - t0 > 900:
                log(f"[EVAL] {adapter}: vLLM did not come up")
                break
            time.sleep(10)
        else:
            log(f"[EVAL] {adapter}: vLLM up, playing 3 {a.tier} games -> {out}")
            o = B / (out + a.suffix)
            o.mkdir(exist_ok=True)
            with open(o / "collect_stdout.log", "a") as so, open(o / "collect_stderr.log", "a") as se:
                p = subprocess.Popen([PY, "-m", "tools.plan_search.cmd_collect", "--out", str(o), "--tiers", "BASIC,INTER,ADV",
                                      "--tier-games", ",".join("%s=%d" % (t, 3 if t == a.tier else 0) for t in ("BASIC", "INTER", "ADV")), "--windows", "3", "--fortify",
                                      "--history-max-chars", "20000", "--slot", "3", "--proxy-port", "8099", "--brain-port", "8109",
                                      "--local-url", "http://127.0.0.1:8000/v1/chat/completions",
                                      "--local-model", "policy"] + flags, cwd=str(ROOT), stdout=so, stderr=se)
                (o / "collector.pid").write_text(str(p.pid))
                p.wait()
            log(f"[EVAL] {adapter}: done rc={p.returncode}")
    vllm_stop()
    (SFT / ("EVAL_DONE" + a.suffix)).write_text("done")
    log("[EVAL] all done")


if __name__ == "__main__":
    main()
