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
Assert-True (-not ($findings | Where-Object id -eq 'wan')) 'WAN coming up must not be treated as a failure.'

$metadata = [ordered]@{ schema_version = 1; transport = @{ exit_code = 0; timed_out = $false; error = $null }; sections = $sections }
$metadata | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $testRoot 'collection.json')
$null = Write-DiagnosticReport $testRoot $metadata
$report = Get-Content -LiteralPath (Join-Path $testRoot 'findings.md') -Raw
Assert-True ($report.Contains('Collection is incomplete')) 'A failed section must be visible in the report.'
$json = Get-Content -LiteralPath (Join-Path $testRoot 'findings.json') -Raw | ConvertFrom-Json
Assert-True ($json.findings.Count -eq 4) 'Machine-readable report is missing findings.'

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
& $pwsh -NoProfile -File $collector -AnalyzePath $failedDir.FullName
Assert-True ($LASTEXITCODE -eq 2 -and -not (Test-Path -LiteralPath (Join-Path $failedDir.FullName 'findings.md'))) 'Reanalysis must also reject captures without logs.'

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
Write-Host "All diagnostic tests passed. Ignored fixtures: $([System.IO.Path]::GetFullPath($testRoot))"
