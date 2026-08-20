param(
    [switch]$SkipAnalyzer
)

# 统一验证门禁：CI 与 Release 工作流共用（避免两份测试列表漂移）。
# 包含：全部脚本解析检查、PSScriptAnalyzer(Error)、28 项回归测试。
# 可用当前宿主（pwsh 或 Windows PowerShell 5.1）运行；子进程用同一宿主本体。
# 注意：托盘、WebView2、连续重启、Dream Skin 真实恢复属于人工 Windows 验收
#（见 docs/DREAM_SKIN_ACCEPTANCE.md），源码级测试不能替代。

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$hostExe = Join-Path $PSHOME $(if ($PSVersionTable.PSEdition -eq 'Core') { 'pwsh.exe' } else { 'powershell.exe' })
$tests = @(
    'test-launch-args.ps1',
    'test-npx-version-parser.ps1',
    'test-dsh-version.ps1',
    'test-runner-mode.ps1',
    'test-repair-regex.ps1',
    'test-install-ownership.ps1',
    'test-uninstall-guards.ps1',
    'test-port-owner.ps1',
    'test-host-log.ps1',
    'test-shell-runtime.ps1',
    'test-accepted-dsh.ps1',
    'test-build-x64.ps1',
    'test-restart-state.ps1',
    'test-startup-identity.ps1',
    'test-tray-quit-deferred.ps1',
    'test-tray-handle-lifecycle.ps1',
    'test-lifecycle-cancellation.ps1',
    'test-recovery-serialization.ps1',
    'test-bounded-process-probe.ps1',
    'test-settings-runtime-snapshot.ps1',
    'test-dialog-owner.ps1',
    'test-webview-unresponsive.ps1',
    'test-owned-health-identity.ps1',
    'test-dpi-manifest.ps1',
    'test-web-context-menu-lifecycle.ps1',
    'test-dream-skin-pin.ps1',
    'test-release-immutable.ps1',
    'test-version-source.ps1'
)

Write-Host "== verify: parse ($($hostExe | Split-Path -Leaf)) =="
$files = @(Get-ChildItem -Path (Join-Path $repo 'scripts'), (Join-Path $repo 'tests') -Filter *.ps1 -Recurse)
foreach ($f in $files) {
    $t = @(); $e = @()
    [void][System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$t, [ref]$e)
    if ($e.Count -gt 0) {
        Write-Host "PARSE FAILED: $($f.Name)"
        foreach ($err in $e) { Write-Host "  L$($err.Extent.StartLineNumber): $($err.Message)" }
        exit 1
    }
}
Write-Host "parse ok ($($files.Count) files)."

if (-not $SkipAnalyzer) {
    Write-Host '== verify: PSScriptAnalyzer (Error) =='
    if (-not (Get-Module -ListAvailable PSScriptAnalyzer)) {
        Install-Module PSScriptAnalyzer -Force -Scope CurrentUser -SkipPublisherCheck -RequiredVersion '1.25.0'
    }
    $issues = $files | Invoke-ScriptAnalyzer -Severity Error
    if ($issues) { $issues | Format-Table; exit 1 }
    Write-Host 'analyzer ok.'
}

Write-Host '== verify: regression tests =='
foreach ($t in $tests) {
    & $hostExe -NoProfile -File (Join-Path $repo "tests\$t")
    if ($LASTEXITCODE -ne 0) {
        Write-Host "TEST FAILED: $t"
        exit 1
    }
    Write-Host "PASS: $t"
}

Write-Host 'VERIFY PASSED'
exit 0
