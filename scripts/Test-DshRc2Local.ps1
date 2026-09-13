[CmdletBinding()]
param(
    [string]$DshVersion = '0.1.5-rc.2',
    [ValidateSet('npx', 'command', 'auto')]
    [string]$PluginRunnerMode = 'npx',
    [string]$PluginDshPath = '',
    [int]$Port = 0,
    [string]$AppExe = '',
    [switch]$LaunchDesktopShell,
    [switch]$RunPlugins,
    [switch]$KeepTemp,
    [int]$TimeoutSeconds = 60,
    [int]$StableSeconds = 3
)

# rc.1 认证脚本的 rc.2 入口：保留同一套临时 DSH_HOME、CLI/Web、插件隔离和 GUI 手动阶段。
$legacyScript = Join-Path $PSScriptRoot 'Test-DshRc1Local.ps1'
$arguments = @{
    DshVersion = $DshVersion
    PluginRunnerMode = $PluginRunnerMode
    PluginDshPath = $PluginDshPath
    Port = $Port
    TimeoutSeconds = $TimeoutSeconds
    StableSeconds = $StableSeconds
}
if ($AppExe) { $arguments.AppExe = $AppExe }
if ($LaunchDesktopShell) { $arguments.LaunchDesktopShell = $true }
if ($RunPlugins) { $arguments.RunPlugins = $true }
if ($KeepTemp) { $arguments.KeepTemp = $true }

& $legacyScript @arguments
exit $LASTEXITCODE
