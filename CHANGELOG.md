# Changelog

本项目的用户可见变更记录。安全边界与修复细节见 [docs/AUDIT.md](docs/AUDIT.md)。

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
