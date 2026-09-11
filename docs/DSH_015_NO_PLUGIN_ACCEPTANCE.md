# DSH 0.1.5-rc.1 无插件兼容验收

适用目标：DesktopShell 工作树 + 官方 `@deepseek-ai/dsh@0.1.5-rc.1`。

本页只记录**全新、无插件 Profile**的兼容边界。npm 上没有裸版本 `0.1.5`；本次以 2026-09-11 的
官方 `latest` 精确解析结果 `0.1.5-rc.1` 为目标，不包含 `next` 通道的 `0.1.5-rc.2`。

## 验收范围

- 每次运行使用新的临时 `DSH_HOME`、新的 `web` Profile 和随机回环端口。
- 不传 `-RunPlugins`，不读取、复制或修改已有 `DSH_HOME` / Profile。
- 启动后必须确认 Profile 的 `dependencies` 为空，bundle 仅为
  `@deepseek-ai/dsh-base` 与 `@deepseek-ai/dsh-web-app`，`cordis.patch.yml` 为空数组。
- 覆盖 CLI `--version`、`--profile web --help`（含 `--port` / `--no-open`）、ready banner、
  BrowserAuth 跳转后的 HTTP 200，以及连续 10 秒 HTTP 200。
- 结束时只停止本次创建的进程树并释放随机端口。

这不是第三方插件、现有会话、主题、附件或 DesktopShell GUI 视觉回归的兼容声明。已有 Profile 的
`dshVersion` 不会因 DesktopShell 默认版本更新而被自动改写。

## 复跑命令

```powershell
.\scripts\Test-Dsh015NoPluginLocal.ps1
```

可选参数：`-TimeoutSeconds 120`、`-StableSeconds 10`、`-Port <随机未占用端口>`；仅在需要保留失败
现场时传 `-KeepTemp`。该脚本不提供接入既有 Profile 或启用插件的参数。

## 2026-09-11 实测记录

在临时空 Profile 上通过：

- `npx -y @deepseek-ai/dsh@0.1.5-rc.1 --version` 输出目标版本；
- `--profile web --help` 包含 `--port` 与 `--no-open`；
- `--profile web --port <随机端口> --no-open` 输出 loopback ready URL；
- BrowserAuth 跳转后的请求连续 10 次返回 HTTP 200；
- Profile 清单为零用户依赖，仅含两个 DSH 核心 bundle，空补丁层；
- 测试后精确停止启动包装进程，监听端口已释放。

因此 `COMPATIBILITY.json` 将 `0.1.5-rc.1` 设为新设置的默认 npx 版本，并将其列入已测版本和
已确认 `--no-open` 能力表；历史 rc.2 插件目录保持不变，不能据此推断插件可用于 0.1.5。
