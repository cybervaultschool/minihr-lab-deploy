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
# The secret has to come from somewhere, but not necessarily from a fresh
# copy: this script destroys the copied file after reading it, so demanding
# one every time would make it single-use — and running it again is the first
# thing anyone does after getting a value wrong.
if [ ! -f "$SECRET_FILE" ] && ! grep -qE '^MICROSOFT_CLIENT_SECRET=.' "$ENV_FILE" 2>/dev/null; then
  fail "No sign-in secret at $SECRET_FILE, and none in $ENV_FILE. Copy it across from where you ran step 4."
fi
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
#
# Two alphabets, and the difference matters.
#
# POSTGRES_PASSWORD and MINIHR_APP_PASSWORD are interpolated into a connection
# URL - postgresql://user:PASSWORD@db:5432/minihr. base64 includes '/' and '+',
# and a '/' in the userinfo makes that URL unparseable: the driver fails with
# ERR_INVALID_URL and the migration step exits 1, naming nothing that leads you
# here. Each base64 character has a 1-in-64 chance of being '/', so across 43 of
# them roughly half of all generated passwords break. It worked for whoever was
# lucky, which is why it survived every test.
#
# Hex has no such characters, and 48 hex digits is 192 bits - no weaker than the
# base64 it replaces. The other two secrets never go near a URL.
keep_or_make() {
  local key="$1" alphabet="${2:-base64}" existing=""
  [ -f "$ENV_FILE" ] && existing="$(grep -E "^${key}=" "$ENV_FILE" | head -1 | cut -d= -f2- || true)"
  if [ -n "$existing" ]; then printf '%s' "$existing"
  elif [ "$alphabet" = "hex" ]; then printf '%s' "$(openssl rand -hex 24)"
  else printf '%s' "$(openssl rand -base64 32)"; fi
}

echo "Preparing secrets..."
POSTGRES_PASSWORD="$(keep_or_make POSTGRES_PASSWORD hex)"
MINIHR_APP_PASSWORD="$(keep_or_make MINIHR_APP_PASSWORD hex)"
BETTER_AUTH_SECRET="$(keep_or_make BETTER_AUTH_SECRET)"
CREDENTIAL_ENCRYPTION_KEY="$(keep_or_make CREDENTIAL_ENCRYPTION_KEY)"
# A freshly copied file wins; otherwise keep what is already configured.
if [ -f "$SECRET_FILE" ]; then
  MICROSOFT_CLIENT_SECRET="$(cat "$SECRET_FILE")"
else
  MICROSOFT_CLIENT_SECRET="$(grep -E '^MICROSOFT_CLIENT_SECRET=' "$ENV_FILE" | head -1 | cut -d= -f2-)"
  echo "  reusing the sign-in secret already in .env"
fi
MINIHR_IMAGE="${MINIHR_IMAGE:-$(grep -E '^MINIHR_IMAGE=' "$REPO_DIR/.env.example" | cut -d= -f2-)}"

cat > "$ENV_FILE" <<EOF
MINIHR_DOMAIN=$MINIHR_HOSTNAME
MICROSOFT_CLIENT_ID=$MICROSOFT_CLIENT_ID
MICROSOFT_CLIENT_SECRET=$MICROSOFT_CLIENT_SECRET
MICROSOFT_TENANT_ID=$MICROSOFT_TENANT_ID
MINIHR_IMAGE=$MINIHR_IMAGE
POSTGRES_PASSWORD=$POSTGRES_PASSWORD
MINIHR_APP_PASSWORD=$MINIHR_APP_PASSWORD
BETTER_AUTH_SECRET=$BETTER_AUTH_SECRET
CREDENTIAL_ENCRYPTION_KEY=$CREDENTIAL_ENCRYPTION_KEY
EOF
chmod 600 "$ENV_FILE"
echo "  written to $ENV_FILE (mode 600, and in .gitignore)"

# The handed-over secret now lives in .env. Leaving a second copy in the home
# directory is one more place to forget about.
[ -f "$SECRET_FILE" ] && { shred -u "$SECRET_FILE" 2>/dev/null || rm -f "$SECRET_FILE"; }

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

One thing about this session: you were added to the 'docker' group just now,
and group membership only applies to a session that starts afterwards. So in
THIS shell, docker commands need sudo. Log out and back in and they will not.

    exit
    ssh $USER@$(curl -s --max-time 5 https://api.ipify.org || echo '<your-vm-ip>')

    https://$MINIHR_HOSTNAME

Then prove each layer separately rather than guessing:

    bash vm/healthcheck.sh

NOTE
