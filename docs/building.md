# Building and validation

[Documentation index](README.md)

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

See [`defconfig/`](../defconfig) for package, driver, and device-specific firmware selections, and [`patches/`](../patches) for local source changes.

## Build workflow

The [GitHub Actions workflow](../.github/workflows/immortalwrt-matrix.yml) runs on pushes to `main` and tags matching `v*`. Before the firmware matrix it tests source locking with local Git fixtures, runs the defaults and diagnostic suites, and builds native UCI and ucode test tools from the versions in the locked upstream tree. Integration tests exercise real UCI section/list and commit behavior and execute the patched converter across bands, domains, widths, and country transitions. The workflow then merges the shared baseline with each device config, applies local patches, installs the selected first-boot script, and compiles each role/subnet variant. It checks script syntax and rejects a generated config that drops the device or required SQM packages. Failed firmware jobs preserve `build.log`, available configuration/build metadata, and source provenance in separate diagnostic artifacts.

## Local checks

Run these commands from the repository root; they need no router or native OpenWrt tools:

```sh
python3 -B tools/test-lock-build-sources.py
sh tools/test-uci-defaults.sh
pwsh -File tools/test-openwrt-diagnostics.ps1
```

The defaults tests cover both devices and subnets, saved WAN settings, AP/router transitions, Wi-Fi inventory checks, and write/commit failures.

## Native integration checks

On Linux with native UCI and ucode tools, run:

```sh
sh tools/test-uci-integration.sh /path/to/uci
sh tools/test-mtwifi-converter.sh /path/to/patched/openwrt /path/to/ucode
```

The converter tests use the actual patched converter and schema with isolated schema-loading and DAT helper fixtures; they do not access live radios. All test fixtures remain under Git-ignored `logs/`.
