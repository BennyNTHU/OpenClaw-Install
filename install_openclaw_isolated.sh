#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_DIR="${HOME}/openclaw-container"
ENV_FILE="${PROJECT_DIR}/.env"
COMPOSE_FILE="${PROJECT_DIR}/docker-compose.yml"
OPENCLAW_IMAGE_DEFAULT="ghcr.io/openclaw/openclaw:latest"
TZ_DEFAULT="Asia/Tokyo"

log() {
  printf '\n[%s] %s\n' "$(date '+%F %T')" "$*"
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Missing required command: $1" >&2
    exit 1
  }
}

if [[ "${EUID}" -eq 0 ]]; then
  echo "Please run this script as your normal user, not root." >&2
  exit 1
fi

require_cmd curl
require_cmd openssl
require_cmd sudo
require_cmd tee
require_cmd dpkg
require_cmd apt-get
require_cmd systemctl

ADDED_TO_DOCKER_GROUP=0

if ! docker version >/dev/null 2>&1; then
  echo "Docker is not usable in this shell." >&2
  echo "Open a new shell, then verify:" >&2
  echo "  docker version" >&2
  echo "  docker compose version" >&2
  exit 1
fi

if ! docker compose version >/dev/null 2>&1; then
  echo "docker compose is not available." >&2
  exit 1
fi

echo "Docker is already installed and usable. Skipping Docker installation."

mkdir -p "${PROJECT_DIR}"

if [[ ! -f "${ENV_FILE}" ]]; then
  GATEWAY_TOKEN="$(openssl rand -hex 32)"
  cat > "${ENV_FILE}" <<EOF
OPENCLAW_IMAGE=${OPENCLAW_IMAGE_DEFAULT}
OPENCLAW_GATEWAY_TOKEN=${GATEWAY_TOKEN}
OPENCLAW_TZ=${TZ_DEFAULT}
EOF
  chmod 600 "${ENV_FILE}"
  log "Created ${ENV_FILE}"
else
  log "${ENV_FILE} already exists; keeping existing values."
fi

cat > "${COMPOSE_FILE}" <<'EOF'
services:
  openclaw-gateway:
    image: ${OPENCLAW_IMAGE}
    environment:
      HOME: /home/node
      TERM: xterm-256color
      TZ: ${OPENCLAW_TZ}
      OPENCLAW_GATEWAY_TOKEN: ${OPENCLAW_GATEWAY_TOKEN}
    volumes:
      - openclaw_home:/home/node
    ports:
      - "127.0.0.1:18789:18789"
      - "127.0.0.1:18790:18790"
    init: true
    restart: unless-stopped
    command:
      [
        "node",
        "dist/index.js",
        "gateway",
        "--bind",
        "lan",
        "--port",
        "18789"
      ]
    healthcheck:
      test:
        [
          "CMD",
          "node",
          "-e",
          "fetch('http://127.0.0.1:18789/healthz').then((r)=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))"
        ]
      interval: 30s
      timeout: 5s
      retries: 5
      start_period: 20s

  openclaw-cli:
    image: ${OPENCLAW_IMAGE}
    network_mode: "service:openclaw-gateway"
    cap_drop:
      - NET_RAW
      - NET_ADMIN
    security_opt:
      - no-new-privileges:true
    environment:
      HOME: /home/node
      TERM: xterm-256color
      TZ: ${OPENCLAW_TZ}
      BROWSER: echo
      OPENCLAW_GATEWAY_TOKEN: ${OPENCLAW_GATEWAY_TOKEN}
    volumes:
      - openclaw_home:/home/node
    stdin_open: true
    tty: true
    init: true
    entrypoint: ["node", "dist/index.js"]
    depends_on:
      - openclaw-gateway

volumes:
  openclaw_home:
EOF

log "Created ${COMPOSE_FILE}"

run_docker() {
  docker "$@"
}

cd "${PROJECT_DIR}"

log "Pulling OpenClaw image..."
run_docker compose pull

log "Running OpenClaw onboarding (interactive; you may be asked for provider API keys)..."
run_docker compose run --rm --no-deps --entrypoint node openclaw-gateway \
  dist/index.js onboard --mode local --no-install-daemon

log "Writing OpenClaw gateway config..."
run_docker compose run --rm --no-deps --entrypoint node openclaw-gateway \
  dist/index.js config set gateway.mode local

run_docker compose run --rm --no-deps --entrypoint node openclaw-gateway \
  dist/index.js config set gateway.bind lan

run_docker compose run --rm --no-deps --entrypoint node openclaw-gateway \
  dist/index.js config set gateway.controlUi.allowedOrigins \
  '["http://localhost:18789","http://127.0.0.1:18789"]' --strict-json

log "Starting OpenClaw gateway..."
run_docker compose up -d openclaw-gateway

log "Waiting for health check..."
for _ in $(seq 1 30); do
  if curl -fsS http://127.0.0.1:18789/healthz >/dev/null 2>&1; then
    HEALTH_OK=1
    break
  fi
  sleep 2
done

if [[ "${HEALTH_OK:-0}" -ne 1 ]]; then
  echo
  echo "Gateway did not become healthy in time."
  echo "Check logs with:"
  echo "  cd ${PROJECT_DIR} && docker compose logs -f openclaw-gateway"
  exit 1
fi

echo
echo "============================================================"
echo "OpenClaw is up."
echo "Control UI: http://127.0.0.1:18789/"
echo "Project dir: ${PROJECT_DIR}"
echo
echo "Useful commands:"
echo "  cd ${PROJECT_DIR}"
echo "  docker compose ps"
echo "  docker compose logs -f openclaw-gateway"
echo "  docker compose run --rm openclaw-cli dashboard --no-open"
echo "  curl -fsS http://127.0.0.1:18789/healthz"
echo "  curl -fsS http://127.0.0.1:18789/readyz"
echo
echo "Isolation notes:"
echo "  - No host bind mounts are used."
echo "  - Data is stored only in Docker named volumes."
echo "  - docker.sock is NOT mounted."
echo "============================================================"
echo

if [[ "${ADDED_TO_DOCKER_GROUP}" -eq 1 ]]; then
  echo "Note: you were added to the docker group."
  echo "Open a NEW shell (or log out and log back in) before using docker without sudo."
fi
