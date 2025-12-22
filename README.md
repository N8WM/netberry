# Netberry

**A DIY Raspberry Pi travel router with enforced NetBird VPN routing**

Netberry turns a Raspberry Pi into a portable Wi-Fi access point that **forces all connected client traffic through NetBird**, providing secure, consistent access to your home network or exit node — without installing VPN software on each device.

You connect the Pi to an upstream network (typically Ethernet), connect your devices to Netberry’s Wi-Fi, and all client traffic is routed through NetBird.

---

## Key features

- **VPN-enforced client routing**  
  Client traffic is fail-closed and cannot reach the internet unless NetBird is up.

- **Dedicated Wi-Fi access point**  
  Creates a WPA2-protected Wi-Fi network for client devices.

- **NetworkManager-based uplinks**  
  Ethernet is used as the primary uplink (Wi-Fi uplink planned).

- **No client VPN software required**  
  Works with devices that cannot install VPNs (TVs, consoles, work laptops).

- **Health-aware hardware LED**  
  The Pi’s ACT LED reflects *actual usability* (VPN + routing + DNS), not just tunnel state.

- **Deterministic validation**  
  Includes a built-in diagnostic script (`doctor.sh`) to verify routing, NAT, policy rules, and NetBird state.

---

## Use cases

- Traveling with locked-down or work-issued devices  
- Securing hotel or Airbnb Wi-Fi  
- Sharing a single VPN tunnel with multiple devices  
- Temporary remote access to a home lab or LAN  

---

## Requirements

- An existing NetBird account with an exit node or exposed subnet  
- Raspberry Pi (tested on Pi 4 and Pi 5)  
- Raspberry Pi OS Lite (64-bit, Debian Trixie)  
- MicroSD card + power supply  
- **Ethernet connection for uplink**  
- **Strongly recommended:** USB Wi-Fi adapter for AP mode  

> The Raspberry Pi’s built-in Wi-Fi (`brcmfmac`) can be unstable in AP mode on newer kernels.  
> Netberry prefers USB Wi-Fi adapters and will warn before using the built-in radio.

---

## Installation

Netberry installs via a **single interactive setup script**.

On a fresh Raspberry Pi OS Lite install:

```
bash <(curl -fsSL https://raw.githubusercontent.com/N8WM/netberry/main/install.sh)
```

The installer will:

- Select an appropriate Wi-Fi interface for AP mode  
- Configure hostapd and dnsmasq  
- Install and enroll NetBird  
- Set up policy routing and NAT  
- Optionally enable LED health signaling  
- Install a diagnostic tool (`doctor.sh`)  

---

## How it works (high level)

```
Client devices
    ↓
Netberry Wi-Fi AP (routed, no bridge)
    ↓
Policy routing + packet marking
    ↓
NetBird tunnel (wt0)
    ↓
Your exit node / home network
```

- Client packets are **marked and routed into NetBird’s routing table**
- NetBird’s own nftables rules handle ACLs and NAT
- Client traffic fails closed if NetBird is unavailable
- Router traffic remains fail-open to allow recovery

---

## LED behavior

- **Heartbeat blink**
  - NetBird control plane connected
  - Tunnel interface present
  - DNS resolution working

- **Solid ON**
  - NetBird down
  - Routing broken
  - DNS unavailable

The LED is debounced to avoid false alarms during brief reconnects.

---

## Diagnostics

After installation, Netberry includes a validation script:

```
~/netbird-doctor.sh
```

This checks:

- NetBird control-plane connectivity  
- Tunnel interface presence  
- AP mode status  
- DHCP activity  
- Policy routing rules  
- Packet marking  
- NAT via the tunnel  
- DNS resolution  

It is safe to run at any time and is also used by the LED logic.

---

## Recovery & safety guarantees

- You can always SSH into the Pi via its Wi-Fi AP  
- The router will not deadlock itself during VPN reconnects  
- Misconfigured uplinks won’t strand the device  
- Client traffic is fail-closed; router traffic is fail-open (by design)  

---

## Disclaimer

This project is provided as-is.  
You are responsible for complying with local laws, network policies, and employer rules.
