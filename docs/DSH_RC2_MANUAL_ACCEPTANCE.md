# DSH 0.1.1-rc.2 兼容与插件收口验收

适用目标：DesktopShell v1.0.6 候选包 + DSH `0.1.1-rc.2`。本清单沿用 rc.1 的临时目录和精确端口清理规则；本版本不修改 DesktopShell 启动/重启状态机。

## 1. CLI/Web 基线

```powershell
.\scripts\Test-DshRc2Local.ps1 -DshVersion 0.1.1-rc.2
```

必须记录以下结果：

- `npx -y @deepseek-ai/dsh@0.1.1-rc.2 --version` 输出 rc.2；
- `--profile web --help` 含 `--port` 和 `--no-open`；
- `--profile web --port <随机端口> --no-open`；
- 输出 `dsh web: http://127.0.0.1:<端口>` ready banner；
- HTTP 200，连续稳定运行至少 10 秒；
- 正常退出后精确测试端口释放。

## 2. DesktopShell 启动、重启和退出

用重新编译的 v1.0.6 x64 候选 EXE，设置 DSH 版本 `0.1.1-rc.2`、Profile `web` 和临时端口：

1. DesktopShell 正常启动并显示 DSH Web；
2. 托盘菜单执行“重启 DSH 后端”，确认旧后端退出、新后端出现 rc.2 ready banner、HTTP 200，页面恢复；
3. 重启过程中不出现假失败覆盖层，日志能区分旧/新 backend generation；
4. 选择正常退出，DesktopShell 和 DSH 后端均退出，测试端口释放。

## 3. rc.2 附件/图片回归

在 DSH Web 内分别验证普通附件和图片附件：

- 选择/拖入一个普通文本或代码文件，附件卡片显示，发送后模型能读取；
- 选择/拖入一张 PNG/JPEG 图片，缩略图或图片附件状态正确，发送后模型能收到图片；
- 取消附件、重复添加、刷新/重启后再次添加均不阻塞 Web；
- 记录浏览器控制台和 `dsh-*.log` 中无 rc.2 附件/图片异常。

这里不添加 DesktopShell 图片适配：图片处理归 DSH rc.2 本身，DesktopShell 只验证 WebView 边界和后端生命周期。

## 4. 插件隔离验收

每个推荐插件单独运行，禁止把 Status Rotator 与 Thought Buddy 放在同一个正常支持组合中：

```powershell
.\scripts\Test-PluginBootPreflight.ps1 `
  -PluginSpec 'dsh-status-rotator@^0.6.6' `
  -DshVersion '0.1.1-rc.2' `
  -Validation status-rotator `
  -StableSeconds 10

.\scripts\Test-PluginBootPreflight.ps1 `
  -PluginSpec '@dsh-plugin/dsh-thought-buddy@^0.2.0' `
  -DshVersion '0.1.1-rc.2' `
  -Validation thought-buddy `
  -StableSeconds 10
```

每次都必须使用临时 `DSH_HOME`、临时 Profile、随机端口，并完成 plugin add → `dsh web --no-open` → ready banner → HTTP 200 → 稳定 10 秒 → 正常退出 → 端口释放。

Status Rotator 还必须确认：梗词轮换、`Deep diving...` 被替换、默认渐变关闭、设置页存在、重启后配置保留。Thought Buddy 单独验证，不与 Status Rotator 同时启动。

已有 Profile 若同时安装两者，管理器只提示冲突并让用户选择保留项；不会在检测时静默卸载。
