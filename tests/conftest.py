"""Shared pytest fixtures for the JARK stack app tests.

The two app modules (``streamlit.py`` and ``dogbooth.py``) import heavy runtime
dependencies (Streamlit, Ray, Torch, diffusers, FastAPI). To keep the test suite
fast and runnable on a plain CI runner, we register lightweight stand-ins for
those packages in ``sys.modules`` *before* importing the modules under test, and
load each source file under a unique module name (so ``streamlit.py`` does not
clash with the real ``streamlit`` package).
"""

import importlib.util
import sys
from pathlib import Path
from unittest.mock import MagicMock

import pytest

REPO_ROOT = Path(__file__).resolve().parents[1]
SRC = REPO_ROOT / "ai-ml" / "jark-stack" / "terraform" / "src"

# Heavy third-party packages we never want to actually import during tests.
_STUBBED_PACKAGES = [
    "streamlit",
    "requests",
    "PIL",
    "PIL.Image",
    "torch",
    "ray",
    "ray.serve",
    "fastapi",
    "fastapi.responses",
    "diffusers",
]


def _install_stubs():
    for name in _STUBBED_PACKAGES:
        # setdefault so a real install (if present) is still overridden only when
        # absent is not what we want — we force the stub for determinism.
        sys.modules[name] = MagicMock(name=f"stub:{name}")


def _load_module(module_name: str, path: Path):
    spec = importlib.util.spec_from_file_location(module_name, path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[module_name] = module
    spec.loader.exec_module(module)
    return module


# Stubs must be in place before any module under test is imported.
_install_stubs()


@pytest.fixture(scope="session")
def streamlit_app():
    """The refactored Streamlit app module (loaded as a non-clashing name)."""
    return _load_module("jark_streamlit_app", SRC / "app" / "streamlit.py")


@pytest.fixture(scope="session")
def dogbooth_service():
    """The Ray Serve dogbooth service module."""
    return _load_module("jark_dogbooth_service", SRC / "service" / "dogbooth.py")
