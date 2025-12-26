#!/usr/bin/env bash
set -euo pipefail

REPO="https://github.com/N8WM/netberry.git"
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
  sudo mkdir -p "$LIBDIR"
  sudo chown "$USER":"$USER" "$LIBDIR"
fi

if [ ! -d "$LIBDIR/.git" ]; then
  git clone $REPO
else
  UPDATING=1
  cd "$LIBDIR"
  git pull
fi

sudo ln -sf "$LIBDIR/netberry" "$BINDIR/netberry"
sudo chmod +x "$LIBDIR/netberry"

sudo mkdir -p /var/lib/netberry
sudo chmod 755 /var/lib/netberry

[ $UPDATING -eq 0 ] && echo "\nnetberry installed successfully"
