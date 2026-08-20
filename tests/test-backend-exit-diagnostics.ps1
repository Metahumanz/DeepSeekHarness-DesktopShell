$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$source = Join-Path $repo 'src\DeepSeekHarness.cs'
$cs = [System.IO.File]::ReadAllText($source)

$fail = 0
function Assert-True([string]$label, [bool]$condition) {
    if ($condition) { Write-Host "PASS: $label" }
    else { $script:fail++; Write-Host "FAIL: $label" }
}

Assert-True 'backend exit event carries identity and state' (
    $cs -match 'class BackendProcessExitedEventArgs' -and
    $cs -match 'WrapperPid' -and
    $cs -match 'ExitCode' -and
    $cs -match 'ExpectedStop' -and
    $cs -match 'BootReadyAtExit')
Assert-True 'manager exposes backend state and exit event' (
    $cs -match 'public string BackendState' -and
    $cs -match 'BackendProcessExited' -and
    $cs -match 'BackendState = "Starting"' -and
    $cs -match 'BackendState = "Running"')
Assert-True 'process exit is observed before normal cleanup' (
    $cs -match 'process\.Exited \+= OnProcessExited' -and
    $cs -match 'private void OnProcessExited')
Assert-True 'desktop-shell log records unexpected process exit fields' (
    $cs -match 'BACKEND process-exited wrapperPid=' -and
    $cs -match 'expectedStop=' -and
    $cs -match 'state=" \+ state')
Assert-True 'stdout and stderr are captured from process start' (
    $cs -match 'process\.OutputDataReceived \+= OnOutput' -and
    $cs -match 'process\.ErrorDataReceived \+= OnError' -and
    $cs -match 'CaptureOutput\("stdout"' -and
    $cs -match 'CaptureOutput\("stderr"')
Assert-True 'recent output is bounded and fatal summary is extracted' (
    $cs -match 'Queue<string> recentOutput' -and
    $cs -match 'RecentOutputLimit' -and
    $cs -match 'GetRecentFailureSummary' -and
    $cs -match 'plugin tree' -and
    $cs -match 'loader entry')
Assert-True 'output drain is bounded after process exit' (
    $cs -match 'WaitForOutputDrain' -and
    $cs -match 'WaitOne\(1000\)')
Assert-True 'MainForm routes post-BootReady exit to runtime interruption' (
    $cs -match 'dsh\.BackendProcessExited \+= OnBackendProcessExited' -and
    $cs -match 'private void OnBackendProcessExited' -and
    $cs -match 'e\.ExpectedStop' -and
    $cs -match 'e\.BootReadyAtExit' -and
    $cs -match 'ShowBackendInterruption')
Assert-True 'startup overlay includes captured backend summary' (
    $cs -match '后端最后错误摘要' -and
    $cs -match '后端最近 stdout/stderr')

if ($fail -eq 0) { Write-Host 'BACKEND EXIT DIAGNOSTICS TESTS PASSED' } else { Write-Host "FAILURES: $fail" }
exit $(if ($fail -eq 0) { 0 } else { 1 })
