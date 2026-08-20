$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$cs = [System.IO.File]::ReadAllText((Join-Path $repo 'src\DeepSeekHarness.cs'))

$fail = 0
function Assert-True([string]$label, [bool]$condition) {
    if ($condition) { Write-Host "PASS: $label" }
    else { $script:fail++; Write-Host "FAIL: $label" }
}
function Get-MethodBody([string]$text, [string]$signature, [string]$nextSignature) {
    $start = $text.IndexOf($signature, [System.StringComparison]::Ordinal)
    if ($start -lt 0) { return '' }
    $end = $text.IndexOf($nextSignature, $start + $signature.Length, [System.StringComparison]::Ordinal)
    if ($end -lt 0) { $end = $text.Length }
    return $text.Substring($start, $end - $start)
}

$owner = Get-MethodBody $cs 'private IWin32Window EffectiveDialogOwner()' 'private bool TryBeginRecoveryOperation'
Assert-True 'unified dialog owner helper exists' ($owner -match 'IWin32Window EffectiveDialogOwner')
Assert-True 'tray owner is null' ($owner -match 'if \(hiddenToTray\) return null;')
Assert-True 'visible valid MainForm is owner' ($owner -match 'Visible && IsHandleCreated && !IsDisposed && !Disposing' -and $owner -match 'return this;')

$settings = Get-MethodBody $cs 'private async Task ShowSettingsAsync()' 'private void RestoreFromTray()'
Assert-True 'settings chooses EffectiveDialogOwner' ($settings -match 'IWin32Window owner = EffectiveDialogOwner\(\)')
Assert-True 'tray settings use ownerless ShowDialog' ($settings -match 'dialog\.ShowDialog\(\)')
Assert-True 'ownerless settings are centered on screen' ($settings -match 'dialog\.StartPosition = FormStartPosition\.CenterScreen')
Assert-True 'settings does not restore main window' ($settings -notmatch 'RestoreFromTray')

$restart = Get-MethodBody $cs 'private async Task RestartBackendAsync()' 'private void HandleRestartError(Exception ex)'
$external = Get-MethodBody $cs 'private void OpenExternalUri(string uriText)' 'private void OnOverlayReloadPage'
Assert-True 'external DSH confirmation uses effective owner' ($restart -match 'ThemedMessageBox\.Show\(EffectiveDialogOwner\(\)')
Assert-True 'external URI confirmation uses effective owner' ($external -match 'ThemedMessageBox\.Show\(' -and $external -match 'EffectiveDialogOwner\(\)')

$closing = Get-MethodBody $cs 'private void OnFormClosing(object sender, FormClosingEventArgs e)' 'private void ShutdownAndClose()'
Assert-True 'close choice uses effective owner' ($closing -match 'IWin32Window owner = EffectiveDialogOwner\(\)' -and $closing -match 'owner == null \? dialog\.ShowDialog\(\)')
Assert-True 'themed message box supports null owner center screen' ($cs -match 'owner == null \? FormStartPosition\.CenterScreen : FormStartPosition\.CenterParent' -and $cs -match 'return owner == null \? dialog\.ShowDialog\(\)')

if ($fail -eq 0) { Write-Host 'DIALOG OWNER TEST PASSED' } else { Write-Host "FAILURES: $fail" }
exit $(if ($fail -eq 0) { 0 } else { 1 })
