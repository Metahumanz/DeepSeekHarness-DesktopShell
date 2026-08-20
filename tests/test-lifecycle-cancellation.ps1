$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$base = Join-Path $env:TEMP ('dsh-lifecycle-cancel-' + [guid]::NewGuid().ToString('N'))
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
    if (-not $core -or -not $winForms) {
        $download = Join-Path $base 'webview2'
        New-Item -ItemType Directory -Force -Path $download | Out-Null
        $nupkg = Join-Path $download 'webview2.zip'
        Invoke-WebRequest -UseBasicParsing -Uri 'https://www.nuget.org/api/v2/package/Microsoft.Web.WebView2/1.0.4078.44' -OutFile $nupkg -TimeoutSec 120
        Expand-Archive -LiteralPath $nupkg -DestinationPath (Join-Path $download 'pkg') -Force
        $core = Get-ChildItem (Join-Path $download 'pkg') -Recurse -Filter 'Microsoft.Web.WebView2.Core.dll' |
            Where-Object { $_.FullName -match '[\\/]lib[\\/]' } | Select-Object -First 1
        $winForms = Get-ChildItem (Join-Path $download 'pkg') -Recurse -Filter 'Microsoft.Web.WebView2.WinForms.dll' |
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
        "[IO.File]::WriteAllText((Join-Path `$PSScriptRoot 'listener.pid'), [string]`$PID)`r`n" +
        "`$delay=0; `$delayFile=Join-Path `$PSScriptRoot 'delay-ms.txt'`r`n" +
        "if(Test-Path `$delayFile){ `$delay=[int](Get-Content `$delayFile -Raw) }`r`n" +
        "if(`$delay -gt 0){ Start-Sleep -Milliseconds `$delay }`r`n" +
        "`$l=[System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback,`$Port); `$l.Start()`r`n" +
        "while(`$true){ Start-Sleep -Seconds 1 }`r`n")
    [System.IO.File]::WriteAllText((Join-Path $dshDir 'delay-ms.txt'), '5000')

    $harnessCs = Join-Path $base 'harness.cs'
    $harnessSource = @'
using System;
using System.Diagnostics;
using System.IO;
using System.Net;
using System.Net.Sockets;
using System.Threading;
using DeepSeekHarnessDesktop;

class Harness
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

    static bool PortOpen(int port)
    {
        try
        {
            using (TcpClient client = new TcpClient())
            {
                IAsyncResult ar = client.BeginConnect(IPAddress.Loopback, port, null, null);
                if (!ar.AsyncWaitHandle.WaitOne(150)) return false;
                client.EndConnect(ar);
                return true;
            }
        }
        catch { return false; }
    }

    static bool Alive(int pid)
    {
        if (pid <= 0) return false;
        try
        {
            using (Process p = Process.GetProcessById(pid)) return !p.HasExited;
        }
        catch { return false; }
    }

    static int ReadPid(string path)
    {
        try { return Int32.Parse(File.ReadAllText(path).Trim()); }
        catch { return -1; }
    }

    static int LaunchCount(string logsDir)
    {
        int count = 0;
        try
        {
            foreach (string path in Directory.GetFiles(logsDir, "dsh-*.log"))
                count += File.ReadAllText(path).Split(new string[] { "Launching:" }, StringSplitOptions.None).Length - 1;
        }
        catch { }
        return count;
    }

    static void CancelAfterWrapper(DshProcessManager manager, CancellationTokenSource cts, int delayMs, int[] observed)
    {
        Stopwatch timer = Stopwatch.StartNew();
        while (timer.ElapsedMilliseconds < 10000 && manager.WrapperPid <= 0) Thread.Sleep(10);
        observed[0] = manager.WrapperPid;
        Thread.Sleep(delayMs);
        cts.Cancel();
    }

    public static int Main(string[] args)
    {
        string baseDir = args[0];
        string dshPath = Path.Combine(baseDir, "dsh", "dsh.cmd");
        string logsDir = Path.Combine(baseDir, "logs");
        string delayFile = Path.Combine(baseDir, "dsh", "delay-ms.txt");
        string pidFile = Path.Combine(baseDir, "dsh", "listener.pid");

        int startPort = FreePort();
        HostLog.Initialize(logsDir, "lifecycle-cancel-start");
        DshProcessManager startManager = new DshProcessManager();
        CancellationTokenSource startCts = new CancellationTokenSource();
        int[] startWrapper = new int[] { -1 };
        Thread startCanceller = new Thread(new ThreadStart(delegate { CancelAfterWrapper(startManager, startCts, 200, startWrapper); }));
        startCanceller.Start();
        try
        {
            startManager.EnsureStarted(startPort, baseDir, logsDir, "0.1.0-rc.7", "web", dshPath, "command", false, startCts.Token);
            Assert(false, "start cancellation throws");
        }
        catch (OperationCanceledException) { Assert(true, "start cancellation throws normally"); }
        catch (Exception ex) { Assert(false, "start cancellation type: " + ex.GetType().Name + " " + ex.Message); }
        finally
        {
            startCanceller.Join(10000);
            startManager.Dispose();
        }
        Thread.Sleep(500);
        int delayedPid = ReadPid(pidFile);
        Assert(!PortOpen(startPort), "cancelled start leaves no listening port");
        Assert(!Alive(startWrapper[0]), "cancelled start wrapper exits");
        Assert(!Alive(delayedPid), "cancelled start listener child exits");

        int restartPort = FreePort();
        File.WriteAllText(delayFile, "0");
        HostLog.Initialize(logsDir, "lifecycle-cancel-restart");
        DshProcessManager restartManager = new DshProcessManager();
        DshProcessManager.BackendStartResult initial = restartManager.EnsureStarted(
            restartPort, baseDir, logsDir, "0.1.0-rc.7", "web", dshPath, "command", false);
        Assert(initial != null && restartManager.OwnsBackend, "restart setup backend starts");
        restartManager.StopOwnedBackend();
        File.WriteAllText(delayFile, "5000");

        CancellationTokenSource restartCts = new CancellationTokenSource();
        int[] restartWrapper = new int[] { -1 };
        Thread restartCanceller = new Thread(new ThreadStart(delegate { CancelAfterWrapper(restartManager, restartCts, 200, restartWrapper); }));
        restartCanceller.Start();
        try
        {
            restartManager.RestartBackend(restartPort, baseDir, logsDir, "0.1.0-rc.7", "web", dshPath, "command", false, restartCts.Token);
            Assert(false, "restart cancellation throws");
        }
        catch (OperationCanceledException) { Assert(true, "restart cancellation throws normally"); }
        catch (Exception ex) { Assert(false, "restart cancellation type: " + ex.GetType().Name + " " + ex.Message); }
        finally
        {
            restartCanceller.Join(10000);
            restartManager.Dispose();
        }
        Thread.Sleep(500);
        int restartPid = ReadPid(pidFile);
        Assert(!PortOpen(restartPort), "cancelled restart leaves no listening port");
        Assert(!Alive(restartWrapper[0]), "cancelled restart wrapper exits");
        Assert(!Alive(restartPid), "cancelled restart listener child exits");

        int launchesBefore = LaunchCount(logsDir);
        try
        {
            restartManager.EnsureStarted(restartPort, baseDir, logsDir, "0.1.0-rc.7", "web", dshPath, "command", false, restartCts.Token);
        }
        catch (OperationCanceledException) { }
        Assert(LaunchCount(logsDir) == launchesBefore, "cancelled lifetime prevents subsequent start");

        Console.WriteLine(Failures == 0 ? "LIFECYCLE CANCELLATION HARNESS PASSED" : "HARNESS FAILURES: " + Failures);
        return Failures == 0 ? 0 : 1;
    }
}
'@
    [System.IO.File]::WriteAllText($harnessCs, $harnessSource, [System.Text.UTF8Encoding]::new($true))

    $harnessExe = Join-Path $base 'harness.exe'
    & $csc /nologo /target:exe /optimize+ /main:Harness "/out:$harnessExe" `
        /reference:System.dll /reference:System.Core.dll /reference:System.Drawing.dll `
        /reference:System.Windows.Forms.dll /reference:System.Web.Extensions.dll `
        "/reference:$($core.FullName)" "/reference:$($winForms.FullName)" `
        (Join-Path $repo 'src\DeepSeekHarness.cs') (Join-Path $repo 'src\HostLog.cs') `
        (Join-Path $repo 'src\NativeTcpTable.cs') $harnessCs 2>&1 | Out-String | Write-Host
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $harnessExe)) { throw 'harness compile failed' }

    $out = & $harnessExe $base 2>&1 | Out-String
    $code = $LASTEXITCODE
    foreach ($line in @($out -split "`r?`n" | Where-Object { $_ -match '^(PASS|FAIL|LIFECYCLE|HARNESS)' })) { Write-Host $line }
    if ($code -ne 0) { $fail++ }
}
catch {
    Write-Host "FAIL: lifecycle cancellation test setup: $($_.Exception.Message)"
    $fail++
}
finally {
    Remove-Item -LiteralPath $base -Recurse -Force -ErrorAction SilentlyContinue
}

if ($fail -eq 0) { Write-Host 'LIFECYCLE CANCELLATION TESTS PASSED' } else { Write-Host "FAILURES: $fail" }
exit $(if ($fail -eq 0) { 0 } else { 1 })
