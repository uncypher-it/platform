#!/bin/bash
# Self-contained tests for scripts/claude-oauth-refresh-daemon.sh.
#
#   /bin/bash tests/claude-auth/test_refresh_daemon.sh        # macOS bash 3.2
#   /opt/homebrew/bin/bash tests/claude-auth/test_refresh_daemon.sh
#
# The daemon runs under the same bash as this runner ("$BASH"), one wake per
# invocation (CLAUDE_REFRESH_ONCE=1) with a pinned clock (CLAUDE_REFRESH_NOW).
# PATH stubs stand in for `claude`, `docker` and `curl`; they read their
# scripted behaviour from, and record calls into, $STUB.

set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
DAEMON="${DAEMON_UNDER_TEST:-$HERE/../../scripts/claude-oauth-refresh-daemon.sh}"
ORIG_PATH="$PATH"
NOW0=2000000000          # pinned "now" (epoch seconds)
H8=$((8 * 3600))
PASS=0
FAIL=0
CURRENT=""

# --- assertions -------------------------------------------------------------

ok() { PASS=$((PASS + 1)); }
bad() {
  FAIL=$((FAIL + 1))
  echo "  FAIL [$CURRENT] $*"
  if [ -f "$T/out.log" ]; then sed 's/^/      | /' "$T/out.log" | tail -n 8; fi
}
assert_eq() { if [ "$1" = "$2" ]; then ok; else bad "$3: expected '$2', got '$1'"; fi; }
assert_grep() { if grep -q -- "$2" "$1" 2>/dev/null; then ok; else bad "$3: '$2' not in $(basename "$1")"; fi; }
assert_no_grep() { if grep -q -- "$2" "$1" 2>/dev/null; then bad "$3: '$2' unexpectedly in $(basename "$1")"; else ok; fi; }
assert_missing() { if [ -e "$1" ]; then bad "$2: $1 should not exist"; else ok; fi; }

count_lines() { if [ -f "$1" ]; then grep -c . "$1" | tr -d ' '; else echo 0; fi; }
calls() { count_lines "$STUB/$1.calls"; }
payloads() { count_lines "$STUB/webhook.payloads"; }
last_payload() { tail -n 1 "$STUB/webhook.payloads" 2>/dev/null; }
field() { python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["claudeAiOauth"].get(sys.argv[2]))' "$1" "$2" 2>/dev/null; }

# --- fixtures ---------------------------------------------------------------

# mkcreds <path> <expiresAt epoch seconds> <tag>  (tokens carry the tag)
mkcreds() {
  printf '{"claudeAiOauth":{"accessToken":"sk-ant-oat01-ACCESS-%s","refreshToken":"sk-ant-ort01-REFRESH-%s","expiresAt":%s000,"scopes":["user:inference"],"subscriptionType":"max"}}\n' \
    "$3" "$3" "$2" >"$1"
  chmod 600 "$1"
}
# What the CLI leaves behind after an auth failure: expiresAt 0, tokens dropped.
mkdead() {
  printf '{"claudeAiOauth":{"expiresAt":0,"scopes":["user:inference"],"subscriptionType":"max"}}\n' >"$1"
}

# cli <rc> <output> [new credentials file to install on the call]
cli() {
  echo "$1" >"$STUB/claude.rc"
  printf '%s\n' "$2" >"$STUB/claude.out"
  rm -f "$STUB/claude.newcreds"
  if [ -n "${3:-}" ]; then cp "$3" "$STUB/claude.newcreds"; fi
}

setup() {
  CURRENT="$1"
  T="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/claude-refresh-test.XXXXXX")" && pwd -P)"
  STUB="$T/stub"
  mkdir -p "$T/home/.claude" "$T/compose/claude-config" "$STUB" "$T/bin"

  cat >"$T/bin/claude" <<'EOF'
#!/bin/bash
echo "$*" >>"$STUB/claude.calls"
if [ -f "$STUB/claude.newcreds" ]; then cp "$STUB/claude.newcreds" "$CLAUDE_HOME/.credentials.json"; fi
cat "$STUB/claude.out" 2>/dev/null
exit "$(cat "$STUB/claude.rc" 2>/dev/null || echo 0)"
EOF
  cat >"$T/bin/docker" <<'EOF'
#!/bin/bash
echo "$1 $2 $3 (cwd=$PWD)" >>"$STUB/docker.calls"   # one line per call
case "$1" in
  exec)
    if [ -f "$STUB/docker.exec.src" ]; then cat "$STUB/docker.exec.src"; exit 0; fi
    echo "Error response from daemon: No such container" >&2; exit 1 ;;
  compose)
    rc="$(cat "$STUB/docker.compose.rc" 2>/dev/null || echo 0)"
    if [ "$rc" != 0 ]; then echo "service \"backend\" failed" >&2; exit "$rc"; fi
    src="" prev=""
    for a in "$@"; do if [ "$prev" = "--volume" ]; then src="${a%%:*}"; fi; prev="$a"; done
    mkdir -p "$STUB/volume" && cp "$src/.credentials.json" "$STUB/volume/.credentials.json" ;;
esac
EOF
  cat >"$T/bin/curl" <<'EOF'
#!/bin/bash
cat >>"$STUB/curl.config"           # -K - : URL arrives on stdin
data="" prev=""
for a in "$@"; do if [ "$prev" = "--data-binary" ]; then data="${a#@}"; fi; prev="$a"; done
echo "$*" >>"$STUB/curl.calls"
cat "$data" >>"$STUB/webhook.payloads"; echo >>"$STUB/webhook.payloads"
rc="$(cat "$STUB/curl.rc" 2>/dev/null || echo 0)"
if [ "$rc" != 0 ]; then echo "curl: (22) The requested URL returned error: 404" >&2; fi
exit "$rc"
EOF
  chmod +x "$T/bin/claude" "$T/bin/docker" "$T/bin/curl"

  export STUB PATH="$T/bin:$ORIG_PATH" HOME="$T/home"
  export CLAUDE_HOME="$T/home/.claude" COMPOSE_DIR="$T/compose" CLAUDE_CLI=claude
  export CLAUDE_REFRESH_ONCE=1 CLAUDE_REFRESH_NOW="$NOW0"
  export ALERT_WEBHOOK_URL="https://hooks.example.test/services/T000/B000/XXXX"
  export ALERT_DEPLOYMENT_NAME=testdeploy
  unset CLAUDE_SKIP_HOST_REFRESH CLAUDE_REFRESH_LOG_FILE CLAUDE_REFRESH_ALERT_TEST \
    CLAUDE_CONFIG_SYNC_DIR CLAUDE_REFRESH_STATE_DIR ALERT_REPEAT_SECONDS

  HOSTC="$CLAUDE_HOME/.credentials.json"
  CFGC="$COMPOSE_DIR/claude-config/.credentials.json"
  VOLC="$STUB/volume/.credentials.json"
}

teardown() {
  chmod -R u+rwx "$T" 2>/dev/null
  rm -rf "$T"
}

# run_at <offset seconds from NOW0>: one daemon wake; output in $T/out.log.
run_at() {
  CLAUDE_REFRESH_NOW=$((NOW0 + $1)) "$BASH" "$DAEMON" >"$T/out.log" 2>&1
  RC=$?
  cat "$T/out.log" >>"$T/all.log"
}

# Secrets must never reach logs or alerts.
assert_no_secrets() {
  assert_no_grep "$T/all.log" "sk-ant-" "no token in logs"
  assert_no_grep "$STUB/webhook.payloads" "sk-ant-" "no token in alerts"
}

# --- tests ------------------------------------------------------------------

test_healthy_refresh_syncs_both_copies() {
  setup healthy_refresh
  mkcreds "$HOSTC" $((NOW0 + 300)) rt1          # inside the 10 min window
  mkcreds "$CFGC" $((NOW0 + 300)) rt1
  mkcreds "$T/rotated" $((NOW0 + H8)) rt2
  cli 0 "ok" "$T/rotated"
  run_at 0
  assert_eq "$RC" 0 "exit code"
  assert_eq "$(calls claude)" 1 "claude called once"
  assert_eq "$(field "$VOLC" refreshToken)" "sk-ant-ort01-REFRESH-rt2" "volume synced"
  assert_eq "$(field "$CFGC" refreshToken)" "sk-ant-ort01-REFRESH-rt2" "claude-config synced"
  assert_eq "$(stat -f %Lp "$CFGC" 2>/dev/null || stat -c %a "$CFGC")" 600 "claude-config mode"
  assert_grep "$STUB/docker.calls" "cwd=$COMPOSE_DIR" "compose ran from COMPOSE_DIR"
  assert_eq "$(payloads)" 0 "no alert"
  assert_grep "$T/out.log" "status=ok cli=in-window:ok(rc=0)" "wake line"
  assert_eq "$(grep -c 'status=' "$T/out.log" | tr -d ' ')" 1 "one line per wake"
  # Next wake, outside the window: no CLI call, nothing newer to sync.
  run_at 60
  assert_eq "$(calls claude)" 1 "no CLI call outside window"
  assert_eq "$(calls docker)" 1 "no second volume sync"
  assert_grep "$T/out.log" "cli=skip:outside-window" "skip reason"
  assert_grep "$T/out.log" "next=3600s" "sleep clamped to max"
  assert_no_secrets
  teardown
}

test_quota_still_syncs_rotated_creds() {
  setup quota_rotated
  mkcreds "$HOSTC" $((NOW0 + 300)) rt1
  mkcreds "$CFGC" $((NOW0 + 300)) rt1
  mkcreds "$T/rotated" $((NOW0 + H8)) rt2
  cli 1 "You've hit your weekly limit · resets Oct 18, 8am (UTC)" "$T/rotated"
  run_at 0
  assert_eq "$RC" 1 "exit code"
  assert_eq "$(field "$VOLC" refreshToken)" "sk-ant-ort01-REFRESH-rt2" "volume synced despite rc=1"
  assert_eq "$(field "$CFGC" refreshToken)" "sk-ant-ort01-REFRESH-rt2" "claude-config synced despite rc=1"
  assert_eq "$(payloads)" 1 "one quota alert"
  assert_grep "$STUB/webhook.payloads" "usage limit (quota)" "quota cause"
  assert_grep "$STUB/webhook.payloads" "hit your weekly limit" "CLI line in alert"
  assert_grep "$STUB/webhook.payloads" "testdeploy" "deployment name"
  assert_grep "$T/out.log" "next=1800s" "quota re-probe cap"
  # Re-probe after 30 min: limit cleared -> recovery.
  cli 0 "ok"
  run_at 1700
  assert_eq "$(calls claude)" 1 "no CLI call before re-probe"
  run_at 1800
  assert_eq "$(calls claude)" 2 "re-probe called the CLI"
  assert_eq "$(payloads)" 2 "recovery alert"
  assert_grep "$STUB/webhook.payloads" "RESOLVED" "recovery text"
  assert_no_secrets
  teardown
}

test_auth_dead_alerts_once_waits_for_login() {
  setup auth_dead_then_login
  mkcreds "$HOSTC" $((NOW0 + 100)) rt1
  mkcreds "$CFGC" $((NOW0 + 100)) rt1
  mkdead "$T/dead"
  cli 1 "Failed to authenticate: OAuth session expired and could not be refreshed" "$T/dead"
  run_at 0
  assert_eq "$RC" 1 "exit code"
  assert_eq "$(payloads)" 1 "alerted once"
  assert_grep "$STUB/webhook.payloads" "Claude chat is failing for every user on testdeploy" "headline"
  assert_grep "$STUB/webhook.payloads" "run \`claude login\` as $(id -un)" "fix"
  assert_grep "$STUB/webhook.payloads" "OAuth session expired" "CLI line"
  assert_missing "$VOLC" "dead creds not synced to volume"
  assert_eq "$(field "$CFGC" refreshToken)" "sk-ant-ort01-REFRESH-rt1" "claude-config untouched"
  assert_grep "$T/out.log" "next=60s" "dead poll interval"
  # Chain dead: no CLI calls, no adoption of the same dead chain, no re-alerts.
  run_at 60
  run_at 120
  run_at 1900
  assert_eq "$(calls claude)" 1 "CLI not re-called while dead"
  assert_eq "$(field "$HOSTC" expiresAt)" 0 "dead chain not re-adopted from claude-config"
  assert_eq "$(payloads)" 1 "no duplicate alert"
  assert_grep "$T/out.log" "cli=skip:no-host-tokens" "skip reason"
  # Operator runs `claude login`.
  mkcreds "$HOSTC" $((NOW0 + 2000 + H8)) login1
  cli 0 "ok"
  run_at 2000
  assert_eq "$RC" 0 "exit code after login"
  assert_eq "$(calls claude)" 2 "login detected, CLI verified"
  assert_eq "$(payloads)" 2 "recovery alert"
  assert_grep "$STUB/webhook.payloads" "RESOLVED.*outage lasted 33m" "recovery with duration"
  assert_eq "$(field "$VOLC" refreshToken)" "sk-ant-ort01-REFRESH-login1" "volume synced after login"
  assert_eq "$(field "$CFGC" refreshToken)" "sk-ant-ort01-REFRESH-login1" "claude-config synced after login"
  assert_no_secrets
  teardown
}

test_auth_dead_with_tokens_reprobes_after_30m() {
  setup auth_dead_401_reprobe
  mkcreds "$HOSTC" $((NOW0 - 10)) rt1           # expired, tokens still present
  cli 1 "Failed to authenticate. API Error: 401 Invalid authentication credentials"
  run_at 0
  assert_eq "$(payloads)" 1 "alerted"
  run_at 60
  run_at 1799
  assert_eq "$(calls claude)" 1 "same fingerprint: no call"
  assert_grep "$T/out.log" "cli=skip:dead-until-login" "skip reason"
  run_at 1800
  assert_eq "$(calls claude)" 2 "re-probe after 30 min"
  assert_eq "$(payloads)" 1 "still one alert"
  teardown
}

test_unreadable_config_copy_read_via_docker_exec() {
  setup unreadable_config_adopt
  mkcreds "$HOSTC" $((NOW0 + 4000)) rt1
  mkcreds "$CFGC" $((NOW0 + H8)) rtc           # consumer rotated first...
  cp "$CFGC" "$STUB/docker.exec.src"
  chmod 000 "$CFGC"                             # ...and left it root-only
  if [ -r "$CFGC" ]; then echo "  SKIP [$CURRENT] running as root"; teardown; return; fi
  cli 0 "ok"
  run_at 0
  assert_eq "$RC" 0 "exit code"
  assert_grep "$STUB/docker.calls" "exec uncypher-chat-consumer" "read through the container"
  assert_eq "$(field "$HOSTC" refreshToken)" "sk-ant-ort01-REFRESH-rtc" "newer chain adopted"
  assert_grep "$T/out.log" "adopted=claude-config(docker)" "adoption logged"
  assert_eq "$(calls claude)" 0 "no CLI call (fresh token)"
  assert_eq "$(field "$VOLC" refreshToken)" "sk-ant-ort01-REFRESH-rtc" "volume gets adopted chain"
  assert_eq "$(payloads)" 0 "no alert"
  teardown

  setup unreadable_config_overwrite
  mkcreds "$HOSTC" $((NOW0 + H8)) rt2
  mkcreds "$CFGC" $((NOW0 + 100)) rt1
  chmod 000 "$CFGC"                             # unreadable, container down
  if [ -r "$CFGC" ]; then echo "  SKIP [$CURRENT] running as root"; teardown; return; fi
  run_at 0
  assert_eq "$RC" 0 "exit code"
  assert_grep "$T/all.log" "cfg=direct" "verified directly after replacing it"
  assert_eq "$(field "$CFGC" refreshToken)" "sk-ant-ort01-REFRESH-rt2" "replaced via temp + mv"
  assert_eq "$(payloads)" 0 "no alert"
  # Same, but this time keep reading blind to check the log says so.
  mkcreds "$HOSTC" $((NOW0 + H8 + 10)) rt3
  chmod 000 "$CFGC"
  export CLAUDE_CONFIG_SYNC_DIR="$COMPOSE_DIR/claude-config"
  run_at 10
  assert_grep "$STUB/docker.calls" "exec uncypher-chat-consumer" "docker exec attempted"
  assert_eq "$(field "$CFGC" refreshToken)" "sk-ant-ort01-REFRESH-rt3" "unknown copy overwritten"
  teardown
}

test_invalid_host_creds_never_synced() {
  setup invalid_host_expired
  export CLAUDE_SKIP_HOST_REFRESH=1
  mkcreds "$HOSTC" $((NOW0 - 60)) rt1           # expired
  mkcreds "$CFGC" $((NOW0 - 120)) rt0
  run_at 0
  assert_eq "$(calls claude)" 0 "skip host refresh honoured"
  assert_missing "$STUB/docker.calls" "no compose sync"
  assert_eq "$(field "$CFGC" refreshToken)" "sk-ant-ort01-REFRESH-rt0" "claude-config untouched"
  teardown

  setup invalid_host_missing
  rm -rf "$COMPOSE_DIR/claude-config"           # deployment without the native dir
  run_at 0
  assert_eq "$RC" 1 "exit code"
  assert_eq "$(calls claude)" 0 "no CLI call without credentials"
  assert_missing "$STUB/docker.calls" "no sync, no docker exec"
  assert_grep "$T/out.log" "cfg=absent" "config dir absent"
  assert_grep "$STUB/webhook.payloads" "auth_dead" "missing creds alert"
  teardown
}

test_repeat_alert_timing() {
  setup repeat_alert
  export ALERT_REPEAT_SECONDS=21600
  mkcreds "$HOSTC" $((NOW0 + 300)) rt1
  cli 1 "Your organization has disabled Claude subscription access for Claude Code · Use an Anthropic API key instead, or ask your admin to enable access"
  run_at 0
  assert_eq "$(payloads)" 1 "first alert"
  assert_grep "$STUB/webhook.payloads" "access_disabled" "classified"
  assert_grep "$STUB/webhook.payloads" "account that has Claude Code enabled" "fix"
  run_at 60
  run_at 21599
  assert_eq "$(payloads)" 1 "no repeat before ALERT_REPEAT_SECONDS"
  run_at 21600
  assert_eq "$(payloads)" 2 "repeat alert"
  assert_grep "$STUB/webhook.payloads" "STILL FAILING.*6h 0m ago" "repeat text"
  run_at 21660
  assert_eq "$(payloads)" 2 "no extra repeat"
  teardown
}

test_unknown_error_alerts_after_three() {
  setup unknown_error
  mkcreds "$HOSTC" $((NOW0 + 300)) rt1
  cli 1 "Error: something unexpected happened"
  run_at 0
  run_at 120
  assert_eq "$(payloads)" 0 "no alert after 2 errors"
  assert_grep "$T/out.log" "next=120s" "fail sleep"
  run_at 240
  assert_eq "$(payloads)" 1 "alert on 3rd error"
  assert_grep "$STUB/webhook.payloads" "3 times in a row" "streak in text"
  run_at 360
  assert_eq "$(payloads)" 1 "no duplicate"
  mkcreds "$T/rotated" $((NOW0 + H8)) rt2
  cli 0 "ok" "$T/rotated"
  run_at 480
  assert_eq "$(payloads)" 2 "recovery"
  teardown

  setup unknown_error_transient
  mkcreds "$HOSTC" $((NOW0 + 300)) rt1
  cli 1 "Error: socket hang up"
  run_at 0
  run_at 120
  mkcreds "$T/rotated" $((NOW0 + H8)) rt2
  cli 0 "ok" "$T/rotated"
  run_at 240
  assert_eq "$RC" 0 "exit code"
  assert_eq "$(payloads)" 0 "transient errors never alert, no recovery"
  teardown
}

test_sync_failure_alerts() {
  setup sync_failed
  echo 1 >"$STUB/docker.compose.rc"
  mkcreds "$HOSTC" $((NOW0 + H8)) rt1
  run_at 0
  assert_eq "$RC" 1 "exit code"
  assert_grep "$STUB/webhook.payloads" "sync_failed" "classified"
  assert_grep "$STUB/webhook.payloads" "volume sync failed" "detail"
  rm -f "$STUB/docker.compose.rc"
  run_at 120
  assert_eq "$(payloads)" 2 "recovered after retry"
  teardown

  setup sync_failed_config_dir
  mkcreds "$HOSTC" $((NOW0 + H8)) rt2
  mkcreds "$CFGC" $((NOW0 + 100)) rt1
  chmod 500 "$COMPOSE_DIR/claude-config"        # cannot write into it
  run_at 0
  assert_grep "$STUB/webhook.payloads" "claude-config copy expires" "verify mismatch detail"
  teardown
}

test_no_webhook_logs_alert() {
  setup no_webhook
  export ALERT_WEBHOOK_URL=""
  export CLAUDE_REFRESH_LOG_FILE="$T/refresh.log"
  mkcreds "$HOSTC" $((NOW0 + 100)) rt1
  mkdead "$T/dead"
  cli 1 "Failed to authenticate: OAuth session expired and could not be refreshed" "$T/dead"
  run_at 0
  assert_grep "$T/out.log" "alerting is not configured" "startup warning"
  assert_grep "$T/out.log" "ALERT \[ALERT\] testdeploy: Claude chat is failing" "ALERT log line"
  assert_missing "$STUB/curl.calls" "curl not called"
  assert_grep "$T/refresh.log" "status=auth_dead" "log file mirror"
  teardown
}

test_webhook_failure_is_not_fatal() {
  setup webhook_failure
  echo 22 >"$STUB/curl.rc"
  mkcreds "$HOSTC" $((NOW0 + 100)) rt1
  cli 1 "Failed to authenticate: OAuth session expired and could not be refreshed"
  run_at 0
  assert_grep "$T/out.log" "alert delivery failed (curl rc=22" "failure logged"
  assert_grep "$T/out.log" "status=auth_dead" "wake completed"
  assert_no_grep "$STUB/curl.calls" "hooks.example.test" "URL not on the command line"
  assert_grep "$STUB/curl.config" "hooks.example.test" "URL passed via config"
  rm -f "$STUB/curl.rc"
  run_at 60
  assert_eq "$(calls curl)" 2 "retried next wake"
  assert_grep "$T/out.log" "alert sent" "delivered on retry"
  run_at 120
  assert_eq "$(calls curl)" 2 "no further posts"
  teardown
}

test_alert_test_mode() {
  setup alert_test
  export CLAUDE_REFRESH_ALERT_TEST=1
  run_at 0
  assert_eq "$RC" 0 "exit code"
  assert_eq "$(payloads)" 1 "one test alert"
  assert_grep "$STUB/webhook.payloads" "\[TEST\] testdeploy" "test text"
  assert_missing "$STUB/claude.calls" "no CLI call"
  if python3 -c 'import json,sys; json.loads(open(sys.argv[1]).readline())' "$STUB/webhook.payloads"; then ok; else bad "payload is valid JSON"; fi
  echo 7 >"$STUB/curl.rc"
  run_at 0
  assert_eq "$RC" 1 "exit code when POST fails"
  export ALERT_WEBHOOK_URL=""
  run_at 0
  assert_eq "$RC" 2 "exit code without webhook"
  assert_grep "$T/out.log" "ALERT_WEBHOOK_URL is not set" "explains"
  teardown
}

test_sourcing_does_not_run_main() {
  setup sourcing
  out="$("$BASH" -c ". '$DAEMON'; type run_wake >/dev/null && echo sourced-ok" 2>&1)"
  assert_eq "$out" "sourced-ok" "functions available, main not run"
  teardown
}

# --- run --------------------------------------------------------------------

echo "bash: $BASH ($BASH_VERSION)"
if "$BASH" -n "$DAEMON"; then ok; else bad "bash -n"; fi
for t in $(declare -F | awk '{print $3}' | grep '^test_'); do
  "$t"
done
echo "passed: $PASS  failed: $FAIL"
[ "$FAIL" -eq 0 ]
