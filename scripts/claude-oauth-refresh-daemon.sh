#!/usr/bin/env bash
# Keep the host's Claude OAuth chain alive, copy fresh credentials to the
# containers, and alert (Slack-compatible webhook) when the chain dies, the
# subscription hits a limit, or the copies drift. Design and runbook:
# claude-auth/README.md.
#
# A host holds up to three copies of the credentials:
#   host     $CLAUDE_HOME/.credentials.json  the chain owner; `claude login` writes it
#   volume   claude_credentials volume        /root/.claude in backend, celery-worker,
#                                             chat-consumer, codebase-claude-runner
#   config   $CLAUDE_CONFIG_SYNC_DIR          chat-consumer's CLAUDE_CONFIG_DIR (native
#                                             harness); only synced when the dir exists
#
# Each wake:
#   1. adopt the config copy when the consumer's CLI rotated the chain there first
#   2. call `claude --print` when the token is inside the refresh window (backing
#      off while the chain is dead), and classify the result:
#      ok | auth_dead | quota | access_disabled | error
#   3. copy the host credentials to every older copy, but only when they are valid
#      (decided by the credentials themselves, not by the CLI's exit code)
#   4. verify the config copy, alert on state changes, sleep
#
# Portable to macOS /bin/bash 3.2 (the tests) and Linux bash 5 (the target):
# no associative arrays, no GNU-only date flags; time and JSON go through python3.

set -euo pipefail

load_config() {
  CLAUDE_HOME="${CLAUDE_HOME:-$HOME/.claude}"
  CLAUDE_CLI="${CLAUDE_CLI:-claude}"
  # Directory containing docker-compose.yml; the volume sync runs from here.
  COMPOSE_DIR="${COMPOSE_DIR:-$HOME/uncypher}"
  HOST_CREDENTIALS="$CLAUDE_HOME/.credentials.json"
  CONFIG_SYNC_DIR="${CLAUDE_CONFIG_SYNC_DIR:-$COMPOSE_DIR/claude-config}"
  CONSUMER_CONTAINER="${CLAUDE_CONSUMER_CONTAINER:-uncypher-chat-consumer}"

  # Refresh early: inside the window, call the CLI every POLL seconds until the
  # host expiresAt advances. Outside it, sleep until it opens (clamped; the
  # hourly cap doubles as a heartbeat). The CLI only rotates within ~5 min of
  # expiry and every call is a (tiny) inference against the subscription, so
  # the window stays short: a few calls per 8 h token, all before it expires.
  REFRESH_WINDOW_SECONDS="${CLAUDE_REFRESH_WINDOW_SECONDS:-600}"
  POLL_SECONDS="${CLAUDE_REFRESH_POLL_SECONDS:-120}"
  MIN_SLEEP_SECONDS="${CLAUDE_REFRESH_MIN_SLEEP_SECONDS:-300}"
  MAX_SLEEP_SECONDS="${CLAUDE_REFRESH_MAX_SLEEP_SECONDS:-3600}"
  FAIL_SLEEP_SECONDS="${CLAUDE_REFRESH_FAIL_SLEEP_SECONDS:-120}"
  # While the chain is dead: wake often to notice a `claude login` quickly, but
  # only call the CLI again when the credentials change or after the re-probe
  # interval (in case the failure was misclassified).
  DEAD_POLL_SECONDS="${CLAUDE_REFRESH_DEAD_POLL_SECONDS:-60}"
  DEAD_REPROBE_SECONDS="${CLAUDE_REFRESH_DEAD_REPROBE_SECONDS:-1800}"
  CLI_TIMEOUT_SECONDS="${CLAUDE_CLI_TIMEOUT_SECONDS:-300}"
  SKIP_HOST_REFRESH="${CLAUDE_SKIP_HOST_REFRESH:-0}"
  RUN_ONCE="${CLAUDE_REFRESH_ONCE:-0}"

  ALERT_WEBHOOK_URL="${ALERT_WEBHOOK_URL:-}"
  ALERT_DEPLOYMENT_NAME="${ALERT_DEPLOYMENT_NAME:-$(uname -n 2>/dev/null || echo unknown-host)}"
  ALERT_REPEAT_SECONDS="${ALERT_REPEAT_SECONDS:-21600}"
  # Unrecognised errors are often transient; alert only after this many in a row.
  ERROR_ALERT_AFTER=3

  STATE_DIR="${CLAUDE_REFRESH_STATE_DIR:-$CLAUDE_HOME}"
  STATE_FILE="$STATE_DIR/claude-auth-refresh.state"
  LOG_FILE="${CLAUDE_REFRESH_LOG_FILE:-}"
  DAEMON_USER="$(id -un 2>/dev/null || echo "${USER:-the deploy user}")"
  CLI_PROMPT="Reply with exactly: ok"
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

log() {
  local line
  line="[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] $*"
  printf '%s\n' "$line"
  if [ -n "${LOG_FILE:-}" ]; then
    printf '%s\n' "$line" >>"$LOG_FILE" 2>/dev/null || true
  fi
}

# Tests pin the clock with CLAUDE_REFRESH_NOW (epoch seconds).
now_epoch() {
  if [ -n "${CLAUDE_REFRESH_NOW:-}" ]; then echo "$CLAUDE_REFRESH_NOW"; else date +%s; fi
}

# Tests that source this file may redefine this.
daemon_sleep() {
  sleep "$1"
}

fmt_duration() {
  local s="$1"
  if [ "$s" -lt 0 ]; then s=$((-s)); fi
  if [ "$s" -ge 86400 ]; then echo "$((s / 86400))d $((s % 86400 / 3600))h"
  elif [ "$s" -ge 3600 ]; then echo "$((s / 3600))h $((s % 3600 / 60))m"
  elif [ "$s" -ge 60 ]; then echo "$((s / 60))m"
  else echo "${s}s"; fi
}

# Keep only digits (and a leading minus); fall back to $2. Guards state-file reads.
int_or() {
  case "$1" in
    '' | *[!0-9-]*) echo "$2" ;;
    *) echo "$1" ;;
  esac
}

# python3 helper: credential parsing, CLI-output classification, JSON payloads.
# Run isolated (-I) so a stray json.py in the working directory is never imported.
IFS= read -r -d '' PY_HELPER <<'PY' || true
import hashlib, json, re, sys, time

def iso(sec):
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(sec))

def cred(path):
    # Prints "<expiresAt ms> <has both tokens 0|1> <fingerprint> <expiresAt ISO>".
    # The fingerprint is a sha256 prefix of the refresh token (of the whole file
    # when there is none): it changes on `claude login` and never reveals the secret.
    try:
        with open(path, "rb") as f:
            raw = f.read()
    except FileNotFoundError:
        print("-1 0 missing -"); return
    except OSError:
        print("-1 0 unreadable -"); return
    try:
        oauth = json.loads(raw.decode("utf-8")).get("claudeAiOauth") or {}
        exp = int(oauth.get("expiresAt") or 0)
        access = oauth.get("accessToken") or ""
        refresh = oauth.get("refreshToken") or ""
    except Exception:
        exp, access, refresh = -1, "", ""
    has = 1 if (access and refresh) else 0
    fp = hashlib.sha256(refresh.encode() if refresh else raw).hexdigest()[:12]
    print(exp, has, fp, iso(exp // 1000) if exp > 0 else "-")

# Ordered: the first family with a matching line wins.
PATTERNS = [
    ("access_disabled", ("disabled claude subscription access", "organization has disabled")),
    ("quota", ("hit your", "usage limit")),
    ("auth_dead", ("failed to authenticate", "oauth session expired", "could not be refreshed",
                   "invalid authentication credentials", "api error: 401", "oauth token has expired",
                   "invalid_grant", "please run /login", "not logged in")),
]
SECRETISH = re.compile(r"sk-ant-[A-Za-z0-9_-]+|[A-Za-z0-9_-]{40,}")

def classify(rc):
    # Prints "<status>|<one-line message>" for the CLI output on stdin.
    lines = [l.strip() for l in sys.stdin.read().splitlines() if l.strip()]
    status, line = ("ok" if rc == 0 else "error"), None
    if rc == 124:
        line = "claude CLI timed out"
    elif rc != 0:
        for name, needles in PATTERNS:
            hit = next((l for l in lines if any(n in l.lower() for n in needles)), None)
            if hit:
                status, line = name, hit
                break
    if line is None:
        line = lines[-1] if lines else "(no output, rc=%d)" % rc
    print("%s|%s" % (status, SECRETISH.sub("<redacted>", line)[:300]))

cmd = sys.argv[1]
if cmd == "cred":
    cred(sys.argv[2])
elif cmd == "classify":
    classify(int(sys.argv[2]))
elif cmd == "payload":
    print(json.dumps({"text": sys.stdin.read()}))
elif cmd == "iso":
    print(iso(int(sys.argv[2])))
PY

py() {
  python3 -I -c "$PY_HELPER" "$@"
}

# Always prints four fields, even if python fails.
cred_fields() {
  py cred "$1" 2>/dev/null || echo "-1 0 error -"
}

iso_of() {
  py iso "$1" 2>/dev/null || echo "@$1"
}

last_line_of() {
  { grep -v '^[[:space:]]*$' "$1" 2>/dev/null || true; } | tail -n 1 | cut -c1-200
}

# ---------------------------------------------------------------------------
# State (small key=value file; parsed, never sourced)
# ---------------------------------------------------------------------------

state_load() {
  ST_CLI_STATUS=ok      # last CLI classification, carried forward between calls
  ST_DETAIL=""          # its one-line message
  ST_OUTAGE_SINCE=0     # epoch of the first failing wake of the current outage
  ST_ALERTED=""         # status we last alerted for ("" = nothing outstanding)
  ST_LAST_ALERT=0
  ST_ERROR_STREAK=0
  ST_DEAD_FP=""         # fingerprint of the credentials that died
  ST_LAST_PROBE=0       # epoch of the last CLI call
  ST_VOLUME_EXP=-1      # host expiresAt last synced into the volume (-1 = unknown)
  if [ ! -f "$STATE_FILE" ]; then return 0; fi
  local key value
  while IFS='=' read -r key value; do
    case "$key" in
      cli_status) ST_CLI_STATUS="$value" ;;
      detail) ST_DETAIL="$value" ;;
      outage_since) ST_OUTAGE_SINCE="$(int_or "$value" 0)" ;;
      alerted) ST_ALERTED="$value" ;;
      last_alert) ST_LAST_ALERT="$(int_or "$value" 0)" ;;
      error_streak) ST_ERROR_STREAK="$(int_or "$value" 0)" ;;
      dead_fp) ST_DEAD_FP="$value" ;;
      last_probe) ST_LAST_PROBE="$(int_or "$value" 0)" ;;
      volume_exp) ST_VOLUME_EXP="$(int_or "$value" -1)" ;;
    esac
  done <"$STATE_FILE"
}

state_save() {
  local tmp="$STATE_FILE.tmp.$$"
  {
    printf 'cli_status=%s\n' "$ST_CLI_STATUS"
    printf 'detail=%s\n' "$ST_DETAIL"
    printf 'outage_since=%s\n' "$ST_OUTAGE_SINCE"
    printf 'alerted=%s\n' "$ST_ALERTED"
    printf 'last_alert=%s\n' "$ST_LAST_ALERT"
    printf 'error_streak=%s\n' "$ST_ERROR_STREAK"
    printf 'dead_fp=%s\n' "$ST_DEAD_FP"
    printf 'last_probe=%s\n' "$ST_LAST_PROBE"
    printf 'volume_exp=%s\n' "$ST_VOLUME_EXP"
  } >"$tmp" && mv -f "$tmp" "$STATE_FILE"
}

# ---------------------------------------------------------------------------
# Credential copies
# ---------------------------------------------------------------------------

read_host() {
  read -r HOST_EXP HOST_HAS HOST_FP HOST_ISO <<<"$(cred_fields "$HOST_CREDENTIALS")"
}

# The consumer's CLI runs as root and may rewrite this copy root:root 0600, so
# fall back to reading it through the running container. Sets CFG_STATE to
# absent (no dir) | missing | direct | docker | unreadable.
read_config_copy() {
  CFG_STATE=absent CFG_EXP=-1 CFG_HAS=0 CFG_FP=- CFG_ISO=- CFG_FILE=""
  if [ ! -d "$CONFIG_SYNC_DIR" ]; then return 0; fi
  local src="$CONFIG_SYNC_DIR/.credentials.json" tmp="$STATE_DIR/.claude-config-read.tmp"
  if [ ! -e "$src" ]; then
    CFG_STATE=missing
    return 0
  fi
  # shellcheck disable=SC2016  # $CLAUDE_CONFIG_DIR expands inside the container
  if [ -r "$src" ]; then
    CFG_FILE="$src" CFG_STATE=direct
  elif docker exec "$CONSUMER_CONTAINER" sh -c 'cat "$CLAUDE_CONFIG_DIR/.credentials.json"' >"$tmp" 2>/dev/null && [ -s "$tmp" ]; then
    CFG_FILE="$tmp" CFG_STATE=docker
  else
    rm -f "$tmp"
    CFG_STATE=unreadable
    return 0
  fi
  read -r CFG_EXP CFG_HAS CFG_FP CFG_ISO <<<"$(cred_fields "$CFG_FILE")"
}

# Replace the host credentials with the (newer) config copy, keeping a backup.
adopt_config_copy() {
  local tmp="$HOST_CREDENTIALS.tmp.$$"
  mkdir -p "$CLAUDE_HOME"
  if [ -f "$HOST_CREDENTIALS" ]; then
    cp -p "$HOST_CREDENTIALS" "$HOST_CREDENTIALS.pre-adopt" 2>/dev/null || true
  fi
  if cp "$CFG_FILE" "$tmp" && chmod 600 "$tmp" && mv -f "$tmp" "$HOST_CREDENTIALS"; then
    return 0
  fi
  rm -f "$tmp" 2>/dev/null || true
  return 1
}

# Temp file + rename: works even when the old file is root-owned, because the
# directory belongs to the deploy user.
write_config_copy() {
  local dest="$CONFIG_SYNC_DIR/.credentials.json" tmp="$CONFIG_SYNC_DIR/.credentials.json.tmp.$$"
  if cp "$HOST_CREDENTIALS" "$tmp" 2>/dev/null && chmod 600 "$tmp" && mv -f "$tmp" "$dest" 2>/dev/null; then
    return 0
  fi
  rm -f "$tmp" 2>/dev/null || true
  return 1
}

# Copy the host credentials into the claude_credentials volume through a
# throwaway backend container (host ~/.claude mounted read-only).
sync_volume() {
  local out="$STATE_DIR/.compose-sync.out" rc=0
  SYNC_ERR=""
  if [ ! -d "$COMPOSE_DIR" ]; then
    SYNC_ERR="compose dir $COMPOSE_DIR not found (set COMPOSE_DIR)"
    return 1
  fi
  if ! command -v docker >/dev/null 2>&1; then
    SYNC_ERR="docker not found on PATH"
    return 1
  fi
  (
    cd "$COMPOSE_DIR" &&
      docker compose run --rm --no-deps \
        --volume "$CLAUDE_HOME:/host-claude:ro" \
        --entrypoint sh \
        backend \
        -c 'set -eu
            umask 077
            test -s /host-claude/.credentials.json
            mkdir -p /root/.claude
            cp /host-claude/.credentials.json /root/.claude/.credentials.json.tmp
            mv /root/.claude/.credentials.json.tmp /root/.claude/.credentials.json
            chmod 600 /root/.claude/.credentials.json'
  ) >"$out" 2>&1 || rc=$?
  if [ "$rc" -ne 0 ]; then
    SYNC_ERR="docker compose run exited $rc: $(last_line_of "$out")"
  fi
  rm -f "$out"
  return "$rc"
}

# ---------------------------------------------------------------------------
# The CLI refresh
# ---------------------------------------------------------------------------

# Decide whether to call the CLI this wake. Sets CLI_REASON.
should_call_cli() {
  local secs_left=$((HOST_EXP / 1000 - NOW))
  if [ "$SKIP_HOST_REFRESH" = 1 ]; then
    CLI_REASON="skip:CLAUDE_SKIP_HOST_REFRESH"
    return 1
  fi
  case "$ST_CLI_STATUS" in
    auth_dead | access_disabled)
      if [ "$HOST_FP" != "$ST_DEAD_FP" ]; then CLI_REASON="creds-changed"; return 0; fi
      if [ $((NOW - ST_LAST_PROBE)) -ge "$DEAD_REPROBE_SECONDS" ]; then CLI_REASON="reprobe"; return 0; fi
      CLI_REASON="skip:dead-until-login"
      return 1
      ;;
    quota)
      if [ "$secs_left" -le "$REFRESH_WINDOW_SECONDS" ]; then CLI_REASON="in-window"; return 0; fi
      if [ $((NOW - ST_LAST_PROBE)) -ge "$DEAD_REPROBE_SECONDS" ]; then CLI_REASON="reprobe"; return 0; fi
      CLI_REASON="skip:quota-reprobe-later"
      return 1
      ;;
    error)
      CLI_REASON="retry"
      return 0
      ;;
  esac
  if [ "$secs_left" -le "$REFRESH_WINDOW_SECONDS" ]; then CLI_REASON="in-window"; return 0; fi
  CLI_REASON="skip:outside-window"
  return 1
}

# One authenticated call; the CLI rotates the token when it is close to expiry.
# Sets CLI_RC, CLI_RESULT and CLI_LINE.
run_cli() {
  local out="$STATE_DIR/.cli-output.tmp" result
  CLI_RC=0
  if ! command -v "$CLAUDE_CLI" >/dev/null 2>&1; then
    CLI_RC=127 CLI_RESULT=error CLI_LINE="claude CLI not found ($CLAUDE_CLI)"
    return 0
  fi
  if command -v timeout >/dev/null 2>&1; then
    timeout "$CLI_TIMEOUT_SECONDS" "$CLAUDE_CLI" --print --max-turns 1 "$CLI_PROMPT" </dev/null >"$out" 2>&1 || CLI_RC=$?
  else
    "$CLAUDE_CLI" --print --max-turns 1 "$CLI_PROMPT" </dev/null >"$out" 2>&1 || CLI_RC=$?
  fi
  result="$(py classify "$CLI_RC" <"$out" 2>/dev/null)" || result="error|could not classify CLI output (rc=$CLI_RC)"
  rm -f "$out"
  CLI_RESULT="${result%%|*}"
  CLI_LINE="${result#*|}"
}

# ---------------------------------------------------------------------------
# Alerts
# ---------------------------------------------------------------------------

# POST {"text": ...} to the webhook, or log it when no webhook is configured.
# Never fatal; returns 1 when delivery failed so the caller retries next wake.
send_alert() {
  local text="$1" flat payload="$STATE_DIR/.alert-payload.tmp" err rc=0 nl='
'
  flat="${text//$nl/ | }"
  if [ -z "$ALERT_WEBHOOK_URL" ]; then
    log "ALERT $flat"
    return 0
  fi
  if ! printf '%s' "$text" | py payload >"$payload" 2>/dev/null; then
    log "alert not sent (could not build JSON): $flat"
    rm -f "$payload"
    return 1
  fi
  # The URL goes in via curl's config on stdin so it never shows up in ps.
  err="$(printf 'url = "%s"\n' "$ALERT_WEBHOOK_URL" |
    curl -fsS -m 10 -K - -H 'Content-Type: application/json' --data-binary "@$payload" 2>&1 >/dev/null)" || rc=$?
  rm -f "$payload"
  if [ "$rc" -ne 0 ]; then
    log "alert delivery failed (curl rc=$rc: $(printf '%s' "$err" | head -n 1 | cut -c1-200)); will retry: $flat"
    return 1
  fi
  log "alert sent: $flat"
  return 0
}

problem_text() {
  local status="$1" detail="$2" phase="$3" name="$ALERT_DEPLOYMENT_NAME" head cause fix tag="[ALERT]"
  head="Claude chat is failing for every user on $name."
  case "$status" in
    auth_dead)
      cause="the Claude login on the host has expired and cannot be refreshed (auth_dead)."
      fix="ssh to the host and run \`claude login\` as $DAEMON_USER; the daemon picks it up within a minute."
      ;;
    quota)
      cause="the Claude subscription has hit its usage limit (quota)."
      fix="wait for the reset time shown in the error; a recovery alert follows when it clears. If the limit is unexpected, check who else uses this Claude subscription."
      ;;
    access_disabled)
      cause="the logged-in account's organization has disabled Claude Code subscription access (access_disabled)."
      fix="ssh to the host and run \`claude login\` as $DAEMON_USER with an account that has Claude Code enabled; logging in again with the same account will not help."
      ;;
    sync_failed)
      head="Claude chat on $name will start failing for every user."
      cause="fresh credentials were refreshed on the host but did not reach the containers (sync_failed)."
      fix="check \`journalctl -u claude-auth-refresh\` and \`docker compose ps\` on the host; the daemon retries every ${FAIL_SLEEP_SECONDS}s."
      ;;
    *)
      head="Claude chat may be failing for every user on $name."
      cause="the Claude auth refresh failed $ST_ERROR_STREAK times in a row with an unrecognised error (error)."
      fix="check \`journalctl -u claude-auth-refresh\` on the host and run \`claude --print ok\` as $DAEMON_USER by hand."
      ;;
  esac
  if [ "$phase" = repeat ]; then tag="[STILL FAILING]"; fi
  printf '%s %s: %s\nCause: %s\nSince: %s (%s ago)\nError: %s\nFix: %s' \
    "$tag" "$name" "$head" "$cause" "$(iso_of "$ST_OUTAGE_SINCE")" \
    "$(fmt_duration $((NOW - ST_OUTAGE_SINCE)))" "${detail:-(none)}" "$fix"
}

recovery_text() {
  printf '[RESOLVED] %s: Claude chat is working again on %s.\nWas: %s since %s; the outage lasted %s.' \
    "$ALERT_DEPLOYMENT_NAME" "$ALERT_DEPLOYMENT_NAME" "$ST_ALERTED" \
    "$(iso_of "$ST_OUTAGE_SINCE")" "$(fmt_duration $((NOW - ST_OUTAGE_SINCE)))"
}

# Alert on entering a failing state, repeat while it lasts, and send one
# recovery alert. Unknown errors alert only after ERROR_ALERT_AFTER in a row.
process_alerts() {
  local status="$1" detail="$2"
  if [ "$status" = ok ]; then
    if [ -z "$ST_ALERTED" ]; then
      ST_OUTAGE_SINCE=0
    elif send_alert "$(recovery_text)"; then
      ST_ALERTED="" ST_OUTAGE_SINCE=0 ST_LAST_ALERT=0
    fi
    return 0
  fi
  if [ "$ST_OUTAGE_SINCE" -eq 0 ]; then ST_OUTAGE_SINCE="$NOW"; fi
  if [ "$status" = error ] && [ "$ST_ERROR_STREAK" -lt "$ERROR_ALERT_AFTER" ]; then return 0; fi
  if [ "$ST_ALERTED" != "$status" ]; then
    if send_alert "$(problem_text "$status" "$detail" new)"; then
      ST_ALERTED="$status" ST_LAST_ALERT="$NOW"
    fi
  elif [ $((NOW - ST_LAST_ALERT)) -ge "$ALERT_REPEAT_SECONDS" ]; then
    if send_alert "$(problem_text "$status" "$detail" repeat)"; then
      ST_LAST_ALERT="$NOW"
    fi
  fi
}

send_test_alert() {
  local text
  text="$(printf '[TEST] %s: Claude auth alerting works. No action needed.\nSent by claude-oauth-refresh-daemon.sh as %s.' \
    "$ALERT_DEPLOYMENT_NAME" "$DAEMON_USER")"
  if [ -z "$ALERT_WEBHOOK_URL" ]; then
    send_alert "$text"
    log "ALERT_WEBHOOK_URL is not set; nothing was sent"
    return 2
  fi
  if send_alert "$text"; then return 0; fi
  return 1
}

# ---------------------------------------------------------------------------
# One wake
# ---------------------------------------------------------------------------

next_sleep_seconds() {
  local status="$1" secs_left s
  case "$status" in
    auth_dead | access_disabled) echo "$DEAD_POLL_SECONDS"; return 0 ;;
    error | sync_failed) echo "$FAIL_SLEEP_SECONDS"; return 0 ;;
  esac
  if [ "$HOST_EXP" -le 0 ]; then echo "$FAIL_SLEEP_SECONDS"; return 0; fi
  secs_left=$((HOST_EXP / 1000 - NOW))
  if [ "$secs_left" -le "$REFRESH_WINDOW_SECONDS" ]; then
    s="$POLL_SECONDS"
  else
    s=$((secs_left - REFRESH_WINDOW_SECONDS))
    if [ "$s" -lt "$MIN_SLEEP_SECONDS" ]; then s="$MIN_SLEEP_SECONDS"; fi
    if [ "$s" -gt "$MAX_SLEEP_SECONDS" ]; then s="$MAX_SLEEP_SECONDS"; fi
  fi
  if [ "$status" = quota ] && [ "$s" -gt "$DEAD_REPROBE_SECONDS" ]; then s="$DEAD_REPROBE_SECONDS"; fi
  echo "$s"
}

host_summary() {
  if [ "$HOST_HAS" != 1 ]; then
    if [ "$HOST_FP" = missing ] || [ "$HOST_FP" = unreadable ]; then echo "$HOST_FP"; else echo "no-tokens"; fi
  elif [ "$HOST_EXP" -le "$NOW_MS" ]; then
    echo "expired($HOST_ISO)"
  else
    echo "valid($HOST_ISO,+$(fmt_duration $((HOST_EXP / 1000 - NOW))))"
  fi
}

run_wake() {
  NOW="$(now_epoch)"
  NOW_MS=$((NOW * 1000))
  state_load
  local cli_status="$ST_CLI_STATUS" cli_detail="$ST_DETAIL" cli_note fp_before
  local status alert_detail synced="" sync_problem="" adopted=""

  # 1. Newest wins: the consumer's CLI may have rotated the chain in the config
  #    copy first. Never re-adopt the credentials that already died.
  read_host
  read_config_copy
  if [ "$CFG_HAS" = 1 ] && [ "$CFG_EXP" -gt 0 ] && [ "$CFG_EXP" -gt "$HOST_EXP" ] &&
    [ "$CFG_FP" != "$ST_DEAD_FP" ]; then
    if adopt_config_copy; then
      adopted=" adopted=claude-config($CFG_STATE)"
      read_host
    else
      log "WARN could not adopt the newer claude-config credentials into $HOST_CREDENTIALS"
    fi
  fi

  # 2. Refresh through the CLI when due, and classify the outcome.
  if [ "$HOST_HAS" != 1 ]; then
    # Missing file or tokens dropped (the CLI does this after an auth failure):
    # nothing to refresh until someone runs `claude login`.
    cli_note="skip:no-host-tokens"
    if [ "$cli_status" != auth_dead ]; then
      cli_detail="no usable credentials at $HOST_CREDENTIALS (missing, or tokens dropped after an auth failure)"
    fi
    cli_status=auth_dead
  elif should_call_cli; then
    fp_before="$HOST_FP"
    run_cli
    ST_LAST_PROBE="$NOW"
    cli_status="$CLI_RESULT" cli_detail="$CLI_LINE"
    cli_note="$CLI_REASON:$CLI_RESULT(rc=$CLI_RC)"
    case "$cli_status" in
      auth_dead | access_disabled) ST_DEAD_FP="$fp_before" ;;
      *) ST_DEAD_FP="" ;;
    esac
    if [ "$cli_status" = error ]; then ST_ERROR_STREAK=$((ST_ERROR_STREAK + 1)); else ST_ERROR_STREAK=0; fi
    read_host
  else
    cli_note="$CLI_REASON"
  fi
  if [ "$cli_status" = ok ]; then cli_detail=""; fi

  # 3. Sync by the credentials themselves: valid host creds go to every older
  #    copy, whatever the CLI exit code was (a quota error still rotates). The
  #    one exception: credentials the CLI just called dead stay on the host.
  local host_syncable=0
  if [ "$HOST_HAS" = 1 ] && [ "$HOST_EXP" -gt "$NOW_MS" ]; then host_syncable=1; fi
  case "$cli_status" in auth_dead | access_disabled) host_syncable=0 ;; esac
  if [ "$host_syncable" = 1 ]; then
    if [ "$HOST_EXP" -gt "$ST_VOLUME_EXP" ]; then
      if sync_volume; then
        ST_VOLUME_EXP="$HOST_EXP" synced="volume"
      else
        sync_problem="volume sync failed: $SYNC_ERR"
      fi
    fi
    if [ "$CFG_STATE" != absent ]; then
      if [ "$HOST_EXP" -gt "$CFG_EXP" ]; then
        if write_config_copy; then
          synced="${synced:+$synced,}claude-config"
        else
          sync_problem="${sync_problem:+$sync_problem; }could not write $CONFIG_SYNC_DIR/.credentials.json"
        fi
      fi
      # 4. Verify. A copy newer than the host is fine: the next wake adopts it.
      read_config_copy
      if [ "$CFG_EXP" -lt "$HOST_EXP" ]; then
        sync_problem="${sync_problem:+$sync_problem; }claude-config copy expires $CFG_ISO but host expires $HOST_ISO (read: $CFG_STATE)"
      fi
    fi
  fi

  status="$cli_status" alert_detail="$cli_detail"
  if [ "$status" = ok ] && [ -n "$sync_problem" ]; then
    status=sync_failed alert_detail="$sync_problem"
  fi
  process_alerts "$status" "$alert_detail"

  ST_CLI_STATUS="$cli_status" ST_DETAIL="$cli_detail"
  NEXT_SLEEP="$(next_sleep_seconds "$status")"
  WAKE_STATUS="$status"
  state_save
  rm -f "$STATE_DIR/.claude-config-read.tmp"
  local err_note=""
  if [ -n "$alert_detail" ]; then err_note=" error=\"$alert_detail\""; fi
  log "status=$status cli=$cli_note host=$(host_summary) cfg=$CFG_STATE sync=${synced:-none}${adopted} next=${NEXT_SLEEP}s$err_note"
}

cleanup_temp_files() {
  rm -f "$STATE_DIR/.cli-output.tmp" "$STATE_DIR/.claude-config-read.tmp" \
    "$STATE_DIR/.alert-payload.tmp" "$STATE_DIR/.compose-sync.out" 2>/dev/null || true
}

main() {
  load_config
  umask 077
  if ! command -v python3 >/dev/null 2>&1; then
    log "missing required command: python3"
    exit 1
  fi
  mkdir -p "$STATE_DIR"
  trap cleanup_temp_files EXIT
  trap 'exit 143' TERM INT

  if [ "${CLAUDE_REFRESH_ALERT_TEST:-0}" = 1 ]; then
    local rc=0
    send_test_alert || rc=$?
    exit "$rc"
  fi

  if [ -z "$ALERT_WEBHOOK_URL" ]; then
    log "WARN alerting is not configured (ALERT_WEBHOOK_URL is empty); alerts are only logged with an ALERT prefix"
  fi
  log "starting: deployment=$ALERT_DEPLOYMENT_NAME host_creds=$HOST_CREDENTIALS compose_dir=$COMPOSE_DIR claude_config=$CONFIG_SYNC_DIR window=${REFRESH_WINDOW_SECONDS}s"

  while true; do
    run_wake
    if [ "$RUN_ONCE" = 1 ]; then
      if [ "$WAKE_STATUS" = ok ]; then exit 0; fi
      exit 1
    fi
    daemon_sleep "$NEXT_SLEEP"
  done
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  main "$@"
fi
