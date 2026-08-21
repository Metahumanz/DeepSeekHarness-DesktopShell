param(
    [switch]$FirstInstall,
    [switch]$NonInteractive,
    [string]$DshVersion = '',
    [string]$ProfileName = '',
    [int]$Port = 0,
    [string]$WorkingDirectory = ''
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$OutputEncoding = [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)

# Windows PowerShell 5.1 与 PowerShell 7 均支持
if ($PSVersionTable.PSVersion -lt [version]'5.1') {
    Write-Host '[DSH] 需要 Windows PowerShell 5.1 或 PowerShell 7。' -ForegroundColor Red
    exit 1
}

function Title([string]$text) {
    Write-Host ''
    Write-Host ('=' * 72) -ForegroundColor DarkGray
    Write-Host $text -ForegroundColor Cyan
    Write-Host ('=' * 72) -ForegroundColor DarkGray
}
function Say([string]$text) { Write-Host "[DSH] $text" -ForegroundColor Cyan }
function Ok([string]$text) { Write-Host "[OK]  $text" -ForegroundColor Green }
function Warn([string]$text) { Write-Host "[!]   $text" -ForegroundColor Yellow }
function Fail([string]$text) { throw $text }

# utf8NoBOM 在 Windows PowerShell 5.1 不可用，统一用 .NET 写无 BOM UTF-8
function Write-Utf8NoBom([string]$Path, [string]$Content) {
    [System.IO.File]::WriteAllText($Path, $Content, [System.Text.UTF8Encoding]::new($false))
}

$homeDir = [Environment]::GetFolderPath('UserProfile')
$dshHome = if ($env:DSH_HOME) { $env:DSH_HOME } else { Join-Path $homeDir '.dsh' }
$desktopDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$settingsPath = Join-Path $desktopDir 'settings.json'
$legacyRuntimeDir = Join-Path $dshHome 'runtime'
# DSH 兼容策略：默认版本 + 最低兼容版本 + 测试版本，单一来源 COMPATIBILITY.json。
# - defaultDshVersion：新设置/缺失/无效时 npx 默认版本，也是 DesktopShell 自己启动的兜底版本。
# - minimumCompatibleDshVersion：明确过旧的版本下限，低于它不应继续尝试。
# - testedDshVersions：实际验证过的版本，只用于日志/提示，不作为未来版本硬白名单。
# 兼容旧 schema v1：只有 verifiedDshVersion 时，默认/最低/测试都回落到该版本。
$DefaultDshVersion = '0.1.0-rc.7'
$MinimumCompatibleDshVersion = '0.1.0-rc.7'
$TestedDshVersions = @('0.1.0-rc.7', '0.1.0-rc.8', '0.1.1-rc.1')
$compatPath = Join-Path $desktopDir 'COMPATIBILITY.json'
if (Test-Path -LiteralPath $compatPath -PathType Leaf) {
    try {
        $compat = Get-Content -LiteralPath $compatPath -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($compat.defaultDshVersion -match '^\d+\.\d+\.\d+(?:-[A-Za-z0-9._+-]+)?$') {
            $DefaultDshVersion = [string]$compat.defaultDshVersion
        } elseif ($compat.verifiedDshVersion -match '^\d+\.\d+\.\d+(?:-[A-Za-z0-9._+-]+)?$') {
            $DefaultDshVersion = [string]$compat.verifiedDshVersion
        }
        if ($compat.minimumCompatibleDshVersion -match '^\d+\.\d+\.\d+(?:-[A-Za-z0-9._+-]+)?$') {
            $MinimumCompatibleDshVersion = [string]$compat.minimumCompatibleDshVersion
        } elseif ($compat.verifiedDshVersion -match '^\d+\.\d+\.\d+(?:-[A-Za-z0-9._+-]+)?$') {
            $MinimumCompatibleDshVersion = [string]$compat.verifiedDshVersion
        }
        if ($compat.testedDshVersions -is [System.Array] -and @($compat.testedDshVersions).Count -gt 0) {
            $parsed = @($compat.testedDshVersions | ForEach-Object { [string]$_ } | Where-Object { $_ -match '^\d+\.\d+\.\d+(?:-[A-Za-z0-9._+-]+)?$' })
            if ($parsed.Count -gt 0) { $TestedDshVersions = $parsed }
        } elseif ($compat.verifiedDshVersion -match '^\d+\.\d+\.\d+(?:-[A-Za-z0-9._+-]+)?$') {
            $TestedDshVersions = @([string]$compat.verifiedDshVersion)
        }
    } catch {}
}
# npx 回退版本与默认版本同一来源，不允许各自硬编码（单一事实来源）。
$defaultDshVersion = $DefaultDshVersion
$defaultProfilePnpmVersion = '10.33.2'

# 插件目录。分层与选择性 pin 策略（v1.0.3 起）：
#   - Tier='core'      核心推荐（新 Profile 默认勾选）：插件发现/工作台/Skills/@file/历史重跑
#   - Tier='enhanced'  体验增强（默认展示但可取消）：UI 与操作效率，不装不影响 DSH 核心
#   - Tier='advanced'  高级/实验（默认不装）：会改变 Agent 行为或涉及估算/兼容修复
#   - 有正式 npm/release 且已确认兼容的推荐项使用 caret/range 或 release tag，不再一律锁旧 commit。
#   - GitHub 插件有正式 release tag 时优先 release tag，不无条件跟随 main。
#   - 对 DesktopShell 有兼容修复依赖的插件（Cost Meter / Sentinel）保持已审核版本，不裸跟 latest。
#   - 下表按本机真实 web Profile（C:\Users\metahumanz\.dsh\profiles\web\package.json，2026-08-21）同步；
#     Installed 只是本机快照，不等于已经完成 rc1 BootReady 兼容认证。
#   - 本机 link:C:\Users\metahumanz\.dsh\dsh-browser\... 的 bridge-browser 是本地集成依赖，
#     不放入可移植推荐目录，也不在隔离 preflight 中伪造安装。
$PluginCatalog = @(
    # ---- 核心推荐 ----
    [pscustomobject]@{ No=1;  Id='market';        Name='插件市场';                  Spec='dshmarket@1.17.1'; Tier='core'; Allow=@(); Installed='1.17.1' },
    [pscustomobject]@{ No=2;  Id='sidebar';       Name='Better Sidebar 工作台';     Spec='dsh-better-sidebar@^0.14.0'; Tier='core'; Allow=@('node-pty'); Installed='0.14.0'; Note='按本机 web Profile 使用 0.14.0；不因本机实测改变 default/minimum rc.7' },
    [pscustomobject]@{ No=3;  Id='skills';        Name='Skills Manager';            Spec='@michengai/dsh-skills-manager@0.1.23'; Tier='core'; Allow=@(); Installed='0.1.23' },
    [pscustomobject]@{ No=4;  Id='at-file';       Name='@file 文件引用';            Spec='github:omdsh-dev/dsh-at-file'; Tier='core'; Allow=@(); Installed='0.6.7' },
    [pscustomobject]@{ No=5;  Id='rewind';        Name='历史消息回退/重跑';         Spec='github:XSJUSTC/dsh-rewind'; Tier='core'; Allow=@(); Installed='2.1.1' },
    # ---- 体验增强 ----
    [pscustomobject]@{ No=6;  Id='file-mentions'; Name='文件路径点击/提及';         Spec='git+https://github.com/a903067276-rgb/dsh-file-mentions.git'; Tier='enhanced'; Allow=@(); Installed='1.0.8' },
    [pscustomobject]@{ No=7;  Id='collapse';      Name='Tool/Think 自动折叠';       Spec='github:a179-sanae/dsh-auto-collapse'; Tier='enhanced'; Allow=@(); Installed='0.1.3' },
    [pscustomobject]@{ No=8;  Id='tidy';          Name='Codex 风格对话排版';        Spec='dsh-chat-tidy@^0.2.0'; Tier='enhanced'; Allow=@(); Installed='0.2.0' },
    [pscustomobject]@{ No=9;  Id='outline';       Name='对话侧边大纲';              Spec='github:EnkiduGilgamesh/dsh-codex-side-outline'; Tier='enhanced'; Allow=@(); Installed='1.0.0' },
    [pscustomobject]@{ No=10; Id='archive';       Name='Better Archive';            Spec='git+https://github.com/huahai0202/dsh-better-archive.git'; Tier='enhanced'; Allow=@(); Installed='0.3.1' },
    [pscustomobject]@{ No=11; Id='video';         Name='视频预览';                  Spec='dsh-video-preview@^0.1.1'; Tier='enhanced'; Allow=@(); Installed='0.1.1' },
    [pscustomobject]@{ No=12; Id='git-remotes';   Name='Git 远程仓库工具';          Spec='github:yq04/dsh-git-remotes'; Tier='enhanced'; Allow=@(); Installed='0.1.0' },
    [pscustomobject]@{ No=13; Id='notification';  Name='通知增强';                  Spec='git+https://github.com/omdsh-dev/dsh-notification.git'; Tier='enhanced'; Allow=@(); Installed='0.1.3' },
    [pscustomobject]@{ No=14; Id='open-vscode';   Name='在 VS Code 中打开';         Spec='github:omdsh-dev/dsh-open-in-vscode'; Tier='enhanced'; Allow=@(); Installed='0.1.6' },
    [pscustomobject]@{ No=15; Id='sidebar-qa';    Name='Sidebar QA';                Spec='github:ChenRuoT/dsh-sidebar-qa'; Tier='enhanced'; Allow=@(); Installed='0.4.0' },
    [pscustomobject]@{ No=16; Id='sidebar-office'; Name='Better Sidebar Office';      Spec='@huanlin/dsh-plugin-better-sidebar-plugin-office@^0.1.0'; Tier='enhanced'; Allow=@(); Installed='0.1.0' },
    [pscustomobject]@{ No=17; Id='archify';       Name='Archify DSH';                Spec='@tt-a1i/archify-dsh@^0.1.0'; Tier='enhanced'; Allow=@(); Installed='0.1.0' },
    # ---- 高级/实验（默认不装） ----
    [pscustomobject]@{ No=18; Id='auto-mode';     Name='Auto Mode';                 Spec='@nanmicoder/dsh-auto-mode@^0.1.4'; Tier='advanced'; Allow=@(); Installed='0.1.4' },
    [pscustomobject]@{ No=19; Id='cost';          Name='Cost Meter';                Spec='dsh-cost-meter@^1.5.35'; Tier='advanced'; Allow=@(); Installed='1.5.35'; Note='统计参考，不等于官方账单；按本机 web Profile 声明 ^1.5.35，当前安装 1.5.35' },
    [pscustomobject]@{ No=20; Id='dream-skin';    Name='Dream Skin 主题';           Spec='dsh-dream-skin@^0.4.5'; Tier='advanced'; Allow=@(); Installed='0.4.5'; Note='本机 web Profile 实际安装 0.4.5，保留 sticky restore / host-backed marker 检查' },
    [pscustomobject]@{ No=21; Id='sentinel';      Name='Sentinel 条件唤醒';         Spec='dsh-sentinel@0.11.0'; Tier='advanced'; Allow=@(); Installed='0.11.0' },
    [pscustomobject]@{ No=22; Id='liangshen';     Name='量神';                       Spec='@linxin666/dsh-liangshen@^0.2.7'; Tier='advanced'; Allow=@(); Installed='0.2.7' },
    [pscustomobject]@{ No=23; Id='thought-buddy'; Name='Thought Buddy';              Spec='@dsh-plugin/dsh-thought-buddy@^0.2.0'; Tier='advanced'; Allow=@(); Installed='0.2.0' }
)

function Read-Default([string]$prompt, [string]$default) {
    if ($NonInteractive) { return $default }
    $value = Read-Host "$prompt [$default]"
    if ([string]::IsNullOrWhiteSpace($value)) { return $default }
    return $value.Trim()
}

function Read-YesNo([string]$prompt, [bool]$defaultYes = $true) {
    if ($NonInteractive) { return $defaultYes }
    $suffix = if ($defaultYes) { '[Y/n]' } else { '[y/N]' }
    while ($true) {
        $value = (Read-Host "$prompt $suffix").Trim().ToLowerInvariant()
        if (-not $value) { return $defaultYes }
        if ($value -in @('y','yes','是','1')) { return $true }
        if ($value -in @('n','no','否','0')) { return $false }
    }
}

function Refresh-ProcessPath {
    try {
        $machine = [Environment]::GetEnvironmentVariable('Path','Machine')
        $user = [Environment]::GetEnvironmentVariable('Path','User')
        $env:Path = "$machine;$user"
    } catch {}
}

function Get-NodeVersion {
    $node = Get-Command node.exe -ErrorAction SilentlyContinue
    if (-not $node) { $node = Get-Command node -ErrorAction SilentlyContinue }
    if (-not $node) { return $null }
    try { return (& $node.Source -p 'process.versions.node').Trim() } catch { return $null }
}

function Test-NodeVersion([string]$raw) {
    if ([string]::IsNullOrWhiteSpace($raw)) { return $false }
    try {
        $v = [version]$raw
        return (($v.Major -eq 22 -and $v.Minor -ge 19) -or $v.Major -ge 24)
    } catch { return $false }
}

function Ensure-Node {
    $version = Get-NodeVersion
    if (Test-NodeVersion $version) {
        Ok "Node.js $version"
        return
    }

    if ($version) { Warn "Node.js $version 过旧；建议 >=22.19，或 >=24。" }
    else { Warn '没有检测到 Node.js。' }

    if ($NonInteractive) { Fail '缺少满足要求的 Node.js，非交互模式不能自动确认 winget 安装。' }
    if (-not (Read-YesNo '是否使用 winget 安装/升级 Node.js LTS？' $true)) {
        Fail '安装 DSH 需要 Node.js。安装已取消。'
    }

    $winget = Get-Command winget.exe -ErrorAction SilentlyContinue
    if (-not $winget) { Fail '找不到 winget。请先安装 Node.js 22.19+ / 24+ 后重试。' }

    Say '正在通过 winget 安装 Node.js LTS...'
    & $winget.Source install --id OpenJS.NodeJS.LTS -e --accept-source-agreements --accept-package-agreements --silent
    if ($LASTEXITCODE -ne 0) { Fail "winget 安装 Node.js 失败，退出码 $LASTEXITCODE。" }
    Refresh-ProcessPath
    $version = Get-NodeVersion
    if (-not (Test-NodeVersion $version)) { Fail 'Node.js 安装后当前进程仍未检测到可用版本，请重新打开 PowerShell 后再运行安装器。' }
    Ok "Node.js $version"
}


function Test-PortOpen([int]$port) {
    $client = [System.Net.Sockets.TcpClient]::new()
    try {
        $iar = $client.BeginConnect('127.0.0.1', $port, $null, $null)
        if (-not $iar.AsyncWaitHandle.WaitOne(250)) { return $false }
        $client.EndConnect($iar)
        return $true
    } catch { return $false } finally { $client.Dispose() }
}

function Get-Npx {
    $npx = Get-Command npx.cmd -ErrorAction SilentlyContinue
    if (-not $npx) { $npx = Get-Command npx.exe -ErrorAction SilentlyContinue }
    if (-not $npx) { $npx = Get-Command npx -ErrorAction SilentlyContinue }
    if (-not $npx) { Fail '找不到 npx。请确认 Node.js/npm 已正确安装。' }
    return $npx.Source
}

function Normalize-Version([string]$value) {
    if ([string]::IsNullOrWhiteSpace($value)) { return $defaultDshVersion }
    if ($value -notmatch '^[A-Za-z0-9._+\-]+$') { return $defaultDshVersion }
    return $value
}

# Profile 名保留字：官方 DSH 禁止 node_modules；Windows 设备名（CON/PRN/AUX/NUL/COM1-9/LPT1-9）不能作目录名
$ReservedProfileNames = @('node_modules', 'con', 'prn', 'aux', 'nul')

function Test-ReservedProfileName([string]$value) {
    if ([string]::IsNullOrWhiteSpace($value)) { return $false }
    $lower = $value.ToLowerInvariant()
    if ($ReservedProfileNames -contains $lower) { return $true }
    if ($lower -match '^(com|lpt)[1-9]$') { return $true }
    return $false
}

function Normalize-Profile([string]$value) {
    if ([string]::IsNullOrWhiteSpace($value)) { return 'web' }
    if ($value -notmatch '^[A-Za-z0-9_-]+$') { return 'web' }
    if (Test-ReservedProfileName $value) { return 'web' }
    return $value
}


function Get-ProfilePnpmVersion([string]$profile) {
    $modules = Join-Path $dshHome "profiles\$profile\node_modules\.modules.yaml"
    if (Test-Path -LiteralPath $modules) {
        $raw = ''
        try {
            $raw = Get-Content -LiteralPath $modules -Raw -Encoding UTF8
        } catch {
            Fail "无法读取 Profile 的 .modules.yaml（$modules），中止以避免用错误 pnpm 重链接 Profile。"
        }
        if ($raw -match '(?i)store[\\/]+v11\b') { return '11.7.0' }
        if ($raw -match '(?i)store[\\/]+v10\b') { return '10.33.2' }
        if ($raw -match '(?i)store[\\/]+(v\d+)\b') {
            Fail "Profile 的 pnpm store 版本（$($Matches[1])）尚未经 DesktopShell 审核（当前只验证 v10/v11）。请升级 DesktopShell 或改用其它 Profile。"
        }
        Fail 'Profile 的 .modules.yaml 中找不到 pnpm store 版本信息，中止以避免用错误 pnpm 重链接 Profile。'
    }
    return $defaultProfilePnpmVersion
}

function Get-DshCommand {
    foreach ($name in @('dsh.cmd','dsh.exe','dsh')) {
        $cmd = Get-Command $name -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($cmd -and $cmd.Source) {
            $full = [IO.Path]::GetFullPath($cmd.Source)
            if (-not $full.StartsWith([IO.Path]::GetFullPath($legacyRuntimeDir), [StringComparison]::OrdinalIgnoreCase)) {
                return $full
            }
        }
    }
    return $null
}

function Get-DshVersionFromCommand([string]$dsh) {
    if (-not $dsh -or -not (Test-Path -LiteralPath $dsh -PathType Leaf)) { return $null }
    try {
        # 注意：不能依赖 $LASTEXITCODE——Windows PowerShell 5.1 下 .cmd 经管道调用时
        # $LASTEXITCODE 可能保持 -1（输出正常却判失败）。只看输出内容；
        # 读不到内容时返回 $null，由调用方按“未验证”走门槛。
        $raw = (& $dsh --version 2>$null)
        $out = @($raw | Select-Object -First 1)
        if ($out.Count -eq 0) { return $null }
        $text = ([string]($out -join '')).Trim()
        if ($text -match '(?<v>\d+\.\d+\.\d+(?:-[A-Za-z0-9._+-]+)?)') { return $Matches['v'] }
        return $text
    } catch { return $null }
}

function Get-DshVersionFromNpx([string]$version) {
    Ensure-Node
    $npx = Get-Npx
    $version = Normalize-Version $version
    # 不吞 stderr：npm 的 ETARGET / 缺失依赖 / 日志路径必须透出，便于判断上游发布是否完整。
    # Windows PowerShell 5.1 在 EAP=Stop 下会把原生 stderr 直接变终止错误，因此这里临时切 Continue。
    $oldEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $raw = (& $npx -y "@deepseek-ai/dsh@$version" --version 2>&1)
    } finally {
        $ErrorActionPreference = $oldEap
    }
    $text = ($raw | Out-String).Trim()
    if ([string]::IsNullOrWhiteSpace($text)) {
        throw "无法通过 npx 启动 @deepseek-ai/dsh@$version：没有收到任何输出。"
    }

    # 先识别明确失败，再判断版本成功；失败文本里即使出现 SemVer 也绝不能当成功。
    if ($text -match '(?i)ETARGET|notarget|npm error|npm ERR|No matching version found for') {
        $missing = ''
        if ($text -match 'No matching version found for (\S+)') { $missing = $Matches[1] }
        $logPath = ''
        if ($text -match '(?im)^.*log of this run can be found in:\s*(.+)$') { $logPath = $Matches[1].Trim() }
        $detail = "无法通过 npx 安装 @deepseek-ai/dsh@$version。"
        if ($missing) { $detail += " 缺失依赖/版本：$missing" }
        if ($logPath) { $detail += " npm 日志：$logPath" }
        $detail += " 原始输出：`r`n$text"
        throw $detail
    }

    # 成功只接受整行独立版本号，不从任意文本中抽取 SemVer。
    if ($text -match '^\d+\.\d+\.\d+(?:-[A-Za-z0-9._+-]+)?$') {
        return $text
    }

    throw "无法通过 npx 启动 @deepseek-ai/dsh@$version：输出不是独立版本号。原始输出：`r`n$text"
}

function Prepare-NpxDsh([string]$version) {
    Ensure-Node
    $version = Normalize-Version $version
    Say "未检测到系统 dsh 命令；按官方运行方式使用 npx @deepseek-ai/dsh@$version。"
    Say 'npx 会在需要时下载到 npm 缓存并直接运行，不做 npm -g 全局安装。'
    $actual = Get-DshVersionFromNpx $version
    if (-not $actual) { Fail "无法通过 npx 启动 @deepseek-ai/dsh@$version。" }
    Ok "npx DSH 可用：@deepseek-ai/dsh@$actual"
    return [pscustomobject]@{ Path=$null; Version=$actual; Mode='npx' }
}

function Resolve-DshRunner([string]$version) {
    $existing = Get-DshCommand
    if ($existing) {
        $gated = Resolve-DshCommandWithGate $existing
        if ($gated) { return $gated }
    }
    return Prepare-NpxDsh $version
}

# DSH 版本门槛：DesktopShell 使用 minimumCompatibleDshVersion 作为最低兼容版本。
# 版本串是 SemVer（如 0.1.0-rc.7），不能用 [version] 强转——System.Version 不解析
# 预发布后缀（0.1.0-rc.6 会抛异常被当“无法判断”而静默放行）。按 SemVer 规则比较：
#   核心三段数字比较；正式版 > 预发布；预发布标识逐段比较
#   （纯数字按数值；数字标识 < 字母标识；字母按 OrdinalIgnoreCase）。
function ConvertTo-SemVerParts([string]$v) {
    if ([string]::IsNullOrWhiteSpace($v)) { return $null }
    if ($v -notmatch '^\s*(\d+)\.(\d+)\.(\d+)(?:-([0-9A-Za-z][0-9A-Za-z.-]*))?(?:\+[0-9A-Za-z.-]+)?\s*$') { return $null }
    $pre = $Matches[4]
    return [pscustomobject]@{
        Major = [int]$Matches[1]
        Minor = [int]$Matches[2]
        Patch = [int]$Matches[3]
        Pre = $(if ($pre) { @($pre -split '\.') } else { @() })
    }
}

function Compare-DshVersion([string]$a, [string]$b) {
    # 返回 -1（a<b）、0（相等）、1（a>b）；任一方无法解析返回 $null。
    $pa = ConvertTo-SemVerParts $a
    $pb = ConvertTo-SemVerParts $b
    if (-not $pa -or -not $pb) { return $null }
    foreach ($n in @('Major', 'Minor', 'Patch')) {
        if ($pa.$n -ne $pb.$n) { return $(if ($pa.$n -lt $pb.$n) { -1 } else { 1 }) }
    }
    if ($pa.Pre.Count -eq 0 -and $pb.Pre.Count -eq 0) { return 0 }
    if ($pa.Pre.Count -eq 0) { return 1 }
    if ($pb.Pre.Count -eq 0) { return -1 }
    $i = 0
    while ($i -lt [Math]::Min($pa.Pre.Count, $pb.Pre.Count)) {
        $x = $pa.Pre[$i]
        $y = $pb.Pre[$i]
        $xn = $x -match '^\d+$'
        $yn = $y -match '^\d+$'
        if ($xn -and $yn) {
            $xi = [int]$x; $yi = [int]$y
            if ($xi -ne $yi) { return $(if ($xi -lt $yi) { -1 } else { 1 }) }
        } elseif ($xn -ne $yn) {
            return $(if ($xn) { -1 } else { 1 })
        } else {
            $cmp = [string]::Compare($x, $y, [StringComparison]::OrdinalIgnoreCase)
            if ($cmp -ne 0) { return $(if ($cmp -lt 0) { -1 } else { 1 }) }
        }
        $i++
    }
    if ($pa.Pre.Count -eq $pb.Pre.Count) { return 0 }
    return $(if ($pa.Pre.Count -lt $pb.Pre.Count) { -1 } else { 1 })
}

# $null = 版本串为空（无法读取，按未知处理）；$false = 版本可解析但低于最低兼容版本，
# 或版本串无法解析（无法证明达到最低版本）；$true = 版本可解析且 >= minimumCompatibleDshVersion。
# 不再要求“等于某个唯一验证版本”：rc.7/rc.8/rc.1 已测试，未来版本只要不低于最低版本就允许尝试。
function Test-DshVersionSupported([string]$version) {
    if ([string]::IsNullOrWhiteSpace($version)) { return $null }
    $cmp = Compare-DshVersion $version $MinimumCompatibleDshVersion
    if ($null -eq $cmp) { return $false }
    return ($cmp -ge 0)
}

function Test-DshVersionTested([string]$version) {
    if ([string]::IsNullOrWhiteSpace($version)) { return $false }
    return @($TestedDshVersions | Where-Object { $_ -eq $version }).Count -gt 0
}

# 带兼容策略的现有 dsh 解析：
# - 已知版本 >= minimumCompatibleDshVersion → 直接使用（已测试或未测试都允许尝试，不强制回退 npx）
# - 已知版本 <  minimumCompatibleDshVersion → 过旧，安全处理（非交互改用 npx，交互询问是否仍要使用）
# - 读不到版本 / 无法解析 → 无法证明达到最低版本，按未知处理（非交互改用 npx，交互询问）
function Resolve-DshCommandWithGate([string]$existing) {
    $actual = Get-DshVersionFromCommand $existing
    if ([string]::IsNullOrWhiteSpace($actual)) {
        Warn "检测到现有 DSH，但无法读取其版本号（$existing）；DesktopShell 无法确认其不低于最低兼容版本。"
        Warn "DesktopShell 默认 npx 版本：$DefaultDshVersion；最低兼容版本：$MinimumCompatibleDshVersion"
        if ($NonInteractive) {
            Warn "非交互模式：改用 npx @deepseek-ai/dsh@$DefaultDshVersion。"
            return $null
        }
        if (Read-YesNo '是否仍要使用现有 DSH？选否则改用 npx 运行默认版本' $false) {
            return [pscustomobject]@{ Path=$existing; Version=(Normalize-Version $defaultDshVersion); Mode='command'; AcceptedPath=$existing; AcceptedVersion='' }
        }
        return $null
    }

    $cmp = Compare-DshVersion $actual $MinimumCompatibleDshVersion
    if ($null -eq $cmp) {
        Warn "检测到现有 DSH，版本串无法解析（$actual），DesktopShell 无法确认其不低于最低兼容版本。"
        Warn "DesktopShell 默认 npx 版本：$DefaultDshVersion；最低兼容版本：$MinimumCompatibleDshVersion"
        if ($NonInteractive) {
            Warn "非交互模式：改用 npx @deepseek-ai/dsh@$DefaultDshVersion。"
            return $null
        }
        if (Read-YesNo '是否仍要使用现有 DSH？选否则改用 npx 运行默认版本' $false) {
            return [pscustomobject]@{ Path=$existing; Version=$actual; Mode='command'; AcceptedPath=$existing; AcceptedVersion=$actual }
        }
        return $null
    }

    if ($cmp -lt 0) {
        Warn "检测到现有 DSH $actual，低于最低兼容版本 $MinimumCompatibleDshVersion（插件/settings 接口可能不兼容）。"
        if ($NonInteractive) {
            Warn "非交互模式：改用 npx @deepseek-ai/dsh@$DefaultDshVersion。"
            return $null
        }
        if (Read-YesNo "现有 DSH $actual 过旧，是否仍要使用？选否则改用 npx 运行默认版本" $false) {
            return [pscustomobject]@{ Path=$existing; Version=$actual; Mode='command'; AcceptedPath=$existing; AcceptedVersion=$actual }
        }
        return $null
    }

    if (-not (Test-DshVersionTested $actual)) {
        Warn "检测到现有 DSH $actual：未在 testedDshVersions 中，但满足最低兼容版本；DesktopShell 将按实际 CLI 能力尝试运行。"
    } else {
        Ok "检测到现有 DSH，直接使用：$existing  ($actual)"
    }
    return [pscustomobject]@{ Path=$existing; Version=$actual; Mode='command'; AcceptedPath=$existing; AcceptedVersion=$actual }
}

function Remove-LegacyPrivateRuntime {
    $pkg = Join-Path $legacyRuntimeDir 'package.json'
    if (-not (Test-Path -LiteralPath $pkg -PathType Leaf)) { return }
    try {
        $j = Get-Content -LiteralPath $pkg -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($j.name -eq 'deepseek-harness-desktop-runtime') {
            Say '清理旧草案曾创建的 ~/.dsh/runtime 私有运行时；现版本不再使用这里。'
            Remove-Item -LiteralPath $legacyRuntimeDir -Recurse -Force
            Ok '旧私有 runtime 已移除。'
        }
    } catch { Warn "旧私有 runtime 清理失败：$($_.Exception.Message)" }
}

function Get-SettingsObject {
    if (Test-Path -LiteralPath $settingsPath) {
        try { return (Get-Content -LiteralPath $settingsPath -Raw -Encoding UTF8 | ConvertFrom-Json) } catch {}
    }
    return [pscustomobject]@{}
}

function Set-Property($obj, [string]$name, $value) {
    if ($obj.PSObject.Properties.Name -contains $name) { $obj.$name = $value }
    else { $obj | Add-Member -NotePropertyName $name -NotePropertyValue $value }
}

# DSH 运行方式：command=只用现有 dsh；npx=只用官方 npx；auto=有 dsh 用 dsh，否则 npx。
# 持久化到 settings.json 的 dshRunnerMode，C# 端同样严格遵守——
# 否则“选择 npx”只会把 dshPath 写空，下次解析又会把 PATH 里的旧 dsh 捡回来。
function Resolve-RunnerMode([string]$value) {
    if ($value -in @('command', 'npx', 'auto')) { return $value }
    return 'auto'
}

function Save-DesktopSettings([string]$dshPath, [string]$version, [string]$profile, [int]$webPort, [string]$workDir,
    [string]$closeAction, [bool]$developerMode, [string]$runnerMode,
    [string]$acceptedDshCommandPath = '', [string]$acceptedDshCommandVersion = '') {
    New-Item -ItemType Directory -Force -Path $desktopDir | Out-Null
    $obj = Get-SettingsObject
    Set-Property $obj 'dshPath' $(if ($dshPath) { $dshPath } else { '' })
    Set-Property $obj 'dshVersion' (Normalize-Version $version)
    Set-Property $obj 'dshRunnerMode' (Resolve-RunnerMode $runnerMode)
    Set-Property $obj 'acceptedDshCommandPath' $(if ($acceptedDshCommandPath) { $acceptedDshCommandPath } else { '' })
    Set-Property $obj 'acceptedDshCommandVersion' $(if ($acceptedDshCommandVersion) { $acceptedDshCommandVersion } else { '' })
    Set-Property $obj 'profileName' (Normalize-Profile $profile)
    Set-Property $obj 'port' $webPort
    Set-Property $obj 'workingDirectory' $workDir
    Set-Property $obj 'closeAction' $closeAction
    Set-Property $obj 'developerMode' $developerMode
    if (-not ($obj.PSObject.Properties.Name -contains 'restoreWindowBounds')) { Set-Property $obj 'restoreWindowBounds' $true }
    if (-not ($obj.PSObject.Properties.Name -contains 'hasSavedWindowBounds')) { Set-Property $obj 'hasSavedWindowBounds' $false }
    if (-not ($obj.PSObject.Properties.Name -contains 'windowX')) { Set-Property $obj 'windowX' 0 }
    if (-not ($obj.PSObject.Properties.Name -contains 'windowY')) { Set-Property $obj 'windowY' 0 }
    if (-not ($obj.PSObject.Properties.Name -contains 'windowWidth')) { Set-Property $obj 'windowWidth' 1440 }
    if (-not ($obj.PSObject.Properties.Name -contains 'windowHeight')) { Set-Property $obj 'windowHeight' 900 }
    if (-not ($obj.PSObject.Properties.Name -contains 'windowMaximized')) { Set-Property $obj 'windowMaximized' $false }

    $tmp = "$settingsPath.tmp-$PID"
    Write-Utf8NoBom $tmp (($obj | ConvertTo-Json -Depth 20))
    Move-Item -LiteralPath $tmp -Destination $settingsPath -Force
    Ok "桌面设置已写入：$settingsPath"
}

function Get-CurrentSettings {
    $obj = Get-SettingsObject
    $mode = Resolve-RunnerMode ([string]$obj.dshRunnerMode)

    $savedPath = $null
    if ($mode -eq 'npx') {
        # 用户明确选择 npx：绝不回捡 PATH 里的 dsh
        $savedPath = $null
    } else {
        if ($obj.dshPath -and (Test-Path -LiteralPath ([string]$obj.dshPath) -PathType Leaf) -and
            -not ([IO.Path]::GetFullPath([string]$obj.dshPath)).StartsWith([IO.Path]::GetFullPath($legacyRuntimeDir), [StringComparison]::OrdinalIgnoreCase)) {
            $savedPath = [string]$obj.dshPath
        }
        if (-not $savedPath) { $savedPath = Get-DshCommand }
    }

    $actualVersion = if ($savedPath) { Get-DshVersionFromCommand $savedPath } else { $null }
    $version = if ($actualVersion) { $actualVersion } elseif ($DshVersion) { Normalize-Version $DshVersion } elseif ($obj.dshVersion) { Normalize-Version ([string]$obj.dshVersion) } else { $defaultDshVersion }
    $profile = if ($ProfileName) { Normalize-Profile $ProfileName } elseif ($obj.profileName) { Normalize-Profile ([string]$obj.profileName) } else { 'web' }
    $webPort = if ($Port -gt 0) { $Port } elseif ($obj.port -ge 1 -and $obj.port -le 65535) { [int]$obj.port } else { 3080 }
    $work = if ($WorkingDirectory) { $WorkingDirectory } elseif ($obj.workingDirectory) { [string]$obj.workingDirectory } else { $homeDir }
    $close = if ($obj.closeAction -in @('ask','tray','exit')) { [string]$obj.closeAction } else { 'ask' }
    $dev = [bool]$obj.developerMode

    return [pscustomobject]@{
        DshPath=$savedPath
        Version=$version
        RunnerMode=$mode
        AcceptedDshPath=([string]$obj.acceptedDshCommandPath)
        AcceptedDshVersion=([string]$obj.acceptedDshCommandVersion)
        Profile=$profile
        Port=$webPort
        Work=$work
        Close=$close
        Dev=$dev
    }
}

function Update-AllowBuilds([string]$profile, [string[]]$packages) {
    if (-not $packages -or $packages.Count -eq 0) { return }
    $profileDir = Join-Path $dshHome "profiles\$profile"
    New-Item -ItemType Directory -Force -Path $profileDir | Out-Null
    $yaml = Join-Path $profileDir 'pnpm-workspace.yaml'
    $lines = [System.Collections.Generic.List[string]]::new()
    if (Test-Path -LiteralPath $yaml) {
        foreach ($line in Get-Content -LiteralPath $yaml -Encoding UTF8) { [void]$lines.Add([string]$line) }
    }

    $allowIndex = -1
    for ($i=0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match '^\s*allowBuilds\s*:\s*$') { $allowIndex = $i; break }
    }
    if ($allowIndex -lt 0) {
        if ($lines.Count -gt 0 -and $lines[$lines.Count-1].Trim()) { $lines.Add('') }
        $lines.Add('allowBuilds:')
        $allowIndex = $lines.Count - 1
    }

    foreach ($pkg in $packages | Sort-Object -Unique) {
        $pattern = '^\s+' + [regex]::Escape($pkg) + '\s*:\s*true\s*$'
        if (-not ($lines | Where-Object { $_ -match $pattern })) {
            $insertAt = $allowIndex + 1
            while ($insertAt -lt $lines.Count -and ($lines[$insertAt] -match '^\s+' -or -not $lines[$insertAt].Trim())) { $insertAt++ }
            $lines.Insert($insertAt, "  ${pkg}: true")
        }
    }
    [System.IO.File]::WriteAllLines($yaml, $lines, [System.Text.UTF8Encoding]::new($false))
    Ok "已更新 build allowlist：$yaml"
}

# 与 C# 端 EnsureStarted 完全一致的 runnerMode 决策：
#   npx      -> 永远返回 $null（用 npx），即使 PATH 里有 dsh
#   command  -> 只用现有 dsh，找不到直接 Fail（绝不悄悄转 npx）
#   auto     -> 有 dsh 用 dsh，否则 $null（用 npx）
function Resolve-DshCommandForOps([string]$runnerMode, [string]$savedPath) {
    $mode = Resolve-RunnerMode $runnerMode
    if ($mode -eq 'npx') { return $null }
    $cmd = $savedPath
    if ($cmd -and -not (Test-Path -LiteralPath $cmd -PathType Leaf)) { $cmd = $null }
    if (-not $cmd) { $cmd = Get-DshCommand }
    if (-not $cmd -and $mode -eq 'command') {
        Fail '设置要求使用现有 dsh（dshRunnerMode=command），但 PATH 中没有 dsh 命令。请安装官方 DSH，或在管理器中改用“自动/仅 npx”。'
    }
    return $cmd
}

# 与 C# ConfirmCommandVersionBeforeStart 完全一致的重验证判定（单一规则，双端同语义）：
# 只要最终解析结果是「使用现有 dsh」：
#   acceptedPath 为空 / acceptedVersion 为空 / actualPath 为空 /
#   acceptedPath != actualPath（accepted 非空时）/ actualVersion 为空 /
#   actualVersion != acceptedVersion  → 需要重新验证
function Test-DshNeedsReacceptance([string]$acceptedPath, [string]$acceptedVersion,
    [string]$actualPath, [string]$actualVersion) {
    if ([string]::IsNullOrWhiteSpace($acceptedPath)) { return $true }
    if ([string]::IsNullOrWhiteSpace($acceptedVersion)) { return $true }
    if ([string]::IsNullOrWhiteSpace($actualPath)) { return $true }
    if (-not [string]::Equals($acceptedPath, $actualPath, [System.StringComparison]::OrdinalIgnoreCase)) { return $true }
    if ([string]::IsNullOrWhiteSpace($actualVersion)) { return $true }
    if ($actualVersion -ne $acceptedVersion) { return $true }
    return $false
}

function Invoke-ManagedDsh([string]$profile, [string[]]$arguments) {
    $current = Get-CurrentSettings
    Ensure-Node
    $pnpmVersion = Get-ProfilePnpmVersion $profile
    $npx = Get-Npx

    $dshCommand = Resolve-DshCommandForOps $current.RunnerMode $current.DshPath

    # 运行时版本重新验证（与 C# 启动前完全一致，command/auto 都执行——只要最终解析
    # 结果是「使用现有 dsh」）：每次插件操作前重新读取 dsh --version，与上次 accepted
    # 记录比对（路径或版本任一变化/无法读取 → 需要重新确认）。满足最低兼容版本的新版本
    # 自动接受并写入 accepted，不打扰用户；其它变化交互询问，非交互模式直接中止。
    if ($dshCommand) {
        $actualVer = Get-DshVersionFromCommand $dshCommand
        if (Test-DshNeedsReacceptance $current.AcceptedDshPath $current.AcceptedDshVersion $dshCommand $actualVer) {
            if (-not [string]::IsNullOrWhiteSpace($actualVer) -and (Test-DshVersionSupported $actualVer)) {
                $obj = Get-SettingsObject
                Set-Property $obj 'acceptedDshCommandPath' $dshCommand
                Set-Property $obj 'acceptedDshCommandVersion' $actualVer
                Write-Utf8NoBom $settingsPath (($obj | ConvertTo-Json -Depth 20))
                Ok "已记住现有 DSH 版本：$actualVer"
            } else {
                $verDesc = if ($actualVer) { "已从 $($current.AcceptedDshVersion) 变为 $actualVer" } else { "已无法读取（上次记录 $($current.AcceptedDshVersion)）" }
                if ($NonInteractive) {
                    Fail "现有 DSH 版本 $verDesc，未获重新确认；请在管理器中重新确认后继续插件操作。"
                }
                if (-not (Read-YesNo "现有 DSH 版本 $verDesc，是否继续使用并记住新版本？" $false)) {
                    Fail '已取消插件操作：请先在管理器中重新确认 DSH。'
                }
                $obj = Get-SettingsObject
                Set-Property $obj 'acceptedDshCommandPath' $dshCommand
                Set-Property $obj 'acceptedDshCommandVersion' $(if ($actualVer) { $actualVer } else { '' })
                Write-Utf8NoBom $settingsPath (($obj | ConvertTo-Json -Depth 20))
                Ok "已记住现有 DSH 版本：$(if ($actualVer) { $actualVer } else { '（无法读取）' })"
            }
        }
    }

    $shimDir = Join-Path $env:TEMP ('dsh-desktop-pnpm-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Force -Path $shimDir | Out-Null
    $shim = Join-Path $shimDir 'pnpm.cmd'
    [IO.File]::WriteAllText($shim, "@echo off`r`nnpx --yes --package=pnpm@$pnpmVersion pnpm %*`r`n", [Text.Encoding]::ASCII)

    $oldPath = $env:Path
    $oldGitCount = $env:GIT_CONFIG_COUNT
    $oldGitKey0 = $env:GIT_CONFIG_KEY_0; $oldGitValue0 = $env:GIT_CONFIG_VALUE_0
    $oldGitKey1 = $env:GIT_CONFIG_KEY_1; $oldGitValue1 = $env:GIT_CONFIG_VALUE_1
    $oldGitKey2 = $env:GIT_CONFIG_KEY_2; $oldGitValue2 = $env:GIT_CONFIG_VALUE_2
    try {
        $runnerDir = if ($dshCommand) { Split-Path -Parent $dshCommand } else { Split-Path -Parent $npx }
        $env:Path = "$shimDir;$runnerDir;$oldPath"
        $env:GIT_CONFIG_COUNT = '3'
        $env:GIT_CONFIG_KEY_0 = 'url.https://github.com/.insteadOf'
        $env:GIT_CONFIG_VALUE_0 = 'git+ssh://git@github.com/'
        $env:GIT_CONFIG_KEY_1 = 'url.https://github.com/.insteadOf'
        $env:GIT_CONFIG_VALUE_1 = 'ssh://git@github.com/'
        $env:GIT_CONFIG_KEY_2 = 'url.https://github.com/.insteadOf'
        $env:GIT_CONFIG_VALUE_2 = 'git@github.com:'

        if ($dshCommand) {
            Say "插件操作：现有 DSH $dshCommand；Profile pnpm@$pnpmVersion"
            & $dshCommand @arguments | Out-Host
        } else {
            Say "插件操作：npx @deepseek-ai/dsh@$($current.Version)；Profile pnpm@$pnpmVersion"
            & $npx -y "@deepseek-ai/dsh@$($current.Version)" @arguments | Out-Host
        }
        return $LASTEXITCODE
    } finally {
        $env:Path = $oldPath
        $env:GIT_CONFIG_COUNT = $oldGitCount
        $env:GIT_CONFIG_KEY_0 = $oldGitKey0; $env:GIT_CONFIG_VALUE_0 = $oldGitValue0
        $env:GIT_CONFIG_KEY_1 = $oldGitKey1; $env:GIT_CONFIG_VALUE_1 = $oldGitValue1
        $env:GIT_CONFIG_KEY_2 = $oldGitKey2; $env:GIT_CONFIG_VALUE_2 = $oldGitValue2
        Remove-Item -LiteralPath $shimDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Show-PluginCatalog {
    Write-Host ''
    foreach ($p in $PluginCatalog) {
        $tag = switch ($p.Tier) { 'core' { '核心推荐' } 'enhanced' { '体验增强' } default { '高级/实验' } }
        Write-Host ('{0,2}. {1,-28} [{2}]' -f $p.No, $p.Name, $tag)
        if ($p.Installed) { Write-Host ('      本机快照：{0}' -f $p.Installed) -ForegroundColor DarkGray }
        if ($p.Note) { Write-Host ('      备注：{0}' -f $p.Note) -ForegroundColor DarkGray }
    }
    Write-Host ''
    Write-Host '内置推荐采用选择性 pin：已确认兼容的新版用 range/release tag，未验证或兼容依赖保持已审核版本。' -ForegroundColor DarkGray
    Write-Host '需要追新版本可在“额外插件”步骤粘贴自定义 spec。' -ForegroundColor DarkGray
}

function Select-Plugins([bool]$existingProfile) {
    if ($NonInteractive) { return @() }

    Write-Host ''
    if ($existingProfile) {
        Write-Host '检测到已有 Profile。默认不会重装现有插件。'
        Write-Host '  0. 保留现有插件，不做变更（推荐）'
    } else {
        # 默认 0：纯 DSH，不自动执行第三方代码；核心推荐标为推荐但需主动选择
        Write-Host '  0. 纯 DSH，不安装社区插件（推荐）'
    }
    $coreCount = @($PluginCatalog | Where-Object { $_.Tier -eq 'core' }).Count
    $nonAdvancedCount = @($PluginCatalog | Where-Object { $_.Tier -ne 'advanced' }).Count
    $allCount = @($PluginCatalog).Count
    Write-Host ("  1. 核心推荐（{0} 个：插件市场 / 工作台 / Skills / @file / Rewind）" -f $coreCount)
    Write-Host ("  2. 核心推荐 + 体验增强（{0} 个）" -f $nonAdvancedCount)
    Write-Host ("  3. 全部已审核插件（{0} 个，选择性 pin）" -f $allCount)
    Write-Host '  4. 自定义选择'
    $choice = Read-Default '插件安装方案' '0'
    if ($choice -eq '0') { return @() }
    if ($choice -eq '1') { return @($PluginCatalog | Where-Object { $_.Tier -eq 'core' }) }
    if ($choice -eq '2') { return @($PluginCatalog | Where-Object { $_.Tier -ne 'advanced' }) }
    if ($choice -eq '3') { return @($PluginCatalog) }

    Show-PluginCatalog
    $raw = Read-Host '输入编号，逗号分隔（例如 1,2,10,13；留空=不装）'
    if ([string]::IsNullOrWhiteSpace($raw)) { return @() }
    $numbers = @($raw -split '[,，\s]+' | Where-Object { $_ -match '^\d+$' } | ForEach-Object { [int]$_ })
    return @($PluginCatalog | Where-Object { $_.No -in $numbers })
}

function Configure-BetterSidebar {
    if (-not (Get-Command pwsh.exe -ErrorAction SilentlyContinue)) { return }
    if (Read-YesNo 'Better Sidebar：固定使用 PowerShell 7 (pwsh.exe)？' $true) {
        [Environment]::SetEnvironmentVariable('DSH_SIDEBAR_SHELL','pwsh.exe','User')
        $env:DSH_SIDEBAR_SHELL = 'pwsh.exe'
        Ok '已设置用户环境变量 DSH_SIDEBAR_SHELL=pwsh.exe。'
    }
}

# Dream Skin 持久化修复检测：上游修复版与旧 npm 0.3.0 的 package.json 版本号完全相同
# （都是 0.3.0），单看版本号分不出来——必须检查源码里的两个能力 marker：
#   'dsh-dream-skin: sticky skin restore'  （sticky restore 加固）
#   '/dream-skin/api'                       （host-backed 持久化接口）
# 两个都存在才算“已修”，缺任意一个都按旧实现处理。
function Test-DreamSkinPersistenceFix([string]$profile) {
    $client = Join-Path $dshHome ("profiles\{0}\node_modules\dsh-dream-skin\lib\client.js" -f $profile)
    if (-not (Test-Path -LiteralPath $client -PathType Leaf)) { return $false }
    try {
        $text = Get-Content -LiteralPath $client -Raw -Encoding UTF8
        return ($text.Contains('dsh-dream-skin: sticky skin restore') -and $text.Contains('/dream-skin/api'))
    } catch { return $false }
}

function Install-Plugins([string]$profile, [object[]]$selected) {
    if (-not $selected -or $selected.Count -eq 0) { return }

    # Dream Skin 非破坏升级：Profile 里已是旧实现（无持久化修复 marker）时，
    # 先说明再确认；确认后按目录里的 npm ^0.4.5 安装（同名包会替换旧实现）。
    # 绝不删 webview2-data / ~/.dsh / Profile，也不手工改 DSH 官方 ThemeRuntime。
    $dreamSkin = @($selected | Where-Object { $_.Id -eq 'dream-skin' } | Select-Object -First 1)
    if ($dreamSkin -and -not (Test-DreamSkinPersistenceFix $profile)) {
        $dreamSpec = [string]$dreamSkin.Spec
        if ($NonInteractive) {
            Warn 'Dream Skin：Profile 中检测到旧 0.3.0 实现（无持久化修复 marker），将替换为 npm ^0.4.5（含持久化修复）。'
        } elseif (Read-YesNo '检测到 Dream Skin 0.3.0 旧实现，存在重启后第三方皮肤回退问题。是否升级到 npm ^0.4.5（含持久化修复）？' $true) {
            Ok '确认升级 Dream Skin 到 npm ^0.4.5。'
        } else {
            $selected = @($selected | Where-Object { $_.Id -ne 'dream-skin' })
            Warn '已跳过 Dream Skin 升级。'
        }
        if ($selected.Id -contains 'dream-skin') {
            Say "Dream Skin 安装源：$dreamSpec"
        }
    }

    $allow = @($selected | ForEach-Object { $_.Allow } | Where-Object { $_ })
    Update-AllowBuilds $profile $allow

    $failures = @()
    foreach ($plugin in $selected) {
        Say "安装插件：$($plugin.Name)"
        $code = Invoke-ManagedDsh $profile @('plugin','--profile',$profile,'add',$plugin.Spec)
        if ($code -ne 0) {
            Warn "安装失败：$($plugin.Name)（退出码 $code）"
            $failures += $plugin.Name
        } else { Ok "已安装：$($plugin.Name)（仅安装成功，尚未证明运行兼容）" }
    }

    if ($selected.Id -contains 'sidebar') { Configure-BetterSidebar }
    if (-not $NonInteractive) {
        $extra = Read-Host '还要安装额外插件吗？可直接粘贴 package/spec，多个用分号分隔；留空跳过'
        foreach ($spec in @($extra -split ';' | ForEach-Object { $_.Trim() } | Where-Object { $_ })) {
            Say "安装额外插件：$spec"
            $code = Invoke-ManagedDsh $profile @('plugin','--profile',$profile,'add',$spec)
            if ($code -ne 0) { $failures += $spec }
            else { Ok "已安装：$spec（仅安装成功，尚未证明运行兼容）" }
        }
    }

    if ($failures.Count -gt 0) {
        Warn ('以下插件安装失败，但不影响其他插件：' + ($failures -join '；'))
    }

    if ($selected.Count -gt 0) {
        if ($failures.Count -gt 0) {
            Warn '存在安装失败项；安装成功不等于运行兼容。'
        }
        Warn '日常插件安装只确认 package 安装成功，不启动用户真实 Profile，也不标记运行兼容 PASS。完整 BootReady 验收请使用独立 release preflight（临时 DSH_HOME/Profile/随机端口）。'
        Write-Host ''
        Say '插件安装/更新完成。新插件与更新默认在 DSH 后端重启后生效：托盘图标 → 重启 DSH 后端。'
    }
}

function Show-Diagnostics([string]$profile) {
    Title '诊断'
    $node = Get-NodeVersion
    $current = Get-CurrentSettings
    Write-Host "DSH_HOME: $dshHome"
    Write-Host "Node.js:  $node"
    Write-Host "DSH:      $(if ($current.DshPath) {$current.DshPath} else {"npx @deepseek-ai/dsh@$($current.Version)"})"
    Write-Host "版本:     $($current.Version)"
    Write-Host "Profile:  $profile"
    $profileDir = Join-Path $dshHome "profiles\$profile"
    Write-Host "Profile 目录: $(if (Test-Path $profileDir) {'存在'} else {'尚未创建'})"
    try {
        $code = Invoke-ManagedDsh $profile @('plugin','--profile',$profile,'list')
        if ($code -ne 0) { Warn 'plugin list 返回非 0。' }
    } catch { Warn $_.Exception.Message }

    # Dream Skin 持久化修复状态：版本号分不出新旧（都是 0.3.0），必须查能力 marker
    $dreamSkinDir = Join-Path $dshHome "profiles\$profile\node_modules\dsh-dream-skin"
    if (Test-Path -LiteralPath $dreamSkinDir -PathType Container) {
        if (Test-DreamSkinPersistenceFix $profile) {
            Ok 'Dream Skin：持久化修复已安装'
        } else {
            Warn 'Dream Skin：检测到旧 0.3.0 实现，建议升级（管理器重装 Dream Skin 插件即可替换为 npm ^0.4.5）'
        }
    }
}

function Guided-Setup {
    # 版本单一来源：安装目录 version.txt（构建/安装流程写入，与根目录 VERSION 一致）
    $shellVersion = '1.0.0'
    $verFile = Join-Path $desktopDir 'version.txt'
    if (Test-Path -LiteralPath $verFile -PathType Leaf) {
        $raw = (Get-Content -LiteralPath $verFile -Raw -ErrorAction SilentlyContinue).Trim()
        if ($raw) { $shellVersion = $raw }
    }
    Title "DeepSeek Harness DesktopShell v$shellVersion 初始化"
    Write-Host 'DSH 启动策略：'
    Write-Host '  • 系统已有 dsh 命令 -> 直接使用，不重装、不移动'
    Write-Host '  • 现有 dsh 低于最低兼容版本或无法解析 -> 安全处理；满足最低版本即允许按 CLI 能力尝试'
    Write-Host '  • 没有 dsh 命令      -> 使用官方 npx @deepseek-ai/dsh web 方式'
    Write-Host '  • npx 只按需下载到 npm 缓存，不执行 npm install -g'
    Write-Host '  • ~/.dsh 只作为 DSH 用户数据/Profile/会话目录，DesktopShell 不安装在其中'
    Write-Host ''

    Ensure-Node
    $current = Get-CurrentSettings
    $existing = Get-DshCommand

    if ($existing) {
        $gated = Resolve-DshCommandWithGate $existing
        if ($gated) {
            $resolved = $gated
            Ok "使用现有 DSH：$($resolved.Path)$(if ($resolved.Version) { "  ($($resolved.Version))" } else { '' })"
        } else {
            $version = Read-Default 'npx 使用的 DSH 版本' $current.Version
            $resolved = Prepare-NpxDsh $version
        }
    } else {
        $version = Read-Default 'npx 使用的 DSH 版本' $current.Version
        $resolved = Prepare-NpxDsh $version
    }

    Remove-LegacyPrivateRuntime

    $profile = Normalize-Profile (Read-Default 'Profile 名称' $current.Profile)
    $webPortText = Read-Default 'Web 端口' ([string]$current.Port)
    $webPort = 3080
    if (-not [int]::TryParse($webPortText, [ref]$webPort) -or $webPort -lt 1 -or $webPort -gt 65535) { $webPort = 3080 }
    $work = Read-Default '默认工作目录' $current.Work
    if (-not (Test-Path -LiteralPath $work -PathType Container)) {
        if (Read-YesNo "目录不存在，是否创建 $work？" $true) { New-Item -ItemType Directory -Force $work | Out-Null }
        else { $work = $homeDir }
    }

    $close = $current.Close
    if (-not $NonInteractive) {
        Write-Host '关闭窗口行为：1=每次询问  2=关闭到托盘  3=关闭并退出'
        $closeDefault = if ($close -eq 'tray') { '2' } elseif ($close -eq 'exit') { '3' } else { '1' }
        $closeChoice = Read-Default '选择' $closeDefault
        $close = if ($closeChoice -eq '2') {'tray'} elseif ($closeChoice -eq '3') {'exit'} else {'ask'}
    }
    $dev = if ($NonInteractive) { $current.Dev } else { Read-YesNo '启用 WebView2 开发者模式（DevTools）？' $current.Dev }

    # command 模式记录 accepted 版本（后续每次启动/插件操作重新验证以此为准）
    $acceptedPath = if ($resolved.Mode -eq 'command') { [string]$resolved.AcceptedPath } else { '' }
    $acceptedVer = if ($resolved.Mode -eq 'command') { [string]$resolved.AcceptedVersion } else { '' }
    Save-DesktopSettings $resolved.Path $resolved.Version $profile $webPort $work $close $dev $resolved.Mode $acceptedPath $acceptedVer

    $profilePackage = Join-Path $dshHome "profiles\$profile\package.json"
    $profileExisted = Test-Path -LiteralPath $profilePackage -PathType Leaf
    if (-not $profileExisted) {
        Say "初始化 DSH Profile：$profile"
        try {
            $code = Invoke-ManagedDsh $profile @('plugin','--profile',$profile,'list')
            if ($code -eq 0) { Ok "DSH Profile 已准备：$profile" }
            else { Warn "Profile 初始化命令返回 $code；首次启动 DSH 时仍会继续初始化。" }
        } catch {
            Warn "Profile 预初始化未完成：$($_.Exception.Message)"
            Warn '这不会阻止 DesktopShell 安装；首次启动 DSH 时仍会继续初始化。'
        }
    }

    $selected = Select-Plugins $profileExisted
    if ($selected.Count -gt 0 -and (Test-PortOpen $webPort)) {
        Warn "127.0.0.1:$webPort 当前仍有服务监听。安装/更新插件时最好先停止 DSH 后端。"
        if (-not (Read-YesNo '仍然继续插件安装？' $false)) { $selected = @() }
    }
    Install-Plugins $profile $selected

    Write-Host ''
    Ok '初始化完成。'
    if ($resolved.Path) { Write-Host "DSH：现有命令 $($resolved.Path)" }
    else { Write-Host "DSH：npx @deepseek-ai/dsh@$($resolved.Version)" }
    Write-Host "Profile：$profile"
    Write-Host "Web： http://127.0.0.1:$webPort"
}

function Interactive-Menu {
    while ($true) {
        $current = Get-CurrentSettings
        Title 'DeepSeek Harness DesktopShell 管理'
        Write-Host "运行方式: $(if ($current.DshPath) { '现有 dsh 命令' } else { 'npx' })"
        Write-Host "DSH:      $(if ($current.DshPath) { $current.DshPath } else { "@deepseek-ai/dsh@$($current.Version)" })"
        Write-Host "Profile:  $($current.Profile)    Port: $($current.Port)"
        Write-Host ''
        Write-Host '  1. 检查 DSH / 设置 npx 版本'
        Write-Host '  2. 修改桌面与 DSH 启动配置'
        Write-Host '  3. 安装插件'
        Write-Host '  4. 查看插件列表 / 诊断'
        Write-Host '  5. 安装自定义 package/spec'
        Write-Host '  0. 退出'
        $choice = Read-Default '选择' '0'
        switch ($choice) {
            '1' {
                Ensure-Node
                $found = Get-DshCommand
                if ($found) {
                    $gated = Resolve-DshCommandWithGate $found
                    if ($gated) {
                        Ok "使用现有 DSH：$($gated.Path)  ($($gated.Version))"
                        Write-Host 'DesktopShell 按规则直接使用它，不会自动更新、覆盖或卸载。'
                        Save-DesktopSettings $gated.Path $gated.Version $current.Profile $current.Port $current.Work $current.Close $current.Dev $gated.Mode $gated.AcceptedPath $gated.AcceptedVersion
                    } else {
                        Write-Host '改用官方 npx 运行方式（已持久化为仅 npx，不会再回捡 PATH 里的 dsh）。'
                        $v = Read-Default 'npx 使用的 DSH 版本' $current.Version
                        $resolved = Prepare-NpxDsh $v
                        Save-DesktopSettings $null $resolved.Version $current.Profile $current.Port $current.Work $current.Close $current.Dev 'npx' '' ''
                    }
                } else {
                    Write-Host '系统 PATH 中没有 dsh；DesktopShell 使用官方 npx 运行方式。'
                    $v = Read-Default 'npx 使用的 DSH 版本' $current.Version
                    $resolved = Prepare-NpxDsh $v
                    Save-DesktopSettings $null $resolved.Version $current.Profile $current.Port $current.Work $current.Close $current.Dev 'npx' '' ''
                }
            }
            '2' {
                $profile = Normalize-Profile (Read-Default 'Profile 名称' $current.Profile)
                $portText = Read-Default 'Web 端口' ([string]$current.Port)
                $p = $current.Port
                if (-not ([int]::TryParse($portText,[ref]$p) -and $p -ge 1 -and $p -le 65535)) { $p=3080 }
                $work = Read-Default '默认工作目录' $current.Work
                Write-Host 'DSH 运行方式：1=自动（有 dsh 用 dsh，否则 npx）  2=仅现有 dsh  3=仅 npx'
                $rmDefault = if ($current.RunnerMode -eq 'command') { '2' } elseif ($current.RunnerMode -eq 'npx') { '3' } else { '1' }
                $rm = Read-Default '选择' $rmDefault
                $runnerMode = if ($rm -eq '2') { 'command' } elseif ($rm -eq '3') { 'npx' } else { 'auto' }
                Write-Host '关闭窗口行为：1=每次询问  2=关闭到托盘  3=关闭并退出'
                $closeDefault = if ($current.Close -eq 'tray') { '2' } elseif ($current.Close -eq 'exit') { '3' } else { '1' }
                $cc = Read-Default '选择' $closeDefault
                $close = if ($cc -eq '2') {'tray'} elseif ($cc -eq '3') {'exit'} else {'ask'}
                $dev = Read-YesNo '启用 WebView2 开发者模式（DevTools）？' $current.Dev
                $savePath = if ($runnerMode -eq 'npx') { $null } else { $current.DshPath }
                # 切到 npx 时清空 accepted 记录；command/auto 保留已有 accepted
                $acceptedPath = if ($runnerMode -eq 'npx') { '' } else { $current.AcceptedDshPath }
                $acceptedVer = if ($runnerMode -eq 'npx') { '' } else { $current.AcceptedDshVersion }
                Save-DesktopSettings $savePath $current.Version $profile $p $work $close $dev $runnerMode $acceptedPath $acceptedVer
            }
            '3' {
                $profilePackage = Join-Path $dshHome "profiles\$($current.Profile)\package.json"
                $selected = Select-Plugins (Test-Path -LiteralPath $profilePackage)
                Install-Plugins $current.Profile $selected
            }
            '4' { Show-Diagnostics $current.Profile }
            '5' {
                # 自定义 spec 独立入口：不要求先选内置插件（“额外插件”提示只在选中内置项后出现）
                $raw = Read-Host '粘贴自定义 package/spec（多个用分号分隔；例如 pkg@1.2.3 或 GitHub tar 链接）'
                $specs = @($raw -split ';' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
                if ($specs.Count -eq 0) { Warn '未输入任何 spec。'; break }
                foreach ($s in $specs) {
                    Say "安装自定义插件：$s"
                    $code = Invoke-ManagedDsh $current.Profile @('plugin','--profile',$current.Profile,'add',$s)
                    if ($code -ne 0) { Warn "安装失败：$s（退出码 $code）" }
                    else { Ok "已安装：$s（仅安装成功，尚未证明运行兼容）" }
                }
                Warn '安装成功 ≠ 运行兼容：日常安装不会启动用户真实 Profile。完整 BootReady 验收请使用独立 release preflight（临时 DSH_HOME/Profile/随机端口）。'
                Say '插件安装/更新完成。新插件与更新默认在 DSH 后端重启后生效：托盘图标 → 重启 DSH 后端。'
            }
            '0' { return }
            default { Warn '无效选择。' }
        }
        if ($choice -ne '0') { Write-Host ''; Read-Host '按 Enter 继续' | Out-Null }
    }
}

try {
    if ($FirstInstall) { Guided-Setup }
    else { Interactive-Menu }
    exit 0
} catch {
    Write-Host ''
    Write-Host "失败：$($_.Exception.Message)" -ForegroundColor Red
    if (-not $NonInteractive) { Write-Host ''; Read-Host '按 Enter 退出' | Out-Null }
    exit 1
}
