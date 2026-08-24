$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$managePath = Join-Path $repo 'scripts\Manage-Dsh.ps1'
$manage = [System.IO.File]::ReadAllText($managePath)
$catalogStart = $manage.IndexOf('$PluginCatalog = @(', [System.StringComparison]::Ordinal)
$catalogEnd = $manage.IndexOf('function Get-ExclusiveSelectionConflicts', $catalogStart, [System.StringComparison]::Ordinal)
$catalogScript = $manage.Substring($catalogStart, $catalogEnd - $catalogStart)
$tokens = @(); $errors = @()
$ast = [System.Management.Automation.Language.Parser]::ParseFile($managePath, [ref]$tokens, [ref]$errors)
if ($errors.Count -gt 0) { throw 'Manage-Dsh.ps1 parse failed' }
$functionNames = @('Get-ExclusiveSelectionConflicts', 'Resolve-ExclusivePluginSelection')
$functions = $ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -in $functionNames }, $true)
if ($functions.Count -ne $functionNames.Count) { throw 'exclusive-group functions not found' }

$fail = 0
function Assert-True([string]$label, [bool]$condition) {
    if ($condition) { Write-Host "PASS: $label" }
    else { $script:fail++; Write-Host "FAIL: $label" }
}
function Warn([string]$text) { }

$PluginCatalog = @()
. ([scriptblock]::Create($catalogScript))
. ([scriptblock]::Create((@($functions | ForEach-Object { $_.Extent.Text }) -join "`n")))
$NonInteractive = $true
$status = @($PluginCatalog | Where-Object { $_.Id -eq 'status-rotator' })[0]
$thought = @($PluginCatalog | Where-Object { $_.Id -eq 'thought-buddy' })[0]

Assert-True 'both status plugins share thinking-status-ui' (
    $status.ExclusiveGroup -eq 'thinking-status-ui' -and $thought.ExclusiveGroup -eq 'thinking-status-ui')
Assert-True 'Status Rotator is the recommended winner' ($status.Recommended -eq $true -and $thought.Recommended -ne $true)
$forward = @(Resolve-ExclusivePluginSelection @($status, $thought))
$reverse = @(Resolve-ExclusivePluginSelection @($thought, $status))
Assert-True 'status then thought resolves to one choice' ($forward.Count -eq 1 -and $forward[0].Id -eq 'status-rotator')
Assert-True 'thought then status resolves symmetrically' ($reverse.Count -eq 1 -and $reverse[0].Id -eq 'status-rotator')
Assert-True 'interactive custom selection prompts for a choice' (
    $manage.Contains('Resolve-ExclusivePluginSelection') -and $manage.Contains('Read-Host'))
Assert-True 'existing Profile conflict does not auto-uninstall' (
    $manage.Contains('Resolve-ProfileExclusiveConflicts') -and $manage.Contains('NonInteractive'))
Assert-True 'chosen existing Profile winner removes only the loser' (
    $manage.Contains('Resolve-ProfileExclusiveConflicts') -and
    $manage -match '\$remove\[0\]\.Package')
$legacyStatusSpecialCase = 'selected\.Id\s*-contains\s*' + [char]39 + 'status'
Assert-True 'legacy scattered status special-case is gone' ($manage -notmatch $legacyStatusSpecialCase)

if ($fail -eq 0) { Write-Host 'PLUGIN EXCLUSIVE GROUP TESTS PASSED' } else { Write-Host "FAILURES: $fail" }
exit $(if ($fail -eq 0) { 0 } else { 1 })
