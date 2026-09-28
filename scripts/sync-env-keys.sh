#!/usr/bin/env bash
# Sync specific env key names from .env.example to .env without overwriting existing values
# Usage: scripts/sync-env-keys.sh [--apply]

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${SCRIPT_DIR}/.."
ENV_FILE="${REPO_ROOT}/.env"
EXAMPLE_FILE="${REPO_ROOT}/.env.example"
DRY_RUN=true
if [[ "${1:-}" == "--apply" ]]; then
  DRY_RUN=false
fi

# Map of example key -> real key(s) to synchronize
# Add entries here when example vs real key names differ
declare -A KEY_MAP
# For now, keep mapping identical names. Example provided if remapping needed.
# KEY_MAP[SONARR_0_API_KEY]=SONARR_0_API_KEY
# KEY_MAP[UN_SONARR_0_API_KEY]=SONARR_0_API_KEY

# If you want to alias alternate names into real ones, list them like:
# KEY_MAP[SONARR_0_API_KEY]=SONARR_0_API_KEY
# KEY_MAP[UN_SONARR_0_API_KEY]=SONARR_0_API_KEY

# Helper: read key from file
get_value() {
  local file="$1" key="$2"
  grep -E "^${key}=" "$file" | sed -E "s/^${key}=(.*)$/\1/" | head -n1 || true
}

if [[ ! -f "$ENV_FILE" ]]; then
  echo "Error: $ENV_FILE not found" >&2
  exit 2
fi
if [[ ! -f "$EXAMPLE_FILE" ]]; then
  echo "Error: $EXAMPLE_FILE not found" >&2
  exit 2
fi

# Build list of keys present in example
mapfile -t EXAMPLE_KEYS < <(grep -E '^[A-Z0-9_]+=' "$EXAMPLE_FILE" | sed -E 's/=.*$//' )

# Default behavior: ensure every key present in example exists in real .env
# If missing in .env and example has a non-placeholder value, copy it; otherwise skip.

PROPOSED=()
for k in "${EXAMPLE_KEYS[@]}"; do
  example_val="$(get_value "$EXAMPLE_FILE" "$k")"
  real_val="$(get_value "$ENV_FILE" "$k")"
  # Treat known placeholders as "empty"
  if [[ -z "$real_val" ]]; then
    if [[ -n "$example_val" && "$example_val" != "replace-with-"* && "$example_val" != "claim-xxxxxxxxxxxxxxxx" && "$example_val" != "00000000-0000-0000-0000-000000000000" && "$example_val" != "replace-with-plex-token" && "$example_val" != "replace-with-36-char-notifiarr-api-key" ]]; then
      PROPOSED+=("$k")
    fi
  fi
done

if [[ ${#PROPOSED[@]} -eq 0 ]]; then
  echo "No keys to sync."
  exit 0
fi

echo "Keys that would be added to $ENV_FILE:" >&2
for k in "${PROPOSED[@]}"; do
  echo "  - $k" >&2
  example_val="$(get_value "$EXAMPLE_FILE" "$k")"
  echo "    example: $example_val" >&2
done

if $DRY_RUN; then
  echo "Dry-run complete. Run with --apply to apply changes." >&2
  exit 0
fi

# Apply changes: append missing keys with example values
for k in "${PROPOSED[@]}"; do
  example_val="$(get_value "$EXAMPLE_FILE" "$k")"
  echo "Appending $k to $ENV_FILE" >&2
  printf '\n%s=%s\n' "$k" "$example_val" >> "$ENV_FILE"
done

echo "Applied $(printf '%s\n' "${PROPOSED[@]}" | wc -l) keys to $ENV_FILE"
