# Custom ImmortalWrt Builds for MT798x

Custom firmware based on
[chasey-dev/immortalwrt-mt798x-rebase](https://github.com/chasey-dev/immortalwrt-mt798x-rebase)
(`25.12-linkup`), built as a preconfigured dumb access point.

## Supported Devices

- Zyxel EX5601-T0 (ubootmod)
- GL.iNet GL-MT3000 / Beryl AX

## Local Features

- Corrected MediaTek country/region mappings.
- 5 GHz DFS, 802.11h, and dedicated zero-wait DFS support.
- English-focused package selection with MediaTek Wi-Fi/LuCI tools and useful
  diagnostics, without the bundled VPN/proxy extras.

## AP Overlay

[`files/etc/uci-defaults/99-ap-mode`](files/etc/uci-defaults/99-ap-mode)
applies these settings on first boot:

- Static LAN address `10.0.0.9/24`, with gateway and DNS server `10.0.0.1`.
- DHCPv4, DHCPv6, router advertisements, NDP, and LAN IPv6 prefix assignment
  disabled.
- Timezone set to `Europe/Stockholm`.
- Wi-Fi country set to Sweden (`SE`).
- 2.4 GHz set to channel 6 with `HE40`; 5 GHz set to `HE80`.
- AP interfaces secured with WPA2-PSK using the initial key `password123`.
- Configuration failures logged and reported with a nonzero exit status.

> **Required:** Reboot the device once after its first boot. This is necessary
> for DNS resolution on the device itself to work correctly.

After rebooting, manage the device at `http://10.0.0.9/`. Change the default
Wi-Fi key immediately.

## Installation

Download the matching draft GitHub Release, extract it, and flash the
`*squashfs-sysupgrade.itb` image from an existing OpenWrt/ImmortalWrt
ubootmod installation.
