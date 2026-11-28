# Configuration

[Documentation index](README.md)

## AP and router defaults

The workflow selects [`uci-defaults/ap`](../uci-defaults/ap) or [`uci-defaults/router`](../uci-defaults/router), sets its `lan_prefix` for the selected subnet, and installs it as `/etc/uci-defaults/99-custom`. The firmware applies it during first boot, after upstream configuration creation and before normal network service startup. The scripts default to `10.0.0.0/24` when used directly outside the workflow; edit the single `lan_prefix` assignment to change that subnet.

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

On a clean installation the upstream WAN defaults use DHCP, with DHCPv6 on WAN6. Existing WAN settings, such as PPPoE credentials, are retained. Global IPv6 connectivity on the router depends on the upstream connection providing IPv6 and a suitable delegated prefix.

The AP is a bridge behind an existing router, which must provide DHCP and routing. Disabling its own IPv6 assignment and advertisements does not block bridged IPv6 traffic or remove IPv6 link-local addresses. Any Ethernet port can serve as the AP uplink with the default port layout.

Both scripts expect the generated LAN bridge and a separate physical WAN device. They validate topology, radio bands, and interface modes and require at least one radio and AP interface before staging UCI changes. Review custom VLAN/bridge layouts before flashing. Missing topology, missing Wi-Fi sections, or failed required UCI writes cause the script to fail; see [Troubleshooting defaults](troubleshooting.md#defaults-failed-or-remain-pending) for partial changes and retry behavior.

The Zyxel uses `wan` as its physical WAN device in OpenWrt/ImmortalWrt 25.12; the GL-MT3000 uses `eth0`. The Zyxel naming follows [OpenWrt's intentional `eth1` to `wan` change](https://github.com/openwrt/openwrt/commit/f26260c7e75112429901fff59ef0a0f5601c5675). The defaults verify that the selected WAN device exists. On a Zyxel with `wan` present and `eth1` absent, they migrate plain `eth1` references in WAN/WAN6, an optional device section, and LAN bridge membership, retaining the saved WAN protocol and credentials. Legacy `eth1.VLAN` references and conflicting `eth1`/`wan` device sections require manual review and stop the defaults before any UCI changes. Existing SQM interface selections are also preserved and must be checked separately after a device rename.

## Wireless and DFS

Both roles set the timezone to `Europe/Stockholm` and the Wi-Fi country to `SE`. The Wi-Fi security reset described under [Installation](../README.md#installation) applies to every existing interface whose mode is `ap`, including those in router images. The scripts preserve SSIDs and radio/interface enable flags; a disabled radio or interface stays disabled.

| Band | Channel | Width |
| --- | --- | --- |
| 2.4 GHz | Automatic | `HE40` |
| 5 GHz | Automatic | `HE80` |

Automatic selection is local to each radio; separate APs do not coordinate channel assignments or continuously rebalance them.

The patches enable 802.11h/DFS and MediaTek's dedicated zero-wait DFS flow for supported regulatory domains, including Sweden. The driver can serve clients on an available non-DFS channel while a dedicated detector performs the radar Channel Availability Check (CAC) for a DFS channel. After successful CAC it can switch to the cleared channel, with a possible brief interruption.

Radar detection still requires rejecting or leaving the affected channel. Zero-wait does not bypass CAC or guarantee a DFS channel will be selected; actual behavior depends on the device, driver, and regulatory conditions.

## SQM

SQM packages are included in **both AP and router images**. Keeping them in [`defconfig/mt798x_baseline.config`](../defconfig/mt798x_baseline.config) avoids variant-specific package scripts and keeps normal package management intact.

The baseline selects `luci-app-sqm`, `sqm-scripts`, `tc-full`, `kmod-sched-cake`, `kmod-ifb`, and `kmod-sched-core`. The build system resolves the remaining dependencies. `tc-full` supplies the complete traffic-control utility.

On a clean installation SQM queues are disabled until configured. Installing the packages alone does not enable shaping. Preserved SQM settings can remain active across upgrades, so review them when changing a device's role.

To use SQM on the router:

1. Open **Network → SQM QoS** in LuCI.
2. Select the actual WAN network device, not the LAN bridge. With the default Ethernet WAN layout this is `wan` on the Zyxel and `eth0` on the GL-MT3000; PPPoE or VLAN configurations can use a different device. Review preserved SQM settings that still reference the Zyxel's former `eth1` name.
3. Set download/upload rates for the connection, choose `cake` and `piece_of_cake.qos`, and configure link-layer overhead for the WAN type.
4. Disable hardware NAT/flow acceleration, including MediaTek HNAT in TurboACC. Hardware acceleration bypasses SQM's CPU traffic shaping. Avoid running another QoS/shaper on the same interface at the same time.
5. Enable the queue, save/apply, and measure latency under load. SQM uses the CPU, so available throughput depends on the device and chosen settings.

Normally leave SQM disabled on a bridged AP and shape the internet connection on its upstream router. See the [OpenWrt SQM guide](https://openwrt.org/docs/guide-user/network/traffic-shaping/sqm) for rate selection, link-layer settings, and verification.

Configuration and source checks cannot replace a firmware build and an on-device test of networking, wireless, and SQM performance.
