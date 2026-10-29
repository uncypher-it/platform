# Claude OAuth Auto-Refresh

Several Uncypher services authenticate to Claude with **OAuth credentials** from
a Claude subscription, not a static API key: the chat agent (`chat-consumer`),
KB cleanup and bulk generation (`backend`, `celery-worker`), and the codebase
`claude-runner`. One host daemon keeps those credentials alive and **says so
loudly when it can't**:

- daemon: [`../scripts/claude-oauth-refresh-daemon.sh`](../scripts/claude-oauth-refresh-daemon.sh)
- systemd unit: [`../systemd/claude-auth-refresh.service`](../systemd/claude-auth-refresh.service)

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
showed `active (running)`. Now the daemon logs one `ALERT` line within a minute,
stops hammering, and writes a machine-readable state file every wake (see
[Alerts and the state file](#alerts-and-the-state-file)). Delivering alerts
(Slack, paging) and exporting the state as telemetry are a follow-up.

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
6. **Report:** log `ALERT`/`RESOLVED` on state changes, rewrite the state file,
   log one status line, sleep.

While the chain is dead it does not hammer: it wakes every 60 s but calls the
CLI again only when the host credentials change (someone ran `claude login`) or
30 min have passed.

> **Each VM gets its own independent OAuth chain.** Never copy `~/.claude`
> between machines: two hosts sharing one chain fight over rotation and knock
> each other offline.

---

## Alerts and the state file

**Log lines.** Entering a failing state logs exactly one `ALERT <status>: …`
line: what is broken, since when, the CLI's error line and the fix. Recovery
logs exactly one `RESOLVED <status>: …` line with the outage duration. Nothing
repeats in between; the per-wake status line (`status=auth_dead …`) shows the
state every wake. `auth_dead`, `access_disabled`, `quota` and `sync_failed`
alert immediately; an unknown `error` alerts after 3 in a row. Switching from
one failing state to another (say `access_disabled` to `quota`) logs a new
`ALERT`. No line ever contains a token.

```bash
journalctl -u claude-auth-refresh | grep -E 'ALERT|RESOLVED'
```

```
[2026-10-21T04:05:12Z] ALERT auth_dead: Claude chat is failing for every user: the Claude login on the host has expired and cannot be refreshed. Since: 2026-10-21T04:05:12Z. Error: Failed to authenticate: OAuth session expired and could not be refreshed. Fix: ssh to the host and run `claude login` as ec2-user; the daemon picks it up within a minute.
[2026-10-29T10:02:40Z] RESOLVED auth_dead: Claude chat is working again after 8d 5h (failing since 2026-10-21T04:05:12Z).
```

| Status | Meaning | Fix |
|--------|---------|-----|
| `auth_dead` | The refresh chain is dead (the monthly event), or the host has no credentials. | `ssh` to the host and run `claude login` as the deploy user. The daemon notices within a minute and logs `RESOLVED`. |
| `quota` | The subscription hit its weekly or session limit (`You've hit your weekly limit · resets …`). | Wait for the reset in the message. If it's unexpected, check who else uses the subscription. Re-checked every 30 min. |
| `access_disabled` | The account's organization disabled Claude Code subscription access. | `claude login` with a different account that has Claude Code enabled. Logging in again with the same account won't help. |
| `sync_failed` | The host refreshed but a container copy didn't update. Chat fails when the containers' token expires. | Check the journal and `docker compose ps`. Retried every 2 min. |
| `error` | An unrecognised CLI failure, 3 times in a row. | Read the journal; run `claude --print ok` as the deploy user by hand. |

**State file.** `~/.claude/claude-auth-refresh.state` (dir set by
`CLAUDE_REFRESH_STATE_DIR`) is rewritten atomically every wake (temp file +
rename), as `key=value` lines, mode 0600, owned by the deploy user. **This is
what a future telemetry collector reads.** Parse it, never `source` it; the
daemon doesn't either.

| Key | Meaning |
|-----|---------|
| `status` | This wake's status: `ok`, `auth_dead`, `quota`, `access_disabled`, `sync_failed` or `error`. `error` shows up here before its `ALERT` (which waits for 3 in a row). |
| `checked_at` | Epoch seconds of this wake. More than ~1 h old (the longest sleep) means the daemon isn't running. |
| `host_expires_at` | Host `expiresAt` in epoch ms. `0` = the CLI wiped a dead chain; `-1` = file missing or unreadable. |
| `outage_since` | Epoch seconds the current outage began (`0` = none). |
| `alerted` | Status of the outstanding `ALERT` (empty = none). |
| `cli_status`, `detail`, `error_streak`, `dead_fp`, `last_probe`, `volume_exp` | Daemon bookkeeping. `dead_fp` is a 12-hex sha256 prefix of the refresh token, never the token. |

---

## One-time setup per VM

1. **Install the Claude CLI on the host** (as the deploy user):
   `curl -fsSL https://claude.ai/install.sh | bash`. The unit's `PATH` already
   includes `~/.local/bin`.
2. **Log in interactively, on the host, as the deploy user:** `claude login`.
   Then check: `test -s ~/.claude/.credentials.json && echo ok`.
3. **Install the unit.** Replace every `DEPLOY_USER` in
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
cd ~/uncypher && git pull --ff-only          # if this is a checkout of this repo; else copy scripts/ and systemd/
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

Set with `Environment=` lines in the unit. All optional; defaults shown.

| Variable | Default | Purpose |
|----------|---------|---------|
| `COMPOSE_DIR` | `$HOME/uncypher` | Directory containing `docker-compose.yml`. The volume sync runs from here. |
| `CLAUDE_HOME` | `$HOME/.claude` | Host credentials dir. Must be the dir the CLI uses. |
| `CLAUDE_CLI` | `claude` | Host Claude CLI (name or absolute path), found via the unit's `PATH`. |
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

Tests: `bash tests/claude-auth/test_refresh_daemon.sh` (stubs `claude` and
`docker`; runs on macOS bash 3.2 and Linux bash 5).

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
| `ALERT auth_dead`, or chat says `Failed to authenticate` / `API Error: 401` | The chain died (expect it monthly). Run `claude login` on the host as the deploy user; a `RESOLVED` line follows within a minute. |
| `cli=skip:no-host-tokens` every minute | Same: the CLI dropped the dead tokens from `~/.claude/.credentials.json`. Log in. |
| State file `checked_at` is stale | The daemon isn't running. `systemctl status claude-auth-refresh`; read the journal for the crash. |
| `cfg=unreadable` | The config copy is root-owned and `docker exec` failed (consumer down?). The daemon still replaces the file; check `docker ps`. |
| `ALERT sync_failed: … volume sync failed: …` | `docker compose run backend` failed: wrong `COMPOSE_DIR`, Docker down, or the deploy user isn't in the `docker` group. |
| Daemon refreshes but containers still 401 | A container cached an old token. `docker compose restart chat-consumer backend celery-worker codebase-claude-runner`. |
| Two refreshers fighting (log lines from both) | The old hand-installed unit or script is still running. See the migration steps. |
