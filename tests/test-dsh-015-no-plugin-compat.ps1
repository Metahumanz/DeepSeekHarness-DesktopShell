$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$compat = Get-Content -LiteralPath (Join-Path $repo 'COMPATIBILITY.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$cs = [System.IO.File]::ReadAllText((Join-Path $repo 'src\DeepSeekHarness.cs'))
$manage = [System.IO.File]::ReadAllText((Join-Path $repo 'scripts\Manage-Dsh.ps1'))
$genericSmoke = [System.IO.File]::ReadAllText((Join-Path $repo 'scripts\Test-DshRc1Local.ps1'))
$noPluginSmoke = [System.IO.File]::ReadAllText((Join-Path $repo 'scripts\Test-Dsh015NoPluginLocal.ps1'))
$manual = [System.IO.File]::ReadAllText((Join-Path $repo 'docs\DSH_015_NO_PLUGIN_ACCEPTANCE.md'))

$fail = 0
function Assert-True([string]$label, [bool]$condition) {
    if ($condition) { Write-Host "PASS: $label" }
    else { $script:fail++; Write-Host "FAIL: $label" }
}

Assert-True 'default is the tested 0.1.5 rc2 baseline' ($compat.defaultDshVersion -eq '0.1.5-rc.2')
Assert-True 'tested versions include 0.1.5 rc2' (@($compat.testedDshVersions | Where-Object { $_ -eq '0.1.5-rc.2' }).Count -eq 1)
Assert-True 'C# fallback includes 0.1.5 rc2' ($cs.Contains('defaultDshVersionCache = "0.1.5-rc.2"'))
Assert-True 'C# known no-open capability includes 0.1.5 rc2' ($cs.Contains('String.Equals(version, "0.1.5-rc.2"'))
Assert-True 'manager fallback includes 0.1.5 rc2' ($manage.Contains("`$DefaultDshVersion = '0.1.5-rc.2'"))
Assert-True 'manager known no-open capability includes 0.1.5 rc2' ($manage.Contains("'0.1.5-rc.2'"))

Assert-True 'no-plugin wrapper pins and enforces the exact target version' (
    $noPluginSmoke.Contains("DshVersion = '0.1.5-rc.2'") -and
    $noPluginSmoke.Contains("if (`$DshVersion -ne '0.1.5-rc.2')") -and
    $noPluginSmoke.Contains('核心无插件验收只接受固定目标 DSH 0.1.5-rc.2。'))
Assert-True 'no-plugin wrapper enables the empty-profile guard' ($noPluginSmoke.Contains('RequireNoUserPlugins = $true'))
Assert-True 'no-plugin wrapper has no existing-profile input' ($noPluginSmoke -notmatch 'WebProfileDshHome')
Assert-True 'generic smoke exposes the empty-profile guard' ($genericSmoke -match '\[switch\]\$RequireNoUserPlugins')
Assert-True 'generic smoke runs the guard after Web readiness' ($genericSmoke -match 'Assert-NoUserPlugins \$webHome')
Assert-True 'empty-profile guard rejects user dependencies' ($genericSmoke -match 'unexpected Profile dependencies')
Assert-True 'empty-profile guard requires only core bundles' (
    $genericSmoke.Contains("'@deepseek-ai/dsh-base'") -and
    $genericSmoke.Contains("'@deepseek-ai/dsh-web-app'"))
Assert-True 'manual acceptance document states the no-plugin boundary' (
    $manual.Contains('# DSH 0.1.5-rc.2') -and
    $manual.Contains('Test-Dsh015NoPluginLocal.ps1'))

if ($fail -eq 0) { Write-Host 'DSH 0.1.5 NO-PLUGIN COMPAT TESTS PASSED' }
else { Write-Host "FAILURES: $fail" }
exit $(if ($fail -eq 0) { 0 } else { 1 })
