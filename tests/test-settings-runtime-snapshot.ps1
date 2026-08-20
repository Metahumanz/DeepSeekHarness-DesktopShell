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

Assert-True 'persisted and active runtime snapshots exist' ($sourceText -match 'persistedSettings' -and $sourceText -match 'activeRuntimeSettings')
Assert-True 'health check reads active port' ($sourceText -match 'IsDshHealthy\(activeRuntimeSettings\.port')
Assert-True 'DSH URL reads active port' ($sourceText -match '127\.0\.0\.1:" \+ activeRuntimeSettings\.port')
Assert-True 'profile and runner startup read active snapshot' ($sourceText -match 'activeRuntimeSettings\.profileName' -and $sourceText -match 'activeRuntimeSettings\.dshRunnerMode')
Assert-True 'save path snapshots before save and classifies backend fields' ($sourceText -match 'AppSettings oldSnapshot = persistedSettings\.Clone\(\)' -and $sourceText -match 'BackendRuntimeSettingsChanged\(oldSnapshot, persistedSettings\)')
Assert-True 'backend change offers immediate restart' ($sourceText -match '这些设置需要重启 DSH 后端才能生效' -and $sourceText -match 'activeRuntimeSettings\.CopyFrom\(persistedSettings\)' -and $sourceText -match 'await RestartBackendAsync\(\)')
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
using System.Reflection;
using DeepSeekHarnessDesktop;

class SettingsHarness
{
    static int Failures;
    static void Assert(bool condition, string label)
    {
        if (condition) Console.WriteLine("PASS: " + label);
        else { Failures++; Console.WriteLine("FAIL: " + label); }
    }

    static bool BackendChanged(AppSettings before, AppSettings after)
    {
        MethodInfo method = typeof(MainForm).GetMethod(
            "BackendRuntimeSettingsChanged",
            BindingFlags.Static | BindingFlags.NonPublic);
        return (bool)method.Invoke(null, new object[] { before, after });
    }

    public static int Main()
    {
        AppSettings persisted = new AppSettings();
        AppSettings active = persisted.Clone();
        AppSettings candidate = persisted.Clone();
        candidate.port = 3088;
        Assert(BackendChanged(persisted, candidate), "3080 -> 3088 is backend-affecting");

        persisted.CopyFrom(candidate); // save without restart
        Assert(active.port == 3080, "save without restart keeps active backend on 3080");

        active.CopyFrom(persisted); // immediate apply path before RestartBackendAsync
        Assert(active.port == 3088, "immediate apply switches active port to 3088");

        AppSettings profileBefore = active.Clone();
        AppSettings profileCandidate = persisted.Clone();
        profileCandidate.profileName = "work";
        Assert(BackendChanged(profileBefore, profileCandidate), "profile change is backend-affecting");
        Assert(active.profileName == "web", "active profile remains web until restart");

        AppSettings closeBefore = active.Clone();
        AppSettings closeCandidate = active.Clone();
        closeCandidate.closeAction = "tray";
        Assert(!BackendChanged(closeBefore, closeCandidate), "closeAction applies without backend restart");

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
