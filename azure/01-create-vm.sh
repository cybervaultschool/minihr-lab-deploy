#!/usr/bin/env bash
#
# The machine that will become an identity.
#
# The important line in this script is `--assign-identity`. Everything else is
# an ordinary Linux VM. That one flag creates a service principal in your
# directory that represents *this machine* — and from then on the machine can
# ask Azure for tokens by being itself, which is what removes the client secret
# from the provisioning path in step 3.
#
# Safe to run twice: existing resources are reused, not recreated.
#
#   ./01-create-vm.sh
#   ./01-create-vm.sh --location westeurope --size Standard_B2als_v2
#
set -euo pipefail

RESOURCE_GROUP="${RESOURCE_GROUP:-rg-minihr-lab}"
VM_NAME="${VM_NAME:-minihr-lab}"
LOCATION="${LOCATION:-eastus}"
SIZE="${SIZE:-Standard_B2s}"
IMAGE="${IMAGE:-Ubuntu2204}"
ADMIN_USER="${ADMIN_USER:-azureuser}"
SHUTDOWN_TIME="${SHUTDOWN_TIME:-2200}"

while [ $# -gt 0 ]; do
  case "$1" in
    --location) LOCATION="$2"; shift 2 ;;
    --size) SIZE="$2"; shift 2 ;;
    --name) VM_NAME="$2"; shift 2 ;;
    --resource-group) RESOURCE_GROUP="$2"; shift 2 ;;
    *) echo "Unknown argument: $1" >&2; exit 1 ;;
  esac
done

echo "Resource group : $RESOURCE_GROUP"
echo "Virtual machine: $VM_NAME ($SIZE, $LOCATION)"
echo

# ── 1. Resource group ─────────────────────────────────────────────────────
#
# One group holds everything, which is what makes step 7 a single command. A
# lab you cannot delete in one line is a lab that keeps billing.
if az group show -n "$RESOURCE_GROUP" >/dev/null 2>&1; then
  echo "Resource group already exists."
else
  az group create -n "$RESOURCE_GROUP" -l "$LOCATION" -o none
  echo "Created resource group."
fi

# ── 2. The VM ─────────────────────────────────────────────────────────────
if az vm show -g "$RESOURCE_GROUP" -n "$VM_NAME" >/dev/null 2>&1; then
  echo "VM already exists — leaving it alone."
else
  echo "Creating the VM. This takes two or three minutes..."
  az vm create \
    --resource-group "$RESOURCE_GROUP" \
    --name "$VM_NAME" \
    --image "$IMAGE" \
    --size "$SIZE" \
    --admin-username "$ADMIN_USER" \
    --assign-identity \
    --generate-ssh-keys \
    --public-ip-sku Standard \
    --os-disk-size-gb 32 \
    --nsg-rule NONE \
    -o none
  echo "Created."
fi

# ── 3. Who may reach it ───────────────────────────────────────────────────
#
# 80 and 443 must be open to the world: Let's Encrypt proves you control the
# hostname by fetching a file over port 80 from wherever it happens to be. If
# you close 80 "for security", the certificate silently stops renewing.
#
# 22 is opened only to the address you are sitting at now. If your address
# changes — different network, or an ISP that rotates it — re-run this script.
MY_IP="$(curl -s --max-time 10 https://api.ipify.org || true)"
NSG_NAME="$(az network nsg list -g "$RESOURCE_GROUP" --query "[0].name" -o tsv)"

if [ -z "$NSG_NAME" ]; then
  NSG_NAME="${VM_NAME}NSG"
  az network nsg create -g "$RESOURCE_GROUP" -n "$NSG_NAME" -o none
  NIC="$(az vm show -g "$RESOURCE_GROUP" -n "$VM_NAME" --query "networkProfile.networkInterfaces[0].id" -o tsv)"
  az network nic update --ids "$NIC" --network-security-group "$NSG_NAME" -o none
fi

rule() {
  az network nsg rule create -g "$RESOURCE_GROUP" --nsg-name "$NSG_NAME" \
    -n "$1" --priority "$2" --source-address-prefixes "$3" \
    --destination-port-ranges "$4" --access Allow --protocol Tcp -o none 2>/dev/null \
  || az network nsg rule update -g "$RESOURCE_GROUP" --nsg-name "$NSG_NAME" \
    -n "$1" --source-address-prefixes "$3" -o none
}

if [ -n "$MY_IP" ]; then
  rule ssh-from-me 1000 "$MY_IP" 22
  echo "SSH allowed from $MY_IP only."
else
  echo "Could not detect your public IP — opening SSH to the internet."
  echo "Narrow it later with: az network nsg rule update -g $RESOURCE_GROUP --nsg-name $NSG_NAME -n ssh-from-me --source-address-prefixes <your-ip>"
  rule ssh-from-me 1000 "Internet" 22
fi
rule http  1010 Internet 80
rule https 1020 Internet 443

# ── 4. Stop paying for it overnight ───────────────────────────────────────
az vm auto-shutdown -g "$RESOURCE_GROUP" -n "$VM_NAME" --time "$SHUTDOWN_TIME" -o none 2>/dev/null \
  && echo "Auto-shutdown set for ${SHUTDOWN_TIME} UTC." \
  || echo "Could not set auto-shutdown — set it in the portal, or remember to deallocate."

# ── 5. What the next steps need ───────────────────────────────────────────
#
# The principal id is read back rather than remembered. Delete and recreate the
# VM and you get a *different* identity with the same name — any permission
# granted to the old one does not follow. Reading it live is what makes a rerun
# correct instead of quietly wrong.
PUBLIC_IP="$(az vm show -d -g "$RESOURCE_GROUP" -n "$VM_NAME" --query publicIps -o tsv)"
PRINCIPAL_ID="$(az vm show -g "$RESOURCE_GROUP" -n "$VM_NAME" --query "identity.principalId" -o tsv)"

cat <<NOTE

────────────────────────────────────────────────────────────────────
  Public IP        $PUBLIC_IP
  Machine identity $PRINCIPAL_ID
  SSH              ssh $ADMIN_USER@$PUBLIC_IP
────────────────────────────────────────────────────────────────────

That identity is a real object in your directory. Look it up:

    Entra admin center → Enterprise applications → All applications
      → filter Application type = Managed Identities → $VM_NAME

It has no credentials tab, because it has no credentials. Azure vouches for
it, and Azure does not need to tell it a secret to do that.

NEXT
  1. Send your instructor this IP address: $PUBLIC_IP
     They will point your hostname at it.
  2. While you wait, run: ./02-grant-graph.sh
NOTE
