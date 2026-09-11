[CmdletBinding()]
param(
    [int]$Port = 0,
    [switch]$KeepTemp,
    [int]$TimeoutSeconds = 120,
    [int]$StableSeconds = 10
)

$ErrorActionPreference = 'Stop'

# 0.1.5-rc.1 的发布基线只覆盖新的空 Profile：不接收现有 DSH_HOME，
# 不传 -RunPlugins，并由底层脚本断言 Profile 中没有用户依赖或补丁。
$smoke = Join-Path $PSScriptRoot 'Test-DshRc1Local.ps1'
$runArgs = @{
    DshVersion = '0.1.5-rc.1'
    Port = $Port
    TimeoutSeconds = $TimeoutSeconds
    StableSeconds = $StableSeconds
    RequireNoUserPlugins = $true
}
if ($KeepTemp) { $runArgs.KeepTemp = $true }

& $smoke @runArgs
exit $LASTEXITCODE
