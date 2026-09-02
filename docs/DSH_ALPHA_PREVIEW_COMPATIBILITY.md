# DSH alpha 预览兼容快照

> 快照日期：2026-09-02。目标为 npm `alpha` 标签当时解析出的 `0.1.2-alpha.4`。
> 这是一份隔离预览验证记录，不会把 alpha 写入 `testedDshVersions`，也不会改变生产默认
> `0.1.1-rc.2`。

## 验证边界

所有结果均由 `scripts/Test-PluginBootPreflight.ps1` 在全新的临时 `DSH_HOME`、临时
Profile 和随机 loopback 端口中得到。每个通过项至少覆盖：安装、BrowserAuth
ready banner、`303 -> Cookie -> HTTP 200`、稳定运行和进程/端口清理；下表的完整组合还
覆盖 Status Rotator 的重启后配置保持性。

DesktopShell 的 alpha BrowserAuth 启动/导航适配已另行验证，但 alpha 页面的一次性
BrowserAuth URL 不写入日志，也不会用来修改真实 Profile。

## 可组合的 Preview 基线

下面 18 个插件在同一个 `0.1.2-alpha.4` 临时 Profile 中完成了 5 秒稳定启动；
`dsh-status-rotator@0.10.0` 额外通过了配置持久化与重启检查。

| 插件/来源 | 本次解析版本或来源 |
| --- | --- |
| Auto Mode | `@nanmicoder/dsh-auto-mode@0.1.6` |
| Context | `dsh-context@0.40.1` |
| At File | `github:omdsh-dev/dsh-at-file` |
| DSH Market | `dshmarket@1.38.1` |
| Chat Tidy | `dsh-chat-tidy@0.3.0` |
| Cost Meter | `dsh-cost-meter@1.6.12` |
| File Upload | `dsh-file-upload@0.4.3` |
| Skills Manager | `@michengai/dsh-skills-manager@0.1.31` |
| Sentinel | `dsh-sentinel@0.11.0` |
| Dream Skin | `dsh-dream-skin@8.30.1` |
| Status Rotator | `dsh-status-rotator@0.10.0` |
| Archify | `@tt-a1i/archify-dsh@0.1.0` |
| Better Archive | `git+https://github.com/huahai0202/dsh-better-archive.git` |
| Video Preview | `dsh-video-preview@0.1.4` |
| Codex Side Outline | `github:EnkiduGilgamesh/dsh-codex-side-outline` |
| File Mentions | `git+https://github.com/a903067276-rgb/dsh-file-mentions.git` |
| Git Remotes | `github:yq04/dsh-git-remotes` |
| Notification | `git+https://github.com/omdsh-dev/dsh-notification.git` |

`@dsh-plugin/dsh-thought-buddy@0.3.2` 也单独通过了专项验证，但它与 Status Rotator
属于互斥的思考状态 UI；Preview 基线只选 Status Rotator。

GitHub 来源按本次运行时 HEAD 解析，后续再次选择 alpha 或重新安装时必须重跑隔离
preflight，不能把本快照当作永久 ABI 承诺。

## 已确认不应带入 alpha Profile 的项

| 插件 | 结果 | 原因 |
| --- | --- | --- |
| `dsh-better-sidebar@0.17.1` | BootReady 前退出 | `@deepseek-ai/dsh-settings` 不再导出 `settingsNamespace` |
| `dsh-auto-collapse@0.1.6` | BootReady 前退出 | `installSettingsSection` / `settingsNamespace` 导出缺失 |
| `dsh-open-in@0.1.1` | BootReady 前退出 | `settingsNamespace` 导出缺失 |
| `@nanmicoder/dsh-agent-teams@0.1.15` | BootReady 前退出 | `ctx.subagents.registerContinuableSetup` 不存在 |
| `@yuxianglin/dsh-bridge-browser`（本地 `link:`） | BootReady 前退出 | 等待已移除/未提供的 `apiProxy` 服务 |
| Sidebar QA / Office 侧栏扩展 | 不纳入基线 | Sidebar QA `0.4.0` 单独可启动，但与所需的 Better Sidebar 配对后触发 `settingsNamespace` 错误；Office 同样依赖 Better Sidebar |

这些是插件 ABI 迁移问题，不是 DesktopShell 的端口、`--no-open`、WebView2 或 BootReady
协议问题。alpha Preview 必须使用新的隔离 Profile；不要直接复用生产 `web` Profile。
