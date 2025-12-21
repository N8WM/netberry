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
  iw reg get 2>/dev/null |
    awk '/country/ {print substr($2,1,2)}' |
    head -n1
}

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
LAN_NET="192.168.50.0/24"

DETECTED_COUNTRY="$(detect_country || true)"
if [ -n "$DETECTED_COUNTRY" ]; then
  WIFI_COUNTRY=$(prompt_default "Wi-Fi country code" "$DETECTED_COUNTRY")
else
  WIFI_COUNTRY=$(prompt_required "Wi-Fi country code (e.g. US, CA, DE)")
fi

LED_ENABLE=$(prompt_default "Enable LED status indicator? (yes/no)" "yes")

NETBIRD_MGMT_URL=$(prompt_optional "NetBird management URL")
NETBIRD_SETUP_KEY=$(prompt_required "NetBird setup key")

### =========================
### Packages
### =========================

sudo apt update
sudo apt install -y \
  hostapd dnsmasq iptables-persistent \
  bridge-utils iw curl jq

### =========================
### NetworkManager config
### =========================

sudo mkdir -p /etc/NetworkManager/conf.d

sudo tee /etc/NetworkManager/conf.d/router-unmanaged.conf >/dev/null <<EOF
[keyfile]
unmanaged-devices=interface-name:wlan0;interface-name:br0
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
### RFKill fix
### =========================

sudo tee /etc/systemd/system/unblock-wifi.service >/dev/null <<EOF
[Unit]
Description=Unblock WiFi after NetworkManager
After=NetworkManager.service

[Service]
Type=oneshot
ExecStart=/usr/sbin/rfkill unblock wifi

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl enable --now unblock-wifi.service

### =========================
### Bridge
### =========================

sudo systemctl enable --now systemd-networkd

sudo tee /etc/systemd/network/br0.netdev >/dev/null <<EOF
[NetDev]
Name=br0
Kind=bridge
EOF

sudo tee /etc/systemd/network/br0.network >/dev/null <<EOF
[Match]
Name=br0

[Network]
Address=$LAN_CIDR
EOF

sudo systemctl restart systemd-networkd

### =========================
### hostapd
### =========================

sudo tee /etc/hostapd/hostapd.conf >/dev/null <<EOF
interface=wlan0
bridge=br0
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
### dnsmasq
### =========================

sudo mv /etc/dnsmasq.conf /etc/dnsmasq.conf.orig 2>/dev/null || true
sudo tee /etc/dnsmasq.conf >/dev/null <<EOF
interface=br0
bind-interfaces
dhcp-range=192.168.50.10,192.168.50.200,12h
domain-needed
bogus-priv
EOF

### =========================
### Routing
### =========================

echo 'net.ipv4.ip_forward=1' | sudo tee /etc/sysctl.d/99-router.conf
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
### Firewall (client-only kill-switch)
### =========================

sudo iptables -F
sudo iptables -t nat -F

sudo iptables -t nat -A POSTROUTING -o wt0 -j MASQUERADE
sudo iptables -A FORWARD -i br0 -o wt0 -j ACCEPT
sudo iptables -A FORWARD -i wt0 -o br0 -m state --state RELATED,ESTABLISHED -j ACCEPT
sudo iptables -A FORWARD -i br0 ! -o wt0 -j DROP

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

sudo systemctl enable hostapd dnsmasq
sudo systemctl restart hostapd dnsmasq

echo
echo "✔ Setup complete. Reboot recommended."
