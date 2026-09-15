$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$buildRelease = [System.IO.File]::ReadAllText((Join-Path $repo 'scripts\Build-Release.ps1'))
$installDesktop = [System.IO.File]::ReadAllText((Join-Path $repo 'scripts\Install-Desktop.ps1'))
$installRelease = [System.IO.File]::ReadAllText((Join-Path $repo 'scripts\Install-Release.ps1'))
$verify = [System.IO.File]::ReadAllText((Join-Path $repo 'tests\verify.ps1'))
$ciYml = [System.IO.File]::ReadAllText((Join-Path $repo '.github\workflows\ci.yml'))
$releaseYml = [System.IO.File]::ReadAllText((Join-Path $repo '.github\workflows\release.yml'))
$versionText = [System.IO.File]::ReadAllText((Join-Path $repo 'VERSION')).Trim()

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
Assert-True "release.yml defaults to repo version $versionText" ($releaseYml -match ("default: '" + [regex]::Escape($versionText) + "'"))
Assert-True "release.yml gates version against VERSION file" ($releaseYml -match 'Get-Content -LiteralPath VERSION -Raw')
Assert-True "release.yml still freezes old releases (no delete step)" ($releaseYml -notmatch 'delete_release|delete-existing')

# ---- 4. CI/Release 只在必要处跨 PowerShell 宿主重复执行 ----
$fullSuiteMatch = [regex]::Match($verify, '(?s)\$fullTests = @\((.*?)\)\s*\r?\n\r?\n# Windows')
$ps51SuiteMatch = [regex]::Match($verify, '(?s)\$ps51CompatibilityTests = @\((.*?)\)\s*\r?\n\r?\n\$tests')
$fullSuiteTests = @($fullSuiteMatch.Groups[1].Value | Select-String -AllMatches "'([^']+\.ps1)'" | ForEach-Object { $_.Matches } | ForEach-Object { $_.Groups[1].Value })
$ps51SuiteTests = @($ps51SuiteMatch.Groups[1].Value | Select-String -AllMatches "'([^']+\.ps1)'" | ForEach-Object { $_.Matches } | ForEach-Object { $_.Groups[1].Value })
$requiredPs51Tests = @(
    'test-ps51-encoding.ps1',
    'test-npx-version-parser.ps1',
    'test-dsh-version.ps1',
    'test-runner-mode.ps1',
    'test-repair-regex.ps1',
    'test-install-ownership.ps1',
    'test-uninstall-guards.ps1',
    'test-plugin-preflight-cleanup.ps1'
)

Assert-True 'verify exposes separate Full and Ps51Compat suites' ($verify -match "ValidateSet\('Full', 'Ps51Compat'\)" -and $fullSuiteMatch.Success -and $ps51SuiteMatch.Success)
Assert-True "Full suite retains all 44 regression tests (got: $($fullSuiteTests.Count))" ($fullSuiteTests.Count -eq 44)
Assert-True 'production compatibility contract test stays in the Full suite' (
    $fullSuiteTests -contains 'test-production-compat-contracts.ps1' -and
    $ps51SuiteTests -notcontains 'test-production-compat-contracts.ps1')
Assert-True "Ps51Compat retains exactly 8 host-sensitive tests (got: $($ps51SuiteTests.Count))" (
    $ps51SuiteTests.Count -eq $requiredPs51Tests.Count -and
    @($requiredPs51Tests | Where-Object { $ps51SuiteTests -notcontains $_ }).Count -eq 0)
Assert-True 'PowerShell 7 remains the one full-source gate' ($ciYml -match 'run: pwsh -NoProfile -File tests/verify\.ps1' -and $releaseYml -match 'run: pwsh -NoProfile -File tests/verify\.ps1')
Assert-True 'both workflows run only the PS 5.1 compatibility suite' ($ciYml -match 'tests/verify\.ps1 -Suite Ps51Compat -SkipAnalyzer' -and $releaseYml -match 'tests/verify\.ps1 -Suite Ps51Compat -SkipAnalyzer')

# Build-Release 是 ZIP 文件清单的唯一权威校验点；CI 不再重复解包，普通 CI 也不上传无人消费的工件。
Assert-True 'Build-Release owns exact package-manifest verification' ($buildRelease -match '\$ExpectedPackageFiles = @\(' -and $buildRelease -match '\$missing = @\(' -and $buildRelease -match '\$unexpected = @\(')
Assert-True 'release and source installer ship dynamic ecosystem management scripts together' (
    $buildRelease.Contains("'Scan-DshPluginEcosystem.cjs'") -and
    $buildRelease.Contains("'Scan-DshPluginEcosystem.ps1'") -and
    $buildRelease.Contains("'Test-PluginBootPreflight.ps1'") -and
    $buildRelease.Contains("'Test-DshPluginEcosystemPreflight.ps1'") -and
    $buildRelease.Contains("'Test-DshWebView2Acceptance.ps1'") -and
    $installDesktop.Contains("'scripts\Scan-DshPluginEcosystem.cjs'") -and
    $installDesktop.Contains("'scripts\Test-DshPluginEcosystemPreflight.ps1'") -and
    $installDesktop.Contains("'scripts\Test-DshWebView2Acceptance.ps1'"))
Assert-True 'CI no longer repeats ZIP extraction or uploads unused release artifacts' ($ciYml -notmatch 'Verify zip content|Expand-Archive|actions/upload-artifact')
Assert-True 'release build no longer repeats package extraction' ($releaseYml -notmatch 'Verify package contents|Expand-Archive')
$downloadIndex = $releaseYml.IndexOf('Download release artifacts', [System.StringComparison]::Ordinal)
$hashIndex = $releaseYml.IndexOf('Verify downloaded artifact hash', [System.StringComparison]::Ordinal)
Assert-True 'release verifies the downloaded artifact hash after the cross-job download' (
    $downloadIndex -ge 0 -and $hashIndex -gt $downloadIndex -and
    $releaseYml -match 'Get-FileHash -LiteralPath \$zip -Algorithm SHA256' -and
    $releaseYml -match 'SHA256SUMS\.txt')

# ---- 5. 根目录版本文件与兼容基线内容自洽 ----
Assert-True "root VERSION is 1.0.13 (got: $versionText)" ($versionText -eq '1.0.13')
$compat = Get-Content -LiteralPath (Join-Path $repo 'COMPATIBILITY.json') -Raw -Encoding UTF8 | ConvertFrom-Json
Assert-True "COMPATIBILITY.json defaultDshVersion is a valid semver (got: $($compat.defaultDshVersion))" ($compat.defaultDshVersion -match '^\d+\.\d+\.\d+(?:-[A-Za-z0-9._+-]+)?$')
Assert-True "COMPATIBILITY.json minimumCompatibleDshVersion is a valid semver (got: $($compat.minimumCompatibleDshVersion))" ($compat.minimumCompatibleDshVersion -match '^\d+\.\d+\.\d+(?:-[A-Za-z0-9._+-]+)?$')

if ($fail -eq 0) { Write-Host 'BUILD/RELEASE WIRING TESTS PASSED' } else { Write-Host "FAILURES: $fail" }
exit $(if ($fail -eq 0) { 0 } else { 1 })
