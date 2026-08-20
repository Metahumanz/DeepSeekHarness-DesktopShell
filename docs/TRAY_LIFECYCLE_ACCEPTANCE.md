# 托盘与运行期生命周期人工验收记录规范

本记录用于 v1.0.4 预发布分支的真实 Windows 验收。源码测试只能证明结构；以下结果必须来自用户实际点击、应用日志和任务管理器/端口观察。

## 安全边界

- 使用用户正常 Profile 做 DesktopShell UI 验收；不得清理、重装或改写 `~\.dsh`、WebView2 数据目录。
- 独立 backend 场景使用临时 `DSH_HOME`，端口使用 3088 或随机空闲端口；不得操作用户正常的 3080 实例以外的进程。
- 不按 `node.exe`、`cmd.exe`、`powershell.exe` 名称杀进程。结束测试前只根据本轮记录的 wrapper/listener PID 操作。

## 每轮记录的证据

从 DesktopShell 日志记录：

- `FORM created instance=<guid>`、`HANDLE created instance=<guid> hwnd=<...>`；
- `HANDLE destroyed instance=<guid> hwnd=<...> recreating=<true/false>`；
- backend 的 `oldWrapperPid`、`oldListenerPid`、`oldPort`；
- backend 的 `targetWrapperPid`、`targetListenerPid`、`targetPort`；
- 恢复时的 `TRAY animation start`、`TRAY animation complete`，或 `TRAY animation cancel reason=...`。

每个场景至少记录：场景编号、DPI、窗口状态、MainForm instance GUID、HANDLE 创建/销毁增量、WebView2 是否重建、wrapper/listener PID、监听端口、是否出现白窗/第二窗口/透明度残留、结果。

## 验收场景

1. 关闭到托盘 → 双击托盘恢复，连续 20 轮。
2. 托盘双击显示 → 隐藏 → 显示，连续 20 轮。
3. 最大化 → 托盘 → 恢复；再最小化 → 双击托盘恢复。
4. WebView2 正在生成内容时隐藏和恢复；内容不丢失、不白屏。
5. 托盘隐藏时打开 Settings：设置窗口可见、可操作、可关闭，不强制恢复主窗口。
6. 125%、150% DPI；双屏不同缩放下重复场景 1–3。
7. 在 Windows“动画效果”关闭时恢复托盘窗口：只执行 `Show`、`Activate`、`BringToFront`，不播放淡入；重新开启后确认淡入恢复。
8. old `3080` → target `3088` 选择“立即应用”：记录 old/target wrapper PID、listener PID、端口及日志阶段，确认旧 3080 listener 先退出，3088 启动后不存在两个 DSH，active 配置与真实 listener 一致。
9. target 启动失败、旧 backend 仍健康时：active 仍为 old runtime；不得导航到 target 端口。
10. restart 或 startup 在不同阶段退出 DesktopShell：不得出现退出后的 backend、wrapper 或 listener 残留。
11. WebView2 重建：健康 backend 的 listener PID 和端口不变，不触发 backend restart。

## 通过标准

- 场景 1–7 中每轮 MainForm instance GUID 不变，没有新的 HANDLE destroy/create，WebView2 不重建，backend wrapper/listener PID 不变。
- 没有白色新窗口、第二窗口、透明度残留；恢复完成后 `Opacity` 回到原始目标值，动画 timer 已停止。
- 场景 8–9 的 old/target 状态与日志、真实监听端口一致；失败时不能把未 ready 的 target 写成 active。
- 所有退出场景的本轮 wrapper/listener 都已退出；不得误伤用户正常 3080 以外的进程。
