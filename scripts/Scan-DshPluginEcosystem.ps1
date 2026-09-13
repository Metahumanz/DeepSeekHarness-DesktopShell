[CmdletBinding()]
param(
    [string]$DshHome = '',
    [string]$Profile = 'web',
    [string]$DshVersion = '0.1.5-rc.2',
    [string]$OutputJson = '',
    [string]$OutputMarkdown = '',
    [string]$PreflightResults = '',
    [switch]$Offline,
    [switch]$SkipPluginList,
    [switch]$PassThru
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

function Assert-SafeProfileName([string]$Value) {
    if ([string]::IsNullOrWhiteSpace($Value) -or $Value -notmatch '^[A-Za-z0-9_-]+$') {
        throw 'Profile 必须是安全的单段名称。'
    }
    return $Value
}

function Assert-DshVersion([string]$Value) {
    if ([string]::IsNullOrWhiteSpace($Value) -or $Value -notmatch '^\d+\.\d+\.\d+(?:-[A-Za-z0-9._+-]+)?$') {
        throw 'DshVersion 必须是精确的 semver/预发布版本，例如 0.1.5-rc.2。'
    }
    return $Value
}

$Profile = Assert-SafeProfileName $Profile
$DshVersion = Assert-DshVersion $DshVersion
if ([string]::IsNullOrWhiteSpace($DshHome)) {
    $DshHome = if ($env:DSH_HOME) { $env:DSH_HOME } else { Join-Path ([Environment]::GetFolderPath('UserProfile')) '.dsh' }
}
$DshHome = [IO.Path]::GetFullPath($DshHome)
$profileDirectory = Join-Path $DshHome (Join-Path 'profiles' $Profile)
if (-not (Test-Path -LiteralPath (Join-Path $profileDirectory 'package.json') -PathType Leaf)) {
    throw "找不到真实 DSH Profile package.json：$profileDirectory"
}

$node = Get-Command node.exe -ErrorAction SilentlyContinue
if (-not $node) { $node = Get-Command node -ErrorAction SilentlyContinue }
if (-not $node) { throw '扫描 DSH 插件生态需要 Node.js。' }
$scanner = Join-Path $PSScriptRoot 'Scan-DshPluginEcosystem.cjs'
if (-not (Test-Path -LiteralPath $scanner -PathType Leaf)) { throw "找不到扫描器：$scanner" }

$temporaryOutput = $false
if ([string]::IsNullOrWhiteSpace($OutputJson)) {
    $OutputJson = Join-Path ([IO.Path]::GetTempPath()) ('dsh-plugin-ecosystem-' + [guid]::NewGuid().ToString('N') + '.json')
    $temporaryOutput = $true
}

$nodeArgs = @(
    $scanner,
    '--dsh-home', $DshHome,
    '--profile', $Profile,
    '--target-version', $DshVersion,
    '--output-json', $OutputJson
)
if (-not [string]::IsNullOrWhiteSpace($OutputMarkdown)) { $nodeArgs += @('--output-markdown', $OutputMarkdown) }
if (-not [string]::IsNullOrWhiteSpace($PreflightResults)) { $nodeArgs += @('--preflight-results', $PreflightResults) }
if ($Offline) { $nodeArgs += '--offline' }
if (-not $SkipPluginList) { $nodeArgs += '--run-plugin-list' }

try {
    & $node.Source @nodeArgs | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "插件生态扫描器返回退出码 $LASTEXITCODE。" }
    if (-not (Test-Path -LiteralPath $OutputJson -PathType Leaf)) { throw '插件生态扫描器未产生 JSON 输出。' }
    $document = Get-Content -LiteralPath $OutputJson -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($PassThru) { return $document }

    Write-Host ("PLUGIN ECOSYSTEM target={0} plugins={1} profileStatus={2}" -f
        $document.targetDshVersion, @($document.plugins).Count, $document.profile.status)
    foreach ($plugin in @($document.plugins)) {
        Write-Host ("  {0}@{1} status={2}" -f $plugin.package, $plugin.version, $plugin.status)
    }
}
finally {
    if ($temporaryOutput) { Remove-Item -LiteralPath $OutputJson -Force -ErrorAction SilentlyContinue }
}
