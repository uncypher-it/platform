# Self-Hosted Deployment

Uncypher is an AI-powered data platform that lets your team query databases in natural language, build a knowledge graph of your data assets, and run AI agents against your codebase. Self-hosting gives you full control over your data, network boundaries, and AI provider keys.

Deploy on your own infrastructure using Docker Compose — pre-built container images, no source code, no build step.

---

## Architecture

```
                         Internet
                            |
                  +---------+---------+
                  |      Traefik      |  HTTPS, TLS, security headers,
                  |    (port 443)     |  rate limiting, IP allowlist
                  +---------+---------+
                            |
    ╔═══════════════════════╧═══════════════════════╗
    ║              Uncypher Platform                 ║
    ║                                               ║
    ║   Frontend             Backend                ║
    ║   (Web UI)             (API + AI Chat)        ║
    ║                        Code Agents            ║
    ║                        (Claude / Codex)       ║
    ║                                               ║
    ╚═══════════════════════╤═══════════════════════╝
                            |
                  +---------+---------+
                  |   Egress Proxy    |  Allowlisted domains only,
                  |    (Squid)        |  audit logging
                  +---------+---------+
                            |
                  OpenAI · Anthropic · GitHub
```

**Security posture:**

- **Network isolation** — All services run on an internal Docker network with no internet access. Even a compromised container cannot reach the internet directly.
- **Egress control** — Outbound API calls route through a Squid proxy that only allows explicitly allowlisted domains. All egress is logged for compliance.
- **TLS termination** — Traefik handles HTTPS with automatic Let's Encrypt or your own certs. Security headers (HSTS, X-Frame-Options, Content-Type-Nosniff) applied to all responses.
- **Access control** — Built-in IP allowlisting and rate limiting at the ingress layer.
- **Secrets management** — Database passwords and JWT keys are generated during setup. No default credentials ship in production.

---

## Prerequisites

| Requirement | Minimum |
|-------------|---------|
| Docker | 24+ |
| Docker Compose | v2 |
| RAM | 8 GB |
| Disk | 20 GB free |
| Ports | 80, 443 (configurable) |
| DNS | 4 A or CNAME records pointing to your server |

---

## Quick Start

```bash
git clone https://github.com/uncypher-it/platform.git uncypher
cd uncypher

chmod +x setup.sh
./setup.sh
```

The setup script walks you through configuration interactively, pulls images, starts all services, and verifies health checks. Once complete, open `https://<your-domain>` to access Uncypher.

---

## Configuration

The installer prompts for each value below. Press Enter to accept defaults where shown.

| Prompt | Required | What it does |
|--------|----------|-------------|
| **Base domain** | Yes | e.g. `uncypher.yourco.com` — subdomains (`api.`, `kb.`, `codebase.`) are derived automatically |
| **TLS mode** | Yes | Let's Encrypt (default) for automatic HTTPS, or static certificates for internal CAs |
| **ACME email** | If Let's Encrypt | Email for certificate expiry notifications |
| **Database passwords** | Yes | Auto-generated secure passwords if you press Enter |
| **OpenAI API key** | Yes | Powers the AI chat agent. Get one at [platform.openai.com/api-keys](https://platform.openai.com/api-keys) |
| **Anthropic API key** | No | For the Claude Code codebase agent. Can also authenticate via OAuth after setup |

The setup script also auto-generates a JWT signing key and configures all internal service URLs. Everything is saved to `.env` — edit it anytime and run `docker compose up -d` to apply changes. See `.env.example` for the full list of advanced options.

### Choosing an image tag

Every `siddhsingh/uncypher:*` reference in `docker-compose.yml` is suffixed by `${TAG_SUFFIX:--20apr-arm}` — when `TAG_SUFFIX` is unset, the current SuperK ARM build is used. To pin a different build (e.g. an x86_64 build for an Intel/AMD VM), set `TAG_SUFFIX` in `.env`:

```bash
TAG_SUFFIX=-12may-x86   # x86_64 build dated 12 May
```

Then `docker compose pull && docker compose up -d`. Rolling back is just changing the suffix and re-running.

---

## TLS Setup

### Let's Encrypt (default)

Automatic HTTPS — zero configuration beyond an email address. Requires:
- Domains resolving to your server's IP
- Ports 80 and 443 open to the internet

### Static Certificates

For internal CAs, air-gapped environments, or wildcard certs:

1. Place `fullchain.pem` and `privkey.pem` in `./certs/`
2. Select "Static certificates" when prompted during setup

---

## DNS Setup

Create four DNS records pointing to your server:

| Record | Type | Value |
|--------|------|-------|
| `uncypher.yourco.com` | A / CNAME | `<server-ip>` |
| `api.uncypher.yourco.com` | A / CNAME | `<server-ip>` |
| `kb.uncypher.yourco.com` | A / CNAME | `<server-ip>` |
| `codebase.uncypher.yourco.com` | A / CNAME | `<server-ip>` |

A wildcard record (`*.uncypher.yourco.com`) also works.

---

## Connecting Enterprise Databases

Uncypher connects to your existing databases at runtime through the web UI. No database credentials are stored in the deployment configuration — users provide connection details when adding a data source.

**Supported:** PostgreSQL, MySQL, Amazon Redshift, Trino / Presto

If your databases are not reachable from the Docker network, add a route or use Docker's `extra_hosts` in the compose file.

---

## Data Residency & Egress Control

All outbound traffic routes through a Squid forward proxy. Only explicitly allowlisted domains are reachable.

**Default allowlist:**

| Domain | Purpose |
|--------|---------|
| `.openai.com`, `.oaiusercontent.com` | AI chat agent, Codex |
| `.anthropic.com` | Claude Code agent |
| `.github.com`, `.githubusercontent.com` | Repository cloning |
| `.letsencrypt.org` | TLS certificate issuance |

**Customize:**

```bash
# Add a domain (e.g., Azure OpenAI for EU data residency)
echo ".openai.azure.com" >> egress-proxy/allowed_domains.txt
docker compose restart egress-proxy

# View egress audit logs
docker compose exec egress-proxy tail -50 /var/log/squid/access.log
```

---

## Operations

```bash
# Upgrade to latest images
docker compose pull && docker compose up -d

# View logs
docker compose logs -f              # all services
docker compose logs -f backend      # single service

# Check service health
docker compose ps

# Backup databases
docker exec uncypher-postgres pg_dump -U postgres data_decipher > backup_main.sql
docker exec uncypher-kb-postgres pg_dump -U kb kb > backup_kb.sql

# Stop all services
docker compose down

# Stop and destroy all data (irreversible)
docker compose down -v
```

---

## Troubleshooting

| Problem | Fix |
|---------|-----|
| Services not starting | `docker compose logs <service>` — usually a missing env var |
| Frontend shows blank page | Verify `NEXT_PUBLIC_API_URL` matches `API_DOMAIN` in `.env` |
| TLS certificate errors | Ensure DNS resolves to server IP; check `docker compose logs traefik` |
| External API calls failing | Check `egress-proxy/allowed_domains.txt` for missing domains |
| Claude/codebase agent 401 | Set `ANTHROPIC_API_KEY`, or run `claude login` on the host and start `claude-auth-refresh.service` |
| Port conflicts | Set `TRAEFIK_HTTP_PORT` / `TRAEFIK_HTTPS_PORT` in `.env` |
