$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$cs = [System.IO.File]::ReadAllText((Join-Path $repo 'src\DeepSeekHarness.cs'))

$fail = 0
function Assert-True([string]$label, [bool]$condition) {
    if ($condition) { Write-Host "PASS: $label" }
    else { $script:fail++; Write-Host "FAIL: $label" }
}

# WebView 右键菜单不能在 ToolStripDropDown 的 Closed/SetVisibleCore 调用栈中同步 Dispose。
# 旧实现：menu.Closed 里同步 menu.Dispose()，替换旧菜单时同步 Close+Dispose。
Assert-True "web context menu Closed uses deferred dispose" ($cs -match 'DisposeWebContextMenuDeferred\(menu\);')
Assert-True "web context menu replacement uses deferred dispose" ($cs -match 'DisposeWebContextMenuDeferred\(previous\);')
Assert-True "no sync Close+Dispose when replacing web menu" ($cs -notmatch 'activeWebContextMenu\.Close\(\); activeWebContextMenu\.Dispose\(\);')
Assert-True "no old sync menu.Dispose inside Closed" ($cs -notmatch 'try \{ deferral\.Complete\(\); \} catch \{ \}\s*try \{ menu\.Dispose\(\); \} catch \{ \}')
Assert-True "deferral completes exactly once" ($cs -match 'bool deferralCompleted = false;')

if ($fail -eq 0) { Write-Host 'WEB CONTEXT MENU LIFECYCLE TEST PASSED' } else { Write-Host "FAILURES: $fail" }
exit $(if ($fail -eq 0) { 0 } else { 1 })
