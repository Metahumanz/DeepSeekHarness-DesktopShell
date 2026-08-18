param([switch]$Force, [switch]$Full)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$appDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$statePath = Join-Path $appDir 'install-state.json'
$startMenu = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\DeepSeek Harness'
$homeDir = [Environment]::GetFolderPath('UserProfile')
$dshHome = if ($env:DSH_HOME) { $env:DSH_HOME } else { Join-Path $homeDir '.dsh' }
$preExisting = $false

if (Test-Path -LiteralPath $statePath -PathType Leaf) {
    try {
        $state = Get-Content -LiteralPath $statePath -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($state.dshHome) { $dshHome = [string]$state.dshHome }
        $preExisting = [bool]$state.dshHomeExistedBeforeInstall
    } catch {}
}

# 只关闭“指定 exe 路径”的桌面程序；路径无法读取/不匹配的进程一律不碰。
# 绝不允许按进程名全杀：DSH 宿主本身也可能叫 DeepSeekHarness。
function Stop-DesktopShellProcess([string]$exePath) {
    if ([string]::IsNullOrWhiteSpace($exePath)) { return }
    $target = ''
    try { $target = [IO.Path]::GetFullPath($exePath) } catch { return }
    Get-Process -Name 'DeepSeekHarness' -ErrorAction SilentlyContinue | ForEach-Object {
        $procPath = ''
        try { $procPath = [IO.Path]::GetFullPath($_.MainModule.FileName) } catch { return }
        if ($procPath -ne $target) { return }
        try {
            $_.CloseMainWindow() | Out-Null
            Start-Sleep -Milliseconds 700
            if (-not $_.HasExited) { Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue }
        } catch {}
    }
}

function Stop-Shell {
    Stop-DesktopShellProcess (Join-Path $appDir 'DeepSeekHarness.exe')
}

function Ask-UninstallMode {
    if ($Force) {
        return $(if ($Full) { 'full' } else { 'shell' })
    }

    $form = New-Object System.Windows.Forms.Form
    $form.Text = '卸载 DeepSeek Harness DesktopShell'
    $form.StartPosition = 'CenterScreen'
    $form.FormBorderStyle = 'FixedDialog'
    $form.MaximizeBox = $false
    $form.MinimizeBox = $false
    $form.ClientSize = New-Object System.Drawing.Size(560, 300)
    $form.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9)

    $title = New-Object System.Windows.Forms.Label
    $title.Text = '选择卸载方式'
    $title.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 14, [System.Drawing.FontStyle]::Bold)
    $title.AutoSize = $true
    $title.Location = New-Object System.Drawing.Point(24, 20)
    $form.Controls.Add($title)

    $desc = New-Object System.Windows.Forms.Label
    $desc.AutoSize = $false
    $desc.Size = New-Object System.Drawing.Size(510, 112)
    $desc.Location = New-Object System.Drawing.Point(26, 62)
    $desc.Text =
        "DesktopShell 和 DSH 是一套使用关系；不会提供「删除 DSH、只留下壳子」的卸载方式。`r`n`r`n" +
        "完整卸载：删除 DesktopShell + DSH_HOME（Profile、插件、会话、设置、storage）。`r`n" +
        "仅卸载桌面壳：保留 DSH_HOME，适合以后仍要单独使用 DSH。"
    $form.Controls.Add($desc)

    if ($preExisting) {
        $warn = New-Object System.Windows.Forms.Label
        $warn.AutoSize = $false
        $warn.Size = New-Object System.Drawing.Size(510, 42)
        $warn.Location = New-Object System.Drawing.Point(26, 175)
        $warn.ForeColor = [System.Drawing.Color]::FromArgb(190, 105, 25)
        $warn.Text = '注意：安装 DesktopShell 之前就检测到了现有 DSH_HOME；完整卸载会删除这份原有数据。'
        $form.Controls.Add($warn)
    }

    $fullBtn = New-Object System.Windows.Forms.Button
    $fullBtn.Text = '完整卸载'
    $fullBtn.Size = New-Object System.Drawing.Size(140, 38)
    $fullBtn.Location = New-Object System.Drawing.Point(72, 238)
    $fullBtn.Add_Click({ $form.Tag = 'full'; $form.Close() })
    $form.Controls.Add($fullBtn)

    $shellBtn = New-Object System.Windows.Forms.Button
    $shellBtn.Text = '仅卸载桌面壳'
    $shellBtn.Size = New-Object System.Drawing.Size(140, 38)
    $shellBtn.Location = New-Object System.Drawing.Point(220, 238)
    $shellBtn.Add_Click({ $form.Tag = 'shell'; $form.Close() })
    $form.Controls.Add($shellBtn)

    $cancelBtn = New-Object System.Windows.Forms.Button
    $cancelBtn.Text = '取消'
    $cancelBtn.Size = New-Object System.Drawing.Size(110, 38)
    $cancelBtn.Location = New-Object System.Drawing.Point(368, 238)
    $cancelBtn.Add_Click({ $form.Tag = 'cancel'; $form.Close() })
    $form.Controls.Add($cancelBtn)

    $form.CancelButton = $cancelBtn
    [void]$form.ShowDialog()
    return $(if ($form.Tag) { [string]$form.Tag } else { 'cancel' })
}

$mode = Ask-UninstallMode
if ($mode -eq 'cancel') { exit 0 }

if ($mode -eq 'full' -and -not $Force) {
    $detail =
        "将永久删除：`r`n`r`n" +
        "• DesktopShell`r`n" +
        "• $dshHome`r`n" +
        "• DSH Profile / 插件 / 会话 / 设置 / storage`r`n`r`n" +
        "npx/npm 缓存和 Node.js 不会删除。"
    if ($preExisting) {
        $detail += "`r`n`r`n这份 DSH_HOME 在安装 DesktopShell 前就已经存在。"
    }
    $confirm = [System.Windows.Forms.MessageBox]::Show(
        $detail + "`r`n`r`n确定继续完整卸载？",
        '确认完整卸载',
        [System.Windows.Forms.MessageBoxButtons]::YesNo,
        [System.Windows.Forms.MessageBoxIcon]::Warning)
    if ($confirm -ne [System.Windows.Forms.DialogResult]::Yes) { exit 0 }
}

Stop-Shell
Remove-Item -LiteralPath $startMenu -Recurse -Force -ErrorAction SilentlyContinue

if ($mode -eq 'full') {
    # 边界守卫：拒绝把用户主目录、盘符根、桌面壳自身目录当作 DSH_HOME 删除。
    $dangerous = $false
    if ([string]::IsNullOrWhiteSpace($dshHome)) { $dangerous = $true }
    else {
        $full = [IO.Path]::GetFullPath($dshHome).TrimEnd('\')
        $homeFull = [IO.Path]::GetFullPath($homeDir).TrimEnd('\')
        $appFull = [IO.Path]::GetFullPath($appDir).TrimEnd('\')
        $root = [IO.Path]::GetPathRoot($full).TrimEnd('\')
        if ($full -eq $homeFull -or $full -eq $root -or $full -eq $appFull -or
            $full.StartsWith($appFull + '\', [StringComparison]::OrdinalIgnoreCase)) { $dangerous = $true }
    }

    if ($dangerous) {
        [System.Windows.Forms.MessageBox]::Show(
            "DSH_HOME 路径不安全（$dshHome），已取消删除 DSH 用户数据，仅继续卸载桌面壳。",
            'DeepSeek Harness DesktopShell',
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
        $mode = 'shell'
    } elseif (Test-Path -LiteralPath $dshHome) {
        try {
            Remove-Item -LiteralPath $dshHome -Recurse -Force -ErrorAction Stop
        } catch {
            [System.Windows.Forms.MessageBox]::Show(
                "删除 DSH_HOME 失败：$($_.Exception.Message)`r`n桌面壳仍会继续卸载。",
                'DeepSeek Harness DesktopShell',
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
        }
    }
}

$tempScript = Join-Path $env:TEMP ("dsh-desktop-uninstall-" + [Guid]::NewGuid().ToString('N') + '.ps1')
$appEscaped = $appDir.Replace("'", "''")
@"
Start-Sleep -Seconds 2
Remove-Item -LiteralPath '$appEscaped' -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath `$PSCommandPath -Force -ErrorAction SilentlyContinue
"@ | Set-Content -LiteralPath $tempScript -Encoding UTF8

$runner = (Get-Command pwsh.exe -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty Source)
if (-not $runner) { $runner = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" }
Start-Process -FilePath $runner -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',"`"$tempScript`"") -WindowStyle Hidden

$msg = if ($mode -eq 'full') {
    '完整卸载已开始：DesktopShell 和 DSH_HOME 都会删除。'
} else {
    'DesktopShell 卸载已开始；DSH_HOME 保留，可继续单独使用 DSH。'
}
[System.Windows.Forms.MessageBox]::Show(
    $msg,
    'DeepSeek Harness DesktopShell',
    [System.Windows.Forms.MessageBoxButtons]::OK,
    [System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null
