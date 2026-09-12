"""Intelligent, Efficient, Adaptive Multi-Agent Strategy Orchestration for Codex."""

from __future__ import annotations

import sys
from pathlib import Path

__author__ = "Parsifal <zmw@izmw.me>"

try:
    if sys.version_info >= (3, 8):
        from importlib.metadata import PackageNotFoundError, version
    else:
        from importlib_metadata import PackageNotFoundError, version  # type: ignore

    __version__ = version("codex-flow")
except Exception:
    # Fallback to local VERSION file if present
    _pkg_dir = Path(__file__).resolve().parent
    _candidates = [
        _pkg_dir / "data" / "VERSION",
        _pkg_dir.parents[1] / "VERSION",
    ]
    __version__ = "unknown"
    for _c in _candidates:
        if _c.exists():
            __version__ = _c.read_text(encoding="utf-8").strip().lstrip("v")
            break
