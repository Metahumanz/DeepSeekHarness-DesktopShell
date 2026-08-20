$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$cs = [System.IO.File]::ReadAllText((Join-Path $repo 'src\DeepSeekHarness.cs'))

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

$failed = Get-MethodBody $cs 'private void OnWebViewProcessFailed' 'private void ClearUnresponsiveState'
$navigation = Get-MethodBody $cs 'private void OnWebViewNavigationCompleted' 'private void OnWebViewPermissionRequested'
$replace = Get-MethodBody $cs 'private async Task ReplaceWebViewControlAsync()' 'private async Task RetryConfigureAsync()'

Assert-True 'unresponsive state fields exist' ($cs -match 'unresponsiveCount' -and $cs -match 'unresponsiveFirstUtc')
Assert-True 'first unresponsive is retained without immediate replacement' ($failed -match 'unresponsiveCount\+\+' -and $failed -match 'if \(unresponsiveCount < 2\) return;')
Assert-True 'repeat unresponsive shows recovery overlay' ($failed -match 'WEBVIEW unresponsive count=' -and $failed -match 'WebView2 未响应' -and $failed -match 'OnOverlayRetryWebView' -and $failed -match 'OnOverlayDismiss')
Assert-True 'short unresponsive window is bounded' ($failed -match 'TimeSpan\.FromSeconds\(15\)')
Assert-True 'old immediate unresponsive return is gone' ($failed -notmatch 'kind\.IndexOf\("Unresponsive"[\s\S]{0,80}return;')
Assert-True 'navigation recovery clears unresponsive state' ($navigation -match 'ClearUnresponsiveState\(\)')
Assert-True 'replace recovery clears unresponsive state' ($replace -match 'ClearUnresponsiveState\(\)')
Assert-True 'replace path does not stop or start backend' ($replace -notmatch 'StopOwnedBackend|EnsureStarted|RestartBackendAsync|StopBackend')
Assert-True 'clear helper resets count and timestamp' ($cs -match 'private void ClearUnresponsiveState' -and $cs -match 'unresponsiveFirstUtc = DateTime\.MinValue')

if ($fail -eq 0) { Write-Host 'WEBVIEW UNRESPONSIVE TEST PASSED' } else { Write-Host "FAILURES: $fail" }
exit $(if ($fail -eq 0) { 0 } else { 1 })
