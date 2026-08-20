[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string[]]$PluginSpec,

    [string]$DshVersion = '0.1.0-rc.7',
    [ValidateSet('npx', 'command', 'auto')]
    [string]$RunnerMode = 'npx',
    [string]$DshPath = '',
    [string]$ProfileName = '',
    [int]$StableSeconds = 10,
    [int]$TimeoutSeconds = 120
)

$ErrorActionPreference = 'Stop'

function Get-FreeTcpPort {
    $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
    try {
        $listener.Start()
        return ([int]$listener.LocalEndpoint.Port)
    }
    finally {
        $listener.Stop()
    }
}

function Test-Http200([int]$port) {
    $request = $null
    try {
        $request = [System.Net.HttpWebRequest]::Create("http://127.0.0.1:$port/")
        $request.Method = 'GET'
        $request.AllowAutoRedirect = $false
        $request.KeepAlive = $false
        $request.Timeout = 700
        $request.ReadWriteTimeout = 700
        $response = $request.GetResponse()
        try { return ([int]$response.StatusCode -eq 200) }
        finally { $response.Dispose() }
    }
    catch { return $false }
}

function Test-PortOpen([int]$port) {
    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $async = $client.BeginConnect('127.0.0.1', $port, $null, $null)
        if (-not $async.AsyncWaitHandle.WaitOne(250)) { return $false }
        $client.EndConnect($async)
        return $true
    }
    catch { return $false }
    finally { $client.Dispose() }
}

function Get-ListeningPidForPort([int]$port) {
    try {
        $connections = Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction Stop
        foreach ($connection in @($connections)) {
            if ([int]$connection.OwningProcess -gt 0) { return [int]$connection.OwningProcess }
        }
    }
    catch { }

    # Native TCP cmdlet 不可用时只解析本次随机端口的 netstat 行；不按进程名筛选。
    try {
        $netstat = Join-Path ([Environment]::GetFolderPath('System')) 'netstat.exe'
        if (-not (Test-Path -LiteralPath $netstat -PathType Leaf)) { return -1 }
        $portText = [regex]::Escape($port.ToString())
        foreach ($line in @(& $netstat -ano -p tcp 2>$null)) {
            if ([string]$line -match '^\s*TCP\s+\S+:' + $portText + '\s+\S+\s+LISTENING\s+(\d+)\s*$') {
                return [int]$Matches[1]
            }
        }
    }
    catch { }
    return -1
}

function Get-ProcessInfoById([int]$processId) {
    if ($processId -le 0) { return $null }
    try {
        $info = Get-CimInstance Win32_Process -Filter ("ProcessId = " + $processId.ToString()) -ErrorAction Stop |
            Select-Object -First 1
        if ($info) { return $info }
    }
    catch {
        try {
            $info = Get-WmiObject Win32_Process -Filter ("ProcessId = " + $processId.ToString()) -ErrorAction Stop |
                Select-Object -First 1
            if ($info) { return $info }
        }
        catch { }
    }
    return $null
}

function Test-PreflightListenerIdentity([int]$listenerPid, [int]$port, [int]$wrapperPid) {
    if ($listenerPid -le 0) { return $false }

    $info = Get-ProcessInfoById $listenerPid
    if (-not $info) {
        # CIM/WMI 受限时仍保留“本次 wrapper 已启动 + 随机端口精确 owner”这一
        # 最小证明；调用方不会在 web wrapper 未创建的情况下清理 listener。
        return ($wrapperPid -gt 0)
    }
    $portPattern = '--port\s+' + [regex]::Escape($port.ToString()) + '(\s|$)'
    $commandLine = [string]$info.CommandLine
    if ($commandLine -match '(?i)(dsh|deepseek-ai)' -and $commandLine -match $portPattern) {
        return $true
    }

    # wrapper 可能已退出，但 listener 的 ParentProcessId 仍保留本次启动的 PID；
    # 沿父链有限步数确认归属，无法证明时宁可不杀并让 preflight 失败。
    $parentId = [int]$info.ParentProcessId
    for ($depth = 0; $depth -lt 8 -and $parentId -gt 0; $depth++) {
        if ($parentId -eq $wrapperPid) { return $true }
        $parent = Get-ProcessInfoById $parentId
        if (-not $parent) { break }
        $parentId = [int]$parent.ParentProcessId
    }
    # 某些受限 Windows 环境拒绝读取 Win32_Process.CommandLine/父链。这里仍然只
    # 接受“本次 web wrapper 已经成功启动 + 本次随机端口的精确 owner PID”，
    # 不按 node.exe/cmd.exe 名称杀；若 wrapper 根本没启动，调用方不会进入此路径。
    return ($wrapperPid -gt 0)
}

function Wait-PortClosed([int]$port, [int]$timeoutMs) {
    $watch = [Diagnostics.Stopwatch]::StartNew()
    $closedSamples = 0
    while ($watch.ElapsedMilliseconds -lt $timeoutMs) {
        if (-not (Test-PortOpen $port)) {
            $closedSamples++
            if ($closedSamples -ge 3) { return $true }
        }
        else { $closedSamples = 0 }
        Start-Sleep -Milliseconds 100
    }
    return ($closedSamples -ge 3 -and -not (Test-PortOpen $port))
}

function Test-ProcessAlive([int]$processId) {
    if ($processId -le 0) { return $false }
    try {
        $process = Get-Process -Id $processId -ErrorAction Stop
        try { return (-not $process.HasExited) }
        finally { $process.Dispose() }
    }
    catch { return $false }
}

function Quote-WindowsArgument([string]$value) {
    if ($null -eq $value -or $value.Length -eq 0) { return '""' }
    if ($value -notmatch '[\s"]') { return $value }
    return '"' + $value.Replace('"', '\"') + '"'
}

function New-LaunchSpec([string]$executable, [string[]]$arguments) {
    $argumentText = (($arguments | ForEach-Object { Quote-WindowsArgument ([string]$_) }) -join ' ')
    $extension = [IO.Path]::GetExtension($executable).ToLowerInvariant()
    if ($extension -in @('.cmd', '.bat')) {
        return [pscustomobject]@{
            FileName = (Join-Path ([Environment]::GetFolderPath('System')) 'cmd.exe')
            Arguments = '/d /s /c ""' + $executable + '" ' + $argumentText + '"'
        }
    }
    return [pscustomobject]@{
        FileName = $executable
        Arguments = $argumentText
    }
}

function Resolve-Executable([string]$name) {
    $command = Get-Command $name -ErrorAction SilentlyContinue
    if (-not $command) { return '' }
    return [string]$command.Source
}

function Stop-ProcessTree([System.Diagnostics.Process]$processToStop) {
    if (-not $processToStop) { return }
    $exited = $false
    try { $exited = $processToStop.HasExited } catch { $exited = $true }
    if (-not $exited) {
        # 只按本次启动返回的 PID 清理整棵树；不按 node/cmd/powershell 进程名全局杀。
        $taskkill = Join-Path ([Environment]::GetFolderPath('System')) 'taskkill.exe'
        if (Test-Path -LiteralPath $taskkill -PathType Leaf) {
            & $taskkill /PID $processToStop.Id /T /F 2>$null | Out-Null
            try { $processToStop.WaitForExit(3000) } catch { }
        }
        else {
            try { $processToStop.Kill() } catch { }
            try { $processToStop.WaitForExit(3000) } catch { }
        }
    }
}

function Stop-ListenerByPort([int]$port, [int]$wrapperPid) {
    $listenerPid = Get-ListeningPidForPort $port
    if ($listenerPid -le 0) { return $true }
    if (-not (Test-PreflightListenerIdentity $listenerPid $port $wrapperPid)) {
        Write-Host "PLUGIN PREFLIGHT cleanup refused pid=$listenerPid port=$port identity=unproven"
        return $false
    }

    Write-Host "PLUGIN PREFLIGHT cleanup listener pid=$listenerPid port=$port"
    $taskkill = Join-Path ([Environment]::GetFolderPath('System')) 'taskkill.exe'
    if (Test-Path -LiteralPath $taskkill -PathType Leaf) {
        try {
            & $taskkill /PID $listenerPid /T /F 2>$null | Out-Null
        }
        catch { }
    }
    else {
        try {
            $listener = [System.Diagnostics.Process]::GetProcessById($listenerPid)
            try { $listener.Kill() } finally { $listener.Dispose() }
        }
        catch { }
    }

    # PowerShell 5.1 某些宿主下 taskkill 的返回时序不可靠；仍只对刚由随机端口
    # 解析出的同一个 PID 做一次强制终止，绝不退化为进程名匹配。
    Write-Host "PLUGIN PREFLIGHT cleanup exact-kill pid=$listenerPid"
    try {
        Stop-Process -Id $listenerPid -Force -ErrorAction Stop
    }
    catch { }

    # 某些受限环境下 taskkill /T 可能只回收 wrapper 记录而 listener 仍短暂存活；
    # 无论 taskkill 的即时返回如何，都再按刚才由随机端口解析出的同一个精确 PID
    # 做一次有界 Kill，不按进程名扩散。
    try {
        $listener = [System.Diagnostics.Process]::GetProcessById($listenerPid)
        try {
            if (-not $listener.HasExited) { $listener.Kill() }
            $listener.WaitForExit(5000)
        }
        finally { $listener.Dispose() }
    }
    catch { }
    return ((Wait-PortClosed $port 5000) -and -not (Test-ProcessAlive $listenerPid))
}

function Stop-PreflightWebProcess([System.Diagnostics.Process]$processToStop, [int]$port) {
    if (-not $processToStop) { return (-not (Test-PortOpen $port)) }
    $wrapperPid = -1
    if ($processToStop) {
        try { $wrapperPid = $processToStop.Id } catch { }
    }
    Stop-ProcessTree $processToStop
    if (Wait-PortClosed $port 800) { return $true }

    # dsh.cmd/cmd.exe 可能已退出而 Node listener 仍在；只按随机测试端口找到
    # 一个 PID，并通过命令行/父链确认它属于本次 preflight 后才按 PID/T 清理。
    if (-not (Stop-ListenerByPort $port $wrapperPid)) { return $false }
    return (Wait-PortClosed $port 5000)
}

function Start-CapturedProcess(
    [object]$launch,
    [string]$workingDirectory,
    [string]$stdoutPath,
    [string]$stderrPath,
    [int]$timeoutMs
) {
    $started = Start-Process -FilePath $launch.FileName -ArgumentList $launch.Arguments `
        -WorkingDirectory $workingDirectory -WindowStyle Hidden `
        -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath -PassThru
    try {
        if (-not $started.WaitForExit($timeoutMs)) {
            Stop-ProcessTree $started
            throw "进程超时（PID=$($started.Id)）。"
        }
        return [int]$started.ExitCode
    }
    finally {
        try { $started.Dispose() } catch { }
    }
}

function Read-CapturedText([string]$path) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return '' }
    try { return [IO.File]::ReadAllText($path) }
    catch { return '' }
}

function Normalize-IsolatedProfile([string]$value) {
    if ([string]::IsNullOrWhiteSpace($value)) {
        return 'compat-' + [guid]::NewGuid().ToString('N').Substring(0, 12)
    }
    if ($value -notmatch '^[A-Za-z0-9_-]+$' -or $value -eq 'node_modules') {
        throw 'ProfileName 必须是安全的隔离 Profile 名；无法构造隔离 Profile，因此不返回兼容 PASS。'
    }
    return $value
}

function New-DshArguments([string[]]$tail) {
    if ($useNpx) {
        return @('-y', ('@deepseek-ai/dsh@' + $DshVersion)) + $tail
    }
    return $tail
}

$tempHome = Join-Path ([IO.Path]::GetTempPath()) ('dsh-plugin-preflight-' + [guid]::NewGuid().ToString('N'))
$profile = Normalize-IsolatedProfile $ProfileName
$port = Get-FreeTcpPort
$probeRoot = Join-Path $tempHome 'preflight'
$stdoutPath = Join-Path $probeRoot 'web-stdout.log'
$stderrPath = Join-Path $probeRoot 'web-stderr.log'
$oldDshHome = $env:DSH_HOME
$webProcess = $null
$passed = $false
$reason = ''
$cleanupPassed = $true
$cleanupReason = ''
$useNpx = $false

try {
    if (-not [IO.Path]::IsPathRooted($tempHome) -or (Test-Path -LiteralPath $tempHome)) {
        throw '无法证明 DSH_HOME 是全新临时目录；不返回兼容 PASS。'
    }
    New-Item -ItemType Directory -Force -Path $probeRoot | Out-Null

    if ($RunnerMode -eq 'npx') {
        $useNpx = $true
        $executable = Resolve-Executable 'npx.cmd'
        if (-not $executable) { $executable = Resolve-Executable 'npx.exe' }
        if (-not $executable) { throw '找不到 npx；独立 release preflight 未执行。' }
    }
    else {
        $executable = if ($DshPath) { $DshPath } else { Resolve-Executable 'dsh.cmd' }
        if (-not $executable) { $executable = Resolve-Executable 'dsh.exe' }
        if (-not $executable -and $RunnerMode -eq 'auto') {
            $useNpx = $true
            $executable = Resolve-Executable 'npx.cmd'
            if (-not $executable) { $executable = Resolve-Executable 'npx.exe' }
        }
        if (-not $executable) { throw '找不到 dsh/npx；无法安全构造独立 release preflight。' }
    }

    # 所有子进程（plugin add 与 web）都继承这个临时 DSH_HOME；绝不启动用户真实 ~/.dsh。
    $env:DSH_HOME = $tempHome
    if ($env:DSH_HOME -ne $tempHome) { throw '临时 DSH_HOME 未生效；不返回兼容 PASS。' }

    for ($i = 0; $i -lt $PluginSpec.Count; $i++) {
        $spec = ([string]$PluginSpec[$i]).Trim()
        if ([string]::IsNullOrWhiteSpace($spec)) { continue }
        $installStdout = Join-Path $probeRoot ('plugin-' + $i.ToString() + '-stdout.log')
        $installStderr = Join-Path $probeRoot ('plugin-' + $i.ToString() + '-stderr.log')
        $installArgs = New-DshArguments @('plugin', '--profile', $profile, 'add', $spec)
        $installLaunch = New-LaunchSpec $executable $installArgs
        Write-Host "PLUGIN PREFLIGHT install spec=$spec isolatedProfile=$profile tempDshHome=$tempHome"
        $installCode = Start-CapturedProcess $installLaunch $tempHome $installStdout $installStderr 120000
        if ($installCode -ne 0) {
            throw "插件安装返回 exitCode=$installCode：$spec"
        }
    }

    $profileDir = Join-Path $tempHome (Join-Path 'profiles' $profile)
    if (-not (Test-Path -LiteralPath $profileDir -PathType Container)) {
        throw '插件安装后未发现临时 Profile 目录；无法证明完整隔离，未返回兼容 PASS。'
    }

    # 与 DesktopShell 的 BuildWebLaunchArguments 保持一致：web 是 dsh 的默认启动入口，
    # 正式启动只传 --profile/--port；rc.8 再追加已确认支持的 --no-open。
    $webArgs = New-DshArguments @('--profile', $profile, '--port', ([string]$port))
    if ($DshVersion -eq '0.1.0-rc.8') { $webArgs += '--no-open' }
    $webLaunch = New-LaunchSpec $executable $webArgs
    $webProcess = Start-Process -FilePath $webLaunch.FileName -ArgumentList $webLaunch.Arguments `
        -WorkingDirectory $tempHome -WindowStyle Hidden -RedirectStandardOutput $stdoutPath `
        -RedirectStandardError $stderrPath -PassThru

    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    $bannerSeen = $false
    while ([DateTime]::UtcNow -lt $deadline) {
        if ($webProcess.HasExited) {
            throw "Profile 在 BootReady 前退出，exitCode=$($webProcess.ExitCode)。"
        }

        $combined = (Read-CapturedText $stdoutPath) + "`r`n" + (Read-CapturedText $stderrPath)
        if ($combined -match '(?i)dsh\s+web:\s+http://(?:127\.0\.0\.1|localhost):' + $port.ToString()) {
            $bannerSeen = $true
        }

        if ($bannerSeen -and (Test-Http200 $port)) {
            $stableDeadline = [DateTime]::UtcNow.AddSeconds($StableSeconds)
            while ([DateTime]::UtcNow -lt $stableDeadline) {
                if ($webProcess.HasExited -or -not (Test-Http200 $port)) {
                    throw 'Profile 已出现 ready banner/HTTP 200，但未稳定运行满要求时长。'
                }
                Start-Sleep -Milliseconds 250
            }
            if ($webProcess.HasExited -or -not (Test-Http200 $port)) {
                throw '稳定确认结束时 Profile 已退出或 HTTP 不再返回 200。'
            }
            $passed = $true
            break
        }
        Start-Sleep -Milliseconds 250
    }

    if (-not $passed) { throw '等待 Profile BootReady 超时。' }
}
catch {
    $reason = $_.Exception.Message
    Write-Host "PLUGIN BOOT PREFLIGHT FAILED: $reason"
    $stdout = Read-CapturedText $stdoutPath
    $stderr = Read-CapturedText $stderrPath
    if ($stdout) { Write-Host '--- web stdout (tail) ---'; Write-Host (($stdout -split "`r?`n" | Select-Object -Last 20) -join [Environment]::NewLine) }
    if ($stderr) { Write-Host '--- web stderr (tail) ---'; Write-Host (($stderr -split "`r?`n" | Select-Object -Last 20) -join [Environment]::NewLine) }
}
finally {
    try {
        if (-not (Stop-PreflightWebProcess $webProcess $port)) {
            $cleanupPassed = $false
            $cleanupReason = "随机测试端口 $port 在 preflight 清理后仍未关闭，或 listener 身份无法安全确认。"
        }
    }
    catch {
        $cleanupPassed = $false
        $cleanupReason = "preflight 清理异常：$($_.Exception.Message)"
    }
    try { if ($webProcess) { $webProcess.Dispose() } } catch { }
    if ($null -eq $oldDshHome) { Remove-Item Env:DSH_HOME -ErrorAction SilentlyContinue }
    else { $env:DSH_HOME = $oldDshHome }
    if (Test-PortOpen $port) {
        $cleanupPassed = $false
        $cleanupReason = "随机测试端口 $port 在最终检查时仍在监听。"
    }
    Remove-Item -LiteralPath $tempHome -Recurse -Force -ErrorAction SilentlyContinue
}

if ($passed -and $cleanupPassed) {
    Write-Host "PLUGIN BOOT PREFLIGHT PASSED profile=$profile port=$port stableSeconds=$StableSeconds cleanup=closed"
    exit 0
}
if (-not $cleanupPassed) { Write-Host "PLUGIN BOOT PREFLIGHT FAILED: $cleanupReason" }
exit 1
