$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$source = Join-Path $repo 'src\DeepSeekHarness.cs'
$hostExe = Join-Path $PSHOME $(if ($PSVersionTable.PSEdition -eq 'Core') { 'pwsh.exe' } else { 'powershell.exe' })

$fail = 0
function Assert-True([string]$label, [bool]$condition) {
    if ($condition) { Write-Host "PASS: $label" }
    else { $fail++; Write-Host "FAIL: $label" }
}

# ---- 1. 源码级守卫：启动参数绝不能拼出 "--profile <profile> web" ----
# 官方 CLI：`dsh web` 是 `dsh --profile web` 的别名，两者叠加会被
# rejectParentOptions('web') 拒绝（"web takes none of parent --profile ..."）。
$cs = [System.IO.File]::ReadAllText($source)
Assert-True "no web-port suffix in arguments" ($cs -notmatch '" web --port "')
Assert-True "no web appended after profile arg" ($cs -notmatch 'QuoteArg\(profile\)\s*\+\s*" web')
Assert-True "uses --profile form" ($cs -match '" --profile " \+ QuoteArg\(profile\)')
Assert-True "passes --port" ($cs -match '" --port " \+ port\.ToString\(\)')

# ---- 2. 真实 CLI 探测（临时 DSH_HOME，--help 不启动服务、不写状态） ----
# 旧形态必须仍被 CLI 拒绝（证明该守卫有实际意义）；新形态必须能通过 launcher 参数解析。
# 注意：5.1 下原生 stderr（reject 错误）会变成错误记录，EAP=Stop 会中止脚本，
# 因此探测期间临时切到 Continue 并把 stderr 并入输出字符串。
function Invoke-NpxProbe([string[]]$argsList) {
    $oldEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        return (& npx @argsList 2>&1 | Out-String)
    } finally {
        $ErrorActionPreference = $oldEap
    }
}

$probeHome = Join-Path $env:TEMP ('dsh-launch-probe-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $probeHome | Out-Null
$oldHome = $env:DSH_HOME
$env:DSH_HOME = $probeHome
try {
    $oldOut = Invoke-NpxProbe @('-y', '@deepseek-ai/dsh@0.1.0-rc.7', '--profile', 'probe', 'web', '--help')
    $newOut = Invoke-NpxProbe @('-y', '@deepseek-ai/dsh@0.1.0-rc.7', '--profile', 'probe', '--help')
} finally {
    $env:DSH_HOME = $oldHome
    Remove-Item -LiteralPath $probeHome -Recurse -Force -ErrorAction SilentlyContinue
}
Assert-True "old form rejected by real CLI (takes none of parent)" ($oldOut -match 'takes none of parent')
Assert-True "new form passes launcher validation (no reject)" ($newOut -notmatch 'takes none of parent')
Write-Host '--- old form sample ---'
Write-Host ($oldOut.Substring(0, [Math]::Min(200, $oldOut.Length)))
Write-Host '--- new form sample ---'
Write-Host ($newOut.Substring(0, [Math]::Min(200, $newOut.Length)))

if ($fail -eq 0) { Write-Host 'LAUNCH ARGS TESTS PASSED' } else { Write-Host "FAILURES: $fail" }
exit $(if ($fail -eq 0) { 0 } else { 1 })