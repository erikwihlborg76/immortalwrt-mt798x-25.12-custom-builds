#Requires -Version 7.0
[CmdletBinding(DefaultParameterSetName = 'Collect')]
param(
    [Parameter(Position = 0, ParameterSetName = 'Collect')]
    [ValidatePattern('^[A-Za-z0-9_][A-Za-z0-9_.:@%\[\]-]*$')]
    [string] $Target,

    [Parameter(ParameterSetName = 'Collect')]
    [ValidateRange(1, 65535)]
    [int] $Port = 22,

    [Parameter(ParameterSetName = 'Collect')]
    [string] $IdentityFile,

    [Parameter(ParameterSetName = 'Collect')]
    [switch] $SkipHostKeyChecking,

    [Parameter(ParameterSetName = 'Collect')]
    [switch] $PasswordAuthentication,

    [Parameter(ParameterSetName = 'Collect')]
    [string] $SshExecutable = 'ssh',

    [Parameter(ParameterSetName = 'Collect')]
    [ValidateRange(5, 3600)]
    [int] $TimeoutSeconds = 120,

    [Parameter(Mandatory, ParameterSetName = 'Analyze')]
    [string] $AnalyzePath
)

$ErrorActionPreference = 'Stop'

function Get-DiagnosticCommands {
    # Fixed read-only commands. Never interpolate connection arguments here.
    [ordered]@{
        logread = 'logread'
        dmesg = 'dmesg'
        board = 'ubus call system board'
        system = 'ubus call system info'
        release = 'cat /etc/openwrt_release'
        uptime = 'uptime'
        addresses = 'ip addr show'
        links = 'ip -s link show'
        routes4 = 'ip route show'
        routes6 = 'ip -6 route show'
        memory = 'free'
        storage = 'df -h'
        qdisc = 'tc -s qdisc show'
        defaults = "if [ -f /etc/uci-defaults/99-custom ]; then printf 'pending\n'; else printf 'complete-or-absent\n'; fi"
    }
}

function New-RemoteScript([string] $Token) {
    $script = @'
run_section() {
    name="$1"
    shift
    printf '\n@TOKEN@ BEGIN %s\n' "$name"
    "$@" 2>&1
    result=$?
    printf '\n@TOKEN@ END %s %s\n' "$name" "$result"
}
'@.Replace('@TOKEN@', $Token)
    foreach ($entry in (Get-DiagnosticCommands).GetEnumerator()) {
        $quoted = "'" + $entry.Value.Replace("'", "'\''") + "'"
        $script += "`nrun_section $($entry.Key) sh -c $quoted"
    }
    # Section failures are reported individually without stopping later commands.
    return ($script + "`nexit 0`n").Replace("`r`n", "`n")
}

function New-SshStartInfo {
    param([string] $Executable, [string] $Destination, [int] $SshPort, [string] $KeyFile, [switch] $SkipHostKeyChecking, [switch] $PasswordAuthentication)
    $info = [System.Diagnostics.ProcessStartInfo]::new()
    $info.FileName = (Get-Command $Executable -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
    $info.UseShellExecute = $false
    $info.RedirectStandardInput = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    # SSH reads passwords directly from the attached terminal, separately from
    # stdin carrying the remote script. Windows must inherit the console.
    $info.CreateNoWindow = -not $PasswordAuthentication
    foreach ($argument in @('-T', '-p', "$SshPort", '-o', 'ConnectTimeout=10', '-o', 'ServerAliveInterval=5', '-o', 'ServerAliveCountMax=2')) {
        $info.ArgumentList.Add($argument)
    }
    $info.ArgumentList.Add('-o')
    $info.ArgumentList.Add($(if ($PasswordAuthentication) { 'BatchMode=no' } else { 'BatchMode=yes' }))
    if ($PasswordAuthentication) {
        foreach ($argument in @('-o', 'PreferredAuthentications=password', '-o', 'PasswordAuthentication=yes', '-o', 'PubkeyAuthentication=no')) {
            $info.ArgumentList.Add($argument)
        }
        $info.Environment['SSH_ASKPASS_REQUIRE'] = 'never'
    }
    $info.ArgumentList.Add('-o')
    $info.ArgumentList.Add($(if ($SkipHostKeyChecking) { 'StrictHostKeyChecking=no' } else { 'StrictHostKeyChecking=yes' }))
    if ($SkipHostKeyChecking) {
        # Windows OpenSSH 9.5 can reject an unknown host with a file list of
        # 'none', despite StrictHostKeyChecking=no. A null device works there.
        $nullDevice = if ($IsWindows) { 'NUL' } else { '/dev/null' }
        $info.ArgumentList.Add('-o')
        $info.ArgumentList.Add("UserKnownHostsFile=$nullDevice")
    }
    if ($KeyFile) {
        $info.ArgumentList.Add('-i')
        $info.ArgumentList.Add((Resolve-Path -LiteralPath $KeyFile).Path)
    }
    $info.ArgumentList.Add('--')
    $info.ArgumentList.Add($Destination)
    $info.ArgumentList.Add('sh -s')
    return $info
}

function Invoke-SshCapture {
    param([System.Diagnostics.ProcessStartInfo] $StartInfo, [string] $RemoteScript, [string] $SessionPath, [int] $Timeout)
    $result = [ordered]@{ exit_code = $null; timed_out = $false; error = $null }
    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $StartInfo
    $stdout = [System.IO.File]::Create((Join-Path $SessionPath 'ssh-output.log'))
    $stderr = [System.IO.File]::Create((Join-Path $SessionPath 'ssh-stderr.log'))
    $started = $false
    $copyOut = $null
    $copyErr = $null
    try {
        $started = $process.Start()
        $copyOut = $process.StandardOutput.BaseStream.CopyToAsync($stdout)
        $copyErr = $process.StandardError.BaseStream.CopyToAsync($stderr)
        $process.StandardInput.Write($RemoteScript)
        $process.StandardInput.Close()
        if (-not $process.WaitForExit($Timeout * 1000)) {
            $result.timed_out = $true
            $process.Kill($true)
            $process.WaitForExit()
        }
        $result.exit_code = $process.ExitCode
    } catch {
        $result.error = $_.Exception.Message
    } finally {
        if ($started -and -not $process.HasExited) {
            $process.Kill($true)
            $process.WaitForExit()
        }
        try {
            if ($copyOut) { $null = $copyOut.GetAwaiter().GetResult() }
            if ($copyErr) { $null = $copyErr.GetAwaiter().GetResult() }
        } finally {
            $stdout.Dispose()
            $stderr.Dispose()
            $process.Dispose()
        }
    }
    return $result
}

function Read-DiagnosticCapture([string] $SessionPath, [string] $Token) {
    $sections = [ordered]@{}
    foreach ($name in (Get-DiagnosticCommands).Keys) {
        $sections[$name] = [pscustomobject]@{ name = $name; status = 'not-captured'; exit_code = $null }
    }
    $prefix = [regex]::Escape($Token)
    $active = $null
    $writer = $null
    try {
        foreach ($line in [System.IO.File]::ReadLines((Join-Path $SessionPath 'ssh-output.log'))) {
            if ($line -match "^$prefix BEGIN ([a-z0-9]+)$" -and $sections.Contains($Matches[1])) {
                if ($writer) { $writer.Dispose() }
                $active = $Matches[1]
                $sections[$active].status = 'incomplete'
                $writer = [System.IO.StreamWriter]::new((Join-Path $SessionPath "$active.log"), $false, [System.Text.UTF8Encoding]::new($false))
            } elseif ($line -match "^$prefix END ([a-z0-9]+) ([0-9]+)$" -and $active -eq $Matches[1]) {
                $sections[$active].exit_code = [int] $Matches[2]
                $sections[$active].status = if ($Matches[2] -eq '0') { 'captured' } else { 'command-failed' }
                $writer.Dispose()
                $writer = $null
                $active = $null
            } elseif ($writer) {
                $writer.WriteLine($line)
            }
        }
    } finally {
        if ($writer) { $writer.Dispose() }
    }
    return @($sections.Values)
}

function Get-DiagnosticFindings([string] $SessionPath) {
    $rules = @(
        @{ id = 'kernel-fault'; severity = 'error'; title = 'Kernel fault reported'; pattern = 'Kernel panic|Oops:|BUG: (?:unable to handle|kernel)|Unable to handle kernel'; advice = 'Inspect the complete kernel log and record the firmware revision and activity preceding the fault.' },
        @{ id = 'out-of-memory'; severity = 'error'; title = 'Out-of-memory event reported'; pattern = 'Out of memory:|oom-kill:|invoked oom-killer|Killed process \d+'; advice = 'Review memory usage and the processes named in the full logs; a current memory snapshot may have recovered after the event.' },
        @{ id = 'storage-error'; severity = 'error'; title = 'Storage error reported'; pattern = '\bI/O error\b|UBIFS error|EXT4-fs error|JFFS2.*(?:error|corrupt)'; advice = 'Inspect the surrounding filesystem and flash messages before changing packages or configuration.' },
        @{ id = 'watchdog'; severity = 'warning'; title = 'Watchdog or stalled task reported'; pattern = 'NETDEV WATCHDOG|soft lockup|hard LOCKUP|blocked for more than|rcu[^\r\n]*stall'; advice = 'Correlate the event with load, driver messages, and the surrounding kernel trace.' },
        @{ id = 'custom-defaults'; severity = 'error'; title = 'Custom defaults failure reported'; pattern = '99-custom.*(?:Expected a LAN bridge|No Wi-Fi radio found|No Wi-Fi AP interface found)'; advice = 'Review the generated LAN bridge, WAN device, and Wi-Fi sections. Network settings may already have been committed before a Wi-Fi failure.' },
        @{ id = 'wifi-driver'; severity = 'warning'; title = 'Wi-Fi driver failure or timeout reported'; pattern = '(?:mt_wifi|mtwifi|mt76|mt798[16]|firmware)[^\r\n]*(?:timed out|timeout|assert|crash|failed)'; advice = 'Inspect surrounding driver messages and correlate with client interruptions; these patterns alone do not establish a cause.' },
        @{ id = 'dhcp'; severity = 'warning'; title = 'DHCP lease acquisition or pool problem reported'; pattern = 'udhcpc.*(?:no lease|lease failed)|dnsmasq.*no address range available'; advice = 'Check the affected interface, upstream DHCP availability, and configured address ranges.' },
        @{ id = 'wan'; severity = 'warning'; title = 'WAN or PPP connection event reported'; pattern = 'netifd.*Interface .+ is now down|pppd.*(?:authentication failed|Connection terminated|timeout)'; advice = 'Check whether this was an expected startup/reconnect event and correlate with upstream connectivity.' },
        @{ id = 'dfs'; severity = 'info'; title = 'DFS radar or channel-availability activity reported'; pattern = 'radar detected|radar detection triggered|CAC.*(?:started|completed|finished)|DFS.*(?:switch|radar)'; advice = 'DFS activity can be normal. Correlate timestamps with channel changes and interruptions; this finding is not a driver-failure diagnosis.' }
    )
    $groups = [ordered]@{}
    foreach ($name in @('logread', 'dmesg')) {
        $path = Join-Path $SessionPath "$name.log"
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { continue }
        $lineNumber = 0
        foreach ($line in [System.IO.File]::ReadLines($path)) {
            $lineNumber++
            foreach ($rule in $rules) {
                if ($line -notmatch $rule.pattern) { continue }
                if (-not $groups.Contains($rule.id)) {
                    $groups[$rule.id] = [pscustomobject]@{
                        id = $rule.id; severity = $rule.severity; title = $rule.title
                        advice = $rule.advice; matched_lines = 0
                        evidence = [System.Collections.Generic.List[object]]::new()
                    }
                }
                $finding = $groups[$rule.id]
                $finding.matched_lines++
                if ($finding.evidence.Count -lt 5) {
                    $finding.evidence.Add([pscustomobject]@{ file = "$name.log"; line = $lineNumber; text = $line })
                }
            }
        }
    }
    $defaultsPath = Join-Path $SessionPath 'defaults.log'
    if ((Test-Path -LiteralPath $defaultsPath) -and [System.IO.File]::ReadAllText($defaultsPath).Trim() -eq 'pending') {
        $groups['pending-defaults'] = [pscustomobject]@{
            id = 'pending-defaults'; severity = 'warning'; title = 'Custom defaults script is still present'
            advice = 'The script may have failed or may not have run yet. Inspect 99-custom messages. A retry on the next boot reapplies defaults.'
            matched_lines = 1; evidence = @([pscustomobject]@{ file = 'defaults.log'; line = 1; text = 'pending' })
        }
    }
    return @($groups.Values)
}

function Get-SshSetupHint([string] $SessionPath, [string] $HostKeyChecking, [string] $AuthenticationMode) {
    $stderrPath = Join-Path $SessionPath 'ssh-stderr.log'
    if (-not (Test-Path -LiteralPath $stderrPath -PathType Leaf)) { return }
    $stderr = [System.IO.File]::ReadAllText($stderrPath)
    if ($stderr -match 'Permission denied \([^\r\n)]*(?:publickey|password|keyboard-interactive)') {
        if ($AuthenticationMode -eq 'password') {
            return 'SSH password authentication failed or is unavailable for this account. Check the password and the router''s password-login settings, then retry -PasswordAuthentication from an interactive terminal.'
        }
        return 'SSH login authentication failed. Load a key authorized for the target account into your SSH agent, or pass -IdentityFile with its private-key path. Default batch collection does not prompt for passwords; use -PasswordAuthentication from an interactive terminal for a hidden SSH password prompt.'
    }
    if ($HostKeyChecking -eq 'disabled' -and $stderr -match 'host key|host identification') {
        return 'The destination was configured with host-key checking disabled. Inspect the selected SSH client and arguments in collection.json and any ProxyJump or ProxyCommand settings; a proxy connection can have separate host-key settings.'
    }
    if ($stderr -match 'REMOTE HOST IDENTIFICATION HAS CHANGED|Host key for [^\r\n]+ has changed') {
        return 'SSH reports a changed host key. Verify the new fingerprint independently before updating the saved key for this router. Collection will continue to reject the changed key until trust is resolved.'
    }
    if ($stderr -match 'No [^\r\n]+ host key is known|Host key verification failed') {
        return 'SSH could not verify the router host key. Connect interactively using StrictHostKeyChecking=ask with the same SSH client, target, port, and identity settings. Verify the displayed fingerprint belongs to your router before accepting it, exit the session, then rerun collection.'
    }
}

function Get-DiagnosticCaptureState([string] $SessionPath, $Metadata) {
    # Older captures accidentally serialized async completion values alongside transport.
    if ($Metadata.transport -is [array]) {
        $Metadata.transport = @($Metadata.transport | Where-Object { $null -ne $_.timed_out } | Select-Object -Last 1)[0]
    }
    if (@($Metadata.sections | Where-Object status -ne 'not-captured').Count -eq 0) { return 'not-started' }
    $usableLogs = @($Metadata.sections | Where-Object {
        if ($_.name -notin @('logread', 'dmesg')) { return $false }
        $path = Join-Path $SessionPath "$($_.name).log"
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $false }
        return $_.status -eq 'captured' -or ($_.status -eq 'incomplete' -and -not [string]::IsNullOrWhiteSpace([System.IO.File]::ReadAllText($path)))
    })
    if (-not $usableLogs.Count) { return 'no-logs' }
    if ($null -eq $Metadata.transport -or $Metadata.transport.exit_code -ne 0 -or $Metadata.transport.timed_out -or $Metadata.transport.error -or @($Metadata.sections | Where-Object status -ne 'captured').Count) { return 'partial' }
    return 'complete'
}

function Write-DiagnosticReport([string] $SessionPath, $Metadata) {
    $state = Get-DiagnosticCaptureState $SessionPath $Metadata
    if ($state -in @('not-started', 'no-logs')) { throw 'No diagnostic logs are available to analyze.' }
    $findings = @(Get-DiagnosticFindings $SessionPath)
    $report = [ordered]@{
        schema_version = 1
        analyzed_at_utc = [DateTime]::UtcNow.ToString('o')
        collection = $Metadata
        findings = $findings
    }
    $report | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath (Join-Path $SessionPath 'findings.json') -Encoding utf8
    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add('# OpenWrt diagnostic findings')
    $lines.Add('')
    $lines.Add('Pattern-based triage of a read-only snapshot. Findings are leads, not confirmed root causes. No matching patterns does not establish that the router is healthy. Log buffers may omit earlier events; logread and dmesg may contain the same event, so matched-line counts are not unique incident counts.')
    $lines.Add('')
    $lines.Add("SSH exit code: $($Metadata.transport.exit_code); timed out: $($Metadata.transport.timed_out).")
    if ($Metadata.host_key_checking) { $lines.Add("Host key checking: $($Metadata.host_key_checking).") }
    if ($Metadata.authentication) { $lines.Add("Authentication mode: $($Metadata.authentication).") }
    if ($Metadata.transport.error) { $lines.Add("Collection error: $($Metadata.transport.error)") }
    $setupHint = Get-SshSetupHint $SessionPath $Metadata.host_key_checking $Metadata.authentication
    if ($setupHint) {
        $lines.Add('')
        $lines.Add($setupHint)
    }
    $lines.Add('')
    $lines.Add('| Section | Status | Exit code |')
    $lines.Add('| --- | --- | --- |')
    foreach ($section in $Metadata.sections) {
        $lines.Add("| $($section.name) | $($section.status) | $($section.exit_code) |")
    }
    if ($state -eq 'partial') {
        $lines.Add('')
        $lines.Add('**Collection is incomplete.** Check ssh-stderr.log and failed section logs. Missing commands or permissions can limit analysis; retained partial logs are still analyzed.')
    }
    $lines.Add('')
    if ($findings.Count -eq 0) { $lines.Add('No configured log patterns matched the captured data.') }
    foreach ($finding in $findings) {
        $lines.Add("## $($finding.title)")
        $lines.Add('')
        $lines.Add("Severity: $($finding.severity). Matched lines: $($finding.matched_lines). Showing up to five examples.")
        $lines.Add('')
        $lines.Add($finding.advice)
        $lines.Add('')
        $samples = @($finding.evidence | ForEach-Object { "$($_.file):$($_.line): $($_.text)" }) -join "`n"
        $fenceLength = 3
        foreach ($match in [regex]::Matches($samples, '`+')) { $fenceLength = [Math]::Max($fenceLength, $match.Length + 1) }
        $fence = ([string] [char] 96) * $fenceLength
        $lines.Add($fence + 'text')
        $lines.Add($samples)
        $lines.Add($fence)
        $lines.Add('')
    }
    $lines | Set-Content -LiteralPath (Join-Path $SessionPath 'findings.md') -Encoding utf8
    return $findings.Count
}

function Complete-DiagnosticCapture([string] $SessionPath, $Metadata) {
    $state = Get-DiagnosticCaptureState $SessionPath $Metadata
    if ($state -in @('not-started', 'no-logs')) {
        $message = if ($state -eq 'not-started') { 'Collection failed: remote diagnostics never started.' } else { 'Collection failed: no usable system or kernel logs were retrieved.' }
        [Console]::Error.WriteLine("$message No findings were generated.")
        if ($null -ne $Metadata.transport.exit_code) { [Console]::Error.WriteLine("SSH exit code: $($Metadata.transport.exit_code)") }
        if ($Metadata.transport.timed_out) { [Console]::Error.WriteLine('SSH session timed out.') }
        if ($Metadata.transport.error) { [Console]::Error.WriteLine($Metadata.transport.error) }
        $stderrPath = Join-Path $SessionPath 'ssh-stderr.log'
        if (Test-Path -LiteralPath $stderrPath -PathType Leaf) {
            foreach ($line in (Get-Content -LiteralPath $stderrPath -Tail 20)) { [Console]::Error.WriteLine($line) }
        }
        $hint = Get-SshSetupHint $SessionPath $Metadata.host_key_checking $Metadata.authentication
        if ($hint) { [Console]::Error.WriteLine($hint) }
        [Console]::Error.WriteLine("Failure details: $SessionPath")
        return 2
    }
    $count = Write-DiagnosticReport $SessionPath $Metadata
    Write-Host "$(if ($state -eq 'partial') { 'Partial capture' } else { 'Capture' }): $SessionPath"
    Write-Host "Findings: $(Join-Path $SessionPath 'findings.md') ($count groups)"
    if ($state -eq 'partial') {
        [Console]::Error.WriteLine('Collection is incomplete; the findings cover only the retrieved logs. See collection.json and ssh-stderr.log.')
        return 2
    }
    return 0
}

if ($MyInvocation.InvocationName -ne '.') {
    try {
        $logRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../logs/openwrt'))
        if ($PSCmdlet.ParameterSetName -eq 'Analyze') {
            $session = (Resolve-Path -LiteralPath $AnalyzePath).Path
            $comparison = if ($IsWindows) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }
            if (-not $session.StartsWith($logRoot + [System.IO.Path]::DirectorySeparatorChar, $comparison)) {
                throw 'AnalyzePath must be a capture directory under this repository''s logs/openwrt/ directory.'
            }
            $metadata = Get-Content -LiteralPath (Join-Path $session 'collection.json') -Raw | ConvertFrom-Json
            if ($metadata.schema_version -ne 1) { throw 'Unsupported collection schema version.' }
        } else {
            if (-not $Target) { throw 'Specify -Target root@ADDRESS to collect, or -AnalyzePath logs/openwrt/CAPTURE to reanalyze.' }
            if ($PasswordAuthentication -and [Console]::IsInputRedirected) {
                throw '-PasswordAuthentication requires an interactive terminal. Run pwsh -File tools/openwrt-diagnostics.ps1 directly in your terminal without piping input.'
            }
            $info = New-SshStartInfo -Executable $SshExecutable -Destination $Target -SshPort $Port -KeyFile $IdentityFile -SkipHostKeyChecking:$SkipHostKeyChecking -PasswordAuthentication:$PasswordAuthentication
            $safeTarget = ($Target -replace '[^A-Za-z0-9_.-]', '_')
            if ($safeTarget.Length -gt 64) { $safeTarget = $safeTarget.Substring(0, 64) }
            $sessionName = [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffZ') + '-' + $safeTarget + '-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
            $session = Join-Path $logRoot $sessionName
            [System.IO.Directory]::CreateDirectory($session) | Out-Null
            $token = '__OPENWRT_DIAG_' + [guid]::NewGuid().ToString('N') + '__'
            if ($PasswordAuthentication) { Write-Host 'Enter the router password at the SSH prompt. Input is hidden.' }
            $metadata = [ordered]@{
                schema_version = 1; started_at_utc = [DateTime]::UtcNow.ToString('o')
                target = $Target; port = $Port
                host_key_checking = if ($SkipHostKeyChecking) { 'disabled' } else { 'strict' }
                authentication = if ($PasswordAuthentication) { 'password' } else { 'key-or-agent' }
                ssh_client = $info.FileName; ssh_arguments = @($info.ArgumentList)
                transport = Invoke-SshCapture -StartInfo $info -RemoteScript (New-RemoteScript $token) -SessionPath $session -Timeout $TimeoutSeconds
                sections = @(Read-DiagnosticCapture -SessionPath $session -Token $token)
                finished_at_utc = [DateTime]::UtcNow.ToString('o')
            }
            $metadata['status'] = Get-DiagnosticCaptureState $session $metadata
            $metadata | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $session 'collection.json') -Encoding utf8
        }
        exit (Complete-DiagnosticCapture -SessionPath $session -Metadata $metadata)
    } catch {
        [Console]::Error.WriteLine($_.Exception.Message)
        exit 1
    }
}
