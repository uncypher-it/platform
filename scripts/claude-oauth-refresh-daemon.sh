#!/usr/bin/env bash
# Refresh host Claude OAuth credentials and sync them into the Compose-managed
# claude_credentials Docker volume used by backend/chat/codebase services.

set -euo pipefail

CLAUDE_HOME="${CLAUDE_HOME:-$HOME/.claude}"
CLAUDE_CLI="${CLAUDE_CLI:-claude}"
# Directory containing docker-compose.yml. The sync step runs `docker compose
# run ...` and must execute from the Compose project root. Do not rely on the
# process CWD: parameterize it so the daemon works when launched by systemd, by
# hand, or from any directory. Override per host with COMPOSE_DIR.
COMPOSE_DIR="${COMPOSE_DIR:-$HOME/uncypher}"
HOST_CREDENTIALS="${CLAUDE_HOME}/.credentials.json"
REFRESH_WINDOW_SECONDS="${CLAUDE_REFRESH_WINDOW_SECONDS:-1800}"
MIN_SLEEP_SECONDS="${CLAUDE_REFRESH_MIN_SLEEP_SECONDS:-300}"
MAX_SLEEP_SECONDS="${CLAUDE_REFRESH_MAX_SLEEP_SECONDS:-3600}"
FAIL_SLEEP_SECONDS="${CLAUDE_REFRESH_FAIL_SLEEP_SECONDS:-120}"

log() {
  printf '[%s] %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*"
}

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    log "missing required command: $1"
    exit 1
  fi
}

credentials_seconds_until_expiry() {
  if [ ! -f "$HOST_CREDENTIALS" ]; then
    echo 0
    return
  fi

  python3 - "$HOST_CREDENTIALS" <<'PY'
import json
import sys
import time

path = sys.argv[1]
try:
    with open(path, "r", encoding="utf-8") as handle:
        payload = json.load(handle)
    expires_at = int(payload.get("expiresAt") or payload.get("expires_at") or 0)
except Exception:
    print(0)
    raise SystemExit(0)

if expires_at > 10_000_000_000:
    expires_at = expires_at / 1000

print(max(0, int(expires_at - time.time())))
PY
}

refresh_host_credentials() {
  if [ "${CLAUDE_SKIP_HOST_REFRESH:-0}" = "1" ]; then
    log "skipping host refresh because CLAUDE_SKIP_HOST_REFRESH=1"
    return 0
  fi

  log "refreshing host Claude OAuth credentials"
  "$CLAUDE_CLI" --print --max-turns 1 "Return exactly: ok" >/dev/null
}

sync_credentials_to_volume() {
  if [ ! -s "$HOST_CREDENTIALS" ]; then
    log "host credentials missing at ${HOST_CREDENTIALS}; run 'claude login' on the host first"
    return 1
  fi

  if ! cd "$COMPOSE_DIR" 2>/dev/null; then
    log "compose dir not found at ${COMPOSE_DIR}; set COMPOSE_DIR to the directory containing docker-compose.yml"
    return 1
  fi

  log "syncing host credentials into claude_credentials volume (compose dir: ${COMPOSE_DIR})"
  docker compose run --rm --no-deps \
    --volume "${CLAUDE_HOME}:/host-claude:ro" \
    --entrypoint sh \
    backend \
    -c 'set -eu
        umask 077
        test -s /host-claude/.credentials.json
        mkdir -p /root/.claude
        cp /host-claude/.credentials.json /root/.claude/.credentials.json.tmp
        mv /root/.claude/.credentials.json.tmp /root/.claude/.credentials.json
        chmod 600 /root/.claude/.credentials.json'
}

sleep_interval_for() {
  local seconds_until_expiry="$1"
  local next_sleep

  if [ "$seconds_until_expiry" -le "$REFRESH_WINDOW_SECONDS" ]; then
    next_sleep="$MIN_SLEEP_SECONDS"
  else
    next_sleep=$((seconds_until_expiry - REFRESH_WINDOW_SECONDS))
    if [ "$next_sleep" -lt "$MIN_SLEEP_SECONDS" ]; then
      next_sleep="$MIN_SLEEP_SECONDS"
    fi
    if [ "$next_sleep" -gt "$MAX_SLEEP_SECONDS" ]; then
      next_sleep="$MAX_SLEEP_SECONDS"
    fi
  fi

  echo "$next_sleep"
}

main() {
  require_command docker
  require_command python3
  require_command "$CLAUDE_CLI"

  while true; do
    seconds_until_expiry="$(credentials_seconds_until_expiry)"

    if [ "$seconds_until_expiry" -le "$REFRESH_WINDOW_SECONDS" ]; then
      if ! refresh_host_credentials; then
        log "host refresh failed; preserving existing Docker-volume credentials"
        sleep "$FAIL_SLEEP_SECONDS"
        continue
      fi
      seconds_until_expiry="$(credentials_seconds_until_expiry)"
    fi

    if ! sync_credentials_to_volume; then
      log "credential sync failed; retrying soon"
      sleep "$FAIL_SLEEP_SECONDS"
      continue
    fi

    if [ "${CLAUDE_REFRESH_ONCE:-0}" = "1" ]; then
      log "CLAUDE_REFRESH_ONCE=1 set; exiting after successful sync"
      exit 0
    fi

    next_sleep="$(sleep_interval_for "$seconds_until_expiry")"
    log "credentials synced; expires in ${seconds_until_expiry}s; sleeping ${next_sleep}s"
    sleep "$next_sleep"
  done
}

main "$@"
