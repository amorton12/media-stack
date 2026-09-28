#!/usr/bin/env bash
set -euo pipefail

. .env

: "${LIDARR_URL:?Must set LIDARR_URL}"
: "${LIDARR_API_KEY:?Must set LIDARR_API_KEY}"

DRY_RUN=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=true; shift ;;
    *) break ;;
  esac
done

echo "Fetching albums..."

curl -fsS \
  -H "X-Api-Key: $LIDARR_API_KEY" \
  "$LIDARR_URL/api/v1/album?monitored=false&includeArtist=true" |
jq -r '
  .[] |
  select((.statistics.trackFileCount // 0) == 0) |
  "\(.id)\t\(.artist.artistName // "Unknown")\t\(.title)"
' |
while IFS=$'\t' read -r id artist title; do

  echo "MATCH: $artist - $title (id=$id)"

  if $DRY_RUN; then
    echo "[DRY RUN] delete id=$id"
    continue
  fi

  echo "DELETE: $artist - $title"

  curl -fsS -X DELETE \
    -H "X-Api-Key: $LIDARR_API_KEY" \
    "$LIDARR_URL/api/v1/album/$id"

done