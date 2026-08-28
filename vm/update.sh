#!/usr/bin/env bash
#
# Take an update. Run this ON THE VM.
#
# `git pull` alone is not enough, and the reason is easy to miss: the image
# your instance runs is pinned in .env, which bootstrap wrote once from
# .env.example. Pulling the repository updates the example and leaves your
# .env — and its old digest — exactly where it was. So you would read new
# instructions while running the old software, which is a worse position than
# not updating at all.
#
#   bash vm/update.sh
#
set -euo pipefail
umask 077

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_DIR"
DOCKER="docker"; docker info >/dev/null 2>&1 || DOCKER="sudo docker"

echo "Fetching the latest lab files..."
git pull --quiet --ff-only

NEW_IMAGE="$(grep -E '^MINIHR_IMAGE=' .env.example | cut -d= -f2-)"
OLD_IMAGE="$(grep -E '^MINIHR_IMAGE=' .env | cut -d= -f2- || true)"

if [ -z "$NEW_IMAGE" ]; then
  echo "No MINIHR_IMAGE in .env.example — nothing to update to." >&2
  exit 1
fi

if [ "$NEW_IMAGE" = "$OLD_IMAGE" ]; then
  echo "Already on the published image."
else
  echo "Image changed:"
  echo "  from ${OLD_IMAGE:-none}"
  echo "  to   $NEW_IMAGE"
  # Rewrite only that line. Everything else in .env - your passwords, your
  # encryption key, the sign-in secret - was generated on this machine and
  # must survive untouched.
  sed -i.bak -E "s|^MINIHR_IMAGE=.*|MINIHR_IMAGE=$NEW_IMAGE|" .env
  rm -f .env.bak
  chmod 600 .env
fi

echo "Pulling and restarting..."
$DOCKER compose --env-file .env pull -q
$DOCKER compose --env-file .env up -d

echo
echo "Done. Your data is untouched — the database is a volume, not part of the image."
echo "Check it came back up with: bash vm/healthcheck.sh"
