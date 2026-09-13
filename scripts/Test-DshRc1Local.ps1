[CmdletBinding()]
param(
    [string]$DshVersion = '0.1.5-rc.2',
    [ValidateSet('npx', 'command', 'auto')]
    [string]$PluginRunnerMode = 'npx',
    [string]$PluginDshPath = '',
    [int]$Port = 0,
    [string]$AppExe = '',
    [switch]$LaunchDesktopShell,
    [switch]$RunPlugins,
    [switch]$RequireNoUserPlugins,
    [switch]$KeepTemp,
    [string]$WebProfileDshHome = '',
    [int]$TimeoutSeconds = 60,
    [int]$StableSeconds = 3
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$repoRoot = Split-Path -Parent $PSScriptRoot
$sessionRoot = Join-Path ([IO.Path]::GetTempPath()) ('dsh-rc2-local-' + [guid]::NewGuid().ToString('N'))
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
    try { Stop-Process -Id $targetPid -Force -ErrorAction Stop } catch { }
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
        ' --profile web --no-open --port ' + $port.ToString() + '"'
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

function Get-RunOutputRaw($run) {
    $stdout = if (Test-Path -LiteralPath $run.StdoutPath) {
        Get-Content -LiteralPath $run.StdoutPath -Raw -ErrorAction SilentlyContinue
    } else { '' }
    $stderr = if (Test-Path -LiteralPath $run.StderrPath) {
        Get-Content -LiteralPath $run.StderrPath -Raw -ErrorAction SilentlyContinue
    } else { '' }
    return ([string]$stdout + "`r`n" + [string]$stderr)
}

function Redact-BrowserAuthText([string]$text) {
    if ($null -eq $text) { return '' }
    return [regex]::Replace(
        $text,
        '(?i)([?&](?:token|access_token|auth|authorization)=)[^&#\s]+',
        '$1[REDACTED]')
}

function Get-RunOutput($run) {
    return (Redact-BrowserAuthText (Get-RunOutputRaw $run))
}

function Get-DshReadyUrl($run, [int]$port) {
    $output = Get-RunOutputRaw $run
    $match = [regex]::Match($output, '(?im)\bdsh\s+web\s*:\s*(?<url>http://[^\s]+)')
    if (-not $match.Success) { return '' }

    [System.Uri]$uri = $null
    if (-not [System.Uri]::TryCreate(
            $match.Groups['url'].Value,
            [System.UriKind]::Absolute,
            [ref]$uri)) {
        return ''
    }
    $readyHost = $uri.Host.ToLowerInvariant()
    $loopback = $readyHost -in @('127.0.0.1', 'localhost', '::1', '[::1]')
    if ($uri.Scheme -ne [System.Uri]::UriSchemeHttp -or -not $loopback -or $uri.Port -ne $port) {
        return ''
    }
    return $uri.AbsoluteUri
}

function Test-Http200([string]$url) {
    $request = $null
    try {
        $request = [System.Net.HttpWebRequest]::Create($url)
        $request.Method = 'GET'
        # alpha BrowserAuth 先 303 写入 Cookie 再跳转到干净根路径；测试 cookie jar
        # 为单次请求所有，既不复用也不落盘。
        $request.AllowAutoRedirect = $true
        $request.MaximumAutomaticRedirections = 3
        $request.CookieContainer = [System.Net.CookieContainer]::new()
        $request.KeepAlive = $false
        $request.Timeout = 3000
        $request.ReadWriteTimeout = 3000
        $response = $request.GetResponse()
        try { return ([int]$response.StatusCode -eq 200) }
        finally { $response.Dispose() }
    }
    catch {
        try { if ($_.Exception.Response) { $_.Exception.Response.Dispose() } } catch { }
        return $false
    }
}

function Assert-NoUserPlugins([string]$dshHome) {
    $profileRoot = Join-Path $dshHome 'profiles\web'
    $manifestPath = Join-Path $profileRoot 'package.json'
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
        throw "No-plugin check failed: profile manifest was not created: $manifestPath"
    }

    try {
        $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
    }
    catch {
        throw "No-plugin check failed: profile manifest is not valid JSON: $manifestPath"
    }

    $dependencies = @()
    if ($null -ne $manifest.dependencies) {
        $dependencies = @($manifest.dependencies.PSObject.Properties | ForEach-Object { [string]$_.Name })
    }
    if ($dependencies.Count -ne 0) {
        throw ('No-plugin check failed: unexpected Profile dependencies: ' + ($dependencies -join ', '))
    }

    if ($null -eq $manifest.dsh -or $null -eq $manifest.dsh.profile) {
        throw 'No-plugin check failed: DSH profile bundle metadata is missing.'
    }
    $bundles = @($manifest.dsh.profile.bundles | ForEach-Object { [string]$_ })
    $expectedBundles = @('@deepseek-ai/dsh-base', '@deepseek-ai/dsh-web-app')
    $unexpectedBundles = @($bundles | Where-Object { $expectedBundles -notcontains $_ })
    $missingBundles = @($expectedBundles | Where-Object { $bundles -notcontains $_ })
    if ($bundles.Count -ne $expectedBundles.Count -or $unexpectedBundles.Count -ne 0 -or $missingBundles.Count -ne 0) {
        throw ('No-plugin check failed: expected only core bundles [' +
            ($expectedBundles -join ', ') + '], got [' + ($bundles -join ', ') + '].')
    }

    $patchPath = Join-Path $profileRoot 'cordis.patch.yml'
    if (-not (Test-Path -LiteralPath $patchPath -PathType Leaf)) {
        throw "No-plugin check failed: profile patch file was not created: $patchPath"
    }
    $effectivePatchLines = @(
        Get-Content -LiteralPath $patchPath |
            ForEach-Object { $_.Trim() } |
            Where-Object { $_ -and -not $_.StartsWith('#') })
    if ($effectivePatchLines.Count -ne 1 -or $effectivePatchLines[0] -ne '[]') {
        throw "No-plugin check failed: profile patch layer is not empty: $patchPath"
    }

    Ok 'fresh Profile contains only DSH core bundles and no user plugins'
}

function Invoke-CliSmoke {
    $cliHome = Join-Path $sessionRoot 'cli-dsh-home'
    New-Item -ItemType Directory -Force -Path $cliHome | Out-Null
    $webHome = $cliHome
    if (-not [string]::IsNullOrWhiteSpace($WebProfileDshHome)) {
        if (-not (Test-Path -LiteralPath $WebProfileDshHome -PathType Container)) {
            throw "WebProfileDshHome does not exist: $WebProfileDshHome"
        }
        $webHome = (Resolve-Path -LiteralPath $WebProfileDshHome).Path
        Say "Web startup uses existing DSH_HOME (read/write only as DSH normally does): $webHome"
    }
    Say "CLI version probe: $DshVersion"

    $versionResult = Invoke-CapturedCommand `
        -argumentLine ('/d /s /c "npx -y @deepseek-ai/dsh@' + $DshVersion + ' --version"') `
        -dshHome $cliHome -timeoutSeconds $TimeoutSeconds
    $versionOutput = ($versionResult.Stdout + "`n" + $versionResult.Stderr)
    $versionTokens = @($versionOutput -split '\s+')
    if (($versionResult.ExitCode -ne 0) -or (-not ($versionTokens -contains $DshVersion))) {
        throw "Version probe failed: $versionOutput"
    }
    Ok 'CLI --version'

    $helpResult = Invoke-CapturedCommand `
        -argumentLine ('/d /s /c "npx -y @deepseek-ai/dsh@' + $DshVersion + ' --profile web --help"') `
        -dshHome $cliHome -timeoutSeconds $TimeoutSeconds
    $helpOutput = ($helpResult.Stdout + "`n" + $helpResult.Stderr)
    if ($helpResult.ExitCode -ne 0 -or
        $helpOutput -notmatch '--port' -or $helpOutput -notmatch '--no-open') {
        throw "Help did not contain both --port and --no-open: $helpOutput"
    }
    Ok 'CLI --help contains --port / --no-open'

    $probePort = if ($Port -gt 0) { $Port } else { Get-FreeTcpPort }
    $run = Start-DshServer $probePort $webHome
    try {
        $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
        $ready = $false
        $readyUrl = ''
        while ([DateTime]::UtcNow -lt $deadline) {
            $run.Process.Refresh()
            if ($run.Process.HasExited) {
                throw "DSH exited before ready, exit code $($run.Process.ExitCode): $(Get-RunOutput $run)"
            }
            $readyUrl = Get-DshReadyUrl $run $probePort
            if ($readyUrl -and (Test-Http200 $readyUrl)) {
                $ready = $true
                break
            }
            Start-Sleep -Milliseconds 500
        }
        if (-not $ready) {
            throw "DSH did not reach banner + HTTP 200 within $TimeoutSeconds seconds: $(Get-RunOutput $run)"
        }

        for ($i = 0; $i -lt $StableSeconds; $i++) {
            if (-not $readyUrl -or -not (Test-Http200 $readyUrl)) {
                throw "DSH HTTP 200 stability check failed on port $probePort"
            }
            Start-Sleep -Seconds 1
        }
        if ($RequireNoUserPlugins) { Assert-NoUserPlugins $webHome }
        Ok ("CLI --no-open ready URL + HTTP 200 + stable {0}s on port {1}" -f $StableSeconds, $probePort)
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
        throw 'No current release candidate EXE was found; pass -AppExe explicitly. The installed older EXE is not sufficient for this DesktopShell acceptance run.'
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
    Write-Host 'Follow docs\DSH_RC2_MANUAL_ACCEPTANCE.md for DesktopShell startup, backend restart, attachment/image, tray, and exit checks.' -ForegroundColor Yellow
    Read-Host 'Press Enter after GUI manual checks; the exact test process and temp directory will be cleaned' | Out-Null

    Stop-TestProcessTree $process.Id
    Stop-TestPort $guiPort
    Ok 'GUI manual phase ended; test port is closed'
}

function Invoke-PluginPreflight {
    if ($DshVersion -ne '0.1.5-rc.2') {
        throw '当前插件生态 preflight 只允许固定目标 0.1.5-rc.2。'
    }
    $ecosystemPreflight = Join-Path $repoRoot 'scripts\Test-DshPluginEcosystemPreflight.ps1'
    $targetHome = if ($WebProfileDshHome) {
        $WebProfileDshHome
    } elseif ($env:DSH_HOME) {
        $env:DSH_HOME
    } else {
        Join-Path ([Environment]::GetFolderPath('UserProfile')) '.dsh'
    }
    Say "Plugin ecosystem preflight uses actual Profile metadata: $targetHome"
    & $ecosystemPreflight -DshHome $targetHome -DshVersion $DshVersion -TimeoutSeconds ([Math]::Max(120, $TimeoutSeconds)) -StableSeconds 10
    if ($LASTEXITCODE -ne 0) { throw "生态 preflight 返回 exit code $LASTEXITCODE" }
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
