#!/usr/bin/env bash
set -euo pipefail

FAILURES=0

### =========================
### Helpers
### =========================

ok() { echo "✔ $*"; }
warn() { echo "⚠ $*"; }
detail() { echo "  > $*"; }
fail() {
  echo "✖ $*"
  FAILURES=$((FAILURES + 1))
}

need() {
  command -v "$1" >/dev/null 2>&1 || {
    fail "Required command not found: $1"
    exit 1
  }
}

need jq
need ip
need iw
need iptables
need nft
need netbird

### =========================
### Detect AP interface
### =========================

AP_IFACE="$(
  iw dev 2>/dev/null | awk '
    $1=="Interface"{iface=$2}
    $1=="type" && $2=="AP"{print iface}
  ' | head -n1
)"

[ -n "$AP_IFACE" ] || {
  fail "No AP interface detected"
  detail "iw dev shows no type AP"
  exit 1
}

ok "AP interface detected: $AP_IFACE"

### =========================
### Phase 1 — NetBird status
### =========================

if netbird status --json | jq -e '.management.connected == true' >/dev/null; then
  ok "NetBird management connected"
else
  fail "NetBird management not connected"
  detail "Sometimes this can be a false positive"
  detail "Check management connection again with \`netbird status\`"
fi

if ip link show wt0 >/dev/null 2>&1; then
  ok "NetBird interface wt0 present"
else
  fail "NetBird interface wt0 missing"
fi

### =========================
### Phase 2 — AP mode sanity
### =========================

if iw dev "$AP_IFACE" info 2>/dev/null | grep -q "type AP"; then
  ok "AP interface is in AP mode"
else
  fail "AP interface is not in AP mode"
fi

### =========================
### Phase 3 — DHCP activity
### =========================

if journalctl -u dnsmasq --no-pager 2>/dev/null | grep -q "DHCPACK"; then
  ok "dnsmasq has issued DHCP leases"
else
  warn "No DHCP leases observed yet"
  detail "May be idle"
fi

### =========================
### Phase 4 — Policy routing
### =========================

NETBIRD_MARK="0x1bd22"
NETBIRD_TABLE="7120"

if ip rule show | grep -q "fwmark $NETBIRD_MARK.*lookup $NETBIRD_TABLE"; then
  ok "Policy rule fwmark $NETBIRD_MARK → table $NETBIRD_TABLE present"
else
  fail "Policy routing rule missing for fwmark $NETBIRD_MARK"
fi

if ip route show table "$NETBIRD_TABLE" | grep -q "default.*wt0"; then
  ok "NetBird routing table $NETBIRD_TABLE routes default via wt0"
else
  fail "NetBird routing table $NETBIRD_TABLE missing default via wt0"
fi

### =========================
### Phase 5 — Marking verification
### =========================

MANGLE_PKTS="$(
  sudo iptables -t mangle -vnL PREROUTING |
    awk -v i="$AP_IFACE" '$0 ~ i {print $1; exit}'
)"

if [ -n "$MANGLE_PKTS" ] && [ "$MANGLE_PKTS" -gt 0 ]; then
  ok "Client traffic is being marked (packets: $MANGLE_PKTS)"
else
  warn "No marked client packets yet"
  detail "Connect a client and retry"
fi

### =========================
### Phase 6 — NAT activity
### =========================

NAT_PKTS="$(
  sudo iptables -t nat -vnL POSTROUTING |
    awk '$0 ~ /MASQUERADE/ && $0 ~ /wt0/ {print $1; exit}'
)"

if [ -n "$NAT_PKTS" ] && [ "$NAT_PKTS" -gt 0 ]; then
  ok "NAT activity detected on wt0 (packets: $NAT_PKTS)"
else
  warn "No NAT packets yet"
  detail "Connect a client and retry"
fi

### =========================
### Phase 7 — NetBird dataplane (nftables)
### =========================

if sudo nft list ruleset 2>/dev/null | grep -q 'oifname "wt0".*masquerade'; then
  ok "NetBird NAT active on wt0"
else
  fail "NetBird NAT on wt0 not detected"
fi

### =========================
### Phase 8 — Routing simulation
### =========================

if ip route get 1.1.1.1 mark "$NETBIRD_MARK" 2>/dev/null | grep -q "dev wt0"; then
  ok "Marked traffic routes via wt0"
else
  fail "Marked traffic does NOT route via wt0"
fi

### =========================
### Phase 9 — Forwarding confirmation
### =========================

PREROUTING_PKTS="$(sudo nft list chain ip mangle PREROUTING 2>/dev/null | grep -Eo 'packets [0-9]+' | awk '{print $2}' | head -n1)"
POSTROUTING_PKTS="$(sudo nft list chain ip nat POSTROUTING 2>/dev/null | grep -Eo 'packets [0-9]+' | awk '{print $2}' | head -n1)"

if [ -n "$PREROUTING_PKTS" ] && [ "$PREROUTING_PKTS" -gt 0 ] &&
  [ -n "$POSTROUTING_PKTS" ] && [ "$POSTROUTING_PKTS" -gt 0 ]; then
  ok "Forwarded client traffic is marked and NATed via wt0"
else
  warn "No forwarded traffic observed yet"
  detail "Connect a client and retry"
fi

### =========================
### Phase 10 — DNS resolution
### =========================

if getent hosts netbird.io >/dev/null 2>&1; then
  ok "DNS resolution works on the Pi"
else
  warn "DNS resolution failed on the Pi"
fi

exit $FAILURES
