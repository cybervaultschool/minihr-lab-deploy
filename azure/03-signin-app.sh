#!/usr/bin/env bash
#
# The one secret in this lab, and the reason it exists.
#
# Signing in is a different problem from provisioning. A human is present, the
# browser is redirected to Entra and back, and the application has to prove it
# is the application that asked. That proof happens over HTTP from a web
# framework, not from Azure's instance metadata — so it is a client secret.
#
# Provisioning has no human, no redirect and no browser, so it can use the
# machine's own identity and store nothing. Two permissions, two mechanisms.
# One of them still has an expiry date. That is the lesson, not a shortcoming.
#
#   ./03-signin-app.sh --hostname student01.lab.fortisentinel.org
#
set -euo pipefail

# ── Git Bash, and arguments that look like paths ──────────────────────────
#
# MSYS rewrites any argument resembling a Unix path into a Windows one before
# the program is started. An Azure resource id begins with /subscriptions/,
# so `--scope /subscriptions/abc` arrives at az as
# `C:/Program Files/Git/subscriptions/abc` and is rejected as malformed — an
# error that describes something the student never typed.
#
# Both variables are ignored everywhere that is not MSYS, so this costs macOS
# and Linux nothing.
export MSYS_NO_PATHCONV=1
export MSYS2_ARG_CONV_EXCL='*'


HOSTNAME_ARG=""
APP_NAME="${APP_NAME:-MiniHR Lab sign-in}"
SECRET_FILE="${SECRET_FILE:-./.signin-secret}"

while [ $# -gt 0 ]; do
  case "$1" in
    --hostname) HOSTNAME_ARG="$2"; shift 2 ;;
    --name) APP_NAME="$2"; shift 2 ;;
    *) echo "Unknown argument: $1" >&2; exit 1 ;;
  esac
done

if [ -z "$HOSTNAME_ARG" ]; then
  echo "Which hostname? The one you chose and pointed at your VM." >&2
  echo "  ./03-signin-app.sh --hostname student01.lab.fortisentinel.org" >&2
  exit 1
fi

REDIRECT_URI="https://${HOSTNAME_ARG}/api/auth/callback/microsoft"
TENANT_ID="$(az account show --query tenantId -o tsv)"

echo "Tenant       : $TENANT_ID"
echo "Redirect URI : $REDIRECT_URI"
echo

# ── The registration ──────────────────────────────────────────────────────
#
# Single tenant. Nobody else's directory ever needs to see this one — it exists
# to sign in the people in your own tenant.
APP_ID="$(az ad app list --display-name "$APP_NAME" --query "[0].appId" -o tsv 2>/dev/null || true)"

if [ -n "$APP_ID" ] && [ "$APP_ID" != "null" ]; then
  echo "Application already exists: $APP_ID"
  az ad app update --id "$APP_ID" --web-redirect-uris "$REDIRECT_URI" -o none
  echo "Redirect URI updated."
else
  APP_ID="$(az ad app create \
    --display-name "$APP_NAME" \
    --sign-in-audience AzureADMyOrg \
    --web-redirect-uris "$REDIRECT_URI" \
    --enable-id-token-issuance true \
    --query appId -o tsv)"
  echo "Created: $APP_ID"
fi

# A service principal, so the application exists as something your directory
# can sign people in to. Creating the registration alone is not enough.
az ad sp show --id "$APP_ID" >/dev/null 2>&1 || az ad sp create --id "$APP_ID" -o none

# ── The secret ────────────────────────────────────────────────────────────
#
# Written to a file with restrictive permissions rather than printed. A secret
# echoed to a terminal lives in scrollback, in screenshots, and in whatever
# your shell records — which is exactly the property that makes secrets tiring
# to own, and exactly what the provisioning path avoids.
umask 077
SECRET="$(az ad app credential reset --id "$APP_ID" \
  --display-name "minihr-lab" --years 1 --query password -o tsv)"
printf '%s' "$SECRET" > "$SECRET_FILE"
chmod 600 "$SECRET_FILE"
unset SECRET

cat <<NOTE

Registered.

  Application (client) ID  $APP_ID
  Directory (tenant) ID    $TENANT_ID
  Client secret            written to $SECRET_FILE (not printed)

Look at what you just made: Entra admin center → App registrations →
"$APP_NAME" → Certificates & secrets. There is a value there with an expiry
date one year out. Somebody has to deal with that before it lapses.

Now compare it with the managed identity from step 3, which has no such tab.
Same directory, same Graph API, two ways of proving identity — and only one of
them put an appointment in someone's calendar.

NEXT  copy these to the VM and run bootstrap:

    scp $SECRET_FILE ${ADMIN_USER:-azureuser}@<your-vm-ip>:~/signin-secret
    ssh ${ADMIN_USER:-azureuser}@<your-vm-ip>

    export MINIHR_HOSTNAME=$HOSTNAME_ARG
    export MICROSOFT_CLIENT_ID=$APP_ID
    export MICROSOFT_TENANT_ID=$TENANT_ID
    bash vm/bootstrap.sh
NOTE
