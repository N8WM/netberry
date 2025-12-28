#!/usr/bin/env bash
set -euo pipefail

REPO="https://github.com/N8WM/netberry.git"
BRANCH="refactor" # TODO: replace
UPDATING=0

echo "Installing netberry..."
echo

need() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Missing dependency: $1"
    exit 1
  }
}

need curl
need git
need bash
need jq

PREFIX="/usr/local"
LIBDIR="$PREFIX/lib/netberry"
BINDIR="$PREFIX/bin"

if [ ! -d "$LIBDIR" ]; then
  OWNER="${SUDO_USER:-$USER}"

  sudo mkdir -p "$LIBDIR"
  sudo chown "$OWNER":"$OWNER" "$LIBDIR"
fi

if [ ! -d "$LIBDIR/.git" ]; then
  sudo rm -rf "$LIBDIR"
  sudo git clone -b "$BRANCH" "$REPO" "$LIBDIR"
else
  UPDATING=1
  sudo git -C "$LIBDIR" pull
fi

sudo chmod +x "$LIBDIR/netberry"
sudo ln -sf "$LIBDIR/netberry" "$BINDIR/netberry"

sudo mkdir -p /var/lib/netberry
sudo chmod 755 /var/lib/netberry

[ $UPDATING -eq 0 ] && echo && echo "netberry installed successfully"
