$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$base = Join-Path $env:TEMP ('dsh-generation-race-' + [guid]::NewGuid().ToString('N'))
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

    # WebView2 引用：NuGet 缓存优先，否则下载固定版本；不下载 DSH/npm。
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
        $download = Join-Path $base 'wv2'
        New-Item -ItemType Directory -Force -Path $download | Out-Null
        $nupkg = Join-Path $download 'wv2.zip'
        Invoke-WebRequest -UseBasicParsing `
            -Uri 'https://www.nuget.org/api/v2/package/Microsoft.Web.WebView2/1.0.4078.44' `
            -OutFile $nupkg -TimeoutSec 120
        Expand-Archive -LiteralPath $nupkg -DestinationPath (Join-Path $download 'pkg') -Force
        $core = Get-ChildItem (Join-Path $download 'pkg') -Recurse -Filter 'Microsoft.Web.WebView2.Core.dll' |
            Where-Object { $_.FullName -match '[\\/]lib[\\/]' } | Select-Object -First 1
        $winForms = Get-ChildItem (Join-Path $download 'pkg') -Recurse -Filter 'Microsoft.Web.WebView2.WinForms.dll' |
            Where-Object { $_.FullName -match '[\\/]lib[\\/]' } | Select-Object -First 1
    }
    if (-not $core -or -not $winForms) { throw 'WebView2 reference assemblies not found after cache/download fallback' }

    $dshDir = Join-Path $base 'dsh'
    $logsDir = Join-Path $base 'logs'
    New-Item -ItemType Directory -Force -Path $dshDir, $logsDir | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $dshDir 'dsh.cmd'),
        "@echo off`r`nsetlocal`r`necho %*|findstr /C:`"--help`" >nul`r`nif not errorlevel 1 ( echo --no-open & exit /b 0 )`r`necho %*|findstr /C:`"--version`" >nul`r`nif not errorlevel 1 ( echo 0.1.0-rc.7 & exit /b 0 )`r`npowershell -NoProfile -ExecutionPolicy Bypass -File `"%~dp0dsh-server.ps1`" %*`r`n")
    [System.IO.File]::WriteAllText((Join-Path $dshDir 'dsh-server.ps1'),
        "param([string]`$Profile='web',[int]`$Port=3080)`r`n" +
        "`$counterFile=Join-Path `$PSScriptRoot 'launch-count.txt'`r`n" +
        "`$n=1; if(Test-Path `$counterFile){ `$n=[int](Get-Content `$counterFile -Raw)+1 }; Set-Content `$counterFile `$n`r`n" +
        "`$label=if(`$n -eq 1){'OLD'}else{'NEW'}`r`n" +
        "`$l=[System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback,`$Port); `$l.Start()`r`n" +
        "Write-Output ('dsh web: http://127.0.0.1:{0}' -f `$Port)`r`n" +
        "Write-Output (`$label + ' stdout ready')`r`n" +
        "[Console]::Error.WriteLine(`$label + ' stderr ready')`r`n" +
        "while(`$true){ `$c=`$l.AcceptTcpClient(); `$s=`$c.GetStream(); `$b=[Text.Encoding]::ASCII.GetBytes(('HTTP/1.1 200 OK' + [char]13 + [char]10 + 'Content-Length: 0' + [char]13 + [char]10 + 'Connection: close' + [char]13 + [char]10 + [char]13 + [char]10)); `$s.Write(`$b,0,`$b.Length); `$s.Close(); `$c.Close() }`r`n")

    $harnessCs = Join-Path $base 'harness.cs'
    $harnessSource = @'
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Net;
using System.Net.Sockets;
using System.Reflection;
using DeepSeekHarnessDesktop;

class GenerationRaceHarness
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

    static object CurrentRun(DshProcessManager manager)
    {
        FieldInfo field = typeof(DshProcessManager).GetField(
            "currentRun", BindingFlags.Instance | BindingFlags.NonPublic);
        return field == null ? null : field.GetValue(manager);
    }

    static long Generation(object run)
    {
        if (run == null) return -1;
        FieldInfo field = run.GetType().GetField("Generation", BindingFlags.Instance | BindingFlags.Public);
        return field == null ? -1 : (long)field.GetValue(run);
    }

    static int RunCount(DshProcessManager manager)
    {
        FieldInfo field = typeof(DshProcessManager).GetField(
            "backendRuns", BindingFlags.Instance | BindingFlags.NonPublic);
        System.Collections.IList runs = field == null ? null : field.GetValue(manager) as System.Collections.IList;
        return runs == null ? -1 : runs.Count;
    }

    static int WaitForRunCountAtMost(DshProcessManager manager, int max, int timeoutMs)
    {
        Stopwatch watch = Stopwatch.StartNew();
        int count = RunCount(manager);
        while (watch.ElapsedMilliseconds < timeoutMs && count > max)
        {
            System.Threading.Thread.Sleep(25);
            count = RunCount(manager);
        }
        return count;
    }

    static void DispatchDelayedExit(DshProcessManager manager, object oldRun)
    {
        MethodInfo callback = null;
        foreach (MethodInfo method in typeof(DshProcessManager).GetMethods(
            BindingFlags.Instance | BindingFlags.NonPublic))
        {
            ParameterInfo[] parameters = method.GetParameters();
            if (method.Name == "OnProcessExited" && parameters.Length == 1 &&
                parameters[0].ParameterType.Name == "BackendRun")
            {
                callback = method;
                break;
            }
        }
        if (callback == null) throw new InvalidOperationException("generation-aware exit callback not found");
        // 两代都是真实 fake DSH 进程；这里把旧代 OS callback 延迟到新代 BootReady 之后
        // 调入同一个生产回调，以稳定复现 Process.Exited 调度竞态，而不是做源码正则断言。
        callback.Invoke(manager, new object[] { oldRun });
    }

    public static int Main(string[] args)
    {
        string baseDir = args[0];
        string dshPath = Path.Combine(baseDir, "dsh", "dsh.cmd");
        string logsDir = Path.Combine(baseDir, "logs");
        int oldPort = FreePort();
        int newPort = FreePort();
        HostLog.Initialize(logsDir, "generation-race");
        DshProcessManager manager = new DshProcessManager();
        List<long> exitGenerations = new List<long>();
        manager.BackendProcessExited += delegate(object sender, BackendProcessExitedEventArgs e)
        {
            exitGenerations.Add(e.Generation);
        };

        try
        {
            DshProcessManager.BackendStartResult oldResult = manager.EnsureStarted(
                oldPort, baseDir, logsDir, "0.1.0-rc.7", "old", dshPath, "command", false);
            object oldRun = CurrentRun(manager);
            long oldGeneration = Generation(oldRun);
            int oldWrapper = oldResult.WrapperPid;
            Assert(oldResult.BootReady && manager.BootReady, "old backend reaches BootReady");
            Assert(oldGeneration > 0 && oldWrapper > 0, "old backend has an independent generation and wrapper PID");

            // No artificial wait: stop the old real process and immediately start the new real process.
            manager.StopOwnedBackend();
            DshProcessManager.BackendStartResult newResult = manager.EnsureStarted(
                newPort, baseDir, logsDir, "0.1.0-rc.7", "new", dshPath, "command", false);
            object newRun = CurrentRun(manager);
            long newGeneration = Generation(newRun);
            Assert(newResult.BootReady && manager.BootReady, "new backend reaches BootReady immediately after old stop");
            Assert(newGeneration > oldGeneration, "new backend receives a distinct generation");
            Assert(manager.BackendState == "Running", "new backend state is Running before delayed old Exited");

            int exitsBeforeDelayedOld = exitGenerations.Count;
            DispatchDelayedExit(manager, oldRun);
            Assert(exitGenerations.Count == exitsBeforeDelayedOld,
                "delayed old Exited does not raise a new-generation interruption event");
            Assert(manager.BootReady && manager.BackendState == "Running",
                "delayed old Exited cannot clear new BootReady/BackendState");
            Assert(manager.WrapperPid == newResult.WrapperPid && manager.OwnedPort == newPort,
                "delayed old Exited cannot replace new wrapper/port identity");
            string summary = manager.GetRecentFailureSummary();
            Assert(summary.IndexOf("NEW stdout ready", StringComparison.OrdinalIgnoreCase) >= 0,
                "current recent output belongs to the new backend run");
            Assert(summary.IndexOf("OLD stdout ready", StringComparison.OrdinalIgnoreCase) < 0,
                "old recent output is not mixed into the new backend run");

            string hostLog = Path.Combine(logsDir, "desktop-shell.log");
            string log = File.Exists(hostLog) ? File.ReadAllText(hostLog) : "";
            Assert(log.IndexOf("ignored=true", StringComparison.OrdinalIgnoreCase) >= 0 &&
                log.IndexOf("generation=" + oldGeneration.ToString(), StringComparison.OrdinalIgnoreCase) >= 0,
                "delayed old Exited is logged as ignored with its own generation");
            Assert(log.IndexOf("generation=" + newGeneration.ToString(), StringComparison.OrdinalIgnoreCase) >= 0,
                "new generation diagnostics remain present");

            int maxRunCount = RunCount(manager);
            int cyclePort = newPort;
            for (int cycle = 1; cycle <= 25; cycle++)
            {
                manager.StopOwnedBackend();
                cyclePort = FreePort();
                DshProcessManager.BackendStartResult cycleResult = manager.EnsureStarted(
                    cyclePort, baseDir, logsDir, "0.1.0-rc.7", "cycle" + cycle.ToString(),
                    dshPath, "command", false);
                int count = WaitForRunCountAtMost(manager, 2, 3000);
                if (count > maxRunCount) maxRunCount = count;
                Assert(cycleResult.BootReady && manager.BootReady && manager.BackendRunning,
                    "restart cycle " + cycle.ToString() + " current backend remains healthy");
                Assert(count <= 2,
                    "restart cycle " + cycle.ToString() + " run contexts stay bounded (count=" + count.ToString() + ")");
            }
            Assert(maxRunCount <= 2,
                "25 restart cycles keep historical BackendRun contexts bounded (max=" + maxRunCount.ToString() + ")");
            Assert(manager.IsDshHealthy(cyclePort, 500),
                "current backend remains healthy after 25 restart cycles");
        }
        catch (Exception ex)
        {
            Assert(false, "generation race harness exception: " + ex.GetType().Name + " " + ex.Message);
        }
        finally { manager.Dispose(); }

        Console.WriteLine(Failures == 0 ? "BACKEND GENERATION RACE HARNESS PASSED" :
            "HARNESS FAILURES: " + Failures);
        return Failures == 0 ? 0 : 1;
    }
}
'@
    [System.IO.File]::WriteAllText($harnessCs, $harnessSource, [System.Text.UTF8Encoding]::new($true))

    $harnessExe = Join-Path $base 'harness.exe'
    & $csc /nologo /target:exe /optimize+ /main:GenerationRaceHarness "/out:$harnessExe" `
        /reference:System.dll /reference:System.Core.dll /reference:System.Drawing.dll `
        /reference:System.Windows.Forms.dll /reference:System.Web.Extensions.dll `
        "/reference:$($core.FullName)" "/reference:$($winForms.FullName)" `
        (Join-Path $repo 'src\DeepSeekHarness.cs') (Join-Path $repo 'src\HostLog.cs') `
        (Join-Path $repo 'src\NativeTcpTable.cs') $harnessCs 2>&1 | Out-String | Write-Host
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $harnessExe)) { throw 'harness compile failed' }

    $out = & $harnessExe $base 2>&1 | Out-String
    $code = $LASTEXITCODE
    foreach ($line in @($out -split "`r?`n" | Where-Object { $_ -match '^(PASS|FAIL|BACKEND|HARNESS)' })) { Write-Host $line }
    if ($code -ne 0) { $fail++ }
}
catch {
    Write-Host "FAIL: generation race test setup: $($_.Exception.Message)"
    $fail++
}
finally {
    Remove-Item -LiteralPath $base -Recurse -Force -ErrorAction SilentlyContinue
}

if ($fail -eq 0) { Write-Host 'BACKEND GENERATION RACE TESTS PASSED' }
else { Write-Host "FAILURES: $fail" }
exit $(if ($fail -eq 0) { 0 } else { 1 })
