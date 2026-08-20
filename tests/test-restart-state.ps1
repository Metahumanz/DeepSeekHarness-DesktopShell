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
Assert-True "listener PID recorded on identity confirmed" ($cs -match 'if \(pid > 0\) ownedListenerPid = pid;')
Assert-True "identity probe verifies it is this DSH" ($cs -match 'ProbeListenerIdentity\(int port, int pid' -and $cs -match 'IsLikelyDshCommandLine\(commandLine, port, out dummy\)')
Assert-True "wrapper PID recorded at start" ($cs -match 'ownedWrapperPid = process\.Id;')

# ---- 1b. 四态状态机（P0-1/2/3/4）：Pending 绝不等于 Foreign ----
Assert-True "ListenerIdentity enum has five states" ($cs -match 'enum ListenerIdentity' -and $cs -match 'Pending' -and $cs -match 'OwnedJob' -and $cs -match 'VerifiedDsh' -and $cs -match 'Foreign')
Assert-True "no immediate NonDsh on open port (old bug pattern gone)" ($cs -notmatch 'IsDshReady\(port, 300\)')
Assert-True "PID missing -> Pending" ($cs -match 'if \(pid <= 0\) return ListenerIdentity\.Pending;')
Assert-True "command line unreadable -> Pending" ($cs -match 'if \(String\.IsNullOrWhiteSpace\(commandLine\)\) return ListenerIdentity\.Pending;')
Assert-True "IsProcessInJob declared" ($cs -match 'static extern bool IsProcessInJob')
Assert-True "job ownership proves own DSH tree" ($cs -match 'if \(IsProcessInJob\(p\.Handle, jobHandle, out inJob\) && inJob\)\s*return ListenerIdentity\.OwnedJob;')
Assert-True "foreign needs 4 stable confirmations" ($cs -match 'foreignStable >= 4')
Assert-True "grace retry every ~120ms" ($cs -match 'Thread\.Sleep\(120\);')
Assert-True "pending resets foreign stability counter" ($cs -match 'foreignPid = -1;\r?\n\s*foreignStable = 0;')

# ---- 1c. 启动成功即确认归属（P0-5） + 半失败清理（P0-6） ----
Assert-True "BackendStartResult returned by EnsureStarted" ($cs -match 'public class BackendStartResult' -and $cs -match 'public BackendStartResult EnsureStarted')
Assert-True "success requires confirmed listener" ($cs -match 'BACKEND ready wrapper=')
Assert-True "failed start cleans up owned job/process" ($cs -match 'START-CLEANUP begin' -and $cs -match 'START-CLEANUP done')
Assert-True "cleanup runs before rethrow" ($cs -match 'HostLog\.Line\("START-CLEANUP done"\);\r?\n\s*throw;')

# ---- 1d. 停止前冻结 listener 身份（P0-7） ----
Assert-True "FreezeOwnedListener exists" ($cs -match 'public void FreezeOwnedListener\(int port\)')
Assert-True "snapshot freezes listener before stopping" ($cs -match 'dsh\.FreezeOwnedListener\(stopRuntime\.port\);')

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
Assert-True "health timer restarted after restart when lifetime is active" ($cs -match 'restartBusy = false;\r?\n\s*healthFailures = 0;' -and $cs -match 'healthTimer\.Start\(\);')

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
    $wrapped = $cs -match ('RestartPhase(?:Async)?\("' + [regex]::Escape($phase) + '"')
    Assert-True "restart phase logged: $phase" ($literal -or $wrapped)
}
Assert-True "snapshot logs old wrapper/listener PIDs" ($cs -match 'SNAPSHOT oldWrapperPid=' -and $cs -match 'oldListenerPid=')
Assert-True "snapshot logs new wrapper/listener PIDs" ($cs -match 'SNAPSHOT-NEW newWrapperPid=' -and $cs -match 'newListenerPid=')
Assert-True "no generic RESTART-only log remains" ($cs -notmatch 'HostLog\.Enter\("RESTART"\)')

# ---- 5. 失败分流（A/B/C） ----
Assert-True "restart error classified by real backend state" ($cs -match 'private void HandleRestartError\(\s*Exception ex,\s*AppSettings oldRuntime,\s*AppSettings targetRuntime,\s*bool targetBackendReady')
Assert-True "case A: original backend still healthy" ($cs -match '重启未完成，原后端仍健康')
Assert-True "case B: old backend stopped" ($cs -match '旧后端已经停止')
Assert-True "case C: new backend listening, page restore failed" ($cs -match '新后端已就绪，页面恢复失败')
Assert-True "webViewReady recomputed from actual health" ($cs -match 'webViewReady = false;' -and $cs -match 'webViewReady = true;')

# ---- 6. 日志阶段错乱修复（P1-9）：RestartPhase 进入即更新 activeRestartPhase ----
Assert-True "activeRestartPhase updated on every phase entry" ($cs -match 'activeRestartPhase = phase;')
Assert-True "outer catch prints activeRestartPhase" ($cs -match 'HostLog\.Fail\("RESTART failed phase=" \+ activeRestartPhase, ex\);')
Assert-True "no stale restartPhase field remains" ($cs -notmatch 'private string restartPhase')

# ---- 7. 启动身份状态转换日志（P1-10） ----
Assert-True "PORT closed transition logged" ($cs -match '"PORT closed"')
Assert-True "pending transition logged" ($cs -match 'identity=pending')
Assert-True "inOwnJob transition logged" ($cs -match 'inOwnJob=true')
Assert-True "foreign stableCount logged" ($cs -match 'identity=foreign stableCount=')

# ---- 8. ready banner 辅助信号（P1-11） ----
Assert-True "sawReadyBanner field exists" ($cs -match 'private bool sawReadyBanner;')
Assert-True "banner detected in OnOutput" ($cs -match 'READY-BANNER seen port=')
Assert-True "banner is auxiliary only (job check still primary)" ($cs -match 'ProbeListenerIdentity\(port, pid, out commandLine\)')

if ($fail -eq 0) { Write-Host 'RESTART STATE TESTS PASSED' } else { Write-Host "FAILURES: $fail" }
exit $(if ($fail -eq 0) { 0 } else { 1 })
