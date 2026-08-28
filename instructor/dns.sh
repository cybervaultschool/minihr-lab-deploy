#!/usr/bin/env bash
#
# Instructor-side. Point one hostname per student at their VM.
#
# Why students do not do this themselves: Let's Encrypt limits certificates per
# registered domain, and the free options that look like a way round that are
# not. Neither cloudapp.azure.com nor sslip.io is on the Public Suffix List, so
# a class of thirty would be counted against azure.com or sslip.io — shared with
# the entire internet, and exhausted by strangers. A domain you control is
# counted against you, and thirty fits comfortably under the weekly limit.
#
# Needs CLOUDFLARE_API_TOKEN with Zone.DNS:Edit on the zone.
#
#   export CLOUDFLARE_API_TOKEN=...
#   ./dns.sh --zone fortisentinel.org --roster roster.csv
#   ./dns.sh --zone fortisentinel.org --name student01 --ip 20.1.2.3
#
# roster.csv is: label,ip  — one student per line, '#' comments allowed.
#
set -euo pipefail

ZONE=""; ROSTER=""; ONE_NAME=""; ONE_IP=""; SUBDOMAIN="${SUBDOMAIN:-lab}"

while [ $# -gt 0 ]; do
  case "$1" in
    --zone) ZONE="$2"; shift 2 ;;
    --roster) ROSTER="$2"; shift 2 ;;
    --name) ONE_NAME="$2"; shift 2 ;;
    --ip) ONE_IP="$2"; shift 2 ;;
    --subdomain) SUBDOMAIN="$2"; shift 2 ;;
    *) echo "Unknown argument: $1" >&2; exit 1 ;;
  esac
done

[ -n "$ZONE" ] || { echo "--zone is required" >&2; exit 1; }
[ -n "${CLOUDFLARE_API_TOKEN:-}" ] || { echo "CLOUDFLARE_API_TOKEN is not set" >&2; exit 1; }

API="https://api.cloudflare.com/client/v4"
AUTH=(-H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" -H "Content-Type: application/json")

ZONE_ID="$(curl -s "${AUTH[@]}" "$API/zones?name=$ZONE" | grep -o '"id":"[^"]*"' | head -1 | cut -d'"' -f4)"
[ -n "$ZONE_ID" ] || { echo "Zone '$ZONE' not found, or the token cannot see it." >&2; exit 1; }
echo "Zone $ZONE ($ZONE_ID)"

upsert() {
  local label="$1" ip="$2" fqdn="${1}.${SUBDOMAIN}.${ZONE}"
  # Proxying must stay off. Let's Encrypt's HTTP-01 challenge has to reach the
  # student's own Caddy; behind Cloudflare's proxy it reaches Cloudflare.
  local body="{\"type\":\"A\",\"name\":\"$fqdn\",\"content\":\"$ip\",\"ttl\":120,\"proxied\":false}"
  local existing
  existing="$(curl -s "${AUTH[@]}" "$API/zones/$ZONE_ID/dns_records?type=A&name=$fqdn" \
              | grep -o '"id":"[^"]*"' | head -1 | cut -d'"' -f4)"
  if [ -n "$existing" ]; then
    curl -s -X PUT "${AUTH[@]}" "$API/zones/$ZONE_ID/dns_records/$existing" --data "$body" >/dev/null
    echo "  updated $fqdn -> $ip"
  else
    curl -s -X POST "${AUTH[@]}" "$API/zones/$ZONE_ID/dns_records" --data "$body" >/dev/null
    echo "  created $fqdn -> $ip"
  fi
}

if [ -n "$ONE_NAME" ] && [ -n "$ONE_IP" ]; then
  upsert "$ONE_NAME" "$ONE_IP"
elif [ -n "$ROSTER" ]; then
  while IFS=, read -r label ip; do
    case "$label" in ''|\#*) continue ;; esac
    upsert "$(echo "$label" | tr -d ' ')" "$(echo "$ip" | tr -d ' ')"
  done < "$ROSTER"
else
  echo "Give me either --roster or both --name and --ip." >&2; exit 1
fi

cat <<NOTE

Done. Records are unproxied and TTL 120, so students can retry quickly.

Watch the certificate budget: Let's Encrypt allows 50 certificates per week per
registered domain, and 5 duplicates of the same hostname per week. Thirty
students fit. Thirty students who each destroy and rebuild twice do not — if a
student is iterating, have them keep the same hostname and the same VM.
NOTE
