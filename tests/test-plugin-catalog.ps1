$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$manage = [IO.File]::ReadAllText((Join-Path $repo 'scripts\Manage-Dsh.ps1'))
$scanner = [IO.File]::ReadAllText((Join-Path $repo 'scripts\Scan-DshPluginEcosystem.cjs'))
$wrapper = [IO.File]::ReadAllText((Join-Path $repo 'scripts\Scan-DshPluginEcosystem.ps1'))

$fail = 0
function Assert-True([string]$label, [bool]$condition) {
    if ($condition) { Write-Host "PASS: $label" }
    else { $script:fail++; Write-Host "FAIL: $label" }
}

Assert-True 'catalog is dynamically initialized rather than populated with a static plugin table' (
    $manage.Contains('$PluginCatalog = @()') -and
    $manage -notmatch "Id='(?:market|sidebar|video|skills)'" -and
    $manage -notmatch "Spec='(?:github:|git\+https://github\.com/)" )
Assert-True 'scanner reads the real Profile package, installed packages and patch layer' (
    $scanner.Contains("path.join(profileDirectory, 'package.json')") -and
    $scanner.Contains("path.join(profileDirectory, 'node_modules'") -and
    $scanner.Contains("path.join(profileDirectory, 'cordis.patch.yml')") -and
    $scanner.Contains('readPinnedGitHeadsFromPnpmLock') -and
    $scanner.Contains("'pnpm-lock.yaml'") -and
    $scanner.Contains('runPluginList'))
Assert-True 'official web/base bundles never become user-plugin rows' (
    $scanner.Contains("coreBundlePackages = new Set(['@deepseek-ai/dsh-base', '@deepseek-ai/dsh-web-app'])"))
Assert-True 'scanner records package metadata and Cordis facts' (
    $scanner.Contains('peerDependencies') -and
    $scanner.Contains('dshClientInject') -and
    $scanner.Contains('declaredInject') -and
    $scanner.Contains('providesService') -and
    $scanner.Contains('requiresService'))
Assert-True 'scanner calculates direct and reverse dependency graph' (
    $scanner.Contains('row.dependsOn') -and
    $scanner.Contains('row.dependents') -and
    $scanner.Contains('calculateInstallOrder'))
Assert-True 'scanner exposes the only accepted machine-readable statuses' (
    $scanner.Contains("'PASS'") -and $scanner.Contains("'WARN'") -and
    $scanner.Contains("'BLOCKED'") -and $scanner.Contains("'UNKNOWN'") -and
    $scanner.Contains('完整精确 preflight 通过'))
Assert-True 'latest is upstream information only and installed version builds the spec' (
    $scanner.Contains("packageName + '@latest'") -and
    $scanner.Contains("return row.package + '@' + row.version") -and
    $manage.Contains('latest 只展示为上游信息') -and
    $manage.Contains('不会自动追 latest'))
Assert-True 'scanner wrapper pins ordinary scans to the rc2 target by default' (
    $wrapper.Contains("DshVersion = '0.1.5-rc.2'") -and
    $wrapper.Contains('--target-version'))
Assert-True 'manager maps the graph into a plugin model instead of trusting display labels' (
    $manage.Contains('Get-DynamicPluginCatalog') -and
    $manage.Contains('DependsOn = @($item.dependsOn)') -and
    $manage.Contains('RequiresService = @($item.requiresService)') -and
    $manage.Contains('HostRange = @($item.hostRange)'))
Assert-True 'upgrade is blocked by a fresh matrix scan instead of assumed from semver' (
    $manage.Contains('Get-DshUpgradeBlockers') -and
    $manage.Contains('Test-DshUpgradeAllowed') -and
    $manage.Contains("`$_.status -ne 'PASS'") -and
    $manage.Contains('plugin-unverified') -and
    $manage.Contains('plugin-list'))

if ($fail -eq 0) { Write-Host 'DYNAMIC PLUGIN CATALOG TESTS PASSED' }
else { Write-Host "FAILURES: $fail" }
exit $(if ($fail -eq 0) { 0 } else { 1 })
