$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$installer = Join-Path $repo 'scripts\Install-Release.ps1'
$base = Join-Path $env:TEMP ('dsh-own-test-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $base | Out-Null

$appFiles = @(
    'DeepSeekHarness.exe','Microsoft.Web.WebView2.Core.dll','Microsoft.Web.WebView2.WinForms.dll',
    'WebView2Loader.dll','DeepSeekHarness.ico','DeepSeekHarness-Light.ico','DeepSeekHarness-Dark.ico',
    'DeepSeekHarness.svg','Manage-Dsh.ps1','Uninstall-DesktopShell.ps1','version.txt'
)

function New-FakePkg([string]$dir) {
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    foreach ($f in $appFiles) { Set-Content -LiteralPath (Join-Path $dir $f) -Value 'x' -Encoding ascii }
    Set-Content -LiteralPath (Join-Path $dir 'install.bat') -Value '@echo off' -Encoding ascii
}

function Invoke-Install([string]$setup, [string]$target, [string]$label) {
    & pwsh -NoProfile -File $installer -SetupDir $setup -InstallDir $target -NoShortcuts -NoLaunch -NoWizard *> $null
    $code = [int]$LASTEXITCODE
    Write-Host ("{0}: exit={1}" -f $label, $code)
    return $code
}

$fail = 0
$pkg = Join-Path $base 'pkg'
New-FakePkg $pkg

# T1: 全新目录 -> 成功，marker + install-state 存在
$t1 = Join-Path $base 'fresh-install'
if ((Invoke-Install $pkg $t1 'T1 fresh-dir') -ne 0) { $fail++; 'T1 FAILED: install' }
$m1 = Test-Path -LiteralPath (Join-Path $t1 '.dsh-desktop-shell-root')
$s1 = Test-Path -LiteralPath (Join-Path $t1 'install-state.json')
Write-Host ("T1 marker={0} state={1}" -f $m1, $s1)
if (-not ($m1 -and $s1)) { $fail++; 'T1 FAILED: marker/state missing' }

# T2: 已存在的空目录 -> 成功
$t2 = Join-Path $base 'empty-dir'
New-Item -ItemType Directory -Force -Path $t2 | Out-Null
if ((Invoke-Install $pkg $t2 'T2 empty-dir') -ne 0) { $fail++; 'T2 FAILED' }

# T3: 非空且非 DesktopShell 的目录 -> 拒绝
$t3 = Join-Path $base 'shared-dir'
New-Item -ItemType Directory -Force -Path $t3 | Out-Null
Set-Content -LiteralPath (Join-Path $t3 'user-file.txt') -Value 'keep me'
if ((Invoke-Install $pkg $t3 'T3 non-empty-shared') -eq 0) { $fail++; 'T3 FAILED: should refuse' }
$t3kept = Test-Path -LiteralPath (Join-Path $t3 'user-file.txt')
Write-Host ("T3 user-file-kept=$t3kept")
if (-not $t3kept) { $fail++; 'T3 FAILED: user file touched' }

# T4: 盘符根 -> 拒绝
if ((Invoke-Install $pkg 'C:\' 'T4 drive-root') -eq 0) { $fail++; 'T4 FAILED: should refuse' }

# T5: 用户主目录 -> 拒绝
if ((Invoke-Install $pkg $env:USERPROFILE 'T5 user-home') -eq 0) { $fail++; 'T5 FAILED: should refuse' }

# T6: 就地安装且目录内只有发布包文件 -> 成功
$t6 = Join-Path $base 'inplace-ok'
New-FakePkg $t6
if ((Invoke-Install $t6 $t6 'T6 inplace-clean') -ne 0) { $fail++; 'T6 FAILED' }
Write-Host ("T6 marker={0}" -f (Test-Path -LiteralPath (Join-Path $t6 '.dsh-desktop-shell-root')))

# T7: 就地安装但目录内有额外文件 -> 拒绝
$t7 = Join-Path $base 'inplace-extra'
New-FakePkg $t7
Set-Content -LiteralPath (Join-Path $t7 'user-file.txt') -Value 'keep me'
if ((Invoke-Install $t7 $t7 'T7 inplace-extra') -eq 0) { $fail++; 'T7 FAILED: should refuse' }
Write-Host ("T7 extra-kept={0}" -f (Test-Path -LiteralPath (Join-Path $t7 'user-file.txt')))

# T8: 已拥有目录上的重复安装（升级）-> 成功
if ((Invoke-Install $pkg $t1 'T8 upgrade-over-owned') -ne 0) { $fail++; 'T8 FAILED' }

# T9: DSH_HOME 内部 -> 拒绝（目标在 ~/.dsh 内部）
$dshHomeReal = if ($env:DSH_HOME) { $env:DSH_HOME } else { Join-Path $env:USERPROFILE '.dsh' }
$t9 = Join-Path $dshHomeReal 'desktop-inner-test'
if ((Invoke-Install $pkg $t9 'T9 inside-dsh-home') -eq 0) { $fail++; 'T9 FAILED: should refuse' }
Write-Host ("T9 dir-created={0}" -f (Test-Path -LiteralPath $t9))

# T10: 损坏 marker -> 拒绝（marker 存在但 product 不符）
$t10 = Join-Path $base 'bad-marker'
New-Item -ItemType Directory -Force -Path $t10 | Out-Null
'{ "product": "something-else" }' | Set-Content -LiteralPath (Join-Path $t10 '.dsh-desktop-shell-root') -Encoding UTF8
if ((Invoke-Install $pkg $t10 'T10 bad-marker') -eq 0) { $fail++; 'T10 FAILED: should refuse' }
Write-Host ("T10 marker-still-bad={0}" -f (Test-Path -LiteralPath (Join-Path $t10 '.dsh-desktop-shell-root')))

if ($fail -eq 0) { Write-Host 'ALL INSTALL TESTS PASSED' } else { Write-Host "FAILURES: $fail" }
Remove-Item -LiteralPath $base -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath $t9 -Recurse -Force -ErrorAction SilentlyContinue
exit $(if ($fail -eq 0) { 0 } else { 1 })