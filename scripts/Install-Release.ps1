param(
    [string]$SetupDir = '',
    [string]$InstallDir = '',
    [switch]$NoShortcuts,
    [switch]$NoLaunch,
    [switch]$NoWizard
)

<#
.SYNOPSIS
    安装预编译的 DesktopShell 发布包（zip 解压后运行，或双击 install.bat）。

.DESCRIPTION
    无需 csc 编译、无需下载 WebView2 SDK：
    1. 校验发布包文件齐全
    2. 复制到 %LOCALAPPDATA%\Programs\DeepSeek Harness DesktopShell
       （就地安装时跳过复制）
    3. 迁移旧版设置、写入 install-state.json
    4. 创建开始菜单入口（可 -NoShortcuts 跳过）
    5. 运行首次配置向导（可 -NoWizard 跳过）
    6. 启动桌面壳（可 -NoLaunch 跳过）

.EXAMPLE
    # 在解压后的目录中双击 install.bat，或：
    pwsh -File Install-Release.ps1
.EXAMPLE
    pwsh -File Install-Release.ps1 -SetupDir C:\tmp\dsh-pkg -InstallDir D:\apps\dsh -NoLaunch
#>

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

function Say([string]$text) { Write-Host "[DSH Desktop] $text" -ForegroundColor Cyan }
function Ok([string]$text) { Write-Host "[OK] $text" -ForegroundColor Green }
function Warn([string]$text) { Write-Host "[!]   $text" -ForegroundColor Yellow }
function Fail([string]$text) { throw $text }

# 只关闭“指定 exe 路径”的桌面程序；路径无法读取/不匹配的进程一律不碰。
# 绝不允许按进程名全杀：DSH 宿主本身也可能叫 DeepSeekHarness。
function Stop-DesktopShellProcess([string]$exePath) {
    if ([string]::IsNullOrWhiteSpace($exePath)) { return }
    $target = ''
    try { $target = [IO.Path]::GetFullPath($exePath) } catch { return }
    Get-Process -Name 'DeepSeekHarness' -ErrorAction SilentlyContinue | ForEach-Object {
        $procPath = ''
        try { $procPath = [IO.Path]::GetFullPath($_.MainModule.FileName) } catch { return }
        if ($procPath -ne $target) { return }
        Say "关闭桌面程序 PID $($_.Id)..."
        try {
            $_.CloseMainWindow() | Out-Null
            Start-Sleep -Milliseconds 700
            if (-not $_.HasExited) { Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue }
        } catch {}
    }
}

$homeDir = [Environment]::GetFolderPath('UserProfile')
$dshHome = if ($env:DSH_HOME) { $env:DSH_HOME } else { Join-Path $homeDir '.dsh' }
$localAppData = if ($env:LOCALAPPDATA) { $env:LOCALAPPDATA } else { [Environment]::GetFolderPath('LocalApplicationData') }

if (-not $SetupDir) { $SetupDir = $PSScriptRoot }
if (-not $InstallDir) { $InstallDir = Join-Path $localAppData 'Programs\DeepSeek Harness DesktopShell' }

$appFiles = @(
    'DeepSeekHarness.exe',
    'Microsoft.Web.WebView2.Core.dll',
    'Microsoft.Web.WebView2.WinForms.dll',
    'WebView2Loader.dll',
    'DeepSeekHarness.ico',
    'DeepSeekHarness-Light.ico',
    'DeepSeekHarness-Dark.ico',
    'DeepSeekHarness.svg',
    'Manage-Dsh.ps1',
    'Uninstall-DesktopShell.ps1',
    'version.txt'
)

try {
    $missing = @($appFiles | Where-Object { -not (Test-Path -LiteralPath (Join-Path $SetupDir $_) -PathType Leaf) })
    if ($missing.Count -gt 0) { Fail ("安装包不完整，缺少：{0}" -f ($missing -join '；')) }

    $setupFull = [IO.Path]::GetFullPath($SetupDir).TrimEnd('\')
    $targetFull = [IO.Path]::GetFullPath($InstallDir).TrimEnd('\')
    $inPlace = $setupFull -eq $targetFull

    New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null

    # 只关闭将被覆盖的旧版桌面壳（路径精确匹配），不影响其它同名进程
    Stop-DesktopShellProcess (Join-Path $InstallDir 'DeepSeekHarness.exe')

    $newSettings = Join-Path $InstallDir 'settings.json'
    $legacyDesktopDir = Join-Path $dshHome 'desktop'
    $oldSettings = Join-Path $legacyDesktopDir 'settings.json'
    if (-not (Test-Path -LiteralPath $newSettings) -and (Test-Path -LiteralPath $oldSettings)) {
        Copy-Item -LiteralPath $oldSettings -Destination $newSettings -Force
        Ok '已迁移旧 DesktopShell settings.json；~/.dsh 的 DSH 数据保持原位。'
    }

    if (-not $inPlace) {
        foreach ($f in $appFiles) {
            Copy-Item -LiteralPath (Join-Path $SetupDir $f) -Destination (Join-Path $InstallDir $f) -Force
        }
        $copied = @($appFiles | Where-Object { Test-Path -LiteralPath (Join-Path $InstallDir $_) -PathType Leaf }).Count
        if ($copied -ne $appFiles.Count) { Fail "文件复制不完整（$copied/$($appFiles.Count)）。" }
        Ok "已安装到：$InstallDir"
    } else {
        Ok "就地安装：$InstallDir"
    }

    $stateVersion = '1.0.0'
    $versionFile = Join-Path $InstallDir 'version.txt'
    if (Test-Path -LiteralPath $versionFile) {
        $raw = (Get-Content -LiteralPath $versionFile -Raw -ErrorAction SilentlyContinue).Trim()
        if ($raw) { $stateVersion = $raw }
    }
    $state = [ordered]@{
        schemaVersion = 1
        product = 'DeepSeek Harness DesktopShell'
        version = $stateVersion
        dshHome = $dshHome
        dshHomeExistedBeforeInstall = [bool](Test-Path -LiteralPath $dshHome -PathType Container)
        webProfileExistedBeforeInstall = [bool](Test-Path -LiteralPath (Join-Path $dshHome 'profiles\web\package.json') -PathType Leaf)
        installedAt = (Get-Date).ToString('o')
    }
    $state | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $InstallDir 'install-state.json') -Encoding utf8NoBOM

    if (-not $NoShortcuts) {
        $startMenu = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\DeepSeek Harness'
        if (Test-Path $startMenu) { Remove-Item $startMenu -Recurse -Force }
        New-Item -ItemType Directory -Force -Path $startMenu | Out-Null

        $shell = New-Object -ComObject WScript.Shell
        $runner = (Get-Command pwsh.exe -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty Source)
        if (-not $runner) { $runner = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" }

        $exe = Join-Path $InstallDir 'DeepSeekHarness.exe'
        $manager = Join-Path $InstallDir 'Manage-Dsh.ps1'
        $uninstall = Join-Path $InstallDir 'Uninstall-DesktopShell.ps1'

        $appShortcut = $shell.CreateShortcut((Join-Path $startMenu 'DeepSeek Harness.lnk'))
        $appShortcut.TargetPath = $exe
        $appShortcut.WorkingDirectory = $homeDir
        $appShortcut.IconLocation = "$exe,0"
        $appShortcut.Description = 'DeepSeek Harness DesktopShell'
        $appShortcut.Save()

        $manageShortcut = $shell.CreateShortcut((Join-Path $startMenu '管理 DSH - 插件与配置.lnk'))
        $manageShortcut.TargetPath = $runner
        $manageShortcut.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$manager`""
        $manageShortcut.WorkingDirectory = $InstallDir
        $manageShortcut.IconLocation = "$exe,0"
        $manageShortcut.Description = '管理 DSH 运行方式、Profile、插件和桌面配置'
        $manageShortcut.Save()

        $uninstallShortcut = $shell.CreateShortcut((Join-Path $startMenu '卸载 DesktopShell.lnk'))
        $uninstallShortcut.TargetPath = $runner
        $uninstallShortcut.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$uninstall`""
        $uninstallShortcut.WorkingDirectory = $InstallDir
        $uninstallShortcut.IconLocation = "$exe,0"
        $uninstallShortcut.Description = '卸载 DesktopShell；可选择同时完整删除 DSH 用户环境'
        $uninstallShortcut.Save()
        Ok '开始菜单入口已创建。'
    }

    if (([IO.Path]::GetFullPath($legacyDesktopDir) -ne $targetFull) -and
        (Test-Path -LiteralPath (Join-Path $legacyDesktopDir 'DeepSeekHarness.cs')) -and
        (Test-Path -LiteralPath (Join-Path $legacyDesktopDir 'Manage-Dsh.ps1'))) {
        try {
            Remove-Item -LiteralPath $legacyDesktopDir -Recurse -Force
            Ok '已移除旧版 ~/.dsh/desktop DesktopShell 文件；其它 ~/.dsh 数据未动。'
        } catch {
            Warn "旧版 ~/.dsh/desktop 未能自动删除，可稍后手工清理：$($_.Exception.Message)"
        }
    }

    if (-not $NoWizard) {
        $manager = Join-Path $InstallDir 'Manage-Dsh.ps1'
        & $manager -FirstInstall
        if ($LASTEXITCODE -ne 0) { Fail "初始化向导失败（退出码 $LASTEXITCODE）。" }
    }

    Ok "DeepSeek Harness DesktopShell $stateVersion 安装完成。"
    Write-Host "程序目录：$InstallDir"
    Write-Host "DSH_HOME：$dshHome"

    if (-not $NoLaunch) {
        Say '启动 DeepSeek Harness...'
        Start-Process -FilePath (Join-Path $InstallDir 'DeepSeekHarness.exe') -WorkingDirectory $homeDir
    }
    exit 0
} catch {
    Write-Host ''
    Write-Host "失败：$($_.Exception.Message)" -ForegroundColor Red
    exit 1
}
