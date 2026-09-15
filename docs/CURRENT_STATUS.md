# 当前状态与维护基线

> 更新日期：2026-09-13。本页描述此工作树；第三方插件与 npm dist-tag 会随上游变化，因此不对未来上游版本作兼容承诺。

## 发布与 DSH 兼容基线

- DesktopShell 版本：`1.0.12`（唯一来源：根目录 `VERSION`）。
- 默认 DSH：`0.1.5-rc.2`；最低兼容 DSH：`0.1.0-rc.7`。
- 已列入测试基线：`0.1.0-rc.7`、`0.1.0-rc.8`、`0.1.1-rc.1`、`0.1.1-rc.2`、`0.1.5-rc.1`、`0.1.5-rc.2`。
- 版本和通道元数据唯一来源是 `COMPATIBILITY.json`。`latest`/`alpha` 仅在用户主动选择时解析；它们不会静默改写既有 Profile，也不能自动成为推荐版本。
- `0.1.5-rc.2` 已通过全新、无插件 `web` Profile 的 CLI/Web 基线：核心 bundle、`--no-open`、完整 ready URL、BrowserAuth HTTP 200 与稳定运行。

## BootReady 与 WebView2 边界

- DesktopShell 只接受本次自有 DSH 进程输出的完整 loopback ready URL；首次导航不拼接固定 `http://127.0.0.1:3080/`。
- BootReady 同时需要本次进程的 ready banner、经过 BrowserAuth 的 HTTP 成功和稳定采样；端口监听不是就绪证明。
- token 保持内存态，敏感 query 会在日志、错误消息和预检结果中脱敏。没有本次 token 的外部 DSH 进程不能被当成可认证的自有会话复用。
- `Test-DshWebView2Acceptance.ps1` 用真实 WinForms/WebView2 对本次 DSH 输出的完整 token URL 导航，验证主界面、刷新、设置入口与插件健康文本；它不打印 URL、token 或页面正文。插件 `PASS` 必须包含此证据和独立的后端重启证据。

## 插件生态与预检

插件矩阵不再来自仓库硬编码目录。管理器和扫描器从当前 `~/.dsh/profiles/web` 的 `package.json`、已安装包、`cordis.patch.yml`、`dsh.client.inject`、Cordis `inject`/`provide` 以及上游 npm/GitHub 元数据生成机器可读图。

```powershell
.\scripts\Scan-DshPluginEcosystem.ps1 -DshVersion 0.1.5-rc.2 -OutputMarkdown docs\PLUGIN_COMPATIBILITY_MATRIX.md
.\scripts\Test-DshPluginEcosystemPreflight.ps1 -DshVersion 0.1.5-rc.2
```

- 图中包含 `DependsOn`、`RequiresService`、`HostRange`、反向依赖和安装顺序。卸载父插件会先展示全部下游链，确认后按反向顺序移除。
- 升级 DSH 前会重新扫描目标版本的硬阻断项。`UNKNOWN` 不能自动视为兼容，`latest` 也不等于推荐版本。
- `PASS` 只表示同一精确 DSH/插件版本与安装 spec 在 BootReady、plugin tree、HTTP、WebView2、刷新、设置页和重启检查全部真实通过；`WARN`、`BLOCKED`、`UNKNOWN` 都不会被管理器自动升级为兼容。Git 来源还必须由 `pnpm-lock.yaml` 或包元数据锁定 commit。
- 若 `cordis.patch.yml` 引用没有已安装 provider 的 id，完整组合预检将 `BLOCKED`，并保留配置等待人工核对，而不是删除无关插件或静默改写补丁。
- 2026-09-13 提交快照：真实 `web` Profile 的 `plugin list` exit 0，12 个已安装插件的独立依赖链和完整组合均为 `PASS`；没有 `Failed to load plugins` 或 `pending (waiting for service...)`。可复查 [矩阵](PLUGIN_COMPATIBILITY_MATRIX.md)、[预检结果](PLUGIN_PREFLIGHT_0.1.5-rc.2.json) 与 [WebView2 结果](WEBVIEW2_ACCEPTANCE_0.1.5-rc.2.json)。

## 验证边界

- PowerShell 7 运行全部源码回归；Windows PowerShell 5.1 解析全部脚本并运行宿主兼容契约。
- 自动化覆盖源码、隔离 Profile、真实 WebView2、刷新、设置页和重启；托盘与主题视觉恢复仍须按 Windows 桌面发布清单复验。
- 端口归属只接受回环 DSH 命令行特征，且在指定端口时要求完整匹配 `--port <端口>`，避免把 `30801` 误认为 `3080`。

## 文档定位

- [DSH_015_NO_PLUGIN_ACCEPTANCE.md](DSH_015_NO_PLUGIN_ACCEPTANCE.md)：固定 `0.1.5-rc.2` 的核心 CLI/Web 验收边界。
- [PLUGIN_COMPATIBILITY_MATRIX.md](PLUGIN_COMPATIBILITY_MATRIX.md)：从真实 Profile 生成的当前插件矩阵与依赖图。
- [PLUGIN_RC2_UPDATE_AUDIT.md](PLUGIN_RC2_UPDATE_AUDIT.md)：历史 `0.1.1-rc.2` 审计快照，不是当前 `0.1.5-rc.2` 兼容声明。
- [AUDIT.md](AUDIT.md)：历史安全审计快照。
