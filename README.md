# DeepSeek Harness DesktopShell

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
- 安全的端口/进程识别和卸载边界

> 当前基线：DesktopShell v1.0.0 · DSH 0.1.0-rc.7

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
irm https://raw.githubusercontent.com/metahumanz/DeepSeekHarness-DesktopShell/v1.0.0/scripts/Install-FromGitHub.ps1 -OutFile "$env:TEMP\install-dsh.ps1"
& "$env:TEMP\install-dsh.ps1" -Owner metahumanz -Repo DeepSeekHarness-DesktopShell -Tag v1.0.0
```

> 必须显式传 `-Owner` / `-Repo` / `-Tag`：脚本被单独下载到临时目录时，
> 无法从 git remote 推断仓库。`-Tag` 同时把下载锁定到对应 Release，
> 并强制校验同源 `SHA256SUMS.txt`（不一致即中止）。
> 如果 `v1.0.0` 尚未发布，可改用仓库根目录的 `install.bat`（main 分支脚本）或源码安装。

#### 无人值守安装

```powershell
& "$env:TEMP\install-dsh.ps1" -Owner metahumanz -Repo DeepSeekHarness-DesktopShell -Tag v1.0.0 `
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

## 推荐插件

### 核心推荐
| 插件 | 用途 |
| --- | --- |
| dshmarket | 插件市场 |
| Better Sidebar | 文件、终端、Git、编辑器工作台 |
| Skills Manager | 管理Skills |
| @file | 在对话中引用文件 |
| Rewind | 编辑历史消息并从原位置重新运行 |

### 体验增强

UI 与操作效率增强，不装也不影响 DSH 核心：

| 插件 | 用途 |
| --- | --- |
| File Mentions | 对话中的文件路径点击/提及 |
| Auto Collapse | Tool/Think 输出自动折叠 |
| Chat Tidy | Codex 风格对话排版 |
| Side Outline | 对话侧边大纲 |
| Better Archive | 会话归档整理 |
| Model Picker | 模型选择器增强 |

### 高级功能

默认不装（会改变 Agent 行为或涉及估算/兼容修复）：

| 插件 | 用途 | 备注 |
| --- | --- | --- |
| Auto Mode | 自动连续执行模式 | 会改变 Agent 行为 |
| Cost Meter | 用量与费用统计 | 统计参考，不等于官方账单 |
| Dream Skin | 主题皮肤 | |
| Status Rotator | 状态栏文案轮换 | |
| Sentinel | 条件唤醒 | |
| ModLens | 视觉包装 | |
| Remote SSH | 远程 SSH 工作区 | |
| Video Preview | 视频预览 | |

内置目录全部锁定精确版本 / commit（可复现），"全部已审核插件"也只安装锁定版本；
需要追新的用户可在向导的"额外插件"步骤粘贴自定义 spec。

## 第一次启动

- DesktopShell 启动后会等待 DSH Web 就绪，窗口直接显示官方 DeepSeek Harness 界面
- 模型凭据由 DSH 自身处理，DesktopShell 不接管
- 托盘图标：显示窗口 / 设置 / 重新加载页面 / **重启 DSH 后端** / 打开日志目录 / 退出
- 关闭窗口行为可在向导或设置中改为"关闭到托盘"

## 日常管理

开始菜单 →「管理 DSH - 插件与配置」：检查 DSH / 修改 npx 版本、Profile、Web 端口、
默认工作目录、关闭行为、开发者模式；安装插件；查看插件列表与诊断。

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
| 启动失败 / 界面空白 | 安装目录 `logs\` 下的 `dsh-*.log` 与 `plugin-compat.log` |
| 缺少 WebView2 Runtime | 安装器会预检并给下载入口；也可直接装 <https://go.microsoft.com/fwlink/p/?LinkId=2124703> |
| 提示 Node.js 过旧/缺失 | 需要 Node 22.19+ 或 24+；向导可代跑 `winget install OpenJS.NodeJS.LTS` |
| 端口被占用 | 设置里换一个端口；占用进程不是 DSH 时桌面壳会拒绝附着并提示 |
| 插件安装失败 | 管理器菜单 4 诊断；`plugin add` 失败不影响其他插件 |

## 安全设计

完整记录见 [docs/AUDIT.md](docs/AUDIT.md)，摘要：

- **安装目录所有权**：`.dsh-desktop-shell-root` 标记；非空且非本产品目录拒绝安装；卸载前再次验证
- **卸载守卫**：DSH_HOME 危险路径双向检查；延迟自删除脚本执行前第三次验证标记
- **端口/进程**：只信任回环 DSH 源；端口占用先查 PID+命令行，非 DSH 进程拒绝附着/强杀；Job Object 回收自家后端
- **发布链**：一键安装强制校验 SHA256SUMS；插件推荐全部锁定版本
- **页面边界**：主导航回环白名单；外链 http/https 白名单，其余协议弹确认；DevTools 默认关闭

## 从源码构建

开发者（普通用户不需要）：

```powershell
.\scripts\Install-Desktop.ps1    # 源码安装：csc 编译 + 向导
.\scripts\Build-Release.ps1      # 构建发布 zip（WebView2 固定 1.0.4078.44）
.\scripts\Build-Release.ps1 -Version 1.1.0 -Arch arm64
```

需要 Windows 自带 .NET Framework `csc.exe` 与网络（下载固定版本 WebView2 SDK）。
回归测试在 `tests\`，CI 每次 push/PR 自动运行。

## Release 流程

GitHub Actions → **Release → Run workflow**，输入版本号（如 `1.0.0`）：

1. 跑全部回归测试
2. `Build-Release -Version`（x64）
3. 校验 tag（已存在时必须指向当前 HEAD，否则拒绝）
4. 创建 tag 与 GitHub Release，上传 `DeepSeekHarness-DesktopShell.zip` + `SHA256SUMS.txt`

推送 `v*` tag 也会触发同样流程。两个资产必须同时上传，一键安装的哈希校验才能通过。

## 项目结构

```
.
├── assets/                 # 图标（源自官方 favicon.svg）
├── scripts/                # 安装 / 管理 / 卸载 / 发布 / 修复脚本
├── src/                    # C# 桌面宿主源码（窗口/WebView2/进程托管/兼容修复）
├── tests/                  # 回归测试：安装所有权 / 卸载守卫 / 账本正则 / 版本门槛
├── .github/workflows/      # CI 与 GitHub Release 工作流
├── docs/AUDIT.md           # 安全审计记录
├── install.bat             # 双击入口（git clone 后使用）
├── LICENSE                 # MIT
└── THIRD_PARTY_NOTICES.md  # 第三方组件与许可声明
```

## 第三方许可

本项目 MIT（见 `LICENSE`）。图标源自官方 DeepSeek Harness favicon（MIT，保留版权声明）；
WebView2 SDK 按 Microsoft 许可条款分发。详见 `THIRD_PARTY_NOTICES.md`。