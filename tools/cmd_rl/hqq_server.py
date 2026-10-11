"""Minimal OpenAI-style chat server for Qwen3.8-27B quantized on the fly with HQQ (runs in WSL /opt/brain_moe/venv).

vLLM 0.30 has no HQQ support, so this serves the commander proxy directly with transformers + micro-batching.
Supports exactly what tools/plan_search/cloud_brain.local_command sends: messages, max_tokens, temperature, top_p,
chat_template_kwargs.enable_thinking, add_generation_prompt / continue_final_message (budget forcing).
Reasoning is returned separately (message.reasoning_content), like vLLM's qwen3 reasoning parser.

  python hqq_server.py --nbits 2 --port 8000 [--save <dir> | --load <dir>]
"""
from __future__ import annotations

import argparse
import json
import queue
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

MODEL = "/mnt/d/StrategyAI/models/Qwen3.8-27B-bf16"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--nbits", type=int, default=2)
    ap.add_argument("--group-size", type=int, default=64)
    ap.add_argument("--port", type=int, default=8000)
    ap.add_argument("--name", default="policy")
    ap.add_argument("--max-batch", type=int, default=8)
    ap.add_argument("--backend", default="", help="hqq inference backend after load (e.g. gemlite); empty = default")
    ap.add_argument("--model", default=MODEL)
    ap.add_argument("--quant", choices=["hqq", "none"], default="hqq")
    ap.add_argument("--causal", action="store_true", help="AutoModelForCausalLM (text-only models, e.g. Spark)")
    ap.add_argument("--trust-remote-code", action="store_true")
    ap.add_argument("--top-k", type=int, default=20)
    a = ap.parse_args()
    import torch
    import transformers
    from transformers import AutoTokenizer
    t0 = time.time()
    rc = {"trust_remote_code": True} if a.trust_remote_code else {}
    tok = AutoTokenizer.from_pretrained(a.model, **rc)
    tok.padding_side = "left"
    if tok.pad_token_id is None:
        tok.pad_token = tok.eos_token
    kw = {"device_map": {"": 0}, **rc}
    kw["torch_dtype" if transformers.__version__.startswith("4.") else "dtype"] = torch.bfloat16
    if a.quant == "hqq":
        from transformers import HqqConfig
        kw["quantization_config"] = HqqConfig(nbits=a.nbits, group_size=a.group_size, skip_modules=["lm_head", "visual"])
    cls = transformers.AutoModelForCausalLM if a.causal else transformers.AutoModelForImageTextToText
    model = cls.from_pretrained(a.model, **kw)
    model.eval()
    if a.backend:
        from hqq.utils.patching import prepare_for_inference
        prepare_for_inference(model, backend=a.backend)
    print(f"[HQQ] loaded {a.model} quant={a.quant} nbits={a.nbits} in {time.time() - t0:.0f}s vram={torch.cuda.memory_allocated() / 2**30:.2f}GiB",
          flush=True)
    think_close = "</think>"
    eos_id = tok.convert_tokens_to_ids("<|im_end|>") if "<|im_end|>" in tok.get_vocab() else tok.eos_token_id
    eos_str = tok.convert_ids_to_tokens(eos_id)
    jobs: "queue.Queue" = queue.Queue()

    def render(body):
        msgs = body.get("messages") or []
        kw = dict(body.get("chat_template_kwargs") or {})
        if body.get("continue_final_message"):
            return tok.apply_chat_template(msgs, tokenize=False, add_generation_prompt=False,
                                           continue_final_message=True, **kw)
        return tok.apply_chat_template(msgs, tokenize=False, add_generation_prompt=True, **kw)

    def split(prompt, text):
        """-> (reasoning, content). The generation prompt may already have opened <think>."""
        opened = prompt.rstrip().endswith("<think>") or ("<think>" in text)
        t = text.replace("<think>", "", 1) if "<think>" in text else text
        if think_close in t:
            r, c = t.split(think_close, 1)
            return r.strip(), c.strip()
        return (t.strip(), "") if opened and not prompt.rstrip().endswith(think_close) else ("", t.strip())

    def worker():
        while True:
            batch = [jobs.get()]
            time.sleep(0.5)
            while len(batch) < a.max_batch:
                try:
                    batch.append(jobs.get_nowait())
                except queue.Empty:
                    break
            prompts = [render(b) for b, _ in batch]
            enc = tok(prompts, return_tensors="pt", padding=True, add_special_tokens=False).to("cuda:0")
            mx = max(int(b.get("max_tokens") or 2048) for b, _ in batch)
            temp = float(batch[0][0].get("temperature") or 0.6)
            ts = time.time()
            with torch.inference_mode():
                out = model.generate(**enc, max_new_tokens=mx, do_sample=temp > 0, temperature=max(temp, 1e-3),
                                     top_p=float(batch[0][0].get("top_p") or 0.95), top_k=a.top_k if a.top_k > 0 else None,
                                     pad_token_id=tok.pad_token_id, eos_token_id=eos_id)
            n_in = enc["input_ids"].shape[1]
            gen_total = 0
            for i, (b, slot) in enumerate(batch):
                ids = out[i][n_in:].tolist()
                cap = int(b.get("max_tokens") or 2048)
                eos = eos_id
                finish = "length"
                if eos in ids[:cap]:
                    ids = ids[:ids.index(eos)]
                    finish = "stop"
                ids = [x for x in ids[:cap] if x != tok.pad_token_id]
                gen_total += len(ids)
                text = tok.decode(ids, skip_special_tokens=False).replace(eos_str, "")
                if b.get("continue_final_message"):
                    reasoning, content = "", text.strip()
                else:
                    reasoning, content = split(prompts[i], text)
                slot["resp"] = {"id": "hqq", "object": "chat.completion", "model": a.name,
                                "choices": [{"index": 0, "finish_reason": finish,
                                             "message": {"role": "assistant", "content": content,
                                                         "reasoning_content": reasoning}}],
                                "usage": {"prompt_tokens": int((enc["attention_mask"][i]).sum()),
                                          "completion_tokens": len(ids)}}
                slot["ev"].set()
            dt = time.time() - ts
            print(f"[HQQ] batch={len(batch)} max_new={mx} gen={gen_total} {dt:.0f}s {gen_total / max(dt, 1e-6):.1f} tok/s",
                  flush=True)
            del out, enc
            torch.cuda.empty_cache()

    threading.Thread(target=worker, daemon=True).start()

    class H(BaseHTTPRequestHandler):
        def log_message(self, *x):
            pass

        def _json(self, code, obj):
            b = json.dumps(obj).encode()
            self.send_response(code)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(b)))
            self.end_headers()
            self.wfile.write(b)

        def do_GET(self):
            if self.path.startswith("/v1/models"):
                self._json(200, {"data": [{"id": a.name}]})
            else:
                self._json(200, {"ok": True})

        def do_POST(self):
            body = json.loads(self.rfile.read(int(self.headers.get("Content-Length", "0"))) or b"{}")
            slot = {"ev": threading.Event()}
            jobs.put((body, slot))
            slot["ev"].wait()
            self._json(200, slot["resp"])

    print(f"[HQQ] serving {a.name} on {a.port}", flush=True)
    ThreadingHTTPServer(("127.0.0.1", a.port), H).serve_forever()


if __name__ == "__main__":
    main()
