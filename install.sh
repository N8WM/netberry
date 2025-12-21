#!/usr/bin/env bash
set -euo pipefail

# Netberry installer (Raspberry Pi OS Lite 64-bit / Debian Trixie, NetworkManager-based)
# Design goals:
# - Prefer a USB Wi-Fi adapter for AP mode (more stable than Pi built-in brcmfmac on newer kernels).
# - Keep NetworkManager for uplinks (Ethernet/Wi-Fi uplink later), but keep it away from the AP interface.
# - No bridges/systemd-networkd. Routed AP + NAT through NetBird (wt0).
# - Minimal “fixup” logic: no aggressive rfkill/NM radio hacks. Just correct ownership & ordering.

### =========================
### Helpers
### =========================

die() {
  echo "ERROR: $*" >&2
  exit 1
}

need_root_tools() {
  command -v sudo >/dev/null 2>&1 || die "sudo not found"
}

prompt_default() {
  local prompt="$1" default="$2" var
  read -rp "$prompt ($default): " var
  echo "${var:-$default}"
}

prompt_optional() {
  local prompt="$1" var
  read -rp "$prompt (optional): " var
  echo "$var"
}

prompt_required() {
  local prompt="$1" var
  while true; do
    read -rp "$prompt (required): " var
    [ -n "$var" ] && {
      echo "$var"
      return
    }
    echo "This value is required."
  done
}

prompt_yesno_default() {
  local prompt="$1" default="$2" var
  while true; do
    read -rp "$prompt [yes/no] ($default): " var
    var="${var:-$default}"
    case "$var" in
    yes | no)
      echo "$var"
      return
      ;;
    *) echo "Please enter 'yes' or 'no'." ;;
    esac
  done
}

detect_country() {
  iw reg get 2>/dev/null | awk '/country/ {print substr($2,1,2)}' | head -n1
}

cidr_to_ip() { echo "$1" | cut -d/ -f1; }
cidr_to_prefix() { echo "$1" | cut -d/ -f2; }

# List wireless interfaces (names only)
list_wifi_ifaces() {
  iw dev 2>/dev/null | awk '$1=="Interface"{print $2}'
}

# Return kernel driver module name for an interface, if available
iface_driver_module() {
  local iface="$1"
  local mod=""
  if command -v ethtool >/dev/null 2>&1; then
    mod="$(ethtool -i "$iface" 2>/dev/null | awk -F': ' '$1=="driver"{print $2}' | head -n1 || true)"
  fi
  if [ -z "$mod" ]; then
    # Fallback: /sys path
    local drv_link="/sys/class/net/${iface}/device/driver/module"
    if [ -e "$drv_link" ]; then
      mod="$(basename "$(readlink -f "$drv_link")" 2>/dev/null || true)"
    fi
  fi
  echo "$mod"
}

# Prefer USB Wi-Fi (non-brcmfmac) for AP. If only brcmfmac exists, allow but warn/confirm.
pick_ap_iface() {
  local ifaces=() i mod
  mapfile -t ifaces < <(list_wifi_ifaces || true)
  [ "${#ifaces[@]}" -gt 0 ] || die "No Wi-Fi interfaces found (iw dev returned none). Plug in a USB Wi-Fi adapter and retry."

  # First pass: any iface whose driver is not brcmfmac
  for i in "${ifaces[@]}"; do
    mod="$(iface_driver_module "$i")"
    if [ -n "$mod" ] && [ "$mod" != "brcmfmac" ]; then
      echo "$i"
      return
    fi
  done

  # Second pass: unknown driver (could still be USB). Prefer non-wlan0 if present.
  for i in "${ifaces[@]}"; do
    mod="$(iface_driver_module "$i")"
    if [ -z "$mod" ] && [ "$i" != "wlan0" ]; then
      echo "$i"
      return
    fi
  done

  # Last resort: wlan0 / brcmfmac
  echo "${ifaces[0]}"
}

# Force NetworkManager to not manage an interface, both persistently (conf) and at runtime (nmcli).
nm_unmanage_iface() {
  local iface="$1"
  sudo mkdir -p /etc/NetworkManager/conf.d
  sudo tee /etc/NetworkManager/conf.d/netberry-ap-unmanaged.conf >/dev/null <<EOF
[keyfile]
unmanaged-devices=interface-name:${iface}
EOF

  sudo systemctl restart NetworkManager

  # Runtime hint (works when NM sees device as managed)
  if command -v nmcli >/dev/null 2>&1; then
    sudo nmcli dev set "$iface" managed no >/dev/null 2>&1 || true
  fi
}

# Create/replace a systemd oneshot to assign a static IP to AP interface before hostapd/dnsmasq
install_ap_ip_service() {
  local iface="$1" ip="$2" prefix="$3"
  sudo tee /etc/systemd/system/netberry-ap-ip.service >/dev/null <<EOF
[Unit]
Description=Assign static LAN IP to ${iface} for Netberry AP
After=NetworkManager.service
Wants=NetworkManager.service
Before=hostapd.service dnsmasq.service

[Service]
Type=oneshot
ExecStart=/usr/sbin/ip link set ${iface} up
ExecStart=/usr/sbin/ip addr flush dev ${iface}
ExecStart=/usr/sbin/ip addr add ${ip}/${prefix} dev ${iface}

[Install]
WantedBy=multi-user.target
EOF
  sudo systemctl enable --now netberry-ap-ip.service
}

install_hostapd() {
  local iface="$1" ssid="$2" psk="$3" country="$4" channel="$5"
  sudo tee /etc/hostapd/hostapd.conf >/dev/null <<EOF
interface=${iface}
driver=nl80211
ssid=${ssid}

# 2.4 GHz AP (broadest compatibility)
country_code=${country}
hw_mode=g
channel=${channel}
ieee80211n=1
wmm_enabled=1

# WPA2-Personal
wpa=2
wpa_passphrase=${psk}
wpa_key_mgmt=WPA-PSK
rsn_pairwise=CCMP
EOF

  # Ensure hostapd reads our config
  if [ -f /etc/default/hostapd ]; then
    sudo sed -i 's|^#\?DAEMON_CONF=.*|DAEMON_CONF="/etc/hostapd/hostapd.conf"|' /etc/default/hostapd
  else
    # Some images may not ship /etc/default/hostapd; systemd unit already sets DAEMON_CONF.
    :
  fi

  # Ensure hostapd starts after IP assignment (avoids races)
  sudo mkdir -p /etc/systemd/system/hostapd.service.d
  sudo tee /etc/systemd/system/hostapd.service.d/netberry-ordering.conf >/dev/null <<EOF
[Unit]
After=netberry-ap-ip.service
Wants=netberry-ap-ip.service
EOF

  sudo systemctl daemon-reload
}

install_dnsmasq() {
  local iface="$1" ip="$2" dhcp_start="$3" dhcp_end="$4"
  sudo mv /etc/dnsmasq.conf /etc/dnsmasq.conf.orig 2>/dev/null || true
  sudo tee /etc/dnsmasq.conf >/dev/null <<EOF
interface=${iface}
bind-interfaces

dhcp-range=${dhcp_start},${dhcp_end},12h
dhcp-option=option:router,${ip}
dhcp-option=option:dns-server,${ip}

domain-needed
bogus-priv
EOF

  # Ensure dnsmasq starts after IP assignment
  sudo mkdir -p /etc/systemd/system/dnsmasq.service.d
  sudo tee /etc/systemd/system/dnsmasq.service.d/netberry-ordering.conf >/dev/null <<EOF
[Unit]
After=netberry-ap-ip.service
Wants=netberry-ap-ip.service
EOF

  sudo systemctl daemon-reload
}

install_sysctl_forwarding() {
  echo 'net.ipv4.ip_forward=1' | sudo tee /etc/sysctl.d/99-netberry-router.conf >/dev/null
  sudo sysctl --system >/dev/null
}

install_netbird() {
  local mgmt_url="$1" setup_key="$2"
  curl -fsSL https://pkgs.netbird.io/install.sh | sh

  local -a cmd=(netbird up --setup-key "$setup_key")
  [ -n "$mgmt_url" ] && cmd+=(--management-url "$mgmt_url")

  sudo "${cmd[@]}"
  sudo systemctl enable netbird
}

install_firewall() {
  local ap_iface="$1"
  # Flush + install minimal client-only kill-switch:
  # - Clients (AP iface) may only forward to wt0
  # - NAT out wt0
  sudo iptables -F
  sudo iptables -t nat -F

  sudo iptables -t nat -A POSTROUTING -o wt0 -j MASQUERADE
  sudo iptables -A FORWARD -i "${ap_iface}" -o wt0 -j ACCEPT
  sudo iptables -A FORWARD -i wt0 -o "${ap_iface}" -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
  sudo iptables -A FORWARD -i "${ap_iface}" ! -o wt0 -j DROP

  sudo netfilter-persistent save
}

install_led_logic() {
  # Uses ACT LED; flips to solid-on after N consecutive failures; heartbeat on success.
  sudo tee /usr/local/bin/netbird-led.sh >/dev/null <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

LED="/sys/class/leds/ACT"
STATE="/run/netbird-led.failcount"
MAX=3

ok()  { echo heartbeat > "$LED/trigger"; echo 0 > "$STATE"; }
bad() { echo none > "$LED/trigger"; echo 1 > "$LED/brightness"; }

fails=0; [ -f "$STATE" ] && fails=$(cat "$STATE")

# Require the data plane interface
if ! ip link show wt0 >/dev/null 2>&1; then
  fails=$((fails+1)); echo "$fails" > "$STATE"; [ "$fails" -ge "$MAX" ] && bad; exit 0
fi

# Simple connectivity check: DNS resolution via system resolver
if getent hosts netbird.io >/dev/null 2>&1; then
  ok
  exit 0
fi

fails=$((fails+1)); echo "$fails" > "$STATE"
[ "$fails" -ge "$MAX" ] && bad
EOF

  sudo chmod +x /usr/local/bin/netbird-led.sh

  sudo tee /etc/systemd/system/netbird-led.timer >/dev/null <<EOF
[Timer]
OnBootSec=20s
OnUnitActiveSec=10s

[Install]
WantedBy=timers.target
EOF

  sudo tee /etc/systemd/system/netbird-led.service >/dev/null <<EOF
[Service]
Type=oneshot
ExecStart=/usr/local/bin/netbird-led.sh
EOF

  sudo systemctl daemon-reload
  sudo systemctl enable --now netbird-led.timer
}

### =========================
### User input
### =========================

need_root_tools

AP_SSID="$(prompt_default "AP SSID" "Netberry")"

while true; do
  read -rsp "AP Passphrase (8–63 chars): " AP_PSK
  echo
  local_len=${#AP_PSK}
  if [ "$local_len" -lt 8 ] || [ "$local_len" -gt 63 ]; then
    echo "Passphrase must be between 8 and 63 characters."
    continue
  fi
  read -rsp "Confirm AP Passphrase: " AP_PSK_CONFIRM
  echo
  if [ "$AP_PSK" != "$AP_PSK_CONFIRM" ]; then
    echo "Passphrases do not match. Try again."
    continue
  fi
  break
done

LAN_CIDR="$(prompt_default "LAN CIDR" "192.168.50.1/24")"
LAN_IP="$(cidr_to_ip "$LAN_CIDR")"
LAN_PREFIX="$(cidr_to_prefix "$LAN_CIDR")"
LAN_DHCP_START="$(prompt_default "DHCP start IP" "192.168.50.10")"
LAN_DHCP_END="$(prompt_default "DHCP end IP" "192.168.50.200")"

DETECTED_COUNTRY="$(detect_country || true)"
if [ -n "$DETECTED_COUNTRY" ]; then
  WIFI_COUNTRY="$(prompt_default "Wi-Fi country code" "$DETECTED_COUNTRY")"
else
  WIFI_COUNTRY="$(prompt_required "Wi-Fi country code (e.g. US, CA, DE)")"
fi

# Keep radio settings conservative for broad compatibility
AP_CHANNEL="$(prompt_default "AP channel (2.4 GHz; 1/6/11 recommended)" "1")"

LED_ENABLE="$(prompt_yesno_default "Enable LED status indicator?" "yes")"

NETBIRD_MGMT_URL="$(prompt_optional "NetBird management URL")"
NETBIRD_SETUP_KEY="$(prompt_required "NetBird setup key")"

echo
echo "Starting installation with the following settings:"
echo "  AP SSID:           $AP_SSID"
echo "  AP Passphrase:     [hidden]"
echo "  LAN CIDR:          $LAN_CIDR"
echo "  DHCP range:        $LAN_DHCP_START - $LAN_DHCP_END"
echo "  Wi-Fi Country:     $WIFI_COUNTRY"
echo "  AP channel:        $AP_CHANNEL"
echo "  LED Indicator:     $LED_ENABLE"
echo "  NetBird Mgmt URL:  ${NETBIRD_MGMT_URL:-[not set]}"
echo "  NetBird Setup Key: [hidden]"
echo

CONFIRM="$(prompt_yesno_default "Proceed with installation?" "no")"
[ "$CONFIRM" = "yes" ] || die "Installation cancelled by user."

### =========================
### Packages
### =========================

sudo apt update
sudo apt install -y \
  hostapd dnsmasq iptables-persistent \
  iw curl jq rfkill ethtool

### =========================
### Regulatory domain (best-effort)
### =========================

if command -v raspi-config >/dev/null 2>&1; then
  sudo raspi-config nonint do_wifi_country "$WIFI_COUNTRY" || true
fi
sudo iw reg set "$WIFI_COUNTRY" || true

### =========================
### Pick AP interface (prefer USB Wi-Fi)
### =========================

AP_IFACE="$(pick_ap_iface)"
AP_DRV="$(iface_driver_module "$AP_IFACE")"

echo "Selected AP interface: $AP_IFACE (driver: ${AP_DRV:-unknown})"

if [ "${AP_DRV:-}" = "brcmfmac" ]; then
  echo "WARNING: Selected interface uses brcmfmac (Pi built-in Wi-Fi)."
  echo "         AP mode may be unstable on newer kernels. A USB Wi-Fi adapter is strongly recommended."
  CONT="$(prompt_yesno_default "Continue anyway using $AP_IFACE?" "no")"
  [ "$CONT" = "yes" ] || die "Aborted. Plug in a USB Wi-Fi adapter and rerun."
fi

### =========================
### Keep NetworkManager away from AP iface
### =========================

nm_unmanage_iface "$AP_IFACE"

### =========================
### Assign static LAN IP to AP iface
### =========================

install_ap_ip_service "$AP_IFACE" "$LAN_IP" "$LAN_PREFIX"

### =========================
### hostapd + dnsmasq
### =========================

install_hostapd "$AP_IFACE" "$AP_SSID" "$AP_PSK" "$WIFI_COUNTRY" "$AP_CHANNEL"
install_dnsmasq "$AP_IFACE" "$LAN_IP" "$LAN_DHCP_START" "$LAN_DHCP_END"

### =========================
### Routing + NetBird + firewall
### =========================

install_sysctl_forwarding
install_netbird "$NETBIRD_MGMT_URL" "$NETBIRD_SETUP_KEY"
install_firewall "$AP_IFACE"

### =========================
### LED logic (optional)
### =========================

if [ "$LED_ENABLE" = "yes" ]; then
  # Only install if the LED path exists
  if [ -d /sys/class/leds/ACT ]; then
    install_led_logic
  else
    echo "NOTE: ACT LED not found at /sys/class/leds/ACT; skipping LED setup."
  fi
fi

### =========================
### Enable services
### =========================

sudo systemctl unmask hostapd >/dev/null 2>&1 || true
sudo systemctl enable hostapd dnsmasq
sudo systemctl restart hostapd dnsmasq

echo
echo "✔ Setup complete."
echo "  AP interface: $AP_IFACE"
echo "  Reboot recommended."
