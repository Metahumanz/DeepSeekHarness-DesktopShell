$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$nativeCs = Join-Path $repo 'src\NativeTcpTable.cs'
$base = Join-Path $env:TEMP ('dsh-port-owner-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $base | Out-Null

$fail = 0
function Assert-True([string]$label, [bool]$condition) {
    if ($condition) { Write-Host "PASS: $label" }
    else { $script:fail++; Write-Host "FAIL: $label" }
}

# ---- 编译「产品同一个 NativeTcpTable.cs + Main 包装」为探测 exe ----
# 关键点：测试编译的是产品源码本身，不是测试里的复制品——
# 原生解析错误（行偏移/字节序/状态过滤）在这里会被真实暴露。
$cscCandidates = @(
    "$env:WINDIR\Microsoft.NET\Framework64\v4.0.30319\csc.exe",
    "$env:WINDIR\Microsoft.NET\Framework\v4.0.30319\csc.exe"
)
$csc = $cscCandidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
if (-not $csc) { Write-Host 'FAIL: csc not found'; exit 1 }

$probeCs = Join-Path $base 'probe.cs'
@'
using System;
class Probe {
    static int Main(string[] args) {
        if (args.Length < 1) { Console.WriteLine("usage: probe <port>"); return 2; }
        int port = int.Parse(args[0]);
        Console.WriteLine(DeepSeekHarnessDesktop.TcpTableHelper.FindListeningPidNative(port));
        return 0;
    }
}
'@ | Set-Content -LiteralPath $probeCs -Encoding ascii
$probeExe = Join-Path $base 'probe.exe'
& $csc /nologo /target:exe /optimize+ "/out:$probeExe" $probeCs $nativeCs | Out-Null
if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $probeExe)) {
    Write-Host 'FAIL: probe compile'
    exit 1
}
Write-Host "probe compiled: $probeExe"

# ---- 真实验证：本进程监听一个空闲端口，原生查询必须返回本进程 PID ----
# 不触碰宿主机任何真实端口：TcpListener 端口 0 = 系统分配的空闲端口。
$listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
$listener.Start()
$port = ([System.Net.IPEndPoint]$listener.LocalEndpoint).Port
Write-Host "listening on 127.0.0.1:$port (test host pid $PID)"

try {
    $owner = (& $probeExe $port).Trim()
    Assert-True "native owner pid matches test host (native=$owner host=$PID)" ($owner -eq ([string]$PID))

    # netstat 交叉验证：同一端口 netstat 的 PID 列也必须等于本进程（输出经文件重定向，
    # 避免管道捕获在受限宿主下的兼容问题；netstat 的 State 列可能本地化，只取末列 PID）
    $netstatOut = Join-Path $base 'netstat.txt'
    & netstat -ano *> $netstatOut
    $line = Select-String -Path $netstatOut -Pattern ":$port\s" | Select-Object -First 1
    $netstatPid = ''
    if ($line) {
        $parts = @(($line.ToString() -split '\s+') | Where-Object { $_ })
        if ($parts.Count -ge 5) { $netstatPid = $parts[$parts.Count - 1] }
    }
    Assert-True "netstat cross-check (netstat=$netstatPid host=$PID)" ($netstatPid -eq ([string]$PID))
} finally {
    $listener.Stop()
}

# 端口关闭后必须返回 -1（而不是 0 / 崩溃 / 残留旧结果）
Start-Sleep -Milliseconds 300
$closed = (& $probeExe $port).Trim()
Assert-True "closed port returns -1 (got: $closed)" ($closed -eq '-1')

Remove-Item -LiteralPath $base -Recurse -Force -ErrorAction SilentlyContinue
if ($fail -eq 0) { Write-Host 'PORT OWNER TESTS PASSED' } else { Write-Host "FAILURES: $fail" }
exit $(if ($fail -eq 0) { 0 } else { 1 })
