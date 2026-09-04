param(
    [switch]$SkipAnalyzer,
    [ValidateSet('Full', 'Ps51Compat')]
    [string]$Suite = 'Full'
)

# 统一验证门禁：CI 与 Release 工作流共用（避免两份测试列表漂移）。
# Full：全部脚本解析检查、PSScriptAnalyzer(Error)、40 项回归测试。
# Ps51Compat：全部脚本解析检查 + 7 项 Windows PowerShell 5.1 宿主兼容回归。
# 可用当前宿主（pwsh 或 Windows PowerShell 5.1）运行；子进程用同一宿主本体。
# 注意：托盘、WebView2、连续重启、Dream Skin 真实恢复属于人工 Windows 验收
#（见 docs/DREAM_SKIN_ACCEPTANCE.md），源码级测试不能替代。

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$hostExe = Join-Path $PSHOME $(if ($PSVersionTable.PSEdition -eq 'Core') { 'pwsh.exe' } else { 'powershell.exe' })
$fullTests = @(
    'test-launch-args.ps1',
    'test-npx-version-parser.ps1',
    'test-dsh-version.ps1',
    'test-rc2-compat.ps1',
    'test-runner-mode.ps1',
    'test-repair-regex.ps1',
    'test-production-compat-contracts.ps1',
    'test-install-ownership.ps1',
    'test-uninstall-guards.ps1',
    'test-port-owner.ps1',
    'test-host-log.ps1',
    'test-shell-runtime.ps1',
    'test-accepted-dsh.ps1',
    'test-build-x64.ps1',
    'test-restart-state.ps1',
    'test-startup-boot-ready.ps1',
    'test-backend-lifecycle-state.ps1',
    'test-backend-exit-diagnostics.ps1',
    'test-backend-generation-race.ps1',
    'test-plugin-boot-acceptance.ps1',
    'test-plugin-catalog.ps1',
    'test-status-rotator-config.ps1',
    'test-plugin-exclusive-group.ps1',
    'test-plugin-preflight-cleanup.ps1',
    'test-startup-identity.ps1',
    'test-tray-quit-deferred.ps1',
    'test-tray-handle-lifecycle.ps1',
    'test-tray-toggle-animation.ps1',
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

# Windows PowerShell 5.1 只运行真实覆盖宿主差异的契约：.cmd/npx 管道、
# 安装/卸载/首次取消、账本脚本和独立 preflight 进程清理。其余静态源码断言、
# C# 行为 harness 和 UI 结构测试由 PowerShell 7 全量门禁运行一次即可。
$ps51CompatibilityTests = @(
    'test-npx-version-parser.ps1',
    'test-dsh-version.ps1',
    'test-runner-mode.ps1',
    'test-repair-regex.ps1',
    'test-install-ownership.ps1',
    'test-uninstall-guards.ps1',
    'test-plugin-preflight-cleanup.ps1'
)

$tests = if ($Suite -eq 'Ps51Compat') { $ps51CompatibilityTests } else { $fullTests }

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

Write-Host "== verify: regression tests ($Suite, $($tests.Count) scripts) =="
foreach ($t in $tests) {
    & $hostExe -NoProfile -File (Join-Path $repo "tests\$t")
    if ($LASTEXITCODE -ne 0) {
        Write-Host "TEST FAILED: $t"
        exit 1
    }
    Write-Host "PASS: $t"
}

Write-Host "VERIFY PASSED ($Suite)"
exit 0
