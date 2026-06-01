# Claude OAuth Auto-Refresh

Several Uncypher services authenticate to Claude with **OAuth credentials**, not
a static API key:

- the **chat / dataflow generation** agent in `backend` + `celery-worker`
- the **codebase claude-runner** agent

All of them read the same `claude_credentials` Docker volume, which is mounted at
`/root/.claude` inside each container (see `docker-compose.yml`).

Claude OAuth access tokens are **short-lived**. They are minted with an
`expiresAt` a few hours out and must be rotated by an authenticated Claude CLI
before they lapse. If nothing rotates them, the refresh token chain eventually
goes stale and **every Claude-backed feature starts returning
`API Error: 401 — Failed to authenticate`** — with no other symptom. This is
exactly what took down the Merlin deployment: the OAuth chain quietly expired a
few days after `claude login`, and dataflow generation + the codebase agent both
started 401-ing at once.

This directory documents the host-based daemon that keeps that volume fresh on
every VM. The daemon itself lives at
[`../scripts/claude-oauth-refresh-daemon.sh`](../scripts/claude-oauth-refresh-daemon.sh)
and the systemd unit at
[`../systemd/claude-auth-refresh.service`](../systemd/claude-auth-refresh.service).

---

## How it works (host-based design)

The Claude CLI runs **on the host**, not in a container. The daemon loops:

1. Check `expiresAt` in the host `~/.claude/.credentials.json`.
2. If the token is near expiry, run `claude --print --max-turns 1` on the host.
   That single authenticated call forces the CLI to rotate the OAuth token and
   rewrite `~/.claude/.credentials.json`.
3. Sync the refreshed `~/.claude/.credentials.json` into the
   `claude_credentials` Docker volume by running a throwaway container:

   ```bash
   docker compose run --rm --no-deps \
     --volume "$HOME/.claude:/host-claude:ro" \
     --entrypoint sh backend \
     -c 'cp /host-claude/.credentials.json /root/.claude/.credentials.json ...'
   ```

   The host `~/.claude` is mounted read-only; only the credentials file is
   copied (atomically, `chmod 600`).
4. Sleep until ~1 minute past the new `expiresAt`, clamped to a sane range so a
   bad timestamp can never wedge the loop, then repeat.

Because the CLI lives on the host and the containers only ever *read* a synced
copy, the rotating refresh-token chain has a single owner per VM.

---

## One-time setup per VM

> **Each VM gets its own independent OAuth chain.**
> Run `claude login` interactively on every VM. **Never copy
> `~/.claude/.credentials.json` (or any of `~/.claude`) from one machine to
> another** — two hosts sharing one chain will fight over rotation and knock
> each other offline with 401s. One login, one host, one chain.

1. **Install the Claude CLI on the host** (as the deploy user):

   ```bash
   curl -fsSL https://claude.ai/install.sh | bash
   # ensure ~/.local/bin is on PATH (the systemd unit already adds it)
   ```

2. **Log in interactively, on the host, as the deploy user.** This is the one
   step that cannot be automated — it opens a browser auth flow:

   ```bash
   claude login
   ```

   Confirm it worked:

   ```bash
   test -s ~/.claude/.credentials.json && echo "credentials present"
   ```

3. **Point the daemon at your Compose directory.** The sync step runs
   `docker compose run ...` and must execute from the directory that holds
   `docker-compose.yml`. Set `COMPOSE_DIR` accordingly (it defaults to
   `$HOME/uncypher`).

4. **Install and enable the systemd unit.** First edit
   `../systemd/claude-auth-refresh.service` and replace every `DEPLOY_USER`
   placeholder with the actual deploy user (e.g. `ec2-user`, `ubuntu`), and fix
   the home/Compose paths to match. Then:

   ```bash
   sudo cp systemd/claude-auth-refresh.service /etc/systemd/system/
   sudo systemctl daemon-reload
   sudo systemctl enable --now claude-auth-refresh.service
   ```

5. **Verify the daemon is healthy:**

   ```bash
   systemctl status claude-auth-refresh.service
   journalctl -u claude-auth-refresh.service -f
   ```

   You should see periodic `credentials synced; expires in <N>s; sleeping <N>s`
   log lines.

---

## Configuration

The daemon reads these environment variables (all optional, defaults shown):

| Variable | Default | Purpose |
|----------|---------|---------|
| `COMPOSE_DIR` | `$HOME/uncypher` | Directory containing `docker-compose.yml`; the sync runs from here. |
| `CLAUDE_HOME` | `$HOME/.claude` | Host Claude config/credentials directory. |
| `CLAUDE_CLI` | `claude` | Claude CLI binary (name or absolute path). |
| `COMPOSE_PROJECT_NAME` | _(unset)_ | Set to match your deployment so the sync container joins the right project. |
| `CLAUDE_REFRESH_WINDOW_SECONDS` | `1800` | Refresh once the token is within this many seconds of expiry. |
| `CLAUDE_REFRESH_MIN_SLEEP_SECONDS` | `300` | Floor on the sleep between cycles. |
| `CLAUDE_REFRESH_MAX_SLEEP_SECONDS` | `3600` | Cap on the sleep between cycles. |
| `CLAUDE_REFRESH_FAIL_SLEEP_SECONDS` | `120` | Backoff after a failed refresh/sync. |
| `CLAUDE_SKIP_HOST_REFRESH` | `0` | Set `1` to sync the existing host credentials without invoking the CLI. |
| `CLAUDE_REFRESH_ONCE` | `0` | Set `1` to run a single refresh+sync and exit (useful for testing). |

To run a one-shot sync by hand (e.g. right after `claude login`):

```bash
COMPOSE_DIR=$HOME/uncypher CLAUDE_REFRESH_ONCE=1 \
  scripts/claude-oauth-refresh-daemon.sh
```

---

## Alternative: static API key

If you would rather not run the OAuth daemon, set `ANTHROPIC_API_KEY` in `.env`
instead. A static key never expires and needs no daemon — but it bills against
the API console rather than a Claude subscription. OAuth + this daemon is the
recommended path for subscription-backed deployments.

---

## Troubleshooting

| Symptom | Likely cause / fix |
|---------|--------------------|
| `API Error: 401` from chat or codebase agent | OAuth chain expired. Confirm the daemon is running (`systemctl status claude-auth-refresh.service`); if the chain is fully stale, re-run `claude login` on the host. |
| `host credentials missing ... run 'claude login'` in logs | No `~/.claude/.credentials.json` on the host. Run `claude login` as the deploy user. |
| `compose dir not found` in logs | `COMPOSE_DIR` does not point at the directory containing `docker-compose.yml`. Fix `Environment=COMPOSE_DIR=...` in the unit. |
| Daemon refreshes but containers still 401 | The running containers cached the old token at start. `docker compose restart backend celery-worker codebase-claude-runner` to pick up the synced credentials. |
