# Third-Party Notices

DeepSeek Harness DesktopShell 使用并分发以下第三方组件。各组件按自身许可条款授权。

## DeepSeek Harness（图标来源）

- 项目：<https://github.com/deepseek-ai/deepseek-harness>
- 组件：`apps/web/public/favicon.svg`（本项目 `assets/` 下图标的几何来源，见 `ICON_SOURCE.txt`）
- 许可：MIT License，Copyright (c) 2026 DeepSeek

```text
MIT License

Copyright (c) 2026 DeepSeek

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

## Microsoft Edge WebView2 SDK

- 组件：`Microsoft.Web.WebView2` NuGet 包 1.0.4078.44
  （`Microsoft.Web.WebView2.Core.dll`、`Microsoft.Web.WebView2.WinForms.dll`、`WebView2Loader.dll`，
  发布包随包分发）
- 来源：<https://www.nuget.org/packages/Microsoft.Web.WebView2/1.0.4078.44>
- 许可：Microsoft 软件许可条款（Microsoft Edge WebView2），详见 NuGet 包内
  LICENSE 文件与 <https://aka.ms/webview2license>
- 说明：DesktopShell 按固定版本 1.0.4078.44 从同一 NuGet 包目录取三件套（可复现构建），
  不混用其它来源/版本的 DLL。

## 运行时依赖（不随包分发，由用户环境提供）

- PowerShell 7（<https://github.com/PowerShell/PowerShell>，MIT License）
- Node.js / npm / npx（<https://nodejs.org/>，按 Node.js 自身许可）
- .NET Framework 4.x csc.exe（Windows 组件）

## 社区插件（用户主动安装，不随包分发）

`scripts/Manage-Dsh.ps1` 的插件目录指向第三方社区插件（npm 包或 GitHub 仓库）。
推荐组合锁定精确版本/commit，可选插件按用户选择安装。各插件按各自仓库的许可授权；
升级锁定版本前应重新审核。

## 许可证变更说明

本项目的桌面壳代码（`src/`）、脚本（`scripts/`）与文档按仓库根目录 `LICENSE`
（MIT License，Copyright (c) 2026 Metahumanz and DeepSeek Harness DesktopShell contributors）
授权。图标几何源自 DeepSeek Harness 官方 favicon，保留其上方的 MIT 版权声明。
