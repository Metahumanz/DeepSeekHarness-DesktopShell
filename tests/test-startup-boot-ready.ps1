$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$base = Join-Path $env:TEMP ('dsh-boot-ready-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $base | Out-Null

$fail = 0
function Assert-True([string]$label, [bool]$condition) {
    if ($condition) { Write-Host "PASS: $label" }
    else { $script:fail++; Write-Host "FAIL: $label" }
}

try {
    $csc = @(
        "$env:WINDIR\Microsoft.NET\Framework64\v4.0.30319\csc.exe",
        "$env:WINDIR\Microsoft.NET\Framework\v4.0.30319\csc.exe"
    ) | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
    if (-not $csc) { throw 'csc not found' }

    $sdkRoot = Join-Path $env:USERPROFILE '.nuget\packages\microsoft.web.webview2\1.0.4078.44'
    $core = $null
    $winForms = $null
    if (Test-Path -LiteralPath $sdkRoot) {
        $core = Get-ChildItem $sdkRoot -Recurse -Filter 'Microsoft.Web.WebView2.Core.dll' |
            Where-Object { $_.FullName -match '[\\/]lib[\\/]' } | Select-Object -First 1
        $winForms = Get-ChildItem $sdkRoot -Recurse -Filter 'Microsoft.Web.WebView2.WinForms.dll' |
            Where-Object { $_.FullName -match '[\\/]lib[\\/]' } | Select-Object -First 1
    }
    if (-not $core -or -not $winForms) { throw 'WebView2 reference assemblies not found' }

    $dshDir = Join-Path $base 'dsh'
    $logsDir = Join-Path $base 'logs'
    New-Item -ItemType Directory -Force -Path $dshDir, $logsDir | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $dshDir 'dsh.cmd'),
        "@echo off`r`nsetlocal`r`necho %*|findstr /C:`"--help`" >nul`r`nif not errorlevel 1 ( echo --no-open & exit /b 0 )`r`necho %*|findstr /C:`"--version`" >nul`r`nif not errorlevel 1 ( echo 0.1.0-rc.7 & exit /b 0 )`r`npowershell -NoProfile -ExecutionPolicy Bypass -File `"%~dp0dsh-server.ps1`" %*`r`n")
    [System.IO.File]::WriteAllText((Join-Path $dshDir 'dsh-server.ps1'),
        "param([string]`$Profile='web',[int]`$Port=3080)`r`n" +
        "`$mode=if(Test-Path (Join-Path `$PSScriptRoot 'mode.txt')){(Get-Content (Join-Path `$PSScriptRoot 'mode.txt') -Raw).Trim()}else{'pass'}`r`n" +
        "`$l=[System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback,`$Port); `$l.Start()`r`n" +
        "if(`$mode -eq 'fail'){ Start-Sleep -Milliseconds 500; Write-Error 'plugin tree failed to load'; exit 1 }`r`n" +
        "Write-Output ('dsh web: http://127.0.0.1:{0}' -f `$Port)`r`n" +
        "while(`$true){ `$c=`$l.AcceptTcpClient(); `$s=`$c.GetStream(); `$b=[Text.Encoding]::ASCII.GetBytes(('HTTP/1.1 200 OK' + [char]13 + [char]10 + 'Content-Length: 0' + [char]13 + [char]10 + 'Connection: close' + [char]13 + [char]10 + [char]13 + [char]10)); `$s.Write(`$b,0,`$b.Length); `$s.Close(); `$c.Close() }`r`n")

    $harnessCs = Join-Path $base 'harness.cs'
    $harnessSource = @'
using System;
using System.Diagnostics;
using System.IO;
using System.Net;
using System.Net.Sockets;
using System.Threading;
using DeepSeekHarnessDesktop;

class BootReadyHarness
{
    static int Failures;

    static void Assert(bool condition, string label)
    {
        if (condition) Console.WriteLine("PASS: " + label);
        else { Failures++; Console.WriteLine("FAIL: " + label); }
    }

    static int FreePort()
    {
        TcpListener listener = new TcpListener(IPAddress.Loopback, 0);
        listener.Start();
        int port = ((IPEndPoint)listener.LocalEndpoint).Port;
        listener.Stop();
        return port;
    }

    static bool Open(int port)
    {
        try
        {
            using (TcpClient client = new TcpClient())
            {
                IAsyncResult ar = client.BeginConnect(IPAddress.Loopback, port, null, null);
                if (!ar.AsyncWaitHandle.WaitOne(250)) return false;
                client.EndConnect(ar);
                return true;
            }
        }
        catch { return false; }
    }

    public static int Main(string[] args)
    {
        string baseDir = args[0];
        string dshPath = Path.Combine(baseDir, "dsh", "dsh.cmd");
        string modePath = Path.Combine(baseDir, "dsh", "mode.txt");
        string logsDir = Path.Combine(baseDir, "logs");

        try
        {
            File.WriteAllText(modePath, "fail");
            int failPort = FreePort();
            HostLog.Initialize(logsDir, "boot-ready-fail");
            DshProcessManager failed = new DshProcessManager();
            try
            {
                failed.EnsureStarted(failPort, baseDir, logsDir, "0.1.0-rc.7", "web",
                    dshPath, "command", false);
                Assert(false, "listen then exit=1 is rejected before BootReady");
            }
            catch (InvalidOperationException ex)
            {
                Assert(ex.Message.IndexOf("BootReady", StringComparison.OrdinalIgnoreCase) >= 0 ||
                    ex.Message.IndexOf("插件或 Profile", StringComparison.OrdinalIgnoreCase) >= 0,
                    "listen then exit=1 reports startup failure");
            }
            finally { failed.Dispose(); }
            Assert(!Open(failPort), "failed boot leaves no listening port");
            Assert(!failed.BootReady, "failed boot never sets BootReady");

            File.WriteAllText(modePath, "pass");
            int passPort = FreePort();
            HostLog.Initialize(logsDir, "boot-ready-pass");
            DshProcessManager ready = new DshProcessManager();
            try
            {
                DshProcessManager.BackendStartResult result = ready.EnsureStarted(
                    passPort, baseDir, logsDir, "0.1.0-rc.7", "web", dshPath, "command", false);
                Assert(result != null && result.BootReady, "ready banner + HTTP200 stable returns BootReady");
                Assert(ready.BootReady, "manager BootReady state is true");
                Assert(ready.IsDshHealthy(passPort, 500), "BootReady backend remains healthy");
                Thread.Sleep(700);
                Assert(ready.BootReady && Open(passPort), "stable backend remains alive after BootReady");
            }
            finally { ready.Dispose(); }

            string hostLog = Path.Combine(logsDir, "desktop-shell.log");
            string log = File.Exists(hostLog) ? File.ReadAllText(hostLog) : "";
            Assert(log.IndexOf("READY-BANNER seen", StringComparison.OrdinalIgnoreCase) >= 0,
                "ready banner is logged");
            Assert(log.IndexOf("HTTP200", StringComparison.OrdinalIgnoreCase) >= 0 &&
                log.IndexOf("BOOTREADY", StringComparison.OrdinalIgnoreCase) >= 0,
                "HTTP200 and BootReady confirmation are logged");
        }
        catch (Exception ex)
        {
            Assert(false, "boot-ready harness exception: " + ex.GetType().Name + " " + ex.Message);
        }

        Console.WriteLine(Failures == 0 ? "BOOT READY HARNESS PASSED" : "HARNESS FAILURES: " + Failures);
        return Failures == 0 ? 0 : 1;
    }
}
'@
    [System.IO.File]::WriteAllText($harnessCs, $harnessSource, [System.Text.UTF8Encoding]::new($true))

    $harnessExe = Join-Path $base 'harness.exe'
    & $csc /nologo /target:exe /optimize+ /main:BootReadyHarness "/out:$harnessExe" `
        /reference:System.dll /reference:System.Core.dll /reference:System.Drawing.dll `
        /reference:System.Windows.Forms.dll /reference:System.Web.Extensions.dll `
        "/reference:$($core.FullName)" "/reference:$($winForms.FullName)" `
        (Join-Path $repo 'src\DeepSeekHarness.cs') (Join-Path $repo 'src\HostLog.cs') `
        (Join-Path $repo 'src\NativeTcpTable.cs') $harnessCs 2>&1 | Out-String | Write-Host
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $harnessExe)) { throw 'harness compile failed' }

    $out = & $harnessExe $base 2>&1 | Out-String
    $code = $LASTEXITCODE
    foreach ($line in @($out -split "`r?`n" | Where-Object { $_ -match '^(PASS|FAIL|BOOT|HARNESS)' })) { Write-Host $line }
    if ($code -ne 0) { $fail++ }
}
catch {
    Write-Host "FAIL: boot-ready test setup: $($_.Exception.Message)"
    $fail++
}
finally {
    Remove-Item -LiteralPath $base -Recurse -Force -ErrorAction SilentlyContinue
}

if ($fail -eq 0) { Write-Host 'BOOT READY TESTS PASSED' } else { Write-Host "FAILURES: $fail" }
exit $(if ($fail -eq 0) { 0 } else { 1 })
