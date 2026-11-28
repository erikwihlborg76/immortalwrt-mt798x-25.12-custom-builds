#Requires -Version 7.0
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'openwrt-diagnostics.ps1')

function Assert-True($Condition, [string] $Message) {
    if (-not $Condition) { throw $Message }
}

# Fixtures and reports use the same ignored root as real captures.
$testRoot = Join-Path $PSScriptRoot ('../logs/openwrt/test-' + [guid]::NewGuid().ToString('N'))
[System.IO.Directory]::CreateDirectory($testRoot) | Out-Null
$token = '__OPENWRT_DIAG_test__'
$transcript = [System.Collections.Generic.List[string]]::new()
foreach ($name in (Get-DiagnosticCommands).Keys) {
    $transcript.Add("$token BEGIN $name")
    switch ($name) {
        logread {
            $transcript.Add('daemon.err 99-custom: No Wi-Fi AP interface found; retry defaults on the next boot')
            $transcript.Add('kern.err kernel: Out of memory: Killed process 456 (example)')
            $transcript.Add('daemon.info mtwifi: CAC completed successfully')
            $transcript.Add('daemon.info netifd: Interface wan is now up')
        }
        dmesg { $transcript.Add('[123] Out of memory: Killed process 456 (example)') }
        defaults { $transcript.Add('pending') }
        qdisc { $transcript.Add('sh: tc: not found') }
        default { $transcript.Add('snapshot') }
    }
    $status = if ($name -eq 'qdisc') { 127 } else { 0 }
    $transcript.Add("$token END $name $status")
}

$transcript | Set-Content -LiteralPath (Join-Path $testRoot 'ssh-output.log') -Encoding utf8
$sections = @(Read-DiagnosticCapture $testRoot $token)
Assert-True ($sections.Count -eq (Get-DiagnosticCommands).Count) 'Missing collection sections.'
Assert-True (($sections | Where-Object name -eq 'qdisc').status -eq 'command-failed') 'Missing commands must be reported as failed.'
Assert-True (($sections | Where-Object name -eq 'defaults').status -eq 'captured') 'A missing optional command stopped later collection.'
$findings = @(Get-DiagnosticFindings $testRoot)
Assert-True ($findings.Count -eq 4) 'Unexpected analysis groups.'
$oom = $findings | Where-Object id -eq 'out-of-memory'
Assert-True ($oom.matched_lines -eq 2) 'Both log sources should be analyzed.'
Assert-True ($oom.evidence[0].file -eq 'logread.log' -and $oom.evidence[0].line -eq 2) 'Evidence line references are incorrect.'
Assert-True (($findings | Where-Object id -eq 'dfs').severity -eq 'info') 'Normal DFS activity must not be treated as a failure.'
Assert-True (-not ($findings | Where-Object { $_.id -in @('interface-down', 'ppp') })) 'WAN coming up must not be treated as a down or PPP event.'

# Routine function names and crash-buffer setup must not become incident findings.
$ruleRoot = Join-Path $testRoot 'rule-regressions'
[System.IO.Directory]::CreateDirectory($ruleRoot) | Out-Null
@(
    'kernel: ramoops: using reserved crash-log memory',
    'kernel: WiFi@C23L3,DfsRadarChannelCheck() 3433: wdev is not 5G',
    'kernel: 7986@C23L3,Dot11HCntDownTimeoutAction() 832: cac not req 0'
) | Set-Content -LiteralPath (Join-Path $ruleRoot 'logread.log')
Assert-True (@(Get-DiagnosticFindings $ruleRoot).Count -eq 0) 'Routine ramoops/DFS messages were misclassified as incidents.'
@(
    'kernel: Oops: fatal exception',
    'kernel: Kernel panic - not syncing',
    'kernel: 7986@C23L1,operate_loader_phy() 375: phy_freq_adjust failed!',
    'kernel: warp_dev0 wed2: probe with driver warp_dev0 failed with error -1',
    'kernel: DfsOutBandCacCountUpdate() 7609: OutBand CAC complete and is available now.',
    'kernel: dfs_off_cac_end_update() 3751: Zero-wait CAC ch 64 is available, bandidx 1',
    'kernel: radar detected on channel 104',
    "daemon.notice netifd: Interface 'guest' is now down",
    'daemon.err pppd: authentication failed',
    "99-custom: WAN device 'eth1' is missing or is a bridge; review VLAN/device mapping before applying defaults",
    '99-custom: Wi-Fi radio 1 has no band; defaults were not applied',
    '99-custom: Wi-Fi interface 1 has no mode; defaults were not applied'
) | Set-Content -LiteralPath (Join-Path $ruleRoot 'logread.log')
$ruleFindings = @(Get-DiagnosticFindings $ruleRoot)
Assert-True (($ruleFindings | Where-Object id -eq 'kernel-fault').matched_lines -eq 2) 'Real Oops and panic messages must still be detected.'
Assert-True (($ruleFindings | Where-Object id -eq 'dfs').matched_lines -eq 2) 'Actual CAC completions and availability messages must be detected.'
Assert-True (($ruleFindings | Where-Object id -eq 'radar').matched_lines -eq 1) 'Radar detection must be separated from routine DFS processing.'
Assert-True (($ruleFindings | Where-Object id -eq 'wifi-driver').matched_lines -eq 1) 'MediaTek numeric driver prefixes must be recognized.'
Assert-True (($ruleFindings | Where-Object id -eq 'offload').matched_lines -eq 1) 'WED probe failures must be surfaced without declaring all acceleration broken.'
Assert-True (($ruleFindings | Where-Object id -eq 'custom-defaults').matched_lines -eq 3) 'WAN-device and Wi-Fi preflight errors must be detected.'
Assert-True (($ruleFindings | Where-Object id -eq 'interface-down').matched_lines -eq 1 -and ($ruleFindings | Where-Object id -eq 'interface-down').severity -eq 'info') 'A guest interface going down must be informational and must not be called a WAN failure.'
Assert-True (($ruleFindings | Where-Object id -eq 'ppp').matched_lines -eq 1 -and ($ruleFindings | Where-Object id -eq 'ppp').severity -eq 'warning') 'PPP authentication failures must remain warnings separate from interface state changes.'

$metadata = [ordered]@{ schema_version = 1; transport = @{ exit_code = 0; timed_out = $false; error = $null }; sections = $sections }
$metadata | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $testRoot 'collection.json')
$null = Write-DiagnosticReport $testRoot $metadata
$report = Get-Content -LiteralPath (Join-Path $testRoot 'findings.md') -Raw
Assert-True ($report.Contains('Collection is incomplete')) 'A failed section must be visible in the report.'
Assert-True ($report.Contains('unsanitized') -and $report.Contains('credentials')) 'Markdown findings must explain that raw logs and findings may contain credentials.'
$json = Get-Content -LiteralPath (Join-Path $testRoot 'findings.json') -Raw | ConvertFrom-Json
Assert-True ($json.findings.Count -eq 4) 'Machine-readable report is missing findings.'
Assert-True ($json.privacy_notice.Contains('unsanitized') -and $json.privacy_notice.Contains('credentials')) 'JSON findings must include the privacy notice.'

# Give actionable first-connection guidance, while treating changed keys separately.
$unknownKeyError = 'No ED25519 host key is known for 10.0.0.9 and you have requested strict checking.' + "`nHost key verification failed."
$unknownKeyError | Set-Content -LiteralPath (Join-Path $testRoot 'ssh-stderr.log')
Assert-True ((Get-SshSetupHint $testRoot).Contains('StrictHostKeyChecking=ask')) 'Unknown host keys need interactive setup guidance.'
Assert-True (-not (Get-SshSetupHint $testRoot 'disabled').Contains('StrictHostKeyChecking=ask')) 'Skip mode must not advise enrolling a key as if strict checking were enabled.'
$null = Write-DiagnosticReport $testRoot $metadata
Assert-True ((Get-Content -LiteralPath (Join-Path $testRoot 'findings.md') -Raw).Contains('StrictHostKeyChecking=ask')) 'Host-key setup guidance is missing from the report.'
'WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED! Host key verification failed.' | Set-Content -LiteralPath (Join-Path $testRoot 'ssh-stderr.log')
$changedHint = Get-SshSetupHint $testRoot
Assert-True ($changedHint.Contains('changed host key') -and -not $changedHint.Contains('StrictHostKeyChecking=ask')) 'Changed host keys must not get first-connection acceptance guidance.'
'Permission denied (publickey).' | Set-Content -LiteralPath (Join-Path $testRoot 'ssh-stderr.log')
$authHint = Get-SshSetupHint $testRoot
Assert-True ($authHint.Contains('login authentication failed') -and $authHint.Contains('-IdentityFile') -and -not $authHint.Contains('host key')) 'Authentication failures must get login-key guidance instead of host-key guidance.'
'root@10.0.0.9: Permission denied (publickey,password).' | Set-Content -LiteralPath (Join-Path $testRoot 'ssh-stderr.log')
Assert-True ((Get-SshSetupHint $testRoot 'disabled').Contains('does not prompt for passwords')) 'Available password authentication must not be mistaken for an attempted password login.'
$passwordHint = Get-SshSetupHint $testRoot 'disabled' 'password'
Assert-True ($passwordHint.Contains('password authentication failed') -and -not $passwordHint.Contains('-IdentityFile')) 'Password-mode errors must explain password authentication.'

# An interrupted SSH stream must retain its final partial section.
$partialRoot = Join-Path $testRoot 'partial'
[System.IO.Directory]::CreateDirectory($partialRoot) | Out-Null
@("$token BEGIN logread", 'partial data') | Set-Content -LiteralPath (Join-Path $partialRoot 'ssh-output.log')
$partial = @(Read-DiagnosticCapture $partialRoot $token)
Assert-True (($partial | Where-Object name -eq 'logread').status -eq 'incomplete') 'Truncated output was marked complete.'
Assert-True (($partial | Where-Object name -eq 'dmesg').status -eq 'not-captured') 'Absent logs were marked captured.'
Assert-True ((Get-Content -LiteralPath (Join-Path $partialRoot 'logread.log') -Raw).Contains('partial data')) 'Partial data was discarded.'
[System.IO.File]::WriteAllText((Join-Path $partialRoot 'defaults.log'), '')
Assert-True (@(Get-DiagnosticFindings $partialRoot).Count -eq 0) 'Empty partial files should not produce findings or crash.'

# Native subprocess fixtures exercise streaming, stderr, exit status and timeout without a router.
$fakeSsh = Join-Path $testRoot 'fake-ssh.ps1'
@'
$null = [Console]::In.ReadToEnd()
[Console]::Out.WriteLine('__OPENWRT_DIAG_test__ BEGIN logread')
[Console]::Out.WriteLine('captured from a subprocess')
[Console]::Out.WriteLine('__OPENWRT_DIAG_test__ END logread 0')
[Console]::Error.WriteLine('test stderr')
exit 255
'@ | Set-Content -LiteralPath $fakeSsh -Encoding utf8
$startInfo = [System.Diagnostics.ProcessStartInfo]::new()
$startInfo.FileName = (Get-Process -Id $PID).Path
$startInfo.UseShellExecute = $false
$startInfo.RedirectStandardInput = $true
$startInfo.RedirectStandardOutput = $true
$startInfo.RedirectStandardError = $true
foreach ($arg in @('-NoProfile', '-NonInteractive', '-File', $fakeSsh)) { $startInfo.ArgumentList.Add($arg) }
$transportRoot = Join-Path $testRoot 'transport'
[System.IO.Directory]::CreateDirectory($transportRoot) | Out-Null
$transport = Invoke-SshCapture $startInfo 'read-only fixture' $transportRoot 10
Assert-True (@($transport).Count -eq 1) 'Async stream completion objects must not leak into the transport result.'
Assert-True ($transport.exit_code -eq 255 -and -not $transport.timed_out) 'SSH failure status was lost.'
Assert-True ((Get-Content -LiteralPath (Join-Path $transportRoot 'ssh-stderr.log') -Raw).Contains('test stderr')) 'SSH stderr was lost.'
$transportSections = @(Read-DiagnosticCapture $transportRoot $token)
Assert-True (($transportSections | Where-Object name -eq 'logread').status -eq 'captured') 'Failed SSH lost already captured logs.'
$partialMetadata = @{ transport = $transport; sections = $transportSections }
Assert-True ((Get-DiagnosticCaptureState $transportRoot $partialMetadata) -eq 'partial') 'SSH failure after retrieving logs should allow partial analysis.'
$null = Write-DiagnosticReport $transportRoot $partialMetadata
Assert-True (Test-Path -LiteralPath (Join-Path $transportRoot 'findings.md')) 'Useful partial logs must still produce a report.'
@'
$null = [Console]::In.ReadToEnd()
[Console]::Out.WriteLine('partial output before timeout')
[Console]::Out.Flush()
Start-Sleep -Seconds 30
'@ | Set-Content -LiteralPath $fakeSsh -Encoding utf8
$transport = Invoke-SshCapture $startInfo 'read-only fixture' $transportRoot 2
Assert-True $transport.timed_out 'A hanging SSH process was not stopped.'
Assert-True ((Get-Content -LiteralPath (Join-Path $transportRoot 'ssh-output.log') -Raw).Contains('partial output')) 'Timeout discarded partial output.'

# Generate the actual shell script for a separate shell syntax check.
$remote = New-RemoteScript $token
Assert-True (-not $remote.Contains("`r")) 'The remote script must use Unix line endings, including after a Windows checkout.'
[System.IO.File]::WriteAllText((Join-Path $testRoot 'remote.sh'), $remote, [System.Text.UTF8Encoding]::new($false))
$sshInfo = New-SshStartInfo -Executable (Get-Process -Id $PID).Path -Destination 'root@192.168.1.9' -SshPort 2222
Assert-True ($sshInfo.ArgumentList.Contains('StrictHostKeyChecking=yes')) 'Host key verification must stay enabled by default.'
Assert-True (@($sshInfo.ArgumentList | Where-Object { $_ -like 'UserKnownHostsFile=*' }).Count -eq 0) 'Default collection must use the saved host keys.'
Assert-True ($sshInfo.ArgumentList[$sshInfo.ArgumentList.Count - 2] -eq 'root@192.168.1.9') 'SSH target must be a separate argument.'
$relaxedInfo = New-SshStartInfo -Executable (Get-Process -Id $PID).Path -Destination 'root@10.0.0.9' -SshPort 22 -SkipHostKeyChecking
Assert-True ($relaxedInfo.ArgumentList.Contains('StrictHostKeyChecking=no') -and -not $relaxedInfo.ArgumentList.Contains('StrictHostKeyChecking=yes')) 'The explicit switch must disable strict checking.'
$expectedNullDevice = if ($IsWindows) { 'NUL' } else { '/dev/null' }
Assert-True ($relaxedInfo.ArgumentList.Contains("UserKnownHostsFile=$expectedNullDevice")) 'Relaxed collection must use the platform null device for host keys.'
Assert-True (-not $relaxedInfo.ArgumentList.Contains('UserKnownHostsFile=none')) 'The Windows OpenSSH host-verification regression must not be reintroduced.'
Assert-True ($relaxedInfo.ArgumentList.Contains('BatchMode=yes')) 'Skipping host-key checks must not change login authentication.'
$passwordInfo = New-SshStartInfo -Executable (Get-Process -Id $PID).Path -Destination 'root@10.0.0.9' -SshPort 22 -PasswordAuthentication
Assert-True ($passwordInfo.ArgumentList.Contains('BatchMode=no') -and -not $passwordInfo.ArgumentList.Contains('BatchMode=yes')) 'Password mode must permit SSH prompts.'
Assert-True ($passwordInfo.ArgumentList.Contains('PreferredAuthentications=password') -and $passwordInfo.ArgumentList.Contains('PasswordAuthentication=yes') -and $passwordInfo.ArgumentList.Contains('PubkeyAuthentication=no')) 'Password mode must select password login explicitly.'
Assert-True (-not $passwordInfo.CreateNoWindow -and $passwordInfo.Environment['SSH_ASKPASS_REQUIRE'] -eq 'never') 'Password mode must use the attached terminal rather than an askpass helper.'
Assert-True ($passwordInfo.ArgumentList.Contains('StrictHostKeyChecking=yes')) 'Password login must preserve the default host-key policy.'

# Exercise both CLI reanalysis exit codes; findings do not make complete data fail.
$pwsh = (Get-Process -Id $PID).Path
$collector = Join-Path $PSScriptRoot 'openwrt-diagnostics.ps1'
& $pwsh -NoProfile -File $collector -AnalyzePath $testRoot
Assert-True ($LASTEXITCODE -eq 2) 'The CLI must report an incomplete snapshot with exit code 2.'
foreach ($section in $metadata.sections) { $section.status = 'captured'; $section.exit_code = 0 }
$metadata | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $testRoot 'collection.json')
& $pwsh -NoProfile -File $collector -AnalyzePath $testRoot
Assert-True ($LASTEXITCODE -eq 0) 'Findings must not make a complete snapshot fail.'

# Exercise the full collection CLI with a local executable that rejects SSH arguments.
# No router is contacted; this must produce failure details instead of empty findings.
$cliRoot = Join-Path $testRoot 'cli-failure'
[System.IO.Directory]::CreateDirectory($cliRoot) | Out-Null
$destination = 'root@fixture-' + [guid]::NewGuid().ToString('N') + '.invalid'
$cliInfo = [System.Diagnostics.ProcessStartInfo]::new()
$cliInfo.FileName = $pwsh
$cliInfo.UseShellExecute = $false
$cliInfo.RedirectStandardInput = $true
$cliInfo.RedirectStandardOutput = $true
$cliInfo.RedirectStandardError = $true
foreach ($argument in @('-NoProfile', '-NonInteractive', '-File', $collector, '-Target', $destination, '-SkipHostKeyChecking', '-SshExecutable', $pwsh)) { $cliInfo.ArgumentList.Add($argument) }
$cliResult = Invoke-SshCapture $cliInfo '' $cliRoot 15
Assert-True ($cliResult.exit_code -eq 2) 'Failed connections must exit with code 2.'
$cliOut = [System.IO.File]::ReadAllText((Join-Path $cliRoot 'ssh-output.log'))
$cliErr = [System.IO.File]::ReadAllText((Join-Path $cliRoot 'ssh-stderr.log'))
Assert-True ($cliOut -notmatch '(?m)^(?:Capture|Partial capture|Findings):') 'Failed connections must not announce a capture or findings.'
Assert-True ($cliErr.Contains('remote diagnostics never started') -and $cliErr.Contains('No findings were generated')) 'Failed connections need an explicit error.'
$failedDir = Get-ChildItem -LiteralPath (Join-Path $PSScriptRoot '../logs/openwrt') -Directory | Where-Object { $_.Name.Contains($destination.Replace('@', '_')) } | Select-Object -First 1
Assert-True ($null -ne $failedDir) 'Failure troubleshooting details were not retained.'
Assert-True (-not (Test-Path -LiteralPath (Join-Path $failedDir.FullName 'findings.md'))) 'Failed connections must not create Markdown findings.'
Assert-True (-not (Test-Path -LiteralPath (Join-Path $failedDir.FullName 'findings.json'))) 'Failed connections must not create JSON findings.'
$failedMetadata = Get-Content -LiteralPath (Join-Path $failedDir.FullName 'collection.json') -Raw | ConvertFrom-Json
Assert-True ($failedMetadata.status -eq 'not-started' -and $failedMetadata.transport -isnot [array]) 'Failed collection status or transport schema is incorrect.'
Assert-True ($failedMetadata.ssh_arguments -contains 'StrictHostKeyChecking=no') 'The CLI skip switch did not reach the actual SSH invocation.'
Assert-True ($failedMetadata.ssh_arguments -contains "UserKnownHostsFile=$expectedNullDevice") 'The actual SSH invocation must use the platform null device.'
Assert-True ($failedMetadata.ssh_client -eq $pwsh) 'The selected SSH client was not recorded.'
Assert-True ($failedMetadata.authentication -eq 'key-or-agent') 'Capture metadata must record the authentication mode.'
& $pwsh -NoProfile -File $collector -AnalyzePath $failedDir.FullName
Assert-True ($LASTEXITCODE -eq 2 -and -not (Test-Path -LiteralPath (Join-Path $failedDir.FullName 'findings.md'))) 'Reanalysis must also reject captures without logs.'

# Password mode must fail clearly in jobs/pipelines, without reading a password
# from stdin or treating the remote script as a credential.
$cliInfo.ArgumentList.Add('-PasswordAuthentication')
$cliResult = Invoke-SshCapture $cliInfo '' $cliRoot 15
Assert-True ($cliResult.exit_code -eq 1) 'Password mode without a terminal must fail before collection.'
Assert-True ([System.IO.File]::ReadAllText((Join-Path $cliRoot 'ssh-stderr.log')).Contains('requires an interactive terminal')) 'Missing-terminal errors must explain how to run password mode.'

# Compatibility with already-saved failure results containing leaked completion objects.
$failedMetadata.transport = @([pscustomobject]@{}, [pscustomobject]@{}, $failedMetadata.transport)
Assert-True ((Get-DiagnosticCaptureState $failedDir.FullName $failedMetadata) -eq 'not-started') 'Legacy failed captures must be recognized.'
Assert-True ($failedMetadata.transport -isnot [array]) 'Legacy transport results must be normalized.'

# Starting remote commands without retrieving either log buffer is not analysis success.
$noLogsMetadata = @{ transport = @{ exit_code = 0; timed_out = $false; error = $null }; sections = @(
    @{ name = 'logread'; status = 'command-failed'; exit_code = 127 },
    @{ name = 'dmesg'; status = 'not-captured'; exit_code = $null },
    @{ name = 'board'; status = 'captured'; exit_code = 0 }
) }
Assert-True ((Get-DiagnosticCaptureState $failedDir.FullName $noLogsMetadata) -eq 'no-logs') 'Missing log buffers must prevent analysis.'

# Reanalyzing unusable captures must archive old reports without altering raw
# evidence. Exercise the CLI for both failure states and legacy transport arrays.
$archiveCases = @(
    @{ name = 'not-started'; transport = $failedMetadata.transport; sections = $failedMetadata.sections; message = 'remote diagnostics never started' },
    @{ name = 'no-logs'; transport = $noLogsMetadata.transport; sections = $noLogsMetadata.sections; message = 'no usable system or kernel logs were retrieved' },
    @{ name = 'legacy-not-started'; transport = @([pscustomobject]@{}, [pscustomobject]@{}, $failedMetadata.transport); sections = $failedMetadata.sections; message = 'remote diagnostics never started' }
)
foreach ($case in $archiveCases) {
    $archiveRoot = Join-Path $testRoot ('archive-' + $case.name)
    [System.IO.Directory]::CreateDirectory($archiveRoot) | Out-Null
    $caseMetadata = @{ schema_version = 1; transport = $case.transport; sections = $case.sections }
    $caseMetadata | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $archiveRoot 'collection.json') -Encoding utf8
    [System.IO.File]::WriteAllText((Join-Path $archiveRoot 'ssh-output.log'), 'Original transport output')
    [System.IO.File]::WriteAllText((Join-Path $archiveRoot 'ssh-stderr.log'), 'Original transport error')
    [System.IO.File]::WriteAllText((Join-Path $archiveRoot 'logread.log'), 'logread: not found')
    [System.IO.File]::WriteAllText((Join-Path $archiveRoot 'board.log'), 'Original board snapshot')
    $originalMarkdown = 'Obsolete findings from an earlier collector'
    $originalJson = '{"schema_version":1,"findings":[]}'
    [System.IO.File]::WriteAllText((Join-Path $archiveRoot 'findings.md'), $originalMarkdown)
    [System.IO.File]::WriteAllText((Join-Path $archiveRoot 'findings.json'), $originalJson)
    $rawHashes = @{}
    foreach ($name in @('collection.json', 'ssh-output.log', 'ssh-stderr.log', 'logread.log', 'board.log')) {
        $rawHashes[$name] = (Get-FileHash -LiteralPath (Join-Path $archiveRoot $name)).Hash
    }
    $analysisInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $analysisInfo.FileName = $pwsh
    $analysisInfo.UseShellExecute = $false
    $analysisInfo.RedirectStandardInput = $true
    $analysisInfo.RedirectStandardOutput = $true
    $analysisInfo.RedirectStandardError = $true
    foreach ($argument in @('-NoProfile', '-NonInteractive', '-File', $collector, '-AnalyzePath', $archiveRoot)) { $analysisInfo.ArgumentList.Add($argument) }
    $invocationRoot = Join-Path $archiveRoot 'invocation'
    [System.IO.Directory]::CreateDirectory($invocationRoot) | Out-Null
    $analysisResult = Invoke-SshCapture $analysisInfo '' $invocationRoot 15
    $analysisError = [System.IO.File]::ReadAllText((Join-Path $invocationRoot 'ssh-stderr.log'))
    $analysisOutput = [System.IO.File]::ReadAllText((Join-Path $invocationRoot 'ssh-output.log'))
    Assert-True ($analysisResult.exit_code -eq 2 -and $analysisError.Contains($case.message)) "$($case.name): unusable reanalysis must retain its failure status."
    Assert-True ($analysisOutput -notmatch '(?m)^(?:Capture|Partial capture|Findings):') "$($case.name): unusable reanalysis must not announce current findings."
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $archiveRoot 'findings.md')) -and -not (Test-Path -LiteralPath (Join-Path $archiveRoot 'findings.json'))) "$($case.name): obsolete reports must not remain as current findings."
    $archives = @(Get-ChildItem -LiteralPath (Join-Path $archiveRoot 'findings-archive') -Directory)
    Assert-True ($archives.Count -eq 1 -and $analysisError.Contains("Previous findings archived: $($archives[0].FullName)")) "$($case.name): the CLI must identify the preserved reports' archive."
    Assert-True ([System.IO.File]::ReadAllText((Join-Path $archives[0].FullName 'findings.md')) -eq $originalMarkdown) "$($case.name): old Markdown findings must be preserved."
    Assert-True ([System.IO.File]::ReadAllText((Join-Path $archives[0].FullName 'findings.json')) -eq $originalJson) "$($case.name): old JSON findings must be preserved."
    foreach ($name in $rawHashes.Keys) {
        Assert-True ((Get-FileHash -LiteralPath (Join-Path $archiveRoot $name)).Hash -eq $rawHashes[$name]) "$($case.name): archival must not alter $name."
    }
    $analysisResult = Invoke-SshCapture $analysisInfo '' $invocationRoot 15
    Assert-True ($analysisResult.exit_code -eq 2 -and @(Get-ChildItem -LiteralPath (Join-Path $archiveRoot 'findings-archive') -Directory).Count -eq 1) "$($case.name): repeating unusable reanalysis must not create another archive."
    Assert-True (-not [System.IO.File]::ReadAllText((Join-Path $invocationRoot 'ssh-stderr.log')).Contains('Previous findings archived:')) "$($case.name): repeating reanalysis must not claim it archived another report."
}
Write-Host "All diagnostic tests passed. Ignored fixtures: $([System.IO.Path]::GetFullPath($testRoot))"

# Expected CLI failures leave LASTEXITCODE nonzero. GitHub Actions propagates
# that value after the script returns, so report success only after all asserts.
exit 0
