$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$buildRelease = [System.IO.File]::ReadAllText((Join-Path $repo 'scripts\Build-Release.ps1'))
$installDesktop = [System.IO.File]::ReadAllText((Join-Path $repo 'scripts\Install-Desktop.ps1'))
$installRelease = [System.IO.File]::ReadAllText((Join-Path $repo 'scripts\Install-Release.ps1'))
$releaseYml = [System.IO.File]::ReadAllText((Join-Path $repo '.github\workflows\release.yml'))

$fail = 0
function Assert-True([string]$label, [bool]$condition) {
    if ($condition) { Write-Host "PASS: $label" }
    else { $script:fail++; Write-Host "FAIL: $label" }
}

# ---- 1. 发布包仅 x64（-Arch 校验集只剩 x64，无 arm64/x86 死分支） ----
Assert-True "Build-Release -Arch ValidateSet is x64-only" ($buildRelease -match '\[ValidateSet\(''x64''\)\]')
Assert-True "loader variant fixed to win-x64" ($buildRelease -match '\$ArchLoader = ''win-x64''')
Assert-True "no dead arm64/x86 arch branches" ($buildRelease -notmatch "'arm64'|'x86'" -and $buildRelease -notmatch 'win-arm64|win-x86')

# ---- 2. 两个新源码文件进入两条编译路径（Build-Release 与源码安装器） ----
foreach ($pair in @(
    @{ Name='Build-Release compiles HostLog.cs';     Text=$buildRelease;    Needle="src\HostLog.cs" },
    @{ Name='Build-Release compiles NativeTcpTable.cs'; Text=$buildRelease; Needle="src\NativeTcpTable.cs" },
    @{ Name='Install-Desktop compiles HostLog.cs';   Text=$installDesktop;  Needle="src\HostLog.cs" },
    @{ Name='Install-Desktop compiles NativeTcpTable.cs'; Text=$installDesktop; Needle="src\NativeTcpTable.cs" }
)) {
    Assert-True $pair.Name ($pair.Text -match [regex]::Escape($pair.Needle))
}

# ---- 3. 版本/兼容基线单一来源 ----
Assert-True "Build-Release defaults version from root VERSION" ($buildRelease -match "'VERSION'" -and $buildRelease -match '\$Version = \$raw')
Assert-True "Install-Desktop reads root VERSION" ($installDesktop -match '\$versionFile = Join-Path \$repoRoot ''VERSION''')
Assert-True "Install-Release ships COMPATIBILITY.json" ($installRelease -match "'COMPATIBILITY\.json'")
Assert-True "release.yml defaults to repo version 1.0.3" ($releaseYml -match "default: '1\.0\.3'")
Assert-True "release.yml gates version against VERSION file" ($releaseYml -match 'Get-Content -LiteralPath VERSION -Raw')
Assert-True "release.yml still freezes old releases (no delete step)" ($releaseYml -notmatch 'delete_release|delete-existing')

# ---- 4. 根目录版本文件与兼容基线内容自洽 ----
$versionText = [System.IO.File]::ReadAllText((Join-Path $repo 'VERSION')).Trim()
Assert-True "root VERSION is 1.0.3 (got: $versionText)" ($versionText -eq '1.0.3')
$compat = Get-Content -LiteralPath (Join-Path $repo 'COMPATIBILITY.json') -Raw -Encoding UTF8 | ConvertFrom-Json
Assert-True "COMPATIBILITY.json defaultDshVersion is a valid semver (got: $($compat.defaultDshVersion))" ($compat.defaultDshVersion -match '^\d+\.\d+\.\d+(?:-[A-Za-z0-9._+-]+)?$')
Assert-True "COMPATIBILITY.json minimumCompatibleDshVersion is a valid semver (got: $($compat.minimumCompatibleDshVersion))" ($compat.minimumCompatibleDshVersion -match '^\d+\.\d+\.\d+(?:-[A-Za-z0-9._+-]+)?$')

if ($fail -eq 0) { Write-Host 'BUILD/RELEASE WIRING TESTS PASSED' } else { Write-Host "FAILURES: $fail" }
exit $(if ($fail -eq 0) { 0 } else { 1 })
