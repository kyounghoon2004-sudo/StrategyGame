"""Blockade game with the RED commander answered from files (2026-10-16, cloud teacher play): spar --manual (BLUE = blockade_bot
over its manual dir) but the RED proxy parks every RED request in TEACHER_RED_DIR (req_NNNN.json -> resp_NNNN.txt) instead of
calling a model. No local model is used.
  TEACHER_RED_DIR=<dir> python -m tools.synth_adv_v1.spar_teacher --manual --per-model 1 --slot 10 --red-port 8250 ...
"""
import os
from tools.cmd_rl import loop as L
L.vllm_stop = lambda *a, **k: None
L.vllm_start = lambda *a, **k: None
L.probe = lambda *a, **k: None
from tools.cmd_rl import spar

_RED = int(os.environ["TEACHER_RED_PORT"])
_DIR = os.environ["TEACHER_RED_DIR"]
_orig = spar.proxy_cmd


def _patched(token, cap, port, bport, extra):
    if port == _RED:
        extra = ["--manual-dir", _DIR, "--manual-poll-s", "0.5"]
    return _orig(token, cap, port, bport, extra)


spar.proxy_cmd = _patched

if __name__ == "__main__":
    spar.main()
