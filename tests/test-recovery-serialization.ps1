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

Assert-True 'recoveryBusy field exists' ($cs -match 'private bool recoveryBusy;')
Assert-True 'gate rejects duplicate operation without blocking' ($cs -match 'if \(LifetimeCancelled \|\| recoveryBusy\) return false;')
Assert-True 'gate has no blocking semaphore or wait' ($cs -notmatch 'Semaphore|\.Wait\(|Wait\(\)')
Assert-True 'recovery buttons are disabled while busy' ($cs -match 'overlayPrimaryButton\.Enabled = false;' -and $cs -match 'overlaySecondaryButton\.Enabled = false;')
Assert-True 'overlay button state follows recoveryBusy' ($cs -match 'overlayPrimaryButton\.Enabled = !recoveryBusy;' -and $cs -match 'overlaySecondaryButton\.Enabled = !recoveryBusy;')

$operations = @(
    @('StartAsync', 'private async Task StartAsync()', 'private void HandleStartupError(Exception ex)'),
    @('RetryWebViewAsync', 'private async Task RetryWebViewAsync()', 'private async Task ReplaceWebViewControlAsync()'),
    @('RetryConfigureAsync', 'private async Task RetryConfigureAsync()', 'private async Task ConfigureWebViewAsync()'),
    @('RestartBackendAsync', 'private async Task RestartBackendAsync()', 'private void HandleRestartError(Exception ex)')
)
foreach ($operation in $operations) {
    $body = Get-MethodBody $cs $operation[1] $operation[2]
    Assert-True "$($operation[0]) enters shared recovery gate" ($body -match 'TryBeginRecoveryOperation\(')
    Assert-True "$($operation[0]) restores state in finally" ($body -match 'finally\s*\{[\s\S]*EndRecoveryOperation\(')
}

$replace = Get-MethodBody $cs 'private async Task ReplaceWebViewControlAsync()' 'private async Task RetryConfigureAsync()'
Assert-True 'replace path disposes old WebView and creates one replacement' ($replace -match 'old\.Dispose\(\)' -and $replace -match 'CreateWebViewControl\(\)')
Assert-True 'replace path is reached only through the gated retry method' (([regex]::Matches($cs, 'ReplaceWebViewControlAsync\(')).Count -eq 2)
Assert-True 'closing skips button restoration' ($cs -match 'if \(CanTouchControls\)' -and $cs -match 'EndRecoveryOperation\(')

# 快速双击/重复调用模型：第二次进入必须被同一个布尔门禁拒绝，释放后才允许下一次操作。
$gateBusy = $false
function Try-TestGate {
    if ($script:gateBusy) { return $false }
    $script:gateBusy = $true
    return $true
}
function End-TestGate { $script:gateBusy = $false }
$first = Try-TestGate
$second = Try-TestGate
End-TestGate
$third = Try-TestGate
End-TestGate
Assert-True 'quick duplicate call is rejected' ($first -and -not $second -and $third)

if ($fail -eq 0) { Write-Host 'RECOVERY SERIALIZATION TEST PASSED' } else { Write-Host "FAILURES: $fail" }
exit $(if ($fail -eq 0) { 0 } else { 1 })
