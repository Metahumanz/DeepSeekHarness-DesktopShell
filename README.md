# DeepSeek Harness DesktopShell

Windows 桌面宿主：把 [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness)（DSH）包装成独立桌面应用。包含 C# WinForms + WebView2 桌面壳、PowerShell 安装 / 管理 / 卸载脚本、插件与兼容配置向导。

> 版本：v1.0.0 · 运行环境：Windows 10/11，PowerShell 7

---

## 特性

- **原生桌面窗口**：WebView2 承载 DSH Web 界面，自动适配深色/浅色主题、每显示器 DPI（PerMonitorV2）
- **按官方方式运行 DSH**：已有 `dsh` 命令直接用；没有则 `npx -y @deepseek-ai/dsh@<版本> web`；**绝不执行 `npm install -g`**
- **边界安全**：只信任回环地址上的 DSH 页面；端口被非 DSH 进程占用时拒绝附着/结束；未知进程绝不强杀
- **进程托管**：Job Object 托管 DSH 后端，桌面壳退出即回收；日志自动轮转（保留 40 个 / 30 天）
- **单实例**：重复启动会激活已有窗口
- **托盘与关闭策略**：每次询问 / 关闭到托盘 / 关闭并退出
- **插件向导**：19 个社区插件目录（推荐/可选），自动匹配 Profile 的 pnpm store 版本（v10/v11），GitHub git+ssh 传输自动降级为 https
- **兼容修复**：Sentinel client-id 特征修复、Cost Meter × ModLens 合成提供方重复计费去重（幂等、带标记、原子写入）

## 核心原则

DeepSeek Harness 官方 README 的运行命令是：

```
npx @deepseek-ai/dsh web
```

DesktopShell v1.0.0 按这个模型工作：

1. 系统已存在 `dsh` 命令 → 直接使用，不重装、不移动
2. 系统没有 `dsh` 命令 → 使用 `npx -y @deepseek-ai/dsh@<版本>`
3. 不执行 `npm install -g`

npx 只用于"获取/缓存并运行"，不会把 `@deepseek-ai/dsh` 注册成 npm 全局安装。

### 目录边界

| 内容 | 位置 |
| --- | --- |
| DesktopShell 程序 | `%LOCALAPPDATA%\Programs\DeepSeek Harness DesktopShell` |
| DSH 用户数据（Profile/插件/会话/设置/storage） | `%USERPROFILE%\.dsh`（设置 `DSH_HOME` 则使用该路径） |

`~/.dsh` 是 DSH 用户状态目录，**不是** `@deepseek-ai/dsh` 的安装目录。删除 `~/.dsh` 等于清空 DSH 用户状态，但不等于 npm uninstall；DesktopShell 卸载不会删除 `~/.dsh`（除非选择"完整卸载"）。

## 目录结构

```
.
├── assets/                 # 图标（.ico/.svg，源自官方 favicon.svg）
├── scripts/                # PowerShell：安装 / 管理 / 卸载 / 发布 / 修复
│   ├── Install-Desktop.ps1      # 源码安装器（编译 + 向导）
│   ├── Install-Release.ps1      # 发布包安装器（zip 内，免编译）
│   ├── Install-FromGitHub.ps1   # 从 GitHub Releases 一条命令安装
│   ├── Build-Release.ps1        # 构建发布 zip（免编译安装包）
│   ├── Manage-Dsh.ps1
│   ├── Uninstall-DesktopShell.ps1
│   └── Repair-CostMeterLedger.ps1  # 清理 ModLens 双倍计价入账
├── src/                    # C# 桌面宿主源码 + app.manifest
│   ├── DeepSeekHarness.cs  # 窗口/WebView2/进程托管/兼容修复
│   └── app.manifest
├── install.bat             # 双击入口：从 GitHub 一条命令安装
├── .gitignore
├── ICON_SOURCE.txt         # 图标来源与处理说明
└── README.md
```

## 安装（普通用户，免编译）

### 方式一：GitHub 一键安装

```powershell
Set-ExecutionPolicy -Scope Process Bypass
irm https://raw.githubusercontent.com/metahumanz/DeepSeekHarness-DesktopShell/main/scripts/Install-FromGitHub.ps1 -OutFile "$env:TEMP\install-dsh.ps1"
& "$env:TEMP\install-dsh.ps1"
```

也可以双击仓库根目录的 `install.bat`（自动推断 git remote 的 metahumanz/DeepSeekHarness-DesktopShell）。

### 方式二：发布包 zip

1. 下载 Release 中的 `DeepSeekHarness-DesktopShell.zip`
2. 解压后**双击 `install.bat`**（或运行 `Install-Release.ps1`）
3. 跟随首次配置向导

无需编译器、无需下载 WebView2 SDK——exe 与运行库已预编译打包。

### 方式三：从源码安装（开发者）

PowerShell 7：

```powershell
Set-ExecutionPolicy -Scope Process Bypass
.\scripts\Install-Desktop.ps1
```

首次向导内容：现有 dsh / npx 运行方式、npx DSH 版本、Profile、Web 端口、默认工作目录、关闭窗口行为、WebView2 开发者模式、插件安装方案。已有 Profile 默认不改现有插件。

源码安装器行为：

- 自动下载/复用 WebView2 SDK（`Microsoft.Web.WebView2`，版本不足则升级）
- 用 .NET Framework 自带 `csc.exe` 编译 `DeepSeekHarness.exe`（winexe + manifest + icon）
- 创建开始菜单入口：应用、管理 DSH、卸载 DesktopShell
- 自动清理旧版 `~/.dsh/desktop` 残留（仅该目录，其它 `~/.dsh` 数据不动）

### 无人值守安装

```powershell
.\scripts\Install-Desktop.ps1 -NoWizard -NoLaunch
```

`-NoWizard`：发现现有 dsh 就使用，否则走 npx，不改现有插件。

## 构建发布包（开发者）

```powershell
.\scripts\Build-Release.ps1
```

产物：`release\DeepSeekHarness-DesktopShell.zip` + `SHA256SUMS.txt`（WebView2 SDK 自动从本机缓存/已安装目录/NuGet 解析）。

## 管理

开始菜单 →「管理 DSH - 插件与配置」（或直接运行 `scripts\Manage-Dsh.ps1`）：

1. 检查 DSH / 设置 npx 版本
2. 修改桌面与 DSH 启动配置
3. 安装插件（推荐组合 / 全部 / 自定义）
4. 查看插件列表 / 诊断

插件命令跟随当前 DSH 运行方式：有现有 dsh → `dsh plugin ...`；npx 模式 → `npx -y @deepseek-ai/dsh@<版本> plugin ...`。

### 兼容配置

- Better Sidebar 可固定 `pwsh.exe`（用户环境变量 `DSH_SIDEBAR_SHELL`）
- Status Rotator 可关闭 gradient 炫彩
- Sentinel client-id 特征式兼容修复
- Cost Meter × ModLens 双倍计价防护：记账守卫（llm/stream）+ 历史回填守卫（backfill.js）+ 账本自动清理（每次启动执行；也可手动运行 `scripts\Repair-CostMeterLedger.ps1`）
- Profile pnpm store v10/v11 匹配，避免交叉迁移

## 卸载

开始菜单 →「卸载 DesktopShell」。两种方式：

1. **完整卸载**：删除 DesktopShell + DSH_HOME（Profile、插件、会话、设置、storage）
2. **仅卸载桌面壳**：保留 DSH_HOME，适合以后继续单独使用 DSH

卸载器**不会**删除：`~/.dsh`（仅卸载桌面壳时）、`~/.modlens`、Node.js/npm、npm 缓存、用户自己已有的 dsh。若 DesktopShell 安装前 DSH_HOME 已存在，卸载器会显式警告。完整卸载带路径安全守卫，拒绝把用户主目录 / 盘符根 / 桌面壳自身当作 DSH_HOME 删除。

## 开发与构建

桌面壳用 .NET Framework 4 C# 编译（无需安装任何 SDK）：

```powershell
$csc = "$env:WINDIR\Microsoft.NET\Framework64\v4.0.30319\csc.exe"
& $csc /nologo /target:winexe /platform:anycpu /optimize+ `
  /out:DeepSeekHarness.exe /win32icon:assets\DeepSeekHarness.ico `
  /win32manifest:src\app.manifest `
  /reference:System.dll /reference:System.Core.dll /reference:System.Drawing.dll `
  /reference:System.Windows.Forms.dll /reference:System.Web.Extensions.dll `
  /reference:path\to\Microsoft.Web.WebView2.Core.dll `
  /reference:path\to\Microsoft.Web.WebView2.WinForms.dll `
  src\DeepSeekHarness.cs
```

需要 WebView2 SDK 程序集（`Microsoft.Web.WebView2.Core.dll` / `WinForms.dll` / `WebView2Loader.dll`），安装器会从 NuGet 自动获取。
