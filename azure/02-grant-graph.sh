#!/usr/bin/env bash
#
# Give the machine permission to write to your directory.
#
# The machine can already prove who it is — that came free with
# `--assign-identity`. Proving who you are and being allowed to do something are
# different questions, and this script answers the second one.
#
# What it grants is exactly what you granted by hand in Part 1:
# User.ReadWrite.All, as an APPLICATION permission. Application, not delegated,
# because nobody is signed in when a leaver is disabled at 3am.
#
# Safe to run twice.
#
set -euo pipefail

RESOURCE_GROUP="${RESOURCE_GROUP:-rg-minihr-lab}"
VM_NAME="${VM_NAME:-minihr-lab}"
PERMISSION="${PERMISSION:-User.ReadWrite.All}"
GRAPH_APP_ID="00000003-0000-0000-c000-000000000000"

while [ $# -gt 0 ]; do
  case "$1" in
    --name) VM_NAME="$2"; shift 2 ;;
    --resource-group) RESOURCE_GROUP="$2"; shift 2 ;;
    *) echo "Unknown argument: $1" >&2; exit 1 ;;
  esac
done

# Read the identity from the VM every time. A recreated VM has a new identity
# with the same name, and a grant made to the old one is invisible but useless.
PRINCIPAL_ID="$(az vm show -g "$RESOURCE_GROUP" -n "$VM_NAME" --query "identity.principalId" -o tsv 2>/dev/null || true)"
if [ -z "$PRINCIPAL_ID" ] || [ "$PRINCIPAL_ID" = "None" ]; then
  echo "That VM has no system-assigned identity. Run 01-create-vm.sh first, or:" >&2
  echo "  az vm identity assign -g $RESOURCE_GROUP -n $VM_NAME" >&2
  exit 1
fi
echo "Machine identity: $PRINCIPAL_ID"

GRAPH_SP_ID="$(az ad sp list --filter "appId eq '$GRAPH_APP_ID'" --query "[0].id" -o tsv)"
ROLE_ID="$(az ad sp show --id "$GRAPH_SP_ID" \
  --query "appRoles[?value=='$PERMISSION' && contains(allowedMemberTypes,'Application')].id | [0]" -o tsv)"
echo "Permission      : $PERMISSION ($ROLE_ID)"
echo

EXISTING="$(az rest --method GET \
  --url "https://graph.microsoft.com/v1.0/servicePrincipals/$PRINCIPAL_ID/appRoleAssignments" \
  --query "value[?appRoleId=='$ROLE_ID'] | [0].id" -o tsv 2>/dev/null || true)"

if [ -n "$EXISTING" ] && [ "$EXISTING" != "None" ]; then
  echo "Already granted."
else
  echo "Granting..."
  az rest --method POST \
    --url "https://graph.microsoft.com/v1.0/servicePrincipals/$PRINCIPAL_ID/appRoleAssignments" \
    --headers "Content-Type=application/json" \
    --body "{\"principalId\":\"$PRINCIPAL_ID\",\"resourceId\":\"$GRAPH_SP_ID\",\"appRoleId\":\"$ROLE_ID\"}" \
    -o none
  echo "Granted."
fi

# ── Wait for it to become true ────────────────────────────────────────────
#
# Entra is eventually consistent. The assignment exists the moment the call
# returns, and the token service may take minutes to agree — so a test run
# immediately after this often fails in a way that looks like a wrong
# permission. Waiting here means the failure you see later is a real one.
echo
echo "Waiting for the grant to propagate. Usually a minute or two; occasionally longer."

DEADLINE=$(( $(date +%s) + 600 ))
while :; do
  SEEN="$(az rest --method GET \
    --url "https://graph.microsoft.com/v1.0/servicePrincipals/$PRINCIPAL_ID/appRoleAssignments" \
    --query "value[?appRoleId=='$ROLE_ID'] | [0].id" -o tsv 2>/dev/null || true)"
  if [ -n "$SEEN" ] && [ "$SEEN" != "None" ]; then
    echo "  visible in the directory"
    break
  fi
  if [ "$(date +%s)" -ge "$DEADLINE" ]; then
    echo "  still not visible after 10 minutes — check the portal before going on" >&2
    exit 1
  fi
  printf '  .'
  sleep 20
done

cat <<NOTE

Granted, and visible.

Go and look at it, the same way you did in Part 1:

    Entra admin center → Enterprise applications → All applications
      → Application type: Managed Identities → $VM_NAME → Permissions

Same permission as your app registration. Same Type: Application. The
difference is on the Certificates & secrets tab, which this object does not
have — there is nothing there to expire, and nothing for you to store.

The machine cannot use this yet: a token it already holds was issued before the
grant existed. vm/healthcheck.sh asks for a fresh one and tells you plainly
whether the permission arrived.

NEXT  ./03-signin-app.sh
NOTE
