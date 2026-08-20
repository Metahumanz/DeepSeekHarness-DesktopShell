$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$source = Join-Path $repo 'src/DeepSeekHarness.cs'

$fail = 0
function Assert-True([string]$label, [bool]$condition) {
    if ($condition) { Write-Host "PASS: $label" }
    else { $fail++; Write-Host "FAIL: $label" }
}

# ---- 1. 源码级守卫：启动参数绝不能拼出 "--profile <profile> web" ----
$cs = [System.IO.File]::ReadAllText($source)
Assert-True "no web-port suffix in arguments" ($cs -notmatch '" web --port "')
Assert-True "no web appended after profile arg" ($cs -notmatch 'QuoteArg\(profile\)\s*\+\s*" web')
Assert-True "uses --profile form" ($cs -match '" --profile " \+ QuoteArg\(profile\)')
Assert-True "passes --port" ($cs -match '" --port " \+ port\.ToString\(\)')

# ---- 2. 统一 CLI 能力检测与参数构造 ----
Assert-True "SupportsNoOpen probes --help for unknown versions" ($cs -match '--profile " \+ QuoteArg\(profile\) \+ " --help"')
Assert-True "SupportsNoOpen checks --no-open in output" ($cs -match 'IndexOf\("--no-open"')
Assert-True "SupportsNoOpen caches capability" ($cs -match 'supportsNoOpenCache')
Assert-True "SupportsNoOpen uses effectiveVersion" ($cs -match 'SupportsNoOpen\(command, usingNpx, effectiveVersion, profile\)')
Assert-True "cache key includes command path" ($cs -match 'string key = \(usingNpx \? "npx:" : "cmd:"\) \+ command \+ ":" \+ version \+ ":" \+ profile;')
Assert-True "known rc.8 short-circuits help probe" ($cs -match 'String\.Equals\(version, "0\.1\.0-rc\.8"' -and $cs -match 'supportsNoOpenCache = true;' -and $cs -match 'return true;')
Assert-True "known rc.8 => --no-open" ($cs -match 'if \(noOpen\)\s*args \+= " --no-open";')
Assert-True "BuildWebLaunchArguments shared by npx/command" ($cs -match 'BuildWebLaunchArguments\(usingNpx, version, profile, port, noOpen\)')
Assert-True "probe timeout uses bounded process-tree cleanup" ($cs -match 'KillProcessTree\(p\)' -and $cs -match 'taskkill\.exe' -and $cs -match 'WaitForExit\(5000\)')
Assert-True "no process-name based kill" ($cs -notmatch 'taskkill /IM')

# ---- 3. COMPATIBILITY.json 默认版本自洽 ----
$compat = Get-Content -LiteralPath (Join-Path $repo 'COMPATIBILITY.json') -Raw -Encoding UTF8 | ConvertFrom-Json
Assert-True "defaultDshVersion valid (got: $($compat.defaultDshVersion))" ($compat.defaultDshVersion -match '^\d+\.\d+\.\d+(?:-[A-Za-z0-9._+-]+)?$')
Assert-True "rc.8 is tested baseline" (@($compat.testedDshVersions | Where-Object { $_ -eq '0.1.0-rc.8' }).Count -gt 0)

if ($fail -eq 0) { Write-Host 'LAUNCH ARGS TESTS PASSED' } else { Write-Host "FAILURES: $fail" }
exit $(if ($fail -eq 0) { 0 } else { 1 })
