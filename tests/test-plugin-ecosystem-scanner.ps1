$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$scanner = Join-Path $repo 'scripts\Scan-DshPluginEcosystem.ps1'
$tempHome = Join-Path ([IO.Path]::GetTempPath()) ('dsh-plugin-graph-fixture-' + [guid]::NewGuid().ToString('N'))
$profileDir = Join-Path $tempHome 'profiles\web'

$fail = 0
function Assert-True([string]$label, [bool]$condition) {
    if ($condition) { Write-Host "PASS: $label" }
    else { $script:fail++; Write-Host "FAIL: $label" }
}
function Write-Utf8([string]$path, [string]$content) {
    $parent = Split-Path -Parent $path
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
    [IO.File]::WriteAllText($path, $content, [Text.UTF8Encoding]::new($false))
}

try {
    $sidebar = Join-Path $profileDir 'node_modules\dsh-better-sidebar'
    $video = Join-Path $profileDir 'node_modules\dsh-video-preview'
    New-Item -ItemType Directory -Force -Path $sidebar, $video | Out-Null
    Write-Utf8 (Join-Path $profileDir 'package.json') @'
{
  "name": "web",
  "dependencies": {
    "dsh-better-sidebar": "github:example/dsh-better-sidebar",
    "dsh-video-preview": "1.0.0"
  }
}
'@
    Write-Utf8 (Join-Path $profileDir 'pnpm-lock.yaml') @'
lockfileVersion: '9.0'
importers:
  .:
    dependencies:
      dsh-better-sidebar:
        specifier: github:example/dsh-better-sidebar
        version: https://codeload.github.com/example/dsh-better-sidebar/tar.gz/1111111111111111111111111111111111111111
'@
    Write-Utf8 (Join-Path $profileDir 'cordis.patch.yml') @'
- id: better-sidebar
- id: video-preview
'@
    Write-Utf8 (Join-Path $sidebar 'package.json') @'
{
  "name": "dsh-better-sidebar",
  "version": "1.0.0",
  "repository": "https://github.com/example/dsh-better-sidebar",
  "dsh": { "bundle": "cordis.patch.yml" }
}
'@
    Write-Utf8 (Join-Path $sidebar 'cordis.patch.yml') "- id: better-sidebar`n"
    Write-Utf8 (Join-Path $sidebar 'index.js') @'
export const inject = ['webServer']
export function apply(ctx) { ctx.provide('betterSidebar', {}) }
'@
    Write-Utf8 (Join-Path $video 'package.json') @'
{
  "name": "dsh-video-preview",
  "version": "1.0.0",
  "dsh": { "bundle": "cordis.patch.yml" }
}
'@
    Write-Utf8 (Join-Path $video 'cordis.patch.yml') "- id: video-preview`n"
    Write-Utf8 (Join-Path $video 'index.js') @'
export const inject = ['betterSidebar']
export function apply() { }
'@

    $matrix = & $scanner -DshHome $tempHome -Profile web -DshVersion '0.1.5-rc.2' -Offline -SkipPluginList -PassThru
    if ($LASTEXITCODE -ne 0) { throw "scanner exit code: $LASTEXITCODE" }
    $parent = @($matrix.plugins | Where-Object { $_.package -eq 'dsh-better-sidebar' })[0]
    $child = @($matrix.plugins | Where-Object { $_.package -eq 'dsh-video-preview' })[0]

    Assert-True 'fixture returns both installed packages' (@($matrix.plugins).Count -eq 2 -and $parent -and $child)
    Assert-True 'service provider is discovered from Cordis source' (@($parent.providesService) -contains 'betterSidebar')
    Assert-True 'Git package uses the exact commit locked by the real profile lockfile format' (
        $parent.gitHead -eq '1111111111111111111111111111111111111111' -and
        $parent.gitHeadSource -eq 'pnpm-lock.yaml' -and
        $parent.installSpec -eq 'github:example/dsh-better-sidebar#1111111111111111111111111111111111111111')
    Assert-True 'Video Preview has a hard betterSidebar service dependency' (@($child.requiresService) -contains 'betterSidebar')
    Assert-True 'service dependency becomes plugin graph edge' (@($child.dependsOn) -contains 'dsh-better-sidebar')
    Assert-True 'reverse graph identifies Video Preview as a downstream plugin' (@($parent.dependents) -contains 'dsh-video-preview')
    Assert-True 'install order installs provider before consumer' (
        [array]::IndexOf(@($matrix.installOrder), 'dsh-better-sidebar') -lt
        [array]::IndexOf(@($matrix.installOrder), 'dsh-video-preview'))
    Assert-True 'matching patch ids are not reported as orphaned' (@($matrix.profile.patchOrphans).Count -eq 0)
    Assert-True 'no metadata/preflight proof is not upgraded to compatible PASS' (
        $parent.status -in @('UNKNOWN', 'WARN') -and $child.status -in @('UNKNOWN', 'WARN'))
}
finally {
    if (Test-Path -LiteralPath $tempHome) { Remove-Item -LiteralPath $tempHome -Recurse -Force -ErrorAction SilentlyContinue }
}

if ($fail -eq 0) { Write-Host 'PLUGIN ECOSYSTEM SCANNER TESTS PASSED' }
else { Write-Host "FAILURES: $fail" }
exit $(if ($fail -eq 0) { 0 } else { 1 })
