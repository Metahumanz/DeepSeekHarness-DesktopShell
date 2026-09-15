[CmdletBinding()]
param(
    [string]$DshHome = '',
    [string]$Profile = 'web',
    [string]$DshVersion = '0.1.5-rc.2',
    [string]$OutputResults = '',
    [int]$TimeoutSeconds = 120,
    [int]$StableSeconds = 10,
    [switch]$KeepTemp
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

if ($DshVersion -ne '0.1.5-rc.2') {
    throw '本轮生态 preflight 只接受固定目标 DSH 0.1.5-rc.2。'
}
if ($Profile -notmatch '^[A-Za-z0-9_-]+$') { throw 'Profile 必须是安全的单段名称。' }
if ([string]::IsNullOrWhiteSpace($DshHome)) {
    $DshHome = if ($env:DSH_HOME) { $env:DSH_HOME } else { Join-Path ([Environment]::GetFolderPath('UserProfile')) '.dsh' }
}
$DshHome = [IO.Path]::GetFullPath($DshHome)
$profileDirectory = Join-Path $DshHome (Join-Path 'profiles' $Profile)
$profilePatch = Join-Path $profileDirectory 'cordis.patch.yml'
if (-not (Test-Path -LiteralPath $profilePatch -PathType Leaf)) { throw "找不到 Profile patch：$profilePatch" }

$scanner = Join-Path $PSScriptRoot 'Scan-DshPluginEcosystem.ps1'
$singlePreflight = Join-Path $PSScriptRoot 'Test-PluginBootPreflight.ps1'
$webView2Acceptance = Join-Path $PSScriptRoot 'Test-DshWebView2Acceptance.ps1'
if (-not (Test-Path -LiteralPath $scanner -PathType Leaf) -or -not (Test-Path -LiteralPath $singlePreflight -PathType Leaf) -or -not (Test-Path -LiteralPath $webView2Acceptance -PathType Leaf)) {
    throw '生态 preflight 所需的扫描器、单插件 preflight 或 WebView2 验收脚本不存在。'
}
if ([string]::IsNullOrWhiteSpace($OutputResults)) {
    # 生产安装目录通常不可写；默认把 token-free 证据放在当前 Profile 旁，供
    # Manage-Dsh 的后续升级门禁读取。仓库/CI 需要提交快照时可显式传 -OutputResults docs\...。
    $OutputResults = Join-Path $DshHome (Join-Path 'profiles' (Join-Path $Profile '.dsh-desktop-shell\PLUGIN_PREFLIGHT_0.1.5-rc.2.json'))
}

function Get-RiskScore([object]$plugin) {
    $text = ((@($plugin.requiresService) + @($plugin.observedServiceInject) + @($plugin.dshClientInject) + @($plugin.package)) -join ' ').ToLowerInvariant()
    if ($text -match 'session|agent|permission|credential|remote|webserver|invariant') { return 30 }
    if ($text -match 'settings|workspace|tools|skill') { return 20 }
    if ($text -match 'theme|skin|css|style') { return 5 }
    return 10
}

function Get-DependencyOrder([object[]]$plugins) {
    $byPackage = @{}
    foreach ($plugin in $plugins) { $byPackage[[string]$plugin.package] = $plugin }
    $remaining = @{}
    foreach ($plugin in $plugins) {
        $required = @($plugin.dependsOn | Where-Object { $byPackage.ContainsKey([string]$_) })
        $remaining[[string]$plugin.package] = @($required)
    }
    $result = @()
    while ($remaining.Count -gt 0) {
        $ready = @($remaining.Keys | Where-Object { @($remaining[$_]).Count -eq 0 } |
            Sort-Object @{ Expression = { -1 * (Get-RiskScore $byPackage[$_]) } }, @{ Expression = { $_ } })
        if ($ready.Count -eq 0) {
            # 循环依赖本身是阻断证据；保持稳定输出，让后续记录指出问题而非随机安装。
            $result += @($remaining.Keys | Sort-Object)
            break
        }
        foreach ($package in $ready) {
            $result += $package
            $remaining.Remove($package)
            foreach ($other in @($remaining.Keys)) {
                $remaining[$other] = @($remaining[$other] | Where-Object { $_ -ne $package })
            }
        }
    }
    return @($result)
}

function Get-DependencyChain([string]$package, [hashtable]$byPackage, [string[]]$installOrder) {
    # 每个插件都在新的临时 Profile 中验证，但只带入它实际需要的父链；
    # 不能把此前不相关的插件反复重装进每一轮，从而把 12 项扫描膨胀成 N² 次安装。
    $needed = @{}
    $queue = New-Object System.Collections.Queue
    $queue.Enqueue($package)
    while ($queue.Count -gt 0) {
        $current = [string]$queue.Dequeue()
        if ($needed.ContainsKey($current)) { continue }
        if (-not $byPackage.ContainsKey($current)) { throw "依赖图缺少插件：$current" }
        $needed[$current] = $true
        foreach ($parent in @($byPackage[$current].dependsOn)) {
            if ($byPackage.ContainsKey([string]$parent)) { $queue.Enqueue([string]$parent) }
        }
    }
    return @($installOrder | Where-Object { $needed.ContainsKey([string]$_) })
}

function New-Result([object]$plugin, [string]$status, [string]$reason, [object]$checks) {
    return [pscustomobject]@{
        package = [string]$plugin.package
        version = [string]$plugin.version
        targetDshVersion = $DshVersion
        installSpec = [string]$plugin.installSpec
        status = $status
        reason = $reason
        checks = $checks
        dependsOn = @($plugin.dependsOn)
        requiresService = @($plugin.requiresService)
    }
}

function New-EmptyChecks {
    return [pscustomobject]@{
        bootReady = $false
        pluginTree = $false
        http = $false
        restart = $false
        webView2 = $false
        refresh = $false
        settings = $false
    }
}

$workingRoot = Join-Path ([IO.Path]::GetTempPath()) ('dsh-ecosystem-preflight-' + [guid]::NewGuid().ToString('N'))
$scanPath = Join-Path $workingRoot 'scan.json'
$results = @()
$fullCombination = $null
$exitCode = 0

try {
    New-Item -ItemType Directory -Force -Path $workingRoot | Out-Null
    # 此扫描仍读取真实 package/patch/source，但不为 preflight 的排序重复访问上游网络。
    $scan = & $scanner -DshHome $DshHome -Profile $Profile -DshVersion $DshVersion -Offline -SkipPluginList -PassThru
    if (@($scan.profile.patchOrphans).Count -gt 0) {
        $reason = 'Profile patch 存在没有已安装 provider 的 id：' + (@($scan.profile.patchOrphans) -join ', ')
        $fullCombination = [pscustomobject]@{ status='BLOCKED'; reason=$reason; checks=(New-EmptyChecks) }
        $exitCode = 1
        throw $reason
    }

    $plugins = @($scan.plugins)
    $byPackage = @{}
    foreach ($plugin in $plugins) { $byPackage[[string]$plugin.package] = $plugin }
    $blocked = @{}
    $fullSpecs = @()
    $installOrder = @(Get-DependencyOrder $plugins)
    foreach ($package in $installOrder) {
        $plugin = $byPackage[$package]
        $blockedParents = @($plugin.dependsOn | Where-Object { $blocked.ContainsKey([string]$_) })
        if ($blockedParents.Count -gt 0) {
            $blocked[$package] = $true
            $results += New-Result $plugin 'BLOCKED' ('上游依赖链已阻断：' + ($blockedParents -join ', ')) (New-EmptyChecks)
            continue
        }
        if ($plugin.status -eq 'BLOCKED') {
            $blocked[$package] = $true
            $results += New-Result $plugin 'BLOCKED' (($plugin.evidence -join '；')) (New-EmptyChecks)
            continue
        }
        if ([string]::IsNullOrWhiteSpace([string]$plugin.installSpec)) {
            $blocked[$package] = $true
            $results += New-Result $plugin 'BLOCKED' '无法从真实已安装版本生成可复现安装 spec。' (New-EmptyChecks)
            continue
        }

        $chainPackages = @(Get-DependencyChain $package $byPackage $installOrder)
        $chainSpecs = @()
        foreach ($chainPackage in $chainPackages) {
            $chainPlugin = $byPackage[[string]$chainPackage]
            if ([string]::IsNullOrWhiteSpace([string]$chainPlugin.installSpec)) {
                throw "依赖链缺少可复现安装 spec：$chainPackage"
            }
            $chainSpecs += [string]$chainPlugin.installSpec
        }
        $singleResultPath = Join-Path $workingRoot (($package -replace '[^A-Za-z0-9._-]', '_') + '.json')
        Write-Host ("ECOSYSTEM PREFLIGHT add package={0} risk={1} dependencyChain={2}" -f $package, (Get-RiskScore $plugin), ($chainPackages -join ','))
        & $singlePreflight -PluginSpec $chainSpecs -DshVersion $DshVersion `
            -TimeoutSeconds $TimeoutSeconds -StableSeconds $StableSeconds -RequireWebView2Settings -ResultPath $singleResultPath
        $singleCode = $LASTEXITCODE
        $single = if (Test-Path -LiteralPath $singleResultPath -PathType Leaf) {
            Get-Content -LiteralPath $singleResultPath -Raw -Encoding UTF8 | ConvertFrom-Json
        } else { $null }
        if ($singleCode -eq 0 -and $single -and $single.status -eq 'PASS') {
            $fullSpecs += [string]$plugin.installSpec
            $results += New-Result $plugin 'PASS' '依赖链隔离 preflight 已通过 BootReady、plugin tree、HTTP、WebView2、刷新、设置页和重启。' $single.checks
        }
        else {
            $blocked[$package] = $true
            $reason = if ($single -and $single.reason) { [string]$single.reason } else { "隔离 preflight 失败（exitCode=$singleCode）。" }
            $results += New-Result $plugin 'BLOCKED' $reason (if ($single) { $single.checks } else { New-EmptyChecks })
        }
    }

    if ($fullSpecs.Count -gt 0) {
        $fullResultPath = Join-Path $workingRoot 'full-combination.json'
        Write-Host ("ECOSYSTEM PREFLIGHT full-combination plugins={0}" -f $fullSpecs.Count)
        & $singlePreflight -PluginSpec $fullSpecs -DshVersion $DshVersion -TimeoutSeconds $TimeoutSeconds `
            -StableSeconds $StableSeconds -RequireWebView2Settings -ProfilePatchPath $profilePatch -ResultPath $fullResultPath
        $fullCode = $LASTEXITCODE
        $full = if (Test-Path -LiteralPath $fullResultPath -PathType Leaf) {
            Get-Content -LiteralPath $fullResultPath -Raw -Encoding UTF8 | ConvertFrom-Json
        } else { $null }
        $fullCombination = [pscustomobject]@{
            installSpecs = @($fullSpecs)
            status = if ($fullCode -eq 0 -and $full -and $full.status -eq 'PASS') { 'PASS' } else { 'BLOCKED' }
            reason = if ($fullCode -eq 0 -and $full -and $full.status -eq 'PASS') {
                '完整组合 preflight 已通过 BootReady、plugin tree、HTTP、WebView2、刷新、设置页和重启。'
            } elseif ($full -and $full.reason) { [string]$full.reason } else { "完整组合 preflight 失败（exitCode=$fullCode）。" }
            checks = if ($full) { $full.checks } else { New-EmptyChecks }
        }
        if ($fullCombination.status -eq 'BLOCKED') { $exitCode = 1 }
    }
    else {
        $fullCombination = [pscustomobject]@{ status='BLOCKED'; reason='没有可以组成完整 Profile 的插件。'; checks=(New-EmptyChecks) }
        $exitCode = 1
    }
}
catch {
    if (-not $fullCombination) {
        $fullCombination = [pscustomobject]@{ status='BLOCKED'; reason=$_.Exception.Message; checks=(New-EmptyChecks) }
    }
    $exitCode = 1
}
finally {
    $document = [pscustomobject]@{
        schemaVersion = 2
        generatedAt = [DateTime]::UtcNow.ToString('o')
        targetDshVersion = $DshVersion
        profile = $Profile
        results = @($results)
        fullCombination = $fullCombination
    }
    $outputDirectory = Split-Path -Parent $OutputResults
    if ($outputDirectory) { New-Item -ItemType Directory -Force -Path $outputDirectory | Out-Null }
    [IO.File]::WriteAllText($OutputResults, ($document | ConvertTo-Json -Depth 20), [System.Text.UTF8Encoding]::new($false))
    if ($KeepTemp) { Write-Host "ECOSYSTEM PREFLIGHT evidence=$workingRoot" }
    else { Remove-Item -LiteralPath $workingRoot -Recurse -Force -ErrorAction SilentlyContinue }
}

if ($exitCode -eq 0) {
    Write-Host "ECOSYSTEM PREFLIGHT PASSED all-required-ui-evidence results=$OutputResults"
    exit 0
}
Write-Host "ECOSYSTEM PREFLIGHT FAILED results=$OutputResults"
exit 1
