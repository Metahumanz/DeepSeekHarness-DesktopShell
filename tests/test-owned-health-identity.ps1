$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$sourceText = [System.IO.File]::ReadAllText((Join-Path $repo 'src\DeepSeekHarness.cs'))
$base = Join-Path $env:TEMP ('dsh-owned-health-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $base | Out-Null

$fail = 0
function Assert-True([string]$label, [bool]$condition) {
    if ($condition) { Write-Host "PASS: $label" }
    else { $script:fail++; Write-Host "FAIL: $label" }
}

Assert-True 'owned health checks current listener PID' ($sourceText -match 'ownedListenerPid > 0 && currentPid == ownedListenerPid')
Assert-True 'owned health accepts only own Job as alternate identity' ($sourceText -match 'return IsProcessInOwnedJob\(currentPid\)')
Assert-True 'health identity helper exists' ($sourceText -match 'private bool IsProcessInOwnedJob\(int pid\)')
Assert-True 'health path still uses NativeTcpTable first' ($sourceText -match 'TcpTableHelper\.FindListeningPidNative\(port\)')

try {
    $csc = @(
        "$env:WINDIR\Microsoft.NET\Framework64\v4.0.30319\csc.exe",
        "$env:WINDIR\Microsoft.NET\Framework\v4.0.30319\csc.exe"
    ) | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
    if (-not $csc) { throw 'csc not found' }

    $sdkRoot = Join-Path $env:USERPROFILE '.nuget\packages\microsoft.web.webview2\1.0.4078.44'
    $core = $null; $winForms = $null
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
        "`$l=[System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback,`$Port); `$l.Start()`r`n" +
        "[IO.File]::WriteAllText((Join-Path `$PSScriptRoot 'listener.pid'),[string]`$PID)`r`n" +
        "Write-Output ('dsh web: http://127.0.0.1:{0}' -f `$Port)`r`n" +
        "while(`$true){ `$c=`$l.AcceptTcpClient(); `$s=`$c.GetStream(); `$b=[Text.Encoding]::ASCII.GetBytes(('HTTP/1.1 200 OK' + [char]13 + [char]10 + 'Content-Length: 0' + [char]13 + [char]10 + 'Connection: close' + [char]13 + [char]10 + [char]13 + [char]10)); `$s.Write(`$b,0,`$b.Length); `$s.Close(); `$c.Close() }`r`n")

    $harnessCs = Join-Path $base 'health-harness.cs'
    $harnessSource = @'
using System;
using System.Diagnostics;
using System.IO;
using System.Net;
using System.Net.Sockets;
using System.Threading;
using DeepSeekHarnessDesktop;

class HealthHarness
{
    static int Failures;
    static void Assert(bool condition, string label)
    {
        if (condition) Console.WriteLine("PASS: " + label);
        else { Failures++; Console.WriteLine("FAIL: " + label); }
    }

    static int FreePort()
    {
        TcpListener l = new TcpListener(IPAddress.Loopback, 0);
        l.Start();
        int port = ((IPEndPoint)l.LocalEndpoint).Port;
        l.Stop();
        return port;
    }

    static bool Open(int port)
    {
        try
        {
            using (TcpClient c = new TcpClient())
            {
                IAsyncResult ar = c.BeginConnect(IPAddress.Loopback, port, null, null);
                if (!ar.AsyncWaitHandle.WaitOne(200)) return false;
                c.EndConnect(ar);
                return true;
            }
        }
        catch { return false; }
    }

    static int ReadPid(string path)
    {
        try { return Int32.Parse(File.ReadAllText(path).Trim()); }
        catch { return -1; }
    }

    public static int Main(string[] args)
    {
        string baseDir = args[0];
        string dsh = Path.Combine(baseDir, "dsh", "dsh.cmd");
        string logs = Path.Combine(baseDir, "logs");
        int port = FreePort();
        HostLog.Initialize(logs, "owned-health-harness");
        DshProcessManager manager = new DshProcessManager();
        try
        {
            DshProcessManager.BackendStartResult result = manager.EnsureStarted(
                port, baseDir, logs, "0.1.0-rc.7", "web", dsh, "command", false);
            Assert(result != null && manager.OwnsBackend, "owned listener setup starts");
            Assert(manager.OwnedListenerPid > 0, "owned listener pid recorded");
            Assert(manager.IsDshHealthy(port, 500), "owned listener normal is healthy");

            int ownedPid = manager.OwnedListenerPid;
            try { Process.GetProcessById(ownedPid).Kill(); } catch { }
            Stopwatch wait = Stopwatch.StartNew();
            while (wait.ElapsedMilliseconds < 3000 && Open(port)) Thread.Sleep(50);
            Assert(!Open(port), "listener disappearance closes port");
            Assert(!manager.IsDshHealthy(port, 500), "listener disappearance is unhealthy");

            TcpListener foreign = new TcpListener(IPAddress.Loopback, port);
            foreign.Start();
            try
            {
                Assert(Open(port), "foreign process takes over port");
                Assert(!manager.IsDshHealthy(port, 500), "foreign takeover is unhealthy");
            }
            finally { foreign.Stop(); }
        }
        catch (Exception ex)
        {
            Assert(false, "health harness exception: " + ex.GetType().Name + " " + ex.Message);
        }
        finally
        {
            try { manager.StopOwnedBackend(); } catch { }
            manager.Dispose();
        }
        Console.WriteLine(Failures == 0 ? "OWNED HEALTH HARNESS PASSED" : "HARNESS FAILURES: " + Failures);
        return Failures == 0 ? 0 : 1;
    }
}
'@
    [System.IO.File]::WriteAllText($harnessCs, $harnessSource, [System.Text.UTF8Encoding]::new($true))
    $harnessExe = Join-Path $base 'health-harness.exe'
    & $csc /nologo /target:exe /optimize+ /main:HealthHarness "/out:$harnessExe" `
        /reference:System.dll /reference:System.Core.dll /reference:System.Drawing.dll `
        /reference:System.Windows.Forms.dll /reference:System.Web.Extensions.dll `
        "/reference:$($core.FullName)" "/reference:$($winForms.FullName)" `
        (Join-Path $repo 'src\DeepSeekHarness.cs') (Join-Path $repo 'src\HostLog.cs') `
        (Join-Path $repo 'src\NativeTcpTable.cs') $harnessCs 2>&1 | Out-String | Write-Host
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $harnessExe)) { throw 'harness compile failed' }
    $out = & $harnessExe $base 2>&1 | Out-String
    $code = $LASTEXITCODE
    foreach ($line in @($out -split "`r?`n" | Where-Object { $_ -match '^(PASS|FAIL|OWNED|HARNESS)' })) { Write-Host $line }
    if ($code -ne 0) { $fail++ }
}
catch {
    Write-Host "FAIL: owned health test setup: $($_.Exception.Message)"
    $fail++
}
finally {
    Remove-Item -LiteralPath $base -Recurse -Force -ErrorAction SilentlyContinue
}

if ($fail -eq 0) { Write-Host 'OWNED HEALTH IDENTITY TESTS PASSED' } else { Write-Host "FAILURES: $fail" }
exit $(if ($fail -eq 0) { 0 } else { 1 })
