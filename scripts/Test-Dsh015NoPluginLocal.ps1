[CmdletBinding()]
param(
    [string]$DshVersion = '0.1.5-rc.2',
    [int]$Port = 0,
    [switch]$KeepTemp,
    [int]$TimeoutSeconds = 120,
    [int]$StableSeconds = 10
)

$ErrorActionPreference = 'Stop'

if ($DshVersion -ne '0.1.5-rc.2') {
    throw '核心无插件验收只接受固定目标 DSH 0.1.5-rc.2。'
}

# 0.1.5-rc.2 的发布基线只覆盖新的空 Profile：不接收现有 DSH_HOME，
# 不传 -RunPlugins，并由底层脚本断言 Profile 中没有用户依赖或补丁。
$smoke = Join-Path $PSScriptRoot 'Test-DshRc1Local.ps1'
$runArgs = @{
    DshVersion = $DshVersion
    Port = $Port
    TimeoutSeconds = $TimeoutSeconds
    StableSeconds = $StableSeconds
    RequireNoUserPlugins = $true
}
if ($KeepTemp) { $runArgs.KeepTemp = $true }

& $smoke @runArgs
exit $LASTEXITCODE
