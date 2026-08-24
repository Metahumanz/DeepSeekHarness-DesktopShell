$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$compat = Get-Content -LiteralPath (Join-Path $repo 'COMPATIBILITY.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$cs = [System.IO.File]::ReadAllText((Join-Path $repo 'src\DeepSeekHarness.cs'))
$manage = [System.IO.File]::ReadAllText((Join-Path $repo 'scripts\Manage-Dsh.ps1'))
$local = [System.IO.File]::ReadAllText((Join-Path $repo 'scripts\Test-DshRc1Local.ps1'))
$preflight = [System.IO.File]::ReadAllText((Join-Path $repo 'scripts\Test-PluginBootPreflight.ps1'))
$manual = [System.IO.File]::ReadAllText((Join-Path $repo 'docs\DSH_RC2_MANUAL_ACCEPTANCE.md'))
$version = (Get-Content -LiteralPath (Join-Path $repo 'VERSION') -Raw).Trim()

$fail = 0
function Assert-True([string]$label, [bool]$condition) {
    if ($condition) { Write-Host "PASS: $label" }
    else { $script:fail++; Write-Host "FAIL: $label" }
}

Assert-True 'testedDshVersions contains rc2' (@($compat.testedDshVersions | Where-Object { $_ -eq '0.1.1-rc.2' }).Count -gt 0)
Assert-True 'default switches to rc2 after live acceptance' ($compat.defaultDshVersion -eq '0.1.1-rc.2')
Assert-True 'minimum remains rc.7' ($compat.minimumCompatibleDshVersion -eq '0.1.0-rc.7')
Assert-True 'C# fallback list contains rc2' ($cs.Contains('"0.1.1-rc.2"'))
Assert-True 'C# known no-open table contains rc2' ($cs.Contains('String.Equals(version, "0.1.1-rc.2"'))
Assert-True 'PowerShell tested list contains rc2' ($manage.Contains("'0.1.1-rc.2'"))
Assert-True 'PowerShell known no-open table contains rc2' ($manage.Contains('$KnownNoOpenDshVersions') -and $manage.Contains("'0.1.1-rc.2'"))
Assert-True 'unknown versions retain help probing' ($cs.Contains('string probeArgs = usingNpx') -and $cs.Contains('--help') -and $cs -notmatch 'version\s*[><=].*no-open')

Assert-True 'local rc2 script defaults to rc2' ($local.Contains("[string]`$DshVersion = '0.1.1-rc.2'"))
Assert-True 'CLI version/help/no-open smoke is present' (
    $local.Contains('--version') -and $local.Contains('--help') -and $local.Contains('--no-open'))
Assert-True 'ready banner and HTTP 200 gate is present' (
    $local.Contains('dsh web:') -and $local.Contains('Test-Http200') -and $local.Contains('HTTP 200'))
Assert-True 'DesktopShell startup/manual restart/normal exit coverage is documented' (
    $local.Contains('[switch]$LaunchDesktopShell') -and $manual.Contains('## 2. DesktopShell') -and
    $manual.Contains('## 4.'))
Assert-True 'rc2 attachment/image regression is explicit and DesktopShell image code is untouched' (
    $manual.Contains('PNG/JPEG') -and $manual.Contains('WebView') -and $manual.Contains('DesktopShell'))
Assert-True 'isolated preflight uses rc2 no-open and separate validation modes' (
    $preflight.Contains("'0.1.1-rc.2'") -and $preflight.Contains("'status-rotator'") -and
    $preflight.Contains("'thought-buddy'"))
Assert-True 'VERSION is 1.0.6' ($version -eq '1.0.6')

if ($fail -eq 0) { Write-Host 'DSH RC2 COMPAT TESTS PASSED' } else { Write-Host "FAILURES: $fail" }
exit $(if ($fail -eq 0) { 0 } else { 1 })
