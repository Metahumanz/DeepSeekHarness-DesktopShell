$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$source = Join-Path $repo 'src\DeepSeekHarness.cs'
$cs = [System.IO.File]::ReadAllText($source)

$fail = 0
function Assert-True([string]$label, [bool]$condition) {
    if ($condition) { Write-Host "PASS: $label" }
    else { $script:fail++; Write-Host "FAIL: $label" }
}
function Get-MethodBody([string]$text, [string]$signature, [string]$nextSignature) {
    $start = $text.IndexOf($signature, [System.StringComparison]::Ordinal)
    if ($start -lt 0) { return '' }
    $end = $text.IndexOf($nextSignature, $start + $signature.Length, [System.StringComparison]::Ordinal)
    if ($end -lt 0) { $end = $text.Length }
    return $text.Substring($start, $end - $start)
}

$start = Get-MethodBody $cs 'private async Task StartAsync()' 'private void ShowBackendInterruption'
$interruption = Get-MethodBody $cs 'private void ShowBackendInterruption' 'private void HandleStartupError'
$startupError = Get-MethodBody $cs 'private void HandleStartupError' 'private async Task RetryWebViewAsync'

Assert-True 'startup lifecycle state fields exist' (
    $cs -match 'private bool bootReadyReached;' -and
    $cs -match 'private bool startOperationActive;' -and
    $cs -match 'private bool startupFailureShown;' -and
    $cs -match 'private bool backendInterruptionShown;')
Assert-True 'start marks operation and resets overlay classification' (
    $start -match 'startOperationActive = true;' -and
    $start -match 'startupFailureShown = false;' -and
    $start -match 'backendInterruptionShown = false;')
Assert-True 'bootReady is latched only after backend phase' (
    $start -match 'if \(!dsh\.BootReady' -and
    $start -match 'backendBootReady = true;' -and
    $start -match 'bootReadyReached = true;')
Assert-True 'pre-BootReady failure uses startup error path' (
    $start -match 'if \(startOperationActive && bootReadyReached && !backendBootReady\)' -and
    $start -match 'else\s+HandleStartupError\(ex\);')
Assert-True 'runtime interruption has dedicated overlay' (
    $interruption -match 'DSH 后端连接已中断' -and
    $interruption -match 'OnOverlayRestartBackend' -and
    $interruption -match 'OnOverlayRetryHealth')
Assert-True 'startup failure names plugin/Profile loading' (
    $startupError -match 'DSH 启动失败' -and
    $startupError -match '插件或 Profile 未能完成加载')
Assert-True 'startup failure offers retry, copy details and log folder' (
    $startupError -match 'primaryText = "重新尝试"' -and
    $startupError -match 'ShowErrorOverlay' -and
    $cs -match 'copyErrorButton\.Text = "复制错误"' -and
    $startupError -match '打开日志目录')
Assert-True 'startup failure is not mislabeled as runtime interruption' (
    $startupError -notmatch 'DSH 后端连接已中断')
Assert-True 'overlay classification is idempotent' (
    $interruption -match 'backendInterruptionShown' -and
    $startupError -match 'startupFailureShown')

if ($fail -eq 0) { Write-Host 'BACKEND LIFECYCLE STATE TESTS PASSED' } else { Write-Host "FAILURES: $fail" }
exit $(if ($fail -eq 0) { 0 } else { 1 })
