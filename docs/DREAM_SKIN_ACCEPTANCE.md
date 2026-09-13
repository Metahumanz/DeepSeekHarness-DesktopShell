# Dream Skin 修复验收（人工 Windows 回归检查表）

> 当前适用基线：从当前 `web` Profile 的动态扫描矩阵取得 Dream Skin 的**已安装精确 spec**；它不是
> 仓库里的固定目录条目。只有该 spec 在固定 DSH `0.1.5-rc.2` 的完整 preflight 中为 `PASS`，才可进入本检查表。
> 本检查表**必须在本机真实 Windows 桌面完成**——托盘、WebView2、连续重启、皮肤恢复属于 GUI 行为，源码级测试不能替代人工验收。
> 历史版本与旧 spec 仅是历史记录，不能作为当前推荐或兼容结论。
> 未取得用户明确 25 次验收记录前，
> 不得声称“验收通过”。

## 前置

1. 安装当前发布包，或从当前分支源码安装；不要动 `~/.dsh`、`webview2-data`。
2. 运行 `Scan-DshPluginEcosystem.ps1`，在 [插件兼容矩阵](PLUGIN_COMPATIBILITY_MATRIX.md) 中确认当前
   `dsh-dream-skin` 行的精确安装 spec 和状态为 `PASS`。升级或重新安装后，必须重新扫描和 preflight，不能复用旧版本号。
3. 安装后**托盘 → 重启 DSH 后端**，让插件生效。
4. 确认已修实现：管理器菜单 4（诊断）应显示
   `Dream Skin：持久化修复已安装`。

## 场景 1：午夜皮肤跨操作保持（核心回归）

1. DSH 界面内选择第三方皮肤「午夜」（midnight）。
2. 依次执行并**每次**确认仍显示「午夜」：

   | 操作 | 次数 | 期望 |
   | --- | --- | --- |
   | 托盘 → 重新加载页面 | 5 | 午夜 |
   | 托盘 → 重启 DSH 后端 | 10 | 午夜（每次重启完等页面恢复后检查） |
   | 退出 DesktopShell 再打开 | 5 | 午夜（壳退出→重新启动→等页面恢复后检查） |
   | 打开/关闭设置页面 | 5 | 午夜 |

3. 任一次不是午夜 → **失败**：记录 `logs/desktop-shell.log` 中该次重启的
   `SNAPSHOT / SNAPSHOT-NEW` 行与 `RESTART phase=*` 行，连同 DSH 后端日志一起反馈。

## 场景 2：默认皮肤不被 sticky restore 拉回（上游保留的边界）

1. 皮肤切回「默认」。
2. 重启 DSH 后端一次，再退出 DesktopShell 重新打开一次。
3. 期望：**保持「默认」**，不能被 sticky restore 强行改回「午夜」。

## 场景 3：host-backed 持久化文件

1. 皮肤选「午夜」后，检查 `$DSH_HOME/dream-skin.json` 存在且包含 Dream Skin 状态：

   ```powershell
   Get-Content "$env:USERPROFILE/.dsh/dream-skin.json" -Raw
   # 期望：JSON 中包含皮肤/主题相关字段，且与当前选择一致
   ```

2. 该文件缺失或内容与当前选择不符 → 记录并反馈（持久化未生效）。

## 记录标准

- 场景 1 全部 25 次操作（5+10+5+5）每次均为「午夜」；
- 场景 2 重启后保持「默认」；
- 场景 3 `dream-skin.json` 存在且状态一致。

三项全过才算本轮 Dream Skin 人工回归通过；验收记录需由用户在下方追加签名/日期，
否则保持“未验收”状态。

### 验收记录

- 日期：
- 操作人：
- 结果：□ 通过　□ 未通过
