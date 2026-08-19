param(
    [string]$LedgerPath = '',
    [switch]$DryRun
)

<#
.SYNOPSIS
    清理 cost-meter 账本中被 ModLens 合成包装误计的条目（双倍计价修复）。

.DESCRIPTION
    删除所有 provider 键为 `deepseek-modlens:*` 或 `modlens-*:*` 的计费桶
    （日级 + 会话级），并从日/会话合计中扣减对应 token 与金额。
    修改前自动备份为 ledger.json.before-modlens-clean-<时间戳>.bak。
    桌面壳每次启动时（PluginCompat 兼容修复）也会自动执行同样的清理，
    因此本脚本主要用于立即修复当前账本。

    注意：正在运行中的 DSH 后端在内存中持有账本，关停时会写回。
    立即生效需要重启桌面壳；此后每次启动都会自动保持干净。

.EXAMPLE
    .\scripts\Repair-CostMeterLedger.ps1
    .\scripts\Repair-CostMeterLedger.ps1 -DryRun
    .\scripts\Repair-CostMeterLedger.ps1 -LedgerPath D:\backup\ledger.json
#>

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

# Windows PowerShell 5.1 与 PowerShell 7 均支持
if ($PSVersionTable.PSVersion -lt [version]'5.1') {
    Write-Host '[Repair] 需要 Windows PowerShell 5.1 或 PowerShell 7。' -ForegroundColor Red
    exit 1
}

function Say([string]$text) { Write-Host "[Repair] $text" -ForegroundColor Cyan }
function Ok([string]$text) { Write-Host "[OK] $text" -ForegroundColor Green }
function Warn([string]$text) { Write-Host "[!]   $text" -ForegroundColor Yellow }

$homeDir = [Environment]::GetFolderPath('UserProfile')
$dshHome = if ($env:DSH_HOME) { $env:DSH_HOME } else { Join-Path $homeDir '.dsh' }
if (-not $LedgerPath) { $LedgerPath = Join-Path $dshHome 'storages\cost-meter\ledger.json' }

if (-not (Test-Path -LiteralPath $LedgerPath -PathType Leaf)) {
    Warn "未找到账本：$LedgerPath"
    exit 0
}

$j = Get-Content -LiteralPath $LedgerPath -Raw -Encoding UTF8 | ConvertFrom-Json
$changed = $false
$removedBuckets = 0
$removedCalls = 0
$removedCost = 0.0

# 与 C# PluginCompat.RemoveSyntheticLedgerBuckets 完全一致的判断：
# deepseek-modlens:* 或 modlens-*（如 modlens-openrouter:gpt）。
# 注意不能用正则 '^(deepseek-modlens|modlens-):'——它会漏掉 modlens-*:* 这类键。
function Test-SyntheticKey([string]$key) {
    if ([string]::IsNullOrEmpty($key)) { return $false }
    return $key.StartsWith('deepseek-modlens:', [StringComparison]::Ordinal) -or
           $key.StartsWith('modlens-', [StringComparison]::Ordinal)
}

# 修复算法：删除合成桶后，从剩余合法 byProviderModel 重新汇总 totals
# （替代“总计减合成桶”的减法——旧账本本身已不一致时也能恢复一致）。
function Set-NodeTotals($node) {
    if (-not $node.byProviderModel) { return }
    $input = 0.0; $output = 0.0; $cacheRead = 0.0; $cacheWrite = 0.0
    $reasoning = 0.0; $calls = 0; $cost = 0.0
    foreach ($k in @($node.byProviderModel.PSObject.Properties.Name)) {
        $b = $node.byProviderModel.$k
        $input += [double]$b.input
        $output += [double]$b.output
        $cacheRead += [double]$b.cacheRead
        $cacheWrite += [double]$b.cacheWrite
        $reasoning += [double]$b.reasoning
        $calls += [int]$b.calls
        $cost += [double]$b.cost
    }
    $node.input = $input
    $node.output = $output
    $node.cacheRead = $cacheRead
    $node.cacheWrite = $cacheWrite
    $node.reasoning = $reasoning
    $node.calls = $calls
    $node.cost = $cost
}

$touched = New-Object System.Collections.Generic.List[object]

foreach ($dayName in @($j.days.PSObject.Properties.Name)) {
    $day = $j.days.$dayName
    if ($day.byProviderModel) {
        $drop = @($day.byProviderModel.PSObject.Properties | Where-Object { Test-SyntheticKey $_.Name } | ForEach-Object { $_.Name })
        foreach ($k in $drop) {
            $b = $day.byProviderModel.$k
            $day.byProviderModel.PSObject.Properties.Remove($k)
            $removedBuckets++
            $removedCalls += [int]$b.calls
            $removedCost += [double]$b.cost
            $changed = $true
            Say "日级 $dayName 移除 $k（calls=$($b.calls) cost=$($b.cost)）"
        }
        if ($drop.Count -gt 0) { $touched.Add($day) }
    }
    foreach ($s in @($day.sessions)) {
        if (-not $s.byProviderModel) { continue }
        $drop = @($s.byProviderModel.PSObject.Properties | Where-Object { Test-SyntheticKey $_.Name } | ForEach-Object { $_.Name })
        foreach ($k in $drop) {
            $b = $s.byProviderModel.$k
            $s.byProviderModel.PSObject.Properties.Remove($k)
            $removedBuckets++
            $removedCalls += [int]$b.calls
            $removedCost += [double]$b.cost
            $changed = $true
            Say "会话级 $($s.id) 移除 $k（calls=$($b.calls) cost=$($b.cost)）"
        }
        if ($drop.Count -gt 0) { $touched.Add($s) }
    }
}

if (-not $changed) {
    Ok '账本中没有 ModLens 合成条目，无需清理。'
    exit 0
}

if ($DryRun) {
    Say "DryRun：将移除 $removedBuckets 个桶（$removedCalls 次调用，金额 $removedCost），未写入。"
    exit 0
}

# 写入前重新汇总所有被修改节点的 totals（顺带归一化旧账本）
foreach ($node in $touched) { Set-NodeTotals $node }

$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$bak = "$LedgerPath.before-modlens-clean-$stamp.bak"
Copy-Item -LiteralPath $LedgerPath -Destination $bak -Force
Ok "备份：$bak"

$json = $j | ConvertTo-Json -Depth 100
$tmp = "$LedgerPath.tmp-$PID"
[System.IO.File]::WriteAllText($tmp, $json, [System.Text.UTF8Encoding]::new($false))
Move-Item -LiteralPath $tmp -Destination $LedgerPath -Force

Ok "已清理 $removedBuckets 个 ModLens 合成桶（$removedCalls 次调用，金额 $removedCost），并重新汇总 totals。"
Say '提示：正在运行的 DSH 后端内存中仍有旧账本，重启桌面壳后生效并持续保持干净。'
