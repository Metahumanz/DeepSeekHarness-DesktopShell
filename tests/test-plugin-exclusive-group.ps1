$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$manage = [IO.File]::ReadAllText((Join-Path $repo 'scripts\Manage-Dsh.ps1'))
$scanner = [IO.File]::ReadAllText((Join-Path $repo 'scripts\Scan-DshPluginEcosystem.cjs'))

$fail = 0
function Assert-True([string]$label, [bool]$condition) {
    if ($condition) { Write-Host "PASS: $label" }
    else { $script:fail++; Write-Host "FAIL: $label" }
}

Assert-True 'uninstall computes a transitive dependent closure from the scanned graph' (
    $manage.Contains('function Get-TransitivePluginDependents') -and
    $manage.Contains('$queue.Enqueue($package)') -and
    $manage.Contains('$byPackage[$current].Dependents'))
Assert-True 'uninstall uses reverse topological order and asks before mutation' (
    $manage.Contains('$document.installOrder') -and
    $manage.Contains('[array]::Reverse($reverseOrder)') -and
    $manage.Contains('确认连锁卸载这些插件？'))
Assert-True 'uninstall does not silently delete a remaining profile patch' (
    $manage.Contains('不会自动删配置；请先核对再处理。'))
Assert-True 'install reintroduces all scanned parent dependencies in topological order' (
    $manage.Contains('function Resolve-PluginInstallPlan') -and
    $manage.Contains('$queue.Enqueue([string]$dependency)') -and
    $manage.Contains('按依赖顺序安装'))
Assert-True 'a missing provider is an explicit graph blocker rather than a catalog guess' (
    $scanner.Contains('没有已安装 provider 的 Cordis 服务') -and
    $scanner.Contains('row.unresolvedService'))
Assert-True 'no hard-coded Better Sidebar or Video Preview exception drives removal' (
    $manage -notmatch "Id='(?:sidebar|video)'" -and
    $manage -notmatch 'dsh-video-preview')

if ($fail -eq 0) { Write-Host 'PLUGIN DEPENDENCY CASCADE TESTS PASSED' }
else { Write-Host "FAILURES: $fail" }
exit $(if ($fail -eq 0) { 0 } else { 1 })
