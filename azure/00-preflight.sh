#!/usr/bin/env bash
#
# Check everything that can stop you, before anything is created.
#
# Almost every painful lab failure is a precondition that was not true and was
# not checked: a subscription with no credit, a VM size that is not offered in
# your region, an Entra role you appear to hold but have not activated. Each one
# is cheap to detect now and expensive to hit in step 5, with a half-built
# machine and a class waiting.
#
# This script creates nothing. Run it as many times as you like.
#
#   ./00-preflight.sh
#   ./00-preflight.sh --location westeurope
#
set -uo pipefail

LOCATION="${LOCATION:-eastus}"
SIZE="${SIZE:-Standard_D2as_v7}"
# Tried in order when the preferred size is not offered here. v7 is recent and
# not in every region yet, so the list walks back through older equivalents
# rather than failing on the newest name.
FALLBACK_SIZES=(Standard_D2as_v7 Standard_D2as_v6 Standard_D2as_v5 Standard_D2s_v5 Standard_D2s_v3)

while [ $# -gt 0 ]; do
  case "$1" in
    --location) LOCATION="$2"; shift 2 ;;
    --size) SIZE="$2"; shift 2 ;;
    *) echo "Unknown argument: $1" >&2; exit 1 ;;
  esac
done

PROBLEMS=0
note()  { printf '  %s\n' "$*"; }
ok()    { printf '  [ ok ] %s\n' "$*"; }
bad()   { printf '  [FAIL] %s\n' "$*"; PROBLEMS=$((PROBLEMS + 1)); }
warn()  { printf '  [warn] %s\n' "$*"; }
head_() { printf '\n%s\n' "$1"; }

# ── 1. The CLI, and who you are ───────────────────────────────────────────
head_ "1. Azure CLI and sign-in"

if ! command -v az >/dev/null 2>&1; then
  bad "The az CLI is not installed. https://aka.ms/azure-cli"
  echo; echo "Cannot continue without it."; exit 1
fi
ok "az $(az version --query '"azure-cli"' -o tsv 2>/dev/null)"

ACCOUNT_JSON="$(az account show -o json 2>/dev/null)"
if [ -z "$ACCOUNT_JSON" ]; then
  bad "Not signed in. Run: az login --tenant <your-tenant-id>"
  echo; echo "Cannot continue without it."; exit 1
fi

TENANT_ID="$(printf '%s' "$ACCOUNT_JSON"  | grep -o '"tenantId": *"[^"]*"'       | head -1 | cut -d'"' -f4)"
SUB_ID="$(printf '%s' "$ACCOUNT_JSON"     | grep -o '"id": *"[^"]*"'             | head -1 | cut -d'"' -f4)"
SUB_STATE="$(printf '%s' "$ACCOUNT_JSON"  | grep -o '"state": *"[^"]*"'          | head -1 | cut -d'"' -f4)"
SIGNED_IN_AS="$(az account show --query user.name -o tsv 2>/dev/null)"

ok "Signed in as $SIGNED_IN_AS"
ok "Tenant       $TENANT_ID"
ok "Subscription $SUB_ID"

if [ "$SUB_STATE" = "Enabled" ]; then
  ok "Subscription state: Enabled"
else
  bad "Subscription state is '$SUB_STATE'. A disabled or expired subscription cannot create a VM."
fi

# A tenant you can sign in to is not necessarily a tenant you administer. This
# is the single most common surprise: Azure subscription rights and Entra
# directory rights are different systems that happen to share a login.
head_ "2. Your directory role"

ROLES="$(az rest --method GET \
  --url 'https://graph.microsoft.com/v1.0/me/memberOf?$select=displayName' \
  --query "value[].displayName" -o tsv 2>/dev/null)"

if [ -z "$ROLES" ]; then
  warn "Could not read your directory roles. That is not necessarily a problem,"
  warn "but it means this script cannot confirm you may grant Graph permissions."
elif printf '%s' "$ROLES" | grep -qi "Global Administrator\|Privileged Role Administrator"; then
  ok "You hold Global Administrator or Privileged Role Administrator"
else
  bad "You do not appear to hold Global Administrator or Privileged Role Administrator."
  note "Step 3 grants an application permission to your VM's identity, and only"
  note "those two roles may do that. If your role is 'eligible' through PIM,"
  note "activate it now — eligible is not the same as active."
fi

# ── 2b. May you create anything in the subscription? ──────────────────────
#
# A directory role and a subscription role are different systems that share a
# login. Global Administrator in Entra grants nothing over Azure resources, and
# somebody who has only ever used the portal has no reason to know that — so it
# gets asked about separately rather than assumed from the check above.
head_ "2b. Your subscription role"

MY_OBJECT_ID="$(az ad signed-in-user show --query id -o tsv 2>/dev/null)"
ASSIGNMENTS=""
[ -n "$MY_OBJECT_ID" ] && ASSIGNMENTS="$(az role assignment list   --assignee "$MY_OBJECT_ID" --scope "/subscriptions/$SUB_ID"   --query "[].roleDefinitionName" -o tsv 2>/dev/null)"

if [ -z "$ASSIGNMENTS" ]; then
  warn "Could not read your subscription role assignments."
  warn "That is often just a missing read permission, not a problem — but if"
  warn "01-create-vm.sh is refused with AuthorizationFailed, this is why:"
  warn "you need Contributor or Owner on the subscription, which Global"
  warn "Administrator does not give you."
elif printf '%s' "$ASSIGNMENTS" | grep -qi "Owner\|Contributor"; then
  ok "Subscription role: $(echo $ASSIGNMENTS)"
else
  bad "Your roles on this subscription are: $(echo $ASSIGNMENTS)"
  note "None of those can create a virtual machine. You need Contributor or Owner."
  note "This is separate from your Entra role — different system, same login."
fi

# ── 3. May you register an application at all? ────────────────────────────
head_ "3. Application registration policy"

CAN_REGISTER="$(az rest --method GET \
  --url 'https://graph.microsoft.com/v1.0/policies/authorizationPolicy' \
  --query "defaultUserRolePermissions.allowedToCreateApps" -o tsv 2>/dev/null)"

case "$CAN_REGISTER" in
  true)  ok "Members may register applications" ;;
  false) warn "Members may not register applications — you will need your admin role for step 4" ;;
  *)     warn "Could not read the tenant's authorization policy (this is often fine)" ;;
esac

# ── 4. Resource providers ─────────────────────────────────────────────────
head_ "4. Resource providers"

for provider in Microsoft.Compute Microsoft.Network; do
  STATE="$(az provider show -n "$provider" --query registrationState -o tsv 2>/dev/null)"
  if [ "$STATE" = "Registered" ]; then
    ok "$provider registered"
  else
    warn "$provider is '$STATE' — registering now (this can take a few minutes)"
    az provider register -n "$provider" >/dev/null 2>&1 && note "requested" || bad "could not register $provider"
  fi
done

# ── 5. A VM size that is actually offered to you, here ────────────────────
#
# "D2as_v7 exists" and "D2as_v7 is available to this subscription in this
# region" are
# different claims. Student offers restrict SKUs, and the restriction is per
# subscription and per region — so this has to be asked, not assumed.
head_ "5. VM size availability in $LOCATION"

SKUS="$(az vm list-skus --location "$LOCATION" --resource-type virtualMachines \
        --query "[].{n:name, r:restrictions[0].reasonCode}" -o tsv 2>/dev/null)"

if [ -z "$SKUS" ]; then
  bad "Could not list VM sizes in $LOCATION. Is the region name right?"
else
  CHOSEN=""
  for candidate in "$SIZE" "${FALLBACK_SIZES[@]}"; do
    LINE="$(printf '%s\n' "$SKUS" | awk -v s="$candidate" '$1 == s {print; exit}')"
    [ -z "$LINE" ] && continue
    REASON="$(printf '%s' "$LINE" | cut -f2)"
    if [ -z "$REASON" ] || [ "$REASON" = "None" ]; then
      CHOSEN="$candidate"; break
    fi
    note "$candidate is offered but restricted here ($REASON)"
  done

  if [ -n "$CHOSEN" ]; then
    ok "Use $CHOSEN"
    [ "$CHOSEN" != "$SIZE" ] && warn "$SIZE was not usable — pass --size $CHOSEN to the next script"
  else
    bad "No supported size is available to you in $LOCATION."
    note "Try another region: ./00-preflight.sh --location westeurope"
  fi
fi

# ── 6. Room for it ────────────────────────────────────────────────────────
head_ "6. Quota"

USAGE="$(az vm list-usage --location "$LOCATION" \
         --query "[?contains(localName,'Total Regional vCPUs')].{c:currentValue, l:limit}" -o tsv 2>/dev/null)"
if [ -n "$USAGE" ]; then
  CUR="$(printf '%s' "$USAGE" | cut -f1)"; LIM="$(printf '%s' "$USAGE" | cut -f2)"
  if [ "$((LIM - CUR))" -ge 2 ]; then
    ok "Regional vCPUs: $CUR of $LIM used — room for 2 more"
  else
    bad "Regional vCPU quota is $CUR of $LIM. A 2-core VM will not fit."
  fi
else
  warn "Could not read vCPU quota"
fi

# ── Verdict ───────────────────────────────────────────────────────────────
echo
if [ "$PROBLEMS" -eq 0 ]; then
  echo "Ready. Nothing has been created yet — run 01-create-vm.sh next."
else
  echo "$PROBLEMS problem(s) above must be fixed first."
  echo "Fixing them now costs minutes. Finding them in step 5 costs the lesson."
  exit 1
fi
