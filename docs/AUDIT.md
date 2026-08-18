# 功能审计与边界检查报告

- 审计日期：2026-08-19
- 审计范围：仓库全部源码与脚本（v1.0.0）
- 审计方法：静态代码审查 + PowerShell 语言解析器校验 + `csc.exe` 实际编译验证

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
| DSH 版本串 | 字符白名单 `[A-Za-z0-9._+-]`，非法回退默认 `0.1.0-rc.7`（PS + C# 双端） | ✅ 防命令行注入 |
| Profile 名 | 白名单 `[A-Za-z0-9_-]`，非法回退 `web`（PS + C# 双端） | ✅ 防路径穿越 |
| 窗口尺寸 | 800–10000 × 600–10000 钳制（本次审计补上限） | ✅ |
| 工作目录 | 空回退用户主目录；不存在时安装向导询问创建 | ✅ |

### 2.2 路径边界

- DesktopShell 程序目录与 `~/.dsh` 用户数据目录严格分离；安装器不再向 `~/.dsh/desktop` 之外写入
- 旧版 `~/.dsh/runtime` 私有运行时：识别 `package.json` 名称特征后才删除，不盲删
- 卸载守卫（本次审计新增）：`DSH_HOME` 为空、等于用户主目录、等于盘符根、等于/包含桌面壳目录时拒绝删除
- 日志目录只写 `dsh-*.log` 且轮转（最新 40 个、30 天内）

### 2.3 进程与端口边界

- 端口被占用时先取 PID，读取命令行确认像 DSH（`@deepseek-ai`+`dsh`+`web` 特征）才附着/结束；**无法确认身份一律拒绝**，并提示用户
- 自家启动的后端挂 Job Object（`KILL_ON_JOB_CLOSE`），桌面壳退出即回收，不留孤儿进程
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

发布链实测：`Build-Release.ps1` 构建 zip（13 文件自校验 + SHA256）→ `Install-FromGitHub.ps1 -ZipPath` 端到端安装（复制校验、install-state.json、settings 迁移、向导/启动/快捷方式开关）全部通过，且未误杀任何进程。

## 5. 遗留观察项（未修改，文档化）

1. `Manage-Dsh.ps1` 插件目录为静态 19 项清单，版本规格硬编码（如 `@michengai/dsh-skills-manager@0.1.23`），上游发版需人工更新。
2. `PluginCompat` 直接改写 `node_modules` 内的插件文件——已用标记 + 幂等 + 原子写 + 备份清理降低风险，但仍依赖插件内部结构字符串特征（上游改动可能导致"无法识别，跳过"，不会误改）。
3. `FindListeningPid` 依赖 `netstat` 输出格式；IPv6 `[::1]` 行已兼容，极端本地化系统差异未覆盖。
4. 卸载器 GUI 依赖 Windows Forms，在 PowerShell 5.1 下同样可用（未做强制 PS7 校验，属有意兼容）。
5. 双倍计价防护依赖 cost-meter 的 `llm/stream`/`request/header` 内部结构锚点；cost-meter 或 modlens 大版本升级后需重新验证（compat 日志会记录"left untouched"）。
6. 会话日志本身仍保留 ModLens 合成 usage 事件（属宿主记录，不影响计价）；若用户手工重置/删除账本，backfill 已不会回填合成条目，但首次启动的自动清理仍以"map 非空即跳过"为幂等前提。
