"""Generate sealed review-probe answers from Thinking-2507 via vLLM.

Start only when GPU is free. --serve owns a foreground WSL vLLM process and
stops that process on exit. Output is resumable and compatible with review_probe.
"""
from __future__ import annotations

import argparse
from concurrent.futures import ThreadPoolExecutor, as_completed
import json
import os
from pathlib import Path
import subprocess
import time
from urllib.error import HTTPError
from urllib.request import Request, urlopen

ROOT = Path(__file__).resolve().parents[2]
PROBE = ROOT / "artifacts" / "brain_pipeline_v1" / "sealed_review_probe_v3"
OUT = ROOT / "artifacts" / "brain_pipeline_v1" / "moe_prep"
TOKENIZER_DIR = (r"D:\StrategyAI\models\Qwen3-30B-A3B-Thinking-2507-tokenizer"
                 if os.name == "nt" else "/mnt/d/StrategyAI/models/Qwen3-30B-A3B-Thinking-2507-tokenizer")
SAMPLING = {"temperature": 0.7, "top_p": 0.8, "top_k": 20, "repetition_penalty": 1.0}
# Broad schema leaves review_v2's decision-specific fields to the existing
# review_probe dry run. vLLM enforces JSON syntax while qwen3 reasoning parser
# puts thinking in message.reasoning and this object in message.content.
REVIEW_SCHEMA = {"type": "object", "properties": {"decision": {"type": "string"}},
                 "required": ["decision"], "additionalProperties": True}


def final_answer(message: dict) -> tuple[str, str]:
    """Return final text and reasoning from parsed or inline Qwen3 output."""
    content = message.get("content") or ""
    reasoning = message.get("reasoning") or message.get("reasoning_content") or ""
    if "<think>" in content:
        before, after = content.split("<think>", 1)
        if "</think>" in after:
            think, content = after.split("</think>", 1)
            reasoning = reasoning or think
            content = before + content
        else:
            reasoning = reasoning or after
            content = before
    elif "</think>" in content:
        think, content = content.split("</think>", 1)
        reasoning = reasoning or think
    return content.strip(), reasoning.strip()


def make_row(job: dict, response: dict, seconds: float, tokenizer=None) -> dict:
    choice = response["choices"][0]
    final, reasoning = final_answer(choice["message"])
    usage = response.get("usage") or {}
    details = usage.get("completion_tokens_details") or {}
    reason_tokens = details.get("reasoning_tokens")
    source = "server"
    if reason_tokens is None:
        reason_tokens = len(tokenizer(reasoning, add_special_tokens=False)["input_ids"]) if tokenizer else None
        source = "retokenized" if tokenizer else "unavailable"
    return {"job_id": job["job_id"], "prompt_id": job["prompt_id"],
            "seed": job["seed"], "text": final,
            "gen_tokens": usage.get("completion_tokens"),
            "hit_token_cap": choice.get("finish_reason") == "length",
            "seconds": round(seconds, 3), "reasoning_tokens": reason_tokens,
            "reasoning_tokens_source": source}


def request_json(url: str, payload: dict | None = None, timeout: int = 1800):
    data = None if payload is None else json.dumps(payload).encode("utf-8")
    req = Request(url, data=data, headers={"Content-Type": "application/json"})
    try:
        with urlopen(req, timeout=timeout) as r:
            return json.load(r)
    except HTTPError as e:
        raise RuntimeError(f"HTTP {e.code} {url}: {e.read(500).decode(errors='replace')}") from e


def atomic_json(path: Path, value: dict):
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_name(path.name + ".tmp")
    tmp.write_text(json.dumps(value, indent=1, ensure_ascii=False), encoding="utf-8")
    os.replace(tmp, path)


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--label", required=True)
    ap.add_argument("--jobs", type=Path, default=PROBE / "jobs.json")
    ap.add_argument("--out", type=Path)
    ap.add_argument("--adapter", help="WSL-visible PEFT adapter directory; omit for zero-shot")
    ap.add_argument("--model", default="brain_moe")
    ap.add_argument("--tokenizer", default=TOKENIZER_DIR,
                    help="official Thinking-2507 tokenizer and chat template")
    ap.add_argument("--url", default="http://127.0.0.1:8001")
    ap.add_argument("--max-tokens", type=int, default=4096,
                    help="thinking plus final JSON; reduced per prompt to fit context")
    ap.add_argument("--thinking-token-budget", type=int, default=2048,
                    help="vLLM qwen3 reasoning budget; reserves remaining tokens for JSON")
    ap.add_argument("--max-model-len", type=int, default=10240)
    ap.add_argument("--concurrency", type=int, default=3)
    ap.add_argument("--serve", action="store_true", help="own /opt/brain_moe/run_vllm_moe.sh process")
    ap.add_argument("--startup-timeout", type=int, default=900)
    args = ap.parse_args()
    if args.concurrency < 1:
        ap.error("--concurrency must be positive")
    out = args.out or OUT / f"gen_{args.label}.json"
    jobs = json.loads(args.jobs.read_text(encoding="utf-8"))
    from transformers import AutoTokenizer
    tok = AutoTokenizer.from_pretrained(args.tokenizer, trust_remote_code=False)
    proc = None
    try:
        if args.serve:
            proc = subprocess.Popen(["wsl.exe", "-d", "Ubuntu-24.04", "-u", "root", "--",
                                     "bash", "/opt/brain_moe/run_vllm_moe.sh"],
                                    stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                                    stderr=subprocess.STDOUT, creationflags=0x08000000 if os.name == "nt" else 0)
        deadline = time.monotonic() + args.startup_timeout
        while True:
            try:
                request_json(args.url + "/v1/models", timeout=3)
                break
            except Exception:
                if proc and proc.poll() is not None:
                    raise RuntimeError(f"vLLM exited with code {proc.returncode}")
                if time.monotonic() >= deadline:
                    raise TimeoutError("vLLM did not become ready")
                time.sleep(3)
        model = args.model
        if args.adapter:
            name = "moe_" + args.label
            request_json(args.url + "/v1/load_lora_adapter",
                         {"lora_name": name, "lora_path": args.adapter}, timeout=300)
            model = name
        existing = json.loads(out.read_text(encoding="utf-8")) if out.exists() else {}
        done = {r["job_id"]: r for r in existing.get("rows", [])}
        order = {j["job_id"]: i for i, j in enumerate(jobs)}
        def write(complete=False):
            rows = sorted(done.values(), key=lambda r: order[r["job_id"]])
            atomic_json(out, {"label": args.label, "adapter": args.adapter,
                              "backend": "vllm_moe", "sampling": dict(SAMPLING, max_new_tokens=args.max_tokens),
                              "rows": rows, "complete": complete})
        def one(job):
            prompt_ids = tok.apply_chat_template(job["messages"], tokenize=True,
                                                 add_generation_prompt=True)
            budget = min(args.max_tokens, args.max_model_len - len(prompt_ids))
            if budget < 1280:
                raise ValueError(f"job {job['job_id']} has only {budget} generation tokens; need 1280 for JSON")
            thinking_budget = min(args.thinking_token_budget, max(0, budget - 1280))
            payload = {"model": model, "messages": job["messages"], "max_tokens": budget,
                       "seed": int(job["seed"]), "chat_template_kwargs": {"enable_thinking": True},
                       "thinking_token_budget": thinking_budget,
                       "response_format": {"type": "json_schema", "json_schema": {
                           "name": "brain_review", "schema": REVIEW_SCHEMA, "strict": False}},
                       **SAMPLING}
            start = time.monotonic()
            response = request_json(args.url + "/v1/chat/completions", payload)
            return make_row(job, response, time.monotonic() - start, tok)
        todo = [j for j in jobs if j["job_id"] not in done]
        with ThreadPoolExecutor(max_workers=args.concurrency) as pool:
            futures = {pool.submit(one, j): j for j in todo}
            for future in as_completed(futures):
                row = future.result()
                done[row["job_id"]] = row
                write()
                print(f"{len(done)}/{len(jobs)} {row['job_id']} {row['seconds']}s", flush=True)
        write(complete=True)
        print(out)
    finally:
        if proc and proc.poll() is None:
            proc.terminate()
            try:
                proc.wait(timeout=30)
            except subprocess.TimeoutExpired:
                proc.kill()


if __name__ == "__main__":
    main()
