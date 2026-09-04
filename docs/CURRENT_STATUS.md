# 当前状态与维护基线

> 更新日期：2026-09-04。本页描述此仓库工作树的维护基线；第三方插件和 npm dist-tag 会随上游变化，
> 因此不把本页视为对未来上游版本的兼容承诺。

## 发布与 DSH 兼容基线

- DesktopShell 版本：`1.0.8`（唯一来源：根目录 `VERSION`）。
- 默认 DSH：`0.1.1-rc.2`；最低兼容 DSH：`0.1.0-rc.7`。
- 已列入测试基线：`0.1.0-rc.7`、`0.1.0-rc.8`、`0.1.1-rc.1`、`0.1.1-rc.2`。
- 版本和通道元数据的唯一来源是 `COMPATIBILITY.json`。`latest`/`alpha` 仅在用户主动选择时解析，
  不会静默改写现有 Profile。

## 验证边界

- PowerShell 7 运行全部 **40** 项源码回归；Windows PowerShell 5.1 解析全部脚本，并运行 7 项
  宿主兼容回归。
- 自动化覆盖源码和可隔离行为；托盘、WebView2、连续重启和 Dream Skin 的视觉恢复仍须在真实 Windows
  桌面按 [Dream Skin 人工验收表](DREAM_SKIN_ACCEPTANCE.md) 记录。
- 端口归属只接受回环 DSH 命令行特征，且在指定端口时要求完整匹配 `--port <端口>`，避免把
  `30801` 误认为 `3080`。
- Cost Meter 的自动账本修复会先限制输入大小（最多 16 Mi 字符），并且只在当前安装源码仍可证明为受影响旧布局时才会写入；新版上游的 wrapper 去重与迁移保持原样。

## 插件目录与可复现性

管理器当前提供 26 项可移植推荐插件。`Installed` 表示目录中已审计的目标版本；它不会自动改动真实
Profile，也不等同于用户机器上的安装状态。

- 精确 npm 版本和带版本的 npm spec 由目录明确声明。
- 目录优先采用已隔离验证的精确 npm 版本或 GitHub release tag，避免未来发布静默改变结果。
- 仍有 3 个 GitHub spec 没有 tag 或 commit，目录会明确标作“GitHub 浮动引用”；安装时会解析上游默认分支，
  不应被理解为固定兼容版本。
- 需要可复现安装时，应在“额外插件”步骤提供精确 tag/commit spec，并运行
  `scripts/Test-PluginBootPreflight.ps1` 的隔离 preflight；日常安装成功不等同于运行兼容。

## 文档定位

- [AUDIT.md](AUDIT.md)：v1.0.4 的历史审计快照，保留旧版本风险和修复记录。
- [DREAM_SKIN_ACCEPTANCE.md](DREAM_SKIN_ACCEPTANCE.md)：当前 Dream Skin 的人工 Windows 验收清单。
- [PLUGIN_RC2_UPDATE_AUDIT.md](PLUGIN_RC2_UPDATE_AUDIT.md)：当前 rc.2 插件升级筛选、隔离验证和排除项。
- [DSH_ALPHA_PREVIEW_COMPATIBILITY.md](DSH_ALPHA_PREVIEW_COMPATIBILITY.md)：alpha 通道的历史/预览快照，
  不是生产兼容声明。
