[CmdletBinding()]
param(
    [string]$DshVersion = '0.1.1-rc.1',
    [int]$Port = 0,
    [string]$AppExe = '',
    [switch]$LaunchDesktopShell,
    [switch]$RunPlugins,
    [switch]$KeepTemp,
    [int]$TimeoutSeconds = 60,
    [int]$StableSeconds = 3
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$repoRoot = Split-Path -Parent $PSScriptRoot
$sessionRoot = Join-Path ([IO.Path]::GetTempPath()) ('dsh-rc1-local-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $sessionRoot | Out-Null

function Say([string]$text) { Write-Host "[LOCAL] $text" -ForegroundColor Cyan }
function Ok([string]$text) { Write-Host "[PASS]  $text" -ForegroundColor Green }
function Warn([string]$text) { Write-Host "[WARN]  $text" -ForegroundColor Yellow }
function Fail([string]$text) { throw $text }

function Get-FreeTcpPort {
    $listener = [System.Net.Sockets.TcpListener]::new(
        [System.Net.IPAddress]::Loopback, 0)
    try {
        $listener.Start()
        return ([int]$listener.LocalEndpoint.Port)
    }
    finally {
        try { $listener.Stop() } catch { }
    }
}

function Restore-DshHome([string]$oldValue) {
    if ($null -eq $oldValue) {
        Remove-Item Env:DSH_HOME -ErrorAction SilentlyContinue
    }
    else {
        $env:DSH_HOME = $oldValue
    }
}

function Stop-TestProcessTree([int]$targetPid) {
    if ($targetPid -le 0) { return }
    $exists = Get-Process -Id $targetPid -ErrorAction SilentlyContinue
    if ($null -eq $exists) { return }
    Say "Stopping exact test PID $targetPid tree"
    & taskkill.exe /PID $targetPid /T /F | Out-Null
}

function Get-ListeningPid([int]$port) {
    try {
        $item = Get-NetTCPConnection -State Listen -LocalPort $port -ErrorAction SilentlyContinue |
            Select-Object -First 1
        if ($null -eq $item) { return 0 }
        return [int]$item.OwningProcess
    }
    catch {
        return 0
    }
}

function Get-ProcessCommandLine([int]$targetPid) {
    try {
        $item = Get-CimInstance Win32_Process -Filter ("ProcessId={0}" -f $targetPid) -ErrorAction Stop
        if ($null -eq $item) { return '' }
        return [string]$item.CommandLine
    }
    catch {
        return ''
    }
}

function Stop-TestPort([int]$port) {
    $deadline = [DateTime]::UtcNow.AddSeconds(10)
    while ([DateTime]::UtcNow -lt $deadline) {
        $listenerPid = Get-ListeningPid $port
        if ($listenerPid -le 0) { return }

        $commandLine = Get-ProcessCommandLine $listenerPid
        $portPattern = '--port\s+' + [regex]::Escape([string]$port) + '(\s|$)'
        if ($commandLine -notmatch '(?i)dsh' -or $commandLine -notmatch $portPattern) {
            throw "Refusing to stop unknown PID $listenerPid on test port $port; command line: $commandLine"
        }

        Stop-TestProcessTree $listenerPid
        Start-Sleep -Milliseconds 250
    }
    throw "Test port $port is still listening after cleanup timeout."
}

function Invoke-CapturedCommand(
    [string]$argumentLine,
    [string]$dshHome,
    [int]$timeoutSeconds = 30
) {
    $name = 'command-' + [guid]::NewGuid().ToString('N')
    $stdoutPath = Join-Path $sessionRoot ($name + '.stdout.log')
    $stderrPath = Join-Path $sessionRoot ($name + '.stderr.log')
    $comSpec = if ($env:ComSpec) { $env:ComSpec } else { 'cmd.exe' }
    $oldDshHome = $env:DSH_HOME
    try {
        $env:DSH_HOME = $dshHome
        $process = Start-Process -FilePath $comSpec `
            -ArgumentList $argumentLine `
            -WorkingDirectory $sessionRoot `
            -WindowStyle Hidden `
            -RedirectStandardOutput $stdoutPath `
            -RedirectStandardError $stderrPath `
            -PassThru
    }
    finally {
        Restore-DshHome $oldDshHome
    }

    if (-not $process.WaitForExit($timeoutSeconds * 1000)) {
        Stop-TestProcessTree $process.Id
        throw "Command timed out: $argumentLine"
    }
    $process.Refresh()
    $exitCode = 0
    if ($process.HasExited) {
        try { $exitCode = [int]$process.ExitCode } catch { $exitCode = 0 }
    }
    $stdout = if (Test-Path -LiteralPath $stdoutPath) {
        Get-Content -LiteralPath $stdoutPath -Raw -ErrorAction SilentlyContinue
    } else { '' }
    $stderr = if (Test-Path -LiteralPath $stderrPath) {
        Get-Content -LiteralPath $stderrPath -Raw -ErrorAction SilentlyContinue
    } else { '' }
    return [pscustomobject]@{
        ExitCode = $exitCode
        Stdout = [string]$stdout
        Stderr = [string]$stderr
        Pid = [int]$process.Id
    }
}

function Start-DshServer([int]$port, [string]$dshHome) {
    $stdoutPath = Join-Path $sessionRoot ('dsh-' + $port.ToString() + '.stdout.log')
    $stderrPath = Join-Path $sessionRoot ('dsh-' + $port.ToString() + '.stderr.log')
    $argumentLine = '/d /s /c "npx -y @deepseek-ai/dsh@' + $DshVersion +
        ' --profile web --port ' + $port.ToString() + ' --no-open"'
    $comSpec = if ($env:ComSpec) { $env:ComSpec } else { 'cmd.exe' }
    $oldDshHome = $env:DSH_HOME
    try {
        $env:DSH_HOME = $dshHome
        $process = Start-Process -FilePath $comSpec `
            -ArgumentList $argumentLine `
            -WorkingDirectory $sessionRoot `
            -WindowStyle Hidden `
            -RedirectStandardOutput $stdoutPath `
            -RedirectStandardError $stderrPath `
            -PassThru
    }
    finally {
        Restore-DshHome $oldDshHome
    }
    return [pscustomobject]@{
        Process = $process
        StdoutPath = $stdoutPath
        StderrPath = $stderrPath
    }
}

function Get-RunOutput($run) {
    $stdout = if (Test-Path -LiteralPath $run.StdoutPath) {
        Get-Content -LiteralPath $run.StdoutPath -Raw -ErrorAction SilentlyContinue
    } else { '' }
    $stderr = if (Test-Path -LiteralPath $run.StderrPath) {
        Get-Content -LiteralPath $run.StderrPath -Raw -ErrorAction SilentlyContinue
    } else { '' }
    return ([string]$stdout + "`r`n" + [string]$stderr)
}

function Test-Http200([int]$port) {
    try {
        $response = Invoke-WebRequest -UseBasicParsing `
            -Uri ('http://127.0.0.1:' + $port.ToString() + '/') `
            -TimeoutSec 3
        return ($response.StatusCode -eq 200)
    }
    catch {
        return $false
    }
}

function Invoke-CliSmoke {
    $cliHome = Join-Path $sessionRoot 'cli-dsh-home'
    New-Item -ItemType Directory -Force -Path $cliHome | Out-Null
    Say "CLI version probe: $DshVersion"

    $versionResult = Invoke-CapturedCommand `
        -argumentLine ('/d /s /c "npx -y @deepseek-ai/dsh@' + $DshVersion + ' --version"') `
        -dshHome $cliHome
    $versionOutput = ($versionResult.Stdout + "`n" + $versionResult.Stderr)
    $versionTokens = @($versionOutput -split '\s+')
    if (($versionResult.ExitCode -ne 0) -or (-not ($versionTokens -contains $DshVersion))) {
        throw "Version probe failed: $versionOutput"
    }
    Ok 'CLI --version'

    $helpResult = Invoke-CapturedCommand `
        -argumentLine ('/d /s /c "npx -y @deepseek-ai/dsh@' + $DshVersion + ' --profile web --help"') `
        -dshHome $cliHome
    $helpOutput = ($helpResult.Stdout + "`n" + $helpResult.Stderr)
    if ($helpResult.ExitCode -ne 0 -or
        $helpOutput -notmatch '--port' -or $helpOutput -notmatch '--no-open') {
        throw "Help did not contain both --port and --no-open: $helpOutput"
    }
    Ok 'CLI --help contains --port / --no-open'

    $probePort = if ($Port -gt 0) { $Port } else { Get-FreeTcpPort }
    $run = Start-DshServer $probePort $cliHome
    try {
        $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
        $ready = $false
        while ([DateTime]::UtcNow -lt $deadline) {
            $run.Process.Refresh()
            if ($run.Process.HasExited) {
                throw "DSH exited before ready, exit code $($run.Process.ExitCode): $(Get-RunOutput $run)"
            }
            $output = Get-RunOutput $run
            $banner = $output -match ('dsh web:\s+http://127\.0\.0\.1:' + [regex]::Escape([string]$probePort))
            if ($banner -and (Test-Http200 $probePort)) {
                $ready = $true
                break
            }
            Start-Sleep -Milliseconds 500
        }
        if (-not $ready) {
            throw "DSH did not reach banner + HTTP 200 within $TimeoutSeconds seconds: $(Get-RunOutput $run)"
        }

        for ($i = 0; $i -lt $StableSeconds; $i++) {
            if (-not (Test-Http200 $probePort)) {
                throw "DSH HTTP 200 stability check failed on port $probePort"
            }
            Start-Sleep -Seconds 1
        }
        Ok ("CLI --no-open ready + HTTP 200 + stable {0}s on port {1}" -f $StableSeconds, $probePort)
    }
    finally {
        try { $run.Process.Refresh() } catch { }
        Stop-TestProcessTree $run.Process.Id
        Stop-TestPort $probePort
    }
}

function Resolve-TestAppExe {
    $candidates = @()
    if ($AppExe) { $candidates += $AppExe }
    $candidates += (Join-Path ([IO.Path]::GetTempPath()) 'dsh-overlay-app\DeepSeek Harness DesktopShell\DeepSeekHarness.exe')
    $candidates += (Join-Path $env:LOCALAPPDATA 'Programs\DeepSeek Harness DesktopShell\DeepSeekHarness.exe')
    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            return (Get-Item -LiteralPath $candidate).FullName
        }
    }
    throw 'DesktopShell EXE not found; use -AppExe to specify the candidate DeepSeekHarness.exe.'
}

function Start-IsolatedDesktopShell {
    $existing = @(Get-Process -Name DeepSeekHarness -ErrorAction SilentlyContinue)
    if ($existing.Count -gt 0) {
        throw ('An existing DesktopShell process was found: ' + (($existing | ForEach-Object Id) -join ',') +
            '. This script will not stop it; exit it manually first.')
    }

    $sourceExe = Resolve-TestAppExe
    $patchedCandidate = Join-Path ([IO.Path]::GetTempPath()) 'dsh-overlay-app\DeepSeek Harness DesktopShell\DeepSeekHarness.exe'
    $installedExe = Join-Path $env:LOCALAPPDATA 'Programs\DeepSeek Harness DesktopShell\DeepSeekHarness.exe'
    if (-not $AppExe -and
        [IO.Path]::GetFullPath($sourceExe) -ieq [IO.Path]::GetFullPath($installedExe) -and
        -not (Test-Path -LiteralPath $patchedCandidate -PathType Leaf)) {
        throw 'No patched candidate EXE was found; pass -AppExe explicitly. The installed older EXE is not sufficient to verify the v1.0.5 overlay fix.'
    }
    $sourceDir = Split-Path -Parent $sourceExe
    $guiDir = Join-Path $sessionRoot 'desktop-shell'
    $dshHome = Join-Path $sessionRoot 'gui-dsh-home'
    New-Item -ItemType Directory -Force -Path $guiDir,$dshHome | Out-Null

    Get-ChildItem -LiteralPath $sourceDir -Force | ForEach-Object {
        if ($_.Name -notin @('settings.json', 'logs', 'webview2-data')) {
            Copy-Item -LiteralPath $_.FullName `
                -Destination (Join-Path $guiDir $_.Name) -Recurse -Force
        }
    }

    $guiPort = Get-FreeTcpPort
    $settings = [ordered]@{
        port = $guiPort
        workingDirectory = $sessionRoot
        closeAction = 'exit'
        restoreWindowBounds = $false
        hasSavedWindowBounds = $false
        windowX = 100
        windowY = 100
        windowWidth = 1280
        windowHeight = 820
        windowMaximized = $false
        developerMode = $false
        dshVersion = $DshVersion
        dshPath = ''
        dshRunnerMode = 'npx'
        acceptedDshCommandPath = ''
        acceptedDshCommandVersion = ''
        profileName = 'web'
    }
    $settings | ConvertTo-Json -Depth 8 |
        Set-Content -LiteralPath (Join-Path $guiDir 'settings.json') -Encoding UTF8

    $guiExe = Join-Path $guiDir 'DeepSeekHarness.exe'
    if (-not (Test-Path -LiteralPath $guiExe -PathType Leaf)) {
        throw "Candidate copy did not contain $guiExe"
    }

    $oldDshHome = $env:DSH_HOME
    try {
        $env:DSH_HOME = $dshHome
        $process = Start-Process -FilePath $guiExe -WorkingDirectory $guiDir `
            -WindowStyle Normal -PassThru
    }
    finally {
        Restore-DshHome $oldDshHome
    }

    Write-Host ''
    Write-Host '===== GUI manual phase started =====' -ForegroundColor Magenta
    Write-Host ("EXE:      {0}" -f $guiExe)
    Write-Host ("PID:      {0}" -f $process.Id)
    Write-Host ("DSH_HOME: {0}" -f $dshHome)
    Write-Host ("Port:     {0}" -f $guiPort)
    Write-Host ("Log:      {0}" -f (Join-Path $guiDir 'logs\desktop-shell.log'))
    Write-Host 'Follow docs\DSH_RC1_MANUAL_ACCEPTANCE.md for real mouse, restart, tray, and exit checks.' -ForegroundColor Yellow
    Read-Host 'Press Enter after GUI manual checks; the exact test process and temp directory will be cleaned' | Out-Null

    Stop-TestProcessTree $process.Id
    Stop-TestPort $guiPort
    Ok 'GUI manual phase ended; test port is closed'
}

function Invoke-PluginPreflight {
    $preflight = Join-Path $repoRoot 'scripts\Test-PluginBootPreflight.ps1'
    $plugins = @(
        [pscustomobject]@{ Name='dshmarket'; Spec='dshmarket@1.17.1' },
        [pscustomobject]@{ Name='dsh-better-sidebar'; Spec='dsh-better-sidebar@^0.14.0' },
        [pscustomobject]@{ Name='@michengai/dsh-skills-manager'; Spec='@michengai/dsh-skills-manager@0.1.23' },
        [pscustomobject]@{ Name='dsh-at-file'; Spec='github:omdsh-dev/dsh-at-file' },
        [pscustomobject]@{ Name='@xsj/dsh-rewind'; Spec='github:XSJUSTC/dsh-rewind' },
        [pscustomobject]@{ Name='dsh-file-mentions'; Spec='git+https://github.com/a903067276-rgb/dsh-file-mentions.git' },
        [pscustomobject]@{ Name='dsh-auto-collapse'; Spec='github:a179-sanae/dsh-auto-collapse' },
        [pscustomobject]@{ Name='dsh-chat-tidy'; Spec='dsh-chat-tidy@^0.2.0' },
        [pscustomobject]@{ Name='dsh-codex-side-outline'; Spec='github:EnkiduGilgamesh/dsh-codex-side-outline' },
        [pscustomobject]@{ Name='dsh-better-archive'; Spec='git+https://github.com/huahai0202/dsh-better-archive.git' },
        [pscustomobject]@{ Name='dsh-video-preview'; Spec='dsh-video-preview@^0.1.1' },
        [pscustomobject]@{ Name='dsh-git-remotes'; Spec='github:yq04/dsh-git-remotes' },
        [pscustomobject]@{ Name='dsh-notification'; Spec='git+https://github.com/omdsh-dev/dsh-notification.git' },
        [pscustomobject]@{ Name='dsh-open-in-vscode'; Spec='github:omdsh-dev/dsh-open-in-vscode' },
        [pscustomobject]@{ Name='dsh-sidebar-qa'; Spec='github:ChenRuoT/dsh-sidebar-qa' },
        [pscustomobject]@{ Name='@huanlin/dsh-plugin-better-sidebar-plugin-office'; Spec='@huanlin/dsh-plugin-better-sidebar-plugin-office@^0.1.0' },
        [pscustomobject]@{ Name='@tt-a1i/archify-dsh'; Spec='@tt-a1i/archify-dsh@^0.1.0' },
        [pscustomobject]@{ Name='@nanmicoder/dsh-auto-mode'; Spec='@nanmicoder/dsh-auto-mode@^0.1.4' },
        [pscustomobject]@{ Name='dsh-cost-meter'; Spec='dsh-cost-meter@^1.5.35' },
        [pscustomobject]@{ Name='dsh-dream-skin'; Spec='dsh-dream-skin@^0.4.5' },
        [pscustomobject]@{ Name='dsh-sentinel'; Spec='dsh-sentinel@0.11.0' },
        [pscustomobject]@{ Name='@linxin666/dsh-liangshen'; Spec='@linxin666/dsh-liangshen@^0.2.7' },
        [pscustomobject]@{ Name='@dsh-plugin/dsh-thought-buddy'; Spec='@dsh-plugin/dsh-thought-buddy@^0.2.0' }
    )
    $failed = 0
    foreach ($plugin in $plugins) {
        Say "Plugin preflight: $($plugin.Name) [$($plugin.Spec)]"
        try {
            & $preflight -PluginSpec $plugin.Spec -DshVersion $DshVersion -StableSeconds 10
            if ($LASTEXITCODE -ne 0) { throw "exit code $LASTEXITCODE" }
            Ok $plugin.Name
        }
        catch {
            $failed++
            Warn ("FAILED {0}: {1}" -f $plugin.Name, $_.Exception.Message)
        }
    }
    if ($failed -gt 0) { throw "$failed plugin preflight run(s) failed; classify plugin vs host failures." }
}

try {
    Say "Starting local DSH $DshVersion smoke test; temp root: $sessionRoot"
    Invoke-CliSmoke
    if ($RunPlugins) { Invoke-PluginPreflight }
    if ($LaunchDesktopShell) { Start-IsolatedDesktopShell }
    Say 'Local test flow completed'
}
finally {
    if ($KeepTemp) {
        Write-Host ("Evidence temp directory kept: {0}" -f $sessionRoot) -ForegroundColor Yellow
    }
    else {
        try { Remove-Item -LiteralPath $sessionRoot -Recurse -Force -ErrorAction Stop }
        catch { Warn ("Could not remove temp directory; check for process locks: $sessionRoot") }
    }
}
