# DSH 0.1.5-rc.2 核心兼容验收

适用目标：DesktopShell 工作树 + 官方 `@deepseek-ai/dsh@0.1.5-rc.2`。

本页记录固定目标版本的核心基线。`latest` 仅保留为用户主动选择后的可选上游通道，不能替代此处的精确版本，也不会被管理器自动设为推荐版本。

## 验收范围

- 每次运行使用新的临时 `DSH_HOME`、新的 `web` Profile 和随机回环端口。
- 首先不读取、复制或修改既有插件、主题、会话或 Profile。
- 启动后确认 Profile 的 `dependencies` 为空，bundle 仅为 `@deepseek-ai/dsh-base` 与 `@deepseek-ai/dsh-web-app`，`cordis.patch.yml` 为空数组。
- 覆盖 CLI `--version`、`--profile web --help`（含 `--port` / `--no-open`），以及正式命令 `--profile web --no-open --port <随机端口>`。
- 就绪条件是本次启动输出的 loopback `dsh web: http://127.0.0.1:<port>/?token=...` 完整 URL 经 BrowserAuth 跳转后返回 HTTP 200，并持续 10 秒稳定；不得以“端口已监听”替代 BootReady。
- BrowserAuth token 只用于本次请求/导航，不能写入设置、日志或预检结果。
- 结束时只停止本次创建的进程树并释放随机端口。

这不是第三方插件、既有会话、主题、附件或 DesktopShell GUI 视觉回归的兼容声明。已有 Profile 的 `dshVersion` 不会因默认版本更新而被自动改写。

## 复跑命令

```powershell
.\scripts\Test-Dsh015NoPluginLocal.ps1 -DshVersion 0.1.5-rc.2
```

可选参数：`-TimeoutSeconds 120`、`-StableSeconds 10`、`-Port <随机未占用端口>`；仅在需要保留失败现场时传 `-KeepTemp`。该脚本不提供接入既有 Profile 或启用插件的参数。

## 2026-09-13 基线记录

在临时空 Profile 上通过：

- `npx -y @deepseek-ai/dsh@0.1.5-rc.2 --version` 输出目标版本；
- `--profile web --help` 包含 `--port` 与 `--no-open`；
- `--profile web --no-open --port <随机端口>` 输出经验证的 loopback ready URL；
- BrowserAuth 跳转后的请求连续稳定返回 HTTP 200；
- Profile 清单为零用户依赖，仅含两个 DSH 核心 bundle，空补丁层；
- 测试后精确停止启动包装进程，监听端口已释放。

因此 `COMPATIBILITY.json` 将 `0.1.5-rc.2` 设为新设置的默认 npx 版本，并将其列入已测版本和已确认 `--no-open` 能力表。第三方插件必须通过动态依赖图和完整 preflight 才能取得 `PASS`，不能由该核心基线推断。

## 2026-09-13 DesktopShell / WebView2 记录

使用新建测试 `DSH_HOME` 和随机端口启动实际 DesktopShell 后，宿主只接受该进程的 `dsh web: http://127.0.0.1:<port>/?token=...` 完整 URL；宿主日志记录 `BOOTREADY` 与 WebView2 的成功导航，但不记录 URL 或 token。没有另开系统浏览器。独立的 `Test-DshWebView2Acceptance.ps1` 还对相同 rc.2 契约验证了 WebView2 的首次认证、主界面、刷新及设置入口；结果文件只保存布尔检查。
