# Changelog

本项目的用户可见变更记录。当前维护基线见 [docs/CURRENT_STATUS.md](docs/CURRENT_STATUS.md)，历史安全审计记录见 [docs/AUDIT.md](docs/AUDIT.md)。
> **v1.0.0 已冻结（2026-08-19）**：不再以同 tag 覆盖发布；后续修复走新版本号
> （Release 工作流已移除"删除已有 Release"步骤，重复发布同一 tag 会失败，属有意行为）。

## v1.0.11（DSH 0.1.5-rc.2 DesktopShell 与真实插件生态适配）

- **固定 rc.2 核心目标**：默认和已测 DSH 升级为精确 `0.1.5-rc.2`，`--no-open` 能力表同步更新；`latest` 保留为用户主动选择的可选通道，绝不自动成为推荐版本。
- **BrowserAuth / BootReady**：保留现有完整 ready URL 提取、loopback/端口校验和仅内存 token 处理；为 rc.2 补充基线测试。WebView2 首次导航必须使用本次 DSH 输出的完整 token URL，端口监听不再被当作 ready，外部进程不能复用旧 token。
- **动态插件生态**：新增扫描器，从真实 Profile、已安装包、patch、Cordis 服务注入/提供、peerDependencies 和 npm/GitHub 上游元数据生成矩阵与依赖图。静态插件目录不再声称某版本兼容。
- **依赖与预检**：插件模型增加 `DependsOn`、`RequiresService`、`HostRange`、反向依赖和安装顺序。连锁卸载与 DSH 升级阻断均以图为依据。新的 rc.2 preflight 先跑纯净基线，再按依赖顺序对每个实际父链检查 plugin tree、HTTP、真实 WebView2、刷新、设置页、重启和完整组合；Git 依赖从 `pnpm-lock.yaml` 读取精确 commit。提交快照中真实 `web` Profile 的 12 个插件和完整组合均通过，且无 failed/pending；`PASS / WARN / BLOCKED / UNKNOWN` 不再由版本号猜测。

## v1.0.10（Windows PowerShell 5.1 发布门禁修复）

- **PowerShell 5.1 解析兼容**：无插件验收脚本不再用 UTF-8 无 BOM 文件中的中文字符串作为 PowerShell 字面量断言，改用同一验收文档的 ASCII 标题与复跑脚本锚点。这样既保留“文档明确给出无插件边界”的门禁，也避免 Windows PowerShell 5.1 按本地 ANSI 代码页解析时把 UTF-8 字节误认作引号。此前 `v1.0.9` tag 的远端构建因此未生成 Release；遵循不可变标签策略，以本补丁版本重新发布。

## v1.0.9（DSH 0.1.5-rc.1 无插件基线）

- **DSH 0.1.5-rc.1 无插件基线**：默认 npx 版本切换到官方 `latest` 的精确版本 `0.1.5-rc.1`，并加入已测版本与 `--no-open` 能力表。新增只接受全新空 Profile 的隔离验收入口，验证 `--version`、`--help`、ready URL、HTTP 200 和稳定运行；本轮不迁移、不安装也不宣称兼容任何第三方插件。
- **CI 去重**：PowerShell 7 保留全部 41 项源码门禁；Windows PowerShell 5.1 改为“解析全部脚本 + 7 项宿主兼容回归”，不再重复运行同一批 C# / 静态结构测试。`Build-Release` 继续作为 ZIP 完整文件清单的唯一权威校验点；普通 CI 不再重复解包或上传无人消费的发布工件，Release 发布 Job 仅在跨 Job 下载后复核 SHA256。
- **兼容修复契约**：新增生产 `PluginCompat` 账本修复、超出默认 JSON 大小的账本，以及 C#/卸载器端口命令行边界匹配的回归覆盖。
- **插件来源透明度**：未带 tag/commit 的 GitHub 目录项明确标记为浮动引用，并在展示与安装前提示其不可复现边界；新增当前状态页，历史审计页改为 v1.0.4 快照定位。
- **rc.2 插件升级审计**：以隔离 `DSH_HOME`/Profile/随机端口逐项验证 15 个新版或 release tag，并验证核心三插件组合；通过项更新为精确 npm 版本或 GitHub tag，剩余 3 个无 tag GitHub 来源继续显式标记为浮动。
- **Cost Meter 迁移收口**：新版上游已原生处理 wrapper provider 重映射与去重；自动账本清理改为仅在可证明的旧版源码布局下执行，手工迁移默认 DryRun 风格的拒绝写入，需显式 `-ForceLegacyCleanup` 才会修改旧账本。
- **Dream Skin 8.x**：目录更新到已隔离启动验证的 `8.30.1`；持久化检测同时兼容历史和新版 sticky-restore marker，人工 Windows 验收表同步为当前 spec。

## v1.0.8（Windows PowerShell 5.1 发布门禁修复）

- **取消路径 CI 稳定性**：首次安装取消的回归改为向安装核心注入确定性的 `Manage-Dsh` 退出码 `2` 桩，直接验证“正常取消、不提交暂存目录”的正式契约；不再依赖 GitHub Runner 非交互 ConsoleHost 对重定向 `Read-Host` 的实现差异。此前 `v1.0.7` 标签的远端门禁因此未能完成发布，按不可变标签策略以本补丁版本重新发布。

## v1.0.7（DSH 通道与 alpha Preview 兼容边界）

- **rc.2 Sidebar QA 回归修复**：生产插件目录和 rc.2 验收改为固定 npm 精确版 `dsh-sidebar-qa@0.4.0`。上游 `0.5.0` 依赖 DSH `0.1.2-alpha.1` 引入的 `remote.session`，在 rc.2 会保持 pending 并让页面显示插件加载失败；不再跟随 GitHub HEAD。
- **rc.2 Agent Teams 回归修复**：生产插件目录和 rc.2 验收改为固定 npm 精确版 `@nanmicoder/dsh-agent-teams@0.1.14`。上游 `0.1.15` 起要求 `0.1.2-alpha.2` 的 `uiConversation` 服务，在 rc.2 会保持 pending 并让页面显示插件加载失败；不再使用会漂移到 alpha 的范围版本。
- **npx 通道选择**：管理器和首次向导改为编号选项，不再要求手输版本号；除生产默认和历史已测版本外，新增官方 `latest` / `alpha` dist-tag 选项。标签在选择时实时解析成准确版本而非在代码中逐个维护，rc.2 仍保持生产默认。
- **预览 Profile 隔离与取消语义**：`alpha` 通道会生成新的隔离 Profile，不修改原有插件、主题或会话；未来未测试 DSH 若在插件 loader 阶段出现明确 API 失配，启动页提供同样的隔离 Profile 重试入口。首次安装中取消版本/Profile 选择会干净退出，不再被上层误报为“安装核心失败”。
- **alpha BrowserAuth 适配**：从本次自有 DSH 的 loopback ready banner 提取并校验临时 URL，完成 `303 → Cookie → 200` BootReady 探测并用于 WebView2 首次导航；token 只保存在对应 backend run 的内存中，后端日志和错误摘要统一脱敏。外部已运行的 BrowserAuth DSH 因无法安全取得 launch token，会明确提示改由 DesktopShell 启动。
- **alpha 线状态**：预览通道不会写入正式 tested 列表，也不会改变生产默认。BrowserAuth 运行期路径已经具备适配，但第三方插件 API 仍处于迁移期，未宣称为正式兼容。
- **alpha.4 隔离验证快照**：`0.1.2-alpha.4` 的 18 项 Preview 插件组合完成稳定启动与 Status Rotator 重启保持性验证；Better Sidebar、Auto Collapse、Open In、Agent Teams 和本地 Browser Bridge 因已确认的 DSH 插件 API 失配被排除。完整范围和版本快照见 `docs/DSH_ALPHA_PREVIEW_COMPATIBILITY.md`。

## v1.0.6（DSH 0.1.1-rc.2 兼容与插件目录收口）

- **rc.2 兼容声明**：`0.1.1-rc.2` 加入 `testedDshVersions`，并加入已确认支持 `--no-open` 的能力表；未知版本仍实际执行 `--help` 探测。真实环境验收通过后，`defaultDshVersion` 切换为 `0.1.1-rc.2`，`minimumCompatibleDshVersion` 继续保持 `0.1.0-rc.7`。
- **rc.2 回归入口**：沿用 rc.1 的临时 `DSH_HOME`/随机端口流程，覆盖 `--version`、`--help`、`--profile web --no-open`、ready banner、HTTP 200、稳定运行、DesktopShell 启动/后端重启/正常退出和附件/图片人工回归；DesktopShell 不增加图片适配。
- **本轮实测结论**：rc.2 CLI/Web 隔离 smoke 与 26/26 插件 preflight 通过，真实环境的 DesktopShell 启动、后端重启、正常退出和附件/图片回归通过，默认版本切换为 rc.2。临时构建 GUI 曾在 WebView2 `WebViewInitialize` 报 `0x8000FFFF (E_UNEXPECTED)`，该结果归因为临时环境异常，不覆盖真实环境验收结论。
- **插件目录按真实 Profile 同步**：更新本机已安装版本，清除失效的 `dsh-open-in-vscode` 等历史项，加入 `dsh-context`、`dsh-open-in`、`dsh-agent-teams` 和 `dsh-status-rotator`；Agent Teams 放在 advanced，保持安装成功不等于兼容通过。
- **思考状态插件互斥**：Status Rotator `dsh-status-rotator@^0.6.6` 放入 enhanced 并作为低侵入首选；Thought Buddy 保留在 advanced。两者使用 `thinking-status-ui` 互斥组，选择冲突时要求二选一，已有 Profile 冲突不会静默卸载。
- **安装后 hook 元数据化**：Sidebar 与 Status Rotator 的配置通过 `PostInstall` 统一遍历执行；Status Rotator 首次安装初始化配置并默认关闭渐变，已有用户配置保持不变。
- **回归门禁**：新增 rc2 兼容、插件目录、Status Rotator 配置和插件互斥组测试，回归总数更新为 39 项。

## v1.0.5（DSH 0.1.1-rc.1兼容认证）

- **完成 rc1 CLI/Web/桌面壳兼容基线**：rc1 `--version`、`--help`（含 `--port` / `--no-open`）、Web ready、HTTP 200、稳定运行和 DesktopShell 后端启动/重启/退出路径已完成实测；OAuth 系统浏览器与回环导航仍保留为发布前人工签核项。
- **兼容声明更新**：`0.1.1-rc.1` 加入 `testedDshVersions`；`defaultDshVersion` 和 `minimumCompatibleDshVersion` 继续保持 `0.1.0-rc.7`。
- **已知能力更新**：rc1 加入已知 `--no-open` 能力；未来未知版本仍实际执行 `--help` 探测，不使用“版本号大于等于 rc.8 即支持”的规则。
- **修复历史覆盖层 BUG**：重启按钮可见性曾受隐藏父容器的 WinForms 有效 `Visible` 影响，导致“能点击但无动作”；现在按显示决策绑定动作，并记录 `UI overlay action=restart`，同时覆盖层显示时隐藏 WebView2，关闭后恢复。
- **插件清单按真实环境同步**：本机 `C:\Users\metahumanz\.dsh\profiles\web\package.json` 中的 23 个可移植插件逐项完成 rc1 隔离 preflight（安装 → Web ready → HTTP 200 → 稳定 10 秒 → 退出 → 端口清理），23/23 PASS。`@yuxianglin/dsh-bridge-browser` 是本地 `link:` 依赖，未伪造为可移植 PASS；`dsh-model-picker`、`modlens`、`dsh-status-rotator` 当前不在真实 Profile，未列入本轮测试。
- **预检脚本加固**：隔离 Profile 先安装同版本 `@deepseek-ai/dsh-web-app`，并兼容读取运行中重定向日志；插件安装超时与 Web 启动超时分开，失败时输出安装日志尾部以区分网络/安装失败和插件运行失败。
- **版本与门禁**：版本测试加入 rc1 支持/测试断言；认证静态检查加入 default/minimum/known-no-open/版本号和不在线下载约束；回归总数更新为 36 项。

## v1.0.4（运行期生命周期修复）

- **托盘隐藏/恢复不再重建主窗口句柄**：MainForm 运行期间不再切换 `ShowInTaskbar`；关闭到托盘与恢复复用同一个 Form、WebView2 和 backend，并增加 Handle 创建/销毁诊断。托盘图标双击现在在显示/隐藏间切换，恢复时使用约 160ms 的 ease-out 淡入动效；普通激活、首次启动和系统关闭动画效果时不播放。
- **退出生命周期统一取消**：真实退出、Windows 关机和重启应用会取消 lifetime；startup/restart/health/retry 在 await 后检查取消，取消后清理本轮启动的 wrapper/listener，不再操作已 Dispose 控件。关闭到托盘不取消。
- **恢复动作串行化**：WebView2 重建、配置、backend 启动/重启共用恢复门禁，重复点击不会并发 Dispose/Create；持续 WebView2 Unresponsive 时保留页面并提供显式“重建 WebView2”入口。
- **设置运行时事务收口**：立即应用使用 oldRuntime/targetRuntime 双快照；旧 backend 的停止链只使用旧端口，目标 backend 的启动链只使用新端口，target ready 后才提交 active runtime。
- **启动完成判定收紧**：DesktopShell 自己启动的 DSH 必须完成 listener 身份确认、`dsh web` ready banner、HTTP 200 和短暂稳定确认后才进入 WebView；监听后插件/Profile 初始化失败并退出会直接判为启动失败。
- **启动失败与运行中断分流**：BootReady 前退出显示插件/Profile 启动失败与重试、复制错误、日志目录入口；BootReady 后才显示“DSH 后端连接已中断”。`desktop-shell.log` 记录 wrapper PID、退出码、expectedStop、状态，并保留最近 stdout/stderr fatal 摘要。
- **后端代际事件隔离**：每次 backend 启动拥有独立 generation、stdout/stderr drain 和 recent output；旧代延迟 `Exited`/输出只写自己的诊断并被标记 ignored，不会清除新代 BootReady、Running 或 expectedStop。
- **后端运行上下文回收**：旧 run 在 Exited callback 完成且 stdout/stderr drain 排空、确认不再是 current 后立即移除并 Dispose；连续 25 次真实 fake backend 重启验证 run 数量保持有界。
- **探测进程有界执行**：版本、netstat/CIM fallback 和 `--help` 探测统一异步读取 stdout/stderr、超时回收进程树，不按进程名误杀。
- **运行配置与持久设置分离**：backend 影响字段使用 active runtime snapshot；保存但稍后重启时，当前 backend 继续按旧端口/profile 运行，立即应用走既有重启事务。
- **健康身份与对话框边界收紧**：自有 backend 健康检查校验监听 PID/Job 归属；托盘隐藏时对话框改用 ownerless + CenterScreen。
- **保持 v1.0.3 的 DSH 默认版本、测试版本和已确认插件规格不变**；日常插件安装不启动用户真实 Profile，完整兼容验收改由独立 release preflight 在临时 `DSH_HOME`/Profile/随机端口中完成；结束时按随机端口解析精确 listener PID 并确认端口/进程无残留，不按 node/cmd 进程名清理；dsh-remote 尚未通过完整验收，暂时移出 v1.0.4 推荐目录。DPI 本轮只增加 100%/125%/150%/200% 的人工 Windows 验收矩阵。

> 发布状态以 Git tag 与 GitHub Release 为准；本版本的自动门禁与 Release 构建已完成，真实 Windows 验收结果仍以实际 Windows 记录为准。

## v1.0.3（仓库维护收尾，2026-08-20）

- **CI/Actions 维护**：checkout v6、upload-artifact v6、download-artifact v7、
  action-gh-release v3；CI 与 Release checkout 均 `fetch-depth: 0`；
  `test-release-immutable` 改为冻结 v1.0.0 / v1.0.1 / v1.0.2 必须存在且为当前 HEAD 祖先
- **已知 CLI 能力收口**：rc.8 直接命中 `--no-open` 并缓存，不再为探测启动 npx --help；
  通用探测超时按 PID 回收进程树（`taskkill /T /F`），不按进程名误杀
- **推荐插件选择性 pin**：dshmarket ^1.16.0、Dream Skin npm ^0.4.1、at-file v0.6.6、
  file-mentions v1.0.6、outline v1.1.1、modlens ^3.22.0、remote 0.7.1（v1.0.3 历史目录）；
  Better Sidebar / Cost Meter / Sentinel 因兼容依赖保持已审核版本
- **文档同步**：v1.0.2 标记已发布并冻结；rc.8 实际 CLI/Web 验证结论更新
  （默认 rc.7 是 fresh npx 安装可靠性决策，不是 rc.8 运行时不兼容）

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
  `DshProcessManager.DefaultDshVersion`（COMPATIBILITY.json 单一来源；VerifiedDshVersion 仅为兼容别名）
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
- **历史健康检查缓存校验原 PID 存活**：该版本的 30 秒缓存只在原 PID 仍存活时复用；后续版本已改为原生 TCP owner PID 身份校验
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
- 后台健康检查降频（历史实现）：自家后端进程存活 + TCP；外部后端曾使用 30 秒 PID 身份缓存，后续版本已改为原生 TCP owner PID，避免周期性拉起 netstat/CIM
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
