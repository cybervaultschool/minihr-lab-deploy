#!/usr/bin/env bash
#
# Run this ON THE VM.
#
# It installs Docker, generates the secrets this deployment needs, writes .env,
# and starts the stack. The generated values are created here and never leave —
# nobody types them, nobody sends them, and there is no copy of them anywhere
# else to leak.
#
#   export MINIHR_HOSTNAME=student01.lab.fortisentinel.org
#   export MICROSOFT_CLIENT_ID=...
#   export MICROSOFT_TENANT_ID=...
#   bash vm/bootstrap.sh
#
# Expects the sign-in secret at ~/signin-secret (scp'd from step 4).
# Safe to run twice: existing secrets in .env are kept, not regenerated.
#
set -euo pipefail
umask 077

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="$REPO_DIR/.env"
SECRET_FILE="${SECRET_FILE:-$HOME/signin-secret}"

fail() { echo "  $*" >&2; exit 1; }

# ── 1. Everything we were told ────────────────────────────────────────────
#
# Checked before anything is installed. A stack that starts half-configured
# gets a certificate, accepts a first sign-in, and creates state you then have
# to unpick — much worse than refusing now.
echo "Checking what you passed in..."
[ -n "${MINIHR_HOSTNAME:-}" ]      || fail "MINIHR_HOSTNAME is not set — the hostname you chose and pointed at this machine."
[ -n "${MICROSOFT_CLIENT_ID:-}" ]  || fail "MICROSOFT_CLIENT_ID is not set — from azure/03-signin-app.sh."
[ -n "${MICROSOFT_TENANT_ID:-}" ]  || fail "MICROSOFT_TENANT_ID is not set — from azure/03-signin-app.sh."
[ -f "$SECRET_FILE" ]              || fail "No sign-in secret at $SECRET_FILE. scp it from where you ran step 4."
echo "  ok"

# ── 2. DNS, before anything asks for a certificate ────────────────────────
#
# Let's Encrypt fetches a file from your hostname over port 80. If the name does
# not resolve here yet, Caddy will try, fail, and try again — and repeated
# failures for the same name are rate limited, so a premature start can lock
# you out of a certificate for the rest of the day. Cheaper to wait.
echo "Checking DNS for $MINIHR_HOSTNAME..."
MY_IP="$(curl -s --max-time 10 https://api.ipify.org || true)"
RESOLVED="$(getent hosts "$MINIHR_HOSTNAME" | awk '{print $1}' | head -1 || true)"

if [ -z "$RESOLVED" ]; then
  fail "$MINIHR_HOSTNAME does not resolve yet. Create the A record in Cloudflare pointing at this machine, with proxy status DNS only (grey cloud), then run this again."
elif [ -n "$MY_IP" ] && [ "$RESOLVED" != "$MY_IP" ]; then
  fail "$MINIHR_HOSTNAME resolves to $RESOLVED but this machine is $MY_IP. Tell your instructor the right address before starting — a certificate request for a name pointing elsewhere will fail and count against your limit."
fi
echo "  $MINIHR_HOSTNAME -> $RESOLVED (this machine)"

# ── 3. Docker ─────────────────────────────────────────────────────────────
if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
  echo "Docker is already installed."
else
  echo "Installing Docker..."
  sudo apt-get update -qq
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq ca-certificates curl >/dev/null
  sudo install -m 0755 -d /etc/apt/keyrings
  sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
  sudo chmod a+r /etc/apt/keyrings/docker.asc
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
    | sudo tee /etc/apt/sources.list.d/docker.list >/dev/null
  sudo apt-get update -qq
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
    docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin >/dev/null
  sudo usermod -aG docker "$USER"
  echo "  installed"
fi

# ── 4. Secrets, made here ─────────────────────────────────────────────────
#
# Kept if they already exist. Regenerating POSTGRES_PASSWORD after the database
# is initialised locks you out of your own data, and regenerating
# CREDENTIAL_ENCRYPTION_KEY makes anything already encrypted unreadable.
keep_or_make() {
  local key="$1" existing=""
  [ -f "$ENV_FILE" ] && existing="$(grep -E "^${key}=" "$ENV_FILE" | head -1 | cut -d= -f2- || true)"
  if [ -n "$existing" ]; then printf '%s' "$existing"; else openssl rand -base64 32 | tr -d '\n'; fi
}

echo "Preparing secrets..."
POSTGRES_PASSWORD="$(keep_or_make POSTGRES_PASSWORD)"
MINIHR_APP_PASSWORD="$(keep_or_make MINIHR_APP_PASSWORD)"
BETTER_AUTH_SECRET="$(keep_or_make BETTER_AUTH_SECRET)"
CREDENTIAL_ENCRYPTION_KEY="$(keep_or_make CREDENTIAL_ENCRYPTION_KEY)"
MICROSOFT_CLIENT_SECRET="$(cat "$SECRET_FILE")"

# Image pins come from the file the course ships; only overridden deliberately.
MINIHR_IMAGE="${MINIHR_IMAGE:-$(grep -E '^MINIHR_IMAGE=' "$REPO_DIR/.env.example" | cut -d= -f2-)}"
POSTGRES_DIGEST="${POSTGRES_DIGEST:-$(grep -E '^POSTGRES_DIGEST=' "$REPO_DIR/.env.example" | cut -d= -f2-)}"
CADDY_DIGEST="${CADDY_DIGEST:-$(grep -E '^CADDY_DIGEST=' "$REPO_DIR/.env.example" | cut -d= -f2-)}"

cat > "$ENV_FILE" <<EOF
MINIHR_DOMAIN=$MINIHR_HOSTNAME
MICROSOFT_CLIENT_ID=$MICROSOFT_CLIENT_ID
MICROSOFT_CLIENT_SECRET=$MICROSOFT_CLIENT_SECRET
MICROSOFT_TENANT_ID=$MICROSOFT_TENANT_ID
MINIHR_IMAGE=$MINIHR_IMAGE
POSTGRES_DIGEST=$POSTGRES_DIGEST
CADDY_DIGEST=$CADDY_DIGEST
POSTGRES_PASSWORD=$POSTGRES_PASSWORD
MINIHR_APP_PASSWORD=$MINIHR_APP_PASSWORD
BETTER_AUTH_SECRET=$BETTER_AUTH_SECRET
CREDENTIAL_ENCRYPTION_KEY=$CREDENTIAL_ENCRYPTION_KEY
EOF
chmod 600 "$ENV_FILE"
echo "  written to $ENV_FILE (mode 600, and in .gitignore)"

# The handed-over secret now lives in .env. Leaving a second copy in the home
# directory is one more place to forget about.
shred -u "$SECRET_FILE" 2>/dev/null || rm -f "$SECRET_FILE"

# ── 5. Start ──────────────────────────────────────────────────────────────
cd "$REPO_DIR"
DOCKER="docker"; docker info >/dev/null 2>&1 || DOCKER="sudo docker"

echo "Pulling images..."
$DOCKER compose --env-file .env pull -q
echo "Starting..."
$DOCKER compose --env-file .env up -d

cat <<NOTE

Started. Caddy is now asking Let's Encrypt for a certificate; that usually
takes under a minute the first time.

    https://$MINIHR_HOSTNAME

Then prove each layer separately rather than guessing:

    bash vm/healthcheck.sh

NOTE
