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
    - 下载后必须通过同源 SHA256SUMS.txt 完整性校验（文件名与 hash 同时匹配，失败即中止）
    - 指定 -ZipPath 时使用本地 zip（离线 / 测试用；若旁边有 SHA256SUMS.txt 同样校验）
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

# Windows PowerShell 5.1 与 PowerShell 7 均支持
if ($PSVersionTable.PSVersion -lt [version]'5.1') {
    Write-Host '[DSH Desktop] 需要 Windows PowerShell 5.1 或 PowerShell 7。' -ForegroundColor Red
    exit 1
}

function Say([string]$text) { Write-Host "[DSH Desktop] $text" -ForegroundColor Cyan }
function Ok([string]$text) { Write-Host "[OK] $text" -ForegroundColor Green }
function Warn([string]$text) { Write-Host "[!]   $text" -ForegroundColor Yellow }
function Fail([string]$text) { throw $text }

# 校验 zip 的 SHA256 与 SHA256SUMS.txt 一致（兼容 "SHA256  <hash>  <name>" 与 "<hash>  <name>" 两种格式）。
# 要求「文件名 + hash 同时匹配」，不允许退化成“任意条目 hash 相同也算通过”。
# -Mandatory 时缺失/解析失败/不匹配一律 Fail（网络下载链必须校验）。
function Confirm-ZipHash([string]$zipFile, [string]$sumsPath, [bool]$mandatory) {
    if (-not (Test-Path -LiteralPath $sumsPath -PathType Leaf)) {
        if ($mandatory) { Fail '无法获取 SHA256SUMS.txt（Release 完整性校验缺失），安装已中止。' }
        Warn '未找到 SHA256SUMS.txt，跳过本地发布包校验（离线/测试路径）。'
        return
    }
    $actual = (Get-FileHash -LiteralPath $zipFile -Algorithm SHA256).Hash.ToLowerInvariant()
    $entries = @()
    foreach ($line in (Get-Content -LiteralPath $sumsPath -Encoding UTF8)) {
        if ($line -match '^\s*(?:SHA256\s+)?([0-9a-fA-F]{64})\s+(\S+)\s*$') {
            $entries += [pscustomobject]@{ Hash = $Matches[1].ToLowerInvariant(); Name = $Matches[2] }
        }
    }
    if ($entries.Count -eq 0) { Fail 'SHA256SUMS.txt 内容无法解析，安装已中止。' }
    $zipName = [IO.Path]::GetFileName($zipFile)
    $byName = @($entries | Where-Object { $_.Name -eq $zipName })
    if ($byName.Count -eq 0) {
        Fail "SHA256SUMS.txt 中没有找到与发布包同名（$zipName）的条目，安装已中止。"
    }
    $ok = @($byName | Where-Object { $_.Hash -eq $actual }).Count -gt 0
    if (-not $ok) {
        Fail ("SHA256 校验失败：$zipName 与 SHA256SUMS.txt 不一致，安装已中止。")
    }
    Ok "SHA256 校验通过：$actual"
}

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

        $pkgZip = Join-Path $work 'DeepSeekHarness-DesktopShell.zip'

        if ($ZipPath) {
            if (-not (Test-Path -LiteralPath $ZipPath -PathType Leaf)) { Fail "找不到本地发布包：$ZipPath" }
            Say "使用本地发布包：$ZipPath"
            Copy-Item -LiteralPath $ZipPath -Destination $pkgZip -Force
            Confirm-ZipHash $pkgZip (Join-Path (Split-Path -Parent $ZipPath) 'SHA256SUMS.txt') $false
        } else {
            if (-not $Owner -or -not $Repo) {
                Fail '无法确定 GitHub 仓库。请显式传入 -Owner xxx -Repo xxx（建议再带 -Tag v1.0.0 锁定已发布版本），或先设置 git remote origin。'
            }
            if ($Tag) { $url = "https://github.com/$Owner/$Repo/releases/download/$Tag/DeepSeekHarness-DesktopShell.zip" }
            else { $url = "https://github.com/$Owner/$Repo/releases/latest/download/DeepSeekHarness-DesktopShell.zip" }
            Say "下载：$url"
            Invoke-WebRequest -UseBasicParsing -Uri $url -OutFile $pkgZip

            $sumsUrl = if ($Tag) { "https://github.com/$Owner/$Repo/releases/download/$Tag/SHA256SUMS.txt" }
                       else { "https://github.com/$Owner/$Repo/releases/latest/download/SHA256SUMS.txt" }
            try {
                Invoke-WebRequest -UseBasicParsing -Uri $sumsUrl -OutFile (Join-Path $work 'SHA256SUMS.txt')
            } catch {
                Fail "下载 SHA256SUMS.txt 失败：$($_.Exception.Message)。无法校验发布包，安装已中止。"
            }
            Confirm-ZipHash $pkgZip (Join-Path $work 'SHA256SUMS.txt') $true
        }

        Expand-Archive -LiteralPath $pkgZip -DestinationPath $work -Force
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
