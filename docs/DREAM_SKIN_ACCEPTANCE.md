# Dream Skin 修复验收（人工 Windows 验收）

> 适用版本：DesktopShell v1.0.2（Dream Skin 固定 commit `28497f52`，含 sticky restore 加固
> 与 host-backed 持久化）。本验收**必须在本机真实 Windows 桌面完成**——托盘、WebView2、
> 连续重启、皮肤恢复属于 GUI 行为，源码级 `-match` 测试不能替代人工验收。

## 前置

1. 从 v1.0.2 分支安装（`install-from-source.bat` 或 `scripts\Install-Desktop.ps1`），或安装
   用户自测构建包；不要动 `~\.dsh`、`webview2-data`。
2. 管理器 → 安装插件 → 选 **14. Dream Skin 主题**（固定 commit 版）。
   若 Profile 里已有旧 0.3.0 实现，应看到升级确认提示：
   `检测到 Dream Skin 0.3.0 旧实现……是否升级到 DesktopShell 审核的固定 commit？` → 选是。
3. 安装后**托盘 → 重启 DSH 后端**，让插件生效。
4. 确认已修实现：管理器菜单 4（诊断）应显示
   `Dream Skin：持久化修复已安装`（或运行：
   `powershell -NoProfile -Command "& 'C:\...\Manage-Dsh.ps1'..."` 对应检查命令）。

## 场景 1：午夜皮肤跨操作保持（核心回归）

1. DSH 界面内选择第三方皮肤「午夜」（midnight）。
2. 依次执行并**每次**确认仍显示「午夜」：

   | 操作 | 次数 | 期望 |
   | --- | --- | --- |
   | 托盘 → 重新加载页面 | 5 | 午夜 |
   | 托盘 → 重启 DSH 后端 | 10 | 午夜（每次重启完等页面恢复后检查） |
   | 退出 DesktopShell 再打开 | 5 | 午夜（壳退出→重新启动→等页面恢复后检查） |
   | 打开/关闭设置页面 | 5 | 午夜 |

3. 任一次不是午夜 → **失败**：记录 `logs\desktop-shell.log` 中该次重启的
   `SNAPSHOT / SNAPSHOT-NEW` 行与 `RESTART phase=*` 行，连同 DSH 后端日志一起反馈。

## 场景 2：默认皮肤不被 sticky restore 拉回（上游保留的边界）

1. 皮肤切回「默认」。
2. 重启 DSH 后端一次，再退出 DesktopShell 重新打开一次。
3. 期望：**保持「默认」**，不能被 sticky restore 强行改回「午夜」。

## 场景 3：host-backed 持久化文件

1. 皮肤选「午夜」后，检查 `$DSH_HOME\dream-skin.json` 存在且包含 Dream Skin 状态
   （皮肤选择被持久化，供跨宿主恢复）：

   ```powershell
   Get-Content "$env:USERPROFILE\.dsh\dream-skin.json" -Raw
   # 期望：JSON 中包含皮肤/主题相关字段（如 theme/skin 名称），且与当前选择一致
   ```

2. 该文件缺失或内容与当前选择不符 → 记录并反馈（持久化未生效）。

## 通过标准

- 场景 1 全部 25 次操作（5+10+5+5）每次均为「午夜」；
- 场景 2 重启后保持「默认」；
- 场景 3 `dream-skin.json` 存在且状态一致。

三项全过才算 Dream Skin 修复验收通过；用户本机验收通过前**不发布 v1.0.2**。
