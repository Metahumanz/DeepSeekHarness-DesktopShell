$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$installer = Join-Path $repo 'scripts\Install-Release.ps1'
$manager = Join-Path $repo 'scripts\Manage-Dsh.ps1'
$hostExe = Join-Path $PSHOME $(if ($PSVersionTable.PSEdition -eq 'Core') { 'pwsh.exe' } else { 'powershell.exe' })

$fail = 0
function Assert-Equal([string]$label, $actual, $expected) {
    if ($actual -eq $expected) { Write-Host "PASS: $label" }
    else { $fail++; Write-Host "FAIL: $label  (actual=<$actual> expected=<$expected>)" }
}

# ---- 1. 纯函数：Resolve-RunnerMode / Normalize-Profile / Test-ReservedProfileName（AST 提取真实实现） ----
$tokens = @(); $errors = @()
$ast = [System.Management.Automation.Language.Parser]::ParseFile($manager, [ref]$tokens, [ref]$errors)
if ($errors.Count -gt 0) { Write-Error "Manage-Dsh.ps1 解析失败"; exit 1 }
$names = @('Resolve-RunnerMode', 'Normalize-Profile', 'Test-ReservedProfileName')
$funcs = $ast.FindAll({
    param($node)
    $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -in $names
}, $true)
if ($funcs.Count -ne $names.Count) { Write-Error "函数提取失败"; exit 1 }
$text = (@($funcs) | ForEach-Object { $_.Extent.Text }) -join "`n"
$ReservedProfileNames = @('node_modules', 'con', 'prn', 'aux', 'nul')
. ([scriptblock]::Create($text))

Assert-Equal "mode npx"          (Resolve-RunnerMode 'npx') 'npx'
Assert-Equal "mode command"      (Resolve-RunnerMode 'command') 'command'
Assert-Equal "mode auto"         (Resolve-RunnerMode 'auto') 'auto'
Assert-Equal "mode garbage->auto" (Resolve-RunnerMode 'latest') 'auto'
Assert-Equal "mode empty->auto"  (Resolve-RunnerMode '') 'auto'
Assert-Equal "profile web"       (Normalize-Profile 'web') 'web'
Assert-Equal "profile Node_Modules reserved" (Normalize-Profile 'Node_Modules') 'web'
Assert-Equal "profile con reserved" (Normalize-Profile 'con') 'web'
Assert-Equal "profile CON reserved" (Normalize-Profile 'CON') 'web'
Assert-Equal "profile com3 reserved" (Normalize-Profile 'com3') 'web'
Assert-Equal "profile com10 ok"  (Normalize-Profile 'com10') 'com10'
Assert-Equal "profile lpt1 reserved" (Normalize-Profile 'lpt1') 'web'
Assert-Equal "profile nul reserved"  (Normalize-Profile 'nul') 'web'
Assert-Equal "profile dots invalid"  (Normalize-Profile 'a..b') 'web'
Assert-Equal "profile valid"     (Normalize-Profile 'my-profile') 'my-profile'

# ---- 2. 端到端：runnerMode 持久化（修掉“选 npx 最后又跑 PATH dsh”的回归） ----
$base = Join-Path $env:TEMP ('dsh-runner-test-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $base | Out-Null
$shimDir = Join-Path $base 'shim'
New-Item -ItemType Directory -Force -Path $shimDir | Out-Null
"@echo off`r`necho 22.19.0`r`n" | Set-Content -LiteralPath (Join-Path $shimDir 'node.cmd') -Encoding ascii
"@echo off`r`necho 0.1.0-rc.7`r`n" | Set-Content -LiteralPath (Join-Path $shimDir 'npx.cmd') -Encoding ascii
$testDshHome = Join-Path $base 'dsh-home'
New-Item -ItemType Directory -Force -Path $testDshHome | Out-Null

$appFiles = @(
    'DeepSeekHarness.exe','Microsoft.Web.WebView2.Core.dll','Microsoft.Web.WebView2.WinForms.dll',
    'WebView2Loader.dll','DeepSeekHarness.ico','DeepSeekHarness-Light.ico','DeepSeekHarness-Dark.ico',
    'DeepSeekHarness.svg','Manage-Dsh.ps1','Uninstall-DesktopShell.ps1','version.txt'
)
$pkg = Join-Path $base 'pkg'
New-Item -ItemType Directory -Force -Path $pkg | Out-Null
foreach ($f in $appFiles) { Set-Content -LiteralPath (Join-Path $pkg $f) -Value 'x' -Encoding ascii }
Copy-Item -LiteralPath $manager -Destination (Join-Path $pkg 'Manage-Dsh.ps1') -Force
Copy-Item -LiteralPath (Join-Path $repo 'scripts\Uninstall-DesktopShell.ps1') -Destination (Join-Path $pkg 'Uninstall-DesktopShell.ps1') -Force

$origPath = $env:Path
$origDshHome = $env:DSH_HOME

function Invoke-HermeticInstall([string]$target) {
    $env:Path = "$shimDir;$env:SystemRoot\System32;$env:SystemRoot"
    $env:DSH_HOME = $testDshHome
    try {
        & $hostExe -NoProfile -File $installer -SetupDir $pkg -InstallDir $target -NoShortcuts -NoLaunch -NoWizard *> $null
        return [int]$LASTEXITCODE
    } finally {
        $env:Path = $origPath
        $env:DSH_HOME = $origDshHome
    }
}

function Get-InstalledSettings([string]$target) {
    return Get-Content -LiteralPath (Join-Path $target 'settings.json') -Raw -Encoding UTF8 | ConvertFrom-Json
}

# 场景 A：没有 PATH dsh -> npx 持久化
$tA = Join-Path $base 'caseA'
if ((Invoke-HermeticInstall $tA) -ne 0) { $fail++; 'A FAILED: install' }
$sA = Get-InstalledSettings $tA
Assert-Equal "A mode=npx" $sA.dshRunnerMode 'npx'
Assert-Equal "A path empty" ([string]$sA.dshPath) ''

# 场景 B：PATH 里有 rc.7 dsh -> command 持久化
$dshCmd = Join-Path $shimDir 'dsh.cmd'
"@echo off`r`necho 0.1.0-rc.7`r`n" | Set-Content -LiteralPath $dshCmd -Encoding ascii
$tB = Join-Path $base 'caseB'
if ((Invoke-HermeticInstall $tB) -ne 0) { $fail++; 'B FAILED: install' }
$sB = Get-InstalledSettings $tB
Assert-Equal "B mode=command" $sB.dshRunnerMode 'command'
Assert-Equal "B path is dsh.cmd" ([IO.Path]::GetFileName([string]$sB.dshPath)) 'dsh.cmd'

# 场景 C（核心回归）：PATH 里有 rc.6（低于验证基线）-> 非交互自动改 npx，且 mode=npx 持久化
"@echo off`r`necho 0.1.0-rc.6`r`n" | Set-Content -LiteralPath $dshCmd -Encoding ascii
$tC = Join-Path $base 'caseC'
if ((Invoke-HermeticInstall $tC) -ne 0) { $fail++; 'C FAILED: install' }
$sC = Get-InstalledSettings $tC
Assert-Equal "C mode=npx (rc.6 rejected)" $sC.dshRunnerMode 'npx'
Assert-Equal "C path empty" ([string]$sC.dshPath) ''

# 场景 D：PATH 里有 rc.8（高于验证基线，未验证）-> 非交互自动改 npx
"@echo off`r`necho 0.1.0-rc.8`r`n" | Set-Content -LiteralPath $dshCmd -Encoding ascii
$tD = Join-Path $base 'caseD'
if ((Invoke-HermeticInstall $tD) -ne 0) { $fail++; 'D FAILED: install' }
$sD = Get-InstalledSettings $tD
Assert-Equal "D mode=npx (rc.8 unverified)" $sD.dshRunnerMode 'npx'
Assert-Equal "D path empty" ([string]$sD.dshPath) ''

Remove-Item -LiteralPath $base -Recurse -Force -ErrorAction SilentlyContinue
if ($fail -eq 0) { Write-Host 'RUNNER MODE TESTS PASSED' } else { Write-Host "FAILURES: $fail" }
exit $(if ($fail -eq 0) { 0 } else { 1 })