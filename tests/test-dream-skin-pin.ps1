$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$manage = Join-Path $repo 'scripts\Manage-Dsh.ps1'
$text = [System.IO.File]::ReadAllText($manage)
$acceptance = [System.IO.File]::ReadAllText((Join-Path $repo 'docs\DREAM_SKIN_ACCEPTANCE.md'))

$fail = 0
function Assert-True([string]$label, [bool]$condition) {
    if ($condition) { Write-Host "PASS: $label" }
    else { $script:fail++; Write-Host "FAIL: $label" }
}

# ---- 1. Dream Skin is selected from the scanned exact install spec, never a historical catalog pin. ----
Assert-True "manager has no hard-coded Dream Skin install spec" ($text -notmatch 'dsh-dream-skin@')
Assert-True "old pinned dream-skin commit removed" ($text -notmatch '28497f5294ba20f44acf8eecc62891297d38fc24')
Assert-True "no 40-char dream-skin commit pinned" ($text -notmatch 'dsh-dream-skin/archive/[0-9a-f]{40}\.tar\.gz')
Assert-True 'Dream Skin uses the same dynamic install spec as every scanned package' (
    $text -match 'Spec\s*=\s*\[string\]\$item\.installSpec' -and
    $text -match 'InstallSpec\s*=\s*\[string\]\$item\.installSpec' -and
    $text -match '\[string\]\$plugin\.InstallSpec')
Assert-True 'diagnostics no longer advertise stale npm ^0.4.5' ($text -notmatch 'npm \^0\.4\.5')
Assert-True 'manual acceptance requires the live matrix rather than a catalog number or version' (
    $acceptance -match 'Scan-DshPluginEcosystem\.ps1' -and
    $acceptance -match 'PLUGIN_COMPATIBILITY_MATRIX\.md' -and
    $acceptance -notmatch 'dsh-dream-skin@8\.30\.1' -and
    $acceptance -notmatch '\*\*22\. Dream Skin 主题\*\*')

# ---- 2. The capability detector accepts both verified sticky-restore markers. ----
Assert-True "Test-DreamSkinPersistenceFix defined" ($text -match 'function Test-DreamSkinPersistenceFix')
Assert-True "checks legacy sticky skin restore marker" ($text -match 'dsh-dream-skin: sticky skin restore')
Assert-True "checks current sticky skin restore marker" ($text -match 'dsh-dream-skin: sticky skin \+ built-in restore')
Assert-True "checks /dream-skin/api marker" ($text -match '(/dream-skin/api)')
Assert-True "diagnostics report fixed state" ($text -match 'Dream Skin：持久化修复已安装')
Assert-True "diagnostics warn legacy implementation" ($text -match '检测到缺少持久化能力的旧实现')

# ---- 3. 行为矩阵：AST 提取产品函数本体（注入 $dshHome），用假 client.js 验证 ----
$tokens = @(); $parseErrors = @()
$ast = [System.Management.Automation.Language.Parser]::ParseFile($manage, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count -gt 0) { Write-Host "FAIL: Manage-Dsh.ps1 parse errors: $($parseErrors.Count)"; exit 1 }
$fn = $ast.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Test-DreamSkinPersistenceFix' }, $true)
if (-not $fn) { Write-Host 'FAIL: Test-DreamSkinPersistenceFix not found'; exit 1 }
$body = $fn.Body.Extent.Text.Trim()
if ($body.StartsWith('{')) { $body = $body.Substring(1) }
if ($body.EndsWith('}')) { $body = $body.Substring(0, $body.Length - 1) }
$fixFn = [scriptblock]::Create("param(`$profile, `$dshHome)`r`n$body")

$base = Join-Path $env:TEMP ('dsh-dreamskin-' + [guid]::NewGuid().ToString('N'))
try {
    $clientDir = Join-Path $base 'profiles\web\node_modules\dsh-dream-skin\lib'
    New-Item -ItemType Directory -Force -Path $clientDir | Out-Null
    $client = Join-Path $clientDir 'client.js'

    [System.IO.File]::WriteAllText($client, "// dsh-dream-skin: sticky skin restore`r`n// /dream-skin/api`r`n", [System.Text.UTF8Encoding]::new($false))
    $got = & $fixFn 'web' $base
    Assert-True "both markers -> fixed (got=$got)" ($got -eq $true)

    [System.IO.File]::WriteAllText($client, "// dsh-dream-skin: sticky skin + built-in restore`r`n// /dream-skin/api`r`n", [System.Text.UTF8Encoding]::new($false))
    $got = & $fixFn 'web' $base
    Assert-True "current markers -> fixed (got=$got)" ($got -eq $true)

    [System.IO.File]::WriteAllText($client, "// dsh-dream-skin: sticky skin restore`r`n", [System.Text.UTF8Encoding]::new($false))
    $got = & $fixFn 'web' $base
    Assert-True "missing /dream-skin/api -> old (got=$got)" ($got -eq $false)

    [System.IO.File]::WriteAllText($client, "// /dream-skin/api`r`n", [System.Text.UTF8Encoding]::new($false))
    $got = & $fixFn 'web' $base
    Assert-True "missing sticky marker -> old (got=$got)" ($got -eq $false)

    $got = & $fixFn 'other-profile' $base
    Assert-True "plugin not installed -> old (got=$got)" ($got -eq $false)
} finally {
    Remove-Item -LiteralPath $base -Recurse -Force -ErrorAction SilentlyContinue
}

if ($fail -eq 0) { Write-Host 'DREAM SKIN PIN TESTS PASSED' } else { Write-Host "FAILURES: $fail" }
exit $(if ($fail -eq 0) { 0 } else { 1 })
