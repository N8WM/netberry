#!/usr/bin/env bash
set -euo pipefail

### =========================
### Helpers
### =========================

prompt_default() {
  local prompt="$1"
  local default="$2"
  local var
  read -rp "$prompt ($default): " var
  echo "${var:-$default}"
}

prompt_optional() {
  local prompt="$1"
  local var
  read -rp "$prompt (optional): " var
  echo "$var"
}

prompt_required() {
  local prompt="$1"
  local var
  while true; do
    read -rp "$prompt (required): " var
    [ -n "$var" ] && {
      echo "$var"
      return
    }
    echo "This value is required."
  done
}

detect_country() {
  iw reg get 2>/dev/null | awk '/country/ {print substr($2,1,2)}' | head -n1
}

cidr_to_ip() { echo "$1" | cut -d/ -f1; }
cidr_to_prefix() { echo "$1" | cut -d/ -f2; }

### =========================
### User input
### =========================

AP_SSID=$(prompt_default "AP SSID" "Netberry")

while true; do
  read -rsp "AP Passphrase (8–63 chars): " AP_PSK
  echo
  PSK_LEN=${#AP_PSK}
  if [ "$PSK_LEN" -lt 8 ] || [ "$PSK_LEN" -gt 63 ]; then
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

LAN_CIDR=$(prompt_default "LAN CIDR" "192.168.50.1/24")
LAN_IP="$(cidr_to_ip "$LAN_CIDR")"
LAN_PREFIX="$(cidr_to_prefix "$LAN_CIDR")"
LAN_DHCP_START="192.168.50.10"
LAN_DHCP_END="192.168.50.200"

DETECTED_COUNTRY="$(detect_country || true)"
if [ -n "$DETECTED_COUNTRY" ]; then
  WIFI_COUNTRY=$(prompt_default "Wi-Fi country code" "$DETECTED_COUNTRY")
else
  WIFI_COUNTRY=$(prompt_required "Wi-Fi country code (e.g. US, CA, DE)")
fi

LED_ENABLE=$(prompt_default "Enable LED status indicator? [yes/no]" "yes")

NETBIRD_MGMT_URL=$(prompt_optional "NetBird management URL")
NETBIRD_SETUP_KEY=$(prompt_required "NetBird setup key")

### =========================
### Packages
### =========================

sudo apt update
sudo apt install -y \
  hostapd dnsmasq iptables-persistent \
  iw curl jq rfkill

### =========================
### NetworkManager config
### =========================

sudo mkdir -p /etc/NetworkManager/conf.d

# Keep NM for uplinks; don't let it touch AP interface
sudo tee /etc/NetworkManager/conf.d/router-unmanaged.conf >/dev/null <<EOF
[keyfile]
unmanaged-devices=interface-name:wlan0
EOF

sudo tee /etc/NetworkManager/conf.d/wifi-powersave.conf >/dev/null <<EOF
[connection]
wifi.powersave=2
EOF

sudo systemctl restart NetworkManager

### =========================
### Regulatory domain
### =========================

sudo raspi-config nonint do_wifi_country "$WIFI_COUNTRY"
sudo iw reg set "$WIFI_COUNTRY"

### =========================
### RFKill fix (Wi-Fi sometimes comes up soft-blocked)
### =========================

sudo tee /etc/systemd/system/unblock-wifi.service >/dev/null <<EOF
[Unit]
Description=Unblock WiFi after NetworkManager
After=NetworkManager.service
Wants=NetworkManager.service

[Service]
Type=oneshot
ExecStart=/usr/sbin/rfkill unblock wifi

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl enable --now unblock-wifi.service
sudo rfkill unblock wifi || true

### =========================
### Assign static LAN IP to wlan0 (no bridge, no systemd-networkd)
### =========================

sudo tee /etc/systemd/system/netberry-wlan0-ip.service >/dev/null <<EOF
[Unit]
Description=Assign static LAN IP to wlan0 for Netberry AP
After=NetworkManager.service unblock-wifi.service
Wants=NetworkManager.service unblock-wifi.service
Before=hostapd.service dnsmasq.service

[Service]
Type=oneshot
ExecStart=/usr/sbin/ip link set wlan0 up
ExecStart=/usr/sbin/ip addr flush dev wlan0
ExecStart=/usr/sbin/ip addr add ${LAN_IP}/${LAN_PREFIX} dev wlan0

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl enable --now netberry-wlan0-ip.service

### =========================
### hostapd (AP on wlan0, routed/NAT)
### =========================

sudo tee /etc/hostapd/hostapd.conf >/dev/null <<EOF
interface=wlan0
driver=nl80211
ssid=$AP_SSID
hw_mode=g
channel=7
wmm_enabled=1
country_code=$WIFI_COUNTRY

wpa=2
wpa_passphrase=$AP_PSK
wpa_key_mgmt=WPA-PSK
rsn_pairwise=CCMP
EOF

sudo sed -i 's|^#\?DAEMON_CONF=.*|DAEMON_CONF="/etc/hostapd/hostapd.conf"|' /etc/default/hostapd

### =========================
### dnsmasq (DHCP/DNS on wlan0; explicit router + dns options)
### =========================

sudo mv /etc/dnsmasq.conf /etc/dnsmasq.conf.orig 2>/dev/null || true
sudo tee /etc/dnsmasq.conf >/dev/null <<EOF
interface=wlan0
bind-interfaces

dhcp-range=${LAN_DHCP_START},${LAN_DHCP_END},12h
dhcp-option=option:router,${LAN_IP}
dhcp-option=option:dns-server,${LAN_IP}

domain-needed
bogus-priv
EOF

### =========================
### Routing
### =========================

echo 'net.ipv4.ip_forward=1' | sudo tee /etc/sysctl.d/99-router.conf >/dev/null
sudo sysctl --system

### =========================
### NetBird install + enrollment
### =========================

curl -fsSL https://pkgs.netbird.io/install.sh | sh

NETBIRD_CMD=(netbird up --setup-key "$NETBIRD_SETUP_KEY")
[ -n "$NETBIRD_MGMT_URL" ] && NETBIRD_CMD+=(--management-url "$NETBIRD_MGMT_URL")

sudo "${NETBIRD_CMD[@]}"
sudo systemctl enable netbird

### =========================
### Firewall (client-only kill-switch; LAN is wlan0 now)
### =========================

sudo iptables -F
sudo iptables -t nat -F

# NAT clients out the NetBird tunnel only
sudo iptables -t nat -A POSTROUTING -o wt0 -j MASQUERADE

# Allow client -> VPN, return traffic back, block client -> non-VPN
sudo iptables -A FORWARD -i wlan0 -o wt0 -j ACCEPT
sudo iptables -A FORWARD -i wt0 -o wlan0 -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
sudo iptables -A FORWARD -i wlan0 ! -o wt0 -j DROP

sudo netfilter-persistent save

### =========================
### LED logic (optional)
### =========================

if [ "$LED_ENABLE" = "yes" ]; then
  sudo tee /usr/local/bin/netbird-led.sh >/dev/null <<'EOF'
#!/bin/bash
set -euo pipefail

LED="/sys/class/leds/ACT"
STATE="/run/netbird-led.failcount"
MAX=3

ok() { echo heartbeat > "$LED/trigger"; echo 0 > "$STATE"; }
bad() { echo none > "$LED/trigger"; echo 1 > "$LED/brightness"; }

fails=0; [ -f "$STATE" ] && fails=$(cat "$STATE")

if ! ip link show wt0 >/dev/null 2>&1; then
  fails=$((fails+1)); echo "$fails" > "$STATE"; [ "$fails" -ge "$MAX" ] && bad; exit 0
fi

if getent hosts netbird.io >/dev/null 2>&1; then ok; exit 0; fi

fails=$((fails+1)); echo "$fails" > "$STATE"; [ "$fails" -ge "$MAX" ] && bad
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

  sudo systemctl enable --now netbird-led.timer
fi

### =========================
### Services
### =========================

sudo systemctl unmask hostapd || true
sudo systemctl enable hostapd dnsmasq
sudo systemctl restart hostapd dnsmasq

echo
echo "✔ Setup complete. Reboot recommended."
