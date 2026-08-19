param([switch]$Force, [switch]$Full)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$appDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$statePath = Join-Path $appDir 'install-state.json'
$startMenu = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\DeepSeek Harness'
$homeDir = [Environment]::GetFolderPath('UserProfile')
$localAppData = if ($env:LOCALAPPDATA) { $env:LOCALAPPDATA } else { [Environment]::GetFolderPath('LocalApplicationData') }
$dshHome = if ($env:DSH_HOME) { $env:DSH_HOME } else { Join-Path $homeDir '.dsh' }
$preExisting = $false

$MarkerName = '.dsh-desktop-shell-root'
$ProductId = 'DeepSeek Harness DesktopShell'

# 目录所有权：只有安装端写入的 marker / install-state.json 产品标记有效。
function Test-ProductFile([string]$path) {
    if ([string]::IsNullOrWhiteSpace($path) -or -not (Test-Path -LiteralPath $path -PathType Leaf)) { return $false }
    try {
        $j = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
        return ($j.product -eq $ProductId)
    } catch { return $false }
}

function Test-DesktopShellOwned([string]$dir) {
    if ([string]::IsNullOrWhiteSpace($dir)) { return $false }
    return (Test-ProductFile (Join-Path $dir $MarkerName)) -or
           (Test-ProductFile (Join-Path $dir 'install-state.json'))
}

# 卸载器会递归删除本脚本所在目录，必须先证明目录所有权（P0）。
$owned = Test-DesktopShellOwned $appDir
if (-not $owned) {
    $msg = "无法确认此目录是 DeepSeek Harness DesktopShell 安装目录（缺少所有权标记 .dsh-desktop-shell-root / install-state.json）：`r`n$appDir`r`n`r`n为避免误删数据，卸载已取消，未删除任何文件。"
    if ($Force) {
        Write-Host ''
        Write-Host $msg -ForegroundColor Red
        exit 1
    }
    [System.Windows.Forms.MessageBox]::Show(
        $msg,
        'DeepSeek Harness DesktopShell',
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
    exit 1
}

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

# ---- 外部 DSH 识别与停止（完整卸载前） ----
# 桌面壳支持附着不是自己启动的 DSH；完整卸载删除 DSH_HOME 前必须先把外部 DSH 停掉，
# 否则运行中的 DSH 关停时会把内存中的账本/状态写回正在被删除的目录。
function Test-PortOpen([int]$port) {
    $client = [System.Net.Sockets.TcpClient]::new()
    try {
        $iar = $client.BeginConnect('127.0.0.1', $port, $null, $null)
        if (-not $iar.AsyncWaitHandle.WaitOne(250)) { return $false }
        $client.EndConnect($iar)
        return $true
    } catch { return $false } finally { $client.Dispose() }
}

function Find-ListeningPid([int]$port) {
    try {
        $out = & netstat -ano -p tcp 2>$null
        $suffix = ":$port"
        foreach ($line in $out) {
            $t = $line.Trim()
            if (-not $t.StartsWith('TCP', [StringComparison]::OrdinalIgnoreCase)) { continue }
            $parts = @($t -split '\s+')
            if ($parts.Count -lt 5) { continue }
            if (-not $parts[1].EndsWith($suffix, [StringComparison]::OrdinalIgnoreCase)) { continue }
            if (-not $parts[3].Equals('LISTENING', [StringComparison]::OrdinalIgnoreCase)) { continue }
            $pidNum = 0
            if ([int]::TryParse($parts[4], [ref]$pidNum)) { return $pidNum }
        }
    } catch {}
    return -1
}

function Get-ProcessCommandLine([int]$processId) {
    try {
        $p = Get-CimInstance Win32_Process -Filter "ProcessId = $processId"
        if ($p) { return [string]$p.CommandLine }
    } catch {}
    return ''
}

# 与 C# 端 IsLikelyDshProcess 一致的特征判断
function Test-LikelyDshCommandLine([string]$cmd) {
    if ([string]::IsNullOrWhiteSpace($cmd)) { return $false }
    $lower = $cmd.ToLowerInvariant()
    $hasPackage = $lower.Contains('@deepseek-ai') -and $lower.Contains('dsh')
    $hasPath = $lower.Contains('\dsh\') -or $lower.Contains('/dsh/') -or
               $lower.Contains('dsh.cmd') -or $lower.Contains('dsh.exe')
    $hasWeb = $lower.Contains(' web') -or $lower.Contains('"web"') -or $lower.Contains("'web'")
    return $hasWeb -and ($hasPackage -or $hasPath)
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

# DSH_HOME 单一事实源冲突检测：运行期以环境变量为准，而 install-state 记录安装时的路径。
# 两者不一致时不得静默二选一——交互模式列出两个路径让用户选择；无人值守拒绝猜测并降级。
if ($mode -eq 'full' -and $state -and $state.dshHome) {
    $envDshHome = if ($env:DSH_HOME) { $env:DSH_HOME } else { Join-Path $homeDir '.dsh' }
    $drift = $false
    try {
        $a = [IO.Path]::GetFullPath([string]$state.dshHome).TrimEnd('\')
        $b = [IO.Path]::GetFullPath($envDshHome).TrimEnd('\')
        if ($a -ne $b) { $drift = $true }
    } catch {}
    if ($drift) {
        if ($Force) {
            Write-Host "[!] 当前 DSH_HOME（$envDshHome）与安装时记录（$($state.dshHome)）不一致；无人值守模式拒绝猜测，已降级为仅卸载桌面壳（DSH_HOME 保留）。" -ForegroundColor Yellow
            $mode = 'shell'
        } else {
            $answer = [System.Windows.Forms.MessageBox]::Show(
                "检测到 DSH_HOME 不一致：`r`n`r`n安装时记录：$($state.dshHome)`r`n当前环境：$envDshHome`r`n`r`n" +
                "完整卸载需要删除 DSH_HOME，请选择删除哪一个：`r`n`r`n" +
                "[是] 删除安装时记录的路径`r`n[否] 删除当前环境变量路径`r`n[取消] 仅卸载桌面壳，两者都保留",
                'DeepSeek Harness DesktopShell',
                [System.Windows.Forms.MessageBoxButtons]::YesNoCancel,
                [System.Windows.Forms.MessageBoxIcon]::Warning)
            if ($answer -eq [System.Windows.Forms.DialogResult]::Yes) { $dshHome = [string]$state.dshHome }
            elseif ($answer -eq [System.Windows.Forms.DialogResult]::No) { $dshHome = $envDshHome }
            else { $mode = 'shell' }
        }
    }
}

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

# 完整卸载前：停止外部启动的 DSH（桌面壳只是附着它，退出不会带走它）。
# 停止失败/无法确认身份时降级为仅卸载桌面壳，绝不“宣称完整卸载成功”却留下
# 一个正在读写 DSH_HOME 的后端。
if ($mode -eq 'full') {
    $webPort = 3080
    $settingsFile = Join-Path $appDir 'settings.json'
    if (Test-Path -LiteralPath $settingsFile -PathType Leaf) {
        try {
            $cfg = Get-Content -LiteralPath $settingsFile -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($cfg.port -ge 1 -and $cfg.port -le 65535) { $webPort = [int]$cfg.port }
        } catch {}
    }

    if (Test-PortOpen $webPort) {
        $dshPid = Find-ListeningPid $webPort
        $cmdLine = ''
        if ($dshPid -gt 0) { $cmdLine = Get-ProcessCommandLine $dshPid }
        $isDsh = Test-LikelyDshCommandLine $cmdLine

        if ($dshPid -gt 0 -and $isDsh) {
            $stopOk = $true
            if (-not $Force) {
                $answer = [System.Windows.Forms.MessageBox]::Show(
                    "检测到外部启动的 DSH 仍在运行（PID $dshPid）：`r`n`r`n$cmdLine`r`n`r`n" +
                    "完整卸载会删除 DSH_HOME。为避免运行中的 DSH 关停时把内存数据写回被删除的目录，需要先停止它。是否停止？",
                    'DeepSeek Harness DesktopShell',
                    [System.Windows.Forms.MessageBoxButtons]::YesNo,
                    [System.Windows.Forms.MessageBoxIcon]::Warning)
                $stopOk = ($answer -eq [System.Windows.Forms.DialogResult]::Yes)
            }
            if ($stopOk) {
                try {
                    Stop-Process -Id $dshPid -Force -ErrorAction Stop
                    Say "已停止外部 DSH（PID $dshPid）。"
                } catch {
                    $stopOk = $false
                    Warn "停止外部 DSH 失败：$($_.Exception.Message)"
                }
            }
            if (-not $stopOk) {
                Warn '外部 DSH 未停止：完整卸载降级为仅卸载桌面壳（DSH_HOME 保留）。'
                $mode = 'shell'
            }
        } else {
            Warn "端口 $webPort 有服务监听，但无法确认它是 DSH：完整卸载降级为仅卸载桌面壳（DSH_HOME 保留）。"
            $mode = 'shell'
        }
    }

    # 枚举其它明显属于 DSH Web 的进程：同一 DSH_HOME 可能有第二个实例
    # （dsh --profile other web --port 3090 等），它们同样可能正在读写 DSH_HOME。
    if ($mode -eq 'full') {
        $otherDsh = @()
        try {
            foreach ($p in (Get-CimInstance Win32_Process -ErrorAction SilentlyContinue)) {
                if ($p.ProcessId -eq $PID) { continue }
                if ($dshPid -gt 0 -and $p.ProcessId -eq $dshPid) { continue }
                if (Test-LikelyDshCommandLine ([string]$p.CommandLine)) {
                    $otherDsh += [pscustomobject]@{ Pid = $p.ProcessId; CommandLine = [string]$p.CommandLine }
                }
            }
        } catch {}
        if ($otherDsh.Count -gt 0) {
            $list = ($otherDsh | ForEach-Object { "PID $($_.Pid): $($_.CommandLine)" }) -join "`r`n"
            $stopOthers = $true
            if (-not $Force) {
                $a = [System.Windows.Forms.MessageBox]::Show(
                    "仍检测到其它 DSH 实例在运行：`r`n`r`n$list`r`n`r`n" +
                    '它们可能正在读写 DSH_HOME。是否停止它们并继续完整卸载？（否=降级为仅卸载桌面壳）',
                    'DeepSeek Harness DesktopShell',
                    [System.Windows.Forms.MessageBoxButtons]::YesNo,
                    [System.Windows.Forms.MessageBoxIcon]::Warning)
                $stopOthers = ($a -eq [System.Windows.Forms.DialogResult]::Yes)
            }
            if ($stopOthers) {
                $failedStop = @()
                foreach ($o in $otherDsh) {
                    try { Stop-Process -Id $o.Pid -Force -ErrorAction Stop } catch { $failedStop += $o.Pid }
                }
                if ($failedStop.Count -gt 0) {
                    Warn "部分 DSH 实例停止失败（PID $($failedStop -join ',')），完整卸载降级为仅卸载桌面壳。"
                    $mode = 'shell'
                } else {
                    Say "已停止其它 DSH 实例（$($otherDsh.Count) 个）。"
                }
            } else {
                $mode = 'shell'
            }
        }
    }
}

# 只删除本产品自己的三个快捷方式；目录里若有用户自有文件则保留目录
foreach ($lnk in @('DeepSeek Harness.lnk', '管理 DSH - 插件与配置.lnk', '卸载 DesktopShell.lnk')) {
    Remove-Item -LiteralPath (Join-Path $startMenu $lnk) -Force -ErrorAction SilentlyContinue
}
$remaining = @(Get-ChildItem -LiteralPath $startMenu -Force -ErrorAction SilentlyContinue)
if ($remaining.Count -eq 0) {
    Remove-Item -LiteralPath $startMenu -Force -ErrorAction SilentlyContinue
}

if ($mode -eq 'full') {
    # 边界守卫：DSH_HOME 为空、等于或包含任何受保护目录、或位于桌面壳目录内时，
    # 一律拒绝整目录删除并降级为仅卸载桌面壳。
    # 方向必须双向检查：
    #   - DSH_HOME 位于桌面壳目录内部（$full 以 $appFull 开头）
    #   - 桌面壳目录位于 DSH_HOME 内部（$appFull 以 $full 开头）
    $dangerous = $false
    if ([string]::IsNullOrWhiteSpace($dshHome)) { $dangerous = $true }
    else {
        try {
            $full = [IO.Path]::GetFullPath($dshHome).TrimEnd('\')
            $appFull = [IO.Path]::GetFullPath($appDir).TrimEnd('\')
            $root = [IO.Path]::GetPathRoot($full).TrimEnd('\')
            if (-not $full -or $full -eq $root) { $dangerous = $true }
            elseif ($full.StartsWith($appFull + '\', [StringComparison]::OrdinalIgnoreCase)) {
                $dangerous = $true   # DSH_HOME 在 DesktopShell 程序目录内部
            } else {
                $protected = @(
                    $homeDir,
                    $appFull,
                    $env:WINDIR,
                    (Join-Path $env:WINDIR 'System32'),
                    $env:ProgramFiles,
                    ${env:ProgramFiles(x86)},
                    $env:ProgramData,
                    $env:PUBLIC,
                    $env:APPDATA,
                    $localAppData,
                    $env:TEMP,
                    $env:TMP,
                    ([Environment]::GetFolderPath('DesktopDirectory')),
                    ([Environment]::GetFolderPath('Personal')),
                    (Join-Path $homeDir 'Downloads'),
                    (Join-Path $homeDir 'OneDrive')
                )
                foreach ($p in $protected) {
                    if ([string]::IsNullOrWhiteSpace($p)) { continue }
                    try {
                        $pf = [IO.Path]::GetFullPath($p).TrimEnd('\')
                        # DSH_HOME 等于受保护目录，或受保护目录位于 DSH_HOME 内部
                        # （例：DSH_HOME=C:\Users 会把整个用户目录删掉；
                        #      DSH_HOME=%LOCALAPPDATA%\Programs 会删掉桌面壳所在目录）
                        if ($full -eq $pf -or
                            $pf.StartsWith($full + '\', [StringComparison]::OrdinalIgnoreCase)) {
                            $dangerous = $true; break
                        }
                    } catch {}
                }
            }
        } catch { $dangerous = $true }
    }

    if ($dangerous) {
        $warnText = "DSH_HOME 路径不安全（$dshHome），已取消删除 DSH 用户数据，仅继续卸载桌面壳。"
        if ($Force) { Write-Host "[!] $warnText" -ForegroundColor Yellow }
        else {
            [System.Windows.Forms.MessageBox]::Show(
                $warnText,
                'DeepSeek Harness DesktopShell',
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
        }
        $mode = 'shell'
    } elseif (Test-Path -LiteralPath $dshHome) {
        try {
            Remove-Item -LiteralPath $dshHome -Recurse -Force -ErrorAction Stop
        } catch {
            # 结果状态改为 partial：不能宣称“完整卸载成功”而 DSH_HOME 其实还在
            $warnText = "删除 DSH_HOME 失败：$($_.Exception.Message)`r`n桌面壳仍会继续卸载（结果：部分卸载）。"
            if ($Force) { Write-Host "[!] $warnText" -ForegroundColor Yellow }
            else {
                [System.Windows.Forms.MessageBox]::Show(
                    $warnText,
                    'DeepSeek Harness DesktopShell',
                    [System.Windows.Forms.MessageBoxButtons]::OK,
                    [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
            }
            $mode = 'partial'
        }
    }
}

$tempScript = Join-Path $env:TEMP ("dsh-desktop-uninstall-" + [Guid]::NewGuid().ToString('N') + '.ps1')
$appEscaped = $appDir.Replace("'", "''")
@"
Start-Sleep -Seconds 2
`$target = '$appEscaped'
`$owned = `$false
foreach (`$f in @('.dsh-desktop-shell-root', 'install-state.json')) {
    `$p = Join-Path `$target `$f
    if (Test-Path -LiteralPath `$p -PathType Leaf) {
        try {
            `$j = Get-Content -LiteralPath `$p -Raw -Encoding UTF8 | ConvertFrom-Json
            if (`$j.product -eq 'DeepSeek Harness DesktopShell') { `$owned = `$true; break }
        } catch {}
    }
}
if (`$owned) {
    Remove-Item -LiteralPath `$target -Recurse -Force -ErrorAction SilentlyContinue
} else {
    Write-Warning "删除前所有权标记验证失败，已跳过删除：`$target"
}
Remove-Item -LiteralPath `$PSCommandPath -Force -ErrorAction SilentlyContinue
"@ | Set-Content -LiteralPath $tempScript -Encoding UTF8

$runner = (Get-Command pwsh.exe -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty Source)
if (-not $runner) { $runner = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" }
Start-Process -FilePath $runner -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',"`"$tempScript`"") -WindowStyle Hidden

$msg = if ($mode -eq 'full') {
    '完整卸载已开始：DesktopShell 和 DSH_HOME 都会删除。'
} elseif ($mode -eq 'partial') {
    '部分卸载完成：DesktopShell 已删除，但 DSH_HOME 删除失败（已保留）。请检查后手动清理。'
} else {
    'DesktopShell 卸载已开始；DSH_HOME 保留，可继续单独使用 DSH。'
}
if ($Force) {
    Write-Host "[OK] $msg" -ForegroundColor Green
} else {
    [System.Windows.Forms.MessageBox]::Show(
        $msg,
        'DeepSeek Harness DesktopShell',
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null
}
