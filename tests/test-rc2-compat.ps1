$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$compat = Get-Content -LiteralPath (Join-Path $repo 'COMPATIBILITY.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$cs = [IO.File]::ReadAllText((Join-Path $repo 'src\DeepSeekHarness.cs'))
$manage = [IO.File]::ReadAllText((Join-Path $repo 'scripts\Manage-Dsh.ps1'))
$local = [IO.File]::ReadAllText((Join-Path $repo 'scripts\Test-DshRc2Local.ps1'))
$genericLocal = [IO.File]::ReadAllText((Join-Path $repo 'scripts\Test-DshRc1Local.ps1'))
$ecosystem = [IO.File]::ReadAllText((Join-Path $repo 'scripts\Test-DshPluginEcosystemPreflight.ps1'))
$manual = [IO.File]::ReadAllText((Join-Path $repo 'docs\DSH_015_NO_PLUGIN_ACCEPTANCE.md'))
$version = (Get-Content -LiteralPath (Join-Path $repo 'VERSION') -Raw).Trim()

$fail = 0
function Assert-True([string]$label, [bool]$condition) {
    if ($condition) { Write-Host "PASS: $label" }
    else { $script:fail++; Write-Host "FAIL: $label" }
}

Assert-True 'rc2 is the exact default and tested version' (
    $compat.defaultDshVersion -eq '0.1.5-rc.2' -and
    @($compat.testedDshVersions | Where-Object { $_ -eq '0.1.5-rc.2' }).Count -eq 1)
Assert-True 'minimum remains rc.7' ($compat.minimumCompatibleDshVersion -eq '0.1.0-rc.7')
Assert-True 'C# fallback and no-open capability contain the exact rc2 target' (
    $cs.Contains('defaultDshVersionCache = "0.1.5-rc.2"') -and
    $cs.Contains('String.Equals(version, "0.1.5-rc.2"'))
Assert-True 'PowerShell manager has the exact rc2 default and no-open capability' (
    $manage.Contains("`$DefaultDshVersion = '0.1.5-rc.2'") -and
    $manage.Contains("'0.1.5-rc.2'"))
Assert-True 'unknown versions still retain real CLI help probing' (
    $cs.Contains('string probeArgs = usingNpx') -and $cs.Contains('--help') -and
    $cs -notmatch 'version\s*[><=].*no-open')
Assert-True 'local rc2 smoke pins 0.1.5-rc.2 and asserts no-open readiness' (
    $local.Contains("DshVersion = '0.1.5-rc.2'") -and
    $local.Contains("'Test-DshRc1Local.ps1'") -and
    $genericLocal.Contains('--version') -and $genericLocal.Contains('--help') -and $genericLocal.Contains('--no-open') -and
    $genericLocal.Contains('Get-DshReadyUrl') -and $genericLocal.Contains('Test-Http200'))
Assert-True 'ecosystem preflight refuses every target other than rc2' (
    $ecosystem.Contains("if (`$DshVersion -ne '0.1.5-rc.2')") -and
    $ecosystem.Contains('只接受固定目标 DSH 0.1.5-rc.2'))
Assert-True 'manual acceptance states the fixed rc2 target' (
    $manual.Contains('# DSH 0.1.5-rc.2') -and $manual.Contains('@deepseek-ai/dsh@0.1.5-rc.2'))
Assert-True 'DesktopShell product VERSION is 1.0.12' ($version -eq '1.0.12')

if ($fail -eq 0) { Write-Host 'DSH 0.1.5 RC2 COMPAT TESTS PASSED' }
else { Write-Host "FAILURES: $fail" }
exit $(if ($fail -eq 0) { 0 } else { 1 })
