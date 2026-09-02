$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$manage = [System.IO.File]::ReadAllText((Join-Path $repo 'scripts\Manage-Dsh.ps1'))
$catalogStart = $manage.IndexOf('$PluginCatalog = @(', [System.StringComparison]::Ordinal)
$catalogEnd = $manage.IndexOf('function Get-ExclusiveSelectionConflicts', $catalogStart, [System.StringComparison]::Ordinal)
$catalog = if ($catalogStart -ge 0 -and $catalogEnd -gt $catalogStart) {
    $manage.Substring($catalogStart, $catalogEnd - $catalogStart)
} else { '' }

$fail = 0
function Assert-True([string]$label, [bool]$condition) {
    if ($condition) { Write-Host "PASS: $label" }
    else { $script:fail++; Write-Host "FAIL: $label" }
}

$entries = @([regex]::Matches($catalog, "No=\d+;\s+Id='[^']+'"))
Assert-True 'catalog has 26 current portable entries' ($entries.Count -eq 26)
Assert-True 'core/enhanced/advanced tiers are all retained' (
    $catalog -match "Tier='core'" -and $catalog -match "Tier='enhanced'" -and $catalog -match "Tier='advanced'")
Assert-True 'catalog has no implicit latest install' ($catalog -notmatch '@latest')
Assert-True 'current core versions are synchronized' (
    $catalog -match "dshmarket@1\.21\.2.*Installed='1\.21\.2'" -and
    $catalog -match "dsh-better-sidebar@\^0\.15\.2.*Installed='0\.15\.2'" -and
    $catalog -match "dsh-skills-manager@0\.1\.24.*Installed='0\.1\.24'" -and
    $catalog -match "dsh-at-file.*Installed='0\.6\.8'")
Assert-True 'current enhanced versions and replacements are synchronized' (
    $catalog -match "file-mentions.*Installed='1\.0\.9'" -and
    $catalog -match "auto-collapse.*Installed='0\.1\.4'" -and
    $catalog -match "Id='open-in'.*dsh-open-in@\^0\.1\.1.*Installed='0\.1\.1'" -and
    $catalog -match "Id='context'.*dsh-context@\^0\.29\.0.*Installed='0\.29\.0'")
Assert-True 'Sidebar QA production spec is pinned to the rc.2-compatible npm release' (
    $catalog -match "Id='sidebar-qa'.*dsh-sidebar-qa@0\.4\.0.*Installed='0\.4\.0'")
Assert-True 'current advanced versions are synchronized' (
    $catalog -match "auto-mode@\^0\.1\.5.*Installed='0\.1\.5'" -and
    $catalog -match "cost-meter@\^1\.5\.42.*Installed='1\.5\.42'" -and
    $catalog -match "dream-skin@\^0\.4\.10.*Installed='0\.4\.10'" -and
    $catalog -match "liangshen@\^0\.3\.2.*Installed='0\.3\.2'")
Assert-True 'agent-teams is advanced' ($catalog -match "Id='agent-teams'.*dsh-agent-teams@\^0\.1\.13.*Tier='advanced'.*Installed='0\.1\.13'")
Assert-True 'stale/nonexistent historical entries are absent' (
    $catalog -notmatch 'dsh-remote' -and $catalog -notmatch 'open-in-vscode' -and
    $catalog -notmatch "Id='model-picker'" -and $catalog -notmatch "Id='modlens'" -and
    $catalog -notmatch 'dsh-bridge-browser')
Assert-True 'local-only bridge remains documented outside portable catalog' (
    $manage -match 'link:' -and $manage -match 'bridge-browser')

if ($fail -eq 0) { Write-Host 'PLUGIN CATALOG TESTS PASSED' } else { Write-Host "FAILURES: $fail" }
exit $(if ($fail -eq 0) { 0 } else { 1 })
