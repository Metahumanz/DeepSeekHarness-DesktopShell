$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$preflight = Join-Path $repo 'scripts\Test-PluginBootPreflight.ps1'
$base = Join-Path $env:TEMP ('dsh-preflight-cleanup-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $base | Out-Null

$fail = 0
$serverPid = -1
$port = -1
$preflightProcess = $null
function Assert-True([string]$label, [bool]$condition) {
    if ($condition) { Write-Host "PASS: $label" }
    else { $script:fail++; Write-Host "FAIL: $label" }
}

function Test-PortOpen([int]$candidatePort) {
    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $async = $client.BeginConnect('127.0.0.1', $candidatePort, $null, $null)
        if (-not $async.AsyncWaitHandle.WaitOne(250)) { return $false }
        $client.EndConnect($async)
        return $true
    }
    catch { return $false }
    finally { $client.Dispose() }
}

try {
    $fakeDsh = Join-Path $base 'dsh.cmd'
    $fakeServer = Join-Path $base 'dsh-server.ps1'
    $fakeDshContent = @'
@echo off
setlocal
if /I "%~1"=="plugin" goto plugin
start "" /b powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0dsh-server.ps1" %* >nul 2>nul
ping 127.0.0.1 -n 2 >nul
exit /b 0
:plugin
set "profile=%~3"
if not defined profile exit /b 2
if not exist "%DSH_HOME%\profiles\%profile%\" mkdir "%DSH_HOME%\profiles\%profile%\"
exit /b 0
'@
    [IO.File]::WriteAllText($fakeDsh, $fakeDshContent)

    $fakeServerContent = @'
$port = 0
for ($i = 0; $i -lt $args.Count - 1; $i++) {
  if ([string]$args[$i] -eq '--port') { $port = [int]$args[$i + 1]; break }
}
if ($port -le 0) { exit 2 }
[IO.File]::WriteAllText((Join-Path $PSScriptRoot 'server.pid'), $PID.ToString())
$root = $env:DSH_HOME
$out = Join-Path $root 'preflight\web-stdout.log'
$listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, $port)
$listener.Start()
Add-Content -LiteralPath $out -Value ('dsh web: http://127.0.0.1:{0}' -f $port)
while ($true) {
  if ($listener.Pending()) {
    $client = $listener.AcceptTcpClient(); $stream = $client.GetStream()
    $head = [Text.Encoding]::ASCII.GetBytes(('HTTP/1.1 200 OK' + [char]13 + [char]10 + 'Content-Length: 0' + [char]13 + [char]10 + 'Connection: close' + [char]13 + [char]10 + [char]13 + [char]10))
    $stream.Write($head, 0, $head.Length); $stream.Close(); $client.Close()
  } else { Start-Sleep -Milliseconds 25 }
}
'@
    [IO.File]::WriteAllText($fakeServer, $fakeServerContent)

    $preflightStdout = Join-Path $base 'preflight.stdout.log'
    $preflightStderr = Join-Path $base 'preflight.stderr.log'
    $preflightArgs = @(
        '-NoProfile', '-File', $preflight,
        '-PluginSpec', 'fake-plugin@0.0.0',
        '-RunnerMode', 'command', '-DshPath', $fakeDsh,
        '-StableSeconds', '2', '-TimeoutSeconds', '15'
    )
    $preflightProcess = Start-Process -FilePath 'powershell.exe' -ArgumentList $preflightArgs `
        -WorkingDirectory $base -WindowStyle Hidden -RedirectStandardOutput $preflightStdout `
        -RedirectStandardError $preflightStderr -PassThru
    $completed = $preflightProcess.WaitForExit(30000)
    if (-not $completed) {
        & taskkill.exe /PID $preflightProcess.Id /T /F 2>$null | Out-Null
        $code = 124
    }
    else {
        try { $preflightProcess.Refresh() } catch { }
        $code = [int]$preflightProcess.ExitCode
    }
    try { $preflightProcess.Dispose() } catch { }
    $output = if (Test-Path -LiteralPath $preflightStdout) { Get-Content -LiteralPath $preflightStdout -Raw } else { '' }
    $errorOutput = if (Test-Path -LiteralPath $preflightStderr) { Get-Content -LiteralPath $preflightStderr -Raw } else { '' }
    if ($errorOutput) { $output += "`r`n" + $errorOutput }
    foreach ($line in @($output -split "`r?`n" | Where-Object { $_ -match '^(PLUGIN PREFLIGHT|PLUGIN BOOT|PASS|FAIL)' })) {
        Write-Host $line
    }

    $portMatch = [regex]::Match($output, 'cleanup listener pid=\d+ port=(\d+)')
    if ($portMatch.Success) { $port = [int]$portMatch.Groups[1].Value }
    $pidPath = Join-Path $base 'server.pid'
    if (Test-Path -LiteralPath $pidPath) {
        try { $serverPid = [int](Get-Content -LiteralPath $pidPath -Raw).Trim() } catch { }
    }

    Assert-True 'preflight exercises exact listener PID cleanup after wrapper exit' (
        $output -match 'cleanup listener pid=\d+ port=\d+')
    Assert-True 'preflight reports cleanup port closed' (
        $output -match 'cleanup=closed' -or
        ($output -match 'cleanup listener pid=\d+ port=\d+' -and $port -gt 0))
    $hasCompatibilityPass = $output -match 'PLUGIN BOOT PREFLIGHT PASSED'
    Assert-True ("preflight does not return compatibility PASS when wrapper exits early (exit=$code pass=$hasCompatibilityPass)") `
        (-not $hasCompatibilityPass)
    $portOpenAfterCleanup = if ($port -gt 0) { Test-PortOpen $port } else { $true }
    Assert-True ("preflight random port is closed after cleanup (port=$port open=$portOpenAfterCleanup)") `
        ($port -gt 0 -and -not $portOpenAfterCleanup)

    $serverAlive = $false
    if ($serverPid -gt 0) {
        try {
            $server = Get-Process -Id $serverPid -ErrorAction Stop
            $serverAlive = -not $server.HasExited
            $server.Dispose()
        }
        catch { $serverAlive = $false }
    }
    Assert-True ("preflight listener process is gone after exact PID cleanup (pid=$serverPid alive=$serverAlive)") `
        ($serverPid -gt 0 -and -not $serverAlive)
}
catch {
    Write-Host "FAIL: preflight cleanup harness setup: $($_.Exception.Message)"
    $fail++
}
finally {
    # 仅使用 harness 自己记录的精确 PID 作兜底，避免测试异常时泄漏 fake listener。
    if ($serverPid -gt 0) {
        try { Stop-Process -Id $serverPid -Force -ErrorAction SilentlyContinue } catch { }
    }
    Remove-Item -LiteralPath $base -Recurse -Force -ErrorAction SilentlyContinue
}

if ($fail -eq 0) { Write-Host 'PLUGIN PREFLIGHT CLEANUP TESTS PASSED' }
else { Write-Host "FAILURES: $fail" }
exit $(if ($fail -eq 0) { 0 } else { 1 })
