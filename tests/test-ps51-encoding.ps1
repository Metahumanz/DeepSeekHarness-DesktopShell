$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$files = @(Get-ChildItem -Path (Join-Path $repo 'scripts'), (Join-Path $repo 'tests') -Filter *.ps1 -Recurse)
$fail = 0

function Assert-True([string]$label, [bool]$condition) {
    if ($condition) { Write-Host "PASS: $label" }
    else { $script:fail++; Write-Host "FAIL: $label" }
}

foreach ($file in $files) {
    $bytes = [System.IO.File]::ReadAllBytes($file.FullName)
    $hasBom = $bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF
    $offset = if ($hasBom) { 3 } else { 0 }
    $content = [System.Text.Encoding]::UTF8.GetString($bytes, $offset, $bytes.Length - $offset)
    $hasNonAscii = $content -match '[^\u0000-\u007F]'
    $relative = $file.FullName.Substring($repo.Length + 1)

    if ($hasNonAscii) {
        Assert-True "$relative uses UTF-8 BOM when it contains non-ASCII source text" $hasBom
    }
}

if ($fail -eq 0) { Write-Host 'PS5.1 ENCODING TESTS PASSED' }
else { Write-Host "FAILURES: $fail" }
exit $(if ($fail -eq 0) { 0 } else { 1 })
