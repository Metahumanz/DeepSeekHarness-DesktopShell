$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$base = Join-Path $env:TEMP ('dsh-startup-identity-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $base | Out-Null

$fail = 0
function Assert-True([string]$label, [bool]$condition) {
    if ($condition) { Write-Host "PASS: $label" }
    else { $script:fail++; Write-Host "FAIL: $label" }
}

# ---- 编译真实产品源码（DeepSeekHarness.cs + HostLog.cs + NativeTcpTable.cs）+ 测试 Main ----
$cscCandidates = @(
    "$env:WINDIR\Microsoft.NET\Framework64\v4.0.30319\csc.exe",
    "$env:WINDIR\Microsoft.NET\Framework\v4.0.30319\csc.exe"
)
$csc = $cscCandidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
if (-not $csc) { Write-Host 'FAIL: csc not found'; exit 1 }

# WebView2 引用（编译 DeepSeekHarness.cs 需要）：NuGet 缓存优先，否则下载固定版本
$sdkRoot = Join-Path $env:USERPROFILE '.nuget\packages\microsoft.web.webview2\1.0.4078.44'
$core = $null; $winForms = $null
if (Test-Path -LiteralPath $sdkRoot) {
    $core = Get-ChildItem $sdkRoot -Recurse -Filter 'Microsoft.Web.WebView2.Core.dll' | Where-Object { $_.FullName -match '[\\/]lib[\\/]' } | Select-Object -First 1
    $winForms = Get-ChildItem $sdkRoot -Recurse -Filter 'Microsoft.Web.WebView2.WinForms.dll' | Where-Object { $_.FullName -match '[\\/]lib[\\/]' } | Select-Object -First 1
}
if (-not $core -or -not $winForms) {
    $dl = Join-Path $base 'wv2'
    New-Item -ItemType Directory -Force -Path $dl | Out-Null
    $nupkg = Join-Path $dl 'wv2.zip'
    Invoke-WebRequest -UseBasicParsing -Uri 'https://www.nuget.org/api/v2/package/Microsoft.Web.WebView2/1.0.4078.44' -OutFile $nupkg -TimeoutSec 120
    Expand-Archive -LiteralPath $nupkg -DestinationPath (Join-Path $dl 'pkg') -Force
    $core = Get-ChildItem (Join-Path $dl 'pkg') -Recurse -Filter 'Microsoft.Web.WebView2.Core.dll' | Where-Object { $_.FullName -match '[\\/]lib[\\/]' } | Select-Object -First 1
    $winForms = Get-ChildItem (Join-Path $dl 'pkg') -Recurse -Filter 'Microsoft.Web.WebView2.WinForms.dll' | Where-Object { $_.FullName -match '[\\/]lib[\\/]' } | Select-Object -First 1
}
if (-not $core -or -not $winForms) { Write-Host 'FAIL: WebView2 reference assemblies not found'; exit 1 }

$harnessCs = Join-Path $base 'harness.cs'
$harnessSource = @'
using System;
using System.Diagnostics;
using System.IO;
using System.Net;
using System.Net.Sockets;
using System.Threading;

namespace Harness
{
    class Program
    {
        static int Failures = 0;

        static void Assert(bool cond, string label)
        {
            if (cond) Console.WriteLine("PASS: " + label);
            else { Failures++; Console.WriteLine("FAIL: " + label); }
        }

        static int GetFreePort()
        {
            TcpListener l = new TcpListener(IPAddress.Loopback, 0);
            l.Start();
            int port = ((IPEndPoint)l.LocalEndpoint).Port;
            l.Stop();
            return port;
        }

        static int Main()
        {
            string baseDir = Path.Combine(Path.GetTempPath(), "dsh-identity-" + Guid.NewGuid().ToString("N"));
            Directory.CreateDirectory(baseDir);
            try
            {
                // ===== 场景 A：自己的 DSH 晚就绪（fake 后端睡眠 500ms 后才开始监听）→ 必须成功 =====
                // fake dsh.cmd 放在含 \dsh\ 的目录（命令行身份特征）；Job 归属证明优先于命令行。
                int portA = GetFreePort();
                string dshDir = Path.Combine(baseDir, "dsh");
                Directory.CreateDirectory(dshDir);
                File.WriteAllText(Path.Combine(dshDir, "dsh.cmd"),
                    "@echo off\r\nsetlocal\r\necho %*|findstr /C:\"--help\" >nul\r\nif not errorlevel 1 ( echo --no-open & exit /b 0 )\r\necho %*|findstr /C:\"--version\" >nul\r\nif not errorlevel 1 ( echo 0.1.0-rc.7 & exit /b 0 )\r\npowershell -NoProfile -ExecutionPolicy Bypass -File \"%~dp0dsh-server.ps1\" %*\r\n");
                File.WriteAllText(Path.Combine(dshDir, "dsh-server.ps1"),
                    "param([string]$Profile='web',[int]$Port=3080)\r\n" +
                    "Start-Sleep -Milliseconds 500\r\n" +
                    "$l=[System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback,$Port)\r\n" +
                    "$l.Start()\r\n" +
                    "Write-Output ('dsh web: http://127.0.0.1:{0}' -f $Port)\r\n" +
                    "while($true){ $c=$l.AcceptTcpClient(); $s=$c.GetStream(); $b=[Text.Encoding]::ASCII.GetBytes(('HTTP/1.1 200 OK' + [char]13 + [char]10 + 'Content-Length: 0' + [char]13 + [char]10 + 'Connection: close' + [char]13 + [char]10 + [char]13 + [char]10)); $s.Write($b,0,$b.Length); $s.Close(); $c.Close() }\r\n");
                string logsA = Path.Combine(baseDir, "logs-a");
                DeepSeekHarnessDesktop.HostLog.Initialize(logsA, "identity-harness-a");
                DeepSeekHarnessDesktop.DshProcessManager mgrA = new DeepSeekHarnessDesktop.DshProcessManager();
                try
                {
                    Stopwatch sw = Stopwatch.StartNew();
                    DeepSeekHarnessDesktop.DshProcessManager.BackendStartResult r =
                        mgrA.EnsureStarted(portA, baseDir, logsA, "0.1.0-rc.7", "web",
                            Path.Combine(dshDir, "dsh.cmd"), "command", false);
                    sw.Stop();
                    Assert(r != null && r.ListenerPid > 0,
                        "A: EnsureStarted returns confirmed listener pid (got " + (r == null ? "null" : r.ListenerPid.ToString()) + ")");
                    Assert(r != null && r.WrapperPid > 0, "A: wrapper pid recorded in result");
                    Assert(mgrA.OwnsBackend, "A: owns backend");
                    Assert(mgrA.OwnedListenerPid > 0, "A: ownedListenerPid written inside EnsureStarted");
                    Assert(mgrA.IsDshReady(portA, 500), "A: port serves DSH");
                    Assert(sw.ElapsedMilliseconds < 20000,
                        "A: started within 20s without NonDsh throw (took " + sw.ElapsedMilliseconds + "ms)");
                    Console.WriteLine("A elapsed=" + sw.ElapsedMilliseconds + "ms wrapper=" + r.WrapperPid + " listener=" + r.ListenerPid);
                }
                catch (Exception ex)
                {
                    Assert(false, "A: must succeed without NonDsh throw: " + ex.GetType().Name + " " + ex.Message);
                }
                finally
                {
                    mgrA.StopOwnedBackend();
                    mgrA.Dispose();
                }

                // A 的宿主日志断言（在切换 HostLog 目标前读取）
                string hostLogA = Path.Combine(logsA, "desktop-shell.log");
                if (File.Exists(hostLogA))
                {
                    string logText = File.ReadAllText(hostLogA);
                    Assert(logText.IndexOf("BACKEND ready generation=") >= 0 &&
                        logText.IndexOf("wrapper=") >= 0 && logText.IndexOf("listener=") >= 0,
                        "A: BACKEND ready logged with generation+wrapper+listener");
                    Assert(logText.IndexOf("inOwnJob=true") >= 0 || logText.IndexOf("identity=verified-dsh") >= 0,
                        "A: identity transition logged (inOwnJob or verified-dsh)");
                    Assert(logText.IndexOf("identity=pending") >= 0 || logText.IndexOf("PORT closed") >= 0,
                        "A: pending/closed transition logged (no immediate NonDsh)");
                }
                else { Assert(false, "A: host log missing"); }

                // ===== 场景 B：真 Foreign 抢占（稳定确认后才拒绝） =====
                // dummy.cmd 什么都不监听；700ms 后由 harness 自己（不在 DSH Job 内、命令行无 DSH 特征）
                // 打开端口——模拟“普通程序占端口”且保持 2 秒以上。
                int portB = GetFreePort();
                string plainDir = Path.Combine(baseDir, "plain");
                Directory.CreateDirectory(plainDir);
                File.WriteAllText(Path.Combine(plainDir, "dummy.cmd"),
                    "@echo off\r\nsetlocal\r\necho %*|findstr /C:\"--help\" >nul\r\nif not errorlevel 1 ( exit /b 0 )\r\necho %*|findstr /C:\"--version\" >nul\r\nif not errorlevel 1 ( echo 0.1.0-rc.7 & exit /b 0 )\r\npowershell -NoProfile -Command \"Start-Sleep -Seconds 30\"\r\n");
                string logsB = Path.Combine(baseDir, "logs-b");
                DeepSeekHarnessDesktop.HostLog.Initialize(logsB, "identity-harness-b");
                DeepSeekHarnessDesktop.DshProcessManager mgrB = new DeepSeekHarnessDesktop.DshProcessManager();
                TcpListener foreign = null;
                int bPort = portB;
                Thread t = new Thread(delegate()
                {
                    Thread.Sleep(700);   // 让 EnsureStarted 先进入等待循环（入口探测时端口必须关闭）
                    foreign = new TcpListener(IPAddress.Loopback, bPort);
                    foreign.Start();
                });
                t.Start();
                try
                {
                    mgrB.EnsureStarted(bPort, baseDir, logsB, "0.1.0-rc.7", "web",
                        Path.Combine(plainDir, "dummy.cmd"), "command", false);
                    Assert(false, "B: must refuse foreign listener");
                }
                catch (InvalidOperationException ex)
                {
                    Assert(ex.Message.IndexOf("非 DSH") >= 0, "B: rejected with NonDsh message");
                }
                catch (Exception ex)
                {
                    Assert(false, "B: unexpected exception " + ex.GetType().Name + ": " + ex.Message);
                }
                finally
                {
                    t.Join(3000);
                    mgrB.Dispose();   // 兜底：Foreign 身份未验证 → 不得被杀，随后显式关闭
                    if (foreign != null) { try { foreign.Stop(); } catch { } }
                }

                string hostLogB = Path.Combine(logsB, "desktop-shell.log");
                if (File.Exists(hostLogB))
                {
                    string logB = File.ReadAllText(hostLogB);
                    Assert(logB.IndexOf("identity=foreign stableCount=4") >= 0, "B: foreign stableCount=4 logged before rejection");
                }
                else { Assert(false, "B: host log missing"); }
            }
            finally
            {
                try { Directory.Delete(baseDir, true); } catch { }
            }

            Console.WriteLine(Failures == 0 ? "STARTUP IDENTITY HARNESS PASSED" : "HARNESS FAILURES: " + Failures);
            return Failures == 0 ? 0 : 1;
        }
    }
}
'@
# 必须 UTF-8 BOM 写入（harness.cs 含中文字符串“非 DSH”，ASCII 写入会被破坏导致断言失效）
[System.IO.File]::WriteAllText($harnessCs, $harnessSource, [System.Text.UTF8Encoding]::new($true))

$harnessExe = Join-Path $base 'harness.exe'
& $csc /nologo /target:exe /optimize+ "/main:Harness.Program" "/out:$harnessExe" `
    /reference:System.dll /reference:System.Core.dll /reference:System.Drawing.dll `
    /reference:System.Windows.Forms.dll /reference:System.Web.Extensions.dll `
    "/reference:$($core.FullName)" "/reference:$($winForms.FullName)" `
    (Join-Path $repo 'src\DeepSeekHarness.cs') (Join-Path $repo 'src\HostLog.cs') `
    (Join-Path $repo 'src\NativeTcpTable.cs') $harnessCs 2>&1 | Out-String
if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $harnessExe)) {
    Write-Host "FAIL: harness compile (exit $LASTEXITCODE)"
    exit 1
}
Write-Host "harness compiled: $harnessExe"

# ---- 运行真实场景 ----
$out = & $harnessExe 2>&1 | Out-String
$code = $LASTEXITCODE
foreach ($line in @($out -split "`r?`n" | Where-Object { $_ -match '^(PASS|FAIL|STARTUP|HARNESS)' })) {
    Write-Host $line
    if ($line -match '^FAIL') { $script:fail++ }
}
if ($code -ne 0) {
    Write-Host "harness exit=$code"
    $script:fail++
}

Remove-Item -LiteralPath $base -Recurse -Force -ErrorAction SilentlyContinue
if ($fail -eq 0) { Write-Host 'STARTUP IDENTITY TESTS PASSED' } else { Write-Host "FAILURES: $fail" }
exit $(if ($fail -eq 0) { 0 } else { 1 })
