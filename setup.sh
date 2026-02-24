#!/usr/bin/env bash
# =============================================================================
# Uncypher Self-Hosted — Guided Setup
# =============================================================================
# Interactive installer that walks you through configuration, then starts
# the full stack. Run it once on a fresh server — it handles everything.
#
# Usage:
#   chmod +x setup.sh
#   ./setup.sh
# =============================================================================

set -euo pipefail

ENV_FILE=".env"
ENV_EXAMPLE=".env.example"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; }
fatal() { error "$*"; exit 1; }

sed_inplace() {
  if [[ "$OSTYPE" == "darwin"* ]]; then
    sed -i '' "$@"
  else
    sed -i "$@"
  fi
}

# Prompt for a value. Usage: ask "prompt" "default" VARNAME
ask() {
  local prompt="$1"
  local default="$2"
  local varname="$3"
  local input

  if [ -n "$default" ]; then
    printf "  ${CYAN}%s${NC} [${BOLD}%s${NC}]: " "$prompt" "$default"
  else
    printf "  ${CYAN}%s${NC}: " "$prompt"
  fi
  read -r input
  if [ -z "$input" ]; then
    input="$default"
  fi
  printf -v "$varname" '%s' "$input"
}

# Prompt for a secret (hidden input). Usage: ask_secret "prompt" VARNAME
ask_secret() {
  local prompt="$1"
  local varname="$2"
  local input

  printf "  ${CYAN}%s${NC}: " "$prompt"
  read -rs input
  echo ""
  printf -v "$varname" '%s' "$input"
}

# Generate random password (24 hex chars)
gen_password() {
  openssl rand -hex 12
}

# Generate random secret (64 hex chars)
gen_secret() {
  openssl rand -hex 32
}

# Write a key=value to the env file, replacing if exists or appending.
# Uses python3 for safe replacement — no sed escaping issues with special chars.
set_env() {
  local key="$1"
  local value="$2"

  if grep -q "^${key}=" "$ENV_FILE" 2>/dev/null || grep -q "^# *${key}=" "$ENV_FILE" 2>/dev/null; then
    python3 -c "
import re, sys
k, v = sys.argv[1], sys.argv[2]
with open(sys.argv[3]) as f: txt = f.read()
txt = re.sub(rf'^#?\s*{re.escape(k)}=.*', f'{k}={v}', txt, count=1, flags=re.MULTILINE)
with open(sys.argv[3], 'w') as f: f.write(txt)
" "$key" "$value" "$ENV_FILE"
  else
    echo "${key}=${value}" >> "$ENV_FILE"
  fi
}

# =============================================================================
echo ""
echo -e "${BOLD}╔══════════════════════════════════════════╗${NC}"
echo -e "${BOLD}║       Uncypher Self-Hosted Setup         ║${NC}"
echo -e "${BOLD}╚══════════════════════════════════════════╝${NC}"
echo ""

# ---------------------------------------------------------
# 1. Check prerequisites
# ---------------------------------------------------------
info "Checking prerequisites..."

if ! command -v docker &>/dev/null; then
  fatal "Docker is not installed. See https://docs.docker.com/engine/install/"
fi

if ! docker compose version &>/dev/null; then
  fatal "Docker Compose v2 is not installed. See https://docs.docker.com/compose/install/"
fi

DOCKER_VERSION=$(docker version --format '{{.Server.Version}}' 2>/dev/null || echo "unknown")
info "Docker version: ${DOCKER_VERSION}"

if ! command -v openssl &>/dev/null; then
  fatal "openssl is required for generating secrets. Install it and re-run."
fi

if ! command -v python3 &>/dev/null; then
  fatal "python3 is required. Install it and re-run."
fi

info "Prerequisites OK"
echo ""

# ---------------------------------------------------------
# 2. Prepare .env file
# ---------------------------------------------------------
if [ -f "$ENV_FILE" ]; then
  echo -e "  An existing ${BOLD}.env${NC} file was found."
  ask "Overwrite with fresh config? (y/N)" "N" OVERWRITE
  if [[ "$OVERWRITE" =~ ^[Yy]$ ]]; then
    cp "$ENV_EXAMPLE" "$ENV_FILE"
    info "Reset .env from ${ENV_EXAMPLE}"
  else
    info "Keeping existing .env — updating values interactively"
  fi
else
  if [ -f "$ENV_EXAMPLE" ]; then
    cp "$ENV_EXAMPLE" "$ENV_FILE"
    info "Created .env from ${ENV_EXAMPLE}"
  else
    fatal "Neither .env nor ${ENV_EXAMPLE} found. Cannot continue."
  fi
fi
echo ""

# ---------------------------------------------------------
# 3. Domain configuration
# ---------------------------------------------------------
echo -e "${BOLD}── 1. Domain Configuration ──${NC}"
echo ""
echo "  Enter your base domain. Subdomains are derived automatically:"
echo "  api.<base>, kb.<base>, codebase.<base>"
echo ""

ask "Base domain (e.g. uncypher.yourco.com)" "" BASE_DOMAIN

if [ -z "$BASE_DOMAIN" ]; then
  fatal "A domain is required. Example: uncypher.yourco.com"
fi

FRONTEND_DOMAIN="$BASE_DOMAIN"
API_DOMAIN="api.${BASE_DOMAIN}"
KB_DOMAIN="kb.${BASE_DOMAIN}"
CODEBASE_DOMAIN="codebase.${BASE_DOMAIN}"

echo ""
echo "  Domains:"
echo -e "    Frontend:  ${GREEN}${FRONTEND_DOMAIN}${NC}"
echo -e "    API:       ${GREEN}${API_DOMAIN}${NC}"
echo -e "    KB:        ${GREEN}${KB_DOMAIN}${NC}"
echo -e "    Codebase:  ${GREEN}${CODEBASE_DOMAIN}${NC}"
echo ""

set_env "FRONTEND_DOMAIN" "$FRONTEND_DOMAIN"
set_env "API_DOMAIN" "$API_DOMAIN"
set_env "KB_DOMAIN" "$KB_DOMAIN"
set_env "CODEBASE_DOMAIN" "$CODEBASE_DOMAIN"
set_env "FRONTEND_URL" "https://${FRONTEND_DOMAIN}"
set_env "NEXT_PUBLIC_API_URL" "https://${API_DOMAIN}"
set_env "NEXT_PUBLIC_KBV1_URL" "https://${KB_DOMAIN}"
set_env "CORS_ALLOWED_ORIGINS" "https://${FRONTEND_DOMAIN},https://${API_DOMAIN},https://${KB_DOMAIN}"

# ---------------------------------------------------------
# 4. TLS configuration
# ---------------------------------------------------------
echo -e "${BOLD}── 2. TLS Configuration ──${NC}"
echo ""
echo "  1) Let's Encrypt — automatic HTTPS (requires public DNS + ports 80/443)"
echo "  2) Static certificates — bring your own certs"
echo ""

ask "TLS mode [1/2]" "1" TLS_MODE

if [ "$TLS_MODE" = "2" ]; then
  set_env "TLS_CERT_RESOLVER" ""
  # Enable static cert config in tls.yml
  if [ -f "traefik/dynamic/tls.yml" ]; then
    sed_inplace 's/^  # certificates:/  certificates:/' traefik/dynamic/tls.yml
    sed_inplace 's/^  #   - certFile:/    - certFile:/' traefik/dynamic/tls.yml
    sed_inplace 's/^  #     keyFile:/      keyFile:/' traefik/dynamic/tls.yml
  fi
  echo ""
  info "Static TLS selected."
  info "Place fullchain.pem and privkey.pem in ./certs/ before starting."
else
  set_env "TLS_CERT_RESOLVER" "letsencrypt"
  echo ""
  ask "Email for Let's Encrypt notifications" "" ACME_EMAIL
  if [ -z "$ACME_EMAIL" ]; then
    fatal "An email is required for Let's Encrypt certificate issuance."
  fi
  set_env "ACME_EMAIL" "$ACME_EMAIL"
fi
echo ""

# ---------------------------------------------------------
# 5. Database passwords
# ---------------------------------------------------------
echo -e "${BOLD}── 3. Database Credentials ──${NC}"
echo ""
echo "  Secure passwords are auto-generated. Press Enter to accept,"
echo "  or type your own."
echo ""

PG_PASS_DEFAULT=$(gen_password)
ask "Primary database password" "$PG_PASS_DEFAULT" POSTGRES_PASSWORD
set_env "POSTGRES_PASSWORD" "$POSTGRES_PASSWORD"

KB_PASS_DEFAULT=$(gen_password)
ask "Knowledge Base database password" "$KB_PASS_DEFAULT" KB_POSTGRES_PASSWORD
set_env "KB_POSTGRES_PASSWORD" "$KB_POSTGRES_PASSWORD"
echo ""

# ---------------------------------------------------------
# 6. JWT secret (always auto-generated)
# ---------------------------------------------------------
JWT_SECRET=$(gen_secret)
set_env "JWT_SECRET_KEY" "$JWT_SECRET"
info "JWT secret key generated"
echo ""

# ---------------------------------------------------------
# 7. AI Provider — OpenAI (required)
# ---------------------------------------------------------
echo -e "${BOLD}── 4. AI Provider ──${NC}"
echo ""
echo "  An OpenAI API key powers the AI chat agent."
echo "  Get one at https://platform.openai.com/api-keys"
echo ""

ask_secret "OpenAI API key (sk-...)" OPENAI_API_KEY
if [ -z "$OPENAI_API_KEY" ]; then
  fatal "An OpenAI API key is required for the chat agent to function."
fi
set_env "OPENAI_API_KEY" "$OPENAI_API_KEY"
set_env "OPENAI_AGENT_MODEL" "gpt-5.2"
echo ""

# ---------------------------------------------------------
# 8. Codebase Agent — Anthropic (optional)
# ---------------------------------------------------------
echo -e "${BOLD}── 5. Codebase Agent (optional) ──${NC}"
echo ""
echo "  The codebase agent uses Claude (Anthropic) by default."
echo "  Provide an API key now, or authenticate via OAuth after setup."
echo ""

ask_secret "Anthropic API key (press Enter to skip)" ANTHROPIC_API_KEY
if [ -n "$ANTHROPIC_API_KEY" ]; then
  set_env "ANTHROPIC_API_KEY" "$ANTHROPIC_API_KEY"
  info "Anthropic API key saved"
else
  info "Skipped — authenticate later with:"
  echo "    docker compose run --rm codebase-claude-runner claude login"
fi
echo ""

# ---------------------------------------------------------
# 9. Create required directories
# ---------------------------------------------------------
info "Creating directories..."
mkdir -p traefik/dynamic
mkdir -p egress-proxy
mkdir -p kb-init-sql
mkdir -p certs

# ---------------------------------------------------------
# 10. Summary
# ---------------------------------------------------------
echo ""
echo -e "${BOLD}── Configuration Summary ──${NC}"
echo ""
echo -e "  Domains:       ${GREEN}${FRONTEND_DOMAIN}${NC} + 3 subdomains"
if [ "$TLS_MODE" = "2" ]; then
  echo -e "  TLS:           ${GREEN}Static certificates${NC}"
else
  echo -e "  TLS:           ${GREEN}Let's Encrypt${NC} (${ACME_EMAIL})"
fi
echo -e "  DB passwords:  ${GREEN}configured${NC}"
echo -e "  JWT secret:    ${GREEN}auto-generated${NC}"
echo -e "  OpenAI key:    ${GREEN}configured${NC}"
if [ -n "${ANTHROPIC_API_KEY:-}" ]; then
  echo -e "  Anthropic key: ${GREEN}configured${NC}"
else
  echo -e "  Anthropic key: ${YELLOW}skipped (OAuth later)${NC}"
fi
echo ""

# ---------------------------------------------------------
# 11. Pull images and start
# ---------------------------------------------------------
echo -e "${BOLD}── Starting Uncypher ──${NC}"
echo ""

info "Pulling images..."
docker compose pull

info "Starting services..."
docker compose up -d

# ---------------------------------------------------------
# 12. Wait for health checks
# ---------------------------------------------------------
info "Waiting for services to become healthy (up to 120s)..."

TIMEOUT=120
ELAPSED=0
while [ $ELAPSED -lt $TIMEOUT ]; do
  UNHEALTHY=$(docker compose ps --format json 2>/dev/null | \
    python3 -c "
import sys, json
unhealthy = []
for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    svc = json.loads(line)
    health = svc.get('Health', svc.get('health', ''))
    status = svc.get('State', svc.get('state', ''))
    if status == 'running' and health and health != 'healthy':
        unhealthy.append(svc.get('Name', svc.get('name', 'unknown')))
print(len(unhealthy))
" 2>/dev/null || echo "?")

  if [ "$UNHEALTHY" = "0" ]; then
    break
  fi
  if [ "$UNHEALTHY" = "?" ]; then
    warn "Could not parse service health status."
    warn "Check manually: docker compose ps"
    break
  fi
  sleep 5
  ELAPSED=$((ELAPSED + 5))
  printf "."
done
echo ""

if [ "$ELAPSED" -ge "$TIMEOUT" ]; then
  warn "Some services may not be healthy yet. Check with:"
  warn "  docker compose ps"
else
  info "All services are healthy!"
fi

# ---------------------------------------------------------
# 13. Done
# ---------------------------------------------------------
echo ""
echo -e "${BOLD}╔══════════════════════════════════════════╗${NC}"
echo -e "${BOLD}║         Uncypher is running!             ║${NC}"
echo -e "${BOLD}╚══════════════════════════════════════════╝${NC}"
echo ""
echo -e "  ${BOLD}Frontend${NC}:  https://${FRONTEND_DOMAIN}"
echo -e "  ${BOLD}API${NC}:       https://${API_DOMAIN}"
echo -e "  ${BOLD}KB${NC}:        https://${KB_DOMAIN}"
echo -e "  ${BOLD}Codebase${NC}:  https://${CODEBASE_DOMAIN}"
echo ""
echo "  Make sure DNS records point to this server:"
echo "    ${FRONTEND_DOMAIN}  →  $(hostname -I 2>/dev/null | awk '{print $1}' || echo '<server-ip>')"
echo "    ${API_DOMAIN}"
echo "    ${KB_DOMAIN}"
echo "    ${CODEBASE_DOMAIN}"
echo ""
echo "  Commands:"
echo "    docker compose ps          # service health"
echo "    docker compose logs -f     # live logs"
echo "    docker compose down        # stop all"
echo "    docker compose pull && docker compose up -d   # upgrade"
echo ""
