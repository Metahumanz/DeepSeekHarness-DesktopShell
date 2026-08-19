$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$manage = Join-Path $repo 'scripts\Manage-Dsh.ps1'
$text = [System.IO.File]::ReadAllText($manage)

$fail = 0
function Assert-True([string]$label, [bool]$condition) {
    if ($condition) { Write-Host "PASS: $label" }
    else { $script:fail++; Write-Host "FAIL: $label" }
}

# ---- 1. 用 AST 提取真实 Test-DshNeedsReacceptance 并做行为矩阵（与 C# 同一规则） ----
$tokens = @(); $parseErrors = @()
$ast = [System.Management.Automation.Language.Parser]::ParseFile($manage, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count -gt 0) {
    Write-Host "FAIL: Manage-Dsh.ps1 parse errors: $($parseErrors.Count)"
    exit 1
}
$fn = $ast.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Test-DshNeedsReacceptance' }, $true)
if (-not $fn) { Write-Host 'FAIL: Test-DshNeedsReacceptance not found in Manage-Dsh.ps1'; exit 1 }
# 函数体（去掉外层大括号）+ 参数包装：直接调用产品函数本体，不复制实现
$body = $fn.Body.Extent.Text.Trim()
if ($body.StartsWith('{')) { $body = $body.Substring(1) }
if ($body.EndsWith('}')) { $body = $body.Substring(0, $body.Length - 1) }
$reaccept = [scriptblock]::Create("param(`$acceptedPath, `$acceptedVersion, `$actualPath, `$actualVersion)`r`n$body")

$matrix = @(
    @{ Label='acceptedPath empty -> re-verify';        AcceptedPath='';          AcceptedVersion='0.1.0-rc.7'; ActualPath='C:\dsh.cmd'; ActualVersion='0.1.0-rc.7'; Expected=$true },
    @{ Label='acceptedVersion empty -> re-verify';     AcceptedPath='C:\dsh.cmd'; AcceptedVersion='';          ActualPath='C:\dsh.cmd'; ActualVersion='0.1.0-rc.7'; Expected=$true },
    @{ Label='actualPath empty -> re-verify';          AcceptedPath='C:\dsh.cmd'; AcceptedVersion='0.1.0-rc.7'; ActualPath='';          ActualVersion='0.1.0-rc.7'; Expected=$true },
    @{ Label='path changed -> re-verify';              AcceptedPath='C:\dsh.cmd'; AcceptedVersion='0.1.0-rc.7'; ActualPath='D:\dsh.cmd'; ActualVersion='0.1.0-rc.7'; Expected=$true },
    @{ Label='actualVersion empty -> re-verify';       AcceptedPath='C:\dsh.cmd'; AcceptedVersion='0.1.0-rc.7'; ActualPath='C:\dsh.cmd'; ActualVersion='';          Expected=$true },
    @{ Label='version changed -> re-verify';           AcceptedPath='C:\dsh.cmd'; AcceptedVersion='0.1.0-rc.7'; ActualPath='C:\dsh.cmd'; ActualVersion='0.1.0-rc.8'; Expected=$true },
    @{ Label='path case differs only -> no re-verify'; AcceptedPath='C:\dsh.cmd'; AcceptedVersion='0.1.0-rc.7'; ActualPath='c:\DSh.CMD';  ActualVersion='0.1.0-rc.7'; Expected=$false },
    @{ Label='everything matches -> no re-verify';     AcceptedPath='C:\dsh.cmd'; AcceptedVersion='0.1.0-rc.7'; ActualPath='C:\dsh.cmd'; ActualVersion='0.1.0-rc.7'; Expected=$false }
)
foreach ($row in $matrix) {
    $got = & $reaccept $row.AcceptedPath $row.AcceptedVersion $row.ActualPath $row.ActualVersion
    Assert-True "$($row.Label) (expected=$($row.Expected) got=$got)" ($got -eq $row.Expected)
}

# ---- 2. Invoke-ManagedDsh 使用统一重验证（command/auto 都执行，不再只看 command 模式） ----
Assert-True "re-verify applied to any resolved dsh command" ($text -match 'if \(\$dshCommand\) \{\s*\$actualVer = Get-DshVersionFromCommand')
Assert-True "re-verify delegates to Test-DshNeedsReacceptance" ($text -match 'Test-DshNeedsReacceptance \$current\.AcceptedDshPath \$current\.AcceptedDshVersion \$dshCommand \$actualVer')
Assert-True "verified version auto-accepted without dialog" ($text -match 'Test-DshVersionSupported \$actualVer')
Assert-True "re-verify no longer gated on command-only mode" ($text -notmatch 'RunnerMode -eq ''command''\) \{\s*\$actualVer = Get-DshVersionFromCommand')

# ---- 3. 版本单一来源：npx 回退版本跟随验证基线 ----
Assert-True "defaultDshVersion derives from VerifiedDshVersion" ($text -match '\$defaultDshVersion = \$VerifiedDshVersion')
Assert-True "baseline read from COMPATIBILITY.json" ($text -match '\$VerifiedDshVersion = \[string\]\$compat\.verifiedDshVersion')

if ($fail -eq 0) { Write-Host 'ACCEPTED DSH TESTS PASSED' } else { Write-Host "FAILURES: $fail" }
exit $(if ($fail -eq 0) { 0 } else { 1 })
