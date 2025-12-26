#!/usr/bin/env bash
set -euo pipefail

source "$(dirname "$0")/state.sh"

die() {
  echo "ERROR: $*" >&2
  exit 1
}

need_root() {
  [ "$(id -u)" -eq 0 ] || die "Must run as root"
}

pkg_dir() {
  echo "$NETBERRY_PACKAGES/$1"
}

pkg_meta() {
  echo "$(pkg_dir "$1")/package.json"
}

pkg_installer() {
  echo "$(pkg_dir "$1")/install.sh"
}

pkg_ver() {
  echo "$(jq -r .version "$(pkg_meta "$1")")"
}

pkg_deps() {
  echo "$(jq -r '.dependencies[]? // empty' "$(pkg_meta "$1")")"
}

pkg_install() {
  bash "$(pkg_installer "$1")"
}

# Installation

in_args() {
  local needle=$1
  shift

  for arg in "$@"; do
    [[ "$arg" == "$needle" ]] && return 0
  done

  return 1
}

can_install() {
  local meta="$(pkg_meta "$1")"
  shift

  if [ ! -f "$meta" ]; then
    die "Unknown package: $1"
  fi

  local pkgs=("$@")

  local deps
  mapfile -t deps < <(jq -r '.dependencies[]? // empty' "$meta")

  local to_install=()
  local missing=()

  for dep in "${deps[@]}"; do
    if is_installed "$dep"; then
      continue
    elif in_args "$dep" "${pkgs[@]}"; then
      to_install+=("$dep")
    else
      missing+=("$dep")
    fi
  done

  if ((${#missing[@]} > 0)); then
    die "Failed to install $1: missing dependencies:\n  ${missing[*]}"
  fi

  printf '%s\n' "${to_install[@]}"
}

install_with_deps() {
  local pkg=$1
  local ver="$(pkg_ver "$pkg")"
  shift

  if output=$(can_install "$pkg" "$@"); then
    local to_install=()
    mapfile -t to_install < <(printf '%s\n' "$output")

    for dep in "${to_install[@]}"; do
      install_with_deps "$dep" "$@"
    done

    echo "Installing $pkg ($ver)..."
    pkg_install "$pkg"
    mark_installed "$pkg" "$ver"
  else
    die "$output"
  fi
}
