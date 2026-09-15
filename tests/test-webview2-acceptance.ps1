$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$scriptText = [IO.File]::ReadAllText((Join-Path $repo 'scripts\Test-DshWebView2Acceptance.ps1'))

$fail = 0
function Assert-True([string]$label, [bool]$condition) {
    if ($condition) { Write-Host "PASS: $label" }
    else { $script:fail++; Write-Host "FAIL: $label" }
}

Assert-True 'harness pins the sole target rc2 and rejects occupied external ports' (
    $scriptText.Contains("DshVersion = '0.1.5-rc.2'") -and
    $scriptText.Contains("if (`$DshVersion -ne '0.1.5-rc.2')") -and
    $scriptText.Contains('拒绝附着外部 DSH，因为没有本次 BrowserAuth token'))
Assert-True 'first WebView2 navigation consumes only the validated ready URL' (
    $scriptText.Contains('core.Navigate(readyUrl)') -and
    $scriptText.Contains('uri.Port == port') -and
    $scriptText.Contains('host == "127.0.0.1"') -and
    $scriptText -notmatch 'http://127\.0\.0\.1:3080/')
Assert-True 'harness proves main UI, refresh, plugin health and the accessible settings entry' (
    $scriptText.Contains('mainUi = JsTrue') -and
    $scriptText.Contains('core.Reload()') -and
    $scriptText.Contains("getAttribute('aria-label')") -and
    $scriptText.Contains('pluginState = JsTrue') -and
    $scriptText.Contains('settings = JsTrue'))
Assert-True 'result/output never serializes the ready URL or token' (
    $scriptText.Contains('不向日志或结果写入它') -and
    $scriptText.Contains('不把 ready URL、页面内容或 token 写到 stdout') -and
    $scriptText -notmatch 'Console\.WriteLine\([^\r\n]{0,200}readyUrl')

if ($fail -eq 0) { Write-Host 'WEBVIEW2 ACCEPTANCE CONTRACT TESTS PASSED' }
else { Write-Host "FAILURES: $fail" }
exit $(if ($fail -eq 0) { 0 } else { 1 })
