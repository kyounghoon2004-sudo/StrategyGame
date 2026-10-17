"""spar.py against the multi-LoRA vLLM on :8010: model name 'policy' -> a served adapter name (env SPAR_MODEL, default
v3b_536); never starts/stops a vLLM (another job may be using it)."""
import os
from tools.cmd_rl import loop as L
L.VLLM_URL = "http://127.0.0.1:8010"
L.vllm_stop = lambda *a, **k: None
L.vllm_start = lambda *a, **k: None
L.probe = lambda *a, **k: None
from tools.cmd_rl import spar

_MODEL = os.environ.get("SPAR_MODEL", "v3b_536")
_THINK = int(os.environ.get("SPAR_THINK_BUDGET", "0"))  # >0: thinking ON for RED with that token budget (budget forcing)
_orig = spar.proxy_cmd


def _patched(token, cap, port, bport, extra):
    extra = [(_MODEL if x == "policy" else x) for x in extra]
    if _THINK > 0 and port == int(os.environ.get("SPAR_RED_PORT", "8122")):
        extra = [x for x in extra if x != "--local-no-think"]
        extra[extra.index("--local-think-budget") + 1] = str(_THINK)
    return _orig(token, cap, port, bport, extra)


spar.proxy_cmd = _patched

if __name__ == "__main__":
    spar.main()
