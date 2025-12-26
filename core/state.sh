#!/usr/bin/env bash
set -euo pipefail

source "$(dirname "$0")/paths.sh"

init_state() {
  if [ ! -f "$NETBERRY_STATE" ]; then
    echo '{"installed":{}}' | sudo tee "$NETBERRY_STATE" >/dev/null
  fi
}

is_installed() {
  jq -e ".installed[\"$1\"]" "$NETBERRY_STATE" >/dev/null 2>&1
}

mark_installed() {
  local pkg="$1"
  local ver="$2"
  tmp=$(mktemp)
  jq ".installed[\"$pkg\"]=\"$ver\"" "$NETBERRY_STATE" >"$tmp"
  sudo mv "$tmp" "$NETBERRY_STATE"
}
