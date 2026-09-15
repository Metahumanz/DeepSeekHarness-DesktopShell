# DeepSeek Harness DesktopShell

> ⚠️ **非 DeepSeek 官方项目**：DesktopShell 是面向官方 DeepSeek Harness
> （<https://github.com/deepseek-ai/deepseek-harness>，MIT 许可）的社区 Windows 桌面宿主。

把DeepSeek Harness变成真正的Windows桌面应用。

DesktopShell不是DSH的替代实现：
它负责Windows窗口、WebView2、托盘、进程管理、安装与插件向导；
实际Agent仍然运行官方DeepSeek Harness。

- 原生Windows窗口与托盘
- 自动启动/复用DSH
- 无全局DSH时按官方npx方式运行
- 插件安装与配置向导
- Better Sidebar / Rewind / Skills等常用增强
- 深浅色、DPI、多屏、通知、原生右键菜单
- DSH崩溃与WebView2异常恢复
- 启动失败诊断：分阶段宿主日志（`logs\desktop-shell.log`）+ 可复制错误详情
- 安全的端口/进程识别和卸载边界

> DesktopShell v1.0.13（DSH `0.1.5-rc.2` 核心基线；发布状态以 GitHub Release 为准） · DSH `0.1.5-rc.2`（默认；最低兼容版本为 rc.7；rc.7 / rc.8 / 0.1.1 rc.1 / rc.2 / 0.1.5 rc.1 / rc.2 已列入测试基线）；未来 DSH 按 CLI 能力 best-effort 兼容

> `0.1.5-rc.2` 是固定的 DesktopShell 目标，绝不自动追 `latest`。核心空 Profile 已验收；第三方插件必须按当前真实 Profile 重新生成依赖图并完成精确 preflight，不能沿用历史 rc.2 插件目录的结论。

## 安装

### 前置条件

- Windows 10/11 x64（当前 Release 为 x64 构建）
- Windows PowerShell 5.1 或 PowerShell 7（需要提前安装，安装器不会自动装；两者均可）
- 网络连接
- WebView2 Runtime：多数 Windows 已自带；安装器会预检，缺失时给出下载入口

Node.js不需要提前准备。
如果未安装兼容版本，首次向导会询问是否通过winget安装。

### 一键安装

在 Windows PowerShell 5.1 或 PowerShell 7 中运行：

```powershell
Set-ExecutionPolicy -Scope Process Bypass
irm https://raw.githubusercontent.com/metahumanz/DeepSeekHarness-DesktopShell/v1.0.13/scripts/Install-FromGitHub.ps1 -OutFile "$env:TEMP\install-dsh.ps1"
& "$env:TEMP\install-dsh.ps1" -Owner metahumanz -Repo DeepSeekHarness-DesktopShell -Tag v1.0.13
```

> 必须显式传 `-Owner` / `-Repo` / `-Tag`：脚本被单独下载到临时目录时，
> 无法从 git remote 推断仓库。`-Tag` 同时把下载锁定到对应 Release，
> 并强制校验同源 `SHA256SUMS.txt`（不一致即中止）。
> 也可以双击仓库根目录的 `install-latest.bat`（GitHub latest Release）或
> `install-from-source.bat`（从当前 checkout 源码安装，与 Release 共用同一安装核心）。

#### 无人值守安装

```powershell
& "$env:TEMP\install-dsh.ps1" -Owner metahumanz -Repo DeepSeekHarness-DesktopShell -Tag v1.0.13 `
    -NoWizard -NoShortcuts -NoLaunch
```

`-NoWizard` 不会跳过初始化：仍会以非交互方式检查 Node、解析现有 DSH（或准备官方 npx）、
初始化 Profile——缺少 Node.js 时直接中止，避免"安装成功、首次启动才发现缺 Node"。

## 安装器会做什么？

1. 下载并校验DesktopShell Release
2. 安装到LocalAppData
3. 检测Node.js
4. 检测现有DSH
5. 没有DSH时使用官方npx方式
6. 创建/复用web Profile
7. 询问插件方案
8. 写入桌面设置
9. 创建开始菜单入口
10. 启动DesktopShell

## 插件生态与兼容性

插件目录不再是仓库里的静态推荐表。管理器会读取当前 `~/.dsh/profiles/web` 的 `package.json`、实际安装包、`cordis.patch.yml`、`dsh.client.inject`、Cordis `inject` / `provide`，并查询 npm/GitHub 上游信息，生成可复查的版本与依赖图。

```powershell
.\scripts\Scan-DshPluginEcosystem.ps1 -DshVersion 0.1.5-rc.2 -OutputMarkdown docs\PLUGIN_COMPATIBILITY_MATRIX.md
```

矩阵包含插件、已装版本、上游版本、依赖服务、依赖插件、`0.1.5-rc.2` 证据、状态和反向依赖。`PASS` 只在同一精确 DSH/插件版本/安装 spec 已经通过 BootReady、plugin tree、HTTP、真实 WebView2、刷新、设置页和重启验收时产生；Git 来源还必须由 `pnpm-lock.yaml` 或包元数据锁定 commit。`WARN`、`BLOCKED` 与 `UNKNOWN` 都不是兼容声明。`latest` 只显示为可选上游信息，永远不会自动成为推荐或安装版本。

管理器会在卸载父插件时先计算所有下游，并要求确认连锁卸载；DSH 升级前会重新扫描硬阻断项。若补丁层引用没有 provider 的服务或插件 id，预检会精确阻断该链，而不会随意删除无关插件。

完整的真实生态 preflight 使用临时 `DSH_HOME`、临时 Profile 和随机端口，先跑干净 rc.2 基线，再按依赖顺序对每个插件及其实际父链独立安装、检查 BootReady/plugin tree/HTTP/真实 WebView2/刷新/设置页/重启，最后运行完整组合：

```powershell
.\scripts\Test-DshPluginEcosystemPreflight.ps1 -DshVersion 0.1.5-rc.2
```

预检默认把 token-free 结果写到当前 Profile 的 `.dsh-desktop-shell` 目录，供管理器的升级门禁使用；仓库维护时可显式传 `-OutputResults docs\PLUGIN_PREFLIGHT_0.1.5-rc.2.json` 生成提交快照。预检会检测 `Failed to load plugins` 和 `pending (waiting for service...)`。遇到首个硬阻断时，只隔离该插件及其下游链；其他独立插件不被删除。需要单个隔离测试时可使用：

本提交的真实 `web` Profile 快照已执行 `plugin list`（exit 0）：12 个当前安装插件的独立依赖链与完整组合都通过，详情见 [插件兼容矩阵](docs/PLUGIN_COMPATIBILITY_MATRIX.md) 和 [token-free 预检结果](docs/PLUGIN_PREFLIGHT_0.1.5-rc.2.json)。这只是该精确 Profile 的结果；重新安装、升级或切换版本后必须重新扫描和预检。

```powershell
.\scripts\Test-PluginBootPreflight.ps1 -DshVersion 0.1.5-rc.2 -PluginSpec 'some-plugin@1.2.3'
```

**新 Profile 的默认选项仍是 0（纯 DSH，不安装社区插件）**。核心 rc.2 本地验收：

```powershell
.\scripts\Test-Dsh015NoPluginLocal.ps1 -DshVersion 0.1.5-rc.2
```

它强制使用临时 `DSH_HOME`，确认只有 `dsh-base` / `dsh-web-app` 核心 bundle、无用户依赖或补丁；详细范围见 [DSH 0.1.5 rc.2 核心验收](docs/DSH_015_NO_PLUGIN_ACCEPTANCE.md)。

## 第一次启动

- DesktopShell 启动后会等待 DSH Web 就绪，窗口直接显示官方 DeepSeek Harness 界面
- 模型凭据由 DSH 自身处理，DesktopShell 不接管
- 托盘图标：双击在显示/隐藏窗口间切换（恢复时淡入）/ 设置 / 重新加载页面 / **重启 DSH 后端** / 打开日志目录 / 关闭行为 / 退出
- 关闭窗口行为可在向导或设置中改为"关闭到托盘"（关闭后任务栏隐藏、托盘常驻，双击托盘图标恢复）
- 启动失败时窗口会显示错误覆盖层：大标题 + 可滚动异常详情 + **复制错误**按钮；后端类失败
  重试只重启后端、WebView2 类失败只重建 WebView2（不会误杀已健康的 DSH 后端）
- 启动过程按阶段记录在 `logs\desktop-shell.log`（含失败原因与完整异常），排查问题先看它

## 日常管理

开始菜单 →「管理 DSH - 插件与配置」：检查 DSH / 修改 npx 版本、Profile、Web 端口、
默认工作目录、关闭行为、开发者模式；安装插件；查看插件列表与诊断。
选择 npx 版本时输入菜单编号，不需要手输版本号：菜单列出生产默认、其他已测试历史版本，
以及官方 `latest` / `alpha` dist-tag 通道。选择通道时才实时查询 npm 并固定到本次解析出的准确版本，
因此不会静默自动升级；`latest` 适合获取当前稳定发布，`alpha` 仅用于预览验证，不会加入正式测试列表或替换默认版本。
`alpha` 通道会自动改用新建的隔离 Profile，保留原 Profile、插件、主题和会话不动；若手动使用未来未测试版本导致
插件 loader 报 API 失配，DesktopShell 也会提供相同的“隔离 Preview Profile 重试”操作。当前 alpha 线使用
BrowserAuth ready URL；DesktopShell 已适配其 303/Cookie 首次握手，token 只在内存中使用、不会写入设置或日志。
当前 alpha Preview 的已验证组合、已确认不兼容插件和验证边界见
[DSH alpha 预览兼容快照](docs/DSH_ALPHA_PREVIEW_COMPATIBILITY.md)；它是按标签解析时的快照，
不构成生产兼容声明。

## 更新插件

- 管理器菜单 3（安装插件），或在 DSH 内使用插件市场
- 安装/更新完成后：**托盘 → 重启 DSH 后端**，让新插件生效
- 兼容修复（Sentinel / Cost Meter 等）在每次 DSH 启动前自动执行

## 卸载

开始菜单 →「卸载 DesktopShell」：

1. **完整卸载**：删除 DesktopShell + DSH_HOME（Profile、插件、会话、设置、storage）
2. **仅卸载桌面壳**：保留 DSH_HOME，可继续单独使用 DSH

卸载器带路径安全守卫：验证安装目录所有权标记后才删除程序目录；
DSH_HOME 等于/包含用户主目录、系统目录、程序目录等危险路径时拒绝删除并降级为仅卸载壳。

## 故障排查

| 症状 | 处理 |
| --- | --- |
| 启动失败 / 界面空白 | 安装目录 `logs\` 下：`desktop-shell.log`（宿主启动分阶段日志）、`dsh-*.log`（后端）、`plugin-compat.log`（兼容修复）；失败界面自带错误详情与"复制错误"按钮 |
| 缺少 WebView2 Runtime | 安装器会预检并给下载入口；也可直接装 <https://go.microsoft.com/fwlink/p/?LinkId=2124703> |
| 提示 Node.js 过旧/缺失 | 需要 Node 22.19+ 或 24+；向导可代跑 `winget install OpenJS.NodeJS.LTS` |
| 端口被占用 | 设置里换一个端口；占用进程不是 DSH 时桌面壳会拒绝附着并提示 |
| 插件安装失败 | 管理器菜单 4 诊断；`plugin add` 失败不影响其他插件 |

## 安全设计

当前维护基线见 [docs/CURRENT_STATUS.md](docs/CURRENT_STATUS.md)，当前真实生态矩阵见
[docs/PLUGIN_COMPATIBILITY_MATRIX.md](docs/PLUGIN_COMPATIBILITY_MATRIX.md)；历史审计记录见
[docs/AUDIT.md](docs/AUDIT.md)。摘要：

- **安装目录所有权**：`.dsh-desktop-shell-root` 标记；非空且非本产品目录拒绝安装；**程序目录** Preflight→Stage→Initialize→Commit 事务式提交（升级保留旧 exe 回滚，失败可恢复旧安装；首次向导对 DSH_HOME 的初始化不在回滚范围）；卸载前再次验证
- **卸载守卫**：DSH_HOME 危险路径双向检查；完整卸载先确认并停止外部 DSH，停止失败降级为仅卸载壳；延迟自删除脚本执行前第三次验证标记
- **端口/进程**：只信任回环 DSH 源；端口占用先查 PID+命令行，非 DSH 进程拒绝附着/强杀；Job Object 回收自家后端；运行方式（自动/现有 dsh/仅 npx）持久化双端一致
- **发布链**：一键安装对 Release 资产做 SHA256 完整性校验（防下载损坏/资产错配）；插件来源类型会在管理器中明示
- **页面边界**：主导航回环白名单；外链 http/https 白名单，其余协议弹确认；DevTools 默认关闭

## 从源码构建

开发者（普通用户不需要）：

```powershell
.\scripts\Install-Desktop.ps1    # 源码安装：csc 编译 + 向导
.\scripts\Build-Release.ps1      # 构建发布 zip（WebView2 固定 1.0.4078.44）
.\scripts\Build-Release.ps1 -Version 1.0.13
```

需要 Windows 自带 .NET Framework `csc.exe` 与网络（下载固定版本 WebView2 SDK）。
**发布包仅支持 x64**：`Build-Release` 的 `-Arch` 固定为 `x64`（不再接受 arm64/x86）。
回归测试在 `tests\`：PowerShell 7 运行全部 41 项；Windows PowerShell 5.1 解析全部脚本，
并运行 7 项真实覆盖宿主差异的兼容回归。CI 每次 push/PR 自动运行。
插件完整 BootReady 验收是独立 release preflight，不在日常插件安装流程中启动用户 Profile。

## Release 流程

GitHub Actions → **Release → Run workflow**，输入版本号（如 `1.0.13`，必须与根目录
`VERSION` 文件一致，否则门禁直接失败）：

1. 校验输入版本 == 根目录 `VERSION`，然后运行 PowerShell 7 全量回归（41 项）及
   Windows PowerShell 5.1 兼容套件（7 项，另解析全部脚本）
2. `Build-Release -Version`（仅 x64）；该步骤按完整期望清单解包自校验 ZIP，并生成 SHA256
3. 发布 Job 下载工件后仅复核 ZIP 与 `SHA256SUMS.txt` 的哈希一致性
4. 校验 tag（已存在时必须指向当前 HEAD，否则拒绝）
5. 创建 tag 与 GitHub Release，上传 `DeepSeekHarness-DesktopShell.zip` + `SHA256SUMS.txt`

推送 `v*` tag 也会触发同样流程。两个资产必须同时上传，一键安装的哈希校验才能通过。

## 项目结构

```
.
├── assets/                 # 图标（源自官方 favicon.svg）
├── scripts/                # 安装 / 管理 / 卸载 / 发布 / 修复脚本
├── src/                    # C# 桌面宿主源码（窗口/WebView2/进程托管/兼容修复）
├── tests/                  # 回归测试（40 项）：安装所有权 / 卸载守卫 / 账本修复 / 版本门槛 /
│                           #   生命周期 / 托盘句柄 / WebView 恢复 / 进程有界探测 / 设置快照 /
│                           #   启动参数 / 端口归属 / 宿主日志 / 壳运行期 / 重验证 / 构建接线
├── .github/workflows/      # CI 与 GitHub Release 工作流
├── docs/CURRENT_STATUS.md  # 当前维护、兼容与验证基线
├── docs/PLUGIN_RC2_UPDATE_AUDIT.md # rc.2 插件升级与预检记录
├── docs/AUDIT.md           # 历史安全审计记录（v1.0.4 快照）
├── install-latest.bat        # 双击入口：从 GitHub 下载 latest Release 安装
├── install-from-source.bat   # 双击入口：从当前 checkout 源码安装
├── LICENSE                 # MIT
└── THIRD_PARTY_NOTICES.md  # 第三方组件与许可声明
```

## 第三方许可

本项目 MIT（见 `LICENSE`）。图标源自官方 DeepSeek Harness favicon（MIT，保留版权声明）；
WebView2 SDK 按 Microsoft 许可条款分发。详见 `THIRD_PARTY_NOTICES.md`。
