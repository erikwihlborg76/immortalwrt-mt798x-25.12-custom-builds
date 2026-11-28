# Live diagnostics

[Documentation index](README.md)

Use [`tools/openwrt-diagnostics.ps1`](../tools/openwrt-diagnostics.ps1) from PowerShell 7 on Windows, Linux, or macOS with an OpenSSH client installed. Authenticate using an SSH key or agent by default, or use the password mode below. By default, verify the router's host key with an interactive SSH connection before collecting; the collector requires an already trusted host key. Use `root` to access the complete system and kernel logs.

## Trust the router host key

For a first connection to `10.0.0.9`, run:

```powershell
ssh -o StrictHostKeyChecking=ask root@10.0.0.9
```

Verify that the displayed fingerprint belongs to your router before answering `yes`, then exit the SSH session. Use the same SSH client, target, port (`-p`), and identity file (`-i`) as the collector. This resolves the error `No ED25519 host key is known ... and you have requested strict checking`. A changed-host-key warning needs separate verification of the replacement key before updating the saved entry.

## Skip host-key checking

To collect without strict host-key checking, use:

```powershell
pwsh -File tools/openwrt-diagnostics.ps1 -Target root@10.0.0.9 -SkipHostKeyChecking
```

This explicitly sets `StrictHostKeyChecking=no` and directs `UserKnownHostsFile` to the platform null device (`NUL` on Windows, `/dev/null` on Linux/macOS), allowing collection without enrolling the router's key and without reading or updating your user host-key database. Using the null device avoids a host-verification failure reproduced with Windows OpenSSH 9.5 and `UserKnownHostsFile=none`. It skips verification of the router's identity against that database; login authentication is still required. The selected mode is recorded in the capture metadata and report. [OpenSSH option reference](https://man.openbsd.org/ssh_config#StrictHostKeyChecking).

## Password authentication

If the router reports `Permission denied (publickey,password)` in the default mode, the connection reached login authentication but the available keys were rejected. Load an authorized key into your SSH agent, pass `-IdentityFile` with its private-key path, or use password mode:

```powershell
pwsh -File tools/openwrt-diagnostics.ps1 -Target root@10.0.0.9 -SkipHostKeyChecking -PasswordAuthentication
```

Run this directly in an interactive terminal and enter the router password at SSH's hidden prompt. Password mode selects password authentication instead of trying SSH keys. SSH reads the password directly from the terminal; the script does not receive it as an argument, environment variable, or captured input, and does not save it to diagnostic files. Password mode requires the server to allow password login and rejects redirected input or background jobs without a terminal. Time spent entering the password counts toward `-TimeoutSeconds`. Host-key checking remains enabled unless you also pass `-SkipHostKeyChecking`. The chosen authentication mode is recorded in the capture metadata and report.

## Collect a snapshot

From the repository root, collect and analyze a snapshot:

```powershell
pwsh -File tools/openwrt-diagnostics.ps1 -Target root@192.168.1.9
```

Use `-Port 2222` for a different SSH port, `-IdentityFile ~/.ssh/id_ed25519` for a specific key, or `-SshExecutable /path/to/ssh` for a specific client. OpenSSH host aliases and configuration are supported; the port defaults to 22, so pass `-Port` when an alias uses a different port. `-TimeoutSeconds 120` controls the overall SSH session timeout, while connection establishment has a 10-second timeout.

## Saved data and privacy

The tooling runs fixed read-only commands in one SSH session. It retrieves `logread`, `dmesg`, board and firmware details, uptime, IP addresses and routes, interface counters, memory and filesystem usage, traffic-shaping queue statistics, selected WAN/LAN device names and bridge port lists, and the presence of the custom defaults script. It does not explicitly query full UCI configuration or credential options. Raw logs and generated findings are unsanitized and may contain Wi-Fi keys, WAN credentials, private addresses, MAC addresses, hostnames, or other sensitive information logged by router software. Review and redact all files before sharing. Individual command failures and SSH failures are recorded, partial logs are retained, and the report identifies incomplete collection.

Each attempt saves troubleshooting details in a timestamped directory under `logs/openwrt/`: raw SSH output and stderr plus `collection.json`, including the selected SSH client, arguments, transport result, and collection status. If remote diagnostics never start or neither system nor kernel logs can be retrieved, the script prints the failure and SSH error, exits with code `2`, and generates no findings. Successful or useful partial captures also contain individual section logs and findings in `findings.md` and `findings.json`; partial captures are explicitly labeled. The entire `logs/` directory is Git-ignored, including all downloaded data, generated findings, archives, and test fixtures.

The analyzer groups known kernel, memory, storage, watchdog, custom-defaults, Wi-Fi/offload, DHCP, interface-state, PPP, radar, and DFS patterns, with source filenames and line numbers for up to five examples per group. Interface-down events are informational and identify the named interface; PPP failures remain separate warnings. Radar detection and routine CAC/channel transitions are separate informational groups; routine DFS function names and `ramoops` initialization are excluded. Pattern matches are investigation leads rather than confirmed root causes; unmatched logs and a successful snapshot do not establish that the router is healthy. Counts refer to matching lines, and the same event can appear in both system and kernel logs. The other snapshots provide context for manual analysis.

## Reanalyze a saved capture

Reanalyze a saved capture without connecting to the router, replacing `CAPTURE` with its directory name:

```powershell
pwsh -File tools/openwrt-diagnostics.ps1 -AnalyzePath logs/openwrt/CAPTURE
```

Reanalysis requires a usable captured system or kernel log and updates only the findings in that capture directory. When the capture is unusable, existing findings are moved into `findings-archive/<timestamp>-<id>/` inside the capture and the archive path is printed. Raw evidence and collection metadata remain unchanged. Exit codes are `0` for a complete snapshot or reanalysis, `2` when collection failed or was incomplete, and `1` for an invocation or local processing error. Findings themselves do not change the exit code. Run the local tests without a router using `pwsh -File tools/test-openwrt-diagnostics.ps1`.
