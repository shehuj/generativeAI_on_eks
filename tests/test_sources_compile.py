"""Smoke test: every Python source under the JARK stack must compile."""

import py_compile
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parents[1]
JARK_SRC = REPO_ROOT / "ai-ml" / "jark-stack" / "terraform" / "src"

_PY_FILES = sorted(p for p in JARK_SRC.rglob("*.py"))


def test_python_sources_present():
    assert _PY_FILES, f"expected Python sources under {JARK_SRC}"


@pytest.mark.parametrize("path", _PY_FILES, ids=lambda p: p.name)
def test_source_compiles(path):
    py_compile.compile(str(path), doraise=True)
