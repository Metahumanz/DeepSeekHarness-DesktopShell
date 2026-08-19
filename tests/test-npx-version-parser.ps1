$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$manager = Join-Path $repo 'scripts\Manage-Dsh.ps1'

$tokens = @(); $errors = @()
$ast = [System.Management.Automation.Language.Parser]::ParseFile($manager, [ref]$tokens, [ref]$errors)
if ($errors.Count -gt 0) { Write-Error "Manage-Dsh.ps1 解析失败"; exit 1 }
$fn = $ast.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Get-DshVersionFromNpx' }, $true)
if (-not $fn) { Write-Error 'Get-DshVersionFromNpx not found'; exit 1 }
$body = $fn.Body.Extent.Text.Trim()
if ($body.StartsWith('{')) { $body = $body.Substring(1) }
if ($body.EndsWith('}')) { $body = $body.Substring(0, $body.Length - 1) }
$getNpxVersion = [scriptblock]::Create("param(`$version)`r`n$body")

# 依赖桩：不真正调用 Node/npx 查找，只使用测试提供的 fake npx.cmd。
function Ensure-Node { }
function Get-Npx { return $script:fakeNpx }
function Normalize-Version([string]$v) { return $v }

$fail = 0
function Assert-True([string]$label, [bool]$condition) {
    if ($condition) { Write-Host "PASS: $label" }
    else { $script:fail++; Write-Host "FAIL: $label" }
}
function Assert-Equal([string]$label, $actual, $expected) {
    if ($actual -eq $expected) { Write-Host "PASS: $label" }
    else { $script:fail++; Write-Host "FAIL: $label (actual=$actual expected=$expected)" }
}

$base = Join-Path $env:TEMP ('dsh-npx-version-test-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $base | Out-Null
try {
    # 1) 成功：整行独立版本号
    $okNpx = Join-Path $base 'ok-npx.cmd'
    "@echo off`r`necho 0.1.0-rc.7`r`n" | Set-Content -LiteralPath $okNpx -Encoding ascii
    $script:fakeNpx = $okNpx
    $got = & $getNpxVersion '0.1.0-rc.7'
    Assert-Equal "success standalone version line returns rc.7" $got '0.1.0-rc.7'

    # 2) 失败：ETARGET 输出中即使包含 0.1.0-rc.8，也必须抛错
    $errNpx = Join-Path $base 'err-npx.cmd'
    @'
@echo off
echo npm error code ETARGET 1>&2
echo npm error notarget No matching version found for @deepseek-ai/dsh-agent-loop@^0.1.0-rc.8. 1>&2
echo npm error A complete log of this run can be found in: C:\fake\path\debug-0.log 1>&2
'@ | Set-Content -LiteralPath $errNpx -Encoding ascii
    $script:fakeNpx = $errNpx
    $thrown = ''
    try { & $getNpxVersion '0.1.0-rc.8' | Out-Null }
    catch { $thrown = $_.Exception.Message }
    Assert-True "ETARGET output must throw" ($thrown -ne '')
    Assert-True "error preserves missing package" ($thrown -match 'dsh-agent-loop')
    Assert-True "error preserves npm log path" ($thrown -match 'debug-0\.log')
    Assert-True "error text containing rc.8 is not treated as success" ($thrown -match '0\.1\.0-rc\.8')

    # 3) 非失败但也不是独立版本号的输出：不能当成功
    $weirdNpx = Join-Path $base 'weird-npx.cmd'
    "@echo off`r`necho prefix 0.1.0-rc.7 suffix`r`n" | Set-Content -LiteralPath $weirdNpx -Encoding ascii
    $script:fakeNpx = $weirdNpx
    $thrown2 = ''
    try { & $getNpxVersion '0.1.0-rc.7' | Out-Null }
    catch { $thrown2 = $_.Exception.Message }
    Assert-True "non-standalone version output must throw" ($thrown2 -ne '')
} finally {
    Remove-Item -LiteralPath $base -Recurse -Force -ErrorAction SilentlyContinue
}

if ($fail -eq 0) { Write-Host 'NPX VERSION PARSER TESTS PASSED' } else { Write-Host "FAILURES: $fail" }
exit $(if ($fail -eq 0) { 0 } else { 1 })
