param(
    [switch]$NoLaunch,
    [switch]$NoWizard
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

function Say([string]$text) { Write-Host "[DSH Desktop] $text" -ForegroundColor Cyan }
function Ok([string]$text) { Write-Host "[OK] $text" -ForegroundColor Green }
function Warn([string]$text) { Write-Host "[!]   $text" -ForegroundColor Yellow }
function Fail([string]$text) { throw $text }

# Windows PowerShell 5.1 与 PowerShell 7 均支持；utf8NoBOM 在 5.1 下不可用，
# 统一用 .NET 写无 BOM UTF-8。
function Write-Utf8NoBom([string]$Path, [string]$Content) {
    [System.IO.File]::WriteAllText($Path, $Content, [System.Text.UTF8Encoding]::new($false))
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

if ($PSVersionTable.PSVersion -lt [version]'5.1') {
    Fail '安装器需要 Windows PowerShell 5.1 或 PowerShell 7。请升级后重新运行。'
}

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot = Split-Path -Parent $here
$homeDir = [Environment]::GetFolderPath('UserProfile')
$dshHome = if ($env:DSH_HOME) { $env:DSH_HOME } else { Join-Path $homeDir '.dsh' }

$localAppData = if ($env:LOCALAPPDATA) { $env:LOCALAPPDATA } else { [Environment]::GetFolderPath('LocalApplicationData') }
$desktopDir = Join-Path $localAppData 'Programs\DeepSeek Harness DesktopShell'
$legacyDesktopDir = Join-Path $dshHome 'desktop'
$startMenu = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\DeepSeek Harness'

$installStatePath = Join-Path $desktopDir 'install-state.json'

Write-Host ''
Write-Host 'DeepSeek Harness DesktopShell v1.0.0' -ForegroundColor Cyan
Write-Host 'Windows 桌面宿主 + DSH npx/现有命令启动 + 插件/配置向导' -ForegroundColor DarkGray
Write-Host ''
Say "DesktopShell: $desktopDir"
Say "DSH_HOME:     $dshHome"
Say 'DSH 规则：已有 dsh 就使用；没有则按官方 npx @deepseek-ai/dsh web 方式运行，不做 npm -g 安装。'

# 运行时预检：WebView2 Runtime
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

New-Item -ItemType Directory -Force -Path $desktopDir | Out-Null

# 只关闭将被覆盖的旧版桌面壳（路径精确匹配），不影响其它同名进程
Stop-DesktopShellProcess (Join-Path $desktopDir 'DeepSeekHarness.exe')

$newSettings = Join-Path $desktopDir 'settings.json'
$oldSettings = Join-Path $legacyDesktopDir 'settings.json'
if (-not (Test-Path -LiteralPath $newSettings) -and (Test-Path -LiteralPath $oldSettings)) {
    Copy-Item -LiteralPath $oldSettings -Destination $newSettings -Force
    Ok '已迁移旧 DesktopShell settings.json；~/.dsh 的 DSH 数据保持原位。'
}

$filesToCopy = @(
    @{ From='src\DeepSeekHarness.cs'; To='DeepSeekHarness.cs' },
    @{ From='src\app.manifest'; To='app.manifest' },
    @{ From='assets\DeepSeekHarness.ico'; To='DeepSeekHarness.ico' },
    @{ From='assets\DeepSeekHarness-Light.ico'; To='DeepSeekHarness-Light.ico' },
    @{ From='assets\DeepSeekHarness-Dark.ico'; To='DeepSeekHarness-Dark.ico' },
    @{ From='assets\DeepSeekHarness.svg'; To='DeepSeekHarness.svg' },
    @{ From='scripts\Manage-Dsh.ps1'; To='Manage-Dsh.ps1' },
    @{ From='scripts\Uninstall-DesktopShell.ps1'; To='Uninstall-DesktopShell.ps1' },
    @{ From='scripts\Repair-CostMeterLedger.ps1'; To='Repair-CostMeterLedger.ps1' }
)
foreach ($f in $filesToCopy) {
    Copy-Item -LiteralPath (Join-Path $repoRoot $f.From) -Destination (Join-Path $desktopDir $f.To) -Force
}
$missing = @($filesToCopy | ForEach-Object {
    $dst = Join-Path $desktopDir $_.To
    if (-not (Test-Path -LiteralPath $dst -PathType Leaf)) { $_.To }
})
if ($missing.Count -gt 0) {
    Fail ("文件复制失败，缺少：{0}" -f ($missing -join '；'))
}

# 顺序调整（事务性）：先编译，成功后才跑向导/写状态。
# 避免旧顺序下“向导已装插件、状态已写，最后 C# 编译失败”留下半安装。

$cscCandidates = @(
    "$env:WINDIR\Microsoft.NET\Framework64\v4.0.30319\csc.exe",
    "$env:WINDIR\Microsoft.NET\Framework\v4.0.30319\csc.exe"
)
$csc = $cscCandidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
if (-not $csc) { Fail '找不到 .NET Framework 4 csc.exe。Windows 11 正常应自带。' }
Ok "C# 编译器: $csc"

$coreDll = Join-Path $desktopDir 'Microsoft.Web.WebView2.Core.dll'
$winFormsDll = Join-Path $desktopDir 'Microsoft.Web.WebView2.WinForms.dll'
$loaderDll = Join-Path $desktopDir 'WebView2Loader.dll'
$sdkVersion = '1.0.4078.44'
$needSdk = -not ((Test-Path $coreDll) -and (Test-Path $winFormsDll) -and (Test-Path $loaderDll))

if (-not $needSdk) {
    # 三件套必须同版本且与固定版本一致，任一不符则整套重新下载（避免混装）
    foreach ($dll in @($coreDll, $winFormsDll, $loaderDll)) {
        try {
            $existing = [System.Diagnostics.FileVersionInfo]::GetVersionInfo($dll).FileVersion
            if ($existing -ne $sdkVersion) {
                Say "现有 WebView2 $(Split-Path $dll -Leaf) 版本 $existing 与固定版本 $sdkVersion 不一致，将重新下载整套。"
                $needSdk = $true
                break
            }
        } catch {
            Say "无法读取 WebView2 $(Split-Path $dll -Leaf) 版本，将重新下载整套。"
            $needSdk = $true
            break
        }
    }
}

if ($needSdk) {
    $sdkTemp = Join-Path $env:TEMP ("webview2-sdk-" + [Guid]::NewGuid().ToString('N'))
    $nupkg = Join-Path $sdkTemp 'webview2.zip'
    $extract = Join-Path $sdkTemp 'pkg'
    New-Item -ItemType Directory -Force -Path $sdkTemp | Out-Null

    try {
        Say "下载 Microsoft.Web.WebView2 SDK $sdkVersion..."
        Invoke-WebRequest -UseBasicParsing -Uri "https://www.nuget.org/api/v2/package/Microsoft.Web.WebView2/$sdkVersion" -OutFile $nupkg
        Expand-Archive -LiteralPath $nupkg -DestinationPath $extract -Force

        $coreSource = Get-ChildItem $extract -Recurse -Filter 'Microsoft.Web.WebView2.Core.dll' |
            Where-Object { $_.FullName -match '[\\/]lib[\\/]' } | Sort-Object { $_.FullName.Length } | Select-Object -First 1
        $wfSource = Get-ChildItem $extract -Recurse -Filter 'Microsoft.Web.WebView2.WinForms.dll' |
            Where-Object { $_.FullName -match '[\\/]lib[\\/]' } | Sort-Object { $_.FullName.Length } | Select-Object -First 1
        $arch = switch ($env:PROCESSOR_ARCHITECTURE) { 'ARM64' {'win-arm64'} 'x86' {'win-x86'} default {'win-x64'} }
        $loaderSource = Get-ChildItem $extract -Recurse -Filter 'WebView2Loader.dll' |
            Where-Object { $_.FullName -match [regex]::Escape($arch) } | Select-Object -First 1
        if (-not $coreSource -or -not $wfSource -or -not $loaderSource) { Fail 'WebView2 SDK 中没有找到所需程序集/Loader。' }

        Copy-Item $coreSource.FullName $coreDll -Force
        Copy-Item $wfSource.FullName $winFormsDll -Force
        Copy-Item $loaderSource.FullName $loaderDll -Force
        Ok 'WebView2 SDK 文件已准备。'
    } finally {
        Remove-Item -LiteralPath $sdkTemp -Recurse -Force -ErrorAction SilentlyContinue
    }
} else { Ok "复用现有 WebView2 SDK $sdkVersion。" }

$source = Join-Path $desktopDir 'DeepSeekHarness.cs'
$manifest = Join-Path $desktopDir 'app.manifest'
$icon = Join-Path $desktopDir 'DeepSeekHarness.ico'
$exe = Join-Path $desktopDir 'DeepSeekHarness.exe'

# EXE 版本元数据由构建脚本注入（与 install-state/version 一致）
$versionInfo = Join-Path $env:TEMP ("dsh-versioninfo-" + [Guid]::NewGuid().ToString('N') + '.cs')
@"
using System.Reflection;
[assembly: AssemblyVersion("1.0.0.0")]
[assembly: AssemblyFileVersion("1.0.0.0")]
[assembly: AssemblyInformationalVersion("1.0.0")]
"@ | Set-Content -LiteralPath $versionInfo -Encoding ascii

Say '编译 DeepSeekHarness.exe...'
$compilerArgs = @(
    '/nologo','/target:winexe','/platform:anycpu','/optimize+',
    "/out:$exe", "/win32icon:$icon", "/win32manifest:$manifest",
    '/reference:System.dll','/reference:System.Core.dll','/reference:System.Drawing.dll',
    '/reference:System.Windows.Forms.dll','/reference:System.Web.Extensions.dll',
    "/reference:$coreDll", "/reference:$winFormsDll", $source, $versionInfo
)
& $csc @compilerArgs
Remove-Item -LiteralPath $versionInfo -Force -ErrorAction SilentlyContinue
if ($LASTEXITCODE -ne 0 -or -not (Test-Path $exe)) { Fail "C# 编译失败，退出码 $LASTEXITCODE。" }
Ok "已生成: $exe"

# 编译成功后才跑初始化向导（失败则中止，不再继续写状态）
$manager = Join-Path $desktopDir 'Manage-Dsh.ps1'
if ($NoWizard) {
    Say 'NoWizard：发现现有 dsh 就使用；否则使用 npx；不改现有插件。'
    & $manager -FirstInstall -NonInteractive
} else {
    & $manager -FirstInstall
}
if ($LASTEXITCODE -ne 0) {
    Fail "初始化向导失败（退出码 $LASTEXITCODE），安装已中止。"
}

# 升级时继承第一次安装的历史事实（dshHomeExistedBeforeInstall 等），
# 并记录 firstInstalledAt / lastUpdatedAt（见 Install-Release.ps1 同段注释）。
$nowIso = (Get-Date).ToString('o')
$priorState = $null
if (Test-Path -LiteralPath $installStatePath -PathType Leaf) {
    try { $priorState = Get-Content -LiteralPath $installStatePath -Raw -Encoding UTF8 | ConvertFrom-Json } catch { $priorState = $null }
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
    version = '1.0.0'
    dshHome = $dshHome
    dshHomeExistedBeforeInstall = $dshHomeExistedBefore
    webProfileExistedBeforeInstall = $webProfileExistedBefore
    firstInstalledAt = $firstInstalledAt
    installedAt = $nowIso
    lastUpdatedAt = $nowIso
}
Write-Utf8NoBom $installStatePath (($state | ConvertTo-Json -Depth 10))

# 目录所有权标记：卸载器只有再次验证 marker/install-state 后才允许递归删除本目录
$marker = [ordered]@{
    schemaVersion = 1
    product = 'DeepSeek Harness DesktopShell'
    installedAt = $nowIso
}
Write-Utf8NoBom (Join-Path $desktopDir '.dsh-desktop-shell-root') (($marker | ConvertTo-Json -Depth 10))

# 只创建/覆盖本产品自己的三个快捷方式，不整目录删除（用户可能放了自有快捷方式）
New-Item -ItemType Directory -Force -Path $startMenu | Out-Null

$shell = New-Object -ComObject WScript.Shell
$runner = (Get-Command pwsh.exe -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty Source)
if (-not $runner) { $runner = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" }

$appShortcut = $shell.CreateShortcut((Join-Path $startMenu 'DeepSeek Harness.lnk'))
$appShortcut.TargetPath = $exe
$appShortcut.WorkingDirectory = $homeDir
$appShortcut.IconLocation = "$exe,0"
$appShortcut.Description = 'DeepSeek Harness DesktopShell'
$appShortcut.Save()

$manageShortcut = $shell.CreateShortcut((Join-Path $startMenu '管理 DSH - 插件与配置.lnk'))
$manageShortcut.TargetPath = $runner
$manageShortcut.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$manager`""
$manageShortcut.WorkingDirectory = $desktopDir
$manageShortcut.IconLocation = "$exe,0"
$manageShortcut.Description = '管理 DSH 运行方式、Profile、插件和桌面配置'
$manageShortcut.Save()

$uninstall = Join-Path $desktopDir 'Uninstall-DesktopShell.ps1'
$shortcut = $shell.CreateShortcut((Join-Path $startMenu '卸载 DesktopShell.lnk'))
$shortcut.TargetPath = $runner
$shortcut.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$uninstall`""
$shortcut.WorkingDirectory = $desktopDir
$shortcut.IconLocation = "$exe,0"
$shortcut.Description = '卸载 DesktopShell；可选择同时完整删除 DSH 用户环境'
$shortcut.Save()

if (([IO.Path]::GetFullPath($legacyDesktopDir) -ne [IO.Path]::GetFullPath($desktopDir)) -and
    (Test-Path -LiteralPath (Join-Path $legacyDesktopDir 'DeepSeekHarness.cs')) -and
    (Test-Path -LiteralPath (Join-Path $legacyDesktopDir 'Manage-Dsh.ps1'))) {
    try {
        Remove-Item -LiteralPath $legacyDesktopDir -Recurse -Force
        Ok '已移除旧版 ~/.dsh/desktop DesktopShell 文件；其它 ~/.dsh 数据未动。'
    } catch {
        Say "旧版 ~/.dsh/desktop 未能自动删除，可稍后手工清理：$($_.Exception.Message)"
    }
}

Write-Host ''
Ok 'DeepSeek Harness DesktopShell v1.0.0 安装完成。'
Write-Host "程序目录：$desktopDir"
Write-Host "DSH_HOME：$dshHome"
Write-Host ''
Write-Host '卸载时可选择：仅卸载 DesktopShell，或完整卸载 DesktopShell + DSH 用户环境。'

if (-not $NoLaunch) {
    Say '启动 DeepSeek Harness...'
    Start-Process -FilePath $exe -WorkingDirectory $homeDir
}
