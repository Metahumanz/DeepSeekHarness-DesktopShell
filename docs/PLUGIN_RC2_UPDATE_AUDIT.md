# DSH 0.1.1-rc.2 插件升级审计

> 审计日期：2026-09-04。结论只适用于 DesktopShell 的 `0.1.1-rc.2` 生产基线；npm 和 GitHub 上游发布变化后，
> 仍须重新执行隔离预检。

## 验证口径

- 先读取 npm peer dependency / engine 或 GitHub release tag，明显要求 DSH `0.1.2` 的版本直接排除。
- 每个候选均在新的临时 `DSH_HOME`、随机 Profile 与随机端口中安装 `@deepseek-ai/dsh-web-app@0.1.1-rc.2` 后验证。
- PASS 表示插件安装成功、Web 返回 BootReady HTTP 200、稳定至少 5 秒且端口已安全释放；不会改动真实 Profile。
- BootReady 不能取代需要交互或视觉检查的功能验收，尤其是 Dream Skin。

## 已纳入目录的升级

| 插件 | 原目录版本/来源 | 已审计 spec | 验证补充 |
| --- | --- | --- | --- |
| 插件市场 | `1.21.2` | `dshmarket@1.41.0` | 单装 PASS；与 Better Sidebar、Skills Manager 组合 PASS |
| Better Sidebar | `0.15.2` | `dsh-better-sidebar@0.17.1` | 单装与核心组合 PASS；不使用最新 `0.18.0` |
| Skills Manager | `0.1.24` | `@michengai/dsh-skills-manager@0.1.38` | 单装与核心组合 PASS |
| @file | 浮动 `0.6.8` 快照 | `github:omdsh-dev/dsh-at-file#v0.7.0` | release tag 单装 PASS |
| 文件提及 | 浮动 `1.0.9` 快照 | `github:a903067276-rgb/dsh-file-mentions#v1.0.13` | release tag 单装 PASS |
| 自动折叠 | 浮动 `0.1.4` 快照 | `github:a179-sanae/dsh-auto-collapse#v0.1.5` | release tag 单装 PASS |
| 侧边大纲 | 浮动 `1.0.0` 快照 | `github:EnkiduGilgamesh/dsh-codex-side-outline#v1.1.1` | release tag 单装 PASS |
| 视频预览 | `0.1.1` | `dsh-video-preview@0.1.4` | 单装 PASS |
| 通知增强 | 浮动 `0.1.3` 快照 | `github:omdsh-dev/dsh-notification#v0.1.4` | release tag 单装 PASS |
| Status Rotator | `0.6.6` | `dsh-status-rotator@0.10.0` | PASS；状态轮换、默认关闭渐变、设置页和重启后配置保持均通过 |
| Context Insight | `0.29.0` | `dsh-context@0.41.3` | 单装 PASS |
| Cost Meter | `1.5.42` | `dsh-cost-meter@1.7.10` | 单装 PASS；源码复核了上游 wrapper 重映射与去重迁移 |
| Dream Skin | `0.4.10` | `dsh-dream-skin@8.30.1` | BootReady PASS；源码确认 sticky restore 与 `/dream-skin/api` host-backed 持久化 |
| 量神 | `0.3.2` | `@linxin666/dsh-liangshen@0.3.14` | 单装 PASS |
| Thought Buddy | `0.2.0` | `@dsh-plugin/dsh-thought-buddy@0.3.3` | 单装 PASS；专项 client 能力检查通过 |

## 暂不升级或保持现状

| 项目 | 结论 | 原因 |
| --- | --- | --- |
| Chat Tidy `0.3.0` | 保持 `^0.2.0` | 包解析完成后 `dsh plugin add` 子进程未退出，触发 180 秒隔离安装超时 |
| Better Sidebar `0.18.0` | 排除 | npm peer dependency 要求 DSH `0.1.2-rc.1` |
| Sidebar QA `0.5.0` | 保持 `0.4.0` | 包声明要求 DSH `>=0.1.2-alpha.1` |
| Auto Mode `0.1.6` | 保持 `^0.1.5` | 包声明要求 DSH `0.1.2-alpha.2` |
| Agent Teams `0.1.15` | 保持 `0.1.14` | 包声明要求 DSH `0.1.2-alpha.2` 的多项 UI/API 服务 |
| Open In、Sidebar Office、Archify、Sentinel | 保持原 spec | npm 当前没有适合 rc.2 的较新发布版本 |
| Rewind、Better Archive、Git Remotes | 保持浮动并提示风险 | GitHub 仓库未发现可采用的 release tag，不能诚实地标为可复现升级 |

## Cost Meter 修复结论

`1.7.10` 已由上游处理 ModLens/wrapper provider：包装样本会改挂到语义上游并以时间窗去重，且自带账本迁移。
因此 DesktopShell 不再对无法确认来源的账本删除 `modlens-*` 桶：自动修复仅在当前安装文件仍证明为受影响旧布局时才运行。

`scripts/Repair-CostMeterLedger.ps1` 仍保留为旧账本迁移工具，但默认只做分析；真正写入需要先 DryRun，
并显式追加 `-ForceLegacyCleanup`。这保留了旧版双计费的可修复路径，同时避免新版 reseller-only 路由被误删。

## 仍需人工完成的事项

Dream Skin 的 8.30.1 已通过启动和源码能力检查，但皮肤切换、跨后端重启恢复与默认皮肤不被错误拉回，
仍须按 [Dream Skin 人工验收表](DREAM_SKIN_ACCEPTANCE.md) 在真实 Windows 桌面完成。
