#!/usr/bin/env bash
# Prepare a WSL2 Ubuntu distribution so an AMD Radeon GPU can run VoiceStudio's
# ROCm image (ghcr.io/debpalash/voicestudio:*-rocm) through AMD's ROCDXG bridge.
#
# Run it INSIDE the WSL distribution (Ubuntu 24.04 or 22.04), not in Windows:
#   bash scripts/wsl-rocm-setup.sh                 # ROCm runtime + librocdxg
#   bash scripts/wsl-rocm-setup.sh --with-docker   # ...plus Docker Engine in WSL
#   bash scripts/wsl-rocm-setup.sh --full          # ...plus the full ROCm SDK
#   bash scripts/wsl-rocm-setup.sh --check         # verify only, change nothing
#   bash scripts/wsl-rocm-setup.sh --check-docker  # verify torch sees the GPU in the image
#
# Windows prerequisites (the script cannot do these): AMD Software Adrenalin
# 26.2.2 or newer (the first driver with ROCDXG support) and a current WSL
# (`wsl --update` from PowerShell). Supported cards are listed in AMD's librocdxg
# compatibility matrix: https://github.com/ROCm/librocdxg#wsl-compatibility-matrix
#
# Versions are pinned together: the ROCm image ships ROCm 7.2.x, which pairs
# with librocdxg 1.2.0. librocdxg 1.2.1+ targets ROCm 7.13+, so bump all three
# only when the image moves to a newer ROCm. See docs/install/docker.md.
set -euo pipefail

ROCM_VERSION="7.2.4"
AMDGPU_INSTALL_DEB="amdgpu-install_7.2.4.70204-1_all.deb"
AMDGPU_INSTALL_SHA256_NOBLE="53c7ec5cace439f1ea97efebd59a3b32aa288c5c0bf76f57ab3cd7159dd98fad"
AMDGPU_INSTALL_SHA256_JAMMY="8015fe26d513bb1b2e355718119184cd81ad7cb0dedc232aaffa89557d65f4d2"
ROCDXG_VERSION="1.2.0"
ROCDXG_SHA256="3ed9526719290cd8f590150dad8ea0f234fa779bea6a4c9a8449d7ae6b8cfb6e"
IMAGE="${VOICESTUDIO_ROCM_IMAGE:-ghcr.io/debpalash/voicestudio:stable-rocm}"
BASHRC_MARKER="# >>> voicestudio wsl-rocm >>>"

mode="install"
with_docker=0
full=0
for arg in "$@"; do
  case "$arg" in
    --check) mode="check" ;;
    --check-docker) mode="check-docker" ;;
    --with-docker) with_docker=1 ;;
    --full) full=1 ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    *) echo "unknown option: $arg" >&2; exit 2 ;;
  esac
done

say() { printf '\n==> %s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }
stamp() { date +%Y%m%d-%H%M%S; }

backup() {
  # Timestamped copy before touching any file outside the repository.
  local f="$1" dest
  if [ -e "$f" ]; then
    dest="$f.bak-$(stamp)"
    sudo cp -a "$f" "$dest"
    echo "backup: $dest"
  fi
}

preflight() {
  grep -qi microsoft /proc/sys/kernel/osrelease 2>/dev/null \
    || die "not running inside WSL2; on native Linux use the --device /dev/kfd --device /dev/dri setup instead"
  [ -e /dev/dxg ] || die "/dev/dxg is missing: update WSL (wsl --update) and the AMD Windows driver"
  # shellcheck disable=SC1091
  . /etc/os-release
  case "${VERSION_CODENAME:-}" in
    noble|jammy) codename="$VERSION_CODENAME" ;;
    *) die "Ubuntu 24.04 (noble) or 22.04 (jammy) required, found ${PRETTY_NAME:-unknown}" ;;
  esac
}

check_rocminfo() {
  say "rocminfo (HSA_ENABLE_DXG_DETECTION=1)"
  [ -x /opt/rocm/bin/rocminfo ] || die "/opt/rocm/bin/rocminfo not found: run this script without --check first"
  [ -e /opt/rocm/lib/librocdxg.so ] || die "/opt/rocm/lib/librocdxg.so not found: librocdxg is not installed"
  local out
  if ! out="$(HSA_ENABLE_DXG_DETECTION=1 /opt/rocm/bin/rocminfo 2>&1)"; then
    printf '%s\n' "$out" | tail -20
    die "rocminfo failed: check the Adrenalin version (26.2.2+) and that the card is in the librocdxg matrix"
  fi
  local agents
  agents="$(printf '%s\n' "$out" | grep -E '^\s+Name:\s+gfx[0-9a-f]+' | awk '{print $2}' | sort -u)"
  printf '%s\n' "$out" | grep -E 'Marketing Name' | grep -vi 'cpu\|ryzen\|intel' | sed 's/^ */  /' || true
  [ -n "$agents" ] || die "rocminfo ran but listed no GPU agent"
  echo "GPU agents: $agents"
}

check_docker() {
  say "PyTorch inside $IMAGE"
  command -v docker >/dev/null || die "docker not found in this distribution (use --with-docker)"
  docker run --rm \
    --device /dev/dxg \
    -v /usr/lib/wsl/lib/libdxcore.so:/usr/lib/libdxcore.so:ro \
    -v /opt/rocm/lib/librocdxg.so:/usr/lib/librocdxg.so:ro \
    -e HSA_ENABLE_DXG_DETECTION=1 \
    --entrypoint python3 \
    "$IMAGE" -c '
import torch
ok = torch.cuda.is_available()
print("torch", torch.__version__, "hip", torch.version.hip)
print("gpu available:", ok, "count:", torch.cuda.device_count())
if ok:
    p = torch.cuda.get_device_properties(0)
    print("device:", p.name, getattr(p, "gcnArchName", "?"), round(p.total_memory / 2**30, 1), "GiB")
    print("compiled archs:", " ".join(torch.cuda.get_arch_list()))
    x = torch.randn(2048, 2048, device="cuda")
    print("matmul ok:", float((x @ x).abs().mean()) > 0)
raise SystemExit(0 if ok else 1)
'
}

if [ "$mode" = "check" ]; then preflight; check_rocminfo; exit 0; fi
if [ "$mode" = "check-docker" ]; then preflight; check_docker; exit 0; fi

preflight
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

say "Removing stale ROCm packages (pre-7.x stacks have no ROCDXG support)"
for list in /etc/apt/sources.list.d/rocm.list /etc/apt/sources.list.d/amdgpu.list \
            /etc/apt/sources.list.d/amdgpu-proprietary.list; do
  backup "$list"
done
stale="$(dpkg-query -W -f='${Package} ${Version}\n' 'rocm-core' 'amdgpu-install' 'hsa-runtime-rocr4wsl-amdgpu' 2>/dev/null \
  | awk -v want="$ROCM_VERSION" 'index($2, want) != 1 {print $1}' || true)"
if [ -n "$stale" ]; then
  # shellcheck disable=SC2086
  sudo apt-get purge -y $stale
else
  echo "nothing to remove"
fi

say "Installing the ROCm $ROCM_VERSION repository for $codename"
curl -fsSL -o "$tmp/amdgpu-install.deb" \
  "https://repo.radeon.com/amdgpu-install/${ROCM_VERSION}/ubuntu/${codename}/${AMDGPU_INSTALL_DEB}"
if [ "$codename" = "noble" ]; then sha="$AMDGPU_INSTALL_SHA256_NOBLE"; else sha="$AMDGPU_INSTALL_SHA256_JAMMY"; fi
echo "$sha  $tmp/amdgpu-install.deb" | sha256sum -c -
sudo apt-get install -y "$tmp/amdgpu-install.deb"
sudo apt-get update

say "Installing the ROCm runtime"
if [ "$full" = 1 ]; then
  # Full SDK for running VoiceStudio natively in this distro (no Docker).
  # --no-dkms: WSL has no amdgpu kernel module; the Windows driver serves the GPU.
  sudo amdgpu-install -y --usecase=rocm --no-dkms
else
  # Enough to verify the bridge with rocminfo; the image carries its own ROCm.
  sudo apt-get install -y rocminfo
fi

say "Installing librocdxg $ROCDXG_VERSION (WSL bridge)"
curl -fsSL -o "$tmp/rocdxg-roct.deb" \
  "https://github.com/ROCm/librocdxg/releases/download/v${ROCDXG_VERSION}/rocdxg-roct_${ROCDXG_VERSION}_amd64.deb"
echo "${ROCDXG_SHA256}  $tmp/rocdxg-roct.deb" | sha256sum -c -
sudo apt-get install -y "$tmp/rocdxg-roct.deb"
sudo ldconfig

say "Shell environment (~/.bashrc)"
if grep -qF "$BASHRC_MARKER" "$HOME/.bashrc" 2>/dev/null; then
  echo "already configured"
else
  cp -a "$HOME/.bashrc" "$HOME/.bashrc.bak-$(stamp)"
  cat >> "$HOME/.bashrc" <<EOF

$BASHRC_MARKER
# ROCm < 7.13 loads the WSL bridge only with this opt-in (librocdxg README).
export HSA_ENABLE_DXG_DETECTION=1
export PATH="/opt/rocm/bin:\$PATH"
# <<< voicestudio wsl-rocm <<<
EOF
  echo "added HSA_ENABLE_DXG_DETECTION=1 and /opt/rocm/bin to ~/.bashrc"
fi

if [ "$with_docker" = 1 ]; then
  say "Installing Docker Engine inside this distribution"
  # A native engine sees /dev/dxg and /opt/rocm directly, which the ROCDXG
  # container flags assume. Leave Docker Desktop's WSL integration off for
  # this distribution so the two CLIs do not compete.
  sudo apt-get install -y docker.io docker-compose-v2
  sudo usermod -aG docker "$USER"
  echo "open a new WSL shell (or run: newgrp docker) before using docker"
fi

check_rocminfo
say "Done. Next: bash scripts/wsl-rocm-setup.sh --check-docker, then"
echo "  docker compose -f deploy/docker-compose.yml --profile rocm-wsl up -d"
