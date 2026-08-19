$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$cs = [System.IO.File]::ReadAllText((Join-Path $repo 'src\DeepSeekHarness.cs'))

$fail = 0
function Assert-True([string]$label, [bool]$condition) {
    if ($condition) { Write-Host "PASS: $label" }
    else { $script:fail++; Write-Host "FAIL: $label" }
}

# 托盘“退出”不能在 ToolStrip Click handler 中同步 ShutdownAndClose()。
# 否则 Click handler 返回后 WinForms 自动收起菜单时会访问已 Dispose 的 ContextMenuStrip，
# 抛 System.ObjectDisposedException: ContextMenuStrip。
Assert-True "tray quit is not direct sync ShutdownAndClose" ($cs -notmatch 'quit\.Click \+= delegate \{ ShutdownAndClose\(\); \};')
Assert-True "tray quit defers via BeginInvoke" ($cs -match 'quit\.Click \+= delegate \{ BeginInvoke\(\(MethodInvoker\)ShutdownAndClose\); \};')

if ($fail -eq 0) { Write-Host 'TRAY QUIT DEFERRED TEST PASSED' } else { Write-Host "FAILURES: $fail" }
exit $(if ($fail -eq 0) { 0 } else { 1 })
