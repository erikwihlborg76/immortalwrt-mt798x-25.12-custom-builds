# Custom ImmortalWrt builds for MT798x — 25.12

ImmortalWrt 25.12 firmware with MediaTek's vendor Wi-Fi driver, LuCI, DFS support, and SQM/CAKE. Both devices have router and dumb access point (AP) variants for the subnets below.

| Device | Profile | Sysupgrade image |
| --- | --- | --- |
| Zyxel EX5601-T0 with OpenWrt U-Boot layout | `zyxel_ex5601-t0-ubootmod` | `.itb` |
| GL.iNet GL-MT3000 / Beryl AX | `glinet_gl-mt3000` | `.bin` |

## Installation

These sysupgrade images require an existing compatible OpenWrt/ImmortalWrt installation. **The Zyxel requires the ubootmod/OpenWrt U-Boot partition layout.**

1. Choose and extract the ZIP matching your device, role, and management address.
2. [Verify the image checksum](docs/firmware-files.md#verify-checksums), then flash the sysupgrade image through LuCI's **System → Backup / Flash Firmware**.
3. After boot, connect a computer to a LAN port and open `http://<management-address>`.

| Variant | Management address |
| --- | --- |
| `ap-10.0.0.9` | `10.0.0.9` |
| `ap-192.168.1.9` | `192.168.1.9` |
| `router-10.0.0.1` | `10.0.0.1` |
| `router-192.168.1.1` | `192.168.1.1` |

All variants use a `/24` subnet. For AP mode, match the existing LAN, reserve the AP's `.9` address, and use an upstream router at `.1` providing DHCP and internet access.

**Defaults reapply after every flash, including upgrades that preserve settings. Wi-Fi AP security resets to WPA2-PSK with the key `password123`; change it after flashing.** The Wi-Fi country defaults to `SE` (Sweden); configure it for your location.

## Documentation

See the [documentation index](docs/README.md) for firmware files and checksums, network defaults, wireless/DFS, SQM, troubleshooting, diagnostics, and build details.
