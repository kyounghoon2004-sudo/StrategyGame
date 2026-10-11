"""(10) No production marathon file is modified.

Evidence = (a) the read-only helper refuses every write mode, (b) the output
writer refuses protected roots, (c) a full pipeline run over a temp copy makes
zero write-intent filesystem calls on the source roots (instrumented),
(d) tools/training_supervisor git status + mtimes unchanged, (e) this package
never imports the supervisor or its GPU lock manager.
Live artifacts are NOT hash-compared (they change legitimately).
"""
import builtins
import os
import shutil
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path

from tools.training_observability import audit_harness as A
from tools.training_observability.config import PACKAGE_DIR, PROJECT_ROOT, SUPERVISOR_CODE_DIR, Paths
from tools.training_observability.dataset_builder import run_dataset
from tools.training_observability.marathon_scan import LiveSnapshot
from tools.training_observability.metrics import run_metrics
from tools.training_observability.safe_io import (OutputWriter, ProtectedPathViolation, ReadOnlySource,
                                                  ReadOnlyViolation)
from tools.training_observability.tests._fixtures import all_files, fresh_workspace

GIT_ROOT = PROJECT_ROOT.parent
T_START = time.time()


def _git_status_supervisor():
    try:
        p = subprocess.run(["git", "-C", str(GIT_ROOT), "status", "--porcelain", "--",
                            str(SUPERVISOR_CODE_DIR.relative_to(GIT_ROOT)).replace("\\", "/")],
                           capture_output=True, text=True, timeout=60)
        return p.stdout
    except (OSError, subprocess.SubprocessError):
        return None


GIT_BEFORE = _git_status_supervisor()


class ReadOnlyTests(unittest.TestCase):
    def test_write_modes_refused(self):
        src = ReadOnlySource()
        f = Path(tempfile.mkdtemp()) / "x.json"
        f.write_text("{}", encoding="utf-8")
        for mode in ("w", "wb", "a", "ab", "r+", "rb+", "x", "w+b"):
            with self.assertRaises(ReadOnlyViolation, msg=mode):
                src.open(f, mode)
        self.assertEqual(src.read_json(f), {})
        self.assertEqual(f.read_text(encoding="utf-8"), "{}")

    def test_writer_refuses_protected_roots(self):
        real = Paths()
        w = OutputWriter(Path(tempfile.mkdtemp()) / "out", real.protected_roots)
        for target in (real.marathon_root / "MARATHON_STATE.json",
                       real.marathon_root / "iterations" / "iteration_000001" / "x.json",
                       SUPERVISOR_CODE_DIR / "x.py", Path(r"D:\StrategyAI\locks\training_marathon_v1.lock"),
                       Path(tempfile.gettempdir()) / "elsewhere.json"):
            with self.assertRaises(ProtectedPathViolation, msg=str(target)):
                w.write_text(target, "x")
        with self.assertRaises(ProtectedPathViolation):
            OutputWriter(real.marathon_root / "sub", real.protected_roots)
        self.assertFalse((real.marathon_root / "iterations" / "iteration_000001" / "x.json").exists())

    @unittest.skipUnless(sys.platform == "win32", "Windows share-mode semantics")
    def test_windows_share_semantics_documented(self):
        """Pins the real Windows behaviour the design relies on:
        * our share-all handle does NOT block a producer APPEND (marathon.log,
          phase.log) - FILE_SHARE_WRITE;
        * ANY open handle (ours included) DOES block os.replace onto the target,
          which is why live state files are read once, instantly, and skipped
          while the producer's .tmp sibling exists (see next test)."""
        d = Path(tempfile.mkdtemp())
        log = d / "marathon.log"
        log.write_bytes(b"a;")
        with ReadOnlySource().open(log) as f:
            with open(log, "ab") as w:
                w.write(b"b;")
            self.assertEqual(f.read(), b"a;b;")
        self.assertEqual(log.read_bytes(), b"a;b;")
        target, tmp = d / "S.json", d / "S.json.tmp"
        target.write_text('{"v": 1}', encoding="utf-8")
        tmp.write_text('{"v": 2}', encoding="utf-8")
        with ReadOnlySource().open(target):
            with self.assertRaises(PermissionError):
                os.replace(tmp, target)
        os.replace(tmp, target)  # handle closed -> replace fine
        self.assertEqual(target.read_text(encoding="utf-8"), '{"v": 2}')

    def test_live_snapshot_read_once_and_defers_to_producer_tmp(self):
        d = Path(tempfile.mkdtemp())
        (d / "MARATHON_STATE.json").write_text('{"champion_id": "T1"}', encoding="utf-8")
        (d / "CHAMPION_LINEAGE.json").write_text('{"records": []}', encoding="utf-8")
        (d / "CHAMPION_LINEAGE.json.tmp").write_text("{}", encoding="utf-8")
        snap = LiveSnapshot(ReadOnlySource(), d, tmp_wait_s=0.01, tmp_wait_tries=3)
        self.assertEqual(snap.get("MARATHON_STATE.json"), {"champion_id": "T1"})
        (d / "MARATHON_STATE.json").write_text('{"champion_id": "T2"}', encoding="utf-8")
        self.assertEqual(snap.get("MARATHON_STATE.json"), {"champion_id": "T1"}, "cached: read once")
        self.assertEqual(snap.src.read_count, 1)
        self.assertIsNone(snap.get("CHAMPION_LINEAGE.json"))
        self.assertIn("TMP_PRESENT", snap.errors["CHAMPION_LINEAGE.json"])
        self.assertEqual(snap.src.read_count, 1, "never opened while producer tmp exists")

    def test_pipeline_makes_no_write_calls_on_sources(self):
        base, paths = fresh_workspace()
        src_root = str(base / "src")
        before = all_files(base / "src")
        violations = []
        real_open, real_replace, real_remove = builtins.open, os.replace, os.remove
        real_unlink, real_rename, real_rmtree = os.unlink, os.rename, shutil.rmtree
        real_path_unlink = Path.unlink

        def under(p):
            return os.path.abspath(str(p)).startswith(src_root)

        def g_open(file, mode="r", *a, **k):
            if isinstance(file, (str, os.PathLike)) and under(file) and set(mode) & set("wax+"):
                violations.append(("open", str(file), mode))
            return real_open(file, mode, *a, **k)

        def g2(name, fn):
            def w(*a, **k):
                if any(isinstance(x, (str, os.PathLike)) and under(x) for x in a[:2]):
                    violations.append((name, [str(x) for x in a[:2]]))
                return fn(*a, **k)
            return w

        builtins.open = g_open
        os.replace, os.remove, os.unlink = g2("replace", real_replace), g2("remove", real_remove), g2("unlink", real_unlink)
        os.rename, shutil.rmtree = g2("rename", real_rename), g2("rmtree", real_rmtree)
        Path.unlink = g2("Path.unlink", real_path_unlink)
        try:
            run_metrics(paths)
            run_dataset(paths)
            A.prepare_audit_assets(paths, n_pairs=8, games_per_opponent=4)
        finally:
            builtins.open, os.replace, os.remove, os.unlink = real_open, real_replace, real_remove, real_unlink
            os.rename, shutil.rmtree, Path.unlink = real_rename, real_rmtree, real_path_unlink
        self.assertEqual(violations, [])
        self.assertEqual(all_files(base / "src"), before, "source copy must be byte/mtime identical")
        self.assertTrue((paths.metrics_dir / "TRAINING_METRICS.json").exists())

    def test_supervisor_code_untouched(self):
        changed = [p for p, (_, mt) in all_files(SUPERVISOR_CODE_DIR).items()
                   if mt / 1e9 > T_START and "__pycache__" not in p]
        self.assertEqual(changed, [])
        if GIT_BEFORE is not None:
            self.assertEqual(_git_status_supervisor(), GIT_BEFORE)

    def test_package_never_imports_supervisor_or_lock(self):
        for py in PACKAGE_DIR.rglob("*.py"):
            if py.parent.name == "tests":
                continue
            text = py.read_text(encoding="utf-8")
            self.assertNotIn("import tools.training_supervisor", text, py)
            self.assertNotIn("from tools.training_supervisor", text, py)
            self.assertNotIn("GpuLockManager", text, py)
            self.assertNotIn("import torch", text, py)
        self.assertNotIn("tools.training_supervisor", sys.modules)


if __name__ == "__main__":
    unittest.main()
