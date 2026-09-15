$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$managePath = Join-Path $repo 'scripts\Manage-Dsh.ps1'
$manage = [System.IO.File]::ReadAllText($managePath)
$tokens = @(); $errors = @()
$ast = [System.Management.Automation.Language.Parser]::ParseFile($managePath, [ref]$tokens, [ref]$errors)
if ($errors.Count -gt 0) { throw 'Manage-Dsh.ps1 parse failed' }

$requiredNames = @(
    'Get-PluginPackageDirectory',
    'Get-DynamicPluginPostInstallHook',
    'Initialize-ExampleGradientConfig',
    'Invoke-PluginPostInstall'
)
$functions = @($ast.FindAll({
    param($node)
    $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -in $requiredNames
}, $true))
if ($functions.Count -ne $requiredNames.Count) {
    throw ('dynamic post-install function extraction failed: ' + (($functions | ForEach-Object Name) -join ','))
}

$fail = 0
function Assert-True([string]$label, [bool]$condition) {
    if ($condition) { Write-Host "PASS: $label" }
    else { $script:fail++; Write-Host "FAIL: $label" }
}
function Ok([string]$text) { }
function Warn([string]$text) { }

Assert-True 'post-install hook is discovered from real package content rather than a static catalog row' (
    $manage -match 'PostInstall\s*=\s*Get-DynamicPluginPostInstallHook' -and
    $manage -match 'config\.example\.json' -and
    $manage -notmatch 'ConfigureStatusRotator' -and
    $manage -notmatch 'dsh-status-rotator')
Assert-True 'dynamic hook dispatches the generic gradient initializer' (
    $manage -match "'InitializeExampleGradientConfig'\s*\{\s*Initialize-ExampleGradientConfig" -and
    $manage -match 'Invoke-PluginPostInstall \$profile \$plugin')

$dshHome = Join-Path ([IO.Path]::GetTempPath()) ('dsh-dynamic-config-test-' + [guid]::NewGuid().ToString('N'))
$package = 'fixture-gradient-plugin'
$profileDir = Join-Path $dshHome ('profiles\web\node_modules\' + $package)
New-Item -ItemType Directory -Force -Path $profileDir | Out-Null
$example = @'
{
  "config": { "gradient": { "enabled": true, "speed": 4 } },
  "phrases": { "zh": { "thinking": ["phrase A", "phrase B"] } }
}
'@
Set-Content -LiteralPath (Join-Path $profileDir 'config.example.json') -Value $example -Encoding UTF8
. ([scriptblock]::Create((@($functions | ForEach-Object Extent | ForEach-Object Text) -join "`n")))

try {
    $hook = Get-DynamicPluginPostInstallHook 'web' $package
    $plugin = [pscustomobject]@{ Package = $package; Name = $package; PostInstall = $hook }
    Invoke-PluginPostInstall 'web' $plugin
    $configPath = Join-Path $profileDir 'config.json'
    $first = Get-Content -LiteralPath $configPath -Raw -Encoding UTF8 | ConvertFrom-Json
    Assert-True 'example metadata selects the generic hook' ($hook -eq 'InitializeExampleGradientConfig')
    Assert-True 'first install creates config.json' (Test-Path -LiteralPath $configPath -PathType Leaf)
    Assert-True 'first install defaults gradient off' ($first.config.gradient.enabled -eq $false)

    $first.config.gradient.enabled = $true
    [IO.File]::WriteAllText($configPath, ($first | ConvertTo-Json -Depth 20), [System.Text.UTF8Encoding]::new($false))
    Invoke-PluginPostInstall 'web' $plugin
    $second = Get-Content -LiteralPath $configPath -Raw -Encoding UTF8 | ConvertFrom-Json
    Assert-True 'existing user config is preserved on re-install' ($second.config.gradient.enabled -eq $true)
}
finally {
    Remove-Item -LiteralPath $dshHome -Recurse -Force -ErrorAction SilentlyContinue
}

if ($fail -eq 0) { Write-Host 'DYNAMIC EXAMPLE CONFIG TESTS PASSED' } else { Write-Host "FAILURES: $fail" }
exit $(if ($fail -eq 0) { 0 } else { 1 })
