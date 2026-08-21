# DSH 0.1.1-rc.1 兼容认证手动测试

> 适用目标：DesktopShell v1.0.5 候选包 + DSH `0.1.1-rc.1`。
>
> 本文用于真实 Windows 桌面验收。源码测试、CI 和 HTTP 探测不能替代窗口、托盘、WebView2、系统浏览器和进程残留的人工检查。所有结果必须按本文记录，不能把“未执行”写成“通过”。

## 0. 结果记录

测试人：__________　机器：__________　Windows：__________　DPI：__________

DesktopShell EXE 路径：________________________________________

DesktopShell 版本：__________　DSH 版本：`0.1.1-rc.1`　日期：__________

| 编号 | 场景 | 结果（PASS/FAIL/BLOCKED） | 日志/截图/备注 |
| --- | --- | --- | --- |
| CLI-01 | 版本、帮助、`--no-open`、HTTP 200 |  |  |
| APP-01 | DesktopShell rc1 正常启动 |  |  |
| APP-02 | 后端异常覆盖层与重启按钮 |  |  |
| APP-03 | “重新检查”按钮 |  |  |
| APP-04 | 正常重启后端 |  |  |
| APP-05 | 托盘隐藏/恢复 |  |  |
| APP-06 | 完全退出与残留检查 |  |  |
| ATTACH-01 | 外部 rc1 附着 |  |  |
| FOREIGN-01 | 非 DSH 进程占端口 |  |  |
| OAUTH-01 | Provider OAuth/WebView2 |  |  |
| PLUG-01 | 重点插件 preflight |  |  |
| REG-01 | PowerShell 7 回归 |  |  |
| REG-02 | Windows PowerShell 5.1 回归 |  |  |
| REL-01 | v1.0.5 x64 候选包 |  |  |

## 1. 安全边界和前置准备

1. 确认机器安装了 Node.js、npm/npx、WebView2 Runtime；桌面壳候选包为 x64。
2. 覆盖层修复必须使用**重新编译后的 v1.0.5 候选 EXE**。正式安装目录中未重新编译的旧 EXE 不能证明修复有效。
3. CLI、外部 DSH、Foreign listener、插件 preflight 使用临时 `DSH_HOME`、临时 Profile 和测试端口；不要清理、重命名或覆盖用户原始 `~\.dsh`、凭据或 WebView2 数据。
4. OAuth 只由用户本人在真实 Profile 中手动完成。不要把 API Key、密码、OTP、授权 URL 查询参数或凭据截图写入记录。
5. 每次启动后记录本轮的 DesktopShell PID、DSH wrapper PID、实际 listener PID、端口和对应日志文件。
6. 不使用 `taskkill /IM`、按进程名批量结束或“杀所有 node/cmd”。清理时只能结束本轮记录的精确 PID。

建议准备临时目录和测试端口：

```powershell
$TestRoot = Join-Path $env:TEMP ('dsh-rc1-manual-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $TestRoot | Out-Null
$TestPort = 3091
$LogDir = Join-Path $env:LOCALAPPDATA 'Programs\DeepSeek Harness DesktopShell\logs'
```

## 1.1 一键本机入口

在仓库根目录执行下面的命令即可完成 CLI smoke test。脚本自动使用随机端口、临时 `DSH_HOME`，结束时按精确 PID 清理：

```powershell
.\scripts\Test-DshRc1Local.ps1 -KeepTemp
```

需要进入 DesktopShell 真实鼠标/托盘测试时执行：

```powershell
.\scripts\Test-DshRc1Local.ps1 -LaunchDesktopShell -KeepTemp
```

脚本会：

1. 验证 rc1 `--version`、`--help`、`--port`、`--no-open`；
2. 启动临时 rc1，检查 ready banner、HTTP 200 和稳定性；
3. 复制候选 EXE 到临时应用目录，写入 rc1 测试设置并启动；
4. 打印 GUI PID、测试端口、临时 `DSH_HOME` 和日志路径；
5. 等待手动测试完成后，按 Enter 清理本轮精确进程和端口。

需要同时跑重点插件 preflight 时执行（耗时较长）：

```powershell
.\scripts\Test-DshRc1Local.ps1 -RunPlugins -KeepTemp
```

OAuth、真实鼠标点击、托盘操作和 Provider 授权仍必须由用户手动完成；脚本不会输入或保存任何凭据。

如果使用解压后的候选包，先设置：

```powershell
$AppDir = 'C:\path\to\extracted\DeepSeek Harness DesktopShell'
$AppExe = Join-Path $AppDir 'DeepSeekHarness.exe'
```

启动临时 DSH_HOME 的候选程序（PowerShell 7 和 Windows PowerShell 5.1 均可）：

```powershell
$oldDshHome = $env:DSH_HOME
$env:DSH_HOME = $TestRoot
$shell = Start-Process -FilePath $AppExe -WorkingDirectory $AppDir -PassThru
if ($null -eq $oldDshHome) { Remove-Item Env:DSH_HOME -ErrorAction SilentlyContinue }
else { $env:DSH_HOME = $oldDshHome }
$shell.Id
```

## 2. CLI 零修改实测（CLI-01）

在独立 PowerShell 窗口执行，不要先修改源码或兼容声明。新窗口中不要依赖上一窗口的变量，先创建独立 CLI DSH_HOME：

```powershell
$CliHome = Join-Path $env:TEMP ('dsh-rc1-cli-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $CliHome | Out-Null
$oldDshHome = $env:DSH_HOME
$env:DSH_HOME = $CliHome
npx -y @deepseek-ai/dsh@0.1.1-rc.1 --version
npx -y @deepseek-ai/dsh@0.1.1-rc.1 --profile web --help
```

确认：

- 版本输出为 `0.1.1-rc.1`；
- help 中存在 `--port` 和 `--no-open`；
- 未出现需要补充的 profile/web 参数格式变化。

再执行：

```powershell
npx -y @deepseek-ai/dsh@0.1.1-rc.1 --profile web --port 3091 --no-open
```

另开窗口检查：

```powershell
$r = Invoke-WebRequest -UseBasicParsing 'http://127.0.0.1:3091/'
$r.StatusCode
$r.Content.Length
Get-NetTCPConnection -State Listen -LocalPort 3091 |
    Select-Object LocalAddress,LocalPort,OwningProcess
```

期望：

- 控制台出现 `dsh web: http://127.0.0.1:3091`；
- 不自动打开系统浏览器；
- HTTP 状态为 `200`，页面标题/UI 正常；
- listener PID 可记录；
- 用启动该 DSH 的同一个窗口 `Ctrl+C` 退出后，3091 端口关闭。

退出后恢复窗口环境变量，并只删除本轮 CLI 临时目录：

```powershell
if ($null -eq $oldDshHome) { Remove-Item Env:DSH_HOME -ErrorAction SilentlyContinue }
else { $env:DSH_HOME = $oldDshHome }
Remove-Item -LiteralPath $CliHome -Recurse -Force
```

## 3. DesktopShell 正常启动（APP-01）

1. 启动候选 EXE。
2. 在设置中确认：
   - DSH Version = `0.1.1-rc.1`；
   - Runner = `npx`；
   - Profile = `web`；
   - Port 使用空闲测试端口，例如 `3091`。
3. 等待 WebView2 进入 DSH 页面。

在 `logs\desktop-shell.log` 和对应 `dsh-*.log` 中记录并确认：

```text
START phase=Backend
READY-BANNER seen
BOOT HTTP200
BOOTREADY
BACKEND ready
START complete
```

期望：

- DesktopShell 内部显示 DSH Web UI；
- 没有额外浏览器窗口被错误打开；
- 端口、listener PID、profile 与日志一致；
- WebView2 页面可正常操作。

## 4. 后端异常覆盖层修复（APP-02）

这是本次修复的核心场景。必须使用真实鼠标点击，不能只看截图或 UIA 树。

### 4.1 制造后端异常退出

1. 从宿主日志记录当前 wrapper PID 和 listener PID。
2. 只结束本轮 DesktopShell 自己启动的 wrapper PID：

```powershell
taskkill.exe /PID <本轮记录的 wrapperPid> /T /F
```

3. 等待覆盖层出现。

期望看到：

```text
DSH 后端连接已中断。
重启 DSH 后端    重新检查
```

同时确认 WebView2 页面不可被覆盖层下方的内容抢焦点。

### 4.2 点击“重启 DSH 后端”

用真实鼠标点击左侧按钮一次，等待完整事务结束。宿主日志应出现：

```text
RECOVERY begin operation=backend-restart
RESTART phase=restart.preflight
RESTART phase=restart.snapshot
RESTART phase=restart.stop-wrapper
RESTART phase=restart.wait-port-close
RESTART phase=restart.compat
RESTART phase=restart.start
RESTART phase=restart.wait-ready
RESTART phase=restart.navigate
RESTART phase=restart.complete
RECOVERY end operation=backend-restart
```

确认：

- 点击后立即有 `RECOVERY begin`，不是只获得焦点；
- 覆盖层消失；
- WebView2 恢复显示并重新导航到 DSH 页面；
- 新 wrapper/listener PID 与旧 PID 不同；
- 新端口 HTTP 200；
- 没有第二个 listener、旧进程或残留端口。

若点击后日志完全没有 `RECOVERY begin`，本项 FAIL；优先确认实际运行的是修复候选 EXE，而不是旧安装目录版本。

### 4.3 点击“重新检查”（APP-03）

重新结束当前记录的 DSH wrapper PID，等待覆盖层出现。点击“重新检查”：

- 后端仍停止时，覆盖层保持显示；
- 不应出现 `RESTART phase=`；
- 恢复后再次点击“重新检查”，健康检查通过，覆盖层消失；
- 不得启动重复 DSH。

## 5. 正常重启、托盘和完全退出

### 5.1 正常重启（APP-04）

1. DSH 页面正常显示时，通过托盘菜单选择“重启 DSH 后端”。
2. 连续完成至少 3 次；每次等页面恢复后再开始下一次。
3. 记录每次 old/new wrapper PID、listener PID、端口和完整重启阶段。

期望：每次只有一代 backend 处于运行状态，页面最终恢复，日志没有假“后端中断”。

### 5.2 托盘隐藏和恢复（APP-05）

至少执行 3 轮：

1. 关闭窗口，选择“关闭到托盘”；
2. 确认主窗口和任务栏图标隐藏，但 DSH listener 仍在；
3. 双击托盘图标恢复；
4. 确认同一页面、同一 backend、同一端口继续工作。

日志应有：

```text
TRAY hide
TRAY restore
```

不要出现第二个 MainForm、第二个 WebView2 或第二个 DSH listener。

### 5.3 完全退出（APP-06）

通过托盘“退出 DeepSeek Harness”，不要只关闭到托盘。退出后执行：

```powershell
Get-Process -Name DeepSeekHarness -ErrorAction SilentlyContinue
Get-NetTCPConnection -State Listen -LocalPort <测试端口> -ErrorAction SilentlyContinue
```

期望两条命令都没有本轮对象。若仍有进程，只能根据本轮日志记录的精确 PID 清理，并记录原因；不得按进程名批量结束。

## 6. 外部 rc1 附着且不误杀（ATTACH-01）

1. 先确保测试端口为空，例如 `3093`。
2. 在第二个 PowerShell 窗口、临时 DSH_HOME 中启动外部 rc1：

```powershell
$ExternalHome = Join-Path $env:TEMP ('dsh-rc1-external-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $ExternalHome | Out-Null
$env:DSH_HOME = $ExternalHome
npx -y @deepseek-ai/dsh@0.1.1-rc.1 --profile web --port 3093 --no-open
```

3. 记录外部 DSH 的 PID 和 HTTP 200。
4. 打开 DesktopShell，把端口改为 `3093`、版本设为 `0.1.1-rc.1`，启动。

期望：

- DesktopShell 能附着现有 DSH；
- 日志出现 `identity=verified-dsh` 或等价的已验证外部身份；
- 不启动第二个 DSH；
- DesktopShell 退出后，外部 DSH 仍存活、3093 仍返回 HTTP 200；
- DesktopShell 不误杀外部 rc1。

测试完成后，在启动外部 DSH 的窗口按 `Ctrl+C`，确认 3093 关闭。

## 7. Foreign 端口拒绝（FOREIGN-01）

1. 选择空闲端口，例如 `3094`。
2. 在第二个 PowerShell 窗口启动一个非 DSH 的 TCP listener：

```powershell
$foreignListener = [System.Net.Sockets.TcpListener]::new(
    [System.Net.IPAddress]::Loopback, 3094)
$foreignListener.Start()
Write-Host "Foreign listener started; close this PowerShell window or press Ctrl+C to stop."
while ($true) { Start-Sleep -Seconds 1 }
```

3. DesktopShell 设置端口为 `3094` 后启动。

期望：

- DesktopShell 拒绝把该进程当成 DSH；
- 日志可见 `identity=foreign` 或明确的“监听进程不像 DSH”错误；
- 不启动新的 DSH；
- 不结束 Foreign listener；
- 端口 `3094` 在 DesktopShell 退出后仍由该 PowerShell listener 占用。

测试结束时只关闭启动该 listener 的 PowerShell 窗口，并再次确认 3094 关闭。

## 8. OAuth / WebView2（OAUTH-01）

本项使用真实用户 Profile，由用户手动输入凭据；不要让自动化工具输入 API Key、密码或 OTP。

1. 正常启动 rc1 并进入 DSH 页面。
2. 手动触发一个确实需要浏览器授权的 Provider 流程。
3. 观察系统浏览器和 DesktopShell：
   - 外部 `https` 授权页交给系统浏览器打开；
   - DesktopShell 内部仍停留在 DSH 页面，不被外部授权页替换；
   - 授权完成后回环地址导航返回正常；
   - DesktopShell 页面不白屏、不跳到外部站点、不丢失 WebView2 控制。
4. 记录授权前后的页面标题、时间和宿主日志；不要记录完整授权 URL 或令牌。

## 9. 插件 rc1 preflight（PLUG-01）

使用已审核的具体插件版本或 spec；禁止把插件批量改成 `latest`。每个插件单独运行，命令统一指定 rc1：

```powershell
$PluginSpecs = @(
    'dshmarket@1.17.1',
    'dsh-better-sidebar@^0.14.0',
    '@michengai/dsh-skills-manager@0.1.23',
    'github:omdsh-dev/dsh-at-file',
    'github:XSJUSTC/dsh-rewind',
    'git+https://github.com/a903067276-rgb/dsh-file-mentions.git',
    'github:a179-sanae/dsh-auto-collapse',
    'dsh-chat-tidy@^0.2.0',
    'github:EnkiduGilgamesh/dsh-codex-side-outline',
    'git+https://github.com/huahai0202/dsh-better-archive.git',
    'dsh-video-preview@^0.1.1',
    'github:yq04/dsh-git-remotes',
    'git+https://github.com/omdsh-dev/dsh-notification.git',
    'github:omdsh-dev/dsh-open-in-vscode',
    'github:ChenRuoT/dsh-sidebar-qa',
    '@huanlin/dsh-plugin-better-sidebar-plugin-office@^0.1.0',
    '@tt-a1i/archify-dsh@^0.1.0',
    '@nanmicoder/dsh-auto-mode@^0.1.4',
    'dsh-cost-meter@^1.5.35',
    'dsh-dream-skin@^0.4.5',
    'dsh-sentinel@0.11.0',
    '@linxin666/dsh-liangshen@^0.2.7',
    '@dsh-plugin/dsh-thought-buddy@^0.2.0'
)

foreach ($plugin in $PluginSpecs) {
    Write-Host "===== PREFLIGHT $plugin ====="
    & .\scripts\Test-PluginBootPreflight.ps1 `
        -PluginSpec $plugin `
        -DshVersion '0.1.1-rc.1' `
        -StableSeconds 10
    if ($LASTEXITCODE -ne 0) {
        Write-Host "FAILED: $plugin"
    }
}
```

本机 `web` Profile 另外存在 `@yuxianglin/dsh-bridge-browser` 的
`link:C:/Users/metahumanz/.dsh/dsh-browser/...` 本地依赖；它不是可移植安装 spec，
不纳入隔离 preflight，需在本机 OAuth/浏览器桥接手动项中验证。

本机当前未安装、因此不列入本轮真实环境清单的历史项：`dsh-model-picker`、`modlens`、
`dsh-status-rotator`。不要把它们的缺席写成 rc1 兼容失败。

本机真实环境的自动结果（2026-08-21）：以上 23 个可移植 spec 均为 `PASS`；每项均完成
安装、Web ready、HTTP 200、稳定 10 秒、正常退出和随机端口/测试进程清理。该结果不覆盖
本地 `link:` 的 `@yuxianglin/dsh-bridge-browser`，也不替代 OAuth 的人工验证。

每个插件必须满足：

```text
安装成功 → DSH 启动 → HTTP 200 → 稳定 10 秒
→ 正常退出 → 测试端口关闭、测试进程无残留
```

插件失败时记录：插件 spec、安装输出、启动阶段、DSH stdout/stderr、端口/PID、是否只有插件自身失败。不要为了插件修改 DesktopShell runtime；只有确认已审核插件版本失效时，才单独升级该插件并记录版本变化。

## 10. PowerShell 回归和候选包（REG-01/02、REL-01）

这部分不是 GUI 的替代品，但属于认证完成前的工程门禁。

PowerShell 7：

```powershell
$PSVersionTable.PSVersion
pwsh -NoProfile -File .\tests\verify.ps1
```

Windows PowerShell 5.1：

```powershell
powershell.exe -NoProfile -File .\tests\verify.ps1
```

两次都必须包含并通过：

```text
test-dsh-version
test-launch-args
test-accepted-dsh
test-startup-identity
test-restart-state
test-backend-lifecycle-state
test-backend-generation-race
test-backend-exit-diagnostics
test-bounded-process-probe
test-build-x64
test-dsh-rc1-certification
```

构建 v1.0.5 候选包：

```powershell
.\scripts\Build-Release.ps1 -Version 1.0.5
```

检查：

- EXE FileVersion/ProductVersion 为 `1.0.5`；
- 仅 x64 构建成功；
- 包内 `COMPATIBILITY.json` 含 rc1，default/minimum 仍为 rc.7；
- 包内 `version.txt` 为 `1.0.5`；
- 从解压后的候选包启动一次，能完成 BootReady 和 WebView2 导航；
- 不创建 tag，不发布 Release。

## 11. 每轮清理和最终通过标准

每轮结束：

1. 正常退出 DesktopShell；
2. 关闭本轮外部 DSH 或 Foreign listener；
3. 用本轮日志中的精确 PID 检查并清理异常残留；
4. 检查测试端口没有 listener；
5. 仅删除本轮创建的临时目录；
6. 保存 `desktop-shell.log`、对应 `dsh-*.log` 和测试输出。

最终认证只能在以下条件全部满足后标记 PASS：

- CLI-01 通过；
- APP-01 至 APP-06 通过，尤其是覆盖层按钮真正进入 `RESTART` 事务；
- ATTACH-01 和 FOREIGN-01 通过且没有误杀；
- OAUTH-01 由用户实际完成并记录；
- 重点插件结果逐项记录，失败项已明确归因；
- PowerShell 7 和 5.1 回归全部通过；
- v1.0.5 x64 候选包检查通过；
- 最终没有 DesktopShell、DSH listener、测试 wrapper 或测试端口残留。

最终汇报至少包含：修改文件、CLI 结果、启动/重启/托盘/退出结果、覆盖层修复结果、OAuth 结果、插件结果、失败原因、PS7/PS5.1 结果、候选包结果、仍存在的问题，以及是否建议未来把 default 切换到 rc1。
