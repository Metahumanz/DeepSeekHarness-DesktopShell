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

$toggle = Get-MethodBody $cs 'private void ToggleTrayWindow()' 'private void RestoreFromTray()'
$restore = Get-MethodBody $cs 'private void RestoreFromTray()' 'private void PrepareTrayShowAnimation()'
$prepare = Get-MethodBody $cs 'private void PrepareTrayShowAnimation()' 'private void StartTrayShowAnimation()'
$advance = Get-MethodBody $cs 'private void AdvanceTrayShowAnimation()' 'private void StopTrayShowAnimation(bool restoreOpacity)'
$stop = Get-MethodBody $cs 'private void StopTrayShowAnimation(bool restoreOpacity)' '/// <summary>'

Assert-True 'tray double-click enters toggle handler' ($cs -match 'trayIcon\.DoubleClick \+= delegate \{ ToggleTrayWindow\(\); \};')
Assert-True 'toggle restores hidden/minimized window' ($toggle -match 'hiddenToTray \|\| !Visible \|\| WindowState == FormWindowState\.Minimized' -and $toggle -match 'RestoreFromTray\(\);')
Assert-True 'toggle hides visible window through deferred path' ($toggle -match 'BeginInvoke\(\(MethodInvoker\)delegate' -and $toggle -match 'HideToTray\(\);')
Assert-True 'toggle does not dispose the Form' ($toggle -notmatch '\bClose\(\);')
Assert-True 'restore keeps the existing Form/WebView' ($restore -match 'Show\(\);' -and $restore -notmatch 'new\s+WebView2|ReplaceWebViewControlAsync|CreateWebViewControl')
Assert-True 'restore starts show animation' ($restore -match 'PrepareTrayShowAnimation\(\);' -and $restore -match 'StartTrayShowAnimation\(\);')
Assert-True 'animation uses bounded opacity steps' ($cs -match 'TrayShowAnimationSteps = 12' -and $prepare -match 'Opacity = 0\.0' -and $advance -match 'Math\.Min\(1\.0' -and $advance -match 'Opacity = trayShowAnimationTargetOpacity \* progress')
Assert-True 'animation timer is lightweight' ($cs -match 'trayShowAnimationTimer\.Interval = 16' -and $cs -match 'trayShowAnimationTimer\.Tick \+= delegate \{ AdvanceTrayShowAnimation\(\); \};')
Assert-True 'hide stops animation before hiding' ($cs -match 'StopTrayShowAnimation\(true\);\s*Hide\(\);')
Assert-True 'dispose stops and disposes animation timer' ($cs -match 'trayShowAnimationTimer\.Stop\(\); trayShowAnimationTimer\.Dispose\(\);')
Assert-True 'toggle is guarded during true shutdown' ($toggle -match 'if \(LifetimeCancelled \|\| trayTransition\) return;')

if ($fail -eq 0) { Write-Host 'TRAY TOGGLE ANIMATION TEST PASSED' } else { Write-Host "FAILURES: $fail" }
exit $(if ($fail -eq 0) { 0 } else { 1 })
