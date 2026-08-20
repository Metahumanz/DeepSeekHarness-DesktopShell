# Changelog

本项目的用户可见变更记录。安全边界与修复细节见 [docs/AUDIT.md](docs/AUDIT.md)。
> **v1.0.0 已冻结（2026-08-19）**：不再以同 tag 覆盖发布；后续修复走新版本号
> （Release 工作流已移除"删除已有 Release"步骤，重复发布同一 tag 会失败，属有意行为）。

## v1.0.2（第九轮修复：重启事务与 Dream Skin，2026-08-19）

> **已发布**：最终发布基线为 `34deef4`。历史上曾覆盖重建 v1.0.2，自此 v1.0.2 冻结，不再覆盖。
> 本版不修改 v1.0.1 tag / Release；也不删除 `~\.dsh`、不清 WebView2 数据、不重装 DSH/Node。

- **重启 DSH 后端改为有状态事务**：`restart.preflight → snapshot → stop-wrapper →
  wait-port-close → stop-listener-fallback → compat → start → wait-ready → navigate →
  complete` 十个阶段，每阶段 ENTER/OK/FAIL 写入宿主日志，并记录新旧 wrapper/listener
  PID、ownsBackend、port——失败时立刻能看出是"停不下来"还是"新进程起不来"
- **修复旧 DSH 子进程没彻底退出**：npx 经 .cmd 启动时保存的进程只是 cmd 包装进程。
  现在 DSH 首次就绪即记录真正监听端口的 Node PID；停止时 Job 关闭 → Kill wrapper →
  WaitForExit(3s) → 端口仍开时**身份验证通过才**结束真正 listener（PID 与记录一致，
  或命令行复验为 DSH + 当前 profile + 当前 port），端口连续两次确认关闭后才释放所有权；
  绝不因为端口还开着就盲目杀 PID
- **修复重启与 5 秒健康检查的竞态**：重启开始即停健康定时器并递增 backendGeneration，
  已飞出的旧代检查结果直接作废；重启结束统一重置 healthFailures 并重启定时器——
  重启期间不再出现"后端连接已中断"假警报
- **重启失败按真实后端状态分流**：A 重启未完成但原后端仍健康 / B 重启失败且旧后端已停止 /
  C 新后端已就绪但页面恢复失败；webViewReady 按实际健康状态重算，泛化提示不再盖掉真因
- **Dream Skin 改为 npm ^0.4.1**（含 sticky restore 加固与 host-backed 持久化），不再锁 npm 0.3.0、
  也不再固定 commit；升级不删 webview2-data / `~\.dsh` / Profile，不改官方
  ThemeRuntime，不注入 JS
- **Dream Skin 新旧实现按能力 marker 区分**（版本号都是 0.3.0 无法区分）：
  `Test-DreamSkinPersistenceFix` 检查 `lib\client.js` 是否含
  `dsh-dream-skin: sticky skin restore` 与 `/dream-skin/api`；管理器安装旧实现时先询问
  是否升级，诊断菜单显示修复状态
- **WebView 失败重试改为真重建**：`ReplaceWebViewControlAsync` 摘除并 Dispose 旧控件、
  新建控件后重新初始化/配置/导航；WebView 失败绝不碰健康 DSH 后端
- **Release 真冻结**：发布前 `gh release view` 检查，Release 已存在直接失败
  （"禁止覆盖，请增加版本号"），不再依赖 softprops 的隐式行为
- **清掉最后一个 DSH 版本硬编码**：`AppSettings.Load` 缺省 dshVersion 改读
  `DshProcessManager.VerifiedDshVersion`（COMPATIBILITY.json 单一来源）
- **验证门禁 11 → 15 项**：新增 test-restart-state / test-dream-skin-pin /
  test-release-immutable / test-version-source；托盘、WebView2、连续重启、Dream Skin
  真实恢复保留人工 Windows 验收（docs/DREAM_SKIN_ACCEPTANCE.md）

### v1.0.2 追加：启动身份状态机（重启反复失败的根因修复）

- **端口监听者身份四态状态机**：`None / Pending / OwnedJob / VerifiedDsh / Foreign`。
  删掉"TCP 一开但身份暂未验证 → 立即判非 DSH"的旧逻辑——"查不到 PID"与"刚查到 PID
  但 CIM 暂时读不到命令行"一律归 `Pending`，**绝不等于 Foreign**
- **Job Object 归属证明**（`IsProcessInJob`）：监听者属于本壳创建的 Job → 自己的 DSH
  进程树 → 无需等 CIM 字符串识别，直接记录 ownedListenerPid
- **Foreign 判定宽限期**：每 100~150ms 重试；只有 PID 稳定为同一 PID + 命令行成功读取 +
  明确不符合 DSH + 连续 4 次，才报"非 DSH 进程"
- **启动成功即确认归属**：`EnsureStarted` 返回 `BackendStartResult{WrapperPid, ListenerPid}`；
  成功 = 进程存活 + 端口监听 + listener 归属已确认 + ownedListenerPid 已写入
- **半失败清理**：启动最终抛异常（超时/真 Foreign/提前退出）时清理本次刚创建的
  Job/process，不再残留"UI 报失败、OwnsBackend=true、DSH 还在后台跑"
- **停止前冻结 listener 身份**：重启 snapshot 阶段在旧进程还活着时先
  `FreezeOwnedListener` 验证并写入 ownedListenerPid，再关 wrapper——fallback 杀的是
  "刚刚确认过的精确 PID"，而不是 wrapper 死后重读不可靠的命令行
- **重启日志阶段错乱修复**：`activeRestartPhase` 随每个阶段进入即更新，外层 catch
  打印真实失败阶段（不再停留在 restart.preflight 误导排查）
- **启动身份转换日志**：`PORT closed` / `PORT open pid=... identity=pending` /
  `inOwnJob=true` / `BACKEND ready wrapper=... listener=...` / `identity=foreign stableCount=1..4`
- **ready banner 辅助信号**：`OnOutput` 识别 `dsh web: http://127.0.0.1:<port>` 记录
  `sawReadyBanner`，仅辅助、不取代 Job/PID 归属检查
- **验证门禁 15 → 16 项**：新增 `test-startup-identity.ps1`——编译产品真实源码做行为回归：
  自己的 DSH 晚就绪（~500ms 后开始监听）必须成功且不抛 NonDsh；真 Foreign（本进程占端口、
  命令行无 DSH 特征）稳定确认后才拒绝；日志断言 BACKEND ready / identity 转换 / stableCount=4

## v1.0.2 追加：DSH rc.8 兼容策略与插件未来维护（2026-08-20）

- **兼容策略从“唯一验证版本”改为“默认 + 最低 + 测试”**：`COMPATIBILITY.json` 升到
  schemaVersion 2，`defaultDshVersion=0.1.0-rc.7`、`minimumCompatibleDshVersion=0.1.0-rc.7`、
  `testedDshVersions=[rc.7, rc.8]`；新设置/缺失/无效值使用默认 rc.7，已有 rc.7 配置继续保留。
  当前默认暂回退 rc.7。DSH 0.1.0-rc.8 已在 Windows 11 + Node 24.14 完成实际 CLI/Web
  运行验证（--version、--no-open、web profile、独立 3088 监听与 HTTP 200 均通过）；
  之前出现的 `dsh-agent-loop` ETARGET 不是“上游缺包”——社区已确认该包存在，
  而是 fresh isolated cache + official registry + npm 11.19.0 下普通 npx 在深层
  dependency/peer resolution 中可能长时间卡住。因此默认 rc.7 是出于 fresh npx 安装
  可靠性，而非 rc.8 运行时不兼容；rc.8 仍保留在 tested 与 CLI capability 兼容信息中。
- **未来 DSH 版本不再因不在 tested 列表被强制回退**：rc.6 及以下按过旧安全处理；rc.7/rc.8
  直接使用；rc.9/后续正式版只要不低于最低版本就允许尝试，按实际 CLI 能力适配
- **统一 CLI 能力检测层**：启动流程改为 Resolve runner → 实际版本 → 探测 CLI capabilities →
  构造 Web 启动参数 → 进入现有启动/Restart 生命周期；`--no-open` 通过 `--profile <profile> --help`
  实际探测，支持才加入，探测失败保守不加；npx 与 command 共用同一套参数构造
- **Web 启动参数保持**：`--profile <profile> --port <明确端口>`，不恢复 `dsh web`，也不引入 `--port 0`
- **推荐插件选择性 pin**：已确认兼容的新版使用 npm range 或 GitHub release tag；
  Dream Skin 切换为 npm 0.4.1（含 sticky restore 与 `/dream-skin/api` marker）；
  对 DesktopShell 有兼容修复依赖的插件保持已审核版本；未验证新版不升级
- **修复菜单 Dispose 生命周期**：托盘退出延迟到 Click 消息后执行；WebView 右键菜单改为
  MainForm 生命周期内复用同一个 `ContextMenuStrip`，只在 `MainForm.Dispose` 中释放，
  不在 Closed/替换路径 Dispose，避免 `ContextMenuStrip ObjectDisposedException`（均有回归测试）
- **测试同步升级**：`test-version-source` / `test-dsh-version` / `test-accepted-dsh` /
  `test-launch-args` / `test-runner-mode` / `test-dream-skin-pin` 覆盖 rc.6/rc.7/rc.8/rc.9、
  `--no-open` 能力检测、未来版本不强制回退、插件选择性 pin 策略等行为

## v1.0.1（第八轮修复：启动运行期稳健性，2026-08-19）

v1.0.0 冻结后的第一个修复版本。

- **宿主日志**：新增 `logs\desktop-shell.log`（与 dsh 后端日志分离），启动按阶段记录
  ENTER/OK/FAIL，失败带完整异常信息；超过 8MB 自动轮转；绝不记录密钥/凭据
- **启动失败错误覆盖层**：大标题 + 可滚动异常详情 + "复制错误"按钮；缺少 WebView2 Runtime
  时单独给出官方下载入口
- **分阶段启动 + 阶段感知重试**：启动拆为 命令验证/后端探测/后端/WebView2 环境/初始化/配置/
  权限/导航 八个阶段；后端类失败 → 重启后端；WebView2 类失败 → 只重建 WebView2（绝不碰健康
  后端）；配置类失败 → 只重配（处理器先摘除再挂接，不叠加）；导航类失败 → 整体重试，且
  `BackendRunning` 守卫保证不会误杀已在运行的 owned 后端
- **关闭到托盘生命周期修复**：延迟到 FormClosing 流程结束后再隐藏（BeginInvoke），避免残留
  不可见窗口；从托盘恢复复用原窗口（不重建 WebView）
- **统一 dsh 版本重验证（PS/C# 双端同一规则）**：command/auto 模式每次启动与每次插件操作前
  重新读 `dsh --version`；accepted 路径/版本任一变化或无法读取 → 重新确认；与验证基线一致
  的新版本自动接受、不打扰用户；PS 端新增 `Test-DshNeedsReacceptance`（行为矩阵回归）
- **原生 TCP owner PID 回归测试**：`tests/test-port-owner.ps1` 编译产品同款
  `src/NativeTcpTable.cs`，真实监听端口必须返回本进程 PID（netstat 交叉验证 + 关闭端口 -1）
- **自定义 Profile 识别**：命令行身份判定接受任意合法 `--profile <name>`（不再只认 web 子命令）
- **版本/兼容基线单一来源收口**：Release 工作流新增"版本号 == 根目录 VERSION"门禁，默认输入
  改为 1.0.1；`test-launch-args.ps1` 探测版本改读 COMPATIBILITY.json
- **发布包仅 x64**：Build-Release `-Arch` 校验集只剩 x64，移除 arm64/x86 死分支
- **验证门禁 6 → 11 项**：新增 test-port-owner / test-host-log / test-shell-runtime /
  test-accepted-dsh / test-build-x64；pwsh 与 Windows PowerShell 5.1 双宿主全绿才发布




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
