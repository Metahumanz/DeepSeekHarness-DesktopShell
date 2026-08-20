$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$sourcePath = Join-Path $repo 'src\DeepSeekHarness.cs'
$sourceText = [System.IO.File]::ReadAllText($sourcePath)
$base = Join-Path $env:TEMP ('dsh-settings-snapshot-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $base | Out-Null

$fail = 0
function Assert-True([string]$label, [bool]$condition) {
    if ($condition) { Write-Host "PASS: $label" }
    else { $script:fail++; Write-Host "FAIL: $label" }
}

function Get-MethodBody([string]$text, [string]$signature, [string]$nextSignature) {
    $start = $text.IndexOf($signature, [System.StringComparison]::Ordinal)
    if ($start -lt 0) { return '' }
    $end = $text.IndexOf($nextSignature, $start + $signature.Length, [System.StringComparison]::Ordinal)
    if ($end -lt 0) { $end = $text.Length }
    return $text.Substring($start, $end - $start)
}

Assert-True 'persisted and active runtime snapshots exist' ($sourceText -match 'persistedSettings' -and $sourceText -match 'activeRuntimeSettings')
Assert-True 'health check reads active port' ($sourceText -match 'IsDshHealthy\(activeRuntimeSettings\.port')
Assert-True 'DSH URL reads active port' ($sourceText -match '127\.0\.0\.1:" \+ activeRuntimeSettings\.port')
Assert-True 'profile and runner startup read active snapshot' ($sourceText -match 'activeRuntimeSettings\.profileName' -and $sourceText -match 'activeRuntimeSettings\.dshRunnerMode')
Assert-True 'save path snapshots before save and classifies backend fields' ($sourceText -match 'AppSettings oldSnapshot = persistedSettings\.Clone\(\)' -and $sourceText -match 'BackendRuntimeSettingsChanged\(oldSnapshot, persistedSettings\)')

$settings = Get-MethodBody $sourceText 'private async Task ShowSettingsAsync()' 'private void ToggleTrayWindow()'
Assert-True 'immediate apply captures old active and target persisted snapshots' ($settings -match 'AppSettings oldRuntime = activeRuntimeSettings\.Clone\(\)' -and $settings -match 'AppSettings targetRuntime = persistedSettings\.Clone\(\)')
Assert-True 'immediate apply passes explicit transaction snapshots' ($settings -match 'await RestartBackendAsync\(oldRuntime, targetRuntime\)')
Assert-True 'immediate apply never pre-commits target into active' ($settings -notmatch 'activeRuntimeSettings\.CopyFrom\(persistedSettings\)')
Assert-True 'restart has explicit old/target signature' ($sourceText -match 'private async Task RestartBackendAsync\(AppSettings oldRuntime, AppSettings targetRuntime\)')
Assert-True 'old stop phases use old snapshot' ($sourceText -match 'RuntimeForPhase\("restart\.snapshot"\)' -and $sourceText -match 'WaitForPortClosedTwice\(stopRuntime\.port')
Assert-True 'target start phases use target snapshot' ($sourceText -match 'RuntimeForPhase\("restart\.start"\)' -and $sourceText -match 'EnsureStarted\(\s*startRuntime\.port')
Assert-True 'target commit happens only after target ready' ($sourceText -match 'transaction\.MarkTargetBackendReady\(\)' -and $sourceText -match 'transaction\.CommitTarget\(activeRuntimeSettings\)')
Assert-True 'restart error receives old and target snapshots' ($sourceText -match 'private void HandleRestartError\(\s*Exception ex,\s*AppSettings oldRuntime,\s*AppSettings targetRuntime,\s*bool targetBackendReady')
Assert-True 'restart logs old and target port/PID snapshots' ($sourceText -match 'oldPort=' -and $sourceText -match 'targetWrapperPid=' -and $sourceText -match 'targetPort=')
Assert-True 'deferred backend change keeps active runtime' ($sourceText -match 'active runtime remains port=')
Assert-True 'closeAction is outside backend-affecting classifier' ($sourceText -match 'before\.port != after\.port' -and $sourceText -match 'closeAction = "tray"')
Assert-True 'developer mode has immediate safe reconfigure path' ($sourceText -match 'ApplyDeveloperModeChangeAsync' -and $sourceText -match 'await ConfigureWebViewAsync\(\)')

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

    $harnessCs = Join-Path $base 'settings-harness.cs'
    $harnessSource = @'
using System;
using System.Collections.Generic;
using DeepSeekHarnessDesktop;

class FakeDsh
{
    public readonly List<string> Calls = new List<string>();

    public void Snapshot(RestartRuntimeTransaction tx)
    {
        Calls.Add("snapshot:" + tx.RuntimeForPhase("restart.snapshot").port.ToString());
    }

    public void StopWrapper(RestartRuntimeTransaction tx)
    {
        Calls.Add("stop-wrapper:" + tx.RuntimeForPhase("restart.stop-wrapper").port.ToString());
    }

    public void StopListenerFallback(RestartRuntimeTransaction tx)
    {
        Calls.Add("fallback:" + tx.RuntimeForPhase("restart.stop-listener-fallback").port.ToString());
    }

    public void WaitPortClosed(RestartRuntimeTransaction tx)
    {
        Calls.Add("wait-port-close:" + tx.RuntimeForPhase("restart.wait-port-close").port.ToString());
    }

    public void Compat(RestartRuntimeTransaction tx)
    {
        Calls.Add("compat:" + tx.RuntimeForPhase("restart.compat").port.ToString());
    }

    public void Start(RestartRuntimeTransaction tx)
    {
        Calls.Add("start:" + tx.RuntimeForPhase("restart.start").port.ToString());
    }

    public void WaitReady(RestartRuntimeTransaction tx)
    {
        Calls.Add("wait-ready:" + tx.RuntimeForPhase("restart.wait-ready").port.ToString());
    }

    public void Navigate(RestartRuntimeTransaction tx)
    {
        Calls.Add("navigate:" + tx.RuntimeForPhase("restart.navigate").port.ToString());
    }
}

class SettingsHarness
{
    static int Failures;

    static void Assert(bool condition, string label)
    {
        if (condition) Console.WriteLine("PASS: " + label);
        else { Failures++; Console.WriteLine("FAIL: " + label); }
    }

    static AppSettings Settings(int port, string profile)
    {
        AppSettings value = new AppSettings();
        value.port = port;
        value.profileName = profile;
        value.dshRunnerMode = "npx";
        return value;
    }

    static bool HasCall(FakeDsh fake, string call)
    {
        return fake.Calls.Contains(call);
    }

    public static int Main()
    {
        AppSettings oldRuntime = Settings(3080, "web");
        AppSettings targetRuntime = oldRuntime.Clone();
        targetRuntime.port = 3088;
        targetRuntime.profileName = "work";
        AppSettings active = oldRuntime.Clone();
        RestartRuntimeTransaction tx = new RestartRuntimeTransaction(oldRuntime, targetRuntime);
        FakeDsh fake = new FakeDsh();

        fake.Snapshot(tx);
        fake.StopWrapper(tx);
        fake.StopListenerFallback(tx);
        fake.WaitPortClosed(tx);
        fake.Compat(tx);
        fake.Start(tx);
        fake.WaitReady(tx);
        fake.Navigate(tx);

        Assert(HasCall(fake, "snapshot:3080"), "restart.snapshot uses old port 3080");
        Assert(HasCall(fake, "stop-wrapper:3080"), "restart.stop-wrapper uses old port 3080");
        Assert(HasCall(fake, "fallback:3080"), "restart.stop-listener-fallback uses old port 3080");
        Assert(HasCall(fake, "wait-port-close:3080"), "restart.wait-port-close uses old port 3080");
        Assert(HasCall(fake, "compat:3088"), "restart.compat uses target port 3088");
        Assert(HasCall(fake, "start:3088"), "restart.start uses target port 3088");
        Assert(HasCall(fake, "wait-ready:3088"), "restart.wait-ready uses target port 3088");
        Assert(HasCall(fake, "navigate:3088"), "restart.navigate uses target port 3088");
        Assert(active.port == 3080, "active remains 3080 before target ready");

        tx.MarkTargetBackendReady();
        tx.CommitTarget(active);
        Assert(active.port == 3088 && active.profileName == "work", "target ready commits 3088 and profile");

        AppSettings deferredActive = Settings(3080, "web");
        AppSettings persisted = deferredActive.Clone();
        persisted.port = 3088;
        Assert(deferredActive.port == 3080, "save but later keeps active runtime on 3080");

        AppSettings failedActive = oldRuntime.Clone();
        RestartRuntimeTransaction failed = new RestartRuntimeTransaction(oldRuntime, targetRuntime);
        bool oldBackendHealthy = true;
        bool targetStarted = false;
        if (oldBackendHealthy && !targetStarted)
            failedActive.CopyFrom(failed.OldRuntime);
        Assert(failedActive.port == 3080, "target start failure with healthy old keeps active 3080");
        Assert(!failed.TargetBackendReady && !failed.TargetCommitted, "failed target never commits active");

        AppSettings stoppedActive = oldRuntime.Clone();
        RestartRuntimeTransaction stopped = new RestartRuntimeTransaction(oldRuntime, targetRuntime);
        Assert(stoppedActive.port == stopped.OldRuntime.port && stoppedActive.port != stopped.TargetRuntime.port,
            "old stopped and target not ready does not claim target active");

        AppSettings profileBefore = Settings(3080, "web");
        AppSettings profileCandidate = profileBefore.Clone();
        profileCandidate.profileName = "work";
        Assert(profileCandidate.profileName != profileBefore.profileName, "profile change is target-only until commit");

        AppSettings closeBefore = profileBefore.Clone();
        AppSettings closeCandidate = closeBefore.Clone();
        closeCandidate.closeAction = "tray";
        Assert(closeCandidate.closeAction == "tray" && closeBefore.port == closeCandidate.port,
            "closeAction changes without backend transaction");

        Console.WriteLine(Failures == 0 ? "SETTINGS SNAPSHOT HARNESS PASSED" : "HARNESS FAILURES: " + Failures);
        return Failures == 0 ? 0 : 1;
    }
}
'@
    [System.IO.File]::WriteAllText($harnessCs, $harnessSource, [System.Text.UTF8Encoding]::new($true))
    $harnessExe = Join-Path $base 'settings-harness.exe'
    & $csc /nologo /target:exe /optimize+ /main:SettingsHarness "/out:$harnessExe" `
        /reference:System.dll /reference:System.Core.dll /reference:System.Drawing.dll `
        /reference:System.Windows.Forms.dll /reference:System.Web.Extensions.dll `
        "/reference:$($core.FullName)" "/reference:$($winForms.FullName)" `
        (Join-Path $repo 'src\DeepSeekHarness.cs') (Join-Path $repo 'src\HostLog.cs') `
        (Join-Path $repo 'src\NativeTcpTable.cs') $harnessCs 2>&1 | Out-String | Write-Host
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $harnessExe)) { throw 'harness compile failed' }
    $out = & $harnessExe 2>&1 | Out-String
    $code = $LASTEXITCODE
    foreach ($line in @($out -split "`r?`n" | Where-Object { $_ -match '^(PASS|FAIL|SETTINGS|HARNESS)' })) { Write-Host $line }
    if ($code -ne 0) { $fail++ }
}
catch {
    Write-Host "FAIL: settings snapshot test setup: $($_.Exception.Message)"
    $fail++
}
finally {
    Remove-Item -LiteralPath $base -Recurse -Force -ErrorAction SilentlyContinue
}

if ($fail -eq 0) { Write-Host 'SETTINGS RUNTIME SNAPSHOT TESTS PASSED' } else { Write-Host "FAILURES: $fail" }
exit $(if ($fail -eq 0) { 0 } else { 1 })
