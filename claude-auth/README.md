# Claude OAuth Auto-Refresh

Several Uncypher services authenticate to Claude with **OAuth credentials** from
a Claude subscription, not a static API key: the chat agent (`chat-consumer`),
KB cleanup and bulk generation (`backend`, `celery-worker`), and the codebase
`claude-runner`. One host daemon keeps those credentials alive and **alerts when
it can't**:

- daemon: [`../scripts/claude-oauth-refresh-daemon.sh`](../scripts/claude-oauth-refresh-daemon.sh)
- systemd unit: [`../systemd/claude-auth-refresh.service`](../systemd/claude-auth-refresh.service)
- settings: `refresh.env` (copy [`refresh.env.example`](refresh.env.example); gitignored)

---

## Expect the chain to die about once a month

Claude OAuth access tokens last ~8 hours and are rotated with a refresh token.
The refresh chain itself does **not** last forever: on SuperK it died four times
(07-24, 08-20, 09-22, 10-21), each of the last three **27–29 days after the
operator's `claude login`**. When it dies, every Claude-backed feature fails
with `Failed to authenticate: OAuth session expired and could not be refreshed`,
and **the only fix is a human running `claude login` on the host**.

The 10-21 death took chat down for 8 days because nothing said so: the old
daemon retried every 60 s, logged ~1,400 failures a day, and systemd still
showed `active (running)`. Now the daemon sends an alert within a minute and
again every 6 h until someone logs in. **Configure the webhook on every host.**

---

## How it works

There are up to three copies of the credentials on a host:

| Copy | Where | Used by |
|------|-------|---------|
| host | `~/.claude/.credentials.json` | the chain owner; `claude login` writes it |
| volume | `claude_credentials` named volume, `/root/.claude` | backend, celery-worker, chat-consumer, codebase-claude-runner |
| config | `$COMPOSE_DIR/claude-config/.credentials.json`, bind-mounted as chat-consumer's `CLAUDE_CONFIG_DIR` | the native chat harness. Synced only when the dir exists |

Each wake, the daemon:

1. **Newest wins.** The consumer's own CLI may rotate the token in the config
   copy first. If that copy is newer than the host's, the daemon adopts it
   (backup at `.credentials.json.pre-adopt`). The consumer runs as root and may
   leave the file `root:root 0600`; the daemon then reads it with
   `docker exec uncypher-chat-consumer`.
2. **Refresh early.** Once the host token is within 10 min of expiry, it runs
   `claude --print` every ~2 min until `expiresAt` moves forward. The CLI rotates
   only in the last ~5 min, so the first call or two rotate nothing; each call is
   a tiny inference against the subscription, which is why the window is short. Outside that
   window it sleeps until the window opens, at least 5 min and at most 1 h (the
   hourly wake is the heartbeat).
3. **Classify** the CLI result: `ok`, `auth_dead`, `quota`, `access_disabled`
   or `error` (unknown).
4. **Sync by the credentials, not the exit code.** Valid host credentials go to
   every older copy. A quota error still rotates the token, so the copies still
   get synced. Invalid credentials are never copied: a missing file, no tokens,
   `expiresAt` 0 or in the past, or credentials the CLI just reported as dead.
   The config copy is written with temp file + `mv`, which also replaces a
   root-owned file.
5. **Verify** that the config copy now matches the host `expiresAt`. A mismatch
   or a failed volume sync is `sync_failed`.
6. **Alert** on state changes, persist state in `~/.claude/claude-auth-refresh.state`,
   log one line, sleep.

While the chain is dead it does not hammer: it wakes every 60 s but calls the
CLI again only when the host credentials change (someone ran `claude login`) or
30 min have passed.

> **Each VM gets its own independent OAuth chain.** Never copy `~/.claude`
> between machines: two hosts sharing one chain fight over rotation and knock
> each other offline.

---

## Alerts

Alerts go to any Slack-compatible incoming webhook (`POST {"text": "..."}`).
They name the deployment, say what is broken, since when, the CLI's error line
and the fix. They never contain tokens.

| Alert | Meaning | Fix |
|-------|---------|-----|
| `auth_dead` | The refresh chain is dead (the monthly event), or the host has no credentials. | `ssh` to the host and run `claude login` as the deploy user. The daemon notices within a minute and sends a recovery alert. |
| `quota` | The subscription hit its weekly or session limit (`You've hit your weekly limit · resets …`). | Wait for the reset in the message. If it's unexpected, check who else uses the subscription. Re-checked every 30 min. |
| `access_disabled` | The account's organization disabled Claude Code subscription access. | `claude login` with a different account that has Claude Code enabled. Logging in again with the same account won't help. |
| `sync_failed` | The host refreshed but a container copy didn't update. Chat fails when the containers' token expires. | Check `journalctl -u claude-auth-refresh` and `docker compose ps`. Retried every 2 min. |
| `error` | An unrecognised CLI failure, 3 times in a row. | Read the journal; run `claude --print ok` as the deploy user by hand. |
| `[RESOLVED]` | Back to `ok`, with the outage duration. | — |

Alerts fire as soon as a failure state starts (`error` waits for 3 in a row),
repeat every `ALERT_REPEAT_SECONDS` (6 h) while it lasts, and resolve once. With
no webhook configured, the daemon warns at startup and logs each alert as an
`ALERT …` line instead. A failed POST is logged and retried on the next wake;
it never stops the daemon.

**Set up and test** (as the deploy user, from the compose dir):

```bash
cp claude-auth/refresh.env.example claude-auth/refresh.env
# set ALERT_WEBHOOK_URL, ALERT_DEPLOYMENT_NAME (e.g. superk-prod), fix DEPLOY_USER
(set -a; . claude-auth/refresh.env; CLAUDE_REFRESH_ALERT_TEST=1 scripts/claude-oauth-refresh-daemon.sh)
sudo systemctl restart claude-auth-refresh.service
```

The test sends one `[TEST]` message and exits 0. It exits 1 if the POST failed
and 2 if no webhook is set.

The backend also alerts on auth/quota failures seen by chat runs. It reads
`OPS_ALERT_WEBHOOK_URL` / `OPS_ALERT_DEPLOYMENT_NAME` from `.env` (passed to
`chat-consumer` in `docker-compose.yml`) and posts through the egress proxy,
which allows `.hooks.slack.com`.

---

## One-time setup per VM

1. **Install the Claude CLI on the host** (as the deploy user):
   `curl -fsSL https://claude.ai/install.sh | bash`
2. **Log in interactively, on the host, as the deploy user:** `claude login`.
   Then check: `test -s ~/.claude/.credentials.json && echo ok`.
3. **Configure** `claude-auth/refresh.env` and test the webhook (above).
4. **Install the unit.** Replace every `DEPLOY_USER` in
   `systemd/claude-auth-refresh.service` and fix the paths if the compose dir
   isn't `~/uncypher`, then:

   ```bash
   sudo cp systemd/claude-auth-refresh.service /etc/systemd/system/
   sudo systemctl daemon-reload
   sudo systemctl enable --now claude-auth-refresh.service
   journalctl -u claude-auth-refresh.service -f
   ```

   Expect a `starting:` line, then one line per wake, e.g.
   `status=ok cli=skip:outside-window host=valid(2026-10-29T18:02:11Z,+5h 12m) cfg=direct sync=none next=3600s`.

## Migrating a host that runs the old hand-installed script

SuperK (and possibly other hosts) runs `~/refresh-claude-auth.sh` from a
hand-written unit with the same name. Replace it:

```bash
sudo systemctl stop claude-auth-refresh.service
sudo systemctl disable claude-auth-refresh.service
sudo cp /etc/systemd/system/claude-auth-refresh.service ~/claude-auth-refresh.service.old
cd ~/uncypher && git pull --ff-only          # if this is a checkout of this repo; else copy scripts/, systemd/, claude-auth/
cp claude-auth/refresh.env.example claude-auth/refresh.env   # fill in; test the webhook
sed 's/DEPLOY_USER/ec2-user/g' systemd/claude-auth-refresh.service | sudo tee /etc/systemd/system/claude-auth-refresh.service >/dev/null
sudo systemctl daemon-reload
sudo systemctl enable --now claude-auth-refresh.service
journalctl -u claude-auth-refresh.service -n 20   # one status= line per wake
systemctl cat claude-auth-refresh.service | grep ExecStart   # must be the repo script
```

Make sure only one refresher runs (`pgrep -af refresh-claude-auth` should print
nothing). Keep `~/refresh-claude-auth.sh` until the new daemon has completed one
refresh (`cli=in-window:ok`), then delete it. The old `~/.claude/refresh.log` is
no longer written unless you set `CLAUDE_REFRESH_LOG_FILE`.

---

## Configuration

Set in `refresh.env` or in the unit. All optional; defaults shown.

| Variable | Default | Purpose |
|----------|---------|---------|
| `ALERT_WEBHOOK_URL` | _(empty)_ | Slack-compatible incoming webhook. Empty means alerts are only logged. |
| `ALERT_DEPLOYMENT_NAME` | hostname | Name shown in alerts. |
| `ALERT_REPEAT_SECONDS` | `21600` | Repeat interval while a failure lasts. |
| `COMPOSE_DIR` | `$HOME/uncypher` | Directory containing `docker-compose.yml`. The volume sync runs from here. |
| `CLAUDE_HOME` | `$HOME/.claude` | Host credentials dir. Must be the dir the CLI uses. |
| `CLAUDE_CLI` | `claude` | Host Claude CLI (name or absolute path). |
| `CLAUDE_CONFIG_SYNC_DIR` | `$COMPOSE_DIR/claude-config` | chat-consumer's bind-mounted config dir. Skipped when it doesn't exist. |
| `CLAUDE_CONSUMER_CONTAINER` | `uncypher-chat-consumer` | Container used to read a root-owned config copy. |
| `CLAUDE_REFRESH_STATE_DIR` | `$CLAUDE_HOME` | Where `claude-auth-refresh.state` lives. |
| `CLAUDE_REFRESH_LOG_FILE` | _(empty)_ | Also append the log to this file (journald always gets it). |
| `CLAUDE_REFRESH_WINDOW_SECONDS` | `600` | Start refreshing this long before expiry. |
| `CLAUDE_REFRESH_POLL_SECONDS` | `120` | CLI poll interval inside the window. |
| `CLAUDE_REFRESH_MIN_SLEEP_SECONDS` / `_MAX_` | `300` / `3600` | Clamp on the sleep outside the window. |
| `CLAUDE_REFRESH_FAIL_SLEEP_SECONDS` | `120` | Retry interval after an unknown error or a failed sync. |
| `CLAUDE_REFRESH_DEAD_POLL_SECONDS` | `60` | Wake interval while the chain is dead (to notice a login). |
| `CLAUDE_REFRESH_DEAD_REPROBE_SECONDS` | `1800` | Re-check a dead or quota state this often even without a login. |
| `CLAUDE_CLI_TIMEOUT_SECONDS` | `300` | Kill a hung CLI call (needs `timeout`, standard on Linux). |
| `CLAUDE_SKIP_HOST_REFRESH` | `0` | `1` = never call the CLI; only sync the existing host credentials. |
| `CLAUDE_REFRESH_ONCE` | `0` | `1` = run one wake and exit (0 when ok). |
| `CLAUDE_REFRESH_ALERT_TEST` | `0` | `1` = send one test alert and exit. |

Tests: `bash tests/claude-auth/test_refresh_daemon.sh` (stubs `claude`, `docker`
and `curl`; runs on macOS bash 3.2 and Linux bash 5).

---

## Alternatives

**Long-lived token (not adopted yet).** `claude setup-token` mints a long-lived
OAuth token for the subscription. Passing it as `CLAUDE_CODE_OAUTH_TOKEN` to the
containers would avoid the monthly chain death and most of this daemon. Adopting
it needs a compose change (pass the env var to every Claude-backed service) and a
rotation reminder before the token expires.

**Static API key.** Set `ANTHROPIC_API_KEY` in `.env`. It never expires and needs
no daemon, but it bills the API console instead of the subscription.

---

## Troubleshooting

| Symptom | Likely cause / fix |
|---------|--------------------|
| `auth_dead` alert, or chat says `Failed to authenticate` / `API Error: 401` | The chain died (expect it monthly). Run `claude login` on the host as the deploy user; a `[RESOLVED]` alert follows within a minute. |
| `cli=skip:no-host-tokens` every minute | Same: the CLI dropped the dead tokens from `~/.claude/.credentials.json`. Log in. |
| No alerts at all, ever | `ALERT_WEBHOOK_URL` unset (see the startup `WARN`), or `refresh.env` isn't where `EnvironmentFile=` points. Run the alert test. |
| `alert delivery failed (curl rc=…)` | Webhook URL wrong or revoked, or the host can't reach Slack. The daemon retries every wake. |
| `cfg=unreadable` | The config copy is root-owned and `docker exec` failed (consumer down?). The daemon still replaces the file; check `docker ps`. |
| `sync_failed: volume sync failed: …` | `docker compose run backend` failed: wrong `COMPOSE_DIR`, Docker down, or the deploy user isn't in the `docker` group. |
| Daemon refreshes but containers still 401 | A container cached an old token. `docker compose restart chat-consumer backend celery-worker codebase-claude-runner`. |
| Two refreshers fighting (log lines from both) | The old hand-installed unit or script is still running. See the migration steps. |
