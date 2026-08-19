$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$repair = Join-Path $repo 'scripts\Repair-CostMeterLedger.ps1'
# 宿主无关：用当前运行测试的 PowerShell 本体执行子进程（pwsh 与 5.1 均可）
$hostExe = Join-Path $PSHOME $(if ($PSVersionTable.PSEdition -eq 'Core') { 'pwsh.exe' } else { 'powershell.exe' })
$testDir = Join-Path $env:TEMP ('dsh-ledger-test-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $testDir | Out-Null

# 合成账本：4 个应删除的合成键（含旧正则会漏掉的 modlens-*:xxx 形式）+ 1 个正常键
$ledger = Join-Path $testDir 'ledger.json'
@'
{
  "days": {
    "2026-08-19": {
      "input": 100, "output": 100, "cacheRead": 0, "cacheWrite": 0, "reasoning": 0, "calls": 10, "cost": 5.0,
      "byProviderModel": {
        "deepseek-modlens:deepseek-chat": {"input":10,"output":10,"cacheRead":0,"cacheWrite":0,"reasoning":0,"calls":1,"cost":0.5},
        "modlens-openrouter:gpt": {"input":10,"output":10,"cacheRead":0,"cacheWrite":0,"reasoning":0,"calls":1,"cost":0.5},
        "modlens-:x": {"input":10,"output":10,"cacheRead":0,"cacheWrite":0,"reasoning":0,"calls":1,"cost":0.5},
        "openrouter:gpt": {"input":10,"output":10,"cacheRead":0,"cacheWrite":0,"reasoning":0,"calls":1,"cost":0.5}
      },
      "sessions": [
        {"id":"s1","input":50,"output":50,"cacheRead":0,"cacheWrite":0,"reasoning":0,"calls":5,"cost":2.5,
         "byProviderModel": {
           "modlens-foo:model": {"input":5,"output":5,"cacheRead":0,"cacheWrite":0,"reasoning":0,"calls":1,"cost":0.25},
           "openrouter:gpt": {"input":5,"output":5,"cacheRead":0,"cacheWrite":0,"reasoning":0,"calls":1,"cost":0.25}
         }}
      ]
    }
  }
}
'@ | Set-Content -LiteralPath $ledger -Encoding UTF8

$output = & $hostExe -NoProfile -File $repair -LedgerPath $ledger -DryRun 2>&1 | Out-String
$code = $LASTEXITCODE
Write-Host $output

$fail = 0
if ($code -ne 0) { $fail++; 'FAILED: repair script exit code != 0' }
# 期望 4 个桶：deepseek-modlens:deepseek-chat、modlens-openrouter:gpt、modlens-:x、modlens-foo:model
if ($output -notmatch '将移除 4 个桶') { $fail++; 'FAILED: expected 4 buckets removed' }
if ($output -notmatch 'modlens-foo:model') { $fail++; 'FAILED: modlens-foo:model not removed (regex regression)' }
if ($output -notmatch 'modlens-openrouter:gpt') { $fail++; 'FAILED: modlens-openrouter:gpt not removed' }
if ($output -match 'openrouter:gpt.*移除') { $fail++; 'FAILED: normal bucket must not be removed' }

# ---- 真实写入 + 重新汇总：把 totals 故意写脏（999），修复后必须等于剩余合法桶之和 ----
$dirty = Join-Path $testDir 'ledger-dirty.json'
$j = Get-Content -LiteralPath $ledger -Raw -Encoding UTF8 | ConvertFrom-Json
$j.days.'2026-08-19'.input = 999
$j.days.'2026-08-19'.output = 999
$j.days.'2026-08-19'.calls = 999
$j.days.'2026-08-19'.cost = 999
$j.days.'2026-08-19'.sessions[0].input = 888
$j.days.'2026-08-19'.sessions[0].calls = 888
$j.days.'2026-08-19'.sessions[0].cost = 888
[System.IO.File]::WriteAllText($dirty, ($j | ConvertTo-Json -Depth 100), [System.Text.UTF8Encoding]::new($false))
$out2 = & $hostExe -NoProfile -File $repair -LedgerPath $dirty 2>&1 | Out-String
if ($LASTEXITCODE -ne 0) { $fail++; 'FAILED: dirty repair exit != 0' }
$fixed = Get-Content -LiteralPath $dirty -Raw -Encoding UTF8 | ConvertFrom-Json
$day = $fixed.days.'2026-08-19'
$daySumInput = 0.0
foreach ($k in @($day.byProviderModel.PSObject.Properties.Name)) { $daySumInput += [double]$day.byProviderModel.$k.input }
$daySumCalls = 0
foreach ($k in @($day.byProviderModel.PSObject.Properties.Name)) { $daySumCalls += [int]$day.byProviderModel.$k.calls }
$daySumCost = 0.0
foreach ($k in @($day.byProviderModel.PSObject.Properties.Name)) { $daySumCost += [double]$day.byProviderModel.$k.cost }
$sess = $day.sessions[0]
$sessSumInput = 0.0
foreach ($k in @($sess.byProviderModel.PSObject.Properties.Name)) { $sessSumInput += [double]$sess.byProviderModel.$k.input }
$sessSumCost = 0.0
foreach ($k in @($sess.byProviderModel.PSObject.Properties.Name)) { $sessSumCost += [double]$sess.byProviderModel.$k.cost }
# 剩余合法桶：日级 openrouter:gpt (input=10, calls=1, cost=0.5)；会话级 openrouter:gpt (input=5, cost=0.25)
if ([double]$day.input -ne 10.0) { $fail++; "FAILED: day.input not recomputed ($($day.input))" }
if ([int]$day.calls -ne 1) { $fail++; "FAILED: day.calls not recomputed ($($day.calls))" }
if ([double]$day.cost -ne 0.5) { $fail++; "FAILED: day.cost not recomputed ($($day.cost))" }
if ([double]$day.input -ne $daySumInput) { $fail++; 'FAILED: day.input != sum of remaining buckets' }
if ([int]$day.calls -ne $daySumCalls) { $fail++; 'FAILED: day.calls != sum of remaining buckets' }
if ([double]$day.cost -ne $daySumCost) { $fail++; 'FAILED: day.cost != sum of remaining buckets' }
if ([double]$sess.input -ne 5.0) { $fail++; "FAILED: session.input not recomputed ($($sess.input))" }
if ([double]$sess.cost -ne 0.25) { $fail++; "FAILED: session.cost not recomputed ($($sess.cost))" }
if ([double]$sess.input -ne $sessSumInput) { $fail++; 'FAILED: session.input != sum of remaining buckets' }
if ([double]$sess.cost -ne $sessSumCost) { $fail++; 'FAILED: session.cost != sum of remaining buckets' }
Write-Host "recompute assertions done (day.input=$($day.input) day.calls=$($day.calls) day.cost=$($day.cost) sess.input=$($sess.input) sess.cost=$($sess.cost))"

Remove-Item -LiteralPath $testDir -Recurse -Force -ErrorAction SilentlyContinue
if ($fail -eq 0) { Write-Host 'REPAIR REGEX TESTS PASSED' } else { Write-Host "FAILURES: $fail" }
exit $(if ($fail -eq 0) { 0 } else { 1 })