$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$base = Join-Path $env:TEMP ('dsh-bounded-probe-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $base | Out-Null

$fail = 0
function Assert-True([string]$label, [bool]$condition) {
    if ($condition) { Write-Host "PASS: $label" }
    else { $script:fail++; Write-Host "FAIL: $label" }
}

$sourceText = [System.IO.File]::ReadAllText((Join-Path $repo 'src\DeepSeekHarness.cs'))
Assert-True 'probe helper exists' ($sourceText -match 'RunCapturedProcessBounded')
Assert-True 'probe code has no direct unbounded ReadToEnd call' ($sourceText -notmatch '\.ReadToEnd\(')
Assert-True 'probe cleanup is PID/tree based' ($sourceText -match 'Arguments = "/PID "' -and $sourceText -notmatch '/IM\s+(node|cmd|powershell)')
Assert-True 'all four probe paths use bounded helper' (([regex]::Matches($sourceText, 'RunCapturedProcessBounded\(')).Count -ge 5)

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

    [System.IO.File]::WriteAllText((Join-Path $base 'short.cmd'), "@echo off`r`necho STDOUT`r`necho STDERR 1>&2`r`nexit /b 0`r`n")
    [System.IO.File]::WriteAllText((Join-Path $base 'hang.cmd'), "@echo off`r`npowershell -NoProfile -ExecutionPolicy Bypass -File `"%~dp0hang-child.ps1`" `"%~dp0child.pid`"`r`n")
    [System.IO.File]::WriteAllText((Join-Path $base 'hang-child.ps1'), "param([string]`$pidPath)`r`n[IO.File]::WriteAllText(`$pidPath,[string]`$PID)`r`nStart-Sleep -Seconds 60`r`n")

    $harnessCs = Join-Path $base 'probe-harness.cs'
    $harnessSource = @'
using System;
using System.Diagnostics;
using System.IO;
using System.Threading;
using DeepSeekHarnessDesktop;

class ProbeHarness
{
    static int Failures;
    static void Assert(bool condition, string label)
    {
        if (condition) Console.WriteLine("PASS: " + label);
        else { Failures++; Console.WriteLine("FAIL: " + label); }
    }

    static ProcessStartInfo Cmd(string script)
    {
        ProcessStartInfo psi = new ProcessStartInfo();
        psi.FileName = Environment.GetEnvironmentVariable("ComSpec") ?? "cmd.exe";
        psi.Arguments = "/d /s /c \"\"" + script + "\"\"";
        psi.UseShellExecute = false;
        psi.CreateNoWindow = true;
        return psi;
    }

    static bool Alive(int pid)
    {
        if (pid <= 0) return false;
        try { using (Process p = Process.GetProcessById(pid)) return !p.HasExited; }
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
        string stdout;
        string stderr;
        bool shortOk = DshProcessManager.RunCapturedProcessBounded(
            Cmd(Path.Combine(baseDir, "short.cmd")), 5000, out stdout, out stderr);
        Assert(shortOk, "short command succeeds");
        Assert(stdout.IndexOf("STDOUT", StringComparison.OrdinalIgnoreCase) >= 0, "stdout is captured");
        Assert(stderr.IndexOf("STDERR", StringComparison.OrdinalIgnoreCase) >= 0, "stderr is captured");

        Process globalNode = null;
        try
        {
            string nodePath = Path.Combine(baseDir, "node.exe");
            File.Copy(Path.Combine(Environment.SystemDirectory, "cmd.exe"), nodePath, true);
            globalNode = Process.Start(nodePath, "/d /s /c \"ping -n 30 127.0.0.1 >nul\"");

            Stopwatch sw = Stopwatch.StartNew();
            bool timeoutResult = DshProcessManager.RunCapturedProcessBounded(
                Cmd(Path.Combine(baseDir, "hang.cmd")), 800, out stdout, out stderr);
            sw.Stop();
            Assert(!timeoutResult, "timeout is not reported as success");
            Assert(sw.ElapsedMilliseconds < 8000, "timeout is bounded (" + sw.ElapsedMilliseconds + "ms)");

            Stopwatch childWait = Stopwatch.StartNew();
            int childPid = -1;
            while (childWait.ElapsedMilliseconds < 3000 && childPid <= 0)
            {
                childPid = ReadPid(Path.Combine(baseDir, "child.pid"));
                if (childPid <= 0) Thread.Sleep(25);
            }
            Thread.Sleep(500);
            Assert(childPid > 0, "timeout parent created a child process");
            Assert(!Alive(childPid), "timeout kills child process tree");
            Assert(globalNode != null && Alive(globalNode.Id), "unrelated node.exe process survives");
        }
        finally
        {
            try { if (globalNode != null && !globalNode.HasExited) globalNode.Kill(); } catch { }
            try { if (globalNode != null) globalNode.WaitForExit(2000); } catch { }
            try { if (globalNode != null) globalNode.Dispose(); } catch { }
        }

        Console.WriteLine(Failures == 0 ? "BOUNDED PROCESS PROBE HARNESS PASSED" : "HARNESS FAILURES: " + Failures);
        return Failures == 0 ? 0 : 1;
    }
}
'@
    [System.IO.File]::WriteAllText($harnessCs, $harnessSource, [System.Text.UTF8Encoding]::new($true))

    $harnessExe = Join-Path $base 'probe-harness.exe'
    & $csc /nologo /target:exe /optimize+ /main:ProbeHarness "/out:$harnessExe" `
        /reference:System.dll /reference:System.Core.dll /reference:System.Drawing.dll `
        /reference:System.Windows.Forms.dll /reference:System.Web.Extensions.dll `
        "/reference:$($core.FullName)" "/reference:$($winForms.FullName)" `
        (Join-Path $repo 'src\DeepSeekHarness.cs') (Join-Path $repo 'src\HostLog.cs') `
        (Join-Path $repo 'src\NativeTcpTable.cs') $harnessCs 2>&1 | Out-String | Write-Host
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $harnessExe)) { throw 'harness compile failed' }

    $out = & $harnessExe $base 2>&1 | Out-String
    $code = $LASTEXITCODE
    foreach ($line in @($out -split "`r?`n" | Where-Object { $_ -match '^(PASS|FAIL|BOUNDED|HARNESS)' })) { Write-Host $line }
    if ($code -ne 0) { $fail++ }
}
catch {
    Write-Host "FAIL: bounded probe test setup: $($_.Exception.Message)"
    $fail++
}
finally {
    Remove-Item -LiteralPath $base -Recurse -Force -ErrorAction SilentlyContinue
}

if ($fail -eq 0) { Write-Host 'BOUNDED PROCESS PROBE TESTS PASSED' } else { Write-Host "FAILURES: $fail" }
exit $(if ($fail -eq 0) { 0 } else { 1 })
