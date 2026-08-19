param(
    [switch]$NoLaunch,
    [switch]$NoWizard
)

<#
.SYNOPSIS
    从源码安装 DesktopShell（开发者/无预编译包场景）。

.DESCRIPTION
    与 Install-Release.ps1 共用同一套安装核心：
    1. 源码编译到临时 stage（固定 WebView2 SDK 1.0.4078.44、版本元数据来自根目录 VERSION）
    2. 组装与 Release 完全相同的 app 目录（含 COMPATIBILITY.json）
    3. 调用 Install-Release.ps1：目录所有权检查、Preflight→Stage→Initialize→Commit
       事务式提交、升级回滚、DSH_HOME 迁移检测、WebView2 预检、向导/快捷方式/启动
    ——目录保护与升级语义只维护一份，不再有第二套安装逻辑。
#>

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

function Say([string]$text) { Write-Host "[DSH Desktop] $text" -ForegroundColor Cyan }
function Ok([string]$text) { Write-Host "[OK] $text" -ForegroundColor Green }
function Warn([string]$text) { Write-Host "[!]   $text" -ForegroundColor Yellow }
function Fail([string]$text) { throw $text }

# Windows PowerShell 5.1 与 PowerShell 7 均支持
if ($PSVersionTable.PSVersion -lt [version]'5.1') {
    Fail '安装器需要 Windows PowerShell 5.1 或 PowerShell 7。请升级后重新运行。'
}

function ConvertTo-AssemblyVersion([string]$v) {
    # 语义化版本 -> 4 段 AssemblyVersion（如 1.0.0 -> 1.0.0.0）
    $core = ($v -split '-')[0]
    $out = [System.Collections.Generic.List[string]]::new()
    foreach ($p in @($core -split '\.' | Select-Object -First 4)) {
        if ($p -notmatch '^\d{1,5}$') { Fail "版本号无法转为 AssemblyVersion：$v" }
        if ([int]$p -gt 65534) { Fail "版本号组件超出 AssemblyVersion 范围：$v" }
        $out.Add($p)
    }
    while ($out.Count -lt 4) { $out.Add('0') }
    return ($out -join '.')
}

# WebView2 Runtime（Evergreen）预检：缺失时给明确入口（安装核心也会再查一次，这里提前快速失败）
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

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot = Split-Path -Parent $here
$homeDir = [Environment]::GetFolderPath('UserProfile')
$localAppData = if ($env:LOCALAPPDATA) { $env:LOCALAPPDATA } else { [Environment]::GetFolderPath('LocalApplicationData') }
$desktopDir = Join-Path $localAppData 'Programs\DeepSeek Harness DesktopShell'
$sdkVersion = '1.0.4078.44'

# 版本单一来源：根目录 VERSION（Build-Release 同样读取它）
$srcVersion = '1.0.0'
$versionFile = Join-Path $repoRoot 'VERSION'
if (Test-Path -LiteralPath $versionFile -PathType Leaf) {
    $raw = (Get-Content -LiteralPath $versionFile -Raw -ErrorAction SilentlyContinue).Trim()
    if ($raw) { $srcVersion = $raw }
}
if ($srcVersion -notmatch '^\d+\.\d+\.\d+(?:\.\d+)?(?:-[A-Za-z0-9._+-]+)?$') {
    Fail "根目录 VERSION 非法：$srcVersion"
}
$asmVersion = ConvertTo-AssemblyVersion $srcVersion

# 运行时预检（在任何写入之前）
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

# ---- Stage：编译并组装与 Release 相同的 app 目录 ----
$stage = Join-Path $env:TEMP ('dsh-source-stage-' + [Guid]::NewGuid().ToString('N'))
$appDir = Join-Path $stage 'DeepSeek Harness DesktopShell'
$manifestTemp = Join-Path $env:TEMP ('dsh-manifest-' + [Guid]::NewGuid().ToString('N') + '.manifest')
$versionInfo = Join-Path $env:TEMP ('dsh-versioninfo-' + [Guid]::NewGuid().ToString('N') + '.cs')
try {
    New-Item -ItemType Directory -Force -Path $appDir | Out-Null

    foreach ($asset in 'DeepSeekHarness.ico', 'DeepSeekHarness-Light.ico', 'DeepSeekHarness-Dark.ico', 'DeepSeekHarness.svg') {
        Copy-Item -LiteralPath (Join-Path $repoRoot "assets\$asset") -Destination (Join-Path $appDir $asset) -Force
    }
    Copy-Item -LiteralPath (Join-Path $repoRoot 'scripts\Manage-Dsh.ps1') -Destination (Join-Path $appDir 'Manage-Dsh.ps1') -Force
    Copy-Item -LiteralPath (Join-Path $repoRoot 'scripts\Uninstall-DesktopShell.ps1') -Destination (Join-Path $appDir 'Uninstall-DesktopShell.ps1') -Force
    Copy-Item -LiteralPath (Join-Path $repoRoot 'scripts\Repair-CostMeterLedger.ps1') -Destination (Join-Path $appDir 'Repair-CostMeterLedger.ps1') -Force
    Copy-Item -LiteralPath (Join-Path $repoRoot 'COMPATIBILITY.json') -Destination (Join-Path $appDir 'COMPATIBILITY.json') -Force
    Set-Content -LiteralPath (Join-Path $appDir 'version.txt') -Value $srcVersion -Encoding ascii

    # ---- WebView2 SDK 三件套（固定版本；复用已安装目录中的同版本，否则下载） ----
    $coreDll = Join-Path $appDir 'Microsoft.Web.WebView2.Core.dll'
    $winFormsDll = Join-Path $appDir 'Microsoft.Web.WebView2.WinForms.dll'
    $loaderDll = Join-Path $appDir 'WebView2Loader.dll'
    $installedCore = Join-Path $desktopDir 'Microsoft.Web.WebView2.Core.dll'
    $reuse = $false
    if ((Test-Path -LiteralPath $installedCore -PathType Leaf) -and
        (Test-Path -LiteralPath (Join-Path $desktopDir 'Microsoft.Web.WebView2.WinForms.dll') -PathType Leaf) -and
        (Test-Path -LiteralPath (Join-Path $desktopDir 'WebView2Loader.dll') -PathType Leaf)) {
        try {
            $fv = [System.Diagnostics.FileVersionInfo]::GetVersionInfo($installedCore).FileVersion
            if ($fv -eq $sdkVersion) { $reuse = $true }
        } catch {}
    }
    if ($reuse) {
        Copy-Item -LiteralPath $installedCore -Destination $coreDll -Force
        Copy-Item -LiteralPath (Join-Path $desktopDir 'Microsoft.Web.WebView2.WinForms.dll') -Destination $winFormsDll -Force
        Copy-Item -LiteralPath (Join-Path $desktopDir 'WebView2Loader.dll') -Destination $loaderDll -Force
        Ok "复用已安装的 WebView2 SDK $sdkVersion。"
    } else {
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
    }

    # ---- 编译（EXE 版本元数据 + manifest 版本都来自根目录 VERSION） ----
    @"
using System.Reflection;
[assembly: AssemblyVersion("$asmVersion")]
[assembly: AssemblyFileVersion("$asmVersion")]
[assembly: AssemblyInformationalVersion("$srcVersion")]
"@ | Set-Content -LiteralPath $versionInfo -Encoding ascii

    $manifestText = [System.IO.File]::ReadAllText((Join-Path $repoRoot 'src\app.manifest'))
    $manifestText = $manifestText -replace 'version="\d+\.\d+\.\d+\.\d+"', ("version=`"{0}`"" -f $asmVersion)
    [System.IO.File]::WriteAllText($manifestTemp, $manifestText, [System.Text.UTF8Encoding]::new($true))

    $cscCandidates = @(
        "$env:WINDIR\Microsoft.NET\Framework64\v4.0.30319\csc.exe",
        "$env:WINDIR\Microsoft.NET\Framework\v4.0.30319\csc.exe"
    )
    $csc = $cscCandidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
    if (-not $csc) { Fail '找不到 .NET Framework 4 csc.exe。Windows 11 正常应自带。' }
    Ok "C# 编译器: $csc"

    $exe = Join-Path $appDir 'DeepSeekHarness.exe'
    Say '编译 DeepSeekHarness.exe...'
    $compilerArgs = @(
        '/nologo','/target:winexe','/platform:anycpu','/optimize+',
        "/out:$exe", "/win32icon:$(Join-Path $repoRoot 'assets\DeepSeekHarness.ico')",
        "/win32manifest:$manifestTemp",
        '/reference:System.dll','/reference:System.Core.dll','/reference:System.Drawing.dll',
        '/reference:System.Windows.Forms.dll','/reference:System.Web.Extensions.dll',
        "/reference:$coreDll", "/reference:$winFormsDll",
        (Join-Path $repoRoot 'src\DeepSeekHarness.cs'), $versionInfo
    )
    & $csc @compilerArgs
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path $exe)) { Fail "C# 编译失败，退出码 $LASTEXITCODE。" }
    Ok "已生成: $exe"

    # ---- 调用发布安装核心：目录所有权 / Preflight→Stage→Initialize→Commit / 升级回滚 /
    #      DSH_HOME 迁移检测 / 向导 / 快捷方式 / 启动 全部由它处理 ----
    $installer = Join-Path $repoRoot 'scripts\Install-Release.ps1'
    Say "调用安装核心：$installer"
    & $installer -SetupDir $appDir -InstallDir $desktopDir -NoWizard:$NoWizard -NoLaunch:$NoLaunch
    if ($LASTEXITCODE -ne 0) { Fail "安装核心退出码 $LASTEXITCODE。" }
    exit 0
} finally {
    Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $manifestTemp -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $versionInfo -Force -ErrorAction SilentlyContinue
}
