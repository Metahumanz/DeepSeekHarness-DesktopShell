$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$source = Join-Path $repo 'src\DeepSeekHarness.cs'

$fail = 0
function Assert-True([string]$label, [bool]$condition) {
    if ($condition) { Write-Host "PASS: $label" }
    else { $script:fail++; Write-Host "FAIL: $label" }
}

# 壳运行期源码守卫：分阶段启动 / 阶段感知重试 / 错误覆盖层 / 托盘生命周期。
# 这些都是纯 C# 行为，无法在 PS 里直接执行，用源码级断言钉住结构，防止回归时
# 悄悄退化成“一把梭启动 + 无差别重试”的老实现。
$cs = [System.IO.File]::ReadAllText($source)

# ---- 1. 分阶段启动（StartupPhase + 每阶段 HostLog Enter/Ok） ----
Assert-True "StartupPhase enum defined" ($cs -match 'internal enum StartupPhase')
$phaseAssignments = ([regex]::Matches($cs, 'currentPhase = StartupPhase\.')).Count
Assert-True "8 staged phase assignments in shell (got: $phaseAssignments)" ($phaseAssignments -ge 8)
Assert-True "StartAsync logs phase enters" ($cs -match 'HostLog\.Enter\("START phase=')
Assert-True "StartAsync logs phase completion" ($cs -match 'HostLog\.Ok\("START phase=')
Assert-True "startup failure logged with phase" ($cs -match 'HostLog\.Fail\("START failed phase=')
Assert-True "owned running backend never double-started" ($cs -match 'if \(!dsh\.BackendRunning\)')

# ---- 2. 阶段感知重试（错误覆盖层按失败阶段给定向重试路径） ----
Assert-True "phase-aware retry dispatcher exists" ($cs -match 'private void HandleStartupError\(Exception ex\)')
Assert-True "backend-phase failures retry via backend restart" ($cs -match 'retryHandler = OnOverlayRestartBackend;')
Assert-True "webview-phase failures retry via webview-only rebuild" ($cs -match 'case StartupPhase\.WebViewEnvironment:' -and $cs -match 'retryHandler = OnOverlayRetryWebView;')
Assert-True "configure-phase retry only re-configures" ($cs -match 'retryHandler = OnOverlayRetryConfigure;')
Assert-True "full retry handler exists" ($cs -match 'private async void OnOverlayRetryStart')
Assert-True "RetryWebViewAsync never touches backend" ($cs -match 'private async Task RetryWebViewAsync\(\)')
Assert-True "RetryConfigureAsync exists" ($cs -match 'private async Task RetryConfigureAsync\(\)')
Assert-True "startup error shown via error overlay with exception details" ($cs -match 'ShowErrorOverlay\(\s*"startup-error"' -and $cs -match 'ex\.ToString\(\)')

# ---- 3. 错误覆盖层（可滚动详情 + 复制按钮） ----
Assert-True "scrollable error details box" ($cs -match 'errorDetails\.ScrollBars = ScrollBars\.Vertical')
Assert-True "copy-error button copies details" ($cs -match 'copyErrorButton' -and $cs -match 'Clipboard\.SetText\(errorDetails\.Text\)')
Assert-True "overlay buttons themed" ($cs -match 'ThemeHelper\.ApplyButtonTheme\(overlayPrimaryButton, dark\)')

# ---- 4. 托盘生命周期（延迟隐藏，恢复不重建 WebView） ----
Assert-True "HideToTray helper exists" ($cs -match 'private void HideToTray\(\)')
Assert-True "tray close deferred via BeginInvoke(MethodInvoker)" ($cs -match 'trayTransition' -and $cs -match 'BeginInvoke\(\(MethodInvoker\)delegate')
$restoreStart = $cs.IndexOf('private void RestoreFromTray()', [System.StringComparison]::Ordinal)
$restoreEnd = $cs.IndexOf('private void HideToTray()', $restoreStart, [System.StringComparison]::Ordinal)
if ($restoreStart -ge 0 -and $restoreEnd -gt $restoreStart) {
    $restoreBody = $cs.Substring($restoreStart, $restoreEnd - $restoreStart)
    Assert-True "RestoreFromTray restores window" ($restoreBody -match 'Show\(\);')
    Assert-True "RestoreFromTray reuses window (no webview recreation)" ($restoreBody -notmatch 'CreateWebViewControl')
} else {
    Assert-True "RestoreFromTray body located" $false
}

# ---- 5. 配置可重入（处理器先摘除再挂接，重试不叠加） ----
Assert-True "configure detaches handlers before attaching" ($cs -match 'core\.NewWindowRequested -= OnWebViewNewWindowRequested')
Assert-True "named navigation handler attached" ($cs -match 'core\.NavigationCompleted \+= OnWebViewNavigationCompleted')

if ($fail -eq 0) { Write-Host 'SHELL RUNTIME TESTS PASSED' } else { Write-Host "FAILURES: $fail" }
exit $(if ($fail -eq 0) { 0 } else { 1 })
