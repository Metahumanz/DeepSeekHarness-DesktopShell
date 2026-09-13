[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$DshHome,
    [string]$Profile = 'web',
    [string]$DshVersion = '0.1.5-rc.2',
    [int]$Port = 0,
    [string]$ResultPath = ''
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

if ($DshVersion -ne '0.1.5-rc.2') { throw 'WebView2 验收只接受固定目标 DSH 0.1.5-rc.2。' }
if ($Profile -notmatch '^[A-Za-z0-9_-]+$') { throw 'Profile 必须是安全的单段名称。' }
$DshHome = [IO.Path]::GetFullPath($DshHome)
$profilePackage = Join-Path $DshHome (Join-Path 'profiles' (Join-Path $Profile 'package.json'))
if (-not (Test-Path -LiteralPath $profilePackage -PathType Leaf)) { throw "找不到待验收 Profile：$profilePackage" }

function Get-FreeTcpPort {
    $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
    try { $listener.Start(); return [int]$listener.LocalEndpoint.Port }
    finally { try { $listener.Stop() } catch { } }
}

function Redact-BrowserAuthText([string]$text) {
    if ([string]::IsNullOrWhiteSpace($text)) { return '' }
    return [regex]::Replace($text, '(?i)([?&](?:token|auth|key|secret|password)=[^&#\s]+)', '$1<redacted>')
}

if ($Port -eq 0) { $Port = Get-FreeTcpPort }
if ($Port -lt 1 -or $Port -gt 65535) { throw 'Port 必须在 1..65535。' }
if (Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue) {
    throw "验收端口已被占用：$Port。拒绝附着外部 DSH，因为没有本次 BrowserAuth token。"
}

$npx = Get-Command npx.cmd -ErrorAction SilentlyContinue
if (-not $npx) { $npx = Get-Command npx.exe -ErrorAction SilentlyContinue }
if (-not $npx) { throw '找不到 npx；无法启动本次受控 DSH 进行 WebView2 验收。' }
$csc = @(
    "$env:WINDIR\Microsoft.NET\Framework64\v4.0.30319\csc.exe",
    "$env:WINDIR\Microsoft.NET\Framework\v4.0.30319\csc.exe"
) | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
if (-not $csc) { throw '找不到 .NET Framework csc.exe。' }

$sdkRoot = Join-Path $env:USERPROFILE '.nuget\packages\microsoft.web.webview2\1.0.4078.44'
if (-not (Test-Path -LiteralPath $sdkRoot -PathType Container)) { throw "找不到固定 WebView2 SDK：$sdkRoot" }
$core = Get-ChildItem -LiteralPath $sdkRoot -Recurse -Filter 'Microsoft.Web.WebView2.Core.dll' |
    Where-Object { $_.FullName -match '[\\/]lib[\\/]' } | Select-Object -First 1
$winForms = Get-ChildItem -LiteralPath $sdkRoot -Recurse -Filter 'Microsoft.Web.WebView2.WinForms.dll' |
    Where-Object { $_.FullName -match '[\\/]lib[\\/]' } | Select-Object -First 1
$loader = Get-ChildItem -LiteralPath $sdkRoot -Recurse -Filter 'WebView2Loader.dll' |
    Where-Object { $_.FullName -match 'win-x64' } | Select-Object -First 1
if (-not $core -or -not $winForms -or -not $loader) { throw '固定 WebView2 SDK 缺少 Core/WinForms/x64 Loader。' }

if ([string]::IsNullOrWhiteSpace($ResultPath)) {
    $ResultPath = Join-Path $PSScriptRoot '..\docs\WEBVIEW2_ACCEPTANCE_0.1.5-rc.2.json'
}
$ResultPath = [IO.Path]::GetFullPath($ResultPath)
$workRoot = Join-Path ([IO.Path]::GetTempPath()) ('dsh-webview2-acceptance-' + [guid]::NewGuid().ToString('N'))
$result = $null

try {
    New-Item -ItemType Directory -Force -Path $workRoot | Out-Null
    $harnessCs = Join-Path $workRoot 'WebView2AcceptanceHarness.cs'
    $harnessExe = Join-Path $workRoot 'WebView2AcceptanceHarness.exe'
    $userData = Join-Path $workRoot 'webview2-data'
    Copy-Item -LiteralPath $core.FullName -Destination (Join-Path $workRoot 'Microsoft.Web.WebView2.Core.dll') -Force
    Copy-Item -LiteralPath $winForms.FullName -Destination (Join-Path $workRoot 'Microsoft.Web.WebView2.WinForms.dll') -Force
    Copy-Item -LiteralPath $loader.FullName -Destination (Join-Path $workRoot 'WebView2Loader.dll') -Force

    $source = @'
using System;
using System.Diagnostics;
using System.Net;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;
using System.Threading.Tasks;
using System.Windows.Forms;
using Microsoft.Web.WebView2.Core;
using Microsoft.Web.WebView2.WinForms;

internal static class WebView2AcceptanceHarness
{
    private static readonly object OutputGate = new object();
    private static readonly StringBuilder Output = new StringBuilder();
    private static Process backend;
    private static TaskCompletionSource<bool> currentNavigation;
    private static bool webView2;
    private static bool mainUi;
    private static bool refresh;
    private static bool settings;
    private static bool pluginState;
    private static string stage = "init";
    private static string settingsDebug = "";

    [STAThread]
    private static int Main(string[] args)
    {
        try
        {
            if (args.Length != 6) throw new InvalidOperationException("invalid arguments");
            string dshHome = args[0];
            string profile = args[1];
            int port = Int32.Parse(args[2]);
            string npx = args[3];
            string userData = args[4];
            int timeoutSeconds = Int32.Parse(args[5]);
            string readyUrl = StartAndWaitForReady(dshHome, profile, port, npx, timeoutSeconds);
            stage = "backend-ready";

            Application.EnableVisualStyles();
            Application.SetCompatibleTextRenderingDefault(false);
            using (Form form = new Form())
            {
                form.Width = 1024;
                form.Height = 720;
                form.ShowInTaskbar = false;
                form.Opacity = 0.01;
                WebView2 view = new WebView2();
                view.Dock = DockStyle.Fill;
                form.Controls.Add(view);
                form.Shown += async delegate
                {
                    try
                    {
                        stage = "webview-environment";
                        CoreWebView2Environment environment = await CoreWebView2Environment.CreateAsync(null, userData);
                        await view.EnsureCoreWebView2Async(environment);
                        CoreWebView2 core = view.CoreWebView2;
                        core.NavigationCompleted += delegate(object sender, CoreWebView2NavigationCompletedEventArgs e)
                        {
                            TaskCompletionSource<bool> pending = currentNavigation;
                            if (pending != null) pending.TrySetResult(e.IsSuccess);
                        };

                        currentNavigation = new TaskCompletionSource<bool>();
                        stage = "first-navigation";
                        // 只在内存中使用本次 dsh web 输出的完整 BrowserAuth URL；不向日志或结果写入它。
                        core.Navigate(readyUrl);
                        webView2 = await WaitForNavigation(currentNavigation.Task, timeoutSeconds);
                        currentNavigation = null;
                        if (webView2)
                        {
                            stage = "main-ui";
                            mainUi = JsTrue(await core.ExecuteScriptAsync(
                                "Boolean(document.body && document.body.innerText && document.body.innerText.length > 0)"));
                            pluginState = JsTrue(await core.ExecuteScriptAsync(
                                "(function(){var t=(document.body&&document.body.innerText)||'';return !/Failed\\s+to\\s+load\\s+plugins|pending\\s*\\(\\s*waiting\\s+for\\s+service/i.test(t);})()"));

                            currentNavigation = new TaskCompletionSource<bool>();
                            stage = "refresh";
                            core.Reload();
                            refresh = await WaitForNavigation(currentNavigation.Task, timeoutSeconds);
                            currentNavigation = null;

                            bool clicked = JsTrue(await core.ExecuteScriptAsync(
                                "(function(){var xs=Array.prototype.slice.call(document.querySelectorAll('a,button,[role=button]'));var e=xs.filter(function(x){return /settings|\\u8bbe\\u7f6e/i.test([(x.innerText||x.textContent||'').trim(),x.getAttribute('aria-label')||'',x.getAttribute('title')||''].join(' '));})[0];if(!e)return false;e.click();return true;})()"));
                            if (clicked)
                            {
                                stage = "settings";
                                await Task.Delay(1200);
                                settings = JsTrue(await core.ExecuteScriptAsync(
                                    "(function(){var u=(location.pathname||'')+(location.hash||'');if(/settings|\\u8bbe\\u7f6e/i.test(u))return true;var d=document.querySelector('[role=dialog]');return Boolean(d&&/settings|\\u8bbe\\u7f6e/i.test((d.innerText||d.textContent||'')));})()"));
                                if (!settings)
                                {
                                    settingsDebug = await core.ExecuteScriptAsync(
                                        "JSON.stringify({dialogs:Array.prototype.slice.call(document.querySelectorAll('[role=dialog]')).map(function(e){return {aria:e.getAttribute('aria-label')||'',text:(e.innerText||e.textContent||'').slice(0,160)}}),controls:Array.prototype.slice.call(document.querySelectorAll('a,button,[role=button]')).slice(0,40).map(function(e){return {tag:e.tagName,aria:e.getAttribute('aria-label')||'',title:e.getAttribute('title')||'',testid:e.getAttribute('data-testid')||'',role:e.getAttribute('role')||''};})})");
                                    stage = "settings-not-confirmed";
                                }
                            }
                            else
                            {
                                // 仅收集控件的无敏感可访问性元数据，帮助定位图标型设置入口；不采集 URL、页面正文或 token。
                                settingsDebug = await core.ExecuteScriptAsync(
                                    "JSON.stringify(Array.prototype.slice.call(document.querySelectorAll('a,button,[role=button]')).slice(0,40).map(function(e){return {tag:e.tagName,aria:e.getAttribute('aria-label')||'',title:e.getAttribute('title')||'',testid:e.getAttribute('data-testid')||'',role:e.getAttribute('role')||''};}))");
                                stage = "settings-link-missing";
                            }
                        }
                        else { stage = "first-navigation-failed"; }
                    }
                    catch
                    {
                        // 结果仅保留布尔检查，不把 ready URL、页面内容或 token 写到 stdout。
                        stage = "webview-exception";
                    }
                    finally { form.Close(); }
                };
                Application.Run(form);
            }
        }
        catch { }
        finally { StopBackend(); }

        bool pass = webView2 && mainUi && refresh && settings && pluginState;
        Console.WriteLine("WEBVIEW2_RESULT {\"status\":\"" + (pass ? "PASS" : "BLOCKED") +
            "\",\"stage\":\"" + stage + "\",\"checks\":{\"webView2\":" + webView2.ToString().ToLowerInvariant() +
            ",\"mainUi\":" + mainUi.ToString().ToLowerInvariant() +
            ",\"refresh\":" + refresh.ToString().ToLowerInvariant() +
            ",\"settings\":" + settings.ToString().ToLowerInvariant() +
            ",\"pluginState\":" + pluginState.ToString().ToLowerInvariant() + "}}");
        if (!String.IsNullOrEmpty(settingsDebug)) Console.WriteLine("WEBVIEW2_DEBUG " + settingsDebug);
        return pass ? 0 : 1;
    }

    private static async Task<bool> WaitForNavigation(Task<bool> task, int seconds)
    {
        Task done = await Task.WhenAny(task, Task.Delay(TimeSpan.FromSeconds(seconds)));
        return done == task && task.Result;
    }

    private static bool JsTrue(string response)
    {
        return !String.IsNullOrEmpty(response) && response.IndexOf("true", StringComparison.OrdinalIgnoreCase) >= 0;
    }

    private static string StartAndWaitForReady(string dshHome, string profile, int port, string npx, int timeoutSeconds)
    {
        ProcessStartInfo psi = new ProcessStartInfo();
        psi.FileName = Environment.GetEnvironmentVariable("ComSpec") ?? "cmd.exe";
        psi.Arguments = "/d /s /c \"\"" + npx + "\" --yes @deepseek-ai/dsh@0.1.5-rc.2 --profile " + profile + " --no-open --port " + port.ToString() + "\"";
        psi.UseShellExecute = false;
        psi.CreateNoWindow = true;
        psi.RedirectStandardOutput = true;
        psi.RedirectStandardError = true;
        psi.EnvironmentVariables["DSH_HOME"] = dshHome;
        backend = Process.Start(psi);
        backend.OutputDataReceived += delegate(object sender, DataReceivedEventArgs e) { if (e.Data != null) lock (OutputGate) Output.AppendLine(e.Data); };
        backend.ErrorDataReceived += delegate(object sender, DataReceivedEventArgs e) { if (e.Data != null) lock (OutputGate) Output.AppendLine(e.Data); };
        backend.BeginOutputReadLine();
        backend.BeginErrorReadLine();
        DateTime deadline = DateTime.UtcNow.AddSeconds(timeoutSeconds);
        Regex ready = new Regex("dsh\\s+web\\s*:\\s*(http://[^\\s\\\"']+)", RegexOptions.IgnoreCase);
        while (DateTime.UtcNow < deadline)
        {
            if (backend.HasExited) throw new InvalidOperationException("backend exited before ready");
            string text;
            lock (OutputGate) text = Output.ToString();
            Match match = ready.Match(text);
            if (match.Success)
            {
                Uri uri = new Uri(match.Groups[1].Value);
                string host = uri.Host.ToLowerInvariant();
                if (uri.Scheme == Uri.UriSchemeHttp && (host == "127.0.0.1" || host == "localhost" || host == "::1") && uri.Port == port)
                    return uri.AbsoluteUri;
            }
            Thread.Sleep(100);
        }
        throw new TimeoutException("ready timeout");
    }

    private static void StopBackend()
    {
        try
        {
            if (backend == null || backend.HasExited) return;
            ProcessStartInfo kill = new ProcessStartInfo();
            kill.FileName = Environment.GetEnvironmentVariable("ComSpec") ?? "cmd.exe";
            kill.Arguments = "/d /s /c taskkill /PID " + backend.Id.ToString() + " /T /F";
            kill.UseShellExecute = false;
            kill.CreateNoWindow = true;
            using (Process process = Process.Start(kill)) process.WaitForExit(5000);
        }
        catch { }
    }
}
'@
    [IO.File]::WriteAllText($harnessCs, $source, [Text.UTF8Encoding]::new($false))
    & $csc /nologo /target:exe /optimize+ "/out:$harnessExe" `
        /reference:System.dll /reference:System.Core.dll /reference:System.Drawing.dll /reference:System.Windows.Forms.dll `
        "/reference:$($core.FullName)" "/reference:$($winForms.FullName)" $harnessCs 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $harnessExe -PathType Leaf)) { throw 'WebView2 验收 harness 编译失败。' }

    $raw = & $harnessExe $DshHome $Profile ([string]$Port) $npx.Source $userData '120' 2>&1 | Out-String
    $code = $LASTEXITCODE
    $line = @($raw -split "`r?`n" | Where-Object { $_ -like 'WEBVIEW2_RESULT *' } | Select-Object -Last 1)
    if ($line.Count -eq 0) { throw 'WebView2 harness 未返回 token-free 结果。' }
    $payload = $line[0].Substring('WEBVIEW2_RESULT '.Length) | ConvertFrom-Json
    $debugLine = @($raw -split "`r?`n" | Where-Object { $_ -like 'WEBVIEW2_DEBUG *' } | Select-Object -Last 1)
    $result = [pscustomobject]@{
        schemaVersion = 1
        targetDshVersion = $DshVersion
        profile = $Profile
        status = [string]$payload.status
        stage = [string]$payload.stage
        checks = $payload.checks
    }
    if ($debugLine.Count -gt 0) {
        try {
            $debugJson = $debugLine[0].Substring('WEBVIEW2_DEBUG '.Length) | ConvertFrom-Json
            Add-Member -InputObject $result -MemberType NoteProperty -Name settingsCandidates -Value ($debugJson | ConvertFrom-Json) -Force
        }
        catch { }
    }
    if ($code -ne 0 -or $result.status -ne 'PASS') { throw ('WebView2 / 主界面 / 刷新 / 设置页验收未全部通过，阶段：' + [string]$payload.stage) }
}
catch {
    if ($result) {
        $result.status = 'BLOCKED'
        Add-Member -InputObject $result -MemberType NoteProperty -Name reason -Value (Redact-BrowserAuthText $_.Exception.Message) -Force
    }
    else {
        $result = [pscustomobject]@{
            schemaVersion = 1
            targetDshVersion = $DshVersion
            profile = $Profile
            status = 'BLOCKED'
            checks = [pscustomobject]@{ webView2=$false; mainUi=$false; refresh=$false; settings=$false; pluginState=$false }
            reason = (Redact-BrowserAuthText $_.Exception.Message)
        }
    }
}
finally {
    $resultDirectory = Split-Path -Parent $ResultPath
    if ($resultDirectory) { New-Item -ItemType Directory -Force -Path $resultDirectory | Out-Null }
    [IO.File]::WriteAllText($ResultPath, ($result | ConvertTo-Json -Depth 8), [Text.UTF8Encoding]::new($false))
    Remove-Item -LiteralPath $workRoot -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ("WEBVIEW2 ACCEPTANCE status={0} result={1}" -f $result.status, $ResultPath)
exit $(if ($result.status -eq 'PASS') { 0 } else { 1 })
