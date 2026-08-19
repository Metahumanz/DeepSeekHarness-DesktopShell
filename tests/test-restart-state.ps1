$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$source = Join-Path $repo 'src\DeepSeekHarness.cs'

$fail = 0
function Assert-True([string]$label, [bool]$condition) {
    if ($condition) { Write-Host "PASS: $label" }
    else { $script:fail++; Write-Host "FAIL: $label" }
}

# 重启事务源码门禁：这些是纯 C# 行为（进程停止链/竞态/日志），用源码级断言钉住结构，
# 防止回归成“一把梭 StopBackend + 笼统 RESTART 日志”的老实现。
$cs = [System.IO.File]::ReadAllText($source)

# ---- 1. 记录真正 listener PID（wrapper 只是 cmd/npx 包装进程） ----
Assert-True "ownedListenerPid field exists" ($cs -match 'private int ownedListenerPid = -1;')
Assert-True "listener PID captured on first ready" ($cs -match 'CaptureOwnedListenerPid\(port\)')
Assert-true "listener capture verifies it is this DSH" ($cs -match 'if \(IsLikelyDshProcess\(pid, out commandLine, port\)\)')
Assert-True "wrapper PID recorded at start" ($cs -match 'ownedWrapperPid = process\.Id;')

# ---- 2. 停止链：WaitForExit + 身份验证兜底 + 端口两次确认 ----
Assert-True "stop waits for wrapper exit (3s)" ($cs -match 'process\.WaitForExit\(3000\)')
Assert-True "listener fallback exists" ($cs -match 'public void TryStopListenerFallback\(int port\)')
Assert-True "fallback refuses unverified identity" ($cs -match 'STOP-FALLBACK refused')
Assert-True "fallback re-verifies DSH identity first" ($cs -match 'if \(IsLikelyDshProcess\(currentPid, out commandLine, port\)\)')
Assert-True "port must close twice before success" ($cs -match 'public bool WaitForPortClosedTwice\(int port, int timeoutMs\)')
Assert-True "OwnsBackend released only after stop sequence" ($cs -match 'OwnsBackend = false;\r?\n\s*HostLog\.Line\("STOP-OWNED complete')

# ---- 3. 健康检查竞态（generation） ----
Assert-True "backendGeneration field exists" ($cs -match 'private long backendGeneration;')
Assert-True "restart bumps generation and stops health timer" ($cs -match 'healthTimer\.Stop\(\);\r?\n\s*backendGeneration\+\+;')
Assert-True "stale generation results dropped" ($cs -match 'if \(generation != backendGeneration\) return;')
Assert-True "health timer restarted after restart" ($cs -match 'finally\r?\n\s*\{\r?\n\s*restartBusy = false;\r?\n\s*healthFailures = 0;\r?\n\s*healthTimer\.Start\(\);')

# ---- 4. 重启分阶段日志（10 个阶段 + 快照 PID） ----
# RestartPhase("...") 包装的阶段在源码里是 RestartPhase("phase", ...) 形式，
# preflight/navigate/complete 是字面量 "RESTART phase=..." 形式，两种都接受。
$phases = @(
    'restart.preflight','restart.snapshot','restart.stop-wrapper','restart.wait-port-close',
    'restart.stop-listener-fallback','restart.compat','restart.start','restart.wait-ready',
    'restart.navigate','restart.complete'
)
foreach ($phase in $phases) {
    $literal = $cs -match ('RESTART phase=' + [regex]::Escape($phase))
    $wrapped = $cs -match ('RestartPhase\("' + [regex]::Escape($phase) + '"')
    Assert-True "restart phase logged: $phase" ($literal -or $wrapped)
}
Assert-True "snapshot logs old wrapper/listener PIDs" ($cs -match 'SNAPSHOT oldWrapperPid=' -and $cs -match 'oldListenerPid=')
Assert-True "snapshot logs new wrapper/listener PIDs" ($cs -match 'SNAPSHOT-NEW newWrapperPid=' -and $cs -match 'newListenerPid=')
Assert-True "no generic RESTART-only log remains" ($cs -notmatch 'HostLog\.Enter\("RESTART"\)')

# ---- 5. 失败分流（A/B/C） ----
Assert-True "restart error classified by real backend state" ($cs -match 'private void HandleRestartError\(Exception ex\)')
Assert-True "case A: original backend still healthy" ($cs -match '重启未完成，原后端仍健康')
Assert-True "case B: old backend stopped" ($cs -match '旧后端已经停止')
Assert-True "case C: new backend listening, page restore failed" ($cs -match '新后端已就绪，页面恢复失败')
Assert-True "webViewReady recomputed from actual health" ($cs -match 'webViewReady = backendStillHealthy;')

if ($fail -eq 0) { Write-Host 'RESTART STATE TESTS PASSED' } else { Write-Host "FAILURES: $fail" }
exit $(if ($fail -eq 0) { 0 } else { 1 })
