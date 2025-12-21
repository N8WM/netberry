# Netberry

**A DIY Raspberry Pi travel router with NetBird VPN enforcement**

Netberry turns a Raspberry Pi into a portable Wi-Fi access point that **forces all connected devices to route traffic through NetBird**, giving you secure, consistent access to your home network from anywhere—without installing VPN clients on each device.

Connect your Pi to an available network and your devices to its Wi-Fi access point, and all traffic is tunneled through NetBird.

## Key features

- **VPN-enforced routing**  
  All client traffic is forced through NetBird (kill-switch enabled).

- **Wi-Fi access point**  
  Creates its own WPA2-protected Wi-Fi network.

- **Ethernet for uplink**  
  Ethernet is used for internet access.  
  *Wired clients are supported but require a USB Wi-Fi adapter for uplink and Wi-Fi security configuration.*

- **No client software required**  
  Works with devices that cannot install VPNs.

- **Hardware LED status indicator**  
  The Pi’s ACT LED shows *real usability* (VPN + routing + DNS), not just “connected”.

## Use cases

- Travel with a work-issued laptop
- Secure hotel or Airbnb Wi-Fi
- Shared VPN access for multiple devices
- Temporary remote access to a home lab or LAN

## Requirements

- An existing NetBird account with a configured exit node
- Raspberry Pi (tested on Pi 4 / Pi 5)
- Raspberry Pi OS Lite (64-bit)
- MicroSD card
- Power supply
- Ethernet cable (for wired uplink)
- Optional: USB Wi-Fi adapter (for future Wi-Fi uplink support)

## Installation

Netberry is installed via a **single interactive setup script**.

In your Pi's terminal, run:

```bash
sh <(curl -fsSL https://raw.githubusercontent.com/N8WM/netberry/main/install.sh)
```

> This script should be run on a **fresh Raspberry Pi OS Lite install**.

## Software stack

- **Raspberry Pi OS Lite (Trixie)**
- NetworkManager (uplinks)
- hostapd (Wi-Fi AP)
- dnsmasq (DHCP)
- NetBird (VPN)
- iptables (client-only kill-switch)
- systemd timers (health checks)
- sysfs LED control

## How it works (high level)

Client devices > Netberry Wi-Fi AP (br0) > NetBird tunnel (wt0) > Your home network / exit node

- Clients **cannot reach the internet** unless the VPN is up
- The router itself is allowed limited connectivity to recover the VPN
- LED reflects whether clients would actually have working internet

## LED behavior

- **Heartbeat blink** → VPN up, DNS working, clients usable
- **Solid ON** → VPN down, routing broken, or DNS unavailable

The LED is debounced and resilient to transient control-plane reconnects.

## Recovery & safety guarantees

- You can always SSH into the Pi via its Wi-Fi AP
- The router never deadlocks itself during VPN reconnects
- Misconfigured uplinks won’t strand the device
- Client traffic is fail-closed; router traffic is fail-open (by design)

## Disclaimer

This project is provided as-is. You are responsible for complying with local laws, network policies, and employer rules.
