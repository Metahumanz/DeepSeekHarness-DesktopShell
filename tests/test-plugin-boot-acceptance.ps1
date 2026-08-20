$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$source = Join-Path $repo 'scripts\Manage-Dsh.ps1'
$ps = [System.IO.File]::ReadAllText($source)

$fail = 0
function Assert-True([string]$label, [bool]$condition) {
    if ($condition) { Write-Host "PASS: $label" }
    else { $script:fail++; Write-Host "FAIL: $label" }
}

$start = $ps.IndexOf('function Test-PluginProfileBootCompatibility', [System.StringComparison]::Ordinal)
$end = $ps.IndexOf('function Get-Npx', $start, [System.StringComparison]::Ordinal)
$body = if ($start -ge 0 -and $end -gt $start) { $ps.Substring($start, $end - $start) } else { '' }
$catalogStart = $ps.IndexOf('$PluginCatalog = @(', [System.StringComparison]::Ordinal)
$catalogEnd = $ps.IndexOf('function Read-Default', $catalogStart, [System.StringComparison]::Ordinal)
$catalog = if ($catalogStart -ge 0 -and $catalogEnd -gt $catalogStart) { $ps.Substring($catalogStart, $catalogEnd - $catalogStart) } else { '' }

Assert-True 'generic Profile boot acceptance helper exists' ($body -match 'function Test-PluginProfileBootCompatibility')
Assert-True 'acceptance uses a random free port and avoids current port' (
    $body -match 'Get-FreeTcpPort' -and
    $body -match 'Test-PortOpen \$current\.Port' -and
    $body -match '未执行独立 BootReady 验收')
Assert-True 'acceptance requires the ready banner' ($body -match 'dsh\\s\+web:' -and $body -match 'bannerSeen')
Assert-True 'acceptance requires HTTP 200' ($body -match 'Test-Http200' -and $body -match '200')
Assert-True 'acceptance requires stable ten-second run' (
    $body -match 'TotalSeconds -lt 10' -and
    $body -match 'StableSeconds = 10' -and
    $body -match '稳定 10 秒')
Assert-True 'acceptance requires process to remain alive' ($body -match '\$probe\.HasExited' -and $body -match '进程仍存活')
Assert-True 'probe cleanup is PID scoped and recursive' (
    $body -match 'Start-Process' -and
    $ps -match 'taskkill\.exe' -and
    $ps -match '/PID \$process\.Id /T /F' -and
    $ps -notmatch 'Get-Process\s+node|Get-Process\s+cmd|Get-Process\s+powershell')
Assert-True 'plugin add success is not called compatibility' (
    $ps -match '仅安装成功，尚未证明运行兼容' -and
    $ps -match '安装成功 ≠ 运行兼容' -and
    $ps -match 'Test-PluginProfileBootCompatibility \$profile')
Assert-True 'real Profile is passed to DSH boot probe' ($ps.Contains('profileArg') -and $ps.Contains('New-PluginBootProbeCommand $current $profile'))
Assert-True 'dsh-remote is absent from the active recommendation catalog' (
    $catalog -notmatch "Id='remote'" -and
    $catalog -notmatch 'dsh-remote' -and
    $catalog -match 'No=18; Id=\x27video\x27')

if ($fail -eq 0) { Write-Host 'PLUGIN BOOT ACCEPTANCE TESTS PASSED' } else { Write-Host "FAILURES: $fail" }
exit $(if ($fail -eq 0) { 0 } else { 1 })
