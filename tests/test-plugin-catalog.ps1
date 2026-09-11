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
Assert-True 'catalog has no unqualified npm @latest install' ($catalog -notmatch '@latest')
Assert-True 'current core versions are synchronized' (
    $catalog -match "dshmarket@1\.41\.0.*Installed='1\.41\.0'" -and
    $catalog -match "dsh-better-sidebar@0\.17\.1.*Installed='0\.17\.1'" -and
    $catalog -match "dsh-skills-manager@0\.1\.38.*Installed='0\.1\.38'" -and
    $catalog -match "dsh-at-file#v0\.7\.0.*Installed='0\.7\.0'")
Assert-True 'current enhanced versions and replacements are synchronized' (
    $catalog -match "file-mentions#v1\.0\.13.*Installed='1\.0\.13'" -and
    $catalog -match "auto-collapse#v0\.1\.5.*Installed='0\.1\.5'" -and
    $catalog -match "dsh-video-preview@0\.1\.4.*Installed='0\.1\.4'" -and
    $catalog -match "dsh-status-rotator@0\.10\.0.*Installed='0\.10\.0'" -and
    $catalog -match "Id='open-in'.*dsh-open-in@\^0\.1\.1.*Installed='0\.1\.1'" -and
    $catalog -match "Id='context'.*dsh-context@0\.41\.3.*Installed='0\.41\.3'")
Assert-True 'Sidebar QA production spec is pinned to the rc.2-compatible npm release' (
    $catalog -match "Id='sidebar-qa'.*dsh-sidebar-qa@0\.4\.0.*Installed='0\.4\.0'")
Assert-True 'current advanced versions are synchronized' (
    $catalog -match "auto-mode@\^0\.1\.5.*Installed='0\.1\.5'" -and
    $catalog -match "cost-meter@1\.7\.10.*Installed='1\.7\.10'" -and
    $catalog -match "dream-skin@8\.30\.1.*Installed='8\.30\.1'" -and
    $catalog -match "liangshen@0\.3\.14.*Installed='0\.3\.14'" -and
    $catalog -match "dsh-thought-buddy@0\.3\.3.*Installed='0\.3\.3'")
Assert-True 'agent-teams is advanced and pinned to the rc.2-compatible release' (
    $catalog -match "Id='agent-teams'.*dsh-agent-teams@0\.1\.14.*Tier='advanced'.*Installed='0\.1\.14'")
Assert-True 'stale/nonexistent historical entries are absent' (
    $catalog -notmatch 'dsh-remote' -and $catalog -notmatch 'open-in-vscode' -and
    $catalog -notmatch "Id='model-picker'" -and $catalog -notmatch "Id='modlens'" -and
    $catalog -notmatch 'dsh-bridge-browser')
Assert-True 'local-only bridge remains documented outside portable catalog' (
    $manage -match 'link:' -and $manage -match 'bridge-browser')

$gitSourceLines = @($catalog -split "\r?\n" | Where-Object {
    $_ -match "Spec='(?:github:|git\+https://github\.com/)"
})
$floatingGitSources = @($gitSourceLines | Where-Object { $_ -match 'Floating=\$true' })
$unpinnedGitSources = @($gitSourceLines | Where-Object {
    $_ -notmatch 'Floating=\$true' -and $_ -notmatch '#v\d'
})
Assert-True 'all remaining three floating GitHub specs are explicitly marked' (
    $gitSourceLines.Count -eq 8 -and $floatingGitSources.Count -eq 3 -and
    $unpinnedGitSources.Count -eq 0)
Assert-True 'catalog and installation path disclose floating GitHub refs' (
    $manage -match '\$p\.Floating -eq \$true' -and
    $manage -match '\$floatingSources\.Count -gt 0')

if ($fail -eq 0) { Write-Host 'PLUGIN CATALOG TESTS PASSED' } else { Write-Host "FAILURES: $fail" }
exit $(if ($fail -eq 0) { 0 } else { 1 })
