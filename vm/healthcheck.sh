#!/usr/bin/env bash
#
# Prove each layer separately, so a failure names itself.
#
# "It doesn't work" has at least five meanings here: containers not running, no
# certificate, the app not answering, the machine having no usable identity, or
# the permission not having arrived. Testing them in order turns one useless
# sentence into one specific one.
#
#   bash vm/healthcheck.sh
#
set -uo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_DIR"
DOCKER="docker"; docker info >/dev/null 2>&1 || DOCKER="sudo docker"
HOST="$(grep -E '^MINIHR_DOMAIN=' .env | cut -d= -f2-)"
FAILED=0

step() { printf '\n%s\n' "$1"; }
ok()   { printf '  [ ok ] %s\n' "$*"; }
bad()  { printf '  [FAIL] %s\n' "$*"; FAILED=$((FAILED + 1)); }

step "1. Containers"
STATUS="$($DOCKER compose --env-file .env ps --format '{{.Service}} {{.State}}' 2>/dev/null)"
if [ -z "$STATUS" ]; then
  bad "nothing is running — try: docker compose --env-file .env up -d"
else
  printf '%s\n' "$STATUS" | sed 's/^/  /'
  printf '%s' "$STATUS" | grep -q "exited" && bad "something exited — docker compose logs <service>" || ok "all up"
fi

step "2. Certificate and reverse proxy"
CODE="$(curl -s -o /dev/null -w '%{http_code}' --max-time 20 "https://$HOST/" 2>/dev/null)"
if [ "$CODE" = "200" ] || [ "$CODE" = "302" ] || [ "$CODE" = "307" ]; then
  ok "https://$HOST answers ($CODE), certificate is trusted"
else
  bad "https://$HOST returned '$CODE'"
  echo "     Caddy's own account of it:"
  $DOCKER compose --env-file .env logs caddy 2>/dev/null | tail -12 | sed 's/^/       /'
fi

step "3. Sign-in configuration"
# The most common single cause of "sign-in works nowhere" is a redirect URI
# that differs from the registered one by a character. Print both rather than
# describing them.
echo "  This deployment will send Entra: https://$HOST/api/auth/callback/microsoft"
echo "  Your app registration must list exactly that, including the scheme."
echo "  App registrations → your app → Authentication → Web → Redirect URIs"

step "4. The machine's identity, from inside the worker"
OUTPUT="$($DOCKER compose --env-file .env exec -T worker node -e "$(cat vm/probe.mjs)" 2>&1)"
printf '%s\n' "$OUTPUT" | sed 's/^/  /'
printf '%s' "$OUTPUT" | grep -q "^GRAPH  yes" && ok "the worker can write to your directory" || bad "the worker cannot reach Graph yet"
printf '%s' "$OUTPUT" | grep -q "ROLES  NONE" && \
  echo "     The grant from step 3 has not propagated. Wait a few minutes and run this again." || true

echo
if [ "$FAILED" -eq 0 ]; then
  cat <<NOTE
Everything answers.

Open https://$HOST, sign in with your own tenant, create an organization, and
connect it — choosing "Use this machine's managed identity". There is no tenant
ID to enter and no secret to paste, because the machine and the directory are
the same tenant now.
NOTE
else
  echo "$FAILED check(s) failed above. Fix them in order — a later layer cannot"
  echo "work while an earlier one is broken, so the first failure is the real one."
  exit 1
fi
