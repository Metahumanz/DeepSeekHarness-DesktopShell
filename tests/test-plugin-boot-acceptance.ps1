$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$managePath = Join-Path $repo 'scripts\Manage-Dsh.ps1'
$preflightPath = Join-Path $repo 'scripts\Test-PluginBootPreflight.ps1'
$csPath = Join-Path $repo 'src\DeepSeekHarness.cs'
$manage = [System.IO.File]::ReadAllText($managePath)
$preflight = [System.IO.File]::ReadAllText($preflightPath)
$cs = [System.IO.File]::ReadAllText($csPath)

$fail = 0
function Assert-True([string]$label, [bool]$condition) {
    if ($condition) { Write-Host "PASS: $label" }
    else { $script:fail++; Write-Host "FAIL: $label" }
}

$catalogStart = $manage.IndexOf('$PluginCatalog = @(', [System.StringComparison]::Ordinal)
$catalogEnd = $manage.IndexOf('function Read-Default', $catalogStart, [System.StringComparison]::Ordinal)
$catalog = if ($catalogStart -ge 0 -and $catalogEnd -gt $catalogStart) {
    $manage.Substring($catalogStart, $catalogEnd - $catalogStart)
} else { '' }

Assert-True 'daily manager does not boot-test a user Profile' (
    $manage -notmatch 'Test-PluginProfileBootCompatibility' -and
    $manage -notmatch 'New-PluginBootProbeCommand' -and
    $manage -match '日常插件安装只确认 package 安装成功' -and
    $manage -match '不启动用户真实 Profile')
Assert-True 'independent preflight uses a new temporary DSH_HOME' (
    $preflight -match '\$tempHome = Join-Path \(\[IO\.Path\]::GetTempPath\(\)\)' -and
    $preflight -match '\$env:DSH_HOME = \$tempHome' -and
    $preflight -match '所有子进程.*临时 DSH_HOME')
Assert-True 'preflight uses an isolated temporary Profile and refuses unsafe construction' (
    $preflight -match 'Normalize-IsolatedProfile' -and
    $preflight -match '\$profileDir = Join-Path \$tempHome' -and
    $preflight -match '未返回兼容 PASS')
Assert-True 'preflight installs plugins before booting the isolated Profile' (
    $preflight -match '\x27plugin\x27,\s+\x27--profile\x27,\s+\$profile,\s+\x27add\x27,\s+\$spec' -and
    $preflight -match '@deepseek-ai/dsh-web-app@' -and
    $preflight -match 'Web 基础包/插件安装后未发现临时 Profile' -and
    $preflight -match '\$webArgs = New-DshArguments @\(\x27--profile\x27,\s+\$profile,\s+\x27--port\x27' -and
    $preflight -notmatch 'New-DshArguments @\(\x27web\x27,\s+\x27--profile\x27')
Assert-True 'preflight uses a random port and the full BootReady gate' (
    $preflight -match 'Get-FreeTcpPort' -and
    $preflight -match 'dsh\\s\+web\\s\*:' -and
    $preflight -match 'Test-Http200' -and
    $preflight -match 'Get-Content -LiteralPath \$path -Raw' -and
    $preflight -match '\$StableSeconds' -and
    $preflight -match '\$installTimeoutMs = \[Math\]::Max' -and
    $preflight -match '\$webProcess\.HasExited')
Assert-True 'preflight accepts BrowserAuth ready URLs without exposing their token' (
    $preflight -match 'Get-DshReadyUrl' -and
    $preflight -match 'MaximumAutomaticRedirections = 3' -and
    $preflight -match 'Redact-BrowserAuthText')
Assert-True 'special plugin validations prove capabilities instead of pinning an obsolete release number' (
    $preflight -match 'BrowserProbeSeconds' -and
    $preflight -match 'Status Rotator 缺少可识别的 package.json 版本' -and
    $preflight -match 'Thought Buddy 缺少可识别的 package.json 版本' -and
    $preflight -notmatch "version -ne '0\.6\.6'" -and
    $preflight -notmatch "version -ne '0\.2\.0'")
Assert-True 'preflight probes --no-open from CLI help instead of listing each future DSH version' (
    $preflight -match 'function Test-DshNoOpenSupport' -and
    $preflight -match 'New-DshArguments @\(\x27--profile\x27, \$profile, \x27--help\x27\)' -and
    $preflight -match 'Test-DshNoOpenSupport \$profile \$tempHome' -and
    $preflight -notmatch "0\.1\.2-alpha\.3.*0\.1\.2-alpha\.4")
Assert-True 'preflight cleans only its own process tree and restores DSH_HOME' (
    $preflight -match 'Stop-ProcessTree' -and
    $preflight -match 'Get-ListeningPidForPort' -and
    $preflight -match 'Stop-ListenerByPort' -and
    $preflight -match 'Wait-PortClosed' -and
    $preflight -match 'taskkill\.exe' -and
    $preflight -match '/PID \$processToStop\.Id /T /F' -and
    $preflight -match 'Remove-Item Env:DSH_HOME' -and
    $preflight -match 'cleanup=closed' -and
    $preflight -notmatch 'Get-Process\s+node|Get-Process\s+cmd|Get-Process\s+powershell')
Assert-True 'install success is explicitly not compatibility success' (
    $manage -match '仅安装成功，尚未证明运行兼容' -and
    $manage -match '安装成功 ≠ 运行兼容' -and
    $manage -match '独立 release preflight')
Assert-True 'dsh-remote is absent from the active recommendation catalog' (
    $catalog -notmatch "Id='remote'" -and
    $catalog -notmatch 'dsh-remote' -and
    $catalog -match 'No=25; Id=\x27thought-buddy\x27' -and
    $catalog -match 'No=26; Id=\x27agent-teams\x27')
Assert-True 'active catalog keeps the audited rc2 plugin set and pins the validated Cost Meter release' (
    $catalog -match "Id='market'.*dshmarket@1\.41\.0" -and
    $catalog -match "Id='sidebar'.*dsh-better-sidebar@0\.17\.1" -and
    $catalog -match "Id='skills'.*@michengai/dsh-skills-manager@0\.1\.38" -and
    $catalog -match "Id='at-file'.*github:omdsh-dev/dsh-at-file#v0\.7\.0" -and
    $catalog -match "Id='file-mentions'.*github:a903067276-rgb/dsh-file-mentions#v1\.0\.13" -and
    $catalog -match "Id='collapse'.*github:a179-sanae/dsh-auto-collapse#v0\.1\.5" -and
    $catalog -match "Id='rewind'.*github:XSJUSTC/dsh-rewind" -and
    $catalog -match "Id='outline'.*github:EnkiduGilgamesh/dsh-codex-side-outline#v1\.1\.1" -and
    $catalog -match "Id='video'.*dsh-video-preview@0\.1\.4" -and
    $catalog -match "Id='notification'.*github:omdsh-dev/dsh-notification#v0\.1\.4" -and
    $catalog -match "Id='cost'.*dsh-cost-meter@1\.7\.10" -and
    $catalog -match "Id='dream-skin'.*dsh-dream-skin@8\.30\.1" -and
    $catalog -match "Id='liangshen'.*@linxin666/dsh-liangshen@0\.3\.14" -and
    $catalog -match "Id='thought-buddy'.*@dsh-plugin/dsh-thought-buddy@0\.3\.3" -and
    $catalog -match "Id='status-rotator'.*dsh-status-rotator@0\.10\.0" -and
    $catalog -match "Id='context'.*dsh-context@0\.41\.3" -and
    $catalog -match "Id='agent-teams'.*@nanmicoder/dsh-agent-teams@0\.1\.14" -and
    $catalog -notmatch "Id='model-picker'" -and
    $catalog -notmatch "Id='modlens'" -and
    $catalog -notmatch 'open-in-vscode'
)
Assert-True 'local-only bridge-browser is documented but not offered as a portable plugin' (
    $manage -match '本地集成依赖' -and
    $manage -match 'bridge-browser' -and
    $catalog -notmatch 'dsh-bridge-browser'
)
Assert-True 'unverified plugin API mismatches offer an isolated Profile instead of modifying the real Profile' (
    $cs -match 'IsPluginLoaderApiMismatch' -and
    $cs -match 'does not provide an export named' -and
    $cs -match 'AllocateIsolatedPreviewProfileName' -and
    $cs -match 'OnOverlayUseIsolatedPreviewProfile' -and
    $cs -match '现有 Profile、插件、主题和会话不会被修改'
)

if ($fail -eq 0) { Write-Host 'PLUGIN BOOT ACCEPTANCE TESTS PASSED' }
else { Write-Host "FAILURES: $fail" }
exit $(if ($fail -eq 0) { 0 } else { 1 })
