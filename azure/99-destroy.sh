#!/usr/bin/env bash
#
# Delete everything. This is a step of the lab, not an afterthought.
#
# Auto-shutdown stops the compute; it does not stop the bill. A stopped VM
# still has a managed disk and a public IP, and both are charged. The only
# thing that ends the cost is deleting the resource group.
#
# It also deletes the app registration from step 4, because a registration with
# a live client secret pointing at a machine that no longer exists is exactly
# the kind of leftover that becomes somebody's incident two years later.
#
set -euo pipefail

RESOURCE_GROUP="${RESOURCE_GROUP:-rg-minihr-lab}"
APP_NAME="${APP_NAME:-MiniHR Lab sign-in}"
ASSUME_YES="${ASSUME_YES:-no}"

while [ $# -gt 0 ]; do
  case "$1" in
    --resource-group) RESOURCE_GROUP="$2"; shift 2 ;;
    --yes) ASSUME_YES=yes; shift ;;
    *) echo "Unknown argument: $1" >&2; exit 1 ;;
  esac
done

if ! az group show -n "$RESOURCE_GROUP" >/dev/null 2>&1; then
  echo "Resource group '$RESOURCE_GROUP' is already gone."
else
  echo "About to delete the resource group '$RESOURCE_GROUP' and everything in it:"
  az resource list -g "$RESOURCE_GROUP" --query "[].{name:name, type:type}" -o table | sed 's/^/  /'
  echo
  if [ "$ASSUME_YES" != "yes" ]; then
    printf 'Type the resource group name to confirm: '
    read -r CONFIRM
    [ "$CONFIRM" = "$RESOURCE_GROUP" ] || { echo "Not deleting."; exit 1; }
  fi
  az group delete -n "$RESOURCE_GROUP" --yes --no-wait
  echo "Deletion started (it runs in the background)."
fi

APP_ID="$(az ad app list --display-name "$APP_NAME" --query "[0].appId" -o tsv 2>/dev/null || true)"
if [ -n "$APP_ID" ] && [ "$APP_ID" != "null" ]; then
  az ad app delete --id "$APP_ID" && echo "Deleted the sign-in application $APP_ID."
fi

# The managed identity disappears with the VM, and so does its Graph permission
# — the grant was made to that principal, and the principal is gone. Nothing to
# revoke, which is the same property that made it easy to trust.

cat <<NOTE

Started. Come back in a few minutes and confirm it is really gone:

    az group show -n $RESOURCE_GROUP

"ResourceGroupNotFound" is the answer you want. Anything else means something
is still running, and still costing.

NOTE
