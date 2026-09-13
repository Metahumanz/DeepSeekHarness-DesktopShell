$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$sourcePath = Join-Path $repo 'src\DeepSeekHarness.cs'
$uninstallPath = Join-Path $repo 'scripts\Uninstall-DesktopShell.ps1'
$source = [System.IO.File]::ReadAllText($sourcePath)
$base = Join-Path $env:TEMP ('dsh-production-contracts-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $base | Out-Null

$fail = 0
function Assert-True([string]$label, [bool]$condition) {
    if ($condition) { Write-Host "PASS: $label" }
    else { $script:fail++; Write-Host "FAIL: $label" }
}

# Extract product C# members directly so the harnesses cannot drift from production logic.
function Get-CSharpMemberText([string]$text, [int]$start) {
    if ($start -lt 0) { throw 'C# member start marker not found' }
    $openBrace = $text.IndexOf('{', $start)
    if ($openBrace -lt 0) { throw 'C# member opening brace not found' }
    $depth = 0
    for ($i = $openBrace; $i -lt $text.Length; $i++) {
        if ($text[$i] -eq '{') { $depth++ }
        elseif ($text[$i] -eq '}') {
            $depth--
            if ($depth -eq 0) { return $text.Substring($start, $i - $start + 1) }
        }
    }
    throw 'C# member closing brace not found'
}

function Get-CscPath {
    $candidates = @(
        "$env:WINDIR\Microsoft.NET\Framework64\v4.0.30319\csc.exe",
        "$env:WINDIR\Microsoft.NET\Framework\v4.0.30319\csc.exe"
    )
    return @($candidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1)[0]
}

function Write-LedgerFixture([string]$dshHome, [string]$json) {
    $ledgerDir = Join-Path $dshHome 'storages\cost-meter'
    New-Item -ItemType Directory -Force -Path $ledgerDir | Out-Null
    $path = Join-Path $ledgerDir 'ledger.json'
    [System.IO.File]::WriteAllText($path, $json, [System.Text.UTF8Encoding]::new($false))
    return $path
}

function Write-LegacyCostMeterSourceFixture([string]$dshHome) {
    $pluginDir = Join-Path $dshHome 'profiles\web\node_modules\dsh-cost-meter\lib'
    New-Item -ItemType Directory -Force -Path $pluginDir | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $pluginDir 'index.js'), @'
ctx.on('llm/stream'
if (usage !== null) { // DSH Desktop compat: ignore synthetic ModLens wrapper
  ledger.account(
}
'@, [System.Text.UTF8Encoding]::new($false))
    [System.IO.File]::WriteAllText((Join-Path $pluginDir 'backfill.js'), @'
// DSH Desktop compat: ignore synthetic ModLens wrapper in backfill replay
'@, [System.Text.UTF8Encoding]::new($false))
}

function Write-WrapperAwareCostMeterSourceFixture([string]$dshHome) {
    $pluginDir = Join-Path $dshHome 'profiles\web\node_modules\dsh-cost-meter\lib'
    New-Item -ItemType Directory -Force -Path $pluginDir | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $pluginDir 'index.js'), @'
if (isWrapperProviderId(sampleProvider)) {
  effectiveProvider = wrapperUpstreamProvider(sampleProvider) ?? sampleProvider
}
'@, [System.Text.UTF8Encoding]::new($false))
    [System.IO.File]::WriteAllText((Join-Path $pluginDir 'backfill.js'), @'
if (isWrapperProviderId(sampleProvider)) {
  effectiveProvider = wrapperUpstreamProvider(sampleProvider) ?? sampleProvider
}
'@, [System.Text.UTF8Encoding]::new($false))
}

$fixture = @'
{
  "days": {
    "2026-08-19": {
      "input": 999, "output": 999, "cacheRead": 999, "cacheWrite": 999, "reasoning": 999, "calls": 999, "cost": 999,
      "byProviderModel": {
        "deepseek-modlens:deepseek-chat": {"input":10,"output":10,"cacheRead":0,"cacheWrite":0,"reasoning":0,"calls":1,"cost":0.5},
        "modlens-openrouter:gpt": {"input":10,"output":10,"cacheRead":0,"cacheWrite":0,"reasoning":0,"calls":1,"cost":0.5},
        "modlens-:x": {"input":10,"output":10,"cacheRead":0,"cacheWrite":0,"reasoning":0,"calls":1,"cost":0.5},
        "openrouter:gpt": {"input":10,"output":10,"cacheRead":0,"cacheWrite":0,"reasoning":0,"calls":1,"cost":0.5}
      },
      "sessions": [
        {"id":"s1","input":888,"output":888,"cacheRead":888,"cacheWrite":888,"reasoning":888,"calls":888,"cost":888,
         "byProviderModel": {
           "modlens-foo:model": {"input":5,"output":5,"cacheRead":0,"cacheWrite":0,"reasoning":0,"calls":1,"cost":0.25},
           "openrouter:gpt": {"input":5,"output":5,"cacheRead":0,"cacheWrite":0,"reasoning":0,"calls":1,"cost":0.25}
         }}
      ]
    }
  }
}
'@

try {
    $csc = Get-CscPath
    if (-not $csc) { throw 'csc not found' }

    # ---- 1. C# and uninstaller port arguments must match a full token: 30801 is not 3080. ----
    $methodStart = $source.IndexOf('        public static bool IsLikelyDshCommandLine', [System.StringComparison]::Ordinal)
    $identityMethod = Get-CSharpMemberText $source $methodStart
    $identityCs = Join-Path $base 'identity-harness.cs'
    $identitySource = @"
using System;
using System.Text.RegularExpressions;
namespace DeepSeekHarnessDesktop
{
    internal static class CommandLineIdentityHarness
    {
$identityMethod

        private static int failures;
        private static void Check(bool condition, string label)
        {
            if (condition) Console.WriteLine("PASS: " + label);
            else { failures++; Console.WriteLine("FAIL: " + label); }
        }

        public static int Main()
        {
            string line;
            Check(IsLikelyDshCommandLine("npx @deepseek-ai/dsh@0.1.5-rc.2 --profile work --port 3080", 3080, out line), "exact port accepted");
            Check(!IsLikelyDshCommandLine("npx @deepseek-ai/dsh@0.1.5-rc.2 --profile work --port 30801", 3080, out line), "port prefix rejected");
            Check(!IsLikelyDshCommandLine("npx @deepseek-ai/dsh@0.1.5-rc.2 --profile work --port 3080x", 3080, out line), "non-boundary suffix rejected");
            return failures == 0 ? 0 : 1;
        }
    }
}
"@
    [System.IO.File]::WriteAllText($identityCs, $identitySource, [System.Text.UTF8Encoding]::new($true))
    $identityExe = Join-Path $base 'identity-harness.exe'
    & $csc /nologo /target:exe /optimize+ /main:DeepSeekHarnessDesktop.CommandLineIdentityHarness `
        "/out:$identityExe" /reference:System.dll /reference:System.Core.dll $identityCs 2>&1 | Out-String | Write-Host
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $identityExe)) { throw 'C# command-line identity harness compile failed' }
    $identityOutput = & $identityExe 2>&1 | Out-String
    Write-Host $identityOutput
    Assert-True 'C# command-line identity applies exact port boundary' ($LASTEXITCODE -eq 0)

    # Extract the production uninstaller function body instead of maintaining a test copy.
    $tokens = @(); $parseErrors = @()
    $uninstallAst = [System.Management.Automation.Language.Parser]::ParseFile($uninstallPath, [ref]$tokens, [ref]$parseErrors)
    if ($parseErrors.Count -gt 0) { throw "Uninstall-DesktopShell.ps1 parse errors: $($parseErrors.Count)" }
    $psIdentityFunction = $uninstallAst.Find({
        param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
        $node.Name -eq 'Test-LikelyDshCommandLine'
    }, $true)
    if (-not $psIdentityFunction) { throw 'Test-LikelyDshCommandLine not found' }
    $psIdentityBody = $psIdentityFunction.Body.Extent.Text.Trim()
    if ($psIdentityBody.StartsWith('{')) { $psIdentityBody = $psIdentityBody.Substring(1) }
    if ($psIdentityBody.EndsWith('}')) { $psIdentityBody = $psIdentityBody.Substring(0, $psIdentityBody.Length - 1) }
    $psIdentity = [scriptblock]::Create("param([string]`$cmd, [int]`$port)`r`n$psIdentityBody")
    $validCommand = 'npx @deepseek-ai/dsh@0.1.5-rc.2 --profile work --port 3080'
    $prefixPortCommand = 'npx @deepseek-ai/dsh@0.1.5-rc.2 --profile work --port 30801'
    Assert-True 'PowerShell uninstaller accepts exact port' ([bool](& $psIdentity $validCommand 3080))
    Assert-True 'PowerShell uninstaller rejects port prefix' (-not [bool](& $psIdentity $prefixPortCommand 3080))

    # ---- 2. Compile production PluginCompat and verify ledger repair above the default 2 MiB JSON limit. ----
    $classStart = $source.IndexOf('    internal static class PluginCompat', [System.StringComparison]::Ordinal)
    $classEnd = $source.IndexOf('    internal sealed class BackendProcessExitedEventArgs', $classStart, [System.StringComparison]::Ordinal)
    if ($classStart -lt 0 -or $classEnd -le $classStart) { throw 'PluginCompat source markers not found' }
    $pluginCompatClass = $source.Substring($classStart, $classEnd - $classStart)
    Assert-True 'PluginCompat configures a deliberate ledger JSON limit' (
        $pluginCompatClass -match 'MaxLedgerJsonChars = 16 \* 1024 \* 1024' -and
        $pluginCompatClass -match 'serializer\.MaxJsonLength = MaxLedgerJsonChars')

    $ledgerHarnessCs = Join-Path $base 'ledger-harness.cs'
    $ledgerHarnessSource = @"
using System;
using System.Collections;
using System.Collections.Generic;
using System.IO;
using System.Text;
using System.Web.Script.Serialization;
namespace DeepSeekHarnessDesktop
{
    internal static class AppSettings
    {
        internal static string NormalizeProfileName(string value)
        {
            return String.IsNullOrWhiteSpace(value) ? "web" : value;
        }
    }

$pluginCompatClass

    internal static class PluginCompatLedgerHarness
    {
        public static int Main(string[] args)
        {
            if (args.Length != 2) return 2;
            int pending = PluginCompat.ApplyAll(args[0], args[1], "web", true);
            Console.WriteLine("PENDING=" + pending);
            return pending == 1 ? 0 : 1;
        }
    }
}
"@
    [System.IO.File]::WriteAllText($ledgerHarnessCs, $ledgerHarnessSource, [System.Text.UTF8Encoding]::new($true))
    $ledgerHarnessExe = Join-Path $base 'ledger-harness.exe'
    & $csc /nologo /target:exe /optimize+ /main:DeepSeekHarnessDesktop.PluginCompatLedgerHarness `
        "/out:$ledgerHarnessExe" /reference:System.dll /reference:System.Core.dll /reference:System.Web.Extensions.dll `
        $ledgerHarnessCs 2>&1 | Out-String | Write-Host
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $ledgerHarnessExe)) { throw 'PluginCompat ledger harness compile failed' }

    $hadDshHome = Test-Path Env:DSH_HOME
    $previousDshHome = $env:DSH_HOME
    try {
        $normalHome = Join-Path $base 'normal-dsh-home'
        $normalLedger = Write-LedgerFixture $normalHome $fixture
        Write-LegacyCostMeterSourceFixture $normalHome
        $env:DSH_HOME = $normalHome
        $normalLogs = Join-Path $base 'normal-logs'
        $normalOutput = & $ledgerHarnessExe $base $normalLogs 2>&1 | Out-String
        Write-Host $normalOutput
        Assert-True 'production PluginCompat repairs the normal synthetic ledger' ($LASTEXITCODE -eq 0 -and $normalOutput -match 'PENDING=1')
        $normalFixed = Get-Content -LiteralPath $normalLedger -Raw -Encoding UTF8 | ConvertFrom-Json
        $normalDay = $normalFixed.days.'2026-08-19'
        $normalSession = $normalDay.sessions[0]
        Assert-True 'production repair removes all synthetic day buckets' (
            @($normalDay.byProviderModel.PSObject.Properties.Name | Where-Object { $_ -match '^(deepseek-modlens:|modlens-)' }).Count -eq 0)
        Assert-True 'production repair recomputes day totals from legitimate bucket' (
            [double]$normalDay.input -eq 10.0 -and [int]$normalDay.calls -eq 1 -and [double]$normalDay.cost -eq 0.5)
        Assert-True 'production repair recomputes session totals from legitimate bucket' (
            [double]$normalSession.input -eq 5.0 -and [int]$normalSession.calls -eq 1 -and [double]$normalSession.cost -eq 0.25)

        $largeHome = Join-Path $base 'large-dsh-home'
        $largePayload = [string]::new([char]'x', (2 * 1024 * 1024) + 4096)
        $largeFixture = '{"metadata":"' + $largePayload + '",' + $fixture.Trim().Substring(1)
        $largeLedger = Write-LedgerFixture $largeHome $largeFixture
        Write-LegacyCostMeterSourceFixture $largeHome
        Assert-True 'large ledger exceeds JavaScriptSerializer default 2 MiB threshold' (
            ([System.IO.File]::ReadAllText($largeLedger).Length -gt (2 * 1024 * 1024)))
        $env:DSH_HOME = $largeHome
        $largeLogs = Join-Path $base 'large-logs'
        $largeOutput = & $ledgerHarnessExe $base $largeLogs 2>&1 | Out-String
        Write-Host $largeOutput
        Assert-True 'production PluginCompat accepts and repairs large bounded ledger' ($LASTEXITCODE -eq 0 -and $largeOutput -match 'PENDING=1')
        $largeFixed = Get-Content -LiteralPath $largeLedger -Raw -Encoding UTF8 | ConvertFrom-Json
        Assert-True 'large ledger retains metadata and removes synthetic buckets' (
            $largeFixed.metadata.Length -eq $largePayload.Length -and
            @($largeFixed.days.'2026-08-19'.byProviderModel.PSObject.Properties.Name |
                Where-Object { $_ -match '^(deepseek-modlens:|modlens-)' }).Count -eq 0)

        $modernHome = Join-Path $base 'wrapper-aware-dsh-home'
        $modernLedger = Write-LedgerFixture $modernHome $fixture
        Write-WrapperAwareCostMeterSourceFixture $modernHome
        $env:DSH_HOME = $modernHome
        $modernLogs = Join-Path $base 'wrapper-aware-logs'
        $modernOutput = & $ledgerHarnessExe $base $modernLogs 2>&1 | Out-String
        Write-Host $modernOutput
        Assert-True 'native wrapper-aware Cost Meter skips legacy ledger deletion' (
            $modernOutput -match 'PENDING=0')
        $modernFixed = Get-Content -LiteralPath $modernLedger -Raw -Encoding UTF8 | ConvertFrom-Json
        Assert-True 'native wrapper-aware ledger retains provider buckets for upstream migration' (
            @($modernFixed.days.'2026-08-19'.byProviderModel.PSObject.Properties.Name |
                Where-Object { $_ -match '^(deepseek-modlens:|modlens-)' }).Count -eq 3)
    }
    finally {
        if ($hadDshHome) { $env:DSH_HOME = $previousDshHome }
        else { Remove-Item Env:DSH_HOME -ErrorAction SilentlyContinue }
    }
}
catch {
    Write-Host "FAIL: production compatibility contract setup: $($_.Exception.Message)"
    $fail++
}
finally {
    Remove-Item -LiteralPath $base -Recurse -Force -ErrorAction SilentlyContinue
}

if ($fail -eq 0) { Write-Host 'PRODUCTION COMPATIBILITY CONTRACT TESTS PASSED' }
else { Write-Host "FAILURES: $fail" }
exit $(if ($fail -eq 0) { 0 } else { 1 })
