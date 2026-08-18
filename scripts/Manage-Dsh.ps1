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
$defaultDshVersion = '0.1.0-rc.7'
$MinSupportedDshVersion = '0.1.0-rc.7'
$defaultProfilePnpmVersion = '10.33.2'

# 插件目录。分层与可复现性规则（2026-08-19 第二轮审计后）：
#   - Tier='core'      核心推荐（新 Profile 默认勾选）：插件发现/工作台/Skills/@file/历史重跑
#   - Tier='enhanced'  体验增强（默认展示但可取消）：UI 与操作效率，不装不影响 DSH 核心
#   - Tier='advanced'  高级/实验（默认不装）：会改变 Agent 行为或涉及估算/兼容修复
#   - 所有内置目录一律锁定精确 npm 版本或 GitHub commit（可复现），不追 latest/main；
#     需要追新的用户可在“额外插件”步骤粘贴自定义 spec。
# 锁定版本升级须经过人工审核：先验证新版本与 PluginCompat 兼容修复、再更新此处。
$PluginCatalog = @(
    # ---- 核心推荐 ----
    [pscustomobject]@{ No=1;  Id='market';        Name='插件市场';                  Spec='dshmarket@1.14.0'; Tier='core'; Allow=@() },
    [pscustomobject]@{ No=2;  Id='sidebar';       Name='Better Sidebar 工作台';     Spec='dsh-better-sidebar@0.13.1'; Tier='core'; Allow=@('node-pty') },
    [pscustomobject]@{ No=3;  Id='skills';        Name='Skills Manager';            Spec='@michengai/dsh-skills-manager@0.1.23'; Tier='core'; Allow=@() },
    [pscustomobject]@{ No=4;  Id='at-file';       Name='@file 文件引用';            Spec='https://github.com/omdsh-dev/dsh-at-file/archive/898369ece56ae6ec41afd8e014f187bb5b723409.tar.gz'; Tier='core'; Allow=@() },
    [pscustomobject]@{ No=5;  Id='rewind';        Name='历史消息回退/重跑';         Spec='https://github.com/XSJUSTC/dsh-rewind/archive/6dcfcc9c4bf388519eb51a6ca312a140b8552154.tar.gz'; Tier='core'; Allow=@() },
    # ---- 体验增强 ----
    [pscustomobject]@{ No=6;  Id='file-mentions'; Name='文件路径点击/提及';         Spec='https://github.com/a903067276-rgb/dsh-file-mentions/archive/a303b81a32a890be02bc57fabd1e28583040ac12.tar.gz'; Tier='enhanced'; Allow=@() },
    [pscustomobject]@{ No=7;  Id='collapse';      Name='Tool/Think 自动折叠';       Spec='https://github.com/a179-sanae/dsh-auto-collapse/archive/9d02fb02e8dd2fb56c5e82fcc5d68b5a5b62efcd.tar.gz'; Tier='enhanced'; Allow=@() },
    [pscustomobject]@{ No=8;  Id='tidy';          Name='Codex 风格对话排版';        Spec='dsh-chat-tidy@0.2.0'; Tier='enhanced'; Allow=@() },
    [pscustomobject]@{ No=9;  Id='outline';       Name='对话侧边大纲';              Spec='https://github.com/EnkiduGilgamesh/dsh-codex-side-outline/archive/2e923efab570557d056ba8cbbb915f55ff878ff7.tar.gz'; Tier='enhanced'; Allow=@() },
    [pscustomobject]@{ No=10; Id='archive';       Name='Better Archive';            Spec='https://github.com/huahai0202/dsh-better-archive/archive/fa31fc486d35b1e270828fd068a240f1775fb992.tar.gz'; Tier='enhanced'; Allow=@() },
    [pscustomobject]@{ No=11; Id='model-picker';  Name='模型选择器增强';            Spec='dsh-model-picker@1.0.2'; Tier='enhanced'; Allow=@() },
    # ---- 高级/实验（默认不装） ----
    [pscustomobject]@{ No=12; Id='auto-mode';     Name='Auto Mode';                 Spec='@nanmicoder/dsh-auto-mode@0.1.4'; Tier='advanced'; Allow=@() },
    [pscustomobject]@{ No=13; Id='cost';          Name='Cost Meter';                Spec='dsh-cost-meter@1.5.10'; Tier='advanced'; Allow=@(); Note='统计参考，不等于官方账单' },
    [pscustomobject]@{ No=14; Id='dream-skin';    Name='Dream Skin 主题';           Spec='dsh-dream-skin@0.3.0'; Tier='advanced'; Allow=@() },
    [pscustomobject]@{ No=15; Id='status';        Name='Status Rotator 状态文案';   Spec='dsh-status-rotator@0.3.0'; Tier='advanced'; Allow=@() },
    [pscustomobject]@{ No=16; Id='sentinel';      Name='Sentinel 条件唤醒';         Spec='dsh-sentinel@0.11.0'; Tier='advanced'; Allow=@() },
    [pscustomobject]@{ No=17; Id='modlens';       Name='ModLens 视觉包装';          Spec='@liustack/modlens@3.21.1'; Tier='advanced'; Allow=@() },
    [pscustomobject]@{ No=18; Id='remote';        Name='Remote SSH 工作区';         Spec='dsh-remote@0.5.7'; Tier='advanced'; Allow=@() },
    [pscustomobject]@{ No=19; Id='video';         Name='视频预览';                  Spec='dsh-video-preview@0.1.1'; Tier='advanced'; Allow=@() }
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

function Normalize-Profile([string]$value) {
    if ([string]::IsNullOrWhiteSpace($value)) { return 'web' }
    if ($value -notmatch '^[A-Za-z0-9_-]+$') { return 'web' }
    return $value
}


function Get-ProfilePnpmVersion([string]$profile) {
    $modules = Join-Path $dshHome "profiles\$profile\node_modules\.modules.yaml"
    if (Test-Path -LiteralPath $modules) {
        try {
            $raw = Get-Content -LiteralPath $modules -Raw -Encoding UTF8
            if ($raw -match '(?i)store[\\/]+v11\b') { return '11.7.0' }
            if ($raw -match '(?i)store[\\/]+v10\b') { return '10.33.2' }
        } catch {}
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
        $out = & $dsh --version 2>$null | Select-Object -First 1
        if ($LASTEXITCODE -eq 0 -and $out) {
            $text = ([string]$out).Trim()
            if ($text -match '(?<v>\d+\.\d+\.\d+(?:-[A-Za-z0-9._+-]+)?)') { return $Matches['v'] }
            return $text
        }
    } catch {}
    return $null
}

function Get-DshVersionFromNpx([string]$version) {
    Ensure-Node
    $npx = Get-Npx
    $version = Normalize-Version $version
    try {
        $out = & $npx -y "@deepseek-ai/dsh@$version" --version 2>$null | Select-Object -First 1
        if ($LASTEXITCODE -eq 0 -and $out) {
            $text = ([string]$out).Trim()
            if ($text -match '(?<v>\d+\.\d+\.\d+(?:-[A-Za-z0-9._+-]+)?)') { return $Matches['v'] }
            return $text
        }
    } catch {}
    return $null
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

# DSH 版本门槛：DesktopShell 验证基线为 $MinSupportedDshVersion。
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

# $null = 版本串为空（无法读取，按可用处理）；$false = 低于基线或无法解析（未验证）；
# $true = 支持。无法解析的版本串一律按“未验证”走门槛，而不是静默放行。
function Test-DshVersionSupported([string]$version) {
    if ([string]::IsNullOrWhiteSpace($version)) { return $null }
    $cmp = Compare-DshVersion $version $MinSupportedDshVersion
    if ($null -eq $cmp) { return $false }
    return ($cmp -ge 0)
}

# 带版本门槛的现有 dsh 解析：低于基线/无法解析时询问或自动改用 npx，而不是静默接管。
function Resolve-DshCommandWithGate([string]$existing) {
    $actual = Get-DshVersionFromCommand $existing
    if ([string]::IsNullOrWhiteSpace($actual)) {
        Ok "检测到现有 DSH（无法读取版本号），直接使用：$existing"
        return [pscustomobject]@{ Path=$existing; Version=(Normalize-Version $defaultDshVersion); Mode='command' }
    }

    $cmp = Compare-DshVersion $actual $MinSupportedDshVersion
    if ($null -eq $cmp) {
        Warn "检测到现有 DSH，版本串无法解析（$actual），未通过验证基线 $MinSupportedDshVersion。"
    } elseif ($cmp -ge 0) {
        Ok "检测到现有 DSH，直接使用：$existing  ($actual)"
        return [pscustomobject]@{ Path=$existing; Version=$actual; Mode='command' }
    } else {
        Warn "检测到现有 DSH $actual，低于 DesktopShell 验证基线 $MinSupportedDshVersion（插件/settings 接口可能不兼容）。"
    }

    if ($NonInteractive) {
        Warn "非交互模式：改用 npx @deepseek-ai/dsh@$MinSupportedDshVersion。"
        return $null
    }
    if (Read-YesNo '是否仍要使用现有 DSH？选否则改用 npx 运行验证基线版本' $false) {
        return [pscustomobject]@{ Path=$existing; Version=$actual; Mode='command' }
    }
    return $null
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

function Save-DesktopSettings([string]$dshPath, [string]$version, [string]$profile, [int]$webPort, [string]$workDir,
    [string]$closeAction, [bool]$developerMode) {
    New-Item -ItemType Directory -Force -Path $desktopDir | Out-Null
    $obj = Get-SettingsObject
    Set-Property $obj 'dshPath' $(if ($dshPath) { $dshPath } else { '' })
    Set-Property $obj 'dshVersion' (Normalize-Version $version)
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

    $savedPath = $null
    if ($obj.dshPath -and (Test-Path -LiteralPath ([string]$obj.dshPath) -PathType Leaf) -and
        -not ([IO.Path]::GetFullPath([string]$obj.dshPath)).StartsWith([IO.Path]::GetFullPath($legacyRuntimeDir), [StringComparison]::OrdinalIgnoreCase)) {
        $savedPath = [string]$obj.dshPath
    }
    if (-not $savedPath) { $savedPath = Get-DshCommand }

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

function Invoke-ManagedDsh([string]$profile, [string[]]$arguments) {
    $current = Get-CurrentSettings
    Ensure-Node
    $pnpmVersion = Get-ProfilePnpmVersion $profile
    $npx = Get-Npx

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
        $runnerDir = if ($current.DshPath) { Split-Path -Parent $current.DshPath } else { Split-Path -Parent $npx }
        $env:Path = "$shimDir;$runnerDir;$oldPath"
        $env:GIT_CONFIG_COUNT = '3'
        $env:GIT_CONFIG_KEY_0 = 'url.https://github.com/.insteadOf'
        $env:GIT_CONFIG_VALUE_0 = 'git+ssh://git@github.com/'
        $env:GIT_CONFIG_KEY_1 = 'url.https://github.com/.insteadOf'
        $env:GIT_CONFIG_VALUE_1 = 'ssh://git@github.com/'
        $env:GIT_CONFIG_KEY_2 = 'url.https://github.com/.insteadOf'
        $env:GIT_CONFIG_VALUE_2 = 'git@github.com:'

        if ($current.DshPath) {
            Say "插件操作：现有 DSH $($current.DshPath)；Profile pnpm@$pnpmVersion"
            & $current.DshPath @arguments | Out-Host
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
        if ($p.Note) { Write-Host ('      备注：{0}' -f $p.Note) -ForegroundColor DarkGray }
    }
    Write-Host ''
    Write-Host '内置目录全部为锁定版本（npm 精确版本 / GitHub commit），可复现。' -ForegroundColor DarkGray
    Write-Host '需要追新版本的插件可在“额外插件”步骤粘贴自定义 spec。' -ForegroundColor DarkGray
}

function Select-Plugins([bool]$existingProfile) {
    if ($NonInteractive) { return @() }

    Write-Host ''
    if ($existingProfile) {
        Write-Host '检测到已有 Profile。默认不会重装现有插件。'
        Write-Host '  0. 保留现有插件，不做变更（推荐）'
    }
    Write-Host '  1. 核心推荐（5 个：插件市场 / 工作台 / Skills / @file / Rewind）'
    Write-Host '  2. 核心推荐 + 体验增强（11 个）'
    Write-Host '  3. 全部已审核插件（19 个，均为锁定版本）'
    Write-Host '  4. 自定义选择'
    $defaultChoice = if ($existingProfile) { '0' } else { '1' }
    $choice = Read-Default '插件安装方案' $defaultChoice
    if ($choice -eq '0' -and $existingProfile) { return @() }
    if ($choice -eq '1') { return @($PluginCatalog | Where-Object { $_.Tier -eq 'core' }) }
    if ($choice -eq '2') { return @($PluginCatalog | Where-Object { $_.Tier -ne 'advanced' }) }
    if ($choice -eq '3') { return @($PluginCatalog) }

    Show-PluginCatalog
    $raw = Read-Host '输入编号，逗号分隔（例如 1,2,10,13；留空=不装）'
    if ([string]::IsNullOrWhiteSpace($raw)) { return @() }
    $numbers = @($raw -split '[,，\s]+' | Where-Object { $_ -match '^\d+$' } | ForEach-Object { [int]$_ })
    return @($PluginCatalog | Where-Object { $_.No -in $numbers })
}

function Configure-StatusRotator([string]$profile) {
    $dir = Join-Path $dshHome "profiles\$profile\node_modules\dsh-status-rotator"
    if (-not (Test-Path -LiteralPath $dir -PathType Container)) { return }
    if (-not (Read-YesNo 'Status Rotator：关闭默认流动炫彩渐变？' $true)) { return }
    $cfg = Join-Path $dir 'config.json'
    $example = Join-Path $dir 'config.example.json'
    if (-not (Test-Path -LiteralPath $cfg) -and (Test-Path -LiteralPath $example)) { Copy-Item $example $cfg -Force }
    if (-not (Test-Path -LiteralPath $cfg)) { Warn '找不到 status-rotator config.json，跳过炫彩配置。'; return }
    try {
        $json = Get-Content $cfg -Raw -Encoding UTF8 | ConvertFrom-Json
        if (-not $json.config) { $json | Add-Member -NotePropertyName config -NotePropertyValue ([pscustomobject]@{}) }
        if ($json.config.PSObject.Properties.Name -contains 'gradient') { $json.config.gradient = $false }
        else { $json.config | Add-Member -NotePropertyName gradient -NotePropertyValue $false }
        $json | ConvertTo-Json -Depth 100 | ForEach-Object { Write-Utf8NoBom $cfg $_ }
        Ok 'Status Rotator 炫彩已关闭。'
    } catch { Warn "Status Rotator 配置失败：$($_.Exception.Message)" }
}

function Configure-BetterSidebar {
    if (-not (Get-Command pwsh.exe -ErrorAction SilentlyContinue)) { return }
    if (Read-YesNo 'Better Sidebar：固定使用 PowerShell 7 (pwsh.exe)？' $true) {
        [Environment]::SetEnvironmentVariable('DSH_SIDEBAR_SHELL','pwsh.exe','User')
        $env:DSH_SIDEBAR_SHELL = 'pwsh.exe'
        Ok '已设置用户环境变量 DSH_SIDEBAR_SHELL=pwsh.exe。'
    }
}

function Install-Plugins([string]$profile, [object[]]$selected) {
    if (-not $selected -or $selected.Count -eq 0) { return }

    $allow = @($selected | ForEach-Object { $_.Allow } | Where-Object { $_ })
    Update-AllowBuilds $profile $allow

    $failures = @()
    foreach ($plugin in $selected) {
        Say "安装插件：$($plugin.Name)"
        $code = Invoke-ManagedDsh $profile @('plugin','--profile',$profile,'add',$plugin.Spec)
        if ($code -ne 0) {
            Warn "安装失败：$($plugin.Name)（退出码 $code）"
            $failures += $plugin.Name
        } else { Ok "已安装：$($plugin.Name)" }
    }

    if ($selected.Id -contains 'sidebar') { Configure-BetterSidebar }
    if ($selected.Id -contains 'status') { Configure-StatusRotator $profile }

    if (-not $NonInteractive) {
        $extra = Read-Host '还要安装额外插件吗？可直接粘贴 package/spec，多个用分号分隔；留空跳过'
        foreach ($spec in @($extra -split ';' | ForEach-Object { $_.Trim() } | Where-Object { $_ })) {
            Say "安装额外插件：$spec"
            $code = Invoke-ManagedDsh $profile @('plugin','--profile',$profile,'add',$spec)
            if ($code -ne 0) { $failures += $spec }
        }
    }

    if ($failures.Count -gt 0) {
        Warn ('以下插件安装失败，但不影响其他插件：' + ($failures -join '；'))
    }

    if ($selected.Count -gt 0) {
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
}

function Guided-Setup {
    Title 'DeepSeek Harness DesktopShell v1.0.0 初始化'
    Write-Host 'DSH 启动策略：'
    Write-Host '  • 系统已有 dsh 命令 -> 直接使用，不重装、不移动'
    Write-Host '  • 现有 dsh 低于验证基线 rc.7 -> 询问是否改用 npx，不静默接管'
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

    Save-DesktopSettings $resolved.Path $resolved.Version $profile $webPort $work $close $dev

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
                        Save-DesktopSettings $gated.Path $gated.Version $current.Profile $current.Port $current.Work $current.Close $current.Dev
                    } else {
                        Write-Host '改用官方 npx 运行方式。'
                        $v = Read-Default 'npx 使用的 DSH 版本' $current.Version
                        $resolved = Prepare-NpxDsh $v
                        Save-DesktopSettings $null $resolved.Version $current.Profile $current.Port $current.Work $current.Close $current.Dev
                    }
                } else {
                    Write-Host '系统 PATH 中没有 dsh；DesktopShell 使用官方 npx 运行方式。'
                    $v = Read-Default 'npx 使用的 DSH 版本' $current.Version
                    $resolved = Prepare-NpxDsh $v
                    Save-DesktopSettings $null $resolved.Version $current.Profile $current.Port $current.Work $current.Close $current.Dev
                }
            }
            '2' {
                $profile = Normalize-Profile (Read-Default 'Profile 名称' $current.Profile)
                $portText = Read-Default 'Web 端口' ([string]$current.Port)
                $p = $current.Port
                if (-not ([int]::TryParse($portText,[ref]$p) -and $p -ge 1 -and $p -le 65535)) { $p=3080 }
                $work = Read-Default '默认工作目录' $current.Work
                Write-Host '关闭窗口行为：1=每次询问  2=关闭到托盘  3=关闭并退出'
                $closeDefault = if ($current.Close -eq 'tray') { '2' } elseif ($current.Close -eq 'exit') { '3' } else { '1' }
                $cc = Read-Default '选择' $closeDefault
                $close = if ($cc -eq '2') {'tray'} elseif ($cc -eq '3') {'exit'} else {'ask'}
                $dev = Read-YesNo '启用 WebView2 开发者模式（DevTools）？' $current.Dev
                Save-DesktopSettings $current.DshPath $current.Version $profile $p $work $close $dev
            }
            '3' {
                $profilePackage = Join-Path $dshHome "profiles\$($current.Profile)\package.json"
                $selected = Select-Plugins (Test-Path -LiteralPath $profilePackage)
                Install-Plugins $current.Profile $selected
            }
            '4' { Show-Diagnostics $current.Profile }
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
