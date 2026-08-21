$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$compatPath = Join-Path $repo 'COMPATIBILITY.json'
$versionPath = Join-Path $repo 'VERSION'
$sourcePath = Join-Path $repo 'src\DeepSeekHarness.cs'

$compat = Get-Content -LiteralPath $compatPath -Raw -Encoding UTF8 | ConvertFrom-Json
$version = (Get-Content -LiteralPath $versionPath -Raw).Trim()
$source = [System.IO.File]::ReadAllText($sourcePath)

$fail = 0
function Assert-True([string]$label, [bool]$condition) {
    if ($condition) { Write-Host "PASS: $label" }
    else { $script:fail++; Write-Host "FAIL: $label" }
}

Assert-True 'testedDshVersions contains rc1' (@($compat.testedDshVersions | Where-Object { $_ -eq '0.1.1-rc.1' }).Count -gt 0)
Assert-True 'default remains rc.7' ($compat.defaultDshVersion -eq '0.1.0-rc.7')
Assert-True 'minimum remains rc.7' ($compat.minimumCompatibleDshVersion -eq '0.1.0-rc.7')
Assert-True 'rc1 is a known no-open version' ($source -match 'String\.Equals\(version, "0\.1\.1-rc\.1"')
Assert-True 'unknown versions still use help probing' ($source -match 'string probeArgs = usingNpx' -and $source -match '--help')
Assert-True 'overlay primary binding does not depend on effective Visible' ($source -match 'bool showPrimary' -and $source -match 'if \(showPrimary\) overlayPrimaryButton\.Click \+=')
Assert-True 'overlay restart action is logged' ($source -match 'UI overlay action=restart')
Assert-True 'VERSION is 1.0.5' ($version -eq '1.0.5')

if ($fail -eq 0) { Write-Host 'DSH RC1 CERTIFICATION TESTS PASSED' } else { Write-Host "FAILURES: $fail" }
exit $(if ($fail -eq 0) { 0 } else { 1 })
