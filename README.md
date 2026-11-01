# Custom ImmortalWrt builds for MT798x — 25.12

Custom firmware for the Zyxel EX5601-T0 (ubootmod) and GL.iNet GL-MT3000,
built in router and preconfigured dumb access point variants.

## Upstream source

- Source: [chasey-dev/immortalwrt-mt798x-rebase](https://github.com/chasey-dev/immortalwrt-mt798x-rebase).
- Branch: `25.12`.
- MediaTek Wi-Fi configuration: `mtwifi-cfg-ucode`.

The workflow follows this branch rather than pinning an upstream commit.
Each release records the source URL and branch; `version.buildinfo` records
the built revision.

## Local features

- Corrected MediaTek country/region mappings and dedicated zero-wait DFS configuration.
- MediaTek Wi-Fi/LuCI tools and diagnostics.
- Restored Zyxel EX5601 LAN/WAN board mapping missing from the upstream source.
- SQM support with LuCI and CAKE.

See [`defconfig/`](defconfig) for package, driver, and device-specific firmware
selections, and [`patches/`](patches) for local source changes.

## Devices and images

| Device | Profile | Sysupgrade image suffix |
| --- | --- | --- |
| Zyxel EX5601-T0 with OpenWrt U-Boot layout | `zyxel_ex5601-t0-ubootmod` | `-squashfs-sysupgrade.itb` |
| GL.iNet GL-MT3000 / Beryl AX | `glinet_gl-mt3000` | `-squashfs-sysupgrade.bin` |

Each device is built as both `ap` and `router` on two LAN subnets: **eight
artifacts per workflow run**. The four variants per device are `ap-10.0.0.9`,
`ap-192.168.1.9`, `router-10.0.0.1`, and `router-192.168.1.1`.
Artifact names are `firmware-<profile>-<role>-<LAN-IP>-<YYYYMMDD>`. Successful
runs also create a draft GitHub Release containing one ZIP per artifact, for
example `firmware-glinet_gl-mt3000-ap-192.168.1.9-20261101.zip`.

Each ZIP contains the device's sysupgrade image, `build.log`, and available
metadata: `sha256sums`, `profiles.json`, `config.buildinfo`, and
`version.buildinfo`. The checksum list can also reference upstream outputs
omitted from these minimal archives.

## AP and router defaults

The workflow selects [`uci-defaults/ap`](uci-defaults/ap) or
[`uci-defaults/router`](uci-defaults/router), sets its `lan_prefix` for the
selected subnet, and installs it as `/etc/uci-defaults/99-custom`.
The firmware applies it during first boot, after upstream configuration
creation and before normal network service startup.

| Variant | LAN / management address | AP gateway and DNS | Router DHCPv4 range |
| --- | --- | --- | --- |
| `ap-10.0.0.9` | `10.0.0.9/24` | `10.0.0.1` | — |
| `ap-192.168.1.9` | `192.168.1.9/24` | `192.168.1.1` | — |
| `router-10.0.0.1` | `10.0.0.1/24` | — | `10.0.0.100`–`10.0.0.249` |
| `router-192.168.1.1` | `192.168.1.1/24` | — | `192.168.1.100`–`192.168.1.249` |

Both subnets use the same role settings:

| Setting | AP | Router |
| --- | --- | --- |
| Gateway and DNS override on LAN | Selected subnet's `.1` address | Removed; WAN supplies upstream connectivity |
| DHCPv4 on LAN | Disabled | `.100`–`.249` in the selected subnet, 12-hour leases |
| Physical WAN port | Added to the LAN bridge | Removed from the LAN bridge; used for WAN |
| WAN and WAN6 interfaces | Disabled; definitions retained | AP disable flags removed; saved protocols retained |
| LAN IPv6 prefix assignment | Disabled; local ULA removed | `/60` assignment; ULA restored if missing |
| IPv6 router advertisements / SLAAC | Disabled | Enabled |
| DHCPv6 server on LAN | Disabled | Disabled; clients use SLAAC |

On a clean installation the upstream WAN defaults use DHCP, with DHCPv6 on
WAN6. Existing WAN settings, such as PPPoE credentials, are retained. Global
IPv6 connectivity on the router depends on the upstream connection providing
IPv6 and a suitable delegated prefix.

The AP is a bridge behind an existing router, which must provide DHCP and
routing. Disabling its own IPv6 assignment and advertisements does not block
bridged IPv6 traffic or remove IPv6 link-local addresses. Any Ethernet port can
serve as the AP uplink with the default port layout.

Both scripts expect the generated LAN bridge and a separate physical WAN
device. Review custom VLAN/bridge layouts before flashing. Missing topology,
missing Wi-Fi sections, or failed required UCI writes cause the script to fail;
OpenWrt retains a failed defaults script for retry on the next boot. Logs use
the `99-custom` tag.

**Defaults are reapplied after each flash, including upgrades that preserve
settings.** The selected script resets the listed role, radio, and Wi-Fi
security settings. In particular, it resets AP Wi-Fi keys to `password123`.
Change that key after flashing, or customize the defaults before building.

Choose the AP variant matching the upstream LAN and reserve its `.9` address
on that network. The scripts default to `10.0.0.0/24` when used directly outside
the workflow; edit the single `lan_prefix` assignment to change that subnet.

## Wireless and DFS

Both roles set the timezone to `Europe/Stockholm`, the Wi-Fi country to `SE`,
and existing AP interfaces to WPA2-PSK with the initial key `password123`.

| Band | Channel | Width |
| --- | --- | --- |
| 2.4 GHz | Automatic | `HE40` |
| 5 GHz | Automatic | `HE80` |

Automatic selection is local to each radio; separate APs do not coordinate
channel assignments or continuously rebalance them.

The patches enable 802.11h/DFS and MediaTek's dedicated zero-wait DFS flow for
supported regulatory domains, including Sweden. The driver can serve clients
on an available non-DFS channel while a dedicated detector performs the radar
Channel Availability Check (CAC) for a DFS channel. After successful CAC it
can switch to the cleared channel, with a possible brief interruption.

Radar detection still requires rejecting or leaving the affected channel.
Zero-wait does not bypass CAC or guarantee a DFS channel will be selected;
actual behavior depends on the device, driver, and regulatory conditions.

## SQM

SQM packages are included in **both AP and router images**. Keeping them in
[`defconfig/mt798x_baseline.config`](defconfig/mt798x_baseline.config) avoids
variant-specific package scripts and keeps normal package management intact.

The baseline selects `luci-app-sqm`, `sqm-scripts`, `tc-full`,
`kmod-sched-cake`, `kmod-ifb`, and `kmod-sched-core`. The build system resolves
the remaining dependencies. `tc-full` supplies the complete traffic-control
utility.

On a clean installation SQM queues are disabled until configured. Installing
the packages alone does not enable shaping. Preserved SQM settings can remain
active across upgrades, so review them when changing a device's role.

To use SQM on the router:

1. Open **Network → SQM QoS** in LuCI.
2. Select the actual WAN network device, not the LAN bridge. With the default
   Ethernet WAN layout this is `eth1` on the Zyxel and `eth0` on the GL-MT3000;
   PPPoE or VLAN configurations can use a different device.
3. Set download/upload rates for the connection, choose `cake` and
   `piece_of_cake.qos`, and configure link-layer overhead for the WAN type.
4. Disable hardware NAT/flow acceleration, including MediaTek HNAT in
   TurboACC. Hardware acceleration bypasses SQM's CPU traffic shaping. Avoid
   running another QoS/shaper on the same interface at the same time.
5. Enable the queue, save/apply, and measure latency under load. SQM uses the
   CPU, so available throughput depends on the device and chosen settings.

Normally leave SQM disabled on a bridged AP and shape the internet connection
on its upstream router. See the [OpenWrt SQM guide](https://openwrt.org/docs/guide-user/network/traffic-shaping/sqm)
for rate selection, link-layer settings, and verification.

## Building and installation

The [GitHub Actions workflow](.github/workflows/immortalwrt-matrix.yml) runs on
pushes to `main` and tags matching `v*`. It discovers device configs, merges the
shared baseline with each device config, applies local patches, installs the
selected first-boot script, and compiles a complete firmware for each role and
subnet combination.
The workflow checks first-boot script syntax and rejects a generated config
that drops the requested device or required SQM packages. It currently uses
full source builds, rather than Image Builder.

Download the ZIP for the correct device, role, and subnet from the draft release,
then extract it and flash the matching sysupgrade image from an
existing compatible OpenWrt/ImmortalWrt installation. The Zyxel image requires
the **ubootmod/OpenWrt U-Boot partition layout**; this is not a stock-firmware
conversion guide. The GL-MT3000 uses the `.bin` image shown above.

After boot, use `http://10.0.0.9/` or `http://192.168.1.9/` for AP mode, or
`http://10.0.0.1/` or `http://192.168.1.1/` for router mode, according to the
selected variant, and change the initial Wi-Fi key. Configuration and source
checks cannot replace a firmware build and an on-device test of networking,
wireless, and SQM performance.
