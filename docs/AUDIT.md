# 功能审计与边界检查报告

- 审计日期：2026-08-20
- 审计范围：仓库全部源码与脚本（v1.0.4 运行期生命周期修复工作树；v1.0.3 已发布并冻结）
- 审计方法：静态代码审查 + PowerShell 语言解析器校验 + `csc.exe` 实际编译验证

## 0. 当前真实状态（v1.0.4，未发布）

本轮从 `main` 的 `509122e` 创建 `fix/v1.0.4-runtime-lifecycle`，不移动、不删除、
不覆盖 v1.0.3 的 tag/Release，也不提前创建 v1.0.4 tag。DSH 默认版本、`COMPATIBILITY.json`
和 v1.0.3 的推荐插件集合保持不变；Dream Skin 仍为 npm `^0.4.1`。

当前收口内容：

- 托盘 hide/restore 不再运行期切换 MainForm 的 `ShowInTaskbar`；Form、WebView2、backend
  复用同一实例，并记录 `HANDLE created/destroyed instance=<guid>` 诊断；托盘双击在显示/隐藏
  间切换，恢复时使用轻量淡入动效。
- 真实退出统一取消 lifetime；startup/restart/health/retry 在 await 后检查取消，取消后
  清理本轮启动的 wrapper/listener；关闭到托盘不取消。
- WebView2、overlay configure、backend start/restart 共用非阻塞恢复门禁；持续
  `Unresponsive` 才显示显式重建入口，重建不触碰健康 backend。
- 版本、netstat、CIM、CLI 能力探测统一走有界进程执行器：启动即异步读取 stdout/stderr，
  超时按 PID 回收进程树；自有 backend 健康检查还要验证当前监听 PID 等于 owned listener
  或属于本壳 Job。
- `persistedSettings` 与 `activeRuntimeSettings` 分离；保存后选择稍后重启时，健康检查与
  `DshHomeUrl` 继续使用当前运行快照；托盘状态下对话框使用 ownerless + CenterScreen。
- DPI 本轮只加入 100%/125%/150%/200% 的人工验收矩阵，不在没有实测错位前改 DPI 代码。

`tests/verify.ps1` 当前列出 29 个回归脚本，并由 PowerShell 7 与 Windows PowerShell 5.1
双宿主执行；托盘/WebView2/连续重启/DPI/Dream Skin 仍需真实 Windows 验收。发布包文件数不在
文档中另行维护：以 `scripts/Build-Release.ps1` 内的 authoritative expected-file 自校验为准，
当前构建清单实际为 15 个文件。

## 1. 模块功能清单

| 模块 | 位置 | 职责 |
| --- | --- | --- |
| `AppSettings` | `src/DeepSeekHarness.cs` L24-180 | 设置加载/保存；输入钳制；旧版窗口位置迁移；原子写入 |
| `ThemeHelper` | L182-351 | 深浅色检测（注册表）、PerMonitorV2 DPI、窗口/控件主题 |
| `PluginCompat` | L384-579 | Sentinel client-id 修复、Cost Meter×ModLens 去重；幂等 + 标记 + 原子写 |
| `DshProcessManager` | L581-1071 | 后端进程托管：端口探测、PID 身份核验、Job Object 回收、日志轮转、重启 |
| `SettingsForm` / `CloseChoiceDialog` / `ThemedMessageBox` | L1073-1495 | 设置对话框、关闭行为对话框、主题化消息框 |
| `MainForm` | L1497-2550 | WebView2 承载、导航守卫、权限、右键菜单、快捷键守卫、健康检查、托盘、窗口位置恢复 |
| `Program` | L2552-2588 | 单实例互斥体 + 激活已有窗口 |
| `Install-Desktop.ps1` | `scripts/` | 安装：文件分发、WebView2 SDK 获取、csc 编译、开始菜单、旧版清理 |
| `Manage-Dsh.ps1` | `scripts/` | 初始化向导 + 交互管理：Node 检查、dsh/npx 解析、插件安装、pnpm 版本匹配、诊断 |
| `Uninstall-DesktopShell.ps1` | `scripts/` | 卸载模式选择（完整/仅壳）、预装 DSH_HOME 警告、延迟自删除 |

## 2. 边界检查结论

### 2.1 输入校验

| 输入 | 校验 | 结论 |
| --- | --- | --- |
| Web 端口 | 1–65535（PS 两处、C# Load、NumericUpDown 四处一致） | ✅ 一致 |
| DSH 版本串 | 字符白名单 `[A-Za-z0-9._+-]`，非法/缺失回退默认 `0.1.0-rc.7`（PS + C# 双端） | ✅ 防命令行注入 |
| Profile 名 | 白名单 `[A-Za-z0-9_-]`，非法回退 `web`（PS + C# 双端） | ✅ 防路径穿越 |
| 窗口尺寸 | 800–10000 × 600–10000 钳制（本次审计补上限） | ✅ |
| 工作目录 | 空回退用户主目录；不存在时安装向导询问创建 | ✅ |

### 2.1.1 DSH 兼容策略（v1.0.2 起，v1.0.4 沿用）

- `COMPATIBILITY.json` 使用 schemaVersion 2：
  `defaultDshVersion=0.1.0-rc.7`、`minimumCompatibleDshVersion=0.1.0-rc.7`、
  `testedDshVersions=[0.1.0-rc.7, 0.1.0-rc.8]`；默认暂回退 rc.7。rc.8 已在 Windows 11 +
  Node 24.14 完成实际 CLI/Web 验证；fresh npx 深层 dependency/peer resolution 可能长时间
  卡住（dsh-agent-loop 包存在，不是上游缺包），因此默认 rc.7 是安装可靠性决策而非运行时
  不兼容
- `defaultDshVersion` 只用于新设置/缺失/无效值；已有用户配置的 `dshVersion=rc.7` 不会被重写
- `minimumCompatibleDshVersion` 是“过旧不应继续尝试”的下限：rc.6 及以下走安全处理
- `testedDshVersions` 只用于日志/提示，不是未来版本硬白名单；rc.9/后续正式版只要不低于
  最低版本就允许尝试，按实际 CLI 能力适配
- CLI 能力检测：rc.8 已确认支持 `--no-open`，直接命中缓存；其它 runner 才对
  `--profile <profile> --help` 做探测。探测统一使用 `RunCapturedProcessBounded`，启动后立即异步
  读取 stdout/stderr，超时回收本次进程树，失败保守不加；npx 与 command 共用
  `BuildWebLaunchArguments`
- 推荐插件选择性 pin：已确认兼容的新版使用 npm range 或 GitHub release tag；对 DesktopShell
  有兼容修复依赖的插件保持已审核版本；未验证新版不升级

### 2.2 路径边界

- DesktopShell 程序目录与 `~/.dsh` 用户数据目录严格分离；安装器不再向 `~/.dsh/desktop` 之外写入
- 旧版 `~/.dsh/runtime` 私有运行时：识别 `package.json` 名称特征后才删除，不盲删
- 卸载守卫（本次审计新增）：`DSH_HOME` 为空、等于用户主目录、等于盘符根、等于/包含桌面壳目录时拒绝删除
- 日志目录只写 `dsh-*.log` 且轮转（最新 40 个、30 天内）

### 2.3 进程与端口边界

- 端口被占用时先取 PID，读取命令行确认像 DSH（`@deepseek-ai`+`dsh`+`web` 特征）才附着/结束；**无法确认身份一律拒绝**，并提示用户
- 自家启动的后端挂 Job Object（`KILL_ON_JOB_CLOSE`），桌面壳退出即回收，不留孤儿进程；
  启动/重启/重试均受 lifetime cancellation 约束，取消发生在 spawn 后也进入清理路径
- 等待 Web 就绪上限 120 秒，重启释放端口上限 10 秒，超时给日志路径
- 单实例：`Local\DeepSeekHarnessDesktop` 互斥体，重复启动 PostMessage 激活旧窗口

### 2.4 网络安全边界

- 主导航白名单：仅 `http://127.0.0.1|localhost|::1` 且端口精确匹配；`about:blank` 放行；其余一律取消并转外部浏览器
- 外部打开时拦截 `javascript:` / `data:` / `blob:` / `about:` 协议
- 通知权限只对 DSH 回环源自动授予
- 快捷键守卫：非开发者模式屏蔽 F12 / Ctrl+Shift+I/J/C；Ctrl+P 始终屏蔽；保留 Ctrl+F、缩放等

### 2.5 卸载安全

- 安装时记录 `dshHomeExistedBeforeInstall`，卸载时据此显式警告"这份 DSH_HOME 在安装前已存在"
- 完整卸载二次确认；`-Force -Full` 无人值守路径跳过 GUI
- 卸载器自删除通过临时脚本延迟 2 秒执行，路径做单引号转义
- 删除 DSH_HOME 失败（本次审计改为）不再中断桌面壳卸载，弹窗警告后继续

### 2.6 异常与失败路径

- PowerShell 三脚本统一 `$ErrorActionPreference='Stop'` + 顶层 try/catch → 退出码 1
- 安装器向导失败（本次审计新增）通过 `$LASTEXITCODE` 传播并中止安装
- WebView2 SDK 临时目录（本次审计新增）try/finally 清理，失败不残留
- 复制文件后（本次审计新增）校验目标齐全，缺失即中止
- 兼容修复绝不让桌面壳启动失败：`PluginCompat.ApplyAll` 全程吞异常并写日志

## 3. 发现并修复的问题

| 级别 | 问题 | 修复 |
| --- | --- | --- |
| **P0** | `Uninstall-DesktopShell.ps1` L58 字符串内含 U+201C/U+201D 弯引号，PowerShell 解析器将其视为字符串定界符，**整个卸载脚本解析失败、无法运行** | 弯引号改为「」角引号（`scripts/Uninstall-DesktopShell.ps1`） |
| P1 | 安装向导 `& $manager` 失败后安装器仍继续"安装完成" | 检查 `$LASTEXITCODE`，非 0 即中止；`Manage-Dsh.ps1` 成功路径显式 `exit 0`，避免残留内部命令退出码造成误判（`scripts/Install-Desktop.ps1`、`scripts/Manage-Dsh.ps1`） |
| P1 | 完整卸载把 `DSH_HOME` 当普通路径删除，若配置异常（=主目录/盘符根）后果严重 | 增加路径安全守卫 + 弹窗降级为仅卸载壳（`scripts/Uninstall-DesktopShell.ps1`） |
| P1 | 删除 DSH_HOME 失败时 EAP=Stop 使整个卸载器静默中止 | try/catch 弹窗警告后继续卸载桌面壳 |
| P2 | SDK 下载/解压失败残留 `%TEMP%\webview2-sdk-*` | try/finally 清理（`scripts/Install-Desktop.ps1`） |
| P2 | 文件复制静默失败，后续编译报错难定位 | 复制后校验 8 个目标文件，缺失即报错 |
| P2 | `settings.json` 窗口尺寸无上限，损坏 JSON 可携带超大值 | Load 时钳制 800–10000 / 600–10000（`src/DeepSeekHarness.cs`） |
| P2 | `$env:LOCALAPPDATA` 未设时安装路径报错 | 回退 `[Environment]::GetFolderPath('LocalApplicationData')` |
| **P0** | 安装/卸载脚本按**进程名** `DeepSeekHarness` 全杀旧实例——DSH 宿主本身（`~/.dsh/desktop\DeepSeekHarness.exe`）同名，实测两次把承载自身的宿主进程杀掉 | 改为 `Stop-DesktopShellProcess`：按 **exe 完整路径精确匹配**（`MainModule.FileName`）才关闭；路径读不到/不匹配一律不碰；旧版目录清理不再主动杀任何进程，删除失败仅警告跳过（三个脚本同步修复） |
| **P1** | Cost Meter × ModLens 双倍计价"复发"根因链：① index.js 守卫只拦**新增**记账，历史入账不清理；② cost-meter 的 `backfill.js` 启动回填会从**会话日志**重建 byProviderModel，而日志里保留全部 ModLens 合成 usage（实测今天 187 次/昨天 217 次）——账本一旦有空 map 即被回填复现；③ 运行中后端内存持有旧账本，关停 flush 会覆盖磁盘清理 | 三层修复（`src/DeepSeekHarness.cs` PluginCompat + `scripts/Repair-CostMeterLedger.ps1`）：a) 启动时自动清理账本中 `deepseek-modlens:*`/`modlens-*:*` 桶并扣减日/会话合计（自动备份、原子写）；b) 给 `backfill.js` 打幂等守卫，重放跳过 ModLens provider（锚点 + 标记，识别失败即跳过不改）；c) 保留 index.js 记账守卫。已对真实账本执行清理（备份 `ledger.json.before-modlens-clean-*.bak`） |

## 4. 编译验证

用与安装器完全一致的参数实编译（`csc.exe` 4.8.9232.0，winexe/anycpu/optimize+，WebView2 SDK 1.0.4078.44）：

```
csc exit: 0 → DeepSeekHarness.exe 生成成功
```

PowerShell 脚本经 `[Parser]::ParseFile` 校验：**全部通过**（修复前 `Uninstall-DesktopShell.ps1` 存在 P0 解析错误）。

发布链实测：`Build-Release.ps1` 构建 zip（当前清单 15 文件自校验 + SHA256）→ `Install-FromGitHub.ps1 -ZipPath` 端到端安装（复制校验、install-state.json、settings 迁移、向导/启动/快捷方式开关）全部通过，且未误杀任何进程。

## 5. 遗留观察项（未修改，文档化）

1. `Manage-Dsh.ps1` 插件目录为静态 19 项清单，版本规格硬编码（如 `@michengai/dsh-skills-manager@0.1.23`），上游发版需人工更新。
2. `PluginCompat` 直接改写 `node_modules` 内的插件文件——已用标记 + 幂等 + 原子写 + 备份清理降低风险，但仍依赖插件内部结构字符串特征（上游改动可能导致"无法识别，跳过"，不会误改）。
3. `FindListeningPid` 优先使用 `NativeTcpTable`，仅原生 API 不可用时才走有界 netstat fallback；IPv6 `[::1]` 行已兼容，极端本地化系统差异未覆盖。
4. 卸载器 GUI 依赖 Windows Forms，在 PowerShell 5.1 下同样可用（未做强制 PS7 校验，属有意兼容）。
5. 双倍计价防护依赖 cost-meter 的 `llm/stream`/`request/header` 内部结构锚点；cost-meter 或 modlens 大版本升级后需重新验证（compat 日志会记录"left untouched"）。
6. 会话日志本身仍保留 ModLens 合成 usage 事件（属宿主记录，不影响计价）；若用户手工重置/删除账本，backfill 已不会回填合成条目，但首次启动的自动清理仍以"map 非空即跳过"为幂等前提。

## 6. 2026-08-19 第二轮修复（外部审计响应）

按外部审计的优先级结论"下一次提交先修 5 项"，本次提交完成：

| # | 级别 | 问题 | 修复 |
| --- | --- | --- | --- |
| 1 | **P0** | 自定义 `-InstallDir` 可指向任意已有目录，卸载时递归删除整个目录 | 安装目录所有权机制：安装端写入 `.dsh-desktop-shell-root` 标记；目标目录非空且不是已有 DesktopShell 安装（marker/`install-state.json` 产品字段）时拒绝安装；盘符根/用户主目录/系统目录/Program Files/AppData/临时目录/DSH_HOME 等已知大目录一律拒绝；卸载前再次验证标记，延迟自删除脚本执行前还会第三次验证（`scripts/Install-Release.ps1`、`scripts/Uninstall-DesktopShell.ps1`、`scripts/Install-Desktop.ps1`） |
| 2 | **P0** | DSH_HOME"包含桌面壳目录"的方向判断写反，父目录会通过安全守卫 | 双向检查：DSH_HOME 位于桌面壳内、桌面壳位于 DSH_HOME 内都拒绝；并扩展为 DSH_HOME 等于/包含用户主目录、系统目录、Program Files、AppData、临时目录等受保护路径时拒绝（`scripts/Uninstall-DesktopShell.ps1`） |
| 3 | P1 | `Repair-CostMeterLedger.ps1` 的 `modlens-*` 正则漏掉 `modlens-xxx:yyy` 键 | 改为与 C# 完全一致的 `StartsWith('deepseek-modlens:') -or StartsWith('modlens-')`（已用合成账本 DryRun 验证 4 类键） |
| 4 | P1 | 推荐组合 11/13 插件追 `@latest`/GitHub `main`，不可复现 | 推荐组合全部锁定精确 npm 版本或 GitHub commit（2026-08-19 快照：dshmarket@1.14.0、dsh-better-sidebar@0.13.1、dsh-chat-tidy@0.2.0、dsh-cost-meter@1.5.10、dsh-model-picker@1.0.2 + 6 个 GitHub commit 固定 tar.gz；`dsh-at-file` 在 npm 上不存在，改用其真实仓库 omdsh-dev/dsh-at-file 的 commit 固定包）。可选插件保留 `@latest`（用户主动选择）。锁定版本升级须人工审核后更新 `$PluginCatalog` |
| 5 | P1 | 一键安装下载 `latest` zip 后不校验 `SHA256SUMS` | `Install-FromGitHub.ps1` 下载同源 `SHA256SUMS.txt` 并强制校验，失败即中止；本地 `-ZipPath` 旁若有 SUMS 文件同样校验。README 引导命令钉到 `v1.0.0` tag（发布时 zip 与 SUMS 必须同时上传） |
| 6 | P1/P2 | `PluginCompat` 只在桌面壳首次启动执行；`WriteAtomic` 替换失败先删原文件 | 兼容修复改为"停止旧后端 → ApplyAll → 启动新后端"，每次启动 DSH 前（含菜单"重启 DSH 后端"）都执行；`WriteAtomic` 改用 `File.Replace` 带滚动备份参数，替换失败时绝不先删原文件（`src/DeepSeekHarness.cs`） |

另顺手修正：`-Force` 无人值守卸载路径下剩余的三处 MessageBox 改为 Write-Host（此前 `-Force` 仍会弹窗阻塞自动化）。

验证：`csc.exe` 实际编译通过；全部 PowerShell 脚本 `[Parser]::ParseFile` 通过；安装所有权 10 项、卸载守卫 3 项、哈希校验正/负向、合成账本正则测试全部通过（测试脚本在 gitignored 的 `.test-install/`）。

### 遗留（已在下一次提交全部收口，见第 7 节）

- 端口可信性 TOCTOU、外链协议白名单、DSH rc.7 最低版本门槛
- WebView2 三件套固定版本、`Build-Release -Version` 同步 EXE 版本、修复脚本入发布包
- LICENSE / THIRD_PARTY_NOTICES / CI / GitHub Release 工作流

## 7. 2026-08-19 第三轮修复（剩余审计项收口 + 发布工程化）

| # | 级别 | 问题 | 修复 |
| --- | --- | --- | --- |
| 1 | P1/P2 | 端口可信性 TOCTOU：启动等待/健康检查只做 TCP 探测 | 新增 `DshProcessManager.IsDshReady` = TCP 可连 + `FindListeningPid` + `IsLikelyDshProcess`；启动等待循环与健康检查全部改用；启动等待期间若端口被非 DSH 进程抢先占用立即报错而不是等 120 秒超时（`src/DeepSeekHarness.cs`） |
| 2 | P2 | 外链协议用危险协议黑名单 | 改为白名单：http/https/mailto 直接交给系统；file:/ms-settings:/自定义 URI handler 等先弹主题化确认框（`src/DeepSeekHarness.cs` `OpenExternalUri`） |
| 3 | P2 | "发现现有 dsh 就直接用"无 rc.7 门槛 | `Manage-Dsh.ps1` 新增 `Resolve-DshCommandWithGate`：现有 dsh 低于验证基线 0.1.0-rc.7 时询问"继续使用 / 改用 npx"，非交互模式默认改用 npx；三处解析入口（向导、菜单"检查 DSH"、Resolve-DshRunner）统一走门槛 |
| 4 | P2 | WebView2 三件套来源/版本不一致 | `Build-Release.ps1` 固定 1.0.4078.44：`-SdkDir` 覆盖（版本不符直接失败）→ 同版本 NuGet 包目录 → NuGet 下载，同一包目录取三件套；`Install-Desktop.ps1` 复用条件改为三件套 FileVersion 全部等于固定版本，否则整套重下 |
| 5 | P2 | `Build-Release -Version` 不改 EXE 版本 | 删除源码里写死的 AssemblyVersion/FileVersion，构建脚本生成 `VersionInfo.cs`（AssemblyVersion/FileVersion=四段版本，InformationalVersion=原始版本串）注入编译；构建后校验 EXE FileVersion 与版本一致 |
| 6 | P2 | `Repair-CostMeterLedger.ps1` 不在发布包 | 进入 `Build-Release.ps1` 与 `Install-Desktop.ps1` 的分发清单（zip 自校验 13→14 文件）；`Install-Release.ps1` 作为可选文件复制（旧包没有不影响安装） |
| 7 | P3 | 无 LICENSE / 第三方声明 | 新增 `LICENSE`（MIT）、`THIRD_PARTY_NOTICES.md`（DeepSeek Harness 图标 MIT 声明、WebView2 SDK 许可、运行时与社区插件说明） |
| 8 | P3 | 无 CI / 发布工作流 | `.github/workflows/ci.yml`（PS 解析 + PSScriptAnalyzer + 三项回归测试 + Build-Release + zip 内容校验 + artifacts）；`.github/workflows/release.yml`（workflow_dispatch 输版本号或推 v* tag：回归测试 → 构建 → 打 tag → 创建 GitHub Release 并上传 zip + SHA256SUMS.txt） |
| 9 | P3 | 回归测试未入库 | `tests/`：`test-install-ownership.ps1`（10 项）、`test-uninstall-guards.ps1`（3 项，自动备份/恢复开始菜单）、`test-repair-regex.ps1`（合成账本 DryRun） |

发布提醒：README 一键安装引导命令钉在 `v1.0.0` tag，远端当前还没有任何 tag/Release；
首次发布请用 `Release` 工作流（或手动打 tag 并上传 zip + `SHA256SUMS.txt` 两个资产）。

## 8. 2026-08-19 第四轮修复（第三方审计响应：发布前收口）

| # | 级别 | 问题 | 修复 |
| --- | --- | --- | --- |
| 1 | P1 | 一键安装引导与脚本互相矛盾：脚本下载到 `%TEMP%` 后无法从 git remote 推断 Owner/Repo，而 README 钉住的 `v1.0.0` tag 尚未创建 | README 命令显式传 `-Owner metahumanz -Repo DeepSeekHarness-DesktopShell -Tag v1.0.0`（发布 tag 后用 `Release` 工作流创建）；`Install-FromGitHub.ps1` 报错提示补全三参数 |
| 2 | P1 | rc.7 版本门槛用 `[version]` 强转，`0.1.0-rc.6` 等预发布 SemVer 抛异常后被当"无法判断"静默放行 | `Manage-Dsh.ps1` 实现真正的 SemVer 比较（`ConvertTo-SemVerParts` / `Compare-DshVersion`：核心三段数值 + 预发布逐标识比较，正式版 > 预发布）；无法解析的版本串按"未验证"走门槛；`tests/test-dsh-version.ps1` 用 AST 提取真实函数做回归（rc.5/rc.6 拒绝、rc.7/1.0.0 放行等 15 项断言） |
| 3 | P1 | Release 工作流默认版本 1.1.0（仓库是 1.0.0）；tag 已存在时只提示不校验 | 默认版本改 `1.0.0`；"Ensure tag"步骤校验已存在 tag 必须指向当前 HEAD，否则拒绝发布 |
| 4 | P1 | `-NoWizard` 语义不一致：源码安装器跑非交互初始化，Release 安装器直接跳过（CI 环境会出现"Release 包装好、启动才发现缺 Node"） | 统一为两者都执行 `Manage-Dsh -FirstInstall -NonInteractive`（检查 Node、解析 DSH/npx、初始化 Profile；缺 Node 即中止）；回归测试改为隔离环境（假 node/npx shim + 临时 DSH_HOME + 受限 PATH）覆盖该路径 |
| 5 | P2 | 缺少 WebView2 Runtime 时用户等到首次启动才看到"启动失败" | 两个安装器增加 Evergreen Runtime 注册表预检（EdgeUpdate Clients `{F3017226-…}`），缺失时给出官方下载入口；C# 启动失败检测 WebView2 异常并显示"下载 WebView2 Runtime"按钮（`OnOverlayOpenWebView2Download`） |
| 6 | P2 | 预编译 Release 的 `WebView2Loader.dll` 跟随构建机架构，README 只笼统写 Windows 10/11 | `Build-Release.ps1` 增加 `-Arch`（x64/arm64/x86，默认 x64）；v1.0.0 首发明确 x64（README 前置条件、Release body 注明）；ARM64 上运行 x64 发布包时安装器给出提示（模拟运行或改用源码安装） |
| 7 | P2 | 新 Profile 默认"推荐组合"一次装 13 个插件，官方/附加体验不分层；6 个可选插件仍追 `@latest`，"全部"按钮引入不可复现模式 | 插件目录改为三层：`core`（5 个默认勾选）/ `enhanced`（6 个默认展示可取消）/ `advanced`（8 个默认不装，Cost Meter 标注"统计参考，不等于官方账单"）；**全部 19 项锁定精确版本/commit**，"全部已审核插件"也只装锁定版本；追新走"额外插件"自定义 spec；安装完成后提示"托盘 → 重启 DSH 后端" |
| 8 | P3 | README 结构像维护文档，安全细节前置、普通用户路径不清晰 | README 重写为：前置条件 → 一键安装（含无人值守）→ 安装器行为 → 插件分层表 → 第一次启动/日常管理/更新插件/卸载/故障排查 → 安全设计摘要 → 源码构建/Release 流程/项目结构/第三方许可（细节链接 `docs/AUDIT.md`） |

验证：四项回归测试全部通过（版本门槛 15 断言、账本正则、安装所有权 10 项、卸载守卫 3 项）；
`csc` 编译通过；全部脚本 `[Parser]::ParseFile` 通过；`Build-Release`（x64，固定 SDK 1.0.4078.44，
EXE FileVersion 1.0.0.0）成功，zip 自校验 14 文件。

## 9. 2026-08-19 第五轮修复（第三方第二轮审计：首批 6 项 + 第二批 + PowerShell 5.1）

### 前置：支持 Windows PowerShell 5.1

| 修复 | 说明 |
| --- | --- |
| 编码 | 全部 .ps1 加 UTF-8 BOM（5.1 无 BOM 会按 ANSI 读，中文注释吞引号致解析失败）；`-Encoding utf8NoBOM` 统一改为 .NET `WriteAllText(UTF8Encoding(false))`；`[ref]` 前变量用空数组占位 |
| 入口 | `install.bat`（根目录 + 发布包模板）优先 pwsh、回退 Windows PowerShell；Install-Desktop 去掉 PS7 强制门槛，改为 >=5.1；README 前置条件更新 |
| CI | 门禁在 pwsh 与 PowerShell 5.1 双宿主各跑一遍 |

### 首批 6 项

| # | 级别 | 问题 | 修复 |
| --- | --- | --- | --- |
| 1 | P1 | "改用 npx"只把 dshPath 写空，Get-CurrentSettings 和 C# 都会重新回捡 PATH 里的旧 dsh | 新增 `dshRunnerMode`（auto/command/npx）持久化到 settings.json：PS 端 npx 模式绝不回捡 PATH；C# `EnsureStarted` 严格遵守（command 找不到 dsh 直接报错，npx 永远走 npx）；设置窗口加"DSH 运行方式"下拉；`tests/test-runner-mode.ps1` 端到端回归（rc.6/rc.8 场景断言 mode=npx 且 dshPath 为空） |
| 2 | P1 | 启动时先 ApplyAll 再探测后端，附着外部 DSH 时直接修改插件/账本（运行中后端关停会写回覆盖） | `PluginCompat.ApplyAll(…, apply)` 双模式：附着外部 DSH 时只做只读检测；有挂起项则启动完成后覆盖层提示"重启 DSH 后端"（重启路径本就是 停止→修复→启动） |
| 3 | P1 | 完整卸载不停外部 DSH 就删 DSH_HOME | 卸载器读 settings.json 端口 → TCP → netstat PID → CIM 命令行 → 特征确认是 DSH → 交互询问/-Force 直接停；停止失败或身份不明 → 降级为仅卸载壳 |
| 4 | P1 | 兼容门槛只有"最低 rc.7"，更高版本被静默信任 | 改为"已验证版本"：仅 rc.7 放行；更旧=不支持、更新=未验证、无法解析=未验证，一律明确询问/非交互改 npx（`tests/test-dsh-version.ps1` 更新为 0.2.0/1.0.0/rc.8 均 $false） |
| 5 | P1/P2 | 升级重写 dshHomeExistedBeforeInstall，历史事实漂移 | 升级读取旧 install-state 继承 `dshHomeExistedBeforeInstall`/`webProfileExistedBeforeInstall`，新增 `firstInstalledAt`/`lastUpdatedAt`（两个安装器同步） |
| 6 | P2 | Profile 可叫 node_modules；未挡 Windows 设备名 | PS/C# 双端保留名：node_modules、CON/PRN/AUX/NUL、COM1-9、LPT1-9 → 回退 web（`tests/test-runner-mode.ps1` 14 项断言） |

### 第二批

| # | 修复 |
| --- | --- |
| 健康检查 | `DshProcessManager.IsDshHealthy`：自家后端 = 进程存活 + TCP；外部后端 = TCP + 30 秒 PID 身份缓存，只有过期/端口变化才跑 netstat+CIM |
| 统一门禁 | `tests/verify.ps1`（解析 + PSScriptAnalyzer + 五项回归测试，宿主自适应）；CI 与 Release 工作流共用，不再维护两份测试列表 |
| 安装事务 | `Install-Release.ps1` 改为 Preflight（完整性/危险路径/所有权/WebView2）→ Stage（旁路目录组装+携带 settings/logs/webview2-data）→ Initialize（在 stage 上跑管理器）→ Commit（目录交换 + 保留 `DeepSeekHarness.exe.previous`，失败恢复旧目录）；`Install-Desktop.ps1` 改为先编译后向导、状态最后写 |
| 开始菜单 | 安装/卸载只管理自有三个 .lnk，不再整目录删除 |
| pnpm | `.modules.yaml` 未知 store 版本（v10/v11 之外）fail closed |
| 文档 | `THIRD_PARTY_NOTICES.md`：csc 移入"源码构建依赖"；README/CHANGELOG 收敛为"SHA256 完整性校验"措辞；Release 工作流支持同 tag 覆盖发布（先 `gh release delete` 再重建） |

### 测试安全

U3 卸载守卫测试一度按默认 3080 端口把宿主机真实 DSH 当外部后端停止（测试杀掉了测试环境自身）。
修复：测试在卸载前把临时安装的 settings.json 端口改为探测出的空闲端口（`Get-FreeTcpPort`），
测试绝不触碰宿主机真实 DSH 端口。

## 10. 2026-08-19 第六轮修复（第三方第三轮审计：优先前 5 项）

| # | 级别 | 问题 | 修复 |
| --- | --- | --- | --- |
| 1 | P1 | `dsh --version` 失败/无输出（读不到版本）时 `Resolve-DshCommandWithGate` 仍直接按 command 放行并假定 rc.7 | 空版本与"无法解析"同等对待：警告未验证 → 非交互改 npx rc.7 / 交互询问；`tests/test-runner-mode.ps1` 新增场景 E（`exit /b 1` 的 dsh shim → 断言 mode=npx 且 dshPath 空） |
| 2 | P1 | 端口上已运行的外部 DSH 绕过 rc.7 门槛与 runnerMode，直接附着 | `EnsureStarted` 附着分支先 `ExtractDshVersionFromCommandLine`（`@deepseek-ai/dsh@x.y.z` 正则），非 rc.7 或读不到版本且未经用户确认 → 拒绝附着；`ProbeExternalDsh` 一次性探测；启动时弹窗"附着（未验证）/ 结束并重启为验证版本"（是=附着，否=停止外部并走 停止→补丁→启动，取消=非破坏性附着） |
| 3 | P1 | 端口开着但 PID/命令行瞬时读取失败时 `externalDsh=false`，兼容器会写文件，随后 EnsureStarted 又拒绝附着 | 规则改为：**只要端口打开，启动前绝不写兼容补丁**（`apply = !probe.PortOpen`），不再依赖第一次 PID 识别成功 |
| 4 | P1 | 30 秒健康缓存不校验监听 PID 是否仍是 `lastExternalPid`，重新引入身份 TOCTOU | 缓存命中前先 `GetProcessById(lastExternalPid)` 检查存活；PID 消失立即作废缓存并全量复验（netstat+CIM）。彻底方案（TCP owner PID API）留待后续 |
| 5 | P2 | PowerShell `Invoke-ManagedDsh` 只看 DshPath，不遵守 runnerMode（command 模式无 dsh 时悄悄用 npx） | 新增 `Resolve-DshCommandForOps`：与 C# `EnsureStarted` 完全同语义（npx 永不回捡 PATH；command 无 dsh 直接 Fail；auto 才回退）；插件管理改用它；测试新增 6 项 AST 单元断言（含 command 无 dsh 抛 `dshRunnerMode=command`） |

### 遗留（下一轮）

- #6 `DSH_HOME` 迁移时 install-state 历史串线（应检测迁移并重新计算元数据/要求确认）
- #7 README "失败不留半安装"措辞收窄（DSH_HOME 副作用不参与回滚；源码安装器非真 stage）
- #8 升级复制 `webview2-data` 应在停旧壳之后（当前顺序可能撞锁文件）
- #9 Cost Meter 账本修复改为"从剩余合法 bucket 重新汇总"（当前减法在旧账本已不一致时可能出负值）
- #10 新 Profile 默认选项改 0（纯 DSH），核心推荐标为推荐但需主动按 1
- 小清理：Install-FromGitHub 注释/文案残留"供应链"字样；SHA256SUMS 校验要求文件名+hash 同时匹配（当前退化为任意条目匹配）；main 分支保护（GitHub 设置，非代码）

## 11. 2026-08-19 第七轮修复（审计 6-10 项 + 小清理）

| # | 级别 | 问题 | 修复 |
| --- | --- | --- | --- |
| 6 | P2 | 升级时 DSH_HOME 变化导致 install-state 历史串线（新路径配旧历史） | 两个安装器检测 `priorState.dshHome` 与当前 DSH_HOME 不一致 → 迁移事件：告警并重新计算 `dshHomeExistedBeforeInstall`/`webProfileExistedBeforeInstall`/`firstInstalledAt`；交互模式 Read-YesNo 确认（否则中止），`-NoWizard` 告警后重算 |
| 7 | P2 | README "失败不留半安装"过度承诺（DSH_HOME 副作用不参与回滚） | README 安全设计收窄为"**程序目录**事务式提交（升级保留旧 exe 回滚，失败可恢复旧安装；首次向导对 DSH_HOME 的初始化不在回滚范围）" |
| 8 | P2 | 升级先复制 webview2-data 再停旧壳，可能撞锁文件 | `Install-Release.ps1` 顺序调整：settings.json 先携带 → 停旧壳 → 再携带 logs/webview2-data |
| 9 | P2 | 账本修复"总计减合成桶"在旧账本不一致时出负值/偏差 | PS `Repair-CostMeterLedger.ps1` 与 C# `PluginCompat` 双端改为：删除合成桶 → 从剩余合法 `byProviderModel` 重新汇总 day/session totals（`RecomputeLedgerTotals`/`Set-NodeTotals`）；`tests/test-repair-regex.ps1` 新增脏账本（totals=999）写入修复断言：修复后 totals 精确等于剩余桶之和 |
| 10 | P3 | 新 Profile 默认装 5 个第三方插件 | `Select-Plugins` 默认选项改 0（纯 DSH，推荐）；核心推荐需主动按 1；README 说明 |
| 小 | P3 | SHA256SUMS 退化为任意条目匹配；文案残留"供应链" | `Confirm-ZipHash` 要求文件名+hash 同时匹配（无同名条目即中止）；`.DESCRIPTION`/报错文案收敛为"完整性校验" |

### 遗留

- 代码层面 6-10 + 小清理已全部收口；仅剩 GitHub 仓库设置（非代码）：main 分支保护 + required CI（当前 `protected:false`）、提交签名（Vigilant Mode）
- v1.1 产品化（下载管理/权限中心/自动更新/Apps & Features/代码签名/主题事件驱动/artifact attestation）不在 v1.0.0 范围

## 12. 2026-08-19 第八轮修复（第三方第四轮审计：启动阻断 bug + 审计项 1-12）

### 启动阻断级（先修）

| 问题 | 修复 |
| --- | --- |
| `--profile X web --port N` 非法拼接：`web` 子命令被 `rejectParentOptions('web')` 拒绝（"web takes none of parent --profile..."），壳启动任何 DSH 都立即失败 | 统一改为 `--profile <profile> --port N`（官方 CLI 中 `dsh web` 即 `dsh --profile web` 别名，不可叠加）；`tests/test-launch-args.ps1`：源码级守卫（禁止 `QuoteArg(profile) + " web"` 拼接）+ 真实 CLI 探测（旧形态必现 reject、新形态通过 launcher 解析），并接入 verify 门禁 |

### 审计项

| # | 级别 | 问题 | 修复 |
| --- | --- | --- | --- |
| 1 | P1 | 版本门槛只在首次安装生效；保存 dshPath 后每次启动/插件操作不再重新验证（dsh.cmd 升级成 rc.8 会被直接运行） | settings 新增 `acceptedDshCommandPath/acceptedDshCommandVersion`：C# 每次启动前（StartAsync + RestartBackendAsync）与 PS 每次插件操作前重新读 `dsh --version`，与 accepted 比对；变化/无法读取 → 询问（确认后更新记录）/ 非交互中止 |
| 2 | P1 | DSH_HOME 两个事实来源：运行期用环境变量，卸载器用 install-state 记录值，运行期漂移会导致卸载删错"旧环境" | 卸载器检测 `state.dshHome ≠ 当前环境 DSH_HOME`：交互 YesNoCancel 列出两个路径让用户选择删除哪一个；`-Force` 拒绝猜测并降级为仅卸载壳 |
| 3 | P1 | 常驻 DSH 的 GIT_CONFIG rewrite 污染整个进程树（SSH 私有仓库被强制改 https） | C# 启动 DSH 不再注入 GIT_CONFIG_*；git+ssh→https 仅保留在 `Invoke-ManagedDsh` 插件事务的进程内作用域 |
| 4 | P2 | 源码安装器是第二套安装逻辑（无目录所有权/事务保护）；且 DSH_HOME 快照在向导后才计算 | `Install-Desktop.ps1` 重写：源码编译到临时 stage → 组装与 Release 完全相同的 app 目录（含 COMPATIBILITY.json）→ 调用 `Install-Release.ps1` 核心；目录保护/升级/回滚/迁移/向导一份实现。版本元数据（EXE/VersionInfo/manifest/version.txt）统一来自根目录 VERSION |
| 5 | P2 | 30 秒健康缓存"原 PID 存活"≠"仍持有端口" | `GetExtendedTcpTable`（P/Invoke）每次廉价取端口 owner PID：owner 未变直接健康，变化才做 CIM 验证；取消时间窗；原生失败退回 netstat |
| 6 | P2 | 卸载只处理设置端口的一个 DSH；DSH_HOME 删除失败仍宣称完整卸载 | 完整卸载前枚举其它 DSH Web 进程（CIM 命令行特征）并停止；删除失败结果状态改为 `partial`（明确"部分卸载完成"） |
| 7 | P2 | 同 tag 覆盖发布使 v1.0.0 zip 可变；RC 版本被当成正式版 | 本轮之后 v1.0.0 冻结（下一次修复走 v1.0.1，另见提交 B 移除重发布删除步骤）；`softprops` 增加 `prerelease`（版本含 `-` 时 true）与 `make_latest` |
| 8 | P2 | Release 门禁缺 PowerShell 5.1 | Release build job 增加 `powershell -NoProfile -File tests/verify.ps1 -SkipAnalyzer` |
| 9 | P2 | 架构/版本元数据非单一来源（anycpu、manifest 1.0.0.0 硬编码、多处 v1.0.0 文本） | 根目录 `VERSION`（Build-Release 默认读取；Install-Desktop 源码编译读取）+ `COMPATIBILITY.json`（verifiedDshVersion，PS/C# 双端运行时读取，随包分发）；manifest assemblyIdentity 版本随构建注入 |
| 10 | P2 | "只装自定义插件"走不通（额外 spec 提示在内置安装流程之后） | 管理菜单新增"5. 安装自定义 package/spec"独立入口 |
| 11 | P2 | Cost Meter 日志单位错写 CNY | 改为 USD（dsh-cost-meter 1.5.10 字段为美元） |
| 12 | P3 | 根目录 install.bat 语义误导（装的是 latest Release 而非当前 checkout） | 拆分为 `install-latest.bat`（GitHub latest）与 `install-from-source.bat`（当前 checkout 源码安装）；README 同步并加"非官方项目"徽标 |

### 非阻断工程化（已一并收口）

Actions 全部钉 commit SHA（checkout v4.2.2 / upload-artifact v4.6.2 / download-artifact v4.2.1 / gh-release v2.2.1）；
PSScriptAnalyzer 钉 1.25.0；Release 拆分为只读 build job + 仅 contents:write 的 publish job。

## 13. 2026-08-19 v1.0.1 修复轮（第八轮修复实现，v1.0.0 冻结不动）

### 实现清单

| # | 项目 | 实现 |
| --- | --- | --- |
| 1 | 宿主日志 | `src/HostLog.cs`（`logs\desktop-shell.log`，8MB 轮转，绝不记录凭据）；MainForm 构造记录环境信息，StartAsync/RestartBackendAsync/托盘/Dispose 记录阶段与结果 |
| 2 | 错误覆盖层 | `ShowErrorOverlay`：大标题 + 可滚动详情 TextBox + 复制错误按钮，与普通覆盖层共用布局与主题（按钮统一走 `ThemeHelper.ApplyButtonTheme`） |
| 3 | 分阶段启动 + 阶段感知重试 | `StartupPhase` 八阶段；`HandleStartupError` 按失败阶段路由：CommandVerify/BackendProbe/Backend → `RestartBackendAsync`；WebViewEnvironment/WebViewInitialize → `RetryWebViewAsync`（只重建 WebView2，不碰后端）；WebViewConfigure → `RetryConfigureAsync`（配置处理器先摘除再挂接，重试不叠加）；权限/导航/未知 → `StartAsync` 整体重试（`BackendRunning` 守卫保证不误杀健康 owned 后端）；缺 WebView2 Runtime 单独给官方下载入口 |
| 4 | 托盘生命周期 | `HideToTray` + `trayTransition` + `BeginInvoke((MethodInvoker)...)` 延迟到 FormClosing 结束后隐藏；`RestoreFromTray` 复用原窗口（不重建 WebView）；Dispose 记录 hiddenToTray |
| 5 | 统一 dsh 版本重验证（PS 端） | `Test-DshNeedsReacceptance`（与 C# `ConfirmCommandVersionBeforeStart` 完全同一规则）；`Invoke-ManagedDsh` 对 command/auto 解析出的 dsh 每次插件操作前重验证，与基线一致自动接受、其它交互询问/非交互中止；`$defaultDshVersion = $VerifiedDshVersion` 单一来源 |
| 6 | 原生 TCP owner PID | `src/NativeTcpTable.cs`：dwNumEntries 表头 + 按 entryCount 行遍历 + 低 16 位字节交换 + 仅 LISTEN；`tests/test-port-owner.ps1` 编译产品同款源码做真实行为回归（owner PID == 测试进程、netstat 交叉验证、关闭端口 -1），证明原生路径真实可用而非静默退回 netstat |
| 7 | 自定义 Profile 身份 | `IsLikelyDshCommandLine`：package/path 特征 +（web 子命令或任意合法 `--profile <name>`）+ 端口；卸载器同步同语义 |
| 8 | VERSION/COMPATIBILITY 单一来源 | release.yml 新增"workflow 版本 == 根目录 VERSION"门禁（不满足直接失败），默认输入改 1.0.1；`test-launch-args.ps1` 探测版本改读 COMPATIBILITY.json，不再硬编码 |
| 9 | 仅 x64 | Build-Release `-Arch` ValidateSet 只剩 `x64`，`$ArchLoader` 固定 win-x64，移除 arm64/x86 死分支 |
| 10 | 验证门禁 6 → 11 | 新增 `test-port-owner` / `test-host-log` / `test-shell-runtime` / `test-accepted-dsh` / `test-build-x64`；pwsh 与 Windows PowerShell 5.1 双宿主全绿才允许发布 |

### 验证

- 11 项回归测试在 PowerShell 7 与 Windows PowerShell 5.1 双宿主通过（含 PSScriptAnalyzer 1.25.0）；
- csc 全量编译（DeepSeekHarness.cs + HostLog.cs + NativeTcpTable.cs）无警告；
- `tests/test-port-owner.ps1` 证明原生 TCP 解析返回真实 owner PID（与 netstat 一致）；
- Release 工作流门禁：`workflowVersion != VERSION 文件` 直接失败，防止手滑发错版本。

## 14. 2026-08-19 v1.0.2 修复轮（第九轮：重启事务与 Dream Skin，未发布）

> 目标版本 v1.0.2；v1.0.1 tag/Release 冻结不动。**发布前必须等用户本机压力测试
> （连续重启 20 次 + 午夜皮肤持久化）通过**，见 docs/DREAM_SKIN_ACCEPTANCE.md。

| # | 项目 | 实现 |
| --- | --- | --- |
| 1 | 重启有状态事务 | `RestartBackendAsync` 十阶段（preflight/snapshot/stop-wrapper/wait-port-close/stop-listener-fallback/compat/start/wait-ready/navigate/complete），`RestartPhase` 统一 ENTER/OK/FAIL；快照记录旧/新 wrapper+listener PID、ownsBackend、port |
| 2 | 旧子进程未退出路径 | `ownedListenerPid` 首次就绪时记录（`CaptureOwnedListenerPid`，含身份验证）；停止链：Job 关闭 → Kill wrapper → `WaitForExit(3000)` → `TryStopListenerFallback`（PID 与记录一致 **或** 命令行复验 DSH+profile+port 才 Kill）→ `WaitForPortClosedTwice`（连续两次确认）→ 最后才 `OwnsBackend=false` |
| 3 | 重启/健康检查竞态 | `backendGeneration`：重启开始 `healthTimer.Stop()` + 代数递增；健康检查完成后 `generation != backendGeneration` 直接丢弃结果；finally 统一 `healthFailures=0` + `healthTimer.Start()` |
| 4 | 失败分流 | `HandleRestartError` 按真实状态分 A（原后端仍健康）/ B（旧后端已停止）/ C（新后端已监听但页面失败），`webViewReady = IsDshHealthy(...)` 重算，不再笼统"重启失败" |
| 5 | Dream Skin 能力版本 | 目录 `dsh-dream-skin@0.3.0` → npm `dsh-dream-skin@^0.4.1`（已确认含 sticky restore + host-backed 持久化 marker；不再固定 commit） |
| 6 | marker 检测 | `Test-DreamSkinPersistenceFix`：`profiles\<profile>\node_modules\dsh-dream-skin\lib\client.js` 需同时含 `dsh-dream-skin: sticky skin restore` 与 `/dream-skin/api`；诊断菜单显示已修/旧实现 |
| 7 | 非破坏升级 | `Install-Plugins` 选中 dream-skin 且旧实现时：说明 → 确认 → 走 npm `dsh-dream-skin@^0.4.1`（同名包替换）；不删 webview2-data / `~\.dsh` / Profile，不改 ThemeRuntime，不注入 JS |
| 8 | 验收覆盖 | docs/DREAM_SKIN_ACCEPTANCE.md：午夜 ×（Reload 5 + 重启后端 10 + 退出重开 5 + 设置开关 5）；「默认」不被 sticky 拉回；`$DSH_HOME\dream-skin.json` 持久化检查 |
| 9 | WebView 真重建 | `ReplaceWebViewControlAsync`：Remove+Dispose 旧控件 → 新建 → 初始化/配置/权限/导航；失败不碰健康后端 |
| 10 | Release 真冻结 | publish job 发布前 `gh release view "v$version"` 已存在直接失败（"禁止覆盖，请增加版本号"）；不进入 softprops |
| 11 | 最后硬编码 | `AppSettings.Load` 缺省 `dshVersion = DshProcessManager.VerifiedDshVersion`（src 中 rc.7 仅剩 VerifiedDshVersion 的合法回退 1 处） |
| 12 | 门禁 11 → 15 | 新增 `test-restart-state`（ownedListenerPid/WaitForExit/身份兜底/generation/十阶段日志/A·B·C 分流）、`test-dream-skin-pin`（npm ^0.4.1、能力 marker 检测 + 行为矩阵）、`test-release-immutable`（gh view 门禁、无删除步骤、v1.0.0/v1.0.1/v1.0.2 tag 仍在且为祖先）、`test-version-source`（C#/PS 硬编码清零、VERSION=1.0.2 与 release.yml 默认一致） |

### 14.1 追加：启动身份状态机（用户本机暴露的"重启失败/半失败"根因）

| # | 项目 | 实现 |
| --- | --- | --- |
| 1 | 四态状态机 | `ListenerIdentity { None, Pending, OwnedJob, VerifiedDsh, Foreign }`；删除 `IsDshReady→IsReady→立即 NonDsh` 旧逻辑；PID 查不到 / 命令行读不到一律 `Pending` |
| 2 | Job 归属证明 | `IsProcessInJob` P/Invoke：监听者属于本壳 Job → `OwnedJob`（无需 CIM 字符串），直接写 ownedListenerPid |
| 3 | Foreign 宽限期 | 等待循环每 ~120ms 探测；Foreign 需同一 PID + 命令行可读 + 明确非 DSH + `foreignStable >= 4` 才拒绝；Pending 重置稳定计数 |
| 4 | unknown ≠ foreign | `ProbeListenerIdentity`：`GetProcessCommandLine()==null` → `Pending`，绝不 `Foreign` |
| 5 | 成功即确认归属 | `EnsureStarted` 返回 `BackendStartResult{WrapperPid, ListenerPid}`；成功=进程活+端口监听+归属确认+ownedListenerPid 已写入 |
| 6 | 半失败清理 | 启动抛异常（超时/真 Foreign/提前退出）→ catch 内 `StopOwnedWrapper`+`TryStopListenerFallback`+状态清零+`process.Dispose()`，再 `throw`；不留"UI 失败但 DSH 后台跑" |
| 7 | 停止前冻结身份 | 重启 snapshot 阶段先 `FreezeOwnedListener(port)`（Job 证明优先、否则命令行验证 DSH+profile+port）再关 wrapper |
| 8 | 真回归测试 | `test-startup-identity.ps1`：csc 编译产品真实源码+测试 Main；场景 A=fake dsh 晚 500ms 监听必须成功（本机 1387ms）、场景 B=harness 自身（不在 Job、命令行无 DSH 特征）占端口 → stableCount=4 后拒绝且不误杀 |
| 9 | 日志阶段错乱 | `activeRestartPhase` 由 `RestartPhase` 进入即更新，外层 catch 打印真实失败阶段 |
| 10 | 身份转换日志 | `PORT closed` / `identity=pending` / `inOwnJob=true` / `BACKEND ready wrapper=… listener=…` / `identity=foreign stableCount=1..4` |
| 11 | ready banner | `OnOutput` 匹配 `dsh web` + `127.0.0.1:<port>` → `sawReadyBanner`（辅助信号，不取代 Job/PID 检查） |
| 12 | 暂停无关压力测试 | 本轮不跑 Dream Skin/WebView/托盘压力；状态机验证后恢复（冷启动 20 / 重启 20 / 托盘 20 / 午夜皮肤 / WebView 恢复） |

### 验证

- 16 项回归测试 PowerShell 7 先行全绿（csc 编译无警告）；双宿主全量在提交前跑；
- `test-startup-identity.ps1` 实测：晚就绪 DSH 1387ms 成功（无 NonDsh 抛错）、真 Foreign
  稳定 4 次后拒绝（日志 stableCount=4）、未验证身份进程不被误杀；
- Dream Skin npm 0.4.1 已实测：`client.js` 含两个 marker（sticky restore 与 host-backed
  持久化）；旧 0.3.0 与新版版本号不同，但能力判定仍以 marker 为准；
- 托盘、WebView2、连续重启、Dream Skin 真实恢复：发布后的人工回归检查表见
  docs/DREAM_SKIN_ACCEPTANCE.md；未取得用户明确验收记录前不得声称已通过。
