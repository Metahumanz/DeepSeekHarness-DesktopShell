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

$hide = Get-MethodBody $cs 'private void HideToTray()' 'protected override void WndProc'
$restore = Get-MethodBody $cs 'private void RestoreFromTray()' '/// <summary>'

Assert-True 'HideToTray exists and calls Hide' ($hide -match '(?m)\bHide\(\);')
Assert-True 'RestoreFromTray exists and calls Show' ($restore -match '(?m)\bShow\(\);')
Assert-True 'HideToTray does not mutate ShowInTaskbar' ($hide -notmatch 'ShowInTaskbar\s*=')
Assert-True 'RestoreFromTray does not mutate ShowInTaskbar' ($restore -notmatch 'ShowInTaskbar\s*=')
Assert-True 'tray close remains deferred with BeginInvoke' ($cs -match 'BeginInvoke\(\(MethodInvoker\)delegate' -and $cs -match 'trayTransition')
Assert-True 'restore does not recreate WebView' ($restore -notmatch 'CreateWebViewControl|new\s+WebView2|ReplaceWebViewControlAsync')
Assert-True 'handle-created diagnostic includes instance and hwnd' ($cs -match 'HANDLE created instance=' -and $cs -match 'hwnd=.*ToString\("X"\)')
Assert-True 'handle-destroyed diagnostic includes instance hwnd and recreating' ($cs -match 'HANDLE destroyed instance=' -and $cs -match 'recreating=.*ToLowerInvariant')
Assert-True 'diagnostics use handle lifecycle overrides' ($cs -match 'protected override void OnHandleCreated\(EventArgs e\)' -and $cs -match 'protected override void OnHandleDestroyed\(EventArgs e\)')
Assert-True 'legal pre-handle dialog ShowInTaskbar settings remain' ($cs -match 'dialog\.ShowInTaskbar = false;' -and $cs -match 'ShowInTaskbar = false;')

if ($fail -eq 0) { Write-Host 'TRAY HANDLE LIFECYCLE TEST PASSED' } else { Write-Host "FAILURES: $fail" }
exit $(if ($fail -eq 0) { 0 } else { 1 })
