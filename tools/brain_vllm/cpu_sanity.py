"""CPU-only sanity: tokenizer + prompt sizes for the parity sets (no GPU)."""
import json
import sys
from pathlib import Path

ROOT = Path(r"D:\Game development\Demon slayer\StrategyGame")
sys.path.insert(0, str(ROOT))
from tools.contract_sft import gpu_common as G

tok = G.load_tokenizer()
VLLM_DIR = ROOT / "artifacts" / "brain_pipeline_v1" / "vllm"
open_p = json.loads((VLLM_DIR / "parity" / "prompts_open.json").read_text(encoding="utf-8"))
rev_p = json.loads((VLLM_DIR / "parity" / "prompts_review.json").read_text(encoding="utf-8"))

def n(messages):
    return len(tok(G.render_prompt(tok, messages), add_special_tokens=False)["input_ids"])

s0b = [p for p in open_p if p["corpus"] == "s0b"]
s0c = [p for p in open_p if p["corpus"] == "s0c"]
lens_b = [n(p["messages"]) for p in s0b]
lens_c = [n(p["messages"]) for p in s0c]
lens_r = [n(p["messages"]) for p in rev_p]
print("s0b open prompts:", len(s0b), "tokens min/mean/max:", min(lens_b), round(sum(lens_b) / len(lens_b), 1), max(lens_b))
print("s0c open prompts:", len(s0c), "tokens min/mean/max:", min(lens_c), round(sum(lens_c) / len(lens_c), 1), max(lens_c))
print("review prompts:", len(rev_p), "tokens min/mean/max:", min(lens_r), round(sum(lens_r) / len(lens_r), 1), max(lens_r))
print("fix messages check:", [m["role"] for m in open_p[0]["messages"]], [m["role"] for m in rev_p[0]["messages"]])
