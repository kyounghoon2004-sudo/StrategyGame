"""spar_8010 + a THINK proxy (same session token, port SPAR_THINK_PORT, budget SPAR_THINK_BUDGET): the relay shim sends the relay
turns of RED there (thinking ON, plan turns only), every other turn goes to the normal thinking-off RED proxy."""
import atexit, os, subprocess
from tools.cmd_rl import loop as L
L.VLLM_URL = "http://127.0.0.1:8010"
L.vllm_stop = lambda *a, **k: None
L.vllm_start = lambda *a, **k: None
L.probe = lambda *a, **k: None
from tools.cmd_rl import spar
from tools.contextual_brain import rl_vs_utility as RV

_MODEL = os.environ.get("SPAR_MODEL", "v3b_536")
_TP = int(os.environ["SPAR_THINK_PORT"])
_BUDGET = os.environ.get("SPAR_THINK_BUDGET", "9000")
_RED = int(os.environ.get("SPAR_RED_PORT", "8122"))
_orig = spar.proxy_cmd
_kids = []
atexit.register(lambda: [k.kill() for k in _kids])


def _patched(token, cap, port, bport, extra):
    extra = [(_MODEL if x == "policy" else x) for x in extra]
    if port == _RED and "--local-pass" not in extra:  # an empty/unusable answer must become {"orders": {}}, not a CMD_JSON fault
        extra = extra + ["--local-pass"]
    if port == _RED:
        capT = cap.parent / "red_think"
        capT.mkdir(parents=True, exist_ok=True)
        ex = [x for x in extra if x != "--local-no-think"]
        ex[ex.index("--local-think-budget") + 1] = _BUDGET
        ex[ex.index("--local-max-tokens") + 1] = "14000"
        _kids.append(subprocess.Popen(_orig(token, capT, _TP, _TP + 1000, ex), cwd=str(RV.ROOT),
                                      stdout=open(capT / "proxy.log", "a"), stderr=subprocess.STDOUT))
    return _orig(token, cap, port, bport, extra)


spar.proxy_cmd = _patched

if __name__ == "__main__":
    spar.main()
