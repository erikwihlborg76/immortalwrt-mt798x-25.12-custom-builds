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
    param([string] $Executable, [string] $Destination, [int] $SshPort, [string] $KeyFile)
    $info = [System.Diagnostics.ProcessStartInfo]::new()
    $info.FileName = (Get-Command $Executable -CommandType Application -ErrorAction Stop).Source
    $info.UseShellExecute = $false
    $info.RedirectStandardInput = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $info.CreateNoWindow = $true
    foreach ($argument in @('-T', '-p', "$SshPort", '-o', 'BatchMode=yes', '-o', 'StrictHostKeyChecking=yes', '-o', 'ConnectTimeout=10', '-o', 'ServerAliveInterval=5', '-o', 'ServerAliveCountMax=2')) {
        $info.ArgumentList.Add($argument)
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
            if ($copyOut) { $copyOut.GetAwaiter().GetResult() }
            if ($copyErr) { $copyErr.GetAwaiter().GetResult() }
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

function Write-DiagnosticReport([string] $SessionPath, $Metadata) {
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
    if ($Metadata.transport.error) { $lines.Add("Collection error: $($Metadata.transport.error)") }
    $lines.Add('')
    $lines.Add('| Section | Status | Exit code |')
    $lines.Add('| --- | --- | --- |')
    foreach ($section in $Metadata.sections) {
        $lines.Add("| $($section.name) | $($section.status) | $($section.exit_code) |")
    }
    if ($Metadata.transport.exit_code -ne 0 -or $Metadata.transport.timed_out -or $Metadata.transport.error -or @($Metadata.sections | Where-Object status -ne 'captured').Count) {
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
            $info = New-SshStartInfo -Executable $SshExecutable -Destination $Target -SshPort $Port -KeyFile $IdentityFile
            $safeTarget = ($Target -replace '[^A-Za-z0-9_.-]', '_')
            if ($safeTarget.Length -gt 64) { $safeTarget = $safeTarget.Substring(0, 64) }
            $sessionName = [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffZ') + '-' + $safeTarget + '-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
            $session = Join-Path $logRoot $sessionName
            [System.IO.Directory]::CreateDirectory($session) | Out-Null
            $token = '__OPENWRT_DIAG_' + [guid]::NewGuid().ToString('N') + '__'
            $metadata = [ordered]@{
                schema_version = 1; started_at_utc = [DateTime]::UtcNow.ToString('o')
                target = $Target; port = $Port
                transport = Invoke-SshCapture -StartInfo $info -RemoteScript (New-RemoteScript $token) -SessionPath $session -Timeout $TimeoutSeconds
                sections = @(Read-DiagnosticCapture -SessionPath $session -Token $token)
                finished_at_utc = [DateTime]::UtcNow.ToString('o')
            }
            $metadata | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $session 'collection.json') -Encoding utf8
        }
        $count = Write-DiagnosticReport -SessionPath $session -Metadata $metadata
        Write-Host "Capture: $session"
        Write-Host "Findings: $(Join-Path $session 'findings.md') ($count groups)"
        if ($metadata.transport.exit_code -ne 0 -or $metadata.transport.timed_out -or $metadata.transport.error -or @($metadata.sections | Where-Object status -ne 'captured').Count) { exit 2 }
    } catch {
        [Console]::Error.WriteLine($_.Exception.Message)
        exit 1
    }
}
