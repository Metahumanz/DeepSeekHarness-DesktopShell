param(
    [string]$Version = '1.0.0',
    [string]$OutDir = '',
    [string]$SdkDir = ''
)

<#
.SYNOPSIS
    构建 DesktopShell 发布包（免编译 zip，普通用户双击即可安装）。

.DESCRIPTION
    1. 定位 WebView2 SDK 程序集（优先 -SdkDir → 已安装目录 → NuGet 缓存 → NuGet 在线下载）
    2. 用 .NET Framework csc 编译 DeepSeekHarness.exe
    3. 组装自包含目录并打包 release/DeepSeekHarness-DesktopShell.zip
    4. 自校验 zip 内容并输出 SHA256

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

function Resolve-SdkRoot([string]$extraRoot) {
    $arch = switch ($env:PROCESSOR_ARCHITECTURE) { 'ARM64' {'win-arm64'} 'x86' {'win-x86'} default {'win-x64'} }
    $candidates = @()
    if ($extraRoot) { $candidates += $extraRoot }
    $candidates += (Join-Path $env:LOCALAPPDATA 'Programs\DeepSeek Harness DesktopShell')
    $candidates += (Join-Path $env:USERPROFILE '.dsh\desktop')
    $nuget = Join-Path $env:USERPROFILE '.nuget\packages\microsoft.web.webview2'
    if (Test-Path -LiteralPath $nuget -PathType Container) {
        $versions = @(Get-ChildItem -LiteralPath $nuget -Directory -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match '^\d+\.\d+' } |
            Sort-Object { try { [version]$_.Name } catch { [version]'0.0' } } -Descending)
        if ($versions.Count -gt 0) { $candidates += $versions[0].FullName }
    }
    foreach ($root in $candidates) {
        $core = Resolve-Assembly $root 'Microsoft.Web.WebView2.Core.dll'
        $wf = Resolve-Assembly $root 'Microsoft.Web.WebView2.WinForms.dll'
        $loader = Resolve-Assembly $root 'WebView2Loader.dll' $arch
        if ($core -and $wf -and $loader) {
            return [pscustomobject]@{ Core = $core; WinForms = $wf; Loader = $loader; Root = $root }
        }
    }
    return $null
}

try {
    $csc = @(
        "$env:WINDIR\Microsoft.NET\Framework64\v4.0.30319\csc.exe",
        "$env:WINDIR\Microsoft.NET\Framework\v4.0.30319\csc.exe"
    ) | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
    if (-not $csc) { Fail '找不到 .NET Framework 4 csc.exe。Windows 11 正常应自带。' }

    $sdk = Resolve-SdkRoot $SdkDir
    if (-not $sdk) {
        $sdkVersion = '1.0.4078.44'
        $sdkTemp = Join-Path $env:TEMP ("dsh-release-sdk-" + [Guid]::NewGuid().ToString('N'))
        try {
            Say "本机没有可用 WebView2 SDK 程序集，从 NuGet 下载 $sdkVersion ..."
            New-Item -ItemType Directory -Force -Path $sdkTemp | Out-Null
            $nupkg = Join-Path $sdkTemp 'pkg.zip'
            Invoke-WebRequest -UseBasicParsing -Uri "https://www.nuget.org/api/v2/package/Microsoft.Web.WebView2/$sdkVersion" -OutFile $nupkg
            $extract = Join-Path $sdkTemp 'x'
            Expand-Archive -LiteralPath $nupkg -DestinationPath $extract -Force
            $sdk = Resolve-SdkRoot $extract
        } finally {
            Remove-Item -LiteralPath $sdkTemp -Recurse -Force -ErrorAction SilentlyContinue
        }
        if (-not $sdk) { Fail '无法获取 WebView2 SDK 程序集。请用 -SdkDir 指定包含三个 DLL 的目录。' }
    }
    Ok ("WebView2 SDK：{0}" -f $sdk.Root)

    $staging = Join-Path $env:TEMP ("dsh-release-" + [Guid]::NewGuid().ToString('N'))
    $appDir = Join-Path $staging 'DeepSeek Harness DesktopShell'
    try {
        New-Item -ItemType Directory -Force -Path $appDir | Out-Null
        $exe = Join-Path $appDir 'DeepSeekHarness.exe'

        Say '编译 DeepSeekHarness.exe...'
        $compilerArgs = @(
            '/nologo', '/target:winexe', '/platform:anycpu', '/optimize+',
            "/out:$exe",
            "/win32icon:$(Join-Path $repoRoot 'assets\DeepSeekHarness.ico')",
            "/win32manifest:$(Join-Path $repoRoot 'src\app.manifest')",
            '/reference:System.dll', '/reference:System.Core.dll', '/reference:System.Drawing.dll',
            '/reference:System.Windows.Forms.dll', '/reference:System.Web.Extensions.dll',
            "/reference:$($sdk.Core)", "/reference:$($sdk.WinForms)",
            (Join-Path $repoRoot 'src\DeepSeekHarness.cs')
        )
        & $csc @compilerArgs
        if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $exe)) {
            Fail "C# 编译失败，退出码 $LASTEXITCODE。"
        }
        Ok '编译完成。'

        Copy-Item -LiteralPath $sdk.Core -Destination (Join-Path $appDir 'Microsoft.Web.WebView2.Core.dll') -Force
        Copy-Item -LiteralPath $sdk.WinForms -Destination (Join-Path $appDir 'Microsoft.Web.WebView2.WinForms.dll') -Force
        Copy-Item -LiteralPath $sdk.Loader -Destination (Join-Path $appDir 'WebView2Loader.dll') -Force
        foreach ($asset in 'DeepSeekHarness.ico', 'DeepSeekHarness-Light.ico', 'DeepSeekHarness-Dark.ico', 'DeepSeekHarness.svg') {
            Copy-Item -LiteralPath (Join-Path $repoRoot "assets\$asset") -Destination (Join-Path $appDir $asset) -Force
        }
        Copy-Item -LiteralPath (Join-Path $repoRoot 'scripts\Manage-Dsh.ps1') -Destination (Join-Path $appDir 'Manage-Dsh.ps1') -Force
        Copy-Item -LiteralPath (Join-Path $repoRoot 'scripts\Uninstall-DesktopShell.ps1') -Destination (Join-Path $appDir 'Uninstall-DesktopShell.ps1') -Force
        Copy-Item -LiteralPath (Join-Path $repoRoot 'scripts\Install-Release.ps1') -Destination (Join-Path $appDir 'Install-Release.ps1') -Force
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
            $expected = 13
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
    }
} catch {
    Write-Host ''
    Write-Host "构建失败：$($_.Exception.Message)" -ForegroundColor Red
    exit 1
}
