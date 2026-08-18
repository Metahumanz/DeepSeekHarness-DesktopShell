param(
    [string]$Version = '1.0.0',
    [string]$OutDir = '',
    [string]$SdkDir = ''
)

<#
.SYNOPSIS
    构建 DesktopShell 发布包（免编译 zip，普通用户双击即可安装）。

.DESCRIPTION
    1. 定位固定版本（1.0.4078.44）的 WebView2 SDK 三件套：-SdkDir 覆盖（版本必须一致）
       → 同版本 NuGet 包目录 → NuGet 在线下载；不再从多个来源拼凑
    2. 用 .NET Framework csc 编译 DeepSeekHarness.exe，EXE 的
       AssemblyVersion / FileVersion / InformationalVersion 与 -Version 同步
    3. 组装自包含目录（含 Repair-CostMeterLedger.ps1 手工修复工具）并打包 zip
    4. 自校验 zip 内容并输出 SHA256SUMS.txt

.EXAMPLE
    .\scripts\Build-Release.ps1
.EXAMPLE
    .\scripts\Build-Release.ps1 -Version 1.1.0 -SdkDir D:\libs\webview2
#>

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

function Say([string]$text) { Write-Host "[Build] $text" -ForegroundColor Cyan }
function Ok([string]$text) { Write-Host "[OK]   $text" -ForegroundColor Green }
function Fail([string]$text) { throw $text }

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot = Split-Path -Parent $here
if (-not $OutDir) { $OutDir = Join-Path $repoRoot 'release' }
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

# 发布构建固定的 WebView2 SDK 版本（可复现性：三件套必须来自同一个 NuGet 包目录）
$SdkVersion = '1.0.4078.44'

function Resolve-Assembly([string]$root, [string]$name, [string]$archFilter = '') {
    if (-not $root -or -not (Test-Path -LiteralPath $root -PathType Container)) { return $null }
    $hits = @(Get-ChildItem -LiteralPath $root -Recurse -Filter $name -ErrorAction SilentlyContinue)
    if ($hits.Count -eq 0) { return $null }
    if ($archFilter) {
        $pref = @($hits | Where-Object { $_.FullName -match [regex]::Escape($archFilter) })
        if ($pref.Count -gt 0) { $hits = $pref }
    }
    $lib = @($hits | Where-Object { $_.FullName -match '[\\/]lib[\\/]' })
    if ($lib.Count -gt 0) { $hits = $lib }
    $first = $hits | Sort-Object { $_.FullName.Length } | Select-Object -First 1
    if ($null -eq $first) { return $null }
    return $first.FullName
}

function Resolve-SdkFromDir([string]$root) {
    $arch = switch ($env:PROCESSOR_ARCHITECTURE) { 'ARM64' {'win-arm64'} 'x86' {'win-x86'} default {'win-x64'} }
    $core = Resolve-Assembly $root 'Microsoft.Web.WebView2.Core.dll'
    $wf = Resolve-Assembly $root 'Microsoft.Web.WebView2.WinForms.dll'
    $loader = Resolve-Assembly $root 'WebView2Loader.dll' $arch
    if (-not ($core -and $wf -and $loader)) { return $null }
    return [pscustomobject]@{ Core = $core; WinForms = $wf; Loader = $loader; Root = $root }
}

# 可复现构建：三件套必须来自同一个 NuGet 包目录，且版本与 $SdkVersion 完全一致。
# 不再从已安装目录/旧 ~/.dsh/desktop/NuGet 缓存“最高版本”拼凑。
function Resolve-SdkRoot([string]$extraRoot) {
    if ($extraRoot) {
        $sdk = Resolve-SdkFromDir $extraRoot
        if ($sdk) {
            $fv = ([System.Diagnostics.FileVersionInfo]::GetVersionInfo($sdk.Core)).FileVersion
            if ($fv -ne $SdkVersion) {
                Fail ("-SdkDir 的 WebView2 版本为 {0}，发布构建要求固定 {1}（可复现性）。" -f $fv, $SdkVersion)
            }
            return $sdk
        }
        return $null
    }
    $package = Join-Path $env:USERPROFILE ".nuget\packages\microsoft.web.webview2\$SdkVersion"
    if (Test-Path -LiteralPath $package -PathType Container) {
        $sdk = Resolve-SdkFromDir $package
        if ($sdk) {
            $fv = ([System.Diagnostics.FileVersionInfo]::GetVersionInfo($sdk.Core)).FileVersion
            if ($fv -eq $SdkVersion) { return $sdk }
        }
    }
    return $null
}

function ConvertTo-AssemblyVersion([string]$v) {
    # 语义化版本 -> 4 段 AssemblyVersion（如 1.1.0 -> 1.1.0.0；1.2.3.4 -> 原样）
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

try {
    if ($Version -notmatch '^\d+\.\d+\.\d+(?:\.\d+)?(?:-[A-Za-z0-9._+-]+)?$') {
        Fail "版本号格式非法：$Version（示例：1.1.0 或 1.1.0-rc.1）。"
    }
    $assemblyVersion = ConvertTo-AssemblyVersion $Version

    $csc = @(
        "$env:WINDIR\Microsoft.NET\Framework64\v4.0.30319\csc.exe",
        "$env:WINDIR\Microsoft.NET\Framework\v4.0.30319\csc.exe"
    ) | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
    if (-not $csc) { Fail '找不到 .NET Framework 4 csc.exe。Windows 11 正常应自带。' }

    $sdkTemp = $null
    $sdk = Resolve-SdkRoot $SdkDir
    if (-not $sdk) {
        # 下载并解压进用户 NuGet 包缓存目录，后续构建直接复用同一来源
        $package = Join-Path $env:USERPROFILE ".nuget\packages\microsoft.web.webview2\$SdkVersion"
        $sdkTemp = Join-Path $env:TEMP ("dsh-release-sdk-" + [Guid]::NewGuid().ToString('N'))
        Say "本机没有固定版本 $SdkVersion 的 WebView2 SDK，从 NuGet 下载 ..."
        New-Item -ItemType Directory -Force -Path $sdkTemp | Out-Null
        New-Item -ItemType Directory -Force -Path $package | Out-Null
        $nupkg = Join-Path $sdkTemp 'pkg.zip'
        Invoke-WebRequest -UseBasicParsing -Uri "https://www.nuget.org/api/v2/package/Microsoft.Web.WebView2/$SdkVersion" -OutFile $nupkg
        Expand-Archive -LiteralPath $nupkg -DestinationPath $package -Force
        $sdk = Resolve-SdkFromDir $package
        if ($sdk) {
            $fv = ([System.Diagnostics.FileVersionInfo]::GetVersionInfo($sdk.Core)).FileVersion
            if ($fv -ne $SdkVersion) { $sdk = $null }
        }
        if (-not $sdk) { Fail "无法获取固定版本 $SdkVersion 的 WebView2 SDK 三件套。可用 -SdkDir 指定同一版本的三个 DLL 所在目录。" }
    }
    Ok ("WebView2 SDK：{0}（固定 {1}）" -f $sdk.Root, $SdkVersion)

    $staging = Join-Path $env:TEMP ("dsh-release-" + [Guid]::NewGuid().ToString('N'))
    $appDir = Join-Path $staging 'DeepSeek Harness DesktopShell'
    try {
        New-Item -ItemType Directory -Force -Path $appDir | Out-Null
        $exe = Join-Path $appDir 'DeepSeekHarness.exe'

        Say '编译 DeepSeekHarness.exe...'
        # EXE 版本元数据与 -Version 同步（AssemblyVersion/FileVersion/InformationalVersion）
        $versionInfo = Join-Path $staging 'VersionInfo.cs'
        @"
using System.Reflection;
[assembly: AssemblyVersion("$assemblyVersion")]
[assembly: AssemblyFileVersion("$assemblyVersion")]
[assembly: AssemblyInformationalVersion("$Version")]
"@ | Set-Content -LiteralPath $versionInfo -Encoding ascii

        $compilerArgs = @(
            '/nologo', '/target:winexe', '/platform:anycpu', '/optimize+',
            "/out:$exe",
            "/win32icon:$(Join-Path $repoRoot 'assets\DeepSeekHarness.ico')",
            "/win32manifest:$(Join-Path $repoRoot 'src\app.manifest')",
            '/reference:System.dll', '/reference:System.Core.dll', '/reference:System.Drawing.dll',
            '/reference:System.Windows.Forms.dll', '/reference:System.Web.Extensions.dll',
            "/reference:$($sdk.Core)", "/reference:$($sdk.WinForms)",
            (Join-Path $repoRoot 'src\DeepSeekHarness.cs'),
            $versionInfo
        )
        & $csc @compilerArgs
        if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $exe)) {
            Fail "C# 编译失败，退出码 $LASTEXITCODE。"
        }
        $exeVersion = [System.Diagnostics.FileVersionInfo]::GetVersionInfo($exe).FileVersion
        if ($exeVersion -ne $assemblyVersion) {
            Fail "EXE 版本元数据未同步：期望 $assemblyVersion，实际 $exeVersion。"
        }
        Ok "编译完成（EXE FileVersion：$exeVersion）。"

        Copy-Item -LiteralPath $sdk.Core -Destination (Join-Path $appDir 'Microsoft.Web.WebView2.Core.dll') -Force
        Copy-Item -LiteralPath $sdk.WinForms -Destination (Join-Path $appDir 'Microsoft.Web.WebView2.WinForms.dll') -Force
        Copy-Item -LiteralPath $sdk.Loader -Destination (Join-Path $appDir 'WebView2Loader.dll') -Force
        foreach ($asset in 'DeepSeekHarness.ico', 'DeepSeekHarness-Light.ico', 'DeepSeekHarness-Dark.ico', 'DeepSeekHarness.svg') {
            Copy-Item -LiteralPath (Join-Path $repoRoot "assets\$asset") -Destination (Join-Path $appDir $asset) -Force
        }
        Copy-Item -LiteralPath (Join-Path $repoRoot 'scripts\Manage-Dsh.ps1') -Destination (Join-Path $appDir 'Manage-Dsh.ps1') -Force
        Copy-Item -LiteralPath (Join-Path $repoRoot 'scripts\Uninstall-DesktopShell.ps1') -Destination (Join-Path $appDir 'Uninstall-DesktopShell.ps1') -Force
        Copy-Item -LiteralPath (Join-Path $repoRoot 'scripts\Install-Release.ps1') -Destination (Join-Path $appDir 'Install-Release.ps1') -Force
        Copy-Item -LiteralPath (Join-Path $repoRoot 'scripts\Repair-CostMeterLedger.ps1') -Destination (Join-Path $appDir 'Repair-CostMeterLedger.ps1') -Force
        Set-Content -LiteralPath (Join-Path $appDir 'version.txt') -Value $Version -Encoding ascii

        $bat = @'
@echo off
setlocal
where pwsh >nul 2>nul
if errorlevel 1 (
  echo [DSH Desktop] PowerShell 7 is required.
  echo Download: https://github.com/PowerShell/PowerShell/releases
  pause
  exit /b 1
)
pwsh -NoProfile -ExecutionPolicy Bypass -File "%~dp0Install-Release.ps1" %*
pause
'@
        Set-Content -LiteralPath (Join-Path $appDir 'install.bat') -Value $bat -Encoding ascii

        $zip = Join-Path $OutDir 'DeepSeekHarness-DesktopShell.zip'
        if (Test-Path -LiteralPath $zip) { Remove-Item -LiteralPath $zip -Force }
        Say '打包 zip...'
        Compress-Archive -Path $appDir -DestinationPath $zip -CompressionLevel Optimal
        if (-not (Test-Path -LiteralPath $zip)) { Fail 'zip 打包失败。' }

        $verify = Join-Path $env:TEMP ("dsh-release-verify-" + [Guid]::NewGuid().ToString('N'))
        try {
            Expand-Archive -LiteralPath $zip -DestinationPath $verify -Force
            $expected = 14
            $actual = @(Get-ChildItem -LiteralPath (Join-Path $verify 'DeepSeek Harness DesktopShell') -File -ErrorAction SilentlyContinue).Count
            if ($actual -ne $expected) { Fail "zip 自校验失败：期望 $expected 个文件，实际 $actual。" }
            Ok "zip 自校验通过（$actual 个文件）。"
        } finally {
            Remove-Item -LiteralPath $verify -Recurse -Force -ErrorAction SilentlyContinue
        }

        $hash = (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash
        $size = (Get-Item -LiteralPath $zip).Length
        Set-Content -LiteralPath (Join-Path $OutDir 'SHA256SUMS.txt') -Value ("SHA256  $hash  DeepSeekHarness-DesktopShell.zip") -Encoding ascii

        Ok "发布包：$zip"
        Ok "大小：$([math]::Round($size / 1KB, 1)) KB"
        Ok "SHA256：$hash"
        Write-Host ''
        Write-Host '使用方式：解压 zip 后双击 install.bat；或运行 Install-Release.ps1。' -ForegroundColor DarkGray
        Write-Host '校验：Get-FileHash -Algorithm SHA256 release\DeepSeekHarness-DesktopShell.zip' -ForegroundColor DarkGray
    } finally {
        Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue
        if ($sdkTemp) { Remove-Item -LiteralPath $sdkTemp -Recurse -Force -ErrorAction SilentlyContinue }
    }
} catch {
    Write-Host ''
    Write-Host "构建失败：$($_.Exception.Message)" -ForegroundColor Red
    exit 1
}
