$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$cs = [System.IO.File]::ReadAllText((Join-Path $repo 'src\DeepSeekHarness.cs'))
$manage = [System.IO.File]::ReadAllText((Join-Path $repo 'scripts\Manage-Dsh.ps1'))
$releaseYml = [System.IO.File]::ReadAllText((Join-Path $repo '.github\workflows\release.yml'))

$fail = 0
function Assert-True([string]$label, [bool]$condition) {
    if ($condition) { Write-Host "PASS: $label" }
    else { $script:fail++; Write-Host "FAIL: $label" }
}

# ---- 1. C# 端 dshVersion 缺省回退到 DefaultDshVersion（新 schema 默认版本） ----
Assert-True "AppSettings.Load no longer hardcodes rc.7" ($cs -notmatch 'value\.dshVersion = "0\.1\.0-rc\.7"')
Assert-True "AppSettings.Load falls back to DefaultDshVersion" ($cs -match 'value\.dshVersion = DshProcessManager\.DefaultDshVersion')
Assert-True "AppSettings.NormalizeDshVersion uses DefaultDshVersion" ($cs -match 'string fallback = DshProcessManager\.DefaultDshVersion')

# ---- 2. PS 端兼容策略单一来源 ----
Assert-True "Manage-Dsh reads defaultDshVersion" ($manage -match '\$DefaultDshVersion = \[string\]\$compat\.defaultDshVersion')
Assert-True "Manage-Dsh reads minimumCompatibleDshVersion" ($manage -match '\$MinimumCompatibleDshVersion = \[string\]\$compat\.minimumCompatibleDshVersion')
Assert-True "Manage-Dsh reads testedDshVersions" ($manage -match '\$TestedDshVersions = \$parsed')
Assert-True "npx fallback version derives from default" ($manage -match '\$defaultDshVersion = \$DefaultDshVersion')
Assert-True "Get-DshVersionFromNpx does not swallow stderr" ($manage -notmatch 'Get-DshVersionFromNpx[\s\S]*?2>\$null')
Assert-True "Get-DshVersionFromNpx surfaces ETARGET" ($manage -match 'No matching version found for')
Assert-True "Get-DshVersionFromNpx surfaces npm log path" ($manage -match 'log of this run can be found in')

# ---- 3. 根 VERSION 与 release.yml 默认一致 ----
$versionText = [System.IO.File]::ReadAllText((Join-Path $repo 'VERSION')).Trim()
Assert-True "root VERSION is 1.0.4 (got: $versionText)" ($versionText -eq '1.0.4')
Assert-True "release.yml default matches VERSION" ($releaseYml -match ("default: '" + [regex]::Escape($versionText) + "'"))

# ---- 4. COMPATIBILITY.json 自洽 ----
$compat = Get-Content -LiteralPath (Join-Path $repo 'COMPATIBILITY.json') -Raw -Encoding UTF8 | ConvertFrom-Json
Assert-True "schemaVersion is 2" ($compat.schemaVersion -eq 2)
Assert-True "defaultDshVersion valid semver (got: $($compat.defaultDshVersion))" ($compat.defaultDshVersion -match '^\d+\.\d+\.\d+(?:-[A-Za-z0-9._+-]+)?$')
Assert-True "minimumCompatibleDshVersion valid semver (got: $($compat.minimumCompatibleDshVersion))" ($compat.minimumCompatibleDshVersion -match '^\d+\.\d+\.\d+(?:-[A-Za-z0-9._+-]+)?$')
Assert-True "testedDshVersions is non-empty array" (@($compat.testedDshVersions).Count -gt 0)
Assert-True "defaultDshVersion is in testedDshVersions" (@($compat.testedDshVersions | Where-Object { $_ -eq $compat.defaultDshVersion }).Count -gt 0)

if ($fail -eq 0) { Write-Host 'VERSION SOURCE TESTS PASSED' } else { Write-Host "FAILURES: $fail" }
exit $(if ($fail -eq 0) { 0 } else { 1 })
