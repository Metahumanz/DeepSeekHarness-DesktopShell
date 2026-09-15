$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$manage = [IO.File]::ReadAllText((Join-Path $repo 'scripts\Manage-Dsh.ps1'))
$single = [IO.File]::ReadAllText((Join-Path $repo 'scripts\Test-PluginBootPreflight.ps1'))
$ecosystem = [IO.File]::ReadAllText((Join-Path $repo 'scripts\Test-DshPluginEcosystemPreflight.ps1'))
$scanner = [IO.File]::ReadAllText((Join-Path $repo 'scripts\Scan-DshPluginEcosystem.cjs'))
$cs = [IO.File]::ReadAllText((Join-Path $repo 'src\DeepSeekHarness.cs'))

$fail = 0
function Assert-True([string]$label, [bool]$condition) {
    if ($condition) { Write-Host "PASS: $label" }
    else { $script:fail++; Write-Host "FAIL: $label" }
}

Assert-True 'single-plugin preflight always creates a new DSH_HOME and Profile' (
    $single -match '\$tempHome = Join-Path \(\[IO\.Path\]::GetTempPath\(\)' -and
    $single -match '\$env:DSH_HOME = \$tempHome' -and
    $single.Contains('Normalize-IsolatedProfile'))
Assert-True 'single-plugin preflight installs web-app and plugins before boot' (
    $single.Contains("@deepseek-ai/dsh-web-app@' + `$DshVersion") -and
    $single.Contains("@('plugin', '--profile', `$profile, 'add', `$spec)") -and
    $single.Contains('Web 基础包/插件安装后未发现临时 Profile'))
Assert-True 'the launch contract remains --profile --no-open --port with exact readiness URL' (
    $single.Contains("@('--profile', `$profile)") -and
    $single.Contains("`$webArgs += '--no-open'") -and
    $single.Contains("`$webArgs += @('--port', ([string]`$port))") -and
    $single.Contains('Get-DshReadyUrl') -and $single.Contains('Test-Http200'))
Assert-True 'preflight treats plugin tree failure and pending services as blockers' (
    $single.Contains('Failed to load plugins') -and
    $single.Contains('pending (waiting for service') -and
    $single.Contains('Assert-PluginRuntimeHealthy') -and
    $single.Contains('Test-PluginTreeHealthy'))
Assert-True 'preflight checks restart for every plugin rather than only named historical plugins' (
    $single.Contains("if (`$Validation -eq 'status-rotator')") -and
    $single.Contains("Write-Host 'PLUGIN PREFLIGHT restart=healthy'") -and
    $single.Contains('重启后未达到 ready URL + HTTP 200。'))
Assert-True 'BrowserAuth URLs are authenticated in memory and redacted from output/result evidence' (
    $single.Contains('CookieContainer') -and
    $single.Contains('Redact-BrowserAuthText') -and
    $single.Contains('token-free preflight 结果') -and
    $cs.Contains('ReadyUrl') -and $cs.Contains('RedactSensitiveOutput') -and
    $cs.Contains('仅保存在本次 backend run 的内存中') -and
    $cs.Contains('WEBVIEW navigation-completed success=') -and
    $cs -notmatch 'WEBVIEW navigation-completed[\s\S]{0,240}e\.Uri')
Assert-True 'ecosystem preflight starts clean then follows the generated dependency order' (
    $ecosystem.Contains("DshVersion = '0.1.5-rc.2'") -and
    $ecosystem.Contains('Get-DependencyOrder') -and
    $ecosystem.Contains('$plugin.dependsOn') -and
    $ecosystem.Contains('Get-DependencyChain') -and
    $ecosystem.Contains('-PluginSpec $chainSpecs'))
Assert-True 'every isolated chain and the full combination require the real token-safe WebView2 settings harness' (
    $ecosystem.Contains('-RequireWebView2Settings') -and
    $single.Contains('[switch]$RequireWebView2Settings') -and
    $single.Contains("'PLUGIN PREFLIGHT webview2=healthy refresh=healthy settings=healthy'"))
Assert-True 'ecosystem preflight isolates only a blocker and its downstream chain' (
    $ecosystem.Contains('$blockedParents') -and
    $ecosystem.Contains('上游依赖链已阻断') -and
    $ecosystem.Contains('继续') -eq $false -and
    $ecosystem.Contains('BLOCKED'))
Assert-True 'full combination copies the real patch only after graph validation' (
    $ecosystem.Contains('patchOrphans') -and
    $ecosystem.Contains('-ProfilePatchPath $profilePatch') -and
    $single.Contains('profile-patch=applied-without-logging-content') -and
    $ecosystem.Contains('-PluginSpec $fullSpecs'))
Assert-True 'PASS cannot be inferred from a version-only scan' (
    $scanner.Contains("required = ['bootReady', 'pluginTree', 'http', 'webView2', 'refresh', 'settings', 'restart']") -and
    $scanner.Contains("exact.status === 'PASS'") -and
    $scanner.Contains('exact.installSpec === row.installSpec') -and
    $scanner.Contains('fullPreflightComplete') -and
    $ecosystem.Contains('完整组合 preflight 已通过 BootReady、plugin tree、HTTP、WebView2、刷新、设置页和重启。'))
Assert-True 'production preflight evidence is profile-local and the manager prefers it for upgrade gating' (
    $ecosystem.Contains('.dsh-desktop-shell\PLUGIN_PREFLIGHT_0.1.5-rc.2.json') -and
    $manage.Contains('profilePreflight') -and
    $manage.Contains('sourcePreflight'))
Assert-True 'daily manager does not boot-test or silently mutate the user Profile' (
    $manage.Contains('日常插件安装只确认 package 安装成功') -and
    $manage.Contains('不启动用户真实 Profile') -and
    $manage.Contains('安装成功 ≠ 运行兼容'))

if ($fail -eq 0) { Write-Host 'PLUGIN BOOT ACCEPTANCE TESTS PASSED' }
else { Write-Host "FAILURES: $fail" }
exit $(if ($fail -eq 0) { 0 } else { 1 })
