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
    if ($exited) { return }

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

    $webArgs = New-DshArguments @('web', '--profile', $profile, '--port', ([string]$port))
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
    Write-Host "PLUGIN BOOT PREFLIGHT PASSED profile=$profile port=$port stableSeconds=$StableSeconds"
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
    Stop-ProcessTree $webProcess
    if ($null -eq $oldDshHome) { Remove-Item Env:DSH_HOME -ErrorAction SilentlyContinue }
    else { $env:DSH_HOME = $oldDshHome }
    Remove-Item -LiteralPath $tempHome -Recurse -Force -ErrorAction SilentlyContinue
}

if ($passed) { exit 0 }
exit 1
