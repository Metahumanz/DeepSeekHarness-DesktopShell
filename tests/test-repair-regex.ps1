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

Remove-Item -LiteralPath $testDir -Recurse -Force -ErrorAction SilentlyContinue
if ($fail -eq 0) { Write-Host 'REPAIR REGEX TESTS PASSED' } else { Write-Host "FAILURES: $fail" }
exit $(if ($fail -eq 0) { 0 } else { 1 })