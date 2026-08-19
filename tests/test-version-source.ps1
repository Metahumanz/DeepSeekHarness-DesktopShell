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

# ---- 1. C# 端最后一个 dshVersion 硬编码已清 ----
Assert-True "AppSettings.Load no longer hardcodes rc.7" ($cs -notmatch 'value\.dshVersion = "0\.1\.0-rc\.7"')
Assert-True "AppSettings.Load falls back to VerifiedDshVersion" ($cs -match 'value\.dshVersion = DshProcessManager\.VerifiedDshVersion')
$rc7Count = ([regex]::Matches($cs, '0\.1\.0-rc\.7')).Count
Assert-True "only sanctioned fallback remains in src (count=$rc7Count)" ($rc7Count -le 1)

# ---- 2. PS 端基线单一来源 ----
Assert-True "Manage-Dsh reads COMPATIBILITY.json" ($manage -match '\$VerifiedDshVersion = \[string\]\$compat\.verifiedDshVersion')
Assert-True "npx fallback version derives from baseline" ($manage -match '\$defaultDshVersion = \$VerifiedDshVersion')
$manageRc7 = ([regex]::Matches($manage, '0\.1\.0-rc\.7')).Count
Assert-true "Manage-Dsh rc.7 only in fallback/comment (count=$manageRc7)" ($manageRc7 -le 2)

# ---- 3. 根 VERSION 与 release.yml 默认一致 ----
$versionText = [System.IO.File]::ReadAllText((Join-Path $repo 'VERSION')).Trim()
Assert-True "root VERSION is 1.0.2 (got: $versionText)" ($versionText -eq '1.0.2')
Assert-True "release.yml default matches VERSION" ($releaseYml -match ("default: '" + [regex]::Escape($versionText) + "'"))

# ---- 4. COMPATIBILITY.json 自洽 ----
$compat = Get-Content -LiteralPath (Join-Path $repo 'COMPATIBILITY.json') -Raw -Encoding UTF8 | ConvertFrom-Json
Assert-True "COMPATIBILITY.json verifiedDshVersion valid semver (got: $($compat.verifiedDshVersion))" ($compat.verifiedDshVersion -match '^\d+\.\d+\.\d+(?:-[A-Za-z0-9._+-]+)?$')

if ($fail -eq 0) { Write-Host 'VERSION SOURCE TESTS PASSED' } else { Write-Host "FAILURES: $fail" }
exit $(if ($fail -eq 0) { 0 } else { 1 })
