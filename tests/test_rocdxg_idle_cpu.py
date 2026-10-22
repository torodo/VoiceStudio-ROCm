"""AMD on WSL2 must not keep two extra CPU cores busy after torch.compile.

ROCDXG has no GPU interrupts, and ROCm 7.2.x's HSA runtime answers that by
keeping two ``AsyncEventsLoop`` threads busy-polling at 100% each in every
process that initialises HIP, for that process's whole life. Inductor's
compile pool started a sidecar that initialised HIP only to cache device
properties, so a ROCm-WSL backend that had preloaded its compiled TTS model
sat at 400% CPU while idle (measured: 200% in uvicorn + 200% in
``torch/_inductor/compile_worker``) instead of 200%. One compile thread keeps
compilation in-process and spawns no sidecar.
"""
from __future__ import annotations

import importlib
import os
import subprocess
import sys
from pathlib import Path

import pytest

_BACKEND = Path(__file__).resolve().parent.parent / "backend"
_KEY = "TORCHINDUCTOR_COMPILE_THREADS"


def _caps():
    """Resolved per call: other suites purge ``sys.modules`` (see #1425)."""
    return importlib.import_module("core.device_caps")


def _host(monkeypatch, *present: str) -> None:
    monkeypatch.setattr("core.device_caps.os.path.exists", lambda path: path in present)


@pytest.fixture
def linux(monkeypatch):
    monkeypatch.setattr(sys, "platform", "linux")


def test_wsl_container_keeps_compilation_in_process(linux, monkeypatch):
    _host(monkeypatch, "/dev/dxg", "/usr/lib/libdxcore.so", "/usr/lib/librocdxg.so")
    assert _caps().rocdxg_env_defaults() == {_KEY: "1"}


def test_backend_run_directly_in_wsl_is_matched(linux, monkeypatch):
    _host(monkeypatch, "/dev/dxg", "/opt/rocm/lib/librocdxg.so")
    assert _caps().is_rocdxg_host()


@pytest.mark.parametrize(
    "present",
    [
        pytest.param(("/dev/kfd", "/dev/dri", "/usr/lib/librocdxg.so"), id="native-rocm"),
        pytest.param(("/dev/dxg",), id="nvidia-on-wsl"),
        pytest.param((), id="no-gpu"),
    ],
)
def test_other_linux_hosts_keep_the_compile_pool(linux, monkeypatch, present):
    _host(monkeypatch, *present)
    assert _caps().rocdxg_env_defaults() == {}


@pytest.mark.parametrize("platform", ["win32", "darwin"])
def test_non_linux_hosts_are_never_rocdxg(monkeypatch, platform):
    monkeypatch.setattr(sys, "platform", platform)
    _host(monkeypatch, "/dev/dxg", "/usr/lib/librocdxg.so")
    assert not _caps().is_rocdxg_host()


_IMPORT_MAIN_ON_ROCDXG = f"""
import os, sys
sys.path.insert(0, {str(_BACKEND)!r})
import core.device_caps as caps
caps.is_rocdxg_host = lambda: True
import main
print("RESULT=" + os.environ.get({_KEY!r}, "<unset>"))
"""


@pytest.mark.parametrize(("preset", "expected"), [(None, "1"), ("4", "4")])
def test_main_applies_the_default_and_keeps_user_values(preset, expected):
    """Import-time contract, so it runs in a fresh interpreter: ``main`` is
    imported once per test session and torch reads the variable at import."""
    env = os.environ.copy()
    env.pop(_KEY, None)
    if preset is not None:
        env[_KEY] = preset
    proc = subprocess.run(
        [sys.executable, "-c", _IMPORT_MAIN_ON_ROCDXG],
        capture_output=True,
        text=True,
        env=env,
        timeout=300,
    )
    assert proc.returncode == 0, proc.stderr[-2000:]
    assert f"RESULT={expected}" in proc.stdout.splitlines()
