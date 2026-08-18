param(
    [string]$Owner = '',
    [string]$Repo = '',
    [string]$Tag = '',
    [string]$ZipPath = '',
    [string]$InstallDir = '',
    [switch]$NoShortcuts,
    [switch]$NoLaunch,
    [switch]$NoWizard
)

<#
.SYNOPSIS
    一条命令安装 DesktopShell：从 GitHub Releases 下载发布包并安装。

.DESCRIPTION
    - 未指定 Owner/Repo 时，优先从 `git remote get-url origin` 推断
    - 指定 -Tag 下载对应版本；否则下载 latest
    - 指定 -ZipPath 时使用本地 zip（离线 / 测试用）
    - 其余参数透传给 Install-Release.ps1

.EXAMPLE
    .\scripts\Install-FromGitHub.ps1
.EXAMPLE
    .\scripts\Install-FromGitHub.ps1 -Owner deepseek-ai -Repo dsh-desktop-shell
.EXAMPLE
    .\scripts\Install-FromGitHub.ps1 -ZipPath release\DeepSeekHarness-DesktopShell.zip -NoLaunch
#>

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

function Say([string]$text) { Write-Host "[DSH Desktop] $text" -ForegroundColor Cyan }
function Ok([string]$text) { Write-Host "[OK] $text" -ForegroundColor Green }
function Fail([string]$text) { throw $text }

try {
    $here = Split-Path -Parent $MyInvocation.MyCommand.Path
    $repoRoot = Split-Path -Parent $here

    if (-not $ZipPath -and (-not $Owner -or -not $Repo)) {
        try {
            $remote = & git -C $repoRoot remote get-url origin 2>$null
            if ($remote -match 'github\.com[:/]([^/]+)/([^/]+?)(?:\.git)?$') {
                if (-not $Owner) { $Owner = $Matches[1] }
                if (-not $Repo) { $Repo = $Matches[2] }
            }
        } catch {}
    }

    $work = Join-Path $env:TEMP ('dsh-desktop-setup-' + [Guid]::NewGuid().ToString('N'))
    try {
        New-Item -ItemType Directory -Force -Path $work | Out-Null

        if ($ZipPath) {
            if (-not (Test-Path -LiteralPath $ZipPath -PathType Leaf)) { Fail "找不到本地发布包：$ZipPath" }
            Say "使用本地发布包：$ZipPath"
            Copy-Item -LiteralPath $ZipPath -Destination (Join-Path $work 'pkg.zip') -Force
        } else {
            if (-not $Owner -or -not $Repo) {
                Fail '无法确定 GitHub 仓库。请显式传入 -Owner xxx -Repo xxx，或先设置 git remote origin。'
            }
            if ($Tag) { $url = "https://github.com/$Owner/$Repo/releases/download/$Tag/DeepSeekHarness-DesktopShell.zip" }
            else { $url = "https://github.com/$Owner/$Repo/releases/latest/download/DeepSeekHarness-DesktopShell.zip" }
            Say "下载：$url"
            Invoke-WebRequest -UseBasicParsing -Uri $url -OutFile (Join-Path $work 'pkg.zip')
        }

        Expand-Archive -LiteralPath (Join-Path $work 'pkg.zip') -DestinationPath $work -Force
        $setupDir = Get-ChildItem -LiteralPath $work -Directory | Sort-Object Name | Select-Object -First 1
        if (-not $setupDir) { Fail '发布包内没有找到应用目录。' }

        $installer = Join-Path $setupDir.FullName 'Install-Release.ps1'
        if (-not (Test-Path -LiteralPath $installer)) { Fail '发布包内缺少 Install-Release.ps1。' }

        & $installer -SetupDir $setupDir.FullName -InstallDir $InstallDir `
            -NoShortcuts:$NoShortcuts -NoLaunch:$NoLaunch -NoWizard:$NoWizard
        if ($LASTEXITCODE -ne 0) { Fail "安装脚本退出码 $LASTEXITCODE。" }
    } finally {
        Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
    }
    exit 0
} catch {
    Write-Host ''
    Write-Host "失败：$($_.Exception.Message)" -ForegroundColor Red
    exit 1
}
