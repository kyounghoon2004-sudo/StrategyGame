"""Discovery of marathon iterations and their persisted evidence.

COMPLETION RULE (discovered from marathon_runner.py, read-only):
  ITERATION_RESULT.json is the LAST file the runner writes for an iteration
  (finalize_iteration / record_skipped_no_signal), after lineage + all phase
  outputs. An iteration is COMPLETE iff
    * its directory is named iteration_NNNNNN, and
    * ITERATION_RESULT.json exists, parses as a JSON object, and its
      "iteration" equals NNNNNN and it carries a "decision".
  Anything else (including the in-progress iteration, whose rollout/train/
  eval files may still be written) is INCOMPLETE and is skipped: only its
  directory listing is observed, no file inside it is opened.
  ITERATION_RESULT.json is written with a plain open("w") (not atomic), so a
  parse failure is retried briefly and then treated as INCOMPLETE.
"""
from __future__ import annotations

import hashlib
import re
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Dict, List, Optional

from .safe_io import ReadOnlySource, UnreadableJSON

ITER_RE = re.compile(r"^iteration_(\d{6})$")
KNOWN_DECISIONS = ("PROMOTE", "REJECT", "SKIPPED_NO_SIGNAL")
TS_RE = re.compile(r"^(\d{2}):(\d{2}):(\d{2}) ")
START_RE = re.compile(r"TRAINING_MARATHON_V1 \w+ start")
DEVICE_RE = re.compile(r"device=(-?[\d.]+)GiB")
HOST_RE = re.compile(r"host_avail=(-?[\d.]+)GiB")
GUARD_RE = re.compile(r"FAILED_MEMORY_GUARD")


@dataclass
class IterationRef:
    number: int
    path: Path
    complete: bool
    reason: str = ""
    result: Optional[Dict[str, Any]] = None
    subdirs: List[str] = field(default_factory=list)


def discover_iterations(src: ReadOnlySource, marathon_root: Path) -> List[IterationRef]:
    it_root = Path(marathon_root) / "iterations"
    refs: List[IterationRef] = []
    for name in src.listdir(it_root):
        m = ITER_RE.match(name)
        if not m:
            continue
        n = int(m.group(1))
        d = it_root / name
        subdirs = [s for s in src.listdir(d) if (d / s).is_dir()]
        rp = d / "ITERATION_RESULT.json"
        if not src.exists(rp):
            refs.append(IterationRef(n, d, False, "NO_ITERATION_RESULT (in progress or aborted)",
                                     subdirs=subdirs))
            continue
        try:
            res = src.read_json(rp)
        except (UnreadableJSON, OSError) as e:
            refs.append(IterationRef(n, d, False, f"ITERATION_RESULT_UNREADABLE: {e}",
                                     subdirs=subdirs))
            continue
        if not isinstance(res, dict) or res.get("iteration") != n or "decision" not in res:
            refs.append(IterationRef(n, d, False, "ITERATION_RESULT_STRUCTURALLY_INVALID",
                                     subdirs=subdirs))
            continue
        refs.append(IterationRef(n, d, True, "", res, subdirs))
    return sorted(refs, key=lambda r: r.number)


def make_issue(kind: str, path, context: str, detail: str = "") -> dict:
    iid = hashlib.sha256(f"{kind}|{path}|{context}".encode("utf-8")).hexdigest()[:32]
    return {"issue_id": iid, "kind": kind, "path": str(path), "context": context,
            "detail": detail[:400]}


def try_read_json(src: ReadOnlySource, path: Path, issues: List[dict], context: str):
    """Read JSON; on failure append an issue and return None (never raises)."""
    if not src.exists(path):
        issues.append(make_issue("MISSING_FILE", path, context))
        return None
    try:
        return src.read_json(path)
    except (UnreadableJSON, OSError) as e:
        issues.append(make_issue("MALFORMED_JSON", path, context, str(e)))
        return None


def parse_phase_log(src: ReadOnlySource, path: Path) -> Dict[str, Any]:
    """Derive duration / memory / guard evidence from a phase.log.

    Timestamps are local HH:MM:SS without a date; duration is last line minus
    the LAST 'start' line (a retried phase appends to the same log), with a
    single midnight wrap handled. Negative producer sentinels (-1) ignored."""
    out: Dict[str, Any] = {"present": False, "starts": 0, "duration_s": None,
                           "device_gib_max": None, "host_avail_gib_min": None,
                           "guard_trips": 0, "fatal_lines": 0}
    if not src.exists(path):
        return out
    try:
        text = src.read_text(path)
    except OSError:
        return out
    out["present"] = True
    last_start = None
    last_ts = None
    dev, host = [], []
    for line in text.splitlines():
        m = TS_RE.match(line)
        ts = int(m.group(1)) * 3600 + int(m.group(2)) * 60 + int(m.group(3)) if m else None
        if START_RE.search(line):
            out["starts"] += 1
            last_start = ts
        if ts is not None and last_start is not None:
            last_ts = ts
        dev += [float(x) for x in DEVICE_RE.findall(line) if float(x) >= 0]
        host += [float(x) for x in HOST_RE.findall(line) if float(x) >= 0]
        if GUARD_RE.search(line):
            out["guard_trips"] += 1
        if "[FATAL]" in line:
            out["fatal_lines"] += 1
    if last_start is not None and last_ts is not None:
        d = last_ts - last_start
        if d < 0:
            d += 86400
        out["duration_s"] = d
    out["device_gib_max"] = max(dev) if dev else None
    out["host_avail_gib_min"] = min(host) if host else None
    return out


class LiveSnapshot:
    """Reads each live state file at most ONCE per process (open-read-close).

    On Windows ANY open handle on the target - even one with FILE_SHARE_DELETE -
    makes the producer's os.replace(tmp, target) fail (verified by test). So:
      * the file is read once, in a single sub-millisecond open/read/close;
      * if the producer's '<name>.tmp' sibling exists (a replace is imminent)
        we wait briefly and, if it persists, SKIP the read (value None,
        reason recorded) rather than race the producer;
      * no retries loop on these files beyond one re-read on a parse error.
    run_state.json is never read (its lineage duplicates CHAMPION_LINEAGE.json).
    """

    FILES = ("MARATHON_STATE.json", "CHAMPION_LINEAGE.json")

    def __init__(self, src: ReadOnlySource, marathon_root: Path, enabled: bool = True,
                 tmp_wait_s: float = 0.5, tmp_wait_tries: int = 6):
        self.src = ReadOnlySource(retries=2, retry_delay_s=0.2)
        self.root = Path(marathon_root)
        self.enabled = enabled
        self.tmp_wait_s = tmp_wait_s
        self.tmp_wait_tries = tmp_wait_tries
        self._cache: Dict[str, Any] = {}
        self.errors: Dict[str, str] = {}
        self.read_counts: Dict[str, int] = {}

    def get(self, name: str):
        assert name in self.FILES, name
        if name in self._cache:
            return self._cache[name]
        p = self.root / name
        tmp = p.with_name(p.name + ".tmp")
        value = None
        if not self.enabled:
            self.errors[name] = "LIVE_STATE_READ_DISABLED"
        elif not self.src.exists(p):
            self.errors[name] = "MISSING"
        else:
            for _ in range(self.tmp_wait_tries):
                if not self.src.exists(tmp):
                    break
                time.sleep(self.tmp_wait_s)
            if self.src.exists(tmp):
                self.errors[name] = "SKIPPED_PRODUCER_TMP_PRESENT (replace in progress)"
            else:
                try:
                    value = self.src.read_json(p)
                    self.read_counts[name] = self.src.read_count
                except (UnreadableJSON, OSError) as e:
                    self.errors[name] = str(e)[:300]
        self._cache[name] = value
        return value
