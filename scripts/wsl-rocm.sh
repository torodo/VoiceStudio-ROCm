#!/usr/bin/env bash
# Start and stop VoiceStudio's ROCm backend inside WSL2 (compose profile
# `rocm-wsl`). Prepare the distribution once with scripts/wsl-rocm-setup.sh.
#
#   bash scripts/wsl-rocm.sh start     # create the API key on first run, start, wait until healthy
#   bash scripts/wsl-rocm.sh stop      # stop and remove the container (data volume kept)
#   bash scripts/wsl-rocm.sh restart
#   bash scripts/wsl-rocm.sh status    # container state and health
#   bash scripts/wsl-rocm.sh logs      # follow the backend logs (Ctrl+C to leave)
#   bash scripts/wsl-rocm.sh key       # copy the API key to the Windows clipboard
#   bash scripts/wsl-rocm.sh key --show  # print it instead
#   bash scripts/wsl-rocm.sh update    # pull the newest image, then restart
#
# The key lives in $VOICESTUDIO_ENV_FILE (default ~/.voicestudio.env), on the
# distribution's own filesystem with mode 600, never in the repository.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${VOICESTUDIO_ENV_FILE:-$HOME/.voicestudio.env}"
CONTAINER="omnivoice-studio-rocm-wsl"
URL="http://localhost:3900"
HEALTH_TIMEOUT="${VOICESTUDIO_HEALTH_TIMEOUT:-900}"

die() { printf 'error: %s\n' "$*" >&2; exit 1; }

compose() {
  docker compose --env-file "$ENV_FILE" -f "$ROOT/deploy/docker-compose.yml" \
    --profile rocm-wsl "$@"
}

ensure_docker() {
  command -v docker >/dev/null || die "docker not found: run bash scripts/wsl-rocm-setup.sh --with-docker"
  docker info >/dev/null 2>&1 \
    || die "the Docker daemon is not reachable (sudo systemctl start docker, or open a new WSL shell after joining the docker group)"
}

ensure_env_file() {
  if [ ! -s "$ENV_FILE" ]; then
    (umask 077; printf 'OMNIVOICE_API_KEY=%s\n' \
      "$(openssl rand -base64 32 | tr -d '/+=')" > "$ENV_FILE")
    echo "created $ENV_FILE with a new API key (bash scripts/wsl-rocm.sh key to copy it)"
  fi
  grep -q '^OMNIVOICE_API_KEY=..*' "$ENV_FILE" || die "$ENV_FILE has no OMNIVOICE_API_KEY line"
  chmod 600 "$ENV_FILE"
}

health() {
  docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' \
    "$CONTAINER" 2>/dev/null || echo "absent"
}

wait_healthy() {
  local waited=0 state
  printf 'waiting for the backend (first start downloads the image and models)'
  while [ "$waited" -lt "$HEALTH_TIMEOUT" ]; do
    state="$(health)"
    case "$state" in
      healthy) printf '\nready: %s\n' "$URL"; return 0 ;;
      unhealthy|exited|dead|absent)
        printf '\nbackend is %s; last log lines:\n' "$state"
        docker logs --tail 40 "$CONTAINER" 2>&1 || true
        return 1 ;;
    esac
    printf '.'; sleep 5; waited=$((waited + 5))
  done
  printf '\nstill starting after %ss; follow it with: bash scripts/wsl-rocm.sh logs\n' "$HEALTH_TIMEOUT"
  return 1
}

copy_key() {
  local key
  key="$(sed -n 's/^OMNIVOICE_API_KEY=//p' "$ENV_FILE" | head -1)"
  [ -n "$key" ] || die "no key in $ENV_FILE: run start first"
  if [ "${1:-}" = "--show" ]; then
    printf '%s\n' "$key"
  elif command -v clip.exe >/dev/null; then
    printf '%s' "$key" | clip.exe
    echo "API key copied to the Windows clipboard"
  else
    die "clip.exe not available (WSL interop off): use key --show"
  fi
}

cmd="${1:-start}"
shift || true
case "$cmd" in
  start)   ensure_docker; ensure_env_file; compose up -d; wait_healthy ;;
  stop)    ensure_docker
           # compose needs the key file to parse the profile; without it, the
           # container (if any) was not started by this script's compose call.
           if [ -s "$ENV_FILE" ]; then compose down; else docker rm -f "$CONTAINER" 2>/dev/null || true; fi ;;
  restart) ensure_docker; ensure_env_file; compose down; compose up -d; wait_healthy ;;
  status)  ensure_docker; echo "backend: $(health)"; compose ps ;;
  logs)    ensure_docker; docker logs -f --tail 100 "$CONTAINER" ;;
  key)     copy_key "${1:-}" ;;
  update)  ensure_docker; ensure_env_file; compose pull; compose up -d; wait_healthy ;;
  -h|--help|help) sed -n '2,16p' "$0" ;;
  *) die "unknown command: $cmd (start|stop|restart|status|logs|key|update)" ;;
esac
