$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$manager = Join-Path $repo 'scripts\Manage-Dsh.ps1'

# 从真实脚本中按名字提取函数定义（AST），直接测试真实实现，
# 避免复制一份逻辑导致测试与产品代码脱节。
$tokens = @(); $errors = @()   # 5.1 下 $null 赋值会让变量消失，[ref] 会报错，用空数组占位
$ast = [System.Management.Automation.Language.Parser]::ParseFile($manager, [ref]$tokens, [ref]$errors)
if ($errors.Count -gt 0) { Write-Error "Manage-Dsh.ps1 解析失败"; exit 1 }
$names = @('ConvertTo-SemVerParts', 'Compare-DshVersion', 'Test-DshVersionSupported')
$funcs = $ast.FindAll({
    param($node)
    $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
    $node.Name -in $names
}, $true)
if ($funcs.Count -ne $names.Count) {
    Write-Error "函数提取失败：期望 $($names -join ',')，找到 $((@($funcs) | ForEach-Object Name) -join ',')"
    exit 1
}
$text = (@($funcs) | ForEach-Object { $_.Extent.Text }) -join "`n"
$MinSupportedDshVersion = '0.1.0-rc.7'   # 函数引用的脚本级变量，测试侧提供
. ([scriptblock]::Create($text))          # 点源：把函数定义进当前作用域

$fail = 0
function Assert-Equal([string]$label, $actual, $expected) {
    if ($actual -eq $expected) { Write-Host "PASS: $label" }
    else { $fail++; Write-Host "FAIL: $label  (actual=$actual expected=$expected)" }
}

# rc.6 必须低于 rc.7（审计指出的回归点：旧实现用 [version] 解析抛异常后被静默放行）
Assert-Equal "rc.6 < rc.7"                (Compare-DshVersion '0.1.0-rc.6' '0.1.0-rc.7') -1
Assert-Equal "rc.7 == rc.7"               (Compare-DshVersion '0.1.0-rc.7' '0.1.0-rc.7') 0
Assert-Equal "rc.10 > rc.9 (numeric)"     (Compare-DshVersion '0.1.0-rc.10' '0.1.0-rc.9') 1
Assert-Equal "release > prerelease"       (Compare-DshVersion '0.1.0' '0.1.0-rc.7') 1
Assert-Equal "1.0.0 > rc.7"               (Compare-DshVersion '1.0.0' '0.1.0-rc.7') 1
Assert-Equal "alpha < rc"                 (Compare-DshVersion '0.1.0-alpha.1' '0.1.0-rc.1') -1
Assert-Equal "0.2.0 > 0.1.99"             (Compare-DshVersion '0.2.0' '0.1.99') 1
Assert-Equal "unparseable -> null"        (Compare-DshVersion 'dev-build' '0.1.0-rc.7') $null

Assert-Equal "support rc.6"               (Test-DshVersionSupported '0.1.0-rc.6') $false
Assert-Equal "support rc.5"               (Test-DshVersionSupported '0.1.0-rc.5') $false
Assert-Equal "support rc.7"               (Test-DshVersionSupported '0.1.0-rc.7') $true
Assert-Equal "support 1.0.0"              (Test-DshVersionSupported '1.0.0') $true
Assert-Equal "support 0.2.0"              (Test-DshVersionSupported '0.2.0') $true
Assert-Equal "support unparseable"        (Test-DshVersionSupported 'weird') $false
Assert-Equal "support empty -> unknown"   (Test-DshVersionSupported '') $null

if ($fail -eq 0) { Write-Host 'VERSION GATE TESTS PASSED' } else { Write-Host "FAILURES: $fail" }
exit $(if ($fail -eq 0) { 0 } else { 1 })