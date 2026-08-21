$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$installer = Join-Path $repo 'scripts\Install-Release.ps1'
$uninstaller = Join-Path $repo 'scripts\Uninstall-DesktopShell.ps1'
# 宿主无关：用当前运行测试的 PowerShell 本体执行子进程（pwsh 与 5.1 均可）
$hostExe = Join-Path $PSHOME $(if ($PSVersionTable.PSEdition -eq 'Core') { 'pwsh.exe' } else { 'powershell.exe' })
$base = Join-Path $env:TEMP ('dsh-uninst-test-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $base | Out-Null

# 隔离环境（与 test-install-ownership.ps1 相同）：-NoWizard 仍执行无人值守初始化
$shimDir = Join-Path $base 'shim'
New-Item -ItemType Directory -Force -Path $shimDir | Out-Null
"@echo off`r`necho 22.19.0`r`n" | Set-Content -LiteralPath (Join-Path $shimDir 'node.cmd') -Encoding ascii
"@echo off`r`necho 0.1.0-rc.7`r`n" | Set-Content -LiteralPath (Join-Path $shimDir 'npx.cmd') -Encoding ascii
$testDshHome = Join-Path $base 'dsh-home'
New-Item -ItemType Directory -Force -Path $testDshHome | Out-Null
$origPath = $env:Path
$origDshHome = $env:DSH_HOME
$origAppData = $env:APPDATA
$testAppData = Join-Path $base 'appdata'
New-Item -ItemType Directory -Force -Path $testAppData | Out-Null
# Install-Release/Uninstall-DesktopShell 用 APPDATA 解析开始菜单；测试必须把它
# 指向自己的临时树，不能搬动或清理用户真实 Start Menu。
$env:APPDATA = $testAppData

function Invoke-HermeticInstall([string]$target) {
    $env:Path = "$shimDir;$env:SystemRoot\System32;$env:SystemRoot"
    $env:DSH_HOME = $testDshHome
    try {
        & $hostExe -NoProfile -File $installer -SetupDir $pkg -InstallDir $target -NoShortcuts -NoLaunch -NoWizard *> $null
        return [int]$LASTEXITCODE
    } finally {
        $env:Path = $origPath
        $env:DSH_HOME = $origDshHome
    }
}

$appFiles = @(
    'DeepSeekHarness.exe','Microsoft.Web.WebView2.Core.dll','Microsoft.Web.WebView2.WinForms.dll',
    'WebView2Loader.dll','DeepSeekHarness.ico','DeepSeekHarness-Light.ico','DeepSeekHarness-Dark.ico',
    'DeepSeekHarness.svg','Manage-Dsh.ps1','Uninstall-DesktopShell.ps1','version.txt','COMPATIBILITY.json'
)
$pkg = Join-Path $base 'pkg'
New-Item -ItemType Directory -Force -Path $pkg | Out-Null
foreach ($f in $appFiles) { Set-Content -LiteralPath (Join-Path $pkg $f) -Value 'x' -Encoding ascii }
# -NoWizard 会真实执行管理器：这两个脚本必须是真实副本
Copy-Item -LiteralPath (Join-Path $repo 'scripts\Manage-Dsh.ps1') -Destination (Join-Path $pkg 'Manage-Dsh.ps1') -Force
Copy-Item -LiteralPath $uninstaller -Destination (Join-Path $pkg 'Uninstall-DesktopShell.ps1') -Force

$fail = 0

# 找一个确定空闲的本地端口。完整卸载前卸载器会按 settings.json 的端口探测并停止
# “外部 DSH”——测试绝不能指向真实 DSH 端口（可能把宿主机上的 DSH/自身环境杀掉），
# 因此卸载前把临时安装的 settings.json 端口改到空闲端口。
function Get-FreeTcpPort {
    foreach ($candidate in 40000..49999) {
        $client = [System.Net.Sockets.TcpClient]::new()
        try {
            $iar = $client.BeginConnect('127.0.0.1', $candidate, $null, $null)
            if (-not $iar.AsyncWaitHandle.WaitOne(150)) { return $candidate }
            $client.EndConnect($iar)
        } catch { return $candidate } finally { $client.Dispose() }
    }
    return 0
}
function Set-TestAppPort([string]$appDir) {
    $settings = Join-Path $appDir 'settings.json'
    if (-not (Test-Path -LiteralPath $settings -PathType Leaf)) { return }
    $port = Get-FreeTcpPort
    if ($port -le 0) { Write-Error '找不到空闲端口'; exit 1 }
    $cfg = Get-Content -LiteralPath $settings -Raw -Encoding UTF8 | ConvertFrom-Json
    $cfg.port = $port
    [System.IO.File]::WriteAllText($settings, ($cfg | ConvertTo-Json -Depth 20), [System.Text.UTF8Encoding]::new($false))
}

# 保护临时开始菜单目录：备份 -> 测试 -> 恢复
$sm = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\DeepSeek Harness'
$smBak = Join-Path $env:TEMP ('dsh-sm-backup-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Force -Path $sm
Set-Content -LiteralPath (Join-Path $sm 'user-sentinel.txt') -Value 'keep me' -Encoding ascii
$hadSm = Test-Path -LiteralPath $sm
if ($hadSm) { Move-Item -LiteralPath $sm -Destination $smBak }

try {
    # ---- U1: 非所有权目录 -> 拒绝，什么都不删 ----
    $u1 = Join-Path $base 'not-owned'
    New-Item -ItemType Directory -Force -Path $u1 | Out-Null
    Set-Content -LiteralPath (Join-Path $u1 'user-file.txt') -Value 'keep me'
    Copy-Item -LiteralPath $uninstaller -Destination (Join-Path $u1 'Uninstall-DesktopShell.ps1') -Force
    & $hostExe -NoProfile -File (Join-Path $u1 'Uninstall-DesktopShell.ps1') -Force *> $null
    $u1code = $LASTEXITCODE
    Write-Host ("U1 non-owned exit={0} user-file-kept={1}" -f $u1code, (Test-Path -LiteralPath (Join-Path $u1 'user-file.txt')))
    if ($u1code -eq 0) { $fail++; 'U1 FAILED: should refuse' }
    if (-not (Test-Path -LiteralPath (Join-Path $u1 'user-file.txt'))) { $fail++; 'U1 FAILED: user file deleted' }

    # ---- U2: 正常安装后的 owned 目录，仅卸载壳 -> 删除 app 目录 ----
    $u2app = Join-Path $base 'owned-install'
    if ((Invoke-HermeticInstall $u2app) -ne 0) { $fail++; 'U2 FAILED: setup install' }
    # 假发布包里的卸载器是占位文件，覆盖为真实卸载器
    Copy-Item -LiteralPath $uninstaller -Destination (Join-Path $u2app 'Uninstall-DesktopShell.ps1') -Force
    # 端口改空闲：防止卸载器把宿主机真实 DSH 当外部后端
    Set-TestAppPort $u2app
    & $hostExe -NoProfile -File (Join-Path $u2app 'Uninstall-DesktopShell.ps1') -Force *> $null
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
    if ((Invoke-HermeticInstall $u3app) -ne 0) { $fail++; 'U3 FAILED: setup install' }
    Copy-Item -LiteralPath $uninstaller -Destination (Join-Path $u3app 'Uninstall-DesktopShell.ps1') -Force
    # 改 install-state.json：dshHome = app 的父目录（模拟危险的 DSH_HOME 配置）
    $st = Get-Content -LiteralPath (Join-Path $u3app 'install-state.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    $st.dshHome = $u3parent
    [System.IO.File]::WriteAllText((Join-Path $u3app 'install-state.json'), ($st | ConvertTo-Json -Depth 10), [System.Text.UTF8Encoding]::new($false))
    # 端口改空闲：防止卸载器把宿主机真实 DSH 当外部后端
    Set-TestAppPort $u3app
    # 父目录里放一个哨兵文件，验证没被删除
    Set-Content -LiteralPath (Join-Path $u3parent 'sentinel.txt') -Value 'keep me'
    & $hostExe -NoProfile -File (Join-Path $u3app 'Uninstall-DesktopShell.ps1') -Force -Full *> $null
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
    # 恢复临时开始菜单目录，并还原宿主环境变量
    if (Test-Path -LiteralPath $sm) { Remove-Item -LiteralPath $sm -Recurse -Force -ErrorAction SilentlyContinue }
    if ($hadSm -and (Test-Path -LiteralPath $smBak)) { Move-Item -LiteralPath $smBak -Destination $sm }
    $env:APPDATA = $origAppData
}

Write-Host ("StartMenu-restored={0}" -f $hadSm)
if ($hadSm -ne (Test-Path -LiteralPath $sm)) { $fail++; 'FAILED: start menu not restored' }
if ($fail -eq 0) { Write-Host 'ALL UNINSTALL TESTS PASSED' } else { Write-Host "FAILURES: $fail" }
Remove-Item -LiteralPath $base -Recurse -Force -ErrorAction SilentlyContinue
exit $(if ($fail -eq 0) { 0 } else { 1 })
