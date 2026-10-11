"""Shared test fixtures: a TEMP COPY of real persisted evidence.

The copy is made through ReadOnlySource (share-all read handles) and written
only into a temp directory. Live marathon artifacts are never written.
Adapter weights (train/candidate_*) are not copied (not needed, ~57 MB each).
"""
from __future__ import annotations

import atexit
import json
import os
import shutil
import tempfile
from functools import lru_cache
from pathlib import Path

from tools.training_observability.config import (HISTORICAL_ROOTS, MARATHON_ROOT, PROMPT_SRC,
                                                 Paths)
from tools.training_observability.marathon_scan import LiveSnapshot
from tools.training_observability.safe_io import ReadOnlySource

# REJECT, PROMOTE(B0->T0004), SKIPPED_NO_SIGNAL, REJECT(resumed?), REJECT, PROMOTE(T0004->T0018)
COPY_ITERATIONS = (1, 4, 5, 8, 17, 18)


def _copy_tree(src: ReadOnlySource, s: Path, d: Path, skip_dir_prefix=("candidate_",)):
    d.mkdir(parents=True, exist_ok=True)
    for name in src.listdir(s):
        sp, dp = s / name, d / name
        if sp.is_dir():
            if name.startswith(skip_dir_prefix):
                continue
            _copy_tree(src, sp, dp, skip_dir_prefix)
        else:
            dp.write_bytes(src.read_bytes(sp))


@lru_cache(maxsize=1)
def pristine_copy() -> Path:
    root = Path(tempfile.mkdtemp(prefix="obs_fixture_"))
    atexit.register(shutil.rmtree, root, True)
    src = ReadOnlySource()
    m = root / "training_marathon_v1"
    for n in COPY_ITERATIONS:
        name = f"iteration_{n:06d}"
        _copy_tree(src, MARATHON_ROOT / "iterations" / name, m / "iterations" / name)
    snap = LiveSnapshot(src, MARATHON_ROOT)  # once, with the producer-tmp guard
    for f in LiveSnapshot.FILES:
        v = snap.get(f)
        if v is not None:
            (m / f).write_text(json.dumps(v, indent=2), encoding="utf-8")
    if (MARATHON_ROOT / "marathon.log").exists():  # append-only log, never replaced
        (m / "marathon.log").write_bytes(src.read_bytes(MARATHON_ROOT / "marathon.log"))
    _copy_tree(src, MARATHON_ROOT / "logs", m / "logs")
    for k, v in HISTORICAL_ROOTS.items():
        _copy_tree(src, v, root / k, skip_dir_prefix=("candidate_", "adapter"))
    if PROMPT_SRC.exists():
        (root / "prompt").mkdir()
        (root / "prompt" / "bench_prompt_A.json").write_bytes(src.read_bytes(PROMPT_SRC))
    return root


def fresh_workspace() -> tuple:
    """Independent writable copy of the pristine fixture + empty output root."""
    base = Path(tempfile.mkdtemp(prefix="obs_ws_"))
    atexit.register(shutil.rmtree, base, True)
    shutil.copytree(pristine_copy(), base / "src")
    paths = Paths(marathon_root=base / "src" / "training_marathon_v1",
                  output_root=base / "out",
                  historical_roots={k: base / "src" / k for k in HISTORICAL_ROOTS},
                  prompt_src=base / "src" / "prompt" / "bench_prompt_A.json")
    return base, paths


def rmtree(p):
    shutil.rmtree(p, ignore_errors=True)


def all_files(root: Path):
    out = {}
    for dp, _, fns in os.walk(root):
        for f in fns:
            p = Path(dp) / f
            st = p.stat()
            out[str(p)] = (st.st_size, st.st_mtime_ns)
    return out
