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
$DefaultDshVersion = '0.1.5-rc.2'
$MinimumCompatibleDshVersion = '0.1.0-rc.7'
$TestedDshVersions = @('0.1.0-rc.7', '0.1.0-rc.8', '0.1.1-rc.1', '0.1.1-rc.2', '0.1.5-rc.1', '0.1.5-rc.2')
$NpxDshChannelOptions = @()
# 已实际确认支持 --no-open 的版本；未知版本仍由 DesktopShell 在启动时探测 --help。
$KnownNoOpenDshVersions = @('0.1.0-rc.8', '0.1.1-rc.1', '0.1.1-rc.2', '0.1.5-rc.1', '0.1.5-rc.2')
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
        if ($compat.PSObject.Properties.Name -contains 'npxDshChannelOptions') {
            $seenTags = @{}
            foreach ($item in @($compat.npxDshChannelOptions)) {
                $tag = ([string]$item.tag).Trim().ToLowerInvariant()
                if ($tag -notmatch '^[a-z][a-z0-9-]{0,31}$') { continue }
                if ($seenTags.ContainsKey($tag)) { continue }
                $seenTags[$tag] = $true

                $label = [string]$item.label
                if ([string]::IsNullOrWhiteSpace($label)) { $label = "官方 $tag 标签" }
                $note = [string]$item.note
                $profileMode = if ([string]$item.profileMode -eq 'isolated') { 'isolated' } else { 'current' }
                $NpxDshChannelOptions += [pscustomobject]@{
                    Tag = $tag
                    Label = $label.Trim()
                    Note = $note.Trim()
                    Preview = [bool]$item.preview
                    ProfileMode = $profileMode
                }
            }
        }
    } catch {}
}
# npx 回退版本与默认版本同一来源，不允许各自硬编码（单一事实来源）。
$defaultDshVersion = $DefaultDshVersion
$defaultProfilePnpmVersion = '10.33.2'

# 插件目录不再内嵌版本或兼容结论。每次由真实 Profile 的 package.json、已安装包、
# cordis.patch.yml、Cordis service inject 与上游元数据重新生成；PASS 只接受精确
# 0.1.5-rc.2 的完整 preflight 证据，latest 始终只是可选上游信息而不是安装建议。
$PluginCatalog = @()
$PluginCatalogCache = @{}

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

function Get-DshPluginEcosystem(
    [string]$profile,
    [string]$targetVersion = $DefaultDshVersion,
    [switch]$Refresh
) {
    if ([string]::IsNullOrWhiteSpace($profile) -or $profile -notmatch '^[A-Za-z0-9_-]+$') { return $null }
    $packagePath = Join-Path $dshHome ("profiles\{0}\package.json" -f $profile)
    if (-not (Test-Path -LiteralPath $packagePath -PathType Leaf)) { return $null }
    $cacheKey = $profile + '|' + $targetVersion
    if (-not $Refresh -and $PluginCatalogCache.ContainsKey($cacheKey)) { return $PluginCatalogCache[$cacheKey] }

    $scanner = Join-Path $desktopDir 'scripts\Scan-DshPluginEcosystem.ps1'
    if (-not (Test-Path -LiteralPath $scanner -PathType Leaf)) {
        Warn "插件生态扫描器不存在：$scanner"
        return $null
    }
    $profilePreflight = Join-Path $dshHome ("profiles\{0}\.dsh-desktop-shell\PLUGIN_PREFLIGHT_0.1.5-rc.2.json" -f $profile)
    $sourcePreflight = Join-Path $desktopDir 'docs\PLUGIN_PREFLIGHT_0.1.5-rc.2.json'
    $preflight = if (Test-Path -LiteralPath $profilePreflight -PathType Leaf) { $profilePreflight } else { $sourcePreflight }
    try {
        $scanArgs = @{
            DshHome = $dshHome
            Profile = $profile
            DshVersion = $targetVersion
            PassThru = $true
        }
        if (Test-Path -LiteralPath $preflight -PathType Leaf) { $scanArgs.PreflightResults = $preflight }
        $document = & $scanner @scanArgs
        if (-not $document -or -not $document.plugins) { throw '扫描器没有返回插件矩阵。' }
        $PluginCatalogCache[$cacheKey] = $document
        return $document
    }
    catch {
        Warn ("无法扫描真实插件生态：{0}" -f $_.Exception.Message)
        return $null
    }
}

function Clear-DshPluginEcosystemCache([string]$profile = '') {
    if ([string]::IsNullOrWhiteSpace($profile)) { $PluginCatalogCache.Clear(); return }
    foreach ($key in @($PluginCatalogCache.Keys)) {
        if ($key -like ($profile + '|*')) { $PluginCatalogCache.Remove($key) }
    }
}

function Get-PluginPackageDirectory([string]$profile, [string]$package) {
    # 名称来自扫描后的 Profile package.json，但仍限制为标准 npm 名称，避免把
    # 自定义 manifest 中的路径片段作为文件系统路径使用。
    if ([string]::IsNullOrWhiteSpace($package) -or
        $package -notmatch '^(?:@[A-Za-z0-9][A-Za-z0-9._-]*/)?[A-Za-z0-9][A-Za-z0-9._-]*$') {
        return $null
    }
    $directory = Join-Path $dshHome (Join-Path 'profiles' (Join-Path $profile 'node_modules'))
    foreach ($part in ($package -split '/')) { $directory = Join-Path $directory $part }
    return $directory
}

function Get-DynamicPluginPostInstallHook([string]$profile, [string]$package) {
    # 不按包名维护钩子目录：仅当已安装包实际携带可解析的 config.example.json，
    # 且其中声明 config.gradient 时，才发现这个可选的安全默认值初始化能力。
    $pluginDirectory = Get-PluginPackageDirectory $profile $package
    if ([string]::IsNullOrWhiteSpace($pluginDirectory)) { return '' }
    $examplePath = Join-Path $pluginDirectory 'config.example.json'
    if (-not (Test-Path -LiteralPath $examplePath -PathType Leaf)) { return '' }
    try {
        $document = Get-Content -LiteralPath $examplePath -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($null -ne $document.config -and
            $document.config -isnot [array] -and
            $document.config.PSObject.Properties.Name -contains 'gradient') {
            return 'InitializeExampleGradientConfig'
        }
    }
    catch { }
    return ''
}

function Get-DynamicPluginCatalog([string]$profile, [string]$targetVersion = $DefaultDshVersion, [switch]$Refresh) {
    $document = Get-DshPluginEcosystem $profile $targetVersion -Refresh:$Refresh
    if (-not $document) { return @() }
    $number = 0
    $catalog = @()
    foreach ($item in @($document.plugins)) {
        $number++
        $catalog += [pscustomobject]@{
            No = $number
            Id = [string]$item.package
            Name = [string]$item.package
            Package = [string]$item.package
            Version = [string]$item.version
            Requested = [string]$item.requested
            Spec = [string]$item.installSpec
            InstallSpec = [string]$item.installSpec
            Status = [string]$item.status
            DependsOn = @($item.dependsOn)
            Dependents = @($item.dependents)
            RequiresService = @($item.requiresService)
            ObservedServiceInject = @($item.observedServiceInject)
            HostRange = @($item.hostRange)
            Evidence = @($item.evidence)
            DshClientInject = @($item.dshClientInject)
            Upstream = $item.upstream
            PostInstall = Get-DynamicPluginPostInstallHook $profile ([string]$item.package)
            Floating = ([string]$item.requested -match '^(?:github:|git\+|https?://github\.com)') -and
                ([string]$item.installSpec -notmatch '#[0-9a-f]{7,40}$')
        }
    }
    return @($catalog)
}

function Get-DshUpgradeBlockers([string]$profile, [string]$targetVersion) {
    $document = Get-DshPluginEcosystem $profile $targetVersion -Refresh
    if (-not $document) { return @() }
    $blockers = @()
    foreach ($plugin in @($document.plugins | Where-Object { $_.status -ne 'PASS' })) {
        $status = [string]$plugin.status
        $blockers += [pscustomobject]@{
            Kind = if ($status -eq 'BLOCKED') { 'plugin-hard-blocker' } else { 'plugin-unverified' }
            Name = [string]$plugin.package
            Reason = if ($status -eq 'BLOCKED') {
                (@($plugin.evidence) -join '；')
            } else {
                ('状态为 {0}，没有目标 DSH 的完整精确 preflight 证据。{1}' -f $status, (@($plugin.evidence) -join '；'))
            }
        }
    }
    foreach ($orphan in @($document.profile.patchOrphans)) {
        $blockers += [pscustomobject]@{
            Kind = 'profile-patch'
            Name = [string]$orphan
            Reason = 'cordis.patch.yml 指向的 id 没有已安装 provider。'
        }
    }
    if ($document.profile.listError) {
        $blockers += [pscustomobject]@{
            Kind = 'plugin-list'
            Name = $profile
            Reason = ('plugin list 失败：' + [string]$document.profile.listError)
        }
    }
    return @($blockers)
}

function Test-DshUpgradeAllowed([string]$profile, [string]$currentVersion, [string]$targetVersion) {
    if ([string]::Equals($currentVersion, $targetVersion, [StringComparison]::OrdinalIgnoreCase)) { return $true }
    $blockers = @(Get-DshUpgradeBlockers $profile $targetVersion)
    if ($blockers.Count -eq 0) { return $true }
    Warn ("拒绝将 Profile {0} 升级到 DSH {1}：发现 {2} 个硬阻断或未验证项。" -f $profile, $targetVersion, $blockers.Count)
    foreach ($blocker in $blockers) { Warn ("  {0}: {1} — {2}" -f $blocker.Kind, $blocker.Name, $blocker.Reason) }
    Warn '请先隔离/修复这些项并完成精确版本 preflight；UNKNOWN 也不会自动视为兼容。'
    return $false
}

function New-NpxDshSelection(
    [string]$version,
    [string]$source = 'fixed',
    [bool]$preview = $false,
    [string]$profileMode = 'current',
    [string]$label = ''
) {
    return [pscustomobject]@{
        Version = Normalize-Version $version
        Source = $source
        Preview = $preview
        ProfileMode = if ($profileMode -eq 'isolated') { 'isolated' } else { 'current' }
        Label = $label
    }
}

function Get-NpxDshVersionChoices([string]$currentVersion) {
    $choices = @()
    $seen = @{}

    $choices += [pscustomobject]@{
        Version = $DefaultDshVersion
        Tag = ''
        Dynamic = $false
        Label = '生产推荐（已测试）'
        Note = 'DesktopShell 默认版本；已纳入正式兼容测试。'
        Preview = $false
        ProfileMode = 'current'
        Kind = '生产推荐'
    }
    $seen[$DefaultDshVersion.ToLowerInvariant()] = $true

    foreach ($version in @($TestedDshVersions)) {
        if ($version -notmatch '^\d+\.\d+\.\d+(?:-[A-Za-z0-9._+-]+)?$') { continue }
        $key = $version.ToLowerInvariant()
        if ($seen.ContainsKey($key)) { continue }
        $seen[$key] = $true
        $choices += [pscustomobject]@{
            Version = $version
            Tag = ''
            Dynamic = $false
            Label = '已测试（历史版本）'
            Note = '已完成历史兼容验证，但不是当前生产默认。'
            Preview = $false
            ProfileMode = 'current'
            Kind = '已测试'
        }
    }

    foreach ($option in @($NpxDshChannelOptions)) {
        $tag = [string]$option.Tag
        if ($tag -notmatch '^[a-z][a-z0-9-]{0,31}$') { continue }
        $choices += [pscustomobject]@{
            Version = ''
            Tag = $tag
            Dynamic = $true
            Label = [string]$option.Label
            Note = [string]$option.Note
            Preview = [bool]$option.Preview
            ProfileMode = [string]$option.ProfileMode
            Kind = if ([bool]$option.Preview) { '预览，未正式测试' } else { '官方通道，未固定为正式测试' }
        }
    }

    # 历史设置或命令行参数若不是目录项，仍可明确地“保持当前”，避免向导静默改写用户选择。
    $current = if ($currentVersion) { $currentVersion.Trim() } else { '' }
    if ($current -match '^\d+\.\d+\.\d+(?:-[A-Za-z0-9._+-]+)?$') {
        $currentKey = $current.ToLowerInvariant()
        if (-not $seen.ContainsKey($currentKey)) {
            $choices += [pscustomobject]@{
                Version = $current
                Tag = ''
                Dynamic = $false
                Label = '当前设置（未列入目录）'
                Note = '保留已有版本；未标记为 DesktopShell 正式测试版本。'
                Preview = $true
                ProfileMode = 'current'
                Kind = '当前设置，未正式测试'
            }
        }
    }
    return @($choices)
}

function Select-NpxDshVersion([string]$currentVersion) {
    # 自动化调用继续尊重 -DshVersion / 已保存设置；交互向导不再要求用户手输版本串。
    if ($NonInteractive) {
        return (New-NpxDshSelection (Normalize-Version $currentVersion) 'fixed' $false 'current' '当前设置')
    }

    $choices = @(Get-NpxDshVersionChoices $currentVersion)
    if ($choices.Count -eq 0) {
        return (New-NpxDshSelection $DefaultDshVersion 'fixed' $false 'current' '生产推荐')
    }

    $defaultChoice = 1
    for ($i = 0; $i -lt $choices.Count; $i++) {
        # 未测试的旧 alpha/自定义设置只允许显式选择，不再成为首次向导的默认项。
        if (-not $choices[$i].Preview -and -not $choices[$i].Dynamic -and
            [string]::Equals([string]$choices[$i].Version, $currentVersion, [StringComparison]::OrdinalIgnoreCase)) {
            $defaultChoice = $i + 1
            break
        }
    }

    Write-Host 'npx DSH 版本（输入编号，不需要手输版本号）：'
    for ($i = 0; $i -lt $choices.Count; $i++) {
        $choice = $choices[$i]
        $suffix = if (($i + 1) -eq $defaultChoice) { '（默认）' } else { '' }
        $kind = [string]$choice.Kind
        $shown = if ($choice.Dynamic) { "官方 $($choice.Tag) 标签（实时解析）" } else { [string]$choice.Version }
        Write-Host ("  {0}. {1}  {2} [{3}] {4}" -f ($i + 1), $shown, $choice.Label, $kind, $suffix)
        if ($choice.Note) { Write-Host ("      " + $choice.Note) -ForegroundColor DarkGray }
    }
    Write-Host '  0. 取消'

    while ($true) {
        $raw = Read-Default '选择版本' ([string]$defaultChoice)
        if ($raw -eq '0') { return $null }

        $number = 0
        if (-not [int]::TryParse($raw, [ref]$number) -or $number -lt 1 -or $number -gt $choices.Count) {
            Warn '请输入上方版本选项的编号。'
            continue
        }

        $selected = $choices[$number - 1]
        if ($selected.Preview) {
            $previewName = if ($selected.Dynamic) { "官方 $($selected.Tag) 标签" } else { [string]$selected.Version }
            Warn ("已选择预览版本/通道 {0}；它不会加入正式 testedDshVersions，也不会改变生产默认版本。" -f $previewName)
            if (-not (Read-YesNo '确认仅用于预览验证？' $false)) { return $null }
        }

        $resolvedVersion = if ($selected.Dynamic) {
            Resolve-NpmDshDistTag ([string]$selected.Tag)
        } else {
            [string]$selected.Version
        }
        if ($selected.Dynamic) {
            Ok ("npm 标签 {0} 当前解析为：{1}" -f $selected.Tag, $resolvedVersion)
        }
        $source = if ($selected.Dynamic) { [string]$selected.Tag } else { 'fixed' }
        return (New-NpxDshSelection -version $resolvedVersion -source $source `
            -preview ([bool]$selected.Preview) -profileMode ([string]$selected.ProfileMode) `
            -label ([string]$selected.Label))
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

function Get-Npm {
    $npm = Get-Command npm.cmd -ErrorAction SilentlyContinue
    if (-not $npm) { $npm = Get-Command npm.exe -ErrorAction SilentlyContinue }
    if (-not $npm) { $npm = Get-Command npm -ErrorAction SilentlyContinue }
    if (-not $npm) { Fail '找不到 npm。无法查询官方 DSH dist-tag。请确认 Node.js/npm 已正确安装。' }
    return $npm.Source
}

function Resolve-NpmDshDistTag([string]$tag) {
    Ensure-Node
    $tag = ([string]$tag).Trim().ToLowerInvariant()
    if ($tag -notmatch '^[a-z][a-z0-9-]{0,31}$') {
        Fail "无效的 npm DSH 标签：$tag"
    }

    $npm = Get-Npm
    Say "查询 npm 官方 DSH 标签：$tag"
    # 与 npx 版本探测一样，保留 npm stderr；否则上游标签/网络故障会被误报成“没有版本”。
    $oldEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $raw = (& $npm view ("@deepseek-ai/dsh@" + $tag) version --json 2>&1)
        $code = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $oldEap
    }
    $text = ($raw | Out-String).Trim()
    if ($code -ne 0) {
        throw "无法查询 npm 标签 @deepseek-ai/dsh@$tag（退出码 $code）。原始输出：`r`n$text"
    }

    # npm view --json 正常输出为 JSON 字符串；只接受独占行的 SemVer，不能从报错文字里猜版本。
    $lines = @($text -split "`r?`n")
    for ($i = $lines.Count - 1; $i -ge 0; $i--) {
        $candidate = $lines[$i].Trim().Trim('"')
        if ($candidate -match '^\d+\.\d+\.\d+(?:-[A-Za-z0-9._+-]+)?$') {
            return $candidate
        }
    }
    throw "npm 标签 @deepseek-ai/dsh@$tag 未返回可用的 DSH SemVer。原始输出：`r`n$text"
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

function Get-NewIsolatedPreviewProfile([string]$version) {
    $safeVersion = ([regex]::Replace(([string]$version).ToLowerInvariant(), '[^a-z0-9]+', '-')).Trim('-')
    if ([string]::IsNullOrWhiteSpace($safeVersion)) { $safeVersion = 'unknown' }
    $base = Normalize-Profile ("desktop-preview-" + $safeVersion)
    if ($base -eq 'web') { $base = 'desktop-preview' }

    $profilesRoot = Join-Path $dshHome 'profiles'
    $candidate = $base
    $number = 2
    while (Test-Path -LiteralPath (Join-Path $profilesRoot $candidate)) {
        $candidate = $base + '-' + $number.ToString()
        $number++
    }
    return $candidate
}

function Resolve-ProfileForNpxSelection(
    [object]$selection,
    [string]$currentProfile,
    [switch]$PromptForProfile
) {
    if ($selection -and $selection.ProfileMode -eq 'isolated') {
        $isolated = Get-NewIsolatedPreviewProfile $selection.Version
        Warn ("该预览通道可能与现有第三方插件 API 不兼容。将使用新的隔离 Profile：{0}" -f $isolated)
        Warn '现有 Profile、插件、主题和会话目录均不会被移动、删除或改写。'
        if (-not (Read-YesNo '确认使用隔离 Profile 继续？' $true)) { return $null }
        return $isolated
    }

    if ($PromptForProfile) {
        return (Normalize-Profile (Read-Default 'Profile 名称' $currentProfile))
    }
    return (Normalize-Profile $currentProfile)
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

    # 成功只接受唯一一行独立版本号，不从任意文本中抽取 SemVer。
    # npm 11 会在正常 npx 输出后追加 "npm notice" 升级提示；这些额外行不应让
    # 已验证的版本探测失败。明确错误已在上方拒绝，仍要求版本行本身完整且唯一。
    $versionLines = @($text -split "`r?`n" | ForEach-Object { $_.Trim() } |
        Where-Object { $_ -match '^\d+\.\d+\.\d+(?:-[A-Za-z0-9._+-]+)?$' })
    if ($versionLines.Count -eq 1) {
        return $versionLines[0]
    }

    throw "无法通过 npx 启动 @deepseek-ai/dsh@$version：输出中没有唯一的独立版本号。原始输出：`r`n$text"
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
# 不再要求“等于某个唯一验证版本”：rc.7/rc.8/rc.1/rc.2 已测试，未来版本只要不低于最低版本就允许尝试。
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

function Show-PluginCatalog([string]$profile, [string]$targetVersion = $DefaultDshVersion) {
    $document = Get-DshPluginEcosystem $profile $targetVersion -Refresh
    $catalog = @(Get-DynamicPluginCatalog $profile $targetVersion)
    Write-Host ''
    if ($catalog.Count -eq 0) {
        Warn '当前 Profile 没有可扫描的实际插件；可通过“自定义 package/spec”安装后重新扫描。'
        return @()
    }
    foreach ($p in $catalog) {
        Write-Host ('{0,2}. {1}@{2} [{3}]' -f $p.No, $p.Package, $p.Version, $p.Status)
        $npmLatest = if ($p.Upstream -and $p.Upstream.npm) { [string]$p.Upstream.npm.version } else { '' }
        $githubLatest = if ($p.Upstream -and $p.Upstream.github) { [string]$p.Upstream.github.value } else { '' }
        $upstream = (@($npmLatest, $githubLatest) | Where-Object { $_ }) -join ' / '
        if ($upstream) { Write-Host ('      上游：{0}' -f $upstream) -ForegroundColor DarkGray }
        if ($p.RequiresService.Count -gt 0) { Write-Host ('      RequiresService：{0}' -f ($p.RequiresService -join ', ')) -ForegroundColor DarkGray }
        if ($p.DependsOn.Count -gt 0) { Write-Host ('      DependsOn：{0}' -f ($p.DependsOn -join ', ')) -ForegroundColor DarkGray }
        if ($p.Dependents.Count -gt 0) { Write-Host ('      下游：{0}' -f ($p.Dependents -join ', ')) -ForegroundColor Yellow }
        if ($p.Evidence.Count -gt 0) { Write-Host ('      证据：{0}' -f ($p.Evidence -join '；')) -ForegroundColor DarkGray }
        if ($p.Floating) { Write-Host '      GitHub 源未解析为已安装 commit；不能把它当作可复现推荐版本。' -ForegroundColor Yellow }
    }
    if ($document -and @($document.profile.patchOrphans).Count -gt 0) {
        Warn ('孤立 cordis.patch.yml id：' + (@($document.profile.patchOrphans) -join '、'))
    }
    Write-Host ''
    Write-Host '状态：PASS=完整精确 preflight；WARN=元数据/部分验证；BLOCKED=硬阻断；UNKNOWN=不能自动当兼容。' -ForegroundColor DarkGray
    Write-Host 'latest 只展示为上游信息；安装始终使用真实已安装版本或已解析 commit，而不会自动追 latest。' -ForegroundColor DarkGray
    return @($catalog)
}

function Get-ExclusiveSelectionConflicts([object[]]$selected) {
    $groups = @($selected |
        Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_.ExclusiveGroup) } |
        Group-Object -Property ExclusiveGroup)
    foreach ($group in $groups) {
        if ($group.Count -gt 1) {
            [pscustomobject]@{ Name=[string]$group.Name; Members=@($group.Group) }
        }
    }
}

function Resolve-ExclusivePluginSelection([object[]]$selected) {
    $result = @($selected)
    foreach ($conflict in @(Get-ExclusiveSelectionConflicts $result)) {
        $members = @($conflict.Members)
        $recommended = @($members | Where-Object { $_.Recommended -eq $true } | Select-Object -First 1)
        if ($recommended.Count -eq 0) { $recommended = @($members | Select-Object -First 1) }
        $keepId = [string]$recommended[0].Id

        if ($NonInteractive) {
            Warn ("互斥插件组 {0} 同时被选中；非交互模式保留推荐项 {1}，跳过 {2}。" -f
                $conflict.Name, $recommended[0].Name,
                (($members | Where-Object { $_.Id -ne $keepId } | ForEach-Object Name) -join '、'))
        }
        else {
            Write-Host ("检测到互斥插件组：{0}" -f $conflict.Name) -ForegroundColor Yellow
            for ($i = 0; $i -lt $members.Count; $i++) {
                $suffix = if ($members[$i].Id -eq $keepId) { '（推荐）' } else { '' }
                Write-Host ("  {0}. {1}{2}" -f ($i + 1), $members[$i].Name, $suffix)
            }
            do {
                $choice = (Read-Host '二选一，输入编号').Trim()
                $choiceIndex = 0
                $valid = [int]::TryParse($choice, [ref]$choiceIndex) -and
                    $choiceIndex -ge 1 -and $choiceIndex -le $members.Count
                if (-not $valid) { Warn '请输入有效编号。' }
            } while (-not $valid)
            $keepId = [string]$members[$choiceIndex - 1].Id
        }

        $result = @($result | Where-Object {
            [string]$_.ExclusiveGroup -ne $conflict.Name -or [string]$_.Id -eq $keepId
        })
    }
    return @($result)
}

function Get-ProfileExclusiveConflicts([string]$profile) {
    $packagePath = Join-Path $dshHome ("profiles\{0}\package.json" -f $profile)
    if (-not (Test-Path -LiteralPath $packagePath -PathType Leaf)) { return @() }
    try {
        $package = Get-Content -LiteralPath $packagePath -Raw -Encoding UTF8 | ConvertFrom-Json
        $dependencyNames = @()
        if ($package.dependencies) { $dependencyNames = @($package.dependencies.PSObject.Properties.Name) }
        foreach ($group in @($PluginCatalog | Where-Object { $_.ExclusiveGroup } | Group-Object ExclusiveGroup)) {
            $members = @($group.Group | Where-Object { $_.Package -and $_.Package -in $dependencyNames })
            if ($members.Count -gt 1) {
                [pscustomobject]@{ Name=[string]$group.Name; Members=$members }
            }
        }
    }
    catch { Warn ("无法读取 Profile 插件依赖，跳过互斥检查：{0}" -f $_.Exception.Message) }
}

function Resolve-ProfileExclusiveConflicts([string]$profile) {
    foreach ($conflict in @(Get-ProfileExclusiveConflicts $profile)) {
        $members = @($conflict.Members)
        Warn ("已有 Profile 同时安装了互斥插件组 {0}：{1}。不会自动卸载。" -f
            $conflict.Name, (($members | ForEach-Object Name) -join '、'))
        if ($NonInteractive) {
            Warn '非交互模式不替用户卸载任何一项；请手动选择保留项后重试。'
            continue
        }

        for ($i = 0; $i -lt $members.Count; $i++) {
            Write-Host ("  {0}. 保留 {1}" -f ($i + 1), $members[$i].Name)
        }
        Write-Host '  0. 暂不处理（保留冲突现状）'
        do {
            $choice = (Read-Host '选择保留项').Trim()
            $choiceIndex = 0
            $valid = [int]::TryParse($choice, [ref]$choiceIndex) -and
                $choiceIndex -ge 0 -and $choiceIndex -le $members.Count
            if (-not $valid) { Warn '请输入有效编号。' }
        } while (-not $valid)
        if ($choiceIndex -eq 0) { continue }

        $keep = $members[$choiceIndex - 1]
        $remove = @($members | Where-Object { $_.Id -ne $keep.Id } | Select-Object -First 1)
        if ($remove.Count -eq 0 -or [string]::IsNullOrWhiteSpace([string]$remove[0].Package)) {
            Warn '无法解析需要移除的插件包名，保留冲突现状。'
            continue
        }
        $code = Invoke-ManagedDsh $profile @('plugin','--profile',$profile,'remove',[string]$remove[0].Package)
        if ($code -eq 0) { Ok ("已按选择保留 {0}，移除 {1}。" -f $keep.Name, $remove[0].Name) }
        else { Warn ("移除 {0} 失败（退出码 {1}）；冲突仍需处理。" -f $remove[0].Name, $code) }
    }
}

function Select-Plugins([string]$profile, [bool]$existingProfile) {
    if ($NonInteractive -or -not $existingProfile) { return @() }
    Write-Host ''
    Write-Host '目录来自当前真实 Profile，而非内嵌插件表。默认不重装任何插件。'
    Write-Host '  0. 保留现有插件，不做变更（推荐）'
    Write-Host '  1. 只重装已经完成完整 preflight 的 PASS 插件'
    Write-Host '  2. 显示矩阵并明确选择（WARN / UNKNOWN 必须手动确认）'
    $choice = Read-Default '插件操作' '0'
    if ($choice -eq '0') { return @() }

    $catalog = @()
    if ($choice -eq '1') {
        $catalog = @(Get-DynamicPluginCatalog $profile)
        $selected = @($catalog | Where-Object { $_.Status -eq 'PASS' })
        if ($selected.Count -eq 0) {
            Warn '没有 PASS 插件可自动重装。请先完成精确版本的完整 preflight。'
            return @()
        }
        return $selected
    }

    $catalog = @(Show-PluginCatalog $profile)
    if ($catalog.Count -eq 0) { return @() }
    $raw = Read-Host '输入编号，逗号分隔；留空=不安装'
    if ([string]::IsNullOrWhiteSpace($raw)) { return @() }
    $numbers = @($raw -split '[,，\s]+' | Where-Object { $_ -match '^\d+$' } | ForEach-Object { [int]$_ })
    $selected = @($catalog | Where-Object { $_.No -in $numbers })
    if ($selected.Count -eq 0) { return @() }
    $unverified = @($selected | Where-Object { $_.Status -ne 'PASS' })
    if ($unverified.Count -gt 0) {
        Warn ('以下项不是 PASS：' + (($unverified | ForEach-Object Package) -join '、'))
        if (-not (Read-YesNo '明确继续安装这些非 PASS 项？它们不会被标为兼容。' $false)) { return @() }
    }
    return @($selected)
}

function Initialize-ExampleGradientConfig([string]$profile, [string]$package) {
    # 这个初始化器完全由扫描到的包内容决定，不为某个插件 id 写专用规则。
    # 只在首次安装且 config.example.json 明确提供 gradient 配置时写 config.json；
    # 已有 config.json 永远由用户保留。
    $pluginDirectory = Get-PluginPackageDirectory $profile $package
    if ([string]::IsNullOrWhiteSpace($pluginDirectory)) { return $false }
    $configPath = Join-Path $pluginDirectory 'config.json'
    $examplePath = Join-Path $pluginDirectory 'config.example.json'
    if (-not (Test-Path -LiteralPath $examplePath -PathType Leaf)) { return $false }
    if (Test-Path -LiteralPath $configPath -PathType Leaf) {
        Ok ("{0}：保留已有配置。" -f $package)
        return $true
    }
    try {
        $document = Get-Content -LiteralPath $examplePath -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($null -eq $document.config -or $document.config -is [array] -or
            $document.config.PSObject.Properties.Name -notcontains 'gradient' -or
            $null -eq $document.config.gradient -or $document.config.gradient -is [array] -or
            $document.config.gradient -is [bool]) {
            return $false
        }
        Add-Member -InputObject $document.config.gradient -MemberType NoteProperty -Name enabled -Value $false -Force
        [IO.File]::WriteAllText($configPath, ($document | ConvertTo-Json -Depth 50), [System.Text.UTF8Encoding]::new($false))
        Ok ("{0}：已由 config.example.json 初始化配置并关闭默认渐变；可在设置页重新开启。" -f $package)
        return $true
    }
    catch {
        Warn ("{0}：默认配置初始化失败：{1}" -f $package, $_.Exception.Message)
        return $false
    }
}

function Invoke-PluginPostInstall([string]$profile, [object]$plugin) {
    $hook = [string]$plugin.PostInstall
    if ([string]::IsNullOrWhiteSpace($hook)) { return }
    switch ($hook) {
        'InitializeExampleGradientConfig' { Initialize-ExampleGradientConfig $profile ([string]$plugin.Package) | Out-Null }
        default { Warn ("未识别的动态 PostInstall hook：{0}（插件 {1}）" -f $hook, $plugin.Name) }
    }
}

# Dream Skin 的持久化能力不能仅靠 semver 判断：上游主版本可以变化，
# 因此仍以 sticky-restore 文本标识和 host-backed API 同时存在作为能力证据。
function Test-DreamSkinPersistenceFix([string]$profile) {
    $client = Join-Path $dshHome ("profiles\{0}\node_modules\dsh-dream-skin\lib\client.js" -f $profile)
    if (-not (Test-Path -LiteralPath $client -PathType Leaf)) { return $false }
    try {
        $text = Get-Content -LiteralPath $client -Raw -Encoding UTF8
        $hasStickyRestore = $text.Contains('dsh-dream-skin: sticky skin restore') -or
            $text.Contains('dsh-dream-skin: sticky skin + built-in restore')
        return ($hasStickyRestore -and $text.Contains('/dream-skin/api'))
    } catch { return $false }
}

function Resolve-PluginInstallPlan([string]$profile, [object[]]$selected) {
    $document = Get-DshPluginEcosystem $profile $DefaultDshVersion -Refresh
    if (-not $document) { return @() }
    $catalog = @(Get-DynamicPluginCatalog $profile $DefaultDshVersion)
    $byPackage = @{}
    foreach ($plugin in $catalog) { $byPackage[[string]$plugin.Package] = $plugin }
    $wanted = @{}
    $queue = New-Object System.Collections.Queue
    foreach ($plugin in @($selected)) { if ($plugin -and $plugin.Package) { $queue.Enqueue([string]$plugin.Package) } }
    while ($queue.Count -gt 0) {
        $package = [string]$queue.Dequeue()
        if ($wanted.ContainsKey($package)) { continue }
        if (-not $byPackage.ContainsKey($package)) { throw "扫描矩阵中不存在插件：$package" }
        $wanted[$package] = $true
        foreach ($dependency in @($byPackage[$package].DependsOn)) { $queue.Enqueue([string]$dependency) }
    }
    $plan = @()
    foreach ($package in @($document.installOrder)) {
        if ($wanted.ContainsKey([string]$package) -and $byPackage.ContainsKey([string]$package)) {
            $plan += $byPackage[[string]$package]
        }
    }
    return @($plan)
}

function Install-Plugins([string]$profile, [object[]]$selected) {
    # 日常插件安装只确认 package 安装成功，绝不启动用户真实 Profile；完整兼容
    # 必须在 Test-DshPluginEcosystemPreflight.ps1 的临时环境中取得证据。
    if (-not $selected -or $selected.Count -eq 0) { return }
    $plan = @(Resolve-PluginInstallPlan $profile $selected)
    if ($plan.Count -eq 0) { Warn '无法从真实插件生态计算安装计划。'; return }
    $blocked = @($plan | Where-Object { $_.Status -eq 'BLOCKED' })
    if ($blocked.Count -gt 0) {
        Warn ('拒绝安装硬阻断插件：' + (($blocked | ForEach-Object Package) -join '、'))
        return
    }
    $floating = @($plan | Where-Object { $_.Floating })
    if ($floating.Count -gt 0) {
        Warn ('以下 GitHub 源没有已解析 commit，管理器不会自动重新安装：' + (($floating | ForEach-Object Package) -join '、'))
        Warn '如需继续，请在“自定义 package/spec”中明确输入 tag 或 commit，再重新扫描与 preflight。'
        return
    }
    $notPass = @($plan | Where-Object { $_.Status -ne 'PASS' })
    if ($notPass.Count -gt 0) {
        $message = '安装计划包含非 PASS 项：' + (($notPass | ForEach-Object { $_.Package + '[' + $_.Status + ']' }) -join '、')
        if ($NonInteractive) { Warn ($message + '；非交互模式拒绝把它们当作兼容项安装。'); return }
        Warn $message
        if (-not (Read-YesNo '明确继续？安装完成后状态仍不是兼容 PASS。' $false)) { return }
    }

    $failures = @()
    foreach ($plugin in $plan) {
        if ([string]::IsNullOrWhiteSpace([string]$plugin.InstallSpec)) {
            $failures += [string]$plugin.Package
            Warn "缺少精确安装 spec：$($plugin.Package)"
            continue
        }
        Say "按依赖顺序安装：$($plugin.Package) [$($plugin.InstallSpec)]"
        $code = Invoke-ManagedDsh $profile @('plugin','--profile',$profile,'add',[string]$plugin.InstallSpec)
        if ($code -ne 0) {
            $failures += [string]$plugin.Package
            Warn "安装失败：$($plugin.Package)（退出码 $code）"
            break
        }
        Ok "已安装：$($plugin.Package)；仍需精确 preflight 才能取得 PASS。"
        Invoke-PluginPostInstall $profile $plugin
    }
    Clear-DshPluginEcosystemCache $profile
    if ($failures.Count -gt 0) {
        Warn ('安装在第一个失败项停止：' + ($failures -join '、'))
        return
    }
    Say '安装事务完成。请运行 Test-DshPluginEcosystemPreflight.ps1；日常安装从不自动把 WARN / UNKNOWN 提升为 PASS。'
}

function Get-TransitivePluginDependents([object[]]$catalog, [string]$package) {
    $byPackage = @{}
    foreach ($item in $catalog) { $byPackage[[string]$item.Package] = $item }
    if (-not $byPackage.ContainsKey($package)) { return @() }
    $seen = @{}
    $queue = New-Object System.Collections.Queue
    $queue.Enqueue($package)
    while ($queue.Count -gt 0) {
        $current = [string]$queue.Dequeue()
        if ($seen.ContainsKey($current)) { continue }
        $seen[$current] = $true
        foreach ($dependent in @($byPackage[$current].Dependents)) {
            if ($byPackage.ContainsKey([string]$dependent)) { $queue.Enqueue([string]$dependent) }
        }
    }
    return @($seen.Keys)
}

function Remove-PluginWithDependents([string]$profile, [string]$package) {
    $document = Get-DshPluginEcosystem $profile $DefaultDshVersion -Refresh
    $catalog = @(Get-DynamicPluginCatalog $profile $DefaultDshVersion)
    if (-not $document -or $catalog.Count -eq 0) { Warn '没有可用的真实插件矩阵。'; return }
    $toRemove = @(Get-TransitivePluginDependents $catalog $package)
    if ($toRemove.Count -eq 0) { Warn "未找到插件：$package"; return }
    $reverseOrder = @($document.installOrder | Where-Object { $toRemove -contains [string]$_ })
    [array]::Reverse($reverseOrder)
    Warn ('卸载将连锁移除：' + ($reverseOrder -join ' → '))
    if (-not $NonInteractive -and -not (Read-YesNo '确认连锁卸载这些插件？' $false)) { return }
    foreach ($name in $reverseOrder) {
        Say "卸载：$name"
        $code = Invoke-ManagedDsh $profile @('plugin','--profile',$profile,'remove',[string]$name)
        if ($code -ne 0) { Warn "卸载失败：$name（退出码 $code）；停止后续卸载。"; break }
        Ok "已卸载：$name"
    }
    Clear-DshPluginEcosystemCache $profile
    $after = Get-DshPluginEcosystem $profile $DefaultDshVersion -Refresh
    if ($after -and @($after.profile.patchOrphans).Count -gt 0) {
        Warn ('官方 remove 后仍检测到孤立 patch id：' + (@($after.profile.patchOrphans) -join '、') + '。不会自动删配置；请先核对再处理。')
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
    Write-Host "已测版本: $($TestedDshVersions -join ', ')"
    Write-Host "已确认 --no-open: $($KnownNoOpenDshVersions -join ', ')"
    Write-Host "Profile:  $profile"
    $profileDir = Join-Path $dshHome "profiles\$profile"
    Write-Host "Profile 目录: $(if (Test-Path $profileDir) {'存在'} else {'尚未创建'})"
    try {
        $code = Invoke-ManagedDsh $profile @('plugin','--profile',$profile,'list')
        if ($code -ne 0) { Warn 'plugin list 返回非 0。' }
    } catch { Warn $_.Exception.Message }
    Show-PluginCatalog $profile | Out-Null

    # Dream Skin 持久化修复状态：不同主版本的 marker 文本不同，必须查能力而非只看版本号。
    $dreamSkinDir = Join-Path $dshHome "profiles\$profile\node_modules\dsh-dream-skin"
    if (Test-Path -LiteralPath $dreamSkinDir -PathType Container) {
        if (Test-DreamSkinPersistenceFix $profile) {
            Ok 'Dream Skin：持久化修复已安装'
        } else {
            Warn 'Dream Skin：检测到缺少持久化能力的旧实现。请先扫描真实矩阵、选择精确安装 spec 并完成 preflight。'
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
    $npxSelection = $null

    if ($existing) {
        $gated = Resolve-DshCommandWithGate $existing
        if ($gated) {
            $resolved = $gated
            Ok "使用现有 DSH：$($resolved.Path)$(if ($resolved.Version) { "  ($($resolved.Version))" } else { '' })"
        } else {
            $npxSelection = Select-NpxDshVersion $current.Version
            if (-not $npxSelection) {
                Warn '已取消选择 npx DSH 版本；不会写入设置。'
                return $false
            }
            $resolved = Prepare-NpxDsh $npxSelection.Version
        }
    } else {
        $npxSelection = Select-NpxDshVersion $current.Version
        if (-not $npxSelection) {
            Warn '已取消选择 npx DSH 版本；不会写入设置。'
            return $false
        }
        $resolved = Prepare-NpxDsh $npxSelection.Version
    }

    $profile = Resolve-ProfileForNpxSelection $npxSelection $current.Profile -PromptForProfile
    if (-not $profile) {
        Warn '已取消 Profile 选择；不会写入设置。'
        return $false
    }
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
    if (-not (Test-DshUpgradeAllowed $profile $current.Version $resolved.Version)) {
        Warn '未写入新 DSH 版本设置。'
        return $false
    }
    Save-DesktopSettings $resolved.Path $resolved.Version $profile $webPort $work $close $dev $resolved.Mode $acceptedPath $acceptedVer
    # 只有用户完成版本/Profile/设置选择并且新设置已成功保存后，才清理旧草案运行时。
    # 因此在向导中取消不会修改用户的现有 DSH 目录。
    Remove-LegacyPrivateRuntime

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

    $selected = Select-Plugins $profile $profileExisted
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
    return $true
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
        Write-Host '  6. 卸载插件（自动列出所有下游）'
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
                        if (Test-DshUpgradeAllowed $current.Profile $current.Version $gated.Version) {
                            Save-DesktopSettings $gated.Path $gated.Version $current.Profile $current.Port $current.Work $current.Close $current.Dev $gated.Mode $gated.AcceptedPath $gated.AcceptedVersion
                        }
                    } else {
                        Write-Host '改用官方 npx 运行方式（已持久化为仅 npx，不会再回捡 PATH 里的 dsh）。'
                        $v = Select-NpxDshVersion $current.Version
                        if ($v) {
                            $profile = Resolve-ProfileForNpxSelection $v $current.Profile
                            if ($profile) {
                                $resolved = Prepare-NpxDsh $v.Version
                                if (Test-DshUpgradeAllowed $profile $current.Version $resolved.Version) {
                                    Save-DesktopSettings $null $resolved.Version $profile $current.Port $current.Work $current.Close $current.Dev 'npx' '' ''
                                }
                            } else {
                                Warn '已取消隔离 Profile 选择，未修改桌面设置。'
                            }
                        } else {
                            Warn '已取消选择 npx 版本，未修改桌面设置。'
                        }
                    }
                } else {
                    Write-Host '系统 PATH 中没有 dsh；DesktopShell 使用官方 npx 运行方式。'
                    $v = Select-NpxDshVersion $current.Version
                    if ($v) {
                        $profile = Resolve-ProfileForNpxSelection $v $current.Profile
                        if ($profile) {
                            $resolved = Prepare-NpxDsh $v.Version
                            if (Test-DshUpgradeAllowed $profile $current.Version $resolved.Version) {
                                Save-DesktopSettings $null $resolved.Version $profile $current.Port $current.Work $current.Close $current.Dev 'npx' '' ''
                            }
                        } else {
                            Warn '已取消隔离 Profile 选择，未修改桌面设置。'
                        }
                    } else {
                        Warn '已取消选择 npx 版本，未修改桌面设置。'
                    }
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
                $selected = Select-Plugins $current.Profile (Test-Path -LiteralPath $profilePackage)
                Install-Plugins $current.Profile $selected
            }
            '4' { Show-Diagnostics $current.Profile }
            '5' {
                # 自定义 spec 独立入口：不要求先选内置插件（“额外插件”提示只在选中内置项后出现）
                $raw = Read-Host '粘贴自定义 package/spec（多个用分号分隔；例如 pkg@1.2.3 或 GitHub tar 链接）'
                $specs = @($raw -split ';' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
                if ($specs.Count -eq 0) { Warn '未输入任何 spec。'; break }
                foreach ($s in $specs) {
                    if ($s -match '(?i)(?:@|#)latest(?:$|\s)') {
                        Warn 'latest 仅作为用户显式选择的可选通道；安装后不会自动标为推荐或兼容。'
                    }
                    Say "安装自定义插件：$s"
                    $code = Invoke-ManagedDsh $current.Profile @('plugin','--profile',$current.Profile,'add',$s)
                    if ($code -ne 0) { Warn "安装失败：$s（退出码 $code）" }
                    else { Ok "已安装：$s（仅安装成功，尚未证明运行兼容）" }
                }
                Clear-DshPluginEcosystemCache $current.Profile
                Warn '安装成功 ≠ 运行兼容：日常安装不会启动用户真实 Profile。完整 BootReady 验收请使用独立 release preflight（临时 DSH_HOME/Profile/随机端口）。'
                Say '插件安装/更新完成。新插件与更新默认在 DSH 后端重启后生效：托盘图标 → 重启 DSH 后端。'
            }
            '6' {
                $catalog = @(Show-PluginCatalog $current.Profile)
                if ($catalog.Count -eq 0) { break }
                $raw = Read-Host '输入要卸载的插件编号（父插件会连锁列出下游；留空取消）'
                $number = 0
                if (-not [int]::TryParse($raw, [ref]$number)) { Warn '未选择有效插件。'; break }
                $plugin = @($catalog | Where-Object { $_.No -eq $number } | Select-Object -First 1)
                if ($plugin.Count -eq 0) { Warn '未找到该插件编号。'; break }
                Remove-PluginWithDependents $current.Profile ([string]$plugin[0].Package)
            }
            '0' { return }
            default { Warn '无效选择。' }
        }
        if ($choice -ne '0') { Write-Host ''; Read-Host '按 Enter 继续' | Out-Null }
    }
}

try {
    if ($FirstInstall) {
        $completed = Guided-Setup
        if (-not $completed) {
            # 2 是安装核心识别的“用户正常取消”信号：不把取消误报为初始化/编译失败。
            Write-Host ''
            Warn '初始化向导已取消；DesktopShell 和现有 DSH 设置均未提交新更改。'
            exit 2
        }
    }
    else { Interactive-Menu }
    exit 0
} catch {
    Write-Host ''
    Write-Host "失败：$($_.Exception.Message)" -ForegroundColor Red
    if (-not $NonInteractive) { Write-Host ''; Read-Host '按 Enter 退出' | Out-Null }
    exit 1
}
