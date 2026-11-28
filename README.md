# Custom ImmortalWrt builds for MT798x — 25.12

Custom firmware for the Zyxel EX5601-T0 (ubootmod) and GL.iNet GL-MT3000, built in router and preconfigured dumb access point variants.

## Devices and images

| Device | Profile | Sysupgrade image suffix |
| --- | --- | --- |
| Zyxel EX5601-T0 with OpenWrt U-Boot layout | `zyxel_ex5601-t0-ubootmod` | `-squashfs-sysupgrade.itb` |
| GL.iNet GL-MT3000 / Beryl AX | `glinet_gl-mt3000` | `-squashfs-sysupgrade.bin` |

Each device is built as both `ap` and `router` on two LAN subnets: **eight artifacts per workflow run**. The four variants per device are listed in the installation table below.

Artifact names are `firmware-<profile>-<role>-<LAN-IP>-<YYYYMMDD>`. Successful runs also create a draft GitHub Release containing one ZIP per artifact, for example `firmware-glinet_gl-mt3000-ap-192.168.1.9-20261101.zip`.

Each ZIP contains the device's sysupgrade image, `build.log`, the run's `source-lock.json` and `feeds.conf.lock`, and available metadata: `sha256sums`, `profiles.json`, `config.buildinfo`, `version.buildinfo`, and `feeds.buildinfo`. The source lock records the exact upstream and feed commits shared by all variants. The checksum list can also reference upstream outputs omitted from these minimal archives.

## Installation

Download the ZIP for the correct device, role, and subnet from the draft release, then extract it. Flash the matching sysupgrade image from an existing compatible OpenWrt/ImmortalWrt installation. The Zyxel image requires the **ubootmod/OpenWrt U-Boot partition layout**; this is not a stock-firmware conversion guide. The GL-MT3000 uses the `.bin` image shown above.

Before flashing, verify the extracted image against its entry in `sha256sums`, when that file is included. On Linux, run this command from the extracted directory:

```sh
sha256sum --check --ignore-missing sha256sums
```

Confirm that the exact sysupgrade image you intend to flash is listed as `OK`. The command skips entries for files omitted from the archive; a successful check of another file alone does not verify your image. Stop if your image is missing from the results or has a checksum mismatch.

In PowerShell, replace `YOUR-SYSUPGRADE-IMAGE` with the extracted image's filename and run:

```powershell
Get-FileHash -Algorithm SHA256 -LiteralPath '.\YOUR-SYSUPGRADE-IMAGE'
```

Compare the returned hash with the entry for that exact filename in `sha256sums`; letter case does not matter.

**Defaults are reapplied after each flash, including upgrades that preserve settings.** Both firmware roles reset existing Wi-Fi AP interfaces to WPA2-PSK with the key `password123`, along with the role and radio settings documented below. Change the key after flashing, or customize the defaults before building.

Choose the AP variant matching the upstream LAN and reserve its `.9` address on that network. After boot, open the LAN / management address below using `http://`.

| Variant | LAN / management address | AP gateway and DNS | Router DHCPv4 range |
| --- | --- | --- | --- |
| `ap-10.0.0.9` | `10.0.0.9/24` | `10.0.0.1` | — |
| `ap-192.168.1.9` | `192.168.1.9/24` | `192.168.1.1` | — |
| `router-10.0.0.1` | `10.0.0.1/24` | — | `10.0.0.100`–`10.0.0.249` |
| `router-192.168.1.1` | `192.168.1.1/24` | — | `192.168.1.100`–`192.168.1.249` |

Configuration and source checks cannot replace a firmware build and an on-device test of networking, wireless, and SQM performance.

## AP and router defaults

The workflow selects [`uci-defaults/ap`](uci-defaults/ap) or [`uci-defaults/router`](uci-defaults/router), sets its `lan_prefix` for the selected subnet, and installs it as `/etc/uci-defaults/99-custom`. The firmware applies it during first boot, after upstream configuration creation and before normal network service startup. The scripts default to `10.0.0.0/24` when used directly outside the workflow; edit the single `lan_prefix` assignment to change that subnet.

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

Both scripts expect the generated LAN bridge and a separate physical WAN device. They validate topology, radio bands, and interface modes and require at least one radio and AP interface before staging UCI changes. Review custom VLAN/bridge layouts before flashing. Missing topology, missing Wi-Fi sections, or failed required UCI writes cause the script to fail; see [Troubleshooting defaults](#troubleshooting-defaults) for partial changes and retry behavior.

The Zyxel uses `wan` as its physical WAN device in OpenWrt/ImmortalWrt 25.12; the GL-MT3000 uses `eth0`. The Zyxel naming follows [OpenWrt's intentional `eth1` to `wan` change](https://github.com/openwrt/openwrt/commit/f26260c7e75112429901fff59ef0a0f5601c5675). The defaults verify that the selected WAN device exists. On a Zyxel with `wan` present and `eth1` absent, they migrate plain `eth1` references in WAN/WAN6, an optional device section, and LAN bridge membership, retaining the saved WAN protocol and credentials. Legacy `eth1.VLAN` references and conflicting `eth1`/`wan` device sections require manual review and stop the defaults before any UCI changes. Existing SQM interface selections are also preserved and must be checked separately after a device rename.

## Wireless and DFS

Both roles set the timezone to `Europe/Stockholm` and the Wi-Fi country to `SE`. The Wi-Fi security reset described under [Installation](#installation) applies to every existing interface whose mode is `ap`, including those in router images. The scripts preserve SSIDs and radio/interface enable flags; a disabled radio or interface stays disabled.

| Band | Channel | Width |
| --- | --- | --- |
| 2.4 GHz | Automatic | `HE40` |
| 5 GHz | Automatic | `HE80` |

Automatic selection is local to each radio; separate APs do not coordinate channel assignments or continuously rebalance them.

The patches enable 802.11h/DFS and MediaTek's dedicated zero-wait DFS flow for supported regulatory domains, including Sweden. The driver can serve clients on an available non-DFS channel while a dedicated detector performs the radar Channel Availability Check (CAC) for a DFS channel. After successful CAC it can switch to the cleared channel, with a possible brief interruption.

Radar detection still requires rejecting or leaving the affected channel. Zero-wait does not bypass CAC or guarantee a DFS channel will be selected; actual behavior depends on the device, driver, and regulatory conditions.

## SQM

SQM packages are included in **both AP and router images**. Keeping them in [`defconfig/mt798x_baseline.config`](defconfig/mt798x_baseline.config) avoids variant-specific package scripts and keeps normal package management intact.

The baseline selects `luci-app-sqm`, `sqm-scripts`, `tc-full`, `kmod-sched-cake`, `kmod-ifb`, and `kmod-sched-core`. The build system resolves the remaining dependencies. `tc-full` supplies the complete traffic-control utility.

On a clean installation SQM queues are disabled until configured. Installing the packages alone does not enable shaping. Preserved SQM settings can remain active across upgrades, so review them when changing a device's role.

To use SQM on the router:

1. Open **Network → SQM QoS** in LuCI.
2. Select the actual WAN network device, not the LAN bridge. With the default Ethernet WAN layout this is `wan` on the Zyxel and `eth0` on the GL-MT3000; PPPoE or VLAN configurations can use a different device. Review preserved SQM settings that still reference the Zyxel's former `eth1` name.
3. Set download/upload rates for the connection, choose `cake` and `piece_of_cake.qos`, and configure link-layer overhead for the WAN type.
4. Disable hardware NAT/flow acceleration, including MediaTek HNAT in TurboACC. Hardware acceleration bypasses SQM's CPU traffic shaping. Avoid running another QoS/shaper on the same interface at the same time.
5. Enable the queue, save/apply, and measure latency under load. SQM uses the CPU, so available throughput depends on the device and chosen settings.

Normally leave SQM disabled on a bridged AP and shape the internet connection on its upstream router. See the [OpenWrt SQM guide](https://openwrt.org/docs/guide-user/network/traffic-shaping/sqm) for rate selection, link-layer settings, and verification.

## Troubleshooting defaults

Missing topology or required Wi-Fi sections stop both scripts before UCI changes. Later write or commit failures can still leave defaults partially applied: network, DHCP, system, and wireless are separate UCI packages, and the scripts commit them in that order. A later failure can leave the LAN / management address changed to the selected variant's address. Reconnect using the installation table; if direct Ethernet access to an AP is needed without an upstream DHCP server, assign your computer an unused address in the same `/24` subnet.

After connecting over SSH or a local console, inspect the diagnostic messages, saved LAN address, active IPv4 addresses, and pending script:

```sh
logread -e 99-custom
uci -q get network.lan.ipaddr
uci -q get network.wan.device
ubus call network.device status '{"name":"br-lan"}'
ip -4 addr show
if [ -f /etc/uci-defaults/99-custom ]; then echo 'Custom defaults pending'; else echo 'No pending custom defaults'; fi
```

The scripts log topology and missing-Wi-Fi errors with the `99-custom` tag; individual failed UCI commands may also report errors outside that tag. OpenWrt retains a failed defaults script for retry on the next boot. Correct the reported topology or Wi-Fi configuration before rebooting; the retry reapplies the defaults, including the Wi-Fi security reset.

## Collecting live diagnostics

Use [`tools/openwrt-diagnostics.ps1`](tools/openwrt-diagnostics.ps1) from PowerShell 7 on Windows, Linux, or macOS with an OpenSSH client installed. Authenticate using an SSH key or agent by default, or use the password mode below. By default, verify the router's host key with an interactive SSH connection before collecting; the collector requires an already trusted host key. Use `root` to access the complete system and kernel logs.

For a first connection to `10.0.0.9`, run:

```powershell
ssh -o StrictHostKeyChecking=ask root@10.0.0.9
```

Verify that the displayed fingerprint belongs to your router before answering `yes`, then exit the SSH session. Use the same SSH client, target, port (`-p`), and identity file (`-i`) as the collector. This resolves the error `No ED25519 host key is known ... and you have requested strict checking`. A changed-host-key warning needs separate verification of the replacement key before updating the saved entry.

To collect without strict host-key checking, use:

```powershell
pwsh -File tools/openwrt-diagnostics.ps1 -Target root@10.0.0.9 -SkipHostKeyChecking
```

This explicitly sets `StrictHostKeyChecking=no` and directs `UserKnownHostsFile` to the platform null device (`NUL` on Windows, `/dev/null` on Linux/macOS), allowing collection without enrolling the router's key and without reading or updating your user host-key database. Using the null device avoids a host-verification failure reproduced with Windows OpenSSH 9.5 and `UserKnownHostsFile=none`. It skips verification of the router's identity against that database; login authentication is still required. The selected mode is recorded in the capture metadata and report. [OpenSSH option reference](https://man.openbsd.org/ssh_config#StrictHostKeyChecking).

If the router reports `Permission denied (publickey,password)` in the default mode, the connection reached login authentication but the available keys were rejected. Load an authorized key into your SSH agent, pass `-IdentityFile` with its private-key path, or use password mode:

```powershell
pwsh -File tools/openwrt-diagnostics.ps1 -Target root@10.0.0.9 -SkipHostKeyChecking -PasswordAuthentication
```

Run this directly in an interactive terminal and enter the router password at SSH's hidden prompt. Password mode selects password authentication instead of trying SSH keys. SSH reads the password directly from the terminal; the script does not receive it as an argument, environment variable, or captured input, and does not save it to diagnostic files. Password mode requires the server to allow password login and rejects redirected input or background jobs without a terminal. Time spent entering the password counts toward `-TimeoutSeconds`. Host-key checking remains enabled unless you also pass `-SkipHostKeyChecking`. The chosen authentication mode is recorded in the capture metadata and report.

From the repository root, collect and analyze a snapshot:

```powershell
pwsh -File tools/openwrt-diagnostics.ps1 -Target root@192.168.1.9
```

Use `-Port 2222` for a different SSH port, `-IdentityFile ~/.ssh/id_ed25519` for a specific key, or `-SshExecutable /path/to/ssh` for a specific client. OpenSSH host aliases and configuration are supported; the port defaults to 22, so pass `-Port` when an alias uses a different port. `-TimeoutSeconds 120` controls the overall SSH session timeout, while connection establishment has a 10-second timeout.

The tooling runs fixed read-only commands in one SSH session. It retrieves `logread`, `dmesg`, board and firmware details, uptime, IP addresses and routes, interface counters, memory and filesystem usage, traffic-shaping queue statistics, selected WAN/LAN device names and bridge port lists, and the presence of the custom defaults script. It does not explicitly query full UCI configuration or credential options. Raw logs and generated findings are unsanitized and may contain Wi-Fi keys, WAN credentials, private addresses, MAC addresses, hostnames, or other sensitive information logged by router software. Review and redact all files before sharing. Individual command failures and SSH failures are recorded, partial logs are retained, and the report identifies incomplete collection.

Each attempt saves troubleshooting details in a timestamped directory under `logs/openwrt/`: raw SSH output and stderr plus `collection.json`, including the selected SSH client, arguments, transport result, and collection status. If remote diagnostics never start or neither system nor kernel logs can be retrieved, the script prints the failure and SSH error, exits with code `2`, and generates no findings. Successful or useful partial captures also contain individual section logs and findings in `findings.md` and `findings.json`; partial captures are explicitly labeled. The entire `logs/` directory is Git-ignored, including all downloaded data, generated findings, archives, and test fixtures.

The analyzer groups known kernel, memory, storage, watchdog, custom-defaults, Wi-Fi/offload, DHCP, interface-state, PPP, radar, and DFS patterns, with source filenames and line numbers for up to five examples per group. Interface-down events are informational and identify the named interface; PPP failures remain separate warnings. Radar detection and routine CAC/channel transitions are separate informational groups; routine DFS function names and `ramoops` initialization are excluded. Pattern matches are investigation leads rather than confirmed root causes; unmatched logs and a successful snapshot do not establish that the router is healthy. Counts refer to matching lines, and the same event can appear in both system and kernel logs. The other snapshots provide context for manual analysis.

Reanalyze a saved capture without connecting to the router, replacing `CAPTURE` with its directory name:

```powershell
pwsh -File tools/openwrt-diagnostics.ps1 -AnalyzePath logs/openwrt/CAPTURE
```

Reanalysis requires a usable captured system or kernel log and updates only the findings in that capture directory. When the capture is unusable, existing findings are moved into `findings-archive/<timestamp>-<id>/` inside the capture and the archive path is printed. Raw evidence and collection metadata remain unchanged. Exit codes are `0` for a complete snapshot or reanalysis, `2` when collection failed or was incomplete, and `1` for an invocation or local processing error. Findings themselves do not change the exit code. Run the local tests without a router using `pwsh -File tools/test-openwrt-diagnostics.ps1`.

## Upstream source

- Source: [chasey-dev/immortalwrt-mt798x-rebase](https://github.com/chasey-dev/immortalwrt-mt798x-rebase).
- Branch: `25.12`.
- MediaTek Wi-Fi configuration: `mtwifi-cfg-ucode`.

Each workflow run resolves the current branch once and locks the upstream commit and all Git feed commits before starting the firmware matrix. All eight variants check out those same inputs, and CI verifies their revisions before applying local patches. Each release records the resolved upstream SHA; `source-lock.json`, `feeds.conf.lock`, `feeds.buildinfo`, and `version.buildinfo` retain source provenance. Following newer branch commits still happens at the start of the next run. These locks preserve source inputs; they do not promise identical binaries across different host environments.

## Local features

- Corrected MediaTek country/region mappings and dedicated zero-wait DFS configuration.
- MediaTek Wi-Fi/LuCI tools and diagnostics.
- Zyxel EX5601 WAN-device validation and migration of legacy plain `eth1` references to the upstream `wan` name.
- SQM support with LuCI and CAKE.

See [`defconfig/`](defconfig) for package, driver, and device-specific firmware selections, and [`patches/`](patches) for local source changes.

## Building

The [GitHub Actions workflow](.github/workflows/immortalwrt-matrix.yml) runs on pushes to `main` and tags matching `v*`. Before the firmware matrix it tests source locking with local Git fixtures, runs the defaults and diagnostic suites, and builds native UCI and ucode test tools from the versions in the locked upstream tree. Integration tests exercise real UCI section/list and commit behavior and execute the patched converter across bands, domains, widths, and country transitions. The workflow then merges the shared baseline with each device config, applies local patches, installs the selected first-boot script, and compiles each role/subnet variant. It checks script syntax and rejects a generated config that drops the device or required SQM packages. Failed firmware jobs preserve `build.log`, available configuration/build metadata, and source provenance in separate diagnostic artifacts.

Run the checks that need no router or native OpenWrt tools with `python3 -B tools/test-lock-build-sources.py`, `sh tools/test-uci-defaults.sh`, and `pwsh -File tools/test-openwrt-diagnostics.ps1`. The defaults tests cover both devices and subnets, saved WAN settings, AP/router transitions, Wi-Fi inventory checks, and write/commit failures. To run the integration checks on Linux with native tools, use `sh tools/test-uci-integration.sh /path/to/uci` and `sh tools/test-mtwifi-converter.sh /path/to/patched/openwrt /path/to/ucode`. The converter tests use the actual patched converter and schema with isolated schema-loading and DAT helper fixtures; they do not access live radios. Test fixtures remain under Git-ignored `logs/`.
