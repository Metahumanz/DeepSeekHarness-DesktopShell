$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$installer = Join-Path $repo 'scripts\Install-Release.ps1'
$uninstaller = Join-Path $repo 'scripts\Uninstall-DesktopShell.ps1'
$base = Join-Path $env:TEMP ('dsh-uninst-test-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $base | Out-Null

$appFiles = @(
    'DeepSeekHarness.exe','Microsoft.Web.WebView2.Core.dll','Microsoft.Web.WebView2.WinForms.dll',
    'WebView2Loader.dll','DeepSeekHarness.ico','DeepSeekHarness-Light.ico','DeepSeekHarness-Dark.ico',
    'DeepSeekHarness.svg','Manage-Dsh.ps1','Uninstall-DesktopShell.ps1','version.txt'
)
$pkg = Join-Path $base 'pkg'
New-Item -ItemType Directory -Force -Path $pkg | Out-Null
foreach ($f in $appFiles) { Set-Content -LiteralPath (Join-Path $pkg $f) -Value 'x' -Encoding ascii }

$fail = 0

# 保护真实开始菜单目录：备份 -> 测试 -> 恢复
$sm = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\DeepSeek Harness'
$smBak = Join-Path $env:TEMP ('dsh-sm-backup-' + [guid]::NewGuid().ToString('N'))
$hadSm = Test-Path -LiteralPath $sm
if ($hadSm) { Move-Item -LiteralPath $sm -Destination $smBak }

try {
    # ---- U1: 非所有权目录 -> 拒绝，什么都不删 ----
    $u1 = Join-Path $base 'not-owned'
    New-Item -ItemType Directory -Force -Path $u1 | Out-Null
    Set-Content -LiteralPath (Join-Path $u1 'user-file.txt') -Value 'keep me'
    Copy-Item -LiteralPath $uninstaller -Destination (Join-Path $u1 'Uninstall-DesktopShell.ps1') -Force
    & pwsh -NoProfile -File (Join-Path $u1 'Uninstall-DesktopShell.ps1') -Force *> $null
    $u1code = $LASTEXITCODE
    Write-Host ("U1 non-owned exit={0} user-file-kept={1}" -f $u1code, (Test-Path -LiteralPath (Join-Path $u1 'user-file.txt')))
    if ($u1code -eq 0) { $fail++; 'U1 FAILED: should refuse' }
    if (-not (Test-Path -LiteralPath (Join-Path $u1 'user-file.txt'))) { $fail++; 'U1 FAILED: user file deleted' }

    # ---- U2: 正常安装后的 owned 目录，仅卸载壳 -> 删除 app 目录 ----
    $u2app = Join-Path $base 'owned-install'
    & pwsh -NoProfile -File $installer -SetupDir $pkg -InstallDir $u2app -NoShortcuts -NoLaunch -NoWizard *> $null
    if ($LASTEXITCODE -ne 0) { $fail++; 'U2 FAILED: setup install' }
    # 假发布包里的卸载器是占位文件，覆盖为真实卸载器
    Copy-Item -LiteralPath $uninstaller -Destination (Join-Path $u2app 'Uninstall-DesktopShell.ps1') -Force
    & pwsh -NoProfile -File (Join-Path $u2app 'Uninstall-DesktopShell.ps1') -Force *> $null
    $u2code = $LASTEXITCODE
    Write-Host ("U2 owned-shell-only exit={0}" -f $u2code)
    Start-Sleep -Seconds 6
    $u2gone = -not (Test-Path -LiteralPath $u2app)
    Write-Host ("U2 app-dir-deleted={0}" -f $u2gone)
    if ($u2code -ne 0) { $fail++; 'U2 FAILED: uninstall exit' }
    if (-not $u2gone) { $fail++; 'U2 FAILED: app dir not deleted' }

    # ---- U3: P0-2 方向 —— DSH_HOME 是 app 目录的父目录 -> 拒绝删除 DSH_HOME，仅卸载壳 ----
    $u3parent = Join-Path $base 'P02-parent'
    $u3app = Join-Path $u3parent 'DeepSeek Harness DesktopShell'
    & pwsh -NoProfile -File $installer -SetupDir $pkg -InstallDir $u3app -NoShortcuts -NoLaunch -NoWizard *> $null
    if ($LASTEXITCODE -ne 0) { $fail++; 'U3 FAILED: setup install' }
    Copy-Item -LiteralPath $uninstaller -Destination (Join-Path $u3app 'Uninstall-DesktopShell.ps1') -Force
    # 改 install-state.json：dshHome = app 的父目录（模拟危险的 DSH_HOME 配置）
    $st = Get-Content -LiteralPath (Join-Path $u3app 'install-state.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    $st.dshHome = $u3parent
    $st | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $u3app 'install-state.json') -Encoding utf8NoBOM
    # 父目录里放一个哨兵文件，验证没被删除
    Set-Content -LiteralPath (Join-Path $u3parent 'sentinel.txt') -Value 'keep me'
    & pwsh -NoProfile -File (Join-Path $u3app 'Uninstall-DesktopShell.ps1') -Force -Full *> $null
    $u3code = $LASTEXITCODE
    Write-Host ("U3 full-uninstall-with-parent-dshhome exit={0}" -f $u3code)
    Start-Sleep -Seconds 6
    $u3sentinel = Test-Path -LiteralPath (Join-Path $u3parent 'sentinel.txt')
    $u3appGone = -not (Test-Path -LiteralPath $u3app)
    Write-Host ("U3 parent-kept={0} app-dir-deleted={1}" -f $u3sentinel, $u3appGone)
    if ($u3code -ne 0) { $fail++; 'U3 FAILED: uninstall exit' }
    if (-not $u3sentinel) { $fail++; 'U3 FAILED: DSH_HOME parent deleted!' }
    if (-not $u3appGone) { $fail++; 'U3 FAILED: app dir should still be deleted (shell-only)' }
}
finally {
    # 恢复真实开始菜单目录
    if (Test-Path -LiteralPath $sm) { Remove-Item -LiteralPath $sm -Recurse -Force -ErrorAction SilentlyContinue }
    if ($hadSm -and (Test-Path -LiteralPath $smBak)) { Move-Item -LiteralPath $smBak -Destination $sm }
}

Write-Host ("StartMenu-restored={0}" -f $hadSm)
if ($hadSm -ne (Test-Path -LiteralPath $sm)) { $fail++; 'FAILED: start menu not restored' }
if ($fail -eq 0) { Write-Host 'ALL UNINSTALL TESTS PASSED' } else { Write-Host "FAILURES: $fail" }
Remove-Item -LiteralPath $base -Recurse -Force -ErrorAction SilentlyContinue
exit $(if ($fail -eq 0) { 0 } else { 1 })