# Firmware files and checksums

[Documentation index](README.md)

## Images and archives

| Device | Profile | Sysupgrade image suffix |
| --- | --- | --- |
| Zyxel EX5601-T0 with OpenWrt U-Boot layout | `zyxel_ex5601-t0-ubootmod` | `-squashfs-sysupgrade.itb` |
| GL.iNet GL-MT3000 / Beryl AX | `glinet_gl-mt3000` | `-squashfs-sysupgrade.bin` |

Each device is built as both `ap` and `router` on two LAN subnets: **eight artifacts per workflow run**. The four variants per device are listed in the [installation table](../README.md#installation).

Artifact names are `firmware-<profile>-<role>-<LAN-IP>-<YYYYMMDD>`. Successful runs also create a draft GitHub Release containing one ZIP per artifact, for example `firmware-glinet_gl-mt3000-ap-192.168.1.9-20261101.zip`.

Each ZIP contains the device's sysupgrade image, `build.log`, the run's `source-lock.json` and `feeds.conf.lock`, and available metadata: `sha256sums`, `profiles.json`, `config.buildinfo`, `version.buildinfo`, and `feeds.buildinfo`. The source lock records the exact upstream and feed commits shared by all variants. The checksum list can also reference upstream outputs omitted from these minimal archives.

## Verify checksums

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

[Return to installation](../README.md#installation).
