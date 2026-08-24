$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$managePath = Join-Path $repo 'scripts\Manage-Dsh.ps1'
$manage = [System.IO.File]::ReadAllText($managePath)
$tokens = @(); $errors = @()
$ast = [System.Management.Automation.Language.Parser]::ParseFile($managePath, [ref]$tokens, [ref]$errors)
if ($errors.Count -gt 0) { throw 'Manage-Dsh.ps1 parse failed' }
$fn = $ast.Find({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'ConfigureStatusRotator' }, $true)
if (-not $fn) { throw 'ConfigureStatusRotator function not found' }

$fail = 0
function Assert-True([string]$label, [bool]$condition) {
    if ($condition) { Write-Host "PASS: $label" }
    else { $script:fail++; Write-Host "FAIL: $label" }
}

Assert-True 'catalog metadata declares status post-install hook' ($manage -match "Id='status-rotator'.*PostInstall='ConfigureStatusRotator'")
Assert-True 'status hook is metadata-dispatched' ($manage -match "'ConfigureStatusRotator'\s*\{\s*ConfigureStatusRotator")
Assert-True 'status hook uses example config and disables gradient for first install' (
    $manage -match 'config\.example\.json' -and $manage -match 'gradient' -and $manage -match 'Name enabled -Value \$false')

function Ok([string]$text) { }
function Warn([string]$text) { }
$dshHome = Join-Path ([IO.Path]::GetTempPath()) ('dsh-status-config-test-' + [guid]::NewGuid().ToString('N'))
$profileDir = Join-Path $dshHome 'profiles\web\node_modules\dsh-status-rotator'
New-Item -ItemType Directory -Force -Path $profileDir | Out-Null
$example = @'
{
  "config": { "gradient": { "enabled": true, "speed": 4 } },
  "phrases": { "zh": { "thinking": ["梗词 A", "梗词 B"] } }
}
'@
Set-Content -LiteralPath (Join-Path $profileDir 'config.example.json') -Value $example -Encoding UTF8
. ([scriptblock]::Create($fn.Extent.Text))
try {
    $created = ConfigureStatusRotator 'web'
    $configPath = Join-Path $profileDir 'config.json'
    $first = Get-Content -LiteralPath $configPath -Raw -Encoding UTF8 | ConvertFrom-Json
    Assert-True 'first install creates config.json' ($created -and (Test-Path -LiteralPath $configPath -PathType Leaf))
    Assert-True 'first install defaults gradient off' ($first.config.gradient.enabled -eq $false)

    $first.config.gradient.enabled = $true
    [IO.File]::WriteAllText($configPath, ($first | ConvertTo-Json -Depth 20), [System.Text.UTF8Encoding]::new($false))
    [void](ConfigureStatusRotator 'web')
    $second = Get-Content -LiteralPath $configPath -Raw -Encoding UTF8 | ConvertFrom-Json
    Assert-True 'existing user config is preserved on re-install' ($second.config.gradient.enabled -eq $true)
}
finally {
    Remove-Item -LiteralPath $dshHome -Recurse -Force -ErrorAction SilentlyContinue
}

if ($fail -eq 0) { Write-Host 'STATUS ROTATOR CONFIG TESTS PASSED' } else { Write-Host "FAILURES: $fail" }
exit $(if ($fail -eq 0) { 0 } else { 1 })
