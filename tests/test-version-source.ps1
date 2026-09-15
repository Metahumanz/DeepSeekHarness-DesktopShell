$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$cs = [System.IO.File]::ReadAllText((Join-Path $repo 'src\DeepSeekHarness.cs'))
$manage = [System.IO.File]::ReadAllText((Join-Path $repo 'scripts\Manage-Dsh.ps1'))
$installer = [System.IO.File]::ReadAllText((Join-Path $repo 'scripts\Install-Release.ps1'))
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
Assert-True "Get-DshVersionFromNpx accepts one standalone version line amid npm notices" ($manage -match '\$versionLines = @\(' -and $manage -match 'unique')

# ---- 3. 根 VERSION 与 release.yml 默认一致 ----
$versionText = [System.IO.File]::ReadAllText((Join-Path $repo 'VERSION')).Trim()
Assert-True "root VERSION is 1.0.13 (got: $versionText)" ($versionText -eq '1.0.13')
Assert-True "release.yml default matches VERSION" ($releaseYml -match ("default: '" + [regex]::Escape($versionText) + "'"))

# ---- 4. COMPATIBILITY.json 自洽 ----
$compat = Get-Content -LiteralPath (Join-Path $repo 'COMPATIBILITY.json') -Raw -Encoding UTF8 | ConvertFrom-Json
Assert-True "schemaVersion is 4" ($compat.schemaVersion -eq 4)
Assert-True "defaultDshVersion valid semver (got: $($compat.defaultDshVersion))" ($compat.defaultDshVersion -match '^\d+\.\d+\.\d+(?:-[A-Za-z0-9._+-]+)?$')
Assert-True "minimumCompatibleDshVersion valid semver (got: $($compat.minimumCompatibleDshVersion))" ($compat.minimumCompatibleDshVersion -match '^\d+\.\d+\.\d+(?:-[A-Za-z0-9._+-]+)?$')
Assert-True "testedDshVersions is non-empty array" (@($compat.testedDshVersions).Count -gt 0)
Assert-True "defaultDshVersion is in testedDshVersions" (@($compat.testedDshVersions | Where-Object { $_ -eq $compat.defaultDshVersion }).Count -gt 0)

# ---- 5. npx 版本菜单：编号选择 + npm 官方通道，不再为每个新版本硬编码条目 ----
$channels = @($compat.npxDshChannelOptions)
$channelTags = @($channels | ForEach-Object { [string]$_.tag })
Assert-True "npx channel options are present" ($channels.Count -ge 2)
Assert-True "latest is an official dynamic channel" ($channelTags -contains 'latest')
Assert-True "alpha is an official dynamic preview channel" ($channelTags -contains 'alpha')
Assert-True "alpha channel requires an isolated Profile" (
    @($channels | Where-Object { $_.tag -eq 'alpha' -and $_.preview -and $_.profileMode -eq 'isolated' }).Count -eq 1)
Assert-True "dynamic channel config contains no version-specific alpha pins" (
    ($channelTags -notcontains '0.1.2-alpha.3') -and ($channelTags -notcontains '0.1.2-alpha.4'))
Assert-True "Manage-Dsh reads channel options" ($manage -match 'npxDshChannelOptions')
Assert-True "Manage-Dsh resolves a selected tag through npm view" (
    $manage -match 'function Resolve-NpmDshDistTag' -and
    $manage -match '@deepseek-ai/dsh@' -and
    $manage -match 'npm view')
Assert-True "Manage-Dsh has an npx version chooser" ($manage -match 'function Select-NpxDshVersion')
Assert-True "npx chooser retains the historical tested-version options" (
    $manage -match 'foreach \(\$version in @\(\$TestedDshVersions\)\)')
Assert-True "interactive npx flow no longer asks for a raw version string" (
    $manage -notmatch "Read-Default 'npx 使用的 DSH 版本'")
Assert-True "preview choice requires explicit confirmation" (
    $manage -match "确认仅用于预览验证")
Assert-True "preview channel chooses a new isolated Profile without touching the current one" (
    $manage -match 'Get-NewIsolatedPreviewProfile' -and
    $manage -match 'Resolve-ProfileForNpxSelection' -and
    $manage -match '现有 Profile、插件、主题和会话目录均不会被移动、删除或改写')
Assert-True "cancelled first-install is a normal installer outcome" (
    $manage -match 'exit 2' -and
    $installer -match '\$managerExitCode -eq 2' -and
    $installer -match '初始化向导已取消；未替换现有 DesktopShell 安装。')
$guidedSetup = $manage.Substring($manage.IndexOf('function Guided-Setup'))
Assert-True "legacy runtime cleanup waits until settings are saved" (
    $guidedSetup.IndexOf('Remove-LegacyPrivateRuntime') -gt
    $guidedSetup.IndexOf('Save-DesktopSettings $resolved.Path'))

if ($fail -eq 0) { Write-Host 'VERSION SOURCE TESTS PASSED' } else { Write-Host "FAILURES: $fail" }
exit $(if ($fail -eq 0) { 0 } else { 1 })
