$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$manifest = [System.IO.File]::ReadAllText((Join-Path $repo 'src\app.manifest'))
$matrix = [System.IO.File]::ReadAllText((Join-Path $repo 'docs\DPI_ACCEPTANCE.md'))

$fail = 0
function Assert-True([string]$label, [bool]$condition) {
    if ($condition) { Write-Host "PASS: $label" }
    else { $script:fail++; Write-Host "FAIL: $label" }
}

Assert-True 'manifest declares PerMonitorV2' ($manifest -match 'PerMonitorV2')
Assert-True 'DPI matrix covers 100%' ($matrix -match '\| 100% \|')
Assert-True 'DPI matrix covers 125%' ($matrix -match '\| 125% \|')
Assert-True 'DPI matrix covers 150%' ($matrix -match '\| 150% \|')
Assert-True 'DPI matrix covers 200%' ($matrix -match '\| 200% \|')
Assert-True 'matrix includes WebView2 and tray checks' ($matrix -match '托盘菜单' -and $matrix -match 'WebView2')
Assert-True 'matrix forbids speculative DPI refactor' ($matrix -match '不要把 DPI 重构')

if ($fail -eq 0) { Write-Host 'DPI MANIFEST TEST PASSED' } else { Write-Host "FAILURES: $fail" }
exit $(if ($fail -eq 0) { 0 } else { 1 })
