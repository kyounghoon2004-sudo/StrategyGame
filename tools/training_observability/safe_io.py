"""Read-only access to live producer artifacts + guarded writes to our outputs.

Windows file-sharing risk: the marathon replaces state files with
tmp + os.replace. A plain Python open() does NOT pass FILE_SHARE_DELETE, so a
reader that happens to hold the target open makes that os.replace fail inside
the marathon. On Windows every read here goes through CreateFileW with
GENERIC_READ and FILE_SHARE_READ|FILE_SHARE_WRITE|FILE_SHARE_DELETE, so our
handle can never block a replace/rename/delete. Handles are opened, read in
full and closed immediately. No locks, no watchers, no polling.

Every read goes through ReadOnlySource; any attempt to open in a write mode
raises ReadOnlyViolation. Writes go only through OutputWriter, which refuses
any path under a protected (producer) root.
"""
from __future__ import annotations

import json
import os
import sys
import time
from pathlib import Path
from typing import Any, Iterable, List, Optional

WRITE_MODE_CHARS = set("wax+")


class ReadOnlyViolation(RuntimeError):
    pass


class ProtectedPathViolation(RuntimeError):
    pass


class UnreadableJSON(ValueError):
    """JSON could not be parsed after retries (possibly mid-write)."""


def _check_mode(mode: str) -> None:
    if set(mode) & WRITE_MODE_CHARS:
        raise ReadOnlyViolation(f"write mode {mode!r} refused on a read-only source")


if sys.platform == "win32":
    import ctypes
    import msvcrt
    from ctypes import wintypes

    _k32 = ctypes.WinDLL("kernel32", use_last_error=True)
    _k32.CreateFileW.restype = wintypes.HANDLE
    _k32.CreateFileW.argtypes = [wintypes.LPCWSTR, wintypes.DWORD, wintypes.DWORD,
                                 wintypes.LPVOID, wintypes.DWORD, wintypes.DWORD,
                                 wintypes.HANDLE]
    _GENERIC_READ = 0x80000000
    _SHARE_ALL = 0x1 | 0x2 | 0x4  # READ | WRITE | DELETE
    _OPEN_EXISTING = 3
    _FILE_ATTRIBUTE_NORMAL = 0x80
    _INVALID = wintypes.HANDLE(-1).value

    def _open_shared_fd(path: str) -> int:
        h = _k32.CreateFileW(str(path), _GENERIC_READ, _SHARE_ALL, None,
                             _OPEN_EXISTING, _FILE_ATTRIBUTE_NORMAL, None)
        if h == _INVALID or h is None:
            err = ctypes.get_last_error()
            if err in (2, 3):
                raise FileNotFoundError(2, "No such file", str(path))
            if err == 5:
                raise PermissionError(13, "Access denied", str(path))
            raise OSError(err, f"CreateFileW failed ({err})", str(path))
        return msvcrt.open_osfhandle(h, os.O_RDONLY | os.O_BINARY)
else:  # pragma: no cover - non-Windows fallback
    def _open_shared_fd(path: str) -> int:
        return os.open(path, os.O_RDONLY)


class _SharedReadHandle:
    """Context manager exposing a binary read-only file object (tests use it to
    prove a concurrent os.replace still succeeds while our handle is open)."""

    def __init__(self, path: Path):
        self.path = path
        self._f = None

    def __enter__(self):
        fd = _open_shared_fd(str(self.path))
        self._f = os.fdopen(fd, "rb")
        return self._f

    def __exit__(self, *exc):
        if self._f is not None:
            self._f.close()
        return False


class ReadOnlySource:
    """All reads of producer artifacts go through this object."""

    def __init__(self, retries: int = 3, retry_delay_s: float = 0.25):
        self.retries = retries
        self.retry_delay_s = retry_delay_s
        self.read_count = 0
        self.read_paths: List[str] = []

    def open(self, path, mode: str = "rb"):
        _check_mode(mode)
        if "b" not in mode:
            raise ReadOnlyViolation("use read_text/read_json for text access")
        return _SharedReadHandle(Path(path))

    def read_bytes(self, path) -> bytes:
        last: Optional[BaseException] = None
        for attempt in range(self.retries):
            try:
                with self.open(path, "rb") as f:
                    data = f.read()
                self.read_count += 1
                self.read_paths.append(str(path))
                return data
            except FileNotFoundError:
                raise
            except PermissionError as e:  # transient sharing violation
                last = e
                time.sleep(self.retry_delay_s)
        raise last  # type: ignore[misc]

    def read_text(self, path, encoding: str = "utf-8") -> str:
        return self.read_bytes(path).decode(encoding, errors="replace")

    def read_json(self, path) -> Any:
        """Parse JSON, retrying briefly if caught mid atomic-replace/mid-write."""
        last: Optional[BaseException] = None
        for attempt in range(self.retries):
            try:
                raw = self.read_bytes(path)
                return json.loads(raw.decode("utf-8-sig"))
            except FileNotFoundError:
                raise
            except (ValueError, UnicodeDecodeError, PermissionError) as e:
                last = e
                time.sleep(self.retry_delay_s)
        raise UnreadableJSON(f"{path}: {last}")

    # directory listing is metadata only (no file handles on entries)
    @staticmethod
    def listdir(path) -> List[str]:
        try:
            return sorted(os.listdir(path))
        except FileNotFoundError:
            return []

    @staticmethod
    def exists(path) -> bool:
        return os.path.exists(path)

    @staticmethod
    def stat_sig(path) -> Optional[list]:
        try:
            st = os.stat(path)
            return [st.st_size, st.st_mtime_ns]
        except OSError:
            return None


def _is_under(path: Path, root: Path) -> bool:
    try:
        Path(os.path.abspath(path)).relative_to(Path(os.path.abspath(root)))
        return True
    except ValueError:
        return False


class OutputWriter:
    """The ONLY way this package writes files. Atomic (tmp + os.replace) on
    our own outputs; refuses anything under a protected producer root."""

    def __init__(self, output_root, protected_roots: Iterable):
        self.output_root = Path(os.path.abspath(output_root))
        self.protected_roots = [Path(os.path.abspath(p)) for p in protected_roots]
        for p in self.protected_roots:
            if _is_under(self.output_root, p):
                raise ProtectedPathViolation(
                    f"output root {self.output_root} lies inside protected {p}")
        self.written: List[str] = []

    def _check(self, path) -> Path:
        p = Path(os.path.abspath(path))
        for root in self.protected_roots:
            if _is_under(p, root):
                raise ProtectedPathViolation(f"refusing to write under protected root: {p}")
        if not _is_under(p, self.output_root):
            raise ProtectedPathViolation(f"refusing to write outside output root: {p}")
        return p

    def write_bytes(self, path, data: bytes) -> Path:
        p = self._check(path)
        p.parent.mkdir(parents=True, exist_ok=True)
        tmp = p.with_name(p.name + ".tmp")
        with open(tmp, "wb") as f:
            f.write(data)
        os.replace(tmp, p)
        self.written.append(str(p))
        return p

    def write_text(self, path, text: str) -> Path:
        return self.write_bytes(path, text.encode("utf-8"))

    def write_json(self, path, obj) -> Path:
        return self.write_text(path, json.dumps(obj, indent=1, sort_keys=True,
                                                ensure_ascii=False) + "\n")

    def read_own_json(self, path, default=None):
        p = self._check(path)
        if not p.exists():
            return default
        with open(p, "r", encoding="utf-8") as f:
            return json.load(f)
