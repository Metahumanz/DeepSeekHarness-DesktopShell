# DSH 0.1.5-rc.2 插件兼容矩阵

> 本文件由 `scripts/Scan-DshPluginEcosystem.ps1` 从真实 profile 生成。它不是静态推荐表；`PASS` 仅来自同一精确 DSH 版本、同一插件版本且包含 BootReady、plugin tree、HTTP、WebView2、刷新、设置页和重启检查的 preflight 证据。

目标 DSH：`0.1.5-rc.2`  \
Profile：`web`  \
Profile 状态：**PASS**  \
`plugin list`：已执行（exit 0）  \
生成时间：`2026-09-13T03:19:39.878Z`

| 插件 | 已装版本 | 上游最新 | 依赖服务 | 依赖插件 | 0.1.5-rc.2 证据 | 状态 |
| --- | --- | --- | --- | --- | --- | --- |
| `@dsh-plugin/dsh-loader` | `1.3.5` | 1.3.5 | webServer | — | 完整精确 preflight 通过 | **PASS** |
| `@michengai/dsh-skills-manager` | `0.1.50` | 0.1.50<br>v0.1.50 | locale, sessions, skills, slots, tools, webRuntime, webServer | — | peerDependencies.@deepseek-ai/dsh-client-locale 满足 0.1.0-rc.8 \|\| 0.1.1-rc.2 \|\| 0.1.2-rc.1 \|\| 0.1.5-rc.1 \|\| 0.1.5-rc.2<br>peerDependencies.@deepseek-ai/dsh-client-ui-primitives 满足 0.1.0-rc.8 \|\| 0.1.1-rc.2 \|\| 0.1.2-rc.1 \|\| 0.1.5-rc.1 \|\| 0.1.5-rc.2<br>peerDependencies.@deepseek-ai/dsh-client-ui-slots 满足 0.1.0-rc.8 \|\| 0.1.1-rc.2 \|\| 0.1.2-rc.1 \|\| 0.1.5-rc.1 \|\| 0.1.5-rc.2<br>peerDependencies.@deepseek-ai/dsh-host-webserver 满足 0.1.0-rc.8 \|\| 0.1.1-rc.2 \|\| 0.1.2-rc.1 \|\| 0.1.5-rc.1 \|\| 0.1.5-rc.2<br>peerDependencies.@deepseek-ai/dsh-session 满足 0.1.0-rc.8 \|\| 0.1.1-rc.2 \|\| 0.1.2-rc.1 \|\| 0.1.5-rc.1 \|\| 0.1.5-rc.2<br>peerDependencies.@deepseek-ai/dsh-skill 满足 0.1.0-rc.8 \|\| 0.1.1-rc.2 \|\| 0.1.2-rc.1 \|\| 0.1.5-rc.1 \|\| 0.1.5-rc.2<br>peerDependencies.@deepseek-ai/dsh-tools 满足 0.1.0-rc.8 \|\| 0.1.1-rc.2 \|\| 0.1.2-rc.1 \|\| 0.1.5-rc.1 \|\| 0.1.5-rc.2<br>peerDependencies.@deepseek-ai/dsh-web-app 满足 0.1.0-rc.8 \|\| 0.1.1-rc.2 \|\| 0.1.2-rc.1 \|\| 0.1.5-rc.1 \|\| 0.1.5-rc.2<br>完整精确 preflight 通过 | **PASS** |
| `@tt-a1i/archify-dsh` | `0.1.0` | 0.1.0 | — | — | 完整精确 preflight 通过 | **PASS** |
| `@xsj/dsh-rewind` | `2.1.2` | 未获取 | agents, sessions, slots, webServer | — | pnpm-lock.yaml 锁定 Git commit 299b1b486b6af88f5db570f0d86bf9f8e7490bcf<br>完整精确 preflight 通过 | **PASS** |
| `dsh-better-archive` | `0.7.7` | 未获取 | locale, sessionPersistence, sessions, slots, webServer, workspaceRegistry | — | peerDependencies.@deepseek-ai/dsh-client-locale 满足 ^0.1.5-alpha.1<br>pnpm-lock.yaml 锁定 Git commit deef9769843dea67764bdc323e89eee2553c4d5b<br>完整精确 preflight 通过 | **PASS** |
| `dsh-context` | `0.50.0` | 0.50.0 | locale, sessionProjections, slots | — | peerDependencies.@deepseek-ai/dsh-client-ui-primitives 满足 >=0.1.2-rc.1<br>peerDependencies.@deepseek-ai/dsh-session 满足 >=0.1.2-rc.1<br>peerDependencies.@deepseek-ai/dsh-settings 满足 >=0.1.2-rc.1<br>完整精确 preflight 通过 | **PASS** |
| `dsh-cost-meter` | `1.7.21` | 1.7.21 | — | — | dsh.compatibility.dsh 满足 >=0.1.0-rc.5<br>peerDependencies.@deepseek-ai/dsh-credentials 满足 ^0.1.0-rc.6 \|\| ^0.1.1-0 \|\| ^0.1.2-0 \|\| ^0.1.3-0 \|\| ^0.1.5-0<br>peerDependencies.@deepseek-ai/dsh-home-paths 满足 ^0.1.0-rc.6 \|\| ^0.1.1-0 \|\| ^0.1.2-0 \|\| ^0.1.3-0 \|\| ^0.1.5-0<br>完整精确 preflight 通过 | **PASS** |
| `dsh-dream-skin` | `9.10.0` | 9.10.0 | locale, slots, theme, webRuntime, webServer | — | peerDependencies.@deepseek-ai/dsh-client-locale 满足 ^0.1.0-rc.6<br>peerDependencies.@deepseek-ai/dsh-client-runtime 满足 ^0.1.0-rc.6<br>peerDependencies.@deepseek-ai/dsh-client-ui-settings 满足 ^0.1.0-rc.6<br>peerDependencies.@deepseek-ai/dsh-client-ui-settings-general 满足 ^0.1.0-rc.6<br>peerDependencies.@deepseek-ai/dsh-client-ui-theme 满足 ^0.1.0-rc.6<br>完整精确 preflight 通过 | **PASS** |
| `dsh-notification` | `0.1.4` | 0.1.1 | invariants, locale, sessionProjections, sessions, slots | — | pnpm-lock.yaml 锁定 Git commit 675aab9b43d5011738feb6185281596c0365ccba<br>完整精确 preflight 通过 | **PASS** |
| `dsh-sentinel` | `0.11.1` | 0.11.1 | agentDefaultModel, agents, locale, slots, tools | — | 完整精确 preflight 通过 | **PASS** |
| `dsh-status-rotator` | `0.17.2` | 0.17.2 | locale, slots | — | 完整精确 preflight 通过 | **PASS** |
| `dshmarket` | `1.45.1` | 1.45.1 | locale, slots, theme | — | peerDependencies.@deepseek-ai/dsh-settings 满足 ^0.1.0-rc.7 \|\| ^0.1.1-rc.2 \|\| ^0.1.2-alpha.2<br>完整精确 preflight 通过 | **PASS** |

## 安装顺序与反向依赖

- `@dsh-plugin/dsh-loader` → 下游：无
- `@michengai/dsh-skills-manager` → 下游：无
- `@tt-a1i/archify-dsh` → 下游：无
- `@xsj/dsh-rewind` → 下游：无
- `dsh-better-archive` → 下游：无
- `dsh-context` → 下游：无
- `dsh-cost-meter` → 下游：无
- `dsh-dream-skin` → 下游：无
- `dsh-notification` → 下游：无
- `dsh-sentinel` → 下游：无
- `dsh-status-rotator` → 下游：无
- `dshmarket` → 下游：无

状态含义：`PASS` = 完整精确 preflight；`WARN` = 元数据支持但未完成完整 preflight；`BLOCKED` = 明确 HostRange/服务/补丁阻断；`UNKNOWN` = 不能据现有证据判断，绝不自动当作兼容。
