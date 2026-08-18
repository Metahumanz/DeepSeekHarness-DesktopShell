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
    2. 安装目录所有权检查：-InstallDir 必须是 DesktopShell 专属目录
       （拒绝盘符根/用户主目录/系统目录等已知大目录；目标目录非空且
       不是已有 DesktopShell 安装时拒绝安装）
    3. 复制到 %LOCALAPPDATA%\Programs\DeepSeek Harness DesktopShell
       （就地安装时跳过复制）
    4. 迁移旧版设置、写入 install-state.json 与目录所有权标记
       （.dsh-desktop-shell-root，卸载前必须再次验证）
    5. 运行时预检：WebView2 Runtime（缺失时给出下载入口）/ 架构提示
    6. 创建开始菜单入口（可 -NoShortcuts 跳过）
    7. 运行首次配置向导（-NoWizard 时执行无人值守非交互初始化，语义与
       Install-Desktop.ps1 一致；缺少 Node.js 时中止而非静默跳过）
    8. 启动桌面壳（可 -NoLaunch 跳过）

.EXAMPLE
    # 在解压后的目录中双击 install.bat，或：
    pwsh -File Install-Release.ps1
.EXAMPLE
    pwsh -File Install-Release.ps1 -SetupDir C:\tmp\dsh-pkg -InstallDir D:\apps\dsh -NoLaunch
#>

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

# Windows PowerShell 5.1 与 PowerShell 7 均支持
if ($PSVersionTable.PSVersion -lt [version]'5.1') {
    Write-Host '[DSH Desktop] 需要 Windows PowerShell 5.1 或 PowerShell 7。' -ForegroundColor Red
    exit 1
}

function Say([string]$text) { Write-Host "[DSH Desktop] $text" -ForegroundColor Cyan }
function Ok([string]$text) { Write-Host "[OK] $text" -ForegroundColor Green }
function Warn([string]$text) { Write-Host "[!]   $text" -ForegroundColor Yellow }
function Fail([string]$text) { throw $text }

# utf8NoBOM 在 Windows PowerShell 5.1 不可用，统一用 .NET 写无 BOM UTF-8
function Write-Utf8NoBom([string]$Path, [string]$Content) {
    [System.IO.File]::WriteAllText($Path, $Content, [System.Text.UTF8Encoding]::new($false))
}

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

# ============================================================
# 安装目录所有权机制（P0）：
# 卸载器会递归删除安装目录，因此安装端必须证明该目录是 DesktopShell 专属目录。
# - 有效 marker（.dsh-desktop-shell-root）或旧版 install-state.json → 已有安装，允许升级
# - 目录不存在 / 为空 → 可接管并写入 marker
# - 目录非空且无 marker → 拒绝（就地安装且目录内只有发布包文件时豁免）
# - 盘符根 / 用户主目录 / 系统目录 / Program Files / DSH_HOME 等已知大目录一律拒绝
# ============================================================
$MarkerName = '.dsh-desktop-shell-root'
$ProductId = 'DeepSeek Harness DesktopShell'

function Test-ProductFile([string]$path) {
    if ([string]::IsNullOrWhiteSpace($path) -or -not (Test-Path -LiteralPath $path -PathType Leaf)) { return $false }
    try {
        $j = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
        return ($j.product -eq $ProductId)
    } catch { return $false }
}

function Test-DesktopShellOwned([string]$dir) {
    if ([string]::IsNullOrWhiteSpace($dir)) { return $false }
    return (Test-ProductFile (Join-Path $dir $MarkerName)) -or
           (Test-ProductFile (Join-Path $dir 'install-state.json'))
}

function Test-DangerousInstallPath([string]$target) {
    if ([string]::IsNullOrWhiteSpace($target)) { return $true }
    try {
        $t = [IO.Path]::GetFullPath($target).TrimEnd('\')
        $root = [IO.Path]::GetPathRoot($t).TrimEnd('\')
        if (-not $t -or $t -eq $root) { return $true }

        $protected = @(
            $homeDir,
            $dshHome,
            $env:WINDIR,
            (Join-Path $env:WINDIR 'System32'),
            $env:ProgramFiles,
            ${env:ProgramFiles(x86)},
            $env:ProgramData,
            $env:PUBLIC,
            $env:APPDATA,
            $localAppData,
            (Join-Path $localAppData 'Programs'),
            $env:TEMP,
            $env:TMP,
            ([Environment]::GetFolderPath('DesktopDirectory')),
            ([Environment]::GetFolderPath('Personal')),
            (Join-Path $homeDir 'Downloads'),
            (Join-Path $homeDir 'OneDrive')
        )
        foreach ($p in $protected) {
            if ([string]::IsNullOrWhiteSpace($p)) { continue }
            try {
                $pf = [IO.Path]::GetFullPath($p).TrimEnd('\')
                # 目标等于受保护目录，或受保护目录位于目标内部（卸载会殃及）
                if ($t -eq $pf -or $pf.StartsWith($t + '\', [StringComparison]::OrdinalIgnoreCase)) { return $true }
            } catch {}
        }
        # DesktopShell 不得安装进 DSH_HOME 内部（目录边界原则）
        try {
            $dshFull = [IO.Path]::GetFullPath($dshHome).TrimEnd('\')
            if ($t.StartsWith($dshFull + '\', [StringComparison]::OrdinalIgnoreCase)) { return $true }
        } catch {}
        return $false
    } catch { return $true }
}

# WebView2 Runtime（Evergreen）预检：桌面壳依赖它承载界面，安装阶段就给出明确入口，
# 而不是让用户等到第一次启动才看到“启动失败”。
function Get-WebView2RuntimeVersion {
    $keys = @(
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}',
        'HKLM:\SOFTWARE\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}',
        'HKCU:\SOFTWARE\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}'
    )
    foreach ($k in $keys) {
        if (Test-Path $k) {
            $pv = (Get-ItemProperty -Path $k -ErrorAction SilentlyContinue).pv
            if ($pv) { return [string]$pv }
        }
    }
    return $null
}

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

# 随包分发但非必需的文件（旧版发布包没有也不影响安装）
$optionalFiles = @('install.bat', 'Repair-CostMeterLedger.ps1')

$stage = $null
$rollback = $null

try {
    $missing = @($appFiles | Where-Object { -not (Test-Path -LiteralPath (Join-Path $SetupDir $_) -PathType Leaf) })
    if ($missing.Count -gt 0) { Fail ("安装包不完整，缺少：{0}" -f ($missing -join '；')) }

    $setupFull = [IO.Path]::GetFullPath($SetupDir).TrimEnd('\')
    $targetFull = [IO.Path]::GetFullPath($InstallDir).TrimEnd('\')
    $inPlace = $setupFull -eq $targetFull

    # ---- Preflight（任何写入之前；失败不留半安装） ----
    if (Test-DangerousInstallPath $targetFull) {
        Fail "安装目录不安全：$InstallDir 。不能使用盘符根、用户主目录、系统目录、Program Files、DSH_HOME 等已知大目录。"
    }
    if ((Test-Path -LiteralPath $InstallDir) -and -not (Test-Path -LiteralPath $InstallDir -PathType Container)) {
        Fail "安装目标已存在但不是目录：$InstallDir"
    }

    $owned = Test-DesktopShellOwned $targetFull
    if (-not $owned -and (Test-Path -LiteralPath $InstallDir -PathType Container)) {
        $entries = @(Get-ChildItem -LiteralPath $InstallDir -Force -ErrorAction SilentlyContinue)
        if ($entries.Count -gt 0) {
            # 豁免：就地安装（SetupDir == InstallDir）且目录内只有发布包自身文件
            $known = @($appFiles) + $optionalFiles
            $allKnown = $true
            foreach ($e in $entries) {
                if ($e.PSIsContainer -or ($known -notcontains $e.Name)) { $allKnown = $false; break }
            }
            if (-not ($inPlace -and $allKnown)) {
                Fail ("目标目录已存在且不是 DesktopShell 安装目录：$InstallDir 。" +
                      '为避免卸载时误删他人文件，请使用默认安装目录，或先清空该目录；' +
                      '就地安装时目录内只能有发布包自身文件。')
            }
        }
    }

    if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') {
        Warn '此发布包为 x64 构建；ARM64 设备会通过 x64 模拟运行，或改用源码安装（Install-Desktop.ps1）获取原生构建。'
    }
    $webView2 = Get-WebView2RuntimeVersion
    if (-not $webView2) {
        $url = 'https://go.microsoft.com/fwlink/p/?LinkId=2124703'
        $msg = "未检测到 WebView2 Runtime（Evergreen）。DesktopShell 依赖它承载界面。下载地址：$url"
        if ($NoWizard) { Fail $msg }
        Warn $msg
        Read-Host '按 Enter 打开下载页（安装完成后重新运行本安装程序）' | Out-Null
        Start-Process $url
        Fail '请先安装 WebView2 Runtime，然后重新运行安装程序。'
    }
    Ok "WebView2 Runtime：$webView2"

    # ---- Stage（事务式安装：先在旁路目录组装，成功后才换入正式目录） ----
    $workTarget = $InstallDir
    $legacyDesktopDir = Join-Path $dshHome 'desktop'

    if (-not $inPlace) {
        $stage = Join-Path (Split-Path -Parent $targetFull) ('.dsh-stage-' + [Guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Force -Path $stage | Out-Null

        foreach ($f in $appFiles) {
            Copy-Item -LiteralPath (Join-Path $SetupDir $f) -Destination (Join-Path $stage $f) -Force
        }
        foreach ($f in $optionalFiles) {
            if (Test-Path -LiteralPath (Join-Path $SetupDir $f)) {
                Copy-Item -LiteralPath (Join-Path $SetupDir $f) -Destination (Join-Path $stage $f) -Force
            }
        }
        $copied = @($appFiles | Where-Object { Test-Path -LiteralPath (Join-Path $stage $_) -PathType Leaf }).Count
        if ($copied -ne $appFiles.Count) { Fail "文件暂存不完整（$copied/$($appFiles.Count)）。" }

        # 携带旧安装的用户数据（设置/日志/WebView2 数据）
        $existingSettings = Join-Path $InstallDir 'settings.json'
        $oldSettings = Join-Path $legacyDesktopDir 'settings.json'
        if (Test-Path -LiteralPath $existingSettings -PathType Leaf) {
            Copy-Item -LiteralPath $existingSettings -Destination (Join-Path $stage 'settings.json') -Force
        } elseif (Test-Path -LiteralPath $oldSettings -PathType Leaf) {
            Copy-Item -LiteralPath $oldSettings -Destination (Join-Path $stage 'settings.json') -Force
            Ok '已迁移旧 DesktopShell settings.json；~/.dsh 的 DSH 数据保持原位。'
        }
        foreach ($carry in @('logs', 'webview2-data')) {
            $src = Join-Path $InstallDir $carry
            if (Test-Path -LiteralPath $src) {
                Copy-Item -LiteralPath $src -Destination (Join-Path $stage $carry) -Recurse -Force
            }
        }
        $workTarget = $stage
    }

    # 只关闭将被覆盖的旧版桌面壳（路径精确匹配），不影响其它同名进程
    Stop-DesktopShellProcess (Join-Path $InstallDir 'DeepSeekHarness.exe')

    $stateVersion = '1.0.0'
    $versionFile = Join-Path $workTarget 'version.txt'
    if (Test-Path -LiteralPath $versionFile) {
        $raw = (Get-Content -LiteralPath $versionFile -Raw -ErrorAction SilentlyContinue).Trim()
        if ($raw) { $stateVersion = $raw }
    }

    # 升级时继承第一次安装的历史事实（dshHomeExistedBeforeInstall 等）。
    # 否则升级一次后“安装前 DSH_HOME 已存在”的判断就会从 false 漂移成 true，
    # 卸载器会错误地警告用户“这份 DSH_HOME 在安装 DesktopShell 之前已存在”。
    $nowIso = (Get-Date).ToString('o')
    $priorState = $null
    $priorStatePath = Join-Path $InstallDir 'install-state.json'
    if (Test-Path -LiteralPath $priorStatePath -PathType Leaf) {
        try { $priorState = Get-Content -LiteralPath $priorStatePath -Raw -Encoding UTF8 | ConvertFrom-Json } catch { $priorState = $null }
    }
    $dshHomeExistedBefore = if ($priorState -and ($null -ne $priorState.dshHomeExistedBeforeInstall)) {
        [bool]$priorState.dshHomeExistedBeforeInstall
    } else {
        [bool](Test-Path -LiteralPath $dshHome -PathType Container)
    }
    $webProfileExistedBefore = if ($priorState -and ($null -ne $priorState.webProfileExistedBeforeInstall)) {
        [bool]$priorState.webProfileExistedBeforeInstall
    } else {
        [bool](Test-Path -LiteralPath (Join-Path $dshHome 'profiles\web\package.json') -PathType Leaf)
    }
    $firstInstalledAt = if ($priorState -and $priorState.firstInstalledAt) { [string]$priorState.firstInstalledAt }
        elseif ($priorState -and $priorState.installedAt) { [string]$priorState.installedAt }
        else { $nowIso }

    $state = [ordered]@{
        schemaVersion = 1
        product = 'DeepSeek Harness DesktopShell'
        version = $stateVersion
        dshHome = $dshHome
        dshHomeExistedBeforeInstall = $dshHomeExistedBefore
        webProfileExistedBeforeInstall = $webProfileExistedBefore
        firstInstalledAt = $firstInstalledAt
        installedAt = $nowIso
        lastUpdatedAt = $nowIso
    }
    Write-Utf8NoBom (Join-Path $workTarget 'install-state.json') (($state | ConvertTo-Json -Depth 10))

    # 目录所有权标记：卸载器只有再次验证 marker/install-state 后才允许递归删除本目录
    $marker = [ordered]@{
        schemaVersion = 1
        product = $ProductId
        installedAt = $nowIso
    }
    Write-Utf8NoBom (Join-Path $workTarget $MarkerName) (($marker | ConvertTo-Json -Depth 10))

    # ---- Initialize（在暂存目录上执行管理器；失败则整体丢弃，不留半安装） ----
    # -NoWizard 与源码安装器语义一致：仍然执行无人值守初始化（检查 Node、
    # 解析现有 DSH / 准备 npx、初始化 Profile），只是不交互；缺少 Node 时中止，
    # 避免“安装成功、首次启动才发现缺 Node”。
    $manager = Join-Path $workTarget 'Manage-Dsh.ps1'
    if ($NoWizard) {
        Say 'NoWizard：无人值守初始化（发现现有 dsh 就使用；否则使用 npx；不改现有插件）。'
        & $manager -FirstInstall -NonInteractive
        if ($LASTEXITCODE -ne 0) { Fail "无人值守初始化失败（退出码 $LASTEXITCODE）。" }
    } else {
        & $manager -FirstInstall
        if ($LASTEXITCODE -ne 0) { Fail "初始化向导失败（退出码 $LASTEXITCODE）。" }
    }

    # ---- Commit（非就地：目录交换 + 保留升级前的 exe 以便回滚） ----
    if (-not $inPlace) {
        $rollback = $targetFull + '.dsh-rollback-' + [Guid]::NewGuid().ToString('N')
        $hadOld = Test-Path -LiteralPath $InstallDir -PathType Container
        if ($hadOld) { Move-Item -LiteralPath $InstallDir -Destination $rollback }
        try {
            Move-Item -LiteralPath $stage -Destination $InstallDir
        } catch {
            if ($hadOld -and -not (Test-Path -LiteralPath $InstallDir)) {
                Move-Item -LiteralPath $rollback -Destination $InstallDir -ErrorAction SilentlyContinue
            }
            Fail ("安装目录切换失败：{0}。旧安装已保留。" -f $_.Exception.Message)
        }
        if ($hadOld) {
            $oldExe = Join-Path $rollback 'DeepSeekHarness.exe'
            if (Test-Path -LiteralPath $oldExe -PathType Leaf) {
                Copy-Item -LiteralPath $oldExe -Destination (Join-Path $InstallDir 'DeepSeekHarness.exe.previous') -Force
                Ok '已保留升级前的 DeepSeekHarness.exe.previous（回滚用）。'
            }
            Remove-Item -LiteralPath $rollback -Recurse -Force -ErrorAction SilentlyContinue
            $rollback = $null
        }
        $stage = $null
    }
    Ok "已安装到：$InstallDir"

    if (-not $NoShortcuts) {
        $startMenu = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\DeepSeek Harness'
        # 只创建/覆盖本产品自己的三个快捷方式，不整目录删除（用户可能放了自有快捷方式）
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

    Ok "DeepSeek Harness DesktopShell $stateVersion 安装完成。"
    Write-Host "程序目录：$InstallDir"
    Write-Host "DSH_HOME：$dshHome"

    if (-not $NoLaunch) {
        Say '启动 DeepSeek Harness...'
        Start-Process -FilePath (Join-Path $InstallDir 'DeepSeekHarness.exe') -WorkingDirectory $homeDir
    }
    exit 0
} catch {
    # 事务清理：丢弃暂存目录；若交换失败且正式目录缺失，恢复旧安装
    if ($stage -and (Test-Path -LiteralPath $stage)) {
        Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue
    }
    if ($rollback -and (Test-Path -LiteralPath $rollback)) {
        if (-not (Test-Path -LiteralPath $InstallDir)) {
            Move-Item -LiteralPath $rollback -Destination $InstallDir -ErrorAction SilentlyContinue
        }
    }
    Write-Host ''
    Write-Host "失败：$($_.Exception.Message)" -ForegroundColor Red
    exit 1
}
