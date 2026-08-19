$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$hostLogCs = Join-Path $repo 'src\HostLog.cs'
$base = Join-Path $env:TEMP ('dsh-hostlog-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $base | Out-Null

$fail = 0
function Assert-True([string]$label, [bool]$condition) {
    if ($condition) { Write-Host "PASS: $label" }
    else { $script:fail++; Write-Host "FAIL: $label" }
}

# ---- 编译「产品同一个 HostLog.cs + Main 包装」为探测 exe ----
$cscCandidates = @(
    "$env:WINDIR\Microsoft.NET\Framework64\v4.0.30319\csc.exe",
    "$env:WINDIR\Microsoft.NET\Framework\v4.0.30319\csc.exe"
)
$csc = $cscCandidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
if (-not $csc) { Write-Host 'FAIL: csc not found'; exit 1 }

$probeCs = Join-Path $base 'probe.cs'
@'
using System;
using System.IO;
class Probe {
    static int Main() {
        string dir = Path.Combine(Path.GetTempPath(), "dsh-hostlog-run-" + Guid.NewGuid().ToString("N"));
        DeepSeekHarnessDesktop.HostLog.Initialize(dir, "test-instance");
        DeepSeekHarnessDesktop.HostLog.Enter("PHASE A");
        DeepSeekHarnessDesktop.HostLog.Ok("PHASE A");
        DeepSeekHarnessDesktop.HostLog.Fail("PHASE B", new InvalidOperationException("boom-detail"));
        DeepSeekHarnessDesktop.HostLog.Line("PLAIN line");
        Console.WriteLine(Path.Combine(dir, "desktop-shell.log"));
        return 0;
    }
}
'@ | Set-Content -LiteralPath $probeCs -Encoding ascii
$probeExe = Join-Path $base 'probe.exe'
& $csc /nologo /target:exe /optimize+ "/out:$probeExe" $probeCs $hostLogCs | Out-Null
if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $probeExe)) {
    Write-Host 'FAIL: probe compile'
    exit 1
}

# ---- 行为验证：初始化/ENTER/OK/FAIL(异常 ToString)/普通行 ----
$logPath = (& $probeExe).Trim()
if (-not $logPath -or -not (Test-Path -LiteralPath $logPath)) {
    Write-Host "FAIL: log file not created: $logPath"
    exit 1
}
Write-Host "log created: $logPath"
$log = [System.IO.File]::ReadAllText($logPath)

Assert-True "INIT line carries instance id" ($log -match 'INIT host log instance=test-instance')
Assert-True "ENTER line written" ($log -match 'ENTER PHASE A')
Assert-True "OK line written" ($log -match 'OK PHASE A')
Assert-True "FAIL line contains exception ToString (type+message)" ($log -match 'FAIL PHASE B[^\r\n]*InvalidOperationException[^\r\n]*boom-detail')
Assert-True "plain Line() written" ($log -match 'PLAIN line')

Remove-Item -LiteralPath $base -Recurse -Force -ErrorAction SilentlyContinue
if ($fail -eq 0) { Write-Host 'HOST LOG TESTS PASSED' } else { Write-Host "FAILURES: $fail" }
exit $(if ($fail -eq 0) { 0 } else { 1 })
