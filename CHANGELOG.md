# Changelog

本项目的用户可见变更记录。安全边界与修复细节见 [docs/AUDIT.md](docs/AUDIT.md)。
> **v1.0.0 已冻结（2026-08-19）**：不再以同 tag 覆盖发布；后续修复将发布 v1.0.1
> （Release 工作流已移除"删除已有 Release"步骤，重复发布同一 tag 会失败，属有意行为）。




## v1.0.0 修订四（同 tag 覆盖发布，2026-08-19）

第七轮审计修复（含启动阻断 bug）：

- **修复启动命令非法拼接**：`--profile X` 后多余 `web` 子命令会被 DSH `rejectParentOptions('web')`
  拒绝（"web takes none of parent --profile ..."），导致壳无法启动任何 DSH——已改为统一
  `--profile <profile> --port N` 形式；新增 `tests/test-launch-args.ps1`（源码守卫 + 真实 CLI 探测）
- **每次启动前重新验证现有 dsh 版本**：settings 记录 `acceptedDshCommandPath/Version`，
  C# 启动与 PS 插件操作前重新读 `dsh --version`，变化/无法读取时询问并更新记录
- **DSH_HOME 漂移确认**：卸载时若当前环境 DSH_HOME ≠ install-state 记录值，交互列出两个路径
  让用户选择删除哪一个（无人值守拒绝猜测，降级为仅卸载壳）
- **移除常驻 DSH 进程的 Git rewrite**：GIT_CONFIG_* 环境变量不再注入 DSH 进程树
  （避免 Agent/终端执行 git@github.com:... 时被强制改 https）；git+ssh→https 降级仅保留在
  插件安装事务的进程内作用域
- **源码安装器复用发布安装核心**：编译到临时 stage → 组装与 Release 相同的 app 目录 →
  调用 Install-Release.ps1；目录所有权/事务提交/升级回滚/DSH_HOME 迁移检测只有一份实现
- **卸载多 DSH 实例 + partial 状态**：完整卸载前枚举其它 DSH Web 进程并停止；DSH_HOME
  删除失败时结果状态改为 partial（不再宣称完整卸载成功）
- **健康检查改用原生 TCP 表**：P/Invoke GetExtendedTcpTable 直接拿端口 owner PID
  （不拉 netstat），owner PID 变化才做 CIM 验证，取消 30 秒时间窗
- **版本单一来源**：根目录 VERSION + COMPATIBILITY.json（verifiedDshVersion）随包分发；
  EXE VersionInfo、manifest assemblyIdentity、管理器标题/基线全部同步读取
- **Release 工作流**：拆分为只读 build job + 仅 contents:write 的 publish job；补 PowerShell
  5.1 门禁；RC 版本自动 prerelease + 非 latest；Actions 钉 commit SHA；PSScriptAnalyzer 钉 1.25.0
- **自定义插件入口**：管理菜单新增"5. 安装自定义 package/spec"（不要求先选内置插件）
- Cost Meter 日志单位 CNY → USD（dsh-cost-meter 1.5.10 字段为美元）
- 根目录 install.bat 拆分为 install-latest.bat / install-from-source.bat；README 加"非官方项目"声明

## v1.0.0 修订三（同 tag 覆盖发布，2026-08-19）

第六轮审计（6-10 项 + 小清理）修复：

- **DSH_HOME 迁移检测**：升级时检测 `priorState.dshHome` 与当前 DSH_HOME 不一致，按迁移事件处理——告警并重新计算 `dshHomeExistedBeforeInstall`/`webProfileExistedBeforeInstall`/`firstInstalledAt`（交互模式要求确认，非交互告警后重算），不再新路径配旧历史
- **升级先停旧壳再复制动态数据**：`webview2-data`/`logs` 在 `Stop-DesktopShellProcess` 之后携带，避免 WebView2 数据库/缓存锁文件与不一致快照
- **Cost Meter 账本修复改为重新汇总**：删除合成桶后从剩余合法 `byProviderModel` 重新计算 day/session totals（PS 与 C# 双端一致），旧账本本身已不一致时也能归一化，不再"总计减桶"出负值
- **新 Profile 默认不装社区插件**：默认选项 0（纯 DSH），按一路 Enter 不执行第三方代码；核心推荐仍需主动按 1
- **SHA256SUMS 校验收紧**：要求文件名 + hash 同时匹配，不允许退化为任意条目匹配；文案收敛为"完整性校验"（去掉残留"供应链"字样）

## v1.0.0 修订二（同 tag 覆盖发布，2026-08-19）

第五轮审计（前 5 项）修复：

- **读不到版本的现有 dsh 不再静默放行**：`--version` 失败/无输出与"版本串无法解析"同等对待，一律按未验证询问；非交互模式改用 npx rc.7（新增场景 E 回归）
- **外部已运行的 DSH 同样必须过验证基线**：`EnsureStarted` 附着前从命令行提取版本（`@deepseek-ai/dsh@x.y.z`），不是 rc.7 或读不到版本一律拒绝附着；启动时弹窗让用户选择"附着（未验证）"或"结束并重启为验证版本"
- **端口已打开时启动前兼容修复一律只读**：不再依赖第一次 PID/命令行识别成功才进 dry-run——只要端口开着绝不写插件/账本；只有端口原本为空才"补丁 → 启动自己的 DSH"
- **健康检查缓存校验原 PID 存活**：30 秒缓存只在原 PID 仍存活时复用，PID 消失立即全量复验，不再重新打开身份 TOCTOU 窗口
- **PowerShell 插件管理完全遵守 runnerMode**：新增 `Resolve-DshCommandForOps` 与 C# `EnsureStarted` 同语义（npx 绝不回捡 PATH dsh；command 找不到 dsh 直接报错；auto 才回退），并有单元断言 + 端到端场景覆盖

## v1.0.0 修订（同 tag 覆盖发布，2026-08-19）

在 v1.0.0 首次发布后的第三方审计基础上，同 tag 覆盖发布修复版：

- 支持 Windows PowerShell 5.1（脚本统一 UTF-8 BOM、去 PS7 专属编码依赖；CI 双宿主验证）
- `dshRunnerMode`（auto/command/npx）持久化，PS 与 C# 双端一致——修复“选 npx 实际仍跑 PATH 里的旧 dsh”
- DSH 兼容策略改为“已验证版本”：仅 rc.7 直接放行，更旧/更新/无法解析一律明确询问
- 外部 DSH 附着时兼容修复只做只读检测，提示“重启 DSH 后端”后完成（不再和运行中的后端抢账本）
- 完整卸载先确认并停止外部 DSH，停止失败或身份不明时降级为仅卸载壳
- 升级继承 install-state 首次安装事实（`dshHomeExistedBeforeInstall` 等）并记录 `firstInstalledAt`/`lastUpdatedAt`
- Profile 名禁止 `node_modules` 与 Windows 设备保留名（PS/C# 双端）
- 后台健康检查降频：自家后端进程存活 + TCP；外部后端 30 秒 PID 身份缓存，避免每 5 秒拉起 netstat/CIM
- CI 与 Release 共用 `tests/verify.ps1` 门禁（解析 + PSScriptAnalyzer + 五项回归测试，pwsh 与 PowerShell 5.1 双跑）
- 安装事务化：Preflight → Stage → Initialize → Commit；升级保留 `DeepSeekHarness.exe.previous` 以便回滚；源码安装器改为先编译后向导
- 开始菜单只管理自有三个快捷方式，不再整目录删除
- 未知 pnpm store 版本 fail closed（不再静默退回 pnpm 10）
- Release 工作流支持同 tag 覆盖发布（先删除旧 Release 再重建）

## v1.0.0（2026-08-19）

首个公开发布。当前基线：DesktopShell v1.0.0 · DSH 0.1.0-rc.7 · Windows 10/11 x64。

### 桌面壳

- WinForms + WebView2 原生窗口：深浅色、PerMonitorV2 DPI、多屏窗口位置恢复、托盘、原生右键菜单、单实例
- DSH 进程托管（Job Object 回收）、日志轮转（40 个 / 30 天）、崩溃与 WebView2 异常恢复
- 端口可信性：TCP 可连 + 监听 PID + 命令行三重核验；非 DSH 进程拒绝附着/结束
- 外链 http/https 白名单；回环导航白名单；DevTools 默认关闭
- 兼容修复（Sentinel client-id、Cost Meter × ModLens 双倍计价去重）在每次 DSH 启动前自动执行（幂等、带备份原子写入）

### 安装与卸载

- 一键安装（强制校验同源 SHA256SUMS）、发布包安装、源码安装三种方式
- 安装目录所有权标记（`.dsh-desktop-shell-root`）；盘符根/主目录/系统目录/非空共享目录拒绝安装
- 卸载前多次验证所有权；DSH_HOME 危险路径双向守卫，命中即降级为仅卸载壳
- WebView2 Runtime 安装期预检；`-NoWizard` 无人值守语义统一（仍执行非交互初始化，缺 Node 即中止）
- 现有 DSH 低于 rc.7 验证基线时询问是否改用官方 npx，不静默接管

### 插件

- 19 个社区插件三层分层：核心推荐（5）/ 体验增强（6）/ 高级实验（8），全部锁定精确版本或 commit
- 推荐组合不再追 `latest`/`main`；追新版本走"额外插件"自定义 spec
- 插件安装完成后提示"托盘 → 重启 DSH 后端"

### 工程化

- CI：PowerShell 解析、PSScriptAnalyzer、安装所有权/卸载守卫/账本正则/版本门槛回归测试、C# 发布构建
- GitHub Release 工作流：输入版本或推 `v*` tag 自动构建并上传 zip + SHA256SUMS.txt
- WebView2 三件套固定 1.0.4078.44 单源构建；`-Version` 同步 EXE 版本元数据；`-Arch` 目标架构（首发 x64）
- LICENSE（MIT）、THIRD_PARTY_NOTICES.md、安全审计记录
