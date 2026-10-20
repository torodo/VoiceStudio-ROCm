"""Docker quick starts must preserve the server-mode admin credential."""

import re
from pathlib import Path

import pytest


ROOT = Path(__file__).resolve().parents[1]


@pytest.mark.parametrize(
    "relative_path",
    ["docs/install/docker.md", "deploy/dockerhub-overview.md"],
)
def test_every_studio_docker_run_passes_the_admin_key(relative_path):
    text = (ROOT / relative_path).read_text(encoding="utf-8")
    commands = [
        block
        for block in re.findall(r"```bash\n(.*?)```", text, flags=re.DOTALL)
        if "docker run" in block
        and re.search(r"(?:omnivoice-studio|voicestudio):", block)
    ]

    assert commands
    for command in commands:
        assert '-e OMNIVOICE_API_KEY="$OMNIVOICE_API_KEY"' in command


def test_every_compose_studio_service_receives_the_admin_key():
    text = (ROOT / "deploy/docker-compose.yml").read_text(encoding="utf-8")
    studio_half = text.split("worker-gpu:", 1)[0]

    required_key = (
        "OMNIVOICE_API_KEY=${OMNIVOICE_API_KEY:?export a long random "
        "OMNIVOICE_API_KEY before starting a Studio profile}"
    )
    assert studio_half.count(required_key) == 4
    assert "OMNIVOICE_API_KEY=${OMNIVOICE_API_KEY:-}" not in studio_half


def test_server_mode_rejects_a_whitespace_admin_key(monkeypatch):
    from api.dependencies import validate_server_admin_key

    monkeypatch.setenv("OMNIVOICE_SERVER_MODE", "1")
    monkeypatch.setenv("OMNIVOICE_API_KEY", "   \t")

    with pytest.raises(RuntimeError, match="non-whitespace administrator key"):
        validate_server_admin_key()


def test_server_mode_allows_an_unset_or_nonblank_admin_key(monkeypatch):
    from api.dependencies import validate_server_admin_key

    monkeypatch.setenv("OMNIVOICE_SERVER_MODE", "1")
    monkeypatch.delenv("OMNIVOICE_API_KEY", raising=False)
    validate_server_admin_key()
    monkeypatch.setenv("OMNIVOICE_API_KEY", "real-secret")
    validate_server_admin_key()


def test_wsl_rocm_command_carries_the_complete_dxg_bridge():
    text = (ROOT / "docs/install/docker.md").read_text(encoding="utf-8")
    section = text.split("### AMD GPU on WSL2", 1)[1].split("###", 1)[0]

    for required in (
        "--device /dev/dxg",
        "/usr/lib/wsl/lib/libdxcore.so:/usr/lib/libdxcore.so",
        "/opt/rocm/lib/librocdxg.so:/usr/lib/librocdxg.so",
        "HSA_ENABLE_DXG_DETECTION=1",
        "--cap-add SYS_PTRACE",
        "--security-opt seccomp=unconfined",
    ):
        assert required in section
    # librocdxg 1.2.0 (the ROCm 7.2.x pairing) ships no dids.conf; mounting a
    # missing file makes Docker create a root-owned directory in its place.
    # The mount belongs to 1.2.1+ and is documented as such, not in the command.
    command = next(
        block
        for block in re.findall(r"```bash\n(.*?)```", section, flags=re.DOTALL)
        if "docker run" in block
    )
    assert "dids.conf" not in command
    assert "/opt/rocm/share/rocdxg/dids.conf:/usr/share/rocdxg/dids.conf" in section


def test_compose_wsl_rocm_service_carries_the_dxg_bridge():
    text = (ROOT / "deploy/docker-compose.yml").read_text(encoding="utf-8")
    service = text.split("  omnivoice-rocm-wsl:", 1)[1].split("\nvolumes:", 1)[0]

    for required in (
        'profiles: ["rocm-wsl"]',
        "image: ${VOICESTUDIO_ROCM_IMAGE:-ghcr.io/debpalash/voicestudio:stable-rocm}",
        "GPU_FLAVOR: rocm",
        "- /dev/dxg",
        "/usr/lib/wsl/lib/libdxcore.so:/usr/lib/libdxcore.so:ro",
        "/opt/rocm/lib/librocdxg.so:/usr/lib/librocdxg.so:ro",
        "HSA_ENABLE_DXG_DETECTION=1",
        "- SYS_PTRACE",
        "- seccomp=unconfined",
        '"127.0.0.1:3900:3900"',
    ):
        assert required in service
    assert "/dev/kfd" not in service
    assert "- /opt/rocm/share/rocdxg/dids.conf" not in service


def test_wsl_rocm_launcher_drives_the_wsl_profile_without_leaking_the_key():
    script = (ROOT / "scripts/wsl-rocm.sh").read_text(encoding="utf-8")
    launcher = (ROOT / "scripts/wsl-rocm.ps1").read_text(encoding="utf-8")

    assert "--profile rocm-wsl" in script
    assert 'CONTAINER="omnivoice-studio-rocm-wsl"' in script
    assert "container_name: omnivoice-studio-rocm-wsl" in (
        ROOT / "deploy/docker-compose.yml"
    ).read_text(encoding="utf-8")
    # The key stays on the distribution's filesystem, owner-only, and is only
    # printed on an explicit `key --show`.
    assert 'ENV_FILE="${VOICESTUDIO_ENV_FILE:-$HOME/.voicestudio.env}"' in script
    assert "umask 077" in script and 'chmod 600 "$ENV_FILE"' in script
    assert script.count("printf '%s\\n' \"$key\"") == 1
    assert 'if [ "${1:-}" = "--show" ]; then' in script
    assert "wsl-rocm.sh" in launcher
    # Engine installs go through the container's own loopback (the only place
    # the one-click installer accepts them) instead of loosening that gate.
    assert 'docker exec "$CONTAINER" curl' in script
    assert "http://localhost:3900/engines/sidecar/${engine}/install" in script
    assert 'LOCAL_IMAGE="voicestudio-rocm:local"' in script
    assert "'build', 'install'" in launcher


def test_wsl_rocm_setup_pins_match_the_rocm_image():
    """The host ROCm and librocdxg must pair with the image's ROCm release.

    librocdxg 1.2.0 is AMD's pairing for ROCm 7.2.x; 1.2.1+ targets ROCm 7.13+.
    Moving the image's ROCm base without bumping the WSL setup would leave
    Windows users with a bridge the container runtime cannot load.
    """
    workflow = (ROOT / ".github/workflows/docker.yml").read_text(encoding="utf-8")
    image_rocm = re.search(r"BASE_IMAGE=rocm/pytorch:rocm(\d+\.\d+\.\d+)_", workflow)
    assert image_rocm, "ROCm base image pin not found in docker.yml"

    script = (ROOT / "scripts/wsl-rocm-setup.sh").read_text(encoding="utf-8")
    host_rocm = re.search(r'^ROCM_VERSION="([\d.]+)"', script, flags=re.M).group(1)
    rocdxg = re.search(r'^ROCDXG_VERSION="([\d.]+)"', script, flags=re.M).group(1)
    deb = re.search(r'^AMDGPU_INSTALL_DEB="([^"]+)"', script, flags=re.M).group(1)

    assert host_rocm == image_rocm.group(1)
    assert deb.startswith(f"amdgpu-install_{host_rocm}.")

    # AMD's sidecar wheels link the image's /opt/rocm, and the local build
    # must start from the same base the published image does.
    compose = (ROOT / "deploy/docker-compose.yml").read_text(encoding="utf-8")
    service = compose.split("  omnivoice-rocm-wsl:", 1)[1].split("\nvolumes:", 1)[0]
    assert (
        "OMNIVOICE_ROCM_FIND_LINKS=https://repo.radeon.com/rocm/manylinux/"
        f"rocm-rel-{host_rocm}/"
    ) in service
    base = re.search(r"BASE_IMAGE=(rocm/pytorch:\S+)", workflow).group(1)
    assert f"BASE_IMAGE: {base}" in service
    if tuple(map(int, host_rocm.split(".")[:2])) < (7, 13):
        assert rocdxg == "1.2.0"
        assert "HSA_ENABLE_DXG_DETECTION=1" in script


def test_wsl_rocm_matrix_marks_rx_6700_xt_unverified():
    text = (ROOT / "docs/install/docker.md").read_text(encoding="utf-8")
    section = text.split("#### WSL2 architecture compatibility matrix", 1)[1].split(
        "###", 1
    )[0]

    for classification in (
        "Supported",
        "Best-effort override",
        "Unverified",
        "Unsupported",
    ):
        assert f"| **{classification}** |" in section

    rx_row = next(line for line in section.splitlines() if "RX 6700 XT" in line)
    assert "`gfx1031`" in rx_row
    assert "**Unverified**" in rx_row
    assert "`gfx1030`" in rx_row
    assert "`/dev/dxg` alone is not proof of acceleration" in section
    assert "CPU fallback stage and reason" in section
    assert "CPU-only completion" in section
    assert "successful GPU validation" in section
