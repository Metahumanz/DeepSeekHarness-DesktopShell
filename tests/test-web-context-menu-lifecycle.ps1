$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$cs = [System.IO.File]::ReadAllText((Join-Path $repo 'src\DeepSeekHarness.cs'))

$fail = 0
function Assert-True([string]$label, [bool]$condition) {
    if ($condition) { Write-Host "PASS: $label" }
    else { $script:fail++; Write-Host "FAIL: $label" }
}

# WebView 右键菜单在 MainForm 生命周期内复用一个 ContextMenuStrip：
# 不在 Closed 或替换路径 Dispose，避免 WinForms 关闭流程中访问已释放对象。
Assert-True "single reusable webContextMenu field exists" ($cs -match 'private ContextMenuStrip webContextMenu;')
Assert-True "EnsureWebContextMenu creates once" ($cs -match 'private ContextMenuStrip EnsureWebContextMenu\(\)')
Assert-True "menu items are cleared on each request" ($cs -match 'menu\.Items\.Clear\(\)')
Assert-True "Closed only completes deferral" ($cs -match 'webContextMenu\.Closed \+= delegate')
Assert-True "no menu.Dispose anywhere in web menu flow" ($cs -cnotmatch 'menu\.Dispose\(\);')
Assert-True "no deferred dispose helper remains" ($cs -notmatch 'DisposeWebContextMenuDeferred')
Assert-True "CompleteWebContextDeferral exists" ($cs -match 'private void CompleteWebContextDeferral\(\)')
Assert-True "deferral completion is one-shot guarded" ($cs -match 'webContextDeferralCompleted')
Assert-True "menu disposed only in MainForm.Dispose" ($cs -match 'if \(webContextMenu != null\) webContextMenu\.Dispose\(\);')

if ($fail -eq 0) { Write-Host 'WEB CONTEXT MENU LIFECYCLE TEST PASSED' } else { Write-Host "FAILURES: $fail" }
exit $(if ($fail -eq 0) { 0 } else { 1 })
