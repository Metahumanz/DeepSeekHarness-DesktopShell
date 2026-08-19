using System;
using System.Collections;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.Net.Sockets;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;
using System.Threading.Tasks;
using System.Web.Script.Serialization;
using System.Windows.Forms;
using Microsoft.Win32;
using Microsoft.Web.WebView2.Core;
using Microsoft.Web.WebView2.WinForms;

[assembly: System.Reflection.AssemblyTitle("DeepSeek Harness DesktopShell")]
[assembly: System.Reflection.AssemblyProduct("DeepSeek Harness DesktopShell")]
// AssemblyVersion / AssemblyFileVersion / AssemblyInformationalVersion 由
// 构建脚本（Build-Release.ps1 / Install-Desktop.ps1）生成的 VersionInfo.cs 注入，
// 保证 release 包里的 EXE 版本与 version.txt 一致。

namespace DeepSeekHarnessDesktop
{
    internal sealed class AppSettings
    {
        public int port { get; set; }
        public string workingDirectory { get; set; }
        public string closeAction { get; set; }
        public bool restoreWindowBounds { get; set; }
        public bool hasSavedWindowBounds { get; set; }
        public int windowX { get; set; }
        public int windowY { get; set; }
        public int windowWidth { get; set; }
        public int windowHeight { get; set; }
        public bool windowMaximized { get; set; }
        public bool developerMode { get; set; }
        public string dshVersion { get; set; }
        public string dshPath { get; set; }
        public string dshRunnerMode { get; set; }
        public string acceptedDshCommandPath { get; set; }
        public string acceptedDshCommandVersion { get; set; }
        public string profileName { get; set; }

        public AppSettings()
        {
            port = 3080;
            workingDirectory = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
            closeAction = "ask";
            restoreWindowBounds = true;
            hasSavedWindowBounds = false;
            windowX = 0;
            windowY = 0;
            windowWidth = 1440;
            windowHeight = 900;
            windowMaximized = false;
            developerMode = false;
            dshVersion = DshProcessManager.VerifiedDshVersion;
            dshPath = "";
            dshRunnerMode = "auto";
            acceptedDshCommandPath = "";
            acceptedDshCommandVersion = "";
            profileName = "web";
        }

        public static AppSettings Load(string path)
        {
            try
            {
                if (!File.Exists(path)) return new AppSettings();
                string json = File.ReadAllText(path, Encoding.UTF8);
                JavaScriptSerializer serializer = new JavaScriptSerializer();
                AppSettings value = serializer.Deserialize<AppSettings>(json);
                if (value == null) return new AppSettings();

                if (value.port < 1 || value.port > 65535) value.port = 3080;
                if (String.IsNullOrWhiteSpace(value.workingDirectory))
                    value.workingDirectory = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
                if (value.closeAction != "ask" && value.closeAction != "tray" && value.closeAction != "exit")
                    value.closeAction = "ask";
                if (value.windowWidth < 800 || value.windowWidth > 10000) value.windowWidth = 1440;
                if (value.windowHeight < 600 || value.windowHeight > 10000) value.windowHeight = 900;
                if (String.IsNullOrWhiteSpace(value.dshVersion))
                    value.dshVersion = DshProcessManager.VerifiedDshVersion;
                value.dshVersion = NormalizeDshVersion(value.dshVersion);
                if (value.dshPath == null) value.dshPath = "";
                if (value.acceptedDshCommandPath == null) value.acceptedDshCommandPath = "";
                if (value.acceptedDshCommandVersion == null) value.acceptedDshCommandVersion = "";
                if (value.dshRunnerMode != "command" && value.dshRunnerMode != "npx" && value.dshRunnerMode != "auto")
                    value.dshRunnerMode = "auto";
                value.profileName = NormalizeProfileName(value.profileName);

                // Older DesktopShell builds used (-1,-1) as "no saved position", which broke legitimate
                // negative monitor coordinates. Migrate old settings once to an explicit flag.
                if (json.IndexOf("\"hasSavedWindowBounds\"", StringComparison.OrdinalIgnoreCase) < 0)
                {
                    value.hasSavedWindowBounds = !(value.windowX == -1 && value.windowY == -1);
                    if (!value.hasSavedWindowBounds)
                    {
                        value.windowX = 0;
                        value.windowY = 0;
                    }
                }

                return value;
            }
            catch
            {
                return new AppSettings();
            }
        }

        public AppSettings Clone()
        {
            AppSettings copy = new AppSettings();
            copy.CopyFrom(this);
            return copy;
        }

        public void CopyFrom(AppSettings other)
        {
            if (other == null) return;
            port = other.port;
            workingDirectory = other.workingDirectory;
            closeAction = other.closeAction;
            restoreWindowBounds = other.restoreWindowBounds;
            hasSavedWindowBounds = other.hasSavedWindowBounds;
            windowX = other.windowX;
            windowY = other.windowY;
            windowWidth = other.windowWidth;
            windowHeight = other.windowHeight;
            windowMaximized = other.windowMaximized;
            developerMode = other.developerMode;
            dshVersion = NormalizeDshVersion(other.dshVersion);
            dshPath = other.dshPath ?? "";
            dshRunnerMode = (other.dshRunnerMode == "command" || other.dshRunnerMode == "npx") ? other.dshRunnerMode : "auto";
            acceptedDshCommandPath = other.acceptedDshCommandPath ?? "";
            acceptedDshCommandVersion = other.acceptedDshCommandVersion ?? "";
            profileName = NormalizeProfileName(other.profileName);
        }

        public static string NormalizeDshVersion(string value)
        {
            string fallback = DshProcessManager.VerifiedDshVersion;   // 单一来源：COMPATIBILITY.json
            string version = String.IsNullOrWhiteSpace(value) ? fallback : value.Trim();
            foreach (char c in version)
            {
                if (!(Char.IsLetterOrDigit(c) || c == '.' || c == '-' || c == '_' || c == '+'))
                    return fallback;
            }
            return version;
        }

        public static string NormalizeProfileName(string value)
        {
            string profile = String.IsNullOrWhiteSpace(value) ? "web" : value.Trim();
            foreach (char c in profile)
            {
                if (!(Char.IsLetterOrDigit(c) || c == '-' || c == '_')) return "web";
            }
            return IsReservedProfileName(profile) ? "web" : profile;
        }

        // 官方 DSH 禁止 node_modules；Windows 设备名（CON/PRN/AUX/NUL/COM1-9/LPT1-9）不能作目录名
        private static bool IsReservedProfileName(string profile)
        {
            string lower = profile.ToLowerInvariant();
            if (lower == "node_modules" || lower == "con" || lower == "prn" ||
                lower == "aux" || lower == "nul") return true;
            if ((lower.StartsWith("com", StringComparison.Ordinal) ||
                 lower.StartsWith("lpt", StringComparison.Ordinal)) && lower.Length == 4)
            {
                int n;
                if (Int32.TryParse(lower.Substring(3), out n) && n >= 1 && n <= 9) return true;
            }
            return false;
        }

        public void Save(string path)
        {
            string dir = Path.GetDirectoryName(path);
            if (!Directory.Exists(dir)) Directory.CreateDirectory(dir);

            JavaScriptSerializer serializer = new JavaScriptSerializer();
            string json = serializer.Serialize(this);
            string temp = path + ".tmp-" + Guid.NewGuid().ToString("N");
            File.WriteAllText(temp, json, new UTF8Encoding(false));

            try
            {
                if (File.Exists(path))
                    File.Replace(temp, path, null);
                else
                    File.Move(temp, path);
            }
            catch
            {
                try
                {
                    File.Copy(temp, path, true);
                    File.Delete(temp);
                }
                catch
                {
                    try { if (File.Exists(temp)) File.Delete(temp); } catch { }
                    throw;
                }
            }
        }
    }

    internal static class ThemeHelper
    {
        [DllImport("user32.dll")]
        private static extern bool SetProcessDPIAware();

        [DllImport("user32.dll")]
        private static extern bool SetProcessDpiAwarenessContext(IntPtr value);

        [DllImport("dwmapi.dll")]
        private static extern int DwmSetWindowAttribute(IntPtr hwnd, int attribute, ref int value, int size);

        [DllImport("uxtheme.dll", CharSet = CharSet.Unicode)]
        private static extern int SetWindowTheme(IntPtr hwnd, string pszSubAppName, string pszSubIdList);

        [DllImport("user32.dll")]
        private static extern IntPtr SendMessage(IntPtr hwnd, int msg, IntPtr wParam, IntPtr lParam);

        private const int WM_THEMECHANGED = 0x031A;

        public static void EnablePerMonitorV2()
        {
            try
            {
                if (!SetProcessDpiAwarenessContext(new IntPtr(-4))) SetProcessDPIAware();
            }
            catch
            {
                try { SetProcessDPIAware(); } catch { }
            }
        }

        public static bool IsDark()
        {
            try
            {
                using (RegistryKey key = Registry.CurrentUser.OpenSubKey(
                    @"Software\Microsoft\Windows\CurrentVersion\Themes\Personalize"))
                {
                    if (key == null) return false;
                    object raw = key.GetValue("AppsUseLightTheme");
                    if (raw == null) return false;
                    return Convert.ToInt32(raw) == 0;
                }
            }
            catch { return false; }
        }

        public static void ApplyWindowChrome(Form form, bool dark)
        {
            if (form == null || !form.IsHandleCreated) return;
            int enabled = dark ? 1 : 0;
            try
            {
                if (DwmSetWindowAttribute(form.Handle, 20, ref enabled, sizeof(int)) != 0)
                    DwmSetWindowAttribute(form.Handle, 19, ref enabled, sizeof(int));
            }
            catch { }

            int rounded = 2;
            try { DwmSetWindowAttribute(form.Handle, 33, ref rounded, sizeof(int)); } catch { }
        }

        public static void ApplyNativeControlTheme(Control control, bool dark)
        {
            if (control == null) return;
            try
            {
                if (control.IsHandleCreated)
                {
                    if (control is TextBox || control is ComboBox || control is NumericUpDown)
                    {
                        SetWindowTheme(control.Handle, dark ? "DarkMode_Explorer" : "Explorer", null);
                        SendMessage(control.Handle, WM_THEMECHANGED, IntPtr.Zero, IntPtr.Zero);
                    }
                }
            }
            catch { }

            foreach (Control child in control.Controls)
                ApplyNativeControlTheme(child, dark);
        }

        public static void ApplyDialogTheme(Form form, bool dark)
        {
            if (form == null) return;

            Color window = dark ? Color.FromArgb(31, 31, 31) : SystemColors.Control;
            Color field = dark ? Color.FromArgb(45, 45, 48) : SystemColors.Window;
            Color text = dark ? Color.WhiteSmoke : SystemColors.ControlText;
            Color fieldText = dark ? Color.FromArgb(245, 245, 245) : SystemColors.WindowText;
            Color button = dark ? Color.FromArgb(48, 48, 48) : SystemColors.Control;
            Color border = dark ? Color.FromArgb(104, 104, 104) : SystemColors.ControlDark;

            form.BackColor = window;
            form.ForeColor = text;
            if (form.IsHandleCreated) ApplyWindowChrome(form, dark);

            foreach (Control c in form.Controls)
                ApplyControlThemeRecursive(c, dark, window, field, text, fieldText, button, border);

            ApplyNativeControlTheme(form, dark);
        }

        /// <summary>
        /// 按钮主题统一入口：对话框递归主题与 MainForm overlay 按钮都走这里，
        /// 不允许各自复制颜色代码。
        /// </summary>
        public static void ApplyButtonTheme(Button button, bool dark)
        {
            ApplyButtonTheme(button, dark,
                dark ? Color.FromArgb(48, 48, 48) : SystemColors.Control,
                dark ? Color.WhiteSmoke : SystemColors.ControlText,
                dark ? Color.FromArgb(104, 104, 104) : SystemColors.ControlDark);
        }

        private static void ApplyButtonTheme(Button btn, bool dark, Color button, Color text, Color border)
        {
            btn.UseVisualStyleBackColor = false;
            btn.BackColor = button;
            btn.ForeColor = text;
            btn.FlatStyle = dark ? FlatStyle.Flat : FlatStyle.Standard;
            if (dark)
            {
                btn.FlatAppearance.BorderColor = border;
                btn.FlatAppearance.MouseOverBackColor = Color.FromArgb(61, 61, 61);
                btn.FlatAppearance.MouseDownBackColor = Color.FromArgb(72, 72, 72);
            }
        }

        private static void ApplyControlThemeRecursive(Control control, bool dark,
            Color window, Color field, Color text, Color fieldText, Color button, Color border)
        {
            if (control == null) return;

            Label label = control as Label;
            if (label != null)
            {
                if (label.Tag as string != "secondary") label.ForeColor = text;
                label.BackColor = Color.Transparent;
            }
            else if (control is TextBox)
            {
                control.BackColor = field;
                control.ForeColor = fieldText;
                TextBox tb = (TextBox)control;
                tb.BorderStyle = BorderStyle.FixedSingle;
            }
            else if (control is ComboBox)
            {
                ComboBox combo = (ComboBox)control;
                combo.BackColor = field;
                combo.ForeColor = fieldText;
                combo.FlatStyle = dark ? FlatStyle.Flat : FlatStyle.Standard;
            }
            else if (control is NumericUpDown)
            {
                control.BackColor = field;
                control.ForeColor = fieldText;
                NumericUpDown num = (NumericUpDown)control;
                num.BorderStyle = BorderStyle.FixedSingle;
            }
            else if (control is Button)
            {
                ApplyButtonTheme((Button)control, dark, button, text, border);
            }
            else if (control is CheckBox)
            {
                CheckBox cb = (CheckBox)control;
                cb.BackColor = Color.Transparent;
                cb.ForeColor = text;
                cb.UseVisualStyleBackColor = true;
            }
            else if (control is Panel || control is GroupBox)
            {
                control.BackColor = window;
                control.ForeColor = text;
            }
            else
            {
                control.ForeColor = text;
            }

            foreach (Control child in control.Controls)
                ApplyControlThemeRecursive(child, dark, window, field, text, fieldText, button, border);
        }
    }

    internal sealed class DarkMenuColorTable : ProfessionalColorTable
    {
        private readonly Color bg = Color.FromArgb(32, 32, 32);
        private readonly Color selected = Color.FromArgb(58, 58, 58);
        private readonly Color border = Color.FromArgb(78, 78, 78);
        private readonly Color separator = Color.FromArgb(72, 72, 72);

        public DarkMenuColorTable()
        {
            UseSystemColors = false;
        }

        public override Color ToolStripDropDownBackground { get { return bg; } }
        public override Color ImageMarginGradientBegin { get { return bg; } }
        public override Color ImageMarginGradientMiddle { get { return bg; } }
        public override Color ImageMarginGradientEnd { get { return bg; } }
        public override Color MenuBorder { get { return border; } }
        public override Color MenuItemBorder { get { return selected; } }
        public override Color MenuItemSelected { get { return selected; } }
        public override Color MenuItemSelectedGradientBegin { get { return selected; } }
        public override Color MenuItemSelectedGradientEnd { get { return selected; } }
        public override Color MenuItemPressedGradientBegin { get { return selected; } }
        public override Color MenuItemPressedGradientMiddle { get { return selected; } }
        public override Color MenuItemPressedGradientEnd { get { return selected; } }
        public override Color SeparatorDark { get { return separator; } }
        public override Color SeparatorLight { get { return separator; } }
        public override Color CheckBackground { get { return selected; } }
        public override Color CheckSelectedBackground { get { return selected; } }
        public override Color CheckPressedBackground { get { return selected; } }
    }

    internal static class PluginCompat
    {
        private const string SentinelWrongId = "id: \"@dsh-external/dsh-sentinel\"";
        private const string SentinelRightId = "id: \"dsh-sentinel\"";
        private const string CostMarker = "DSH Desktop compat: ignore synthetic ModLens wrapper";
        private const string BackfillMarker = "DSH Desktop compat: ignore synthetic ModLens wrapper in backfill replay";

        /// <summary>
        /// 兼容修复入口。apply=false 时只做只读检测并返回待修复项数量（不写任何文件），
        /// 用于端口上已附着外部 DSH 的场景——运行中的 DSH 在内存持有账本，关停时会
        /// 写回，直接修文件会被覆盖。返回值为（待）修复项数量。
        /// </summary>
        public static int ApplyAll(string desktopDirectory, string logsDirectory, string profileName, bool apply)
        {
            int pending = 0;
            try
            {
                string dshHome = Environment.GetEnvironmentVariable("DSH_HOME");
                if (String.IsNullOrWhiteSpace(dshHome))
                {
                    dshHome = Path.Combine(
                        Environment.GetFolderPath(Environment.SpecialFolder.UserProfile),
                        ".dsh");
                }

                if (String.IsNullOrWhiteSpace(dshHome)) return 0;
                if (!Directory.Exists(logsDirectory)) Directory.CreateDirectory(logsDirectory);

                StringBuilder log = new StringBuilder();
                log.AppendLine("DeepSeek Harness DesktopShell plugin compatibility");
                log.AppendLine("Mode: " + (apply ? "apply" : "dry-run (external DSH attached, no writes)"));
                log.AppendLine("Checked: " + DateTime.Now.ToString("O"));
                log.AppendLine("DSH_HOME: " + dshHome);

                string profile = AppSettings.NormalizeProfileName(profileName);
                log.AppendLine("Profile: " + profile);
                if (RepairSentinel(dshHome, profile, log, apply)) pending++;
                if (RepairCostMeterModLens(dshHome, profile, log, apply)) pending++;
                if (RepairCostMeterBackfill(dshHome, profile, log, apply)) pending++;
                if (RepairCostMeterLedger(dshHome, log, apply)) pending++;
                log.AppendLine(apply
                    ? ("Applied repairs: " + pending)
                    : ("Pending repairs (skipped): " + pending));

                File.WriteAllText(
                    Path.Combine(logsDirectory, "plugin-compat.log"),
                    log.ToString(),
                    new UTF8Encoding(false));
            }
            catch
            {
                // Compatibility repair must never prevent the shell itself from starting.
            }
            return pending;
        }

        private static bool RepairSentinel(string dshHome, string profileName, StringBuilder log, bool apply)
        {
            string path = Path.Combine(dshHome, "profiles", profileName, "node_modules", "dsh-sentinel", "lib", "client.js");
            if (!File.Exists(path))
            {
                log.AppendLine("Sentinel: not installed; skipped.");
                return false;
            }

            try
            {
                string source = File.ReadAllText(path, Encoding.UTF8);
                int wrongCount = CountOccurrences(source, SentinelWrongId);
                int rightCount = CountOccurrences(source, SentinelRightId);

                if (wrongCount == 1 && rightCount == 0)
                {
                    if (apply)
                    {
                        source = source.Replace(SentinelWrongId, SentinelRightId);
                        WriteAtomic(path, source);
                        log.AppendLine("Sentinel: repaired client bundle id.");
                        CleanupFiles(Path.GetDirectoryName(path), "client.js.before-client-id-fix-*.bak");
                    }
                    else
                    {
                        log.AppendLine("Sentinel: pending client bundle id repair (skipped: external DSH attached).");
                    }
                    return true;
                }
                else if (wrongCount == 0 && rightCount >= 1)
                {
                    log.AppendLine("Sentinel: already healthy / upstream fixed; no action.");
                    if (apply) CleanupFiles(Path.GetDirectoryName(path), "client.js.before-client-id-fix-*.bak");
                }
                else
                {
                    log.AppendLine("Sentinel: unrecognized bundle shape; left untouched.");
                }
            }
            catch (Exception ex)
            {
                log.AppendLine("Sentinel: repair failed: " + ex.Message);
            }
            return false;
        }

        private static bool RepairCostMeterModLens(string dshHome, string profileName, StringBuilder log, bool apply)
        {
            string path = Path.Combine(dshHome, "profiles", profileName, "node_modules", "dsh-cost-meter", "lib", "index.js");
            if (!File.Exists(path))
            {
                log.AppendLine("Cost meter: not installed; skipped.");
                return false;
            }

            try
            {
                string source = File.ReadAllText(path, Encoding.UTF8);
                if (source.IndexOf(CostMarker, StringComparison.Ordinal) >= 0)
                {
                    log.AppendLine("Cost meter: ModLens de-dup already active.");
                    if (apply) CleanupFiles(Path.GetDirectoryName(path), "index.js.before-modlens-dedup-*.bak");
                    return false;
                }

                int handler = source.IndexOf("ctx.on('llm/stream'", StringComparison.Ordinal);
                if (handler < 0)
                    handler = source.IndexOf("ctx.on(\"llm/stream\"", StringComparison.Ordinal);

                if (handler < 0)
                {
                    log.AppendLine("Cost meter: llm/stream handler not found; left untouched.");
                    return false;
                }

                int account = source.IndexOf("ledger.account(", handler, StringComparison.Ordinal);
                if (account < 0)
                {
                    log.AppendLine("Cost meter: ledger.account call not found; left untouched.");
                    return false;
                }

                string region = source.Substring(handler, account - handler);
                if (region.IndexOf("deepseek-modlens", StringComparison.Ordinal) >= 0 ||
                    region.IndexOf("modlens-", StringComparison.Ordinal) >= 0)
                {
                    log.AppendLine("Cost meter: upstream already contains ModLens filtering; no action.");
                    if (apply) CleanupFiles(Path.GetDirectoryName(path), "index.js.before-modlens-dedup-*.bak");
                    return false;
                }

                string needle = "if (usage !== null) {";
                int condition = source.IndexOf(needle, handler, StringComparison.Ordinal);
                if (condition < 0 || condition > account)
                {
                    log.AppendLine("Cost meter: expected usage guard not found; left untouched.");
                    return false;
                }

                if (!apply)
                {
                    log.AppendLine("Cost meter: pending ModLens synthetic-provider double billing repair (skipped: external DSH attached).");
                    return true;
                }

                string replacement =
                    "if (usage !== null && !(typeof options?.provider === 'string' && " +
                    "(options.provider === 'deepseek-modlens' || options.provider.startsWith('modlens-')))) { " +
                    "// " + CostMarker;

                source = source.Substring(0, condition) + replacement +
                         source.Substring(condition + needle.Length);

                WriteAtomic(path, source);
                log.AppendLine("Cost meter: repaired ModLens synthetic-provider double billing.");
                CleanupFiles(Path.GetDirectoryName(path), "index.js.before-modlens-dedup-*.bak");
                return true;
            }
            catch (Exception ex)
            {
                log.AppendLine("Cost meter: repair failed: " + ex.Message);
            }
            return false;
        }

        /// <summary>
        /// 给 cost-meter 的 backfill.js 打幂等补丁：历史回放（backfillLegacyLedger）
        /// 会从会话日志重建 byProviderModel，而会话日志里保留着 ModLens 合成包装的
        /// request/header + usage 事件。若不拦截，任何被清空/新建的账本都会在启动
        /// 回填时把合成条目重新计回（双倍计价“复发”的根因）。与 index.js 的守卫一致。
        /// </summary>
        private static bool RepairCostMeterBackfill(string dshHome, string profileName, StringBuilder log, bool apply)
        {
            string path = Path.Combine(dshHome, "profiles", profileName, "node_modules",
                "dsh-cost-meter", "lib", "backfill.js");
            if (!File.Exists(path))
            {
                log.AppendLine("Cost meter backfill: not installed; skipped.");
                return false;
            }

            try
            {
                string source = File.ReadAllText(path, Encoding.UTF8);
                if (source.IndexOf(BackfillMarker, StringComparison.Ordinal) >= 0)
                {
                    log.AppendLine("Cost meter backfill: ModLens skip already active.");
                    if (apply) CleanupFiles(Path.GetDirectoryName(path), "backfill.js.before-modlens-backfill-fix-*.bak");
                    return false;
                }

                string anchor = "    const atMs = Number(event.time)";
                int at = source.IndexOf(anchor, StringComparison.Ordinal);
                if (at < 0)
                {
                    log.AppendLine("Cost meter backfill: anchor not found; left untouched.");
                    return false;
                }

                if (!apply)
                {
                    log.AppendLine("Cost meter backfill: pending ModLens replay skip repair (skipped: external DSH attached).");
                    return true;
                }

                string patch =
                    "    // " + BackfillMarker + "\r\n" +
                    "    if (provider === 'deepseek-modlens' || provider.startsWith('modlens-')) continue\r\n";
                source = source.Substring(0, at) + patch + source.Substring(at);

                WriteAtomic(path, source);
                log.AppendLine("Cost meter backfill: repaired ModLens replay skip.");
                CleanupFiles(Path.GetDirectoryName(path), "backfill.js.before-modlens-backfill-fix-*.bak");
                return true;
            }
            catch (Exception ex)
            {
                log.AppendLine("Cost meter backfill: repair failed: " + ex.Message);
            }
            return false;
        }

        /// <summary>
        /// 清理 cost-meter 账本中被 ModLens 合成包装误计的条目（双倍计价修复）。
        /// 删除 provider 键为 deepseek-modlens:* 或 modlens-*:* 的计费桶（日级 + 会话级），
        /// 并从日/会话合计中扣减对应 token 与金额；修改前自动备份。
        /// 与 scripts/Repair-CostMeterLedger.ps1 逻辑一致，桌面壳每次启动时执行。
        /// </summary>
        private static bool RepairCostMeterLedger(string dshHome, StringBuilder log, bool apply)
        {
            string path = Path.Combine(dshHome, "storages", "cost-meter", "ledger.json");
            if (!File.Exists(path))
            {
                log.AppendLine("Cost meter ledger: not found; skipped.");
                return false;
            }

            try
            {
                JavaScriptSerializer serializer = new JavaScriptSerializer();
                Dictionary<string, object> ledger;
                try
                {
                    ledger = serializer.Deserialize<Dictionary<string, object>>(
                        File.ReadAllText(path, Encoding.UTF8));
                }
                catch
                {
                    log.AppendLine("Cost meter ledger: unparseable; left untouched.");
                    return false;
                }

                if (ledger == null || !ledger.ContainsKey("days"))
                {
                    log.AppendLine("Cost meter ledger: no days; skipped.");
                    return false;
                }

                bool changed = false;
                int removedBuckets = 0;
                int removedCalls = 0;
                double removedCost = 0;
                List<Dictionary<string, object>> touched = new List<Dictionary<string, object>>();

                Dictionary<string, object> days = ledger["days"] as Dictionary<string, object>;
                if (days != null)
                {
                    foreach (KeyValuePair<string, object> dayPair in new List<KeyValuePair<string, object>>(days))
                    {
                        Dictionary<string, object> day = dayPair.Value as Dictionary<string, object>;
                        if (day == null) continue;
                        removedBuckets += RemoveSyntheticLedgerBuckets(
                            day, dayPair.Key + " day", log,
                            ref changed, ref removedCalls, ref removedCost, touched);

                        object sessionsObj;
                        if (day.TryGetValue("sessions", out sessionsObj))
                        {
                            ArrayList sessions = sessionsObj as ArrayList;
                            if (sessions != null)
                            {
                                foreach (object sObj in sessions)
                                {
                                    Dictionary<string, object> session = sObj as Dictionary<string, object>;
                                    if (session == null) continue;
                                    string sid = session.ContainsKey("id")
                                        ? Convert.ToString(session["id"]) : "?";
                                    removedBuckets += RemoveSyntheticLedgerBuckets(
                                        session, sid, log,
                                        ref changed, ref removedCalls, ref removedCost, touched);
                                }
                            }
                        }
                    }
                }

                if (!changed)
                {
                    log.AppendLine("Cost meter ledger: no synthetic ModLens entries; clean.");
                    return false;
                }

                if (!apply)
                {
                    log.AppendLine("Cost meter ledger: pending removal of " + removedBuckets + " synthetic bucket(s) (" +
                        removedCalls + " calls, " + removedCost.ToString("0.######") + " USD) (skipped: external DSH attached).");
                    return true;
                }

                // 修复算法：删除合成桶后，从剩余合法 byProviderModel 重新汇总
                // day/session totals（顺带归一化旧账本本身已不一致的总计）。
                foreach (Dictionary<string, object> parent in touched)
                    RecomputeLedgerTotals(parent);

                string stamp = DateTime.Now.ToString("yyyyMMdd-HHmmss");
                string bak = path + ".before-modlens-clean-" + stamp + ".bak";
                File.Copy(path, bak, true);
                WriteAtomic(path, serializer.Serialize(ledger));
                log.AppendLine("Cost meter ledger: removed " + removedBuckets + " synthetic bucket(s) (" +
                    removedCalls + " calls, " + removedCost.ToString("0.######") + " USD) and recomputed totals; backup " + bak);
                return true;
            }
            catch (Exception ex)
            {
                log.AppendLine("Cost meter ledger: repair failed: " + ex.Message);
            }
            return false;
        }

        private static int RemoveSyntheticLedgerBuckets(Dictionary<string, object> parent,
            string label, StringBuilder log, ref bool changed, ref int removedCalls, ref double removedCost,
            List<Dictionary<string, object>> touched)
        {
            int removed = 0;
            if (!parent.ContainsKey("byProviderModel")) return 0;
            Dictionary<string, object> pm = parent["byProviderModel"] as Dictionary<string, object>;
            if (pm == null || pm.Count == 0) return 0;

            List<string> drop = new List<string>();
            foreach (string key in pm.Keys)
            {
                if (key.StartsWith("deepseek-modlens:", StringComparison.Ordinal) ||
                    key.StartsWith("modlens-", StringComparison.Ordinal))
                    drop.Add(key);
            }

            foreach (string key in drop)
            {
                Dictionary<string, object> b = pm[key] as Dictionary<string, object>;
                pm.Remove(key);
                removed++;
                changed = true;
                int calls = b != null && b.ContainsKey("calls") ? Convert.ToInt32(b["calls"]) : 0;
                double cost = b != null && b.ContainsKey("cost") ? Convert.ToDouble(b["cost"]) : 0;
                removedCalls += calls;
                removedCost += cost;
                log.AppendLine("Cost meter ledger: drop " + label + " " + key +
                    " (calls=" + calls + " cost=" + cost.ToString("0.######") + ")");
            }

            if (removed > 0) touched.Add(parent);
            return removed;
        }

        // 从剩余合法 byProviderModel 桶重新汇总父节点 totals（替代“总计减合成桶”的减法算法，
        // 旧账本本身已不一致时也能恢复一致）。
        private static void RecomputeLedgerTotals(Dictionary<string, object> parent)
        {
            if (!parent.ContainsKey("byProviderModel")) return;
            Dictionary<string, object> pm = parent["byProviderModel"] as Dictionary<string, object>;
            if (pm == null) return;

            double input = 0, output = 0, cacheRead = 0, cacheWrite = 0, reasoning = 0, cost = 0;
            int calls = 0;
            foreach (Dictionary<string, object> b in pm.Values)
            {
                if (b == null) continue;
                input += LedgerNumber(b, "input");
                output += LedgerNumber(b, "output");
                cacheRead += LedgerNumber(b, "cacheRead");
                cacheWrite += LedgerNumber(b, "cacheWrite");
                reasoning += LedgerNumber(b, "reasoning");
                calls += LedgerCount(b, "calls");
                cost += LedgerNumber(b, "cost");
            }
            parent["input"] = input;
            parent["output"] = output;
            parent["cacheRead"] = cacheRead;
            parent["cacheWrite"] = cacheWrite;
            parent["reasoning"] = reasoning;
            parent["calls"] = calls;
            parent["cost"] = cost;
        }

        private static double LedgerNumber(Dictionary<string, object> b, string key)
        {
            if (!b.ContainsKey(key)) return 0;
            try { return Convert.ToDouble(b[key]); } catch { return 0; }
        }

        private static int LedgerCount(Dictionary<string, object> b, string key)
        {
            if (!b.ContainsKey(key)) return 0;
            try { return Convert.ToInt32(b[key]); } catch { return 0; }
        }

        private static void WriteAtomic(string path, string content)
        {
            string temp = path + ".dsh-desktop.tmp";
            File.WriteAllText(temp, content, new UTF8Encoding(false));
            if (File.Exists(path))
            {
                // File.Replace 原子替换并保留 backup（.dsh-desktop.bak 为滚动备份）。
                string backup = path + ".dsh-desktop.bak";
                try
                {
                    File.Replace(temp, path, backup);
                    return;
                }
                catch { }
            }

            // Replace 不受支持（如 FAT/网络卷）时退化为复制覆盖。
            // 绝不「先删原文件再 Move」：先删后动一旦第二步失败，插件文件直接丢失。
            try
            {
                File.Copy(temp, path, true);
                File.Delete(temp);
            }
            catch
            {
                try { if (File.Exists(temp)) File.Delete(temp); } catch { }
                throw;
            }
        }

        private static int CountOccurrences(string text, string value)
        {
            if (String.IsNullOrEmpty(text) || String.IsNullOrEmpty(value)) return 0;
            int count = 0;
            int index = 0;
            while ((index = text.IndexOf(value, index, StringComparison.Ordinal)) >= 0)
            {
                count++;
                index += value.Length;
            }
            return count;
        }

        private static void CleanupFiles(string directory, string pattern)
        {
            if (String.IsNullOrWhiteSpace(directory) || !Directory.Exists(directory)) return;
            try
            {
                foreach (string file in Directory.GetFiles(directory, pattern))
                {
                    try { File.Delete(file); } catch { }
                }
            }
            catch { }
        }
    }

    internal sealed class DshProcessManager : IDisposable
    {
        private Process process;
        private IntPtr jobHandle = IntPtr.Zero;
        private readonly object logLock = new object();
        private string logPath;
        public bool OwnsBackend { get; private set; }

        // 真正监听 DSH 端口的进程（npx 经 .cmd 启动时，process 只是 cmd 包装进程，
        // 监听 3080 的 Node 是它的子进程）。首次就绪时记录；停止时身份验证后兜底结束。
        private int ownedListenerPid = -1;
        private int ownedWrapperPid = -1;
        private int ownedPort = -1;
        private string ownedProfile = "";

        // 本次启动的 DSH 进程树是否已输出官方 ready banner（辅助信号，不取代 Job/PID 检查）
        private bool sawReadyBanner;
        // 端口身份转换日志去重：只记录状态变化
        private string lastPortLog = "";

        /// <summary>启动时保存的 wrapper（cmd/npx 包装进程）PID；无则 -1。</summary>
        public int WrapperPid
        {
            get
            {
                try { return process == null ? -1 : process.Id; } catch { return -1; }
            }
        }

        /// <summary>启动时记录并验证过的真正 listener PID；未记录则 -1。</summary>
        public int OwnedListenerPid { get { return ownedListenerPid; } }

        public int OwnedPort { get { return ownedPort; } }
        public string OwnedProfile { get { return ownedProfile ?? ""; } }

        /// <summary>自家后端是否仍存活（用于“未知宿主异常重试”时避免无意义重启健康 DSH）。</summary>
        public bool BackendRunning
        {
            get { return OwnsBackend && process != null && !process.HasExited; }
        }

        private const uint JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE = 0x00002000;
        private const int JobObjectExtendedLimitInformation = 9;

        [StructLayout(LayoutKind.Sequential)]
        private struct JOBOBJECT_BASIC_LIMIT_INFORMATION
        {
            public long PerProcessUserTimeLimit;
            public long PerJobUserTimeLimit;
            public uint LimitFlags;
            public UIntPtr MinimumWorkingSetSize;
            public UIntPtr MaximumWorkingSetSize;
            public uint ActiveProcessLimit;
            public IntPtr Affinity;
            public uint PriorityClass;
            public uint SchedulingClass;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct IO_COUNTERS
        {
            public ulong ReadOperationCount;
            public ulong WriteOperationCount;
            public ulong OtherOperationCount;
            public ulong ReadTransferCount;
            public ulong WriteTransferCount;
            public ulong OtherTransferCount;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct JOBOBJECT_EXTENDED_LIMIT_INFORMATION
        {
            public JOBOBJECT_BASIC_LIMIT_INFORMATION BasicLimitInformation;
            public IO_COUNTERS IoInfo;
            public UIntPtr ProcessMemoryLimit;
            public UIntPtr JobMemoryLimit;
            public UIntPtr PeakProcessMemoryUsed;
            public UIntPtr PeakJobMemoryUsed;
        }

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode)]
        private static extern IntPtr CreateJobObject(IntPtr attributes, string name);

        [DllImport("kernel32.dll")]
        private static extern bool SetInformationJobObject(
            IntPtr job,
            int infoClass,
            IntPtr info,
            uint length);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool AssignProcessToJobObject(IntPtr job, IntPtr processHandle);

        [DllImport("kernel32.dll")]
        private static extern bool CloseHandle(IntPtr handle);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool IsProcessInJob(
            IntPtr processHandle,
            IntPtr jobHandle,
            out bool result);

        public bool IsReady(int port, int timeoutMs)
        {
            try
            {
                using (TcpClient client = new TcpClient())
                {
                    IAsyncResult ar = client.BeginConnect("127.0.0.1", port, null, null);
                    bool ok = ar.AsyncWaitHandle.WaitOne(timeoutMs);
                    if (!ok) return false;
                    client.EndConnect(ar);
                    return true;
                }
            }
            catch { return false; }
        }

        /// <summary>
        /// DSH 就绪判定 = TCP 可连 + 监听进程 PID 可查 + 命令行像 DSH。
        /// 只用 TCP 判定存在 TOCTOU 窗口：DSH 崩溃后端口被其它本地服务抢到，
        /// 纯 TCP 探测会误以为 DSH 正常，并继续把 127.0.0.1:port 当可信 DSH origin。
        /// </summary>
        public bool IsDshReady(int port, int timeoutMs)
        {
            if (!IsReady(port, timeoutMs)) return false;

            int pid = FindListeningPid(port);
            if (pid <= 0) return false;

            string commandLine;
            return IsLikelyDshProcess(pid, out commandLine, port);
        }

        // DesktopShell 验证基线：只有该版本被审核过。外部已运行的 DSH 同样必须过这道门槛。
        // 唯一来源：安装目录 COMPATIBILITY.json（构建/安装流程随包分发），缺失时回退硬编码。
        private static string verifiedDshVersionCache = null;
        public static string VerifiedDshVersion
        {
            get
            {
                if (verifiedDshVersionCache != null) return verifiedDshVersionCache;
                verifiedDshVersionCache = "0.1.0-rc.7";
                try
                {
                    string compatPath = Path.Combine(
                        AppDomain.CurrentDomain.BaseDirectory.TrimEnd(Path.DirectorySeparatorChar),
                        "COMPATIBILITY.json");
                    if (File.Exists(compatPath))
                    {
                        JavaScriptSerializer serializer = new JavaScriptSerializer();
                        Dictionary<string, object> compat =
                            serializer.Deserialize<Dictionary<string, object>>(File.ReadAllText(compatPath, Encoding.UTF8));
                        object raw;
                        if (compat != null && compat.TryGetValue("verifiedDshVersion", out raw))
                        {
                            string v = Convert.ToString(raw);
                            if (Regex.IsMatch(v, @"^\d+\.\d+\.\d+(?:-[A-Za-z0-9._+-]+)?$"))
                                verifiedDshVersionCache = v;
                        }
                    }
                }
                catch { }
                return verifiedDshVersionCache;
            }
        }

        /// <summary>从命令行里提取 npx 形式的版本（@deepseek-ai/dsh@x.y.z-rc.n）；提取不到返回 null。</summary>
        public static string ExtractDshVersionFromCommandLine(string commandLine)
        {
            if (String.IsNullOrWhiteSpace(commandLine)) return null;
            Match m = Regex.Match(commandLine, @"@deepseek-ai/dsh@([0-9A-Za-z._+-]+)", RegexOptions.IgnoreCase);
            if (m.Success) return m.Groups[1].Value;
            return null;
        }

        public static bool IsVerifiedDshVersion(string version)
        {
            if (String.IsNullOrWhiteSpace(version)) return false;
            return String.Equals(version.Trim(), VerifiedDshVersion, StringComparison.OrdinalIgnoreCase);
        }

        /// <summary>读取 dsh 命令自身的版本（运行 &lt;command&gt; --version）。读不到返回 null。</summary>
        public static string GetCommandVersion(string command)
        {
            if (String.IsNullOrWhiteSpace(command) || !File.Exists(command)) return null;
            try
            {
                ProcessStartInfo psi = new ProcessStartInfo();
                string ext = Path.GetExtension(command).ToLowerInvariant();
                if (ext == ".cmd" || ext == ".bat")
                {
                    psi.FileName = Environment.GetEnvironmentVariable("ComSpec") ?? "cmd.exe";
                    psi.Arguments = "/d /s /c \"\"" + command + "\" --version\"";
                }
                else
                {
                    psi.FileName = command;
                    psi.Arguments = "--version";
                }
                psi.UseShellExecute = false;
                psi.CreateNoWindow = true;
                psi.RedirectStandardOutput = true;
                psi.RedirectStandardError = true;
                psi.StandardOutputEncoding = Encoding.UTF8;

                using (Process p = Process.Start(psi))
                {
                    if (p == null) return null;
                    string output = p.StandardOutput.ReadToEnd();
                    p.WaitForExit(5000);
                    if (String.IsNullOrWhiteSpace(output)) return null;
                    Match m = Regex.Match(output, @"\d+\.\d+\.\d+(?:-[A-Za-z0-9._+-]+)?");
                    if (m.Success) return m.Value;
                    return output.Trim();
                }
            }
            catch { return null; }
        }

        /// <summary>端口探测结果：PortOpen 为假时其余字段无意义。</summary>
        public class ExternalBackendInfo
        {
            public bool PortOpen;
            public int Pid = -1;
            public string CommandLine = "";
            public bool IsDsh;
            public string Version;      // null = 命令行里读不到版本
            public bool IsVerified;
        }

        /// <summary>一次性探测端口：TCP + PID + 命令行 + 版本提取（不修改任何状态）。</summary>
        public ExternalBackendInfo ProbeExternalDsh(int port)
        {
            ExternalBackendInfo info = new ExternalBackendInfo();
            info.PortOpen = IsReady(port, 350);
            if (!info.PortOpen) return info;

            info.Pid = FindListeningPid(port);
            string cmd;
            info.IsDsh = IsLikelyDshProcess(info.Pid, out cmd, port);
            info.CommandLine = cmd ?? "";
            info.Version = ExtractDshVersionFromCommandLine(info.CommandLine);
            info.IsVerified = IsVerifiedDshVersion(info.Version);
            return info;
        }

        private int lastExternalPid = -1;

        /// <summary>
        /// 后台健康检查专用（每 5 秒一次）：
        /// - 自家后端：进程存活 + TCP 即可（无需身份复验）
        /// - 外部后端：每次用廉价的原生 TCP 表拿「当前端口 owner PID」（GetExtendedTcpTable，
        ///   不拉 netstat 子进程）；owner PID 与上次已验证的 PID 相同 → 身份未变，直接健康；
        ///   PID 变化（端口被换手）才做昂贵的 CIM 命令行验证。不再使用 30 秒时间窗缓存。
        /// </summary>
        public bool IsDshHealthy(int port, int timeoutMs)
        {
            if (OwnsBackend)
            {
                if (process == null || process.HasExited) return false;
                return IsReady(port, timeoutMs);
            }

            if (!IsReady(port, timeoutMs))
            {
                lastExternalPid = -1;
                return false;
            }

            int pid = FindListeningPid(port);   // 优先原生 TCP 表，原生不可用时退回 netstat
            if (pid <= 0)
            {
                lastExternalPid = -1;
                return false;
            }
            if (pid == lastExternalPid) return true;   // 端口 owner 未变 → 身份可信

            string commandLine;
            if (!IsLikelyDshProcess(pid, out commandLine, port))
            {
                lastExternalPid = -1;
                return false;
            }
            lastExternalPid = pid;
            return true;
        }

        /// <summary>启动结果：wrapper（cmd/npx 包装进程）与真正 listener 的 PID。</summary>
        public class BackendStartResult
        {
            public int WrapperPid;
            public int ListenerPid;
        }

        public BackendStartResult EnsureStarted(int port, string workingDirectory, string logsDirectory, string requestedVersion, string profileName, string configuredDshPath, string runnerMode, bool allowUnverifiedAttach)
        {
            if (runnerMode != "npx" && runnerMode != "command") runnerMode = "auto";

            if (IsReady(port, 350))
            {
                int existingPid = FindListeningPid(port);
                if (existingPid <= 0)
                    throw new InvalidOperationException(
                        "端口 " + port.ToString() + " 已被占用，但无法确认监听进程身份。为避免误附着，桌面壳不会继续。");

                string commandLine;
                if (!IsLikelyDshProcess(existingPid, out commandLine, port))
                    throw new InvalidOperationException(
                        "端口 " + port.ToString() + " 已被非 DSH 进程占用（PID " + existingPid.ToString() + "）。\r\n\r\n" +
                        "命令行：\r\n" + (String.IsNullOrWhiteSpace(commandLine) ? "（无法读取）" : commandLine) +
                        "\r\n\r\n桌面壳拒绝把它当作 DSH。请更换端口或结束占用进程。");

                // 外部 backend 也必须单独通过版本验证：runnerMode 只约束“端口为空时怎么启动”，
                // 不约束“允许附着什么”。读不到版本与读到的不是 rc.7 一律按未验证处理。
                string externalVersion = ExtractDshVersionFromCommandLine(commandLine);
                if (!IsVerifiedDshVersion(externalVersion) && !allowUnverifiedAttach)
                    throw new InvalidOperationException(
                        "端口 " + port.ToString() + " 上已有一个 DSH 后端在运行，但它未通过版本验证：" +
                        (String.IsNullOrEmpty(externalVersion) ? "无法从命令行读取其版本。" : "其版本为 " + externalVersion + "。") +
                        "\r\n\r\nDesktopShell 验证基线：" + VerifiedDshVersion +
                        "。已拒绝附着。请结束该进程后重试，或重新启动桌面壳并在提示时确认附着。");

                OwnsBackend = false;
                ownedWrapperPid = -1;
                ownedListenerPid = -1;
                ownedPort = -1;
                ownedProfile = "";
                lastExternalPid = existingPid;
                return new BackendStartResult { WrapperPid = -1, ListenerPid = existingPid };
            }

            if (!Directory.Exists(logsDirectory)) Directory.CreateDirectory(logsDirectory);
            CleanupOldLogs(logsDirectory);
            logPath = Path.Combine(logsDirectory, "dsh-" + DateTime.Now.ToString("yyyyMMdd-HHmmss") + ".log");
            File.WriteAllText(logPath,
                "DeepSeek Harness DesktopShell\r\n" +
                "Started: " + DateTime.Now.ToString("O") + "\r\n" +
                "Working directory: " + workingDirectory + "\r\n\r\n",
                new UTF8Encoding(false));

            string version = AppSettings.NormalizeDshVersion(requestedVersion);
            string profile = AppSettings.NormalizeProfileName(profileName);
            string command = configuredDshPath == null ? "" : configuredDshPath.Trim();
            bool usingNpx = false;

            // dshRunnerMode 两端一致：npx=绝不回捡 PATH 里的 dsh；
            // command=只用现有 dsh（找不到即报错，不悄悄转 npx）；auto=有 dsh 用 dsh，否则 npx。
            if (runnerMode == "npx")
            {
                usingNpx = true;
            }
            else
            {
                if (String.IsNullOrWhiteSpace(command) || !File.Exists(command))
                    command = FindCommand("dsh");

                if (String.IsNullOrWhiteSpace(command) || !File.Exists(command))
                {
                    if (runnerMode == "command")
                    {
                        throw new InvalidOperationException(
                            "设置要求使用现有 dsh（dshRunnerMode=command），但 PATH 中找不到 dsh 命令。\r\n\r\n" +
                            "请安装官方 DeepSeek Harness，或在设置中把运行方式改为“自动”或“仅 npx”。");
                    }
                    usingNpx = true;
                }
            }

            if (usingNpx)
                command = FindCommand("npx");

            if (String.IsNullOrWhiteSpace(command) || !File.Exists(command))
            {
                throw new InvalidOperationException(
                    "既没有找到系统 dsh 命令，也没有找到 npx。\r\n\r\n" +
                    "DeepSeek Harness 官方推荐通过 npx @deepseek-ai/dsh web 运行。\r\n" +
                    "请先安装可用的 Node.js/npm，然后重新启动 DesktopShell。");
            }

            string arguments;
            if (usingNpx)
            {
                // 官方 CLI：`dsh web` 本身就是 `dsh --profile web` 的别名，两者不能叠加
                // （rejectParentOptions('web')）。自定义 Profile 统一用 --profile 形式，
                // 不再额外附加 `web` 子命令；--port 作为应用参数继续传给 Profile。
                arguments = "-y @deepseek-ai/dsh@" + QuoteArg(version) +
                    " --profile " + QuoteArg(profile) +
                    " --port " + port.ToString();
            }
            else
            {
                arguments = "--profile " + QuoteArg(profile) +
                    " --port " + port.ToString();
            }

            ProcessStartInfo psi = BuildStartInfo(command, arguments, workingDirectory);
            string oldPath = psi.EnvironmentVariables["PATH"] ?? Environment.GetEnvironmentVariable("PATH") ?? "";
            string commandDir = Path.GetDirectoryName(command) ?? "";
            if (!String.IsNullOrWhiteSpace(commandDir)) psi.EnvironmentVariables["PATH"] = commandDir + ";" + oldPath;
            psi.EnvironmentVariables["DSH_DESKTOP_DSH_VERSION"] = version;
            // 注意：不为常驻 DSH 进程设置 GIT_CONFIG_* rewrite——
            // 那会污染整个 DSH 进程树（Agent/终端/子进程执行 git@github.com:... 时被
            // 强制改成 https，破坏本应正常的 SSH 私有仓库认证）。
            // git+ssh→https 降级只保留在 PowerShell 管理器“插件安装事务”的进程内作用域。
            process = new Process();
            process.StartInfo = psi;
            process.EnableRaisingEvents = true;
            process.OutputDataReceived += OnOutput;
            process.ErrorDataReceived += OnOutput;

            AppendLog("Launching: " + psi.FileName + " " + psi.Arguments);
            if (!process.Start())
                throw new InvalidOperationException("无法启动 DeepSeek Harness。");

            OwnsBackend = true;
            ownedWrapperPid = process.Id;
            ownedPort = port;
            ownedProfile = profile;
            ownedListenerPid = -1;
            sawReadyBanner = false;
            lastPortLog = "";
            TryAttachJob(process);
            process.BeginOutputReadLine();
            process.BeginErrorReadLine();

            try
            {
                // 身份状态机（四态）：端口刚打开时 PID/命令行可能滞后数百毫秒（Pending），
                // 绝不把 Pending 当 Foreign 立即报错；Foreign 需要 PID 稳定 + 命令行可读 +
                // 连续 3~4 次确认。Job 归属证明（OwnedJob）优先于命令行字符串。
                int waited = 0;
                int foreignPid = -1;
                int foreignStable = 0;
                while (waited < 120000)
                {
                    if (!IsReady(port, 100))
                    {
                        foreignPid = -1;
                        foreignStable = 0;
                        LogPortState(port, -1, ListenerIdentity.None, 0);
                        Thread.Sleep(120);
                        waited += 120;
                        continue;
                    }

                    int pid = FindListeningPid(port);
                    string commandLine;
                    ListenerIdentity identity = ProbeListenerIdentity(port, pid, out commandLine);

                    if (identity == ListenerIdentity.OwnedJob || identity == ListenerIdentity.VerifiedDsh)
                    {
                        // 归属已确认（Job 证明优先，命令行证明次之）：记录 listener PID 即成功
                        if (pid > 0) ownedListenerPid = pid;
                        LogPortState(port, pid, identity, 0);
                        HostLog.Line("BACKEND ready wrapper=" + ownedWrapperPid.ToString() +
                            " listener=" + pid.ToString() + " identity=" + identity.ToString() +
                            " sawReadyBanner=" + sawReadyBanner.ToString());
                        AppendLog("Listener PID: " + pid.ToString() + " identity=" + identity.ToString());
                        return new BackendStartResult { WrapperPid = ownedWrapperPid, ListenerPid = pid };
                    }

                    if (identity == ListenerIdentity.Foreign)
                    {
                        if (pid == foreignPid) foreignStable++;
                        else { foreignPid = pid; foreignStable = 1; }
                        LogPortState(port, pid, identity, foreignStable);
                        if (foreignStable >= 4)
                            throw new InvalidOperationException(
                                "端口 " + port.ToString() + " 在 DSH 就绪前被非 DSH 进程占用（PID " + pid.ToString() +
                                "）。桌面壳拒绝把它当作 DSH。请查看日志：" + logPath);
                    }
                    else
                    {
                        // Pending：身份信息暂时不可用——记录转换，重置 Foreign 稳定计数，继续等待
                        LogPortState(port, pid, identity, 0);
                        foreignPid = -1;
                        foreignStable = 0;
                    }

                    if (process.HasExited)
                        throw new InvalidOperationException("DSH 在 Web 服务就绪前退出，退出码 " +
                            process.ExitCode.ToString() + "。请查看日志：" + logPath);

                    Thread.Sleep(120);
                    waited += 120;
                }

                throw new TimeoutException("等待 DSH Web 启动超时（120 秒）。请查看日志：" + logPath);
            }
            catch
            {
                // 半失败清理：UI 会报失败，绝不能留下“OwnsBackend=true 但 DSH 还在后台跑”；
                // 只清理本次刚创建的 Job/process（未验证身份的监听者绝不动）。
                HostLog.Line("START-CLEANUP begin (failed backend start, port=" + port.ToString() + ")");
                StopOwnedWrapper();
                TryStopListenerFallback(port);
                OwnsBackend = false;
                ownedListenerPid = -1;
                ownedWrapperPid = -1;
                ownedPort = -1;
                ownedProfile = "";
                sawReadyBanner = false;
                try { if (process != null) process.Dispose(); } catch { }
                process = null;
                HostLog.Line("START-CLEANUP done");
                throw;
            }
        }

        /// <summary>
        /// 端口监听者身份探测（四态）。任何“暂时读不到”都归 Pending：
        /// PID 查不到 → Pending；PID 有但 Job 判定失败且命令行读不到 → Pending；
        /// 属于本壳 Job → OwnedJob（最强证明，无需命令行字符串）；
        /// 命令行非空 → VerifiedDsh / Foreign。
        /// </summary>
        private ListenerIdentity ProbeListenerIdentity(int port, int pid, out string commandLine)
        {
            commandLine = null;
            if (pid <= 0) return ListenerIdentity.Pending;

            // 归属证明优先：属于本壳 Job 的进程树 = 自己的 DSH（无需等 CIM 字符串识别）
            if (jobHandle != IntPtr.Zero)
            {
                try
                {
                    using (Process p = Process.GetProcessById(pid))
                    {
                        bool inJob;
                        if (IsProcessInJob(p.Handle, jobHandle, out inJob) && inJob)
                            return ListenerIdentity.OwnedJob;
                    }
                }
                catch { /* 句柄打开失败（权限等）→ 退回命令行判定 */ }
            }

            commandLine = GetProcessCommandLine(pid);
            if (String.IsNullOrWhiteSpace(commandLine)) return ListenerIdentity.Pending;

            string dummy;
            if (IsLikelyDshCommandLine(commandLine, port, out dummy))
                return ListenerIdentity.VerifiedDsh;
            return ListenerIdentity.Foreign;
        }

        /// <summary>端口身份状态转换日志：每次状态变化记录一次（Foreign 带 stableCount）。</summary>
        private void LogPortState(int port, int pid, ListenerIdentity identity, int stableCount)
        {
            string line;
            switch (identity)
            {
                case ListenerIdentity.None:
                    line = "PORT closed";
                    break;
                case ListenerIdentity.Pending:
                    line = "PORT open pid=" + pid.ToString() + " identity=pending";
                    break;
                case ListenerIdentity.OwnedJob:
                    line = "PORT open pid=" + pid.ToString() + " inOwnJob=true";
                    break;
                case ListenerIdentity.VerifiedDsh:
                    line = "PORT open pid=" + pid.ToString() + " identity=verified-dsh";
                    break;
                default:
                    line = "PORT open pid=" + pid.ToString() + " identity=foreign stableCount=" + stableCount.ToString();
                    break;
            }
            if (line != lastPortLog)
            {
                HostLog.Line(line);
                lastPortLog = line;
            }
        }

        /// <summary>
        /// 停止前冻结 listener 身份：旧进程还活着时，把当前监听 PID 验证后写入 ownedListenerPid
        /// （Job 归属证明优先，否则命令行验证 DSH+profile+port）。供重启的 snapshot 阶段调用，
        /// 让 fallback 能杀“刚刚确认过的精确 PID”，而不是 wrapper 死后重读不可靠的命令行。
        /// </summary>
        public void FreezeOwnedListener(int port)
        {
            if (port <= 0 || !IsReady(port, 300)) return;
            int pid = FindListeningPid(port);
            if (pid <= 0) return;
            string commandLine;
            ListenerIdentity identity = ProbeListenerIdentity(port, pid, out commandLine);
            if (identity == ListenerIdentity.OwnedJob || identity == ListenerIdentity.VerifiedDsh)
            {
                ownedListenerPid = pid;
                HostLog.Line("FREEZE-LISTENER pid=" + pid.ToString() + " identity=" + identity.ToString());
            }
            else
            {
                HostLog.Line("FREEZE-LISTENER refused pid=" + pid.ToString() + " identity=" + identity.ToString());
            }
        }

        public int FindListeningPid(int port)
        {
            // 原生 TCP 表优先（实现见 src/NativeTcpTable.cs，回归测试 test-port-owner.ps1 直接验证）；
            // API 真正失败才退回 netstat。
            int pid = TcpTableHelper.FindListeningPidNative(port);
            if (pid > 0) return pid;

            try
            {
                ProcessStartInfo psi = new ProcessStartInfo();
                psi.FileName = Environment.GetEnvironmentVariable("ComSpec") ?? "cmd.exe";
                psi.Arguments = "/d /s /c \"netstat -ano -p tcp\"";
                psi.UseShellExecute = false;
                psi.CreateNoWindow = true;
                psi.RedirectStandardOutput = true;
                psi.RedirectStandardError = true;

                using (Process probe = Process.Start(psi))
                {
                    if (probe == null) return -1;
                    string output = probe.StandardOutput.ReadToEnd();
                    probe.WaitForExit(5000);
                    string suffix = ":" + port.ToString();

                    foreach (string raw in output.Split(new string[] { "\r\n", "\n" }, StringSplitOptions.RemoveEmptyEntries))
                    {
                        string line = raw.Trim();
                        if (!line.StartsWith("TCP", StringComparison.OrdinalIgnoreCase)) continue;
                        string[] parts = line.Split((char[])null, StringSplitOptions.RemoveEmptyEntries);
                        if (parts.Length < 5) continue;
                        if (!parts[1].EndsWith(suffix, StringComparison.OrdinalIgnoreCase)) continue;
                        if (!parts[3].Equals("LISTENING", StringComparison.OrdinalIgnoreCase)) continue;

                        int foundPid;
                        if (Int32.TryParse(parts[4], out foundPid)) return foundPid;
                    }
                }
            }
            catch { }
            return -1;
        }

        /// <summary>
        /// DSH 身份判断（端口未知时 port 传 -1）：
        /// 官方 package/path 特征 +（legacy "web" 子命令 或 "--profile &lt;合法profile&gt;"）
        /// + 调用方知道端口时必须匹配 "--port &lt;port&gt;"。
        /// 不再把字符串 "web" 当作 Web 服务身份——自定义 Profile（--profile work）同样是合法 DSH。
        /// </summary>
        public bool IsLikelyDshProcess(int pid, out string commandLine)
        {
            return IsLikelyDshCommandLine(GetProcessCommandLine(pid), -1, out commandLine);
        }

        public bool IsLikelyDshProcess(int pid, out string commandLine, int port)
        {
            return IsLikelyDshCommandLine(GetProcessCommandLine(pid), port, out commandLine);
        }

        public static bool IsLikelyDshCommandLine(string rawCommandLine, int port, out string outLine)
        {
            outLine = rawCommandLine ?? "";
            if (String.IsNullOrWhiteSpace(rawCommandLine)) return false;

            string lower = rawCommandLine.ToLowerInvariant();
            bool hasDshPackage =
                lower.Contains("@deepseek-ai") && lower.Contains("dsh");
            bool hasDshPath =
                lower.Contains("\\dsh\\") || lower.Contains("/dsh/") ||
                lower.Contains("dsh.cmd") || lower.Contains("dsh.exe");
            if (!(hasDshPackage || hasDshPath)) return false;

            // legacy 子命令形式：dsh web ...（rc.7 及更早）或 --profile 形式（任意合法 Profile 名）
            bool hasWebSubcommand =
                lower.Contains(" web") || lower.Contains("\"web\"") || lower.Contains("'web'");
            bool hasProfileFlag = Regex.IsMatch(lower, @"--profile\s+[a-z0-9_-]+");
            if (!(hasWebSubcommand || hasProfileFlag)) return false;

            // 调用方知道端口时：必须匹配当前端口，防止误判其它 DSH 实例
            if (port > 0)
            {
                if (!Regex.IsMatch(lower, @"--port\s+" + port.ToString())) return false;
            }
            return true;
        }

        private string GetProcessCommandLine(int pid)
        {
            try
            {
                string powershell = Path.Combine(
                    Environment.GetFolderPath(Environment.SpecialFolder.System),
                    @"WindowsPowerShell\v1.0\powershell.exe");

                if (!File.Exists(powershell)) powershell = "powershell.exe";

                ProcessStartInfo psi = new ProcessStartInfo();
                psi.FileName = powershell;
                psi.Arguments =
                    "-NoProfile -NonInteractive -Command \"$p = Get-CimInstance Win32_Process -Filter 'ProcessId = " +
                    pid.ToString() + "'; if ($null -ne $p) { $p.CommandLine }\"";
                psi.UseShellExecute = false;
                psi.CreateNoWindow = true;
                psi.RedirectStandardOutput = true;
                psi.RedirectStandardError = true;
                psi.StandardOutputEncoding = Encoding.UTF8;

                using (Process probe = Process.Start(psi))
                {
                    if (probe == null) return null;
                    string output = probe.StandardOutput.ReadToEnd();
                    probe.WaitForExit(5000);
                    return output == null ? null : output.Trim();
                }
            }
            catch
            {
                return null;
            }
        }

        private bool WaitForPortClosed(int port, int timeoutMs)
        {
            int waited = 0;
            while (waited < timeoutMs)
            {
                if (!IsReady(port, 200)) return true;
                Thread.Sleep(200);
                waited += 200;
            }
            return !IsReady(port, 200);
        }

        /// <summary>等端口连续两次确认关闭（每次间隔 250ms），避免单次探测抖动误判。</summary>
        public bool WaitForPortClosedTwice(int port, int timeoutMs)
        {
            int closedCount = 0;
            int waited = 0;
            while (waited < timeoutMs && closedCount < 2)
            {
                if (!IsReady(port, 150)) closedCount++;
                else closedCount = 0;
                Thread.Sleep(250);
                waited += 250;
            }
            return closedCount >= 2;
        }

        /// <summary>
        /// ① 关闭 Job Object（KILL_ON_JOB_CLOSE 终止仍在其内的进程树）
        /// → ② Kill wrapper → ③ WaitForExit(wrapper, 3000)。
        /// </summary>
        public void StopOwnedWrapper()
        {
            if (!OwnsBackend) return;

            if (jobHandle != IntPtr.Zero)
            {
                try { CloseHandle(jobHandle); } catch { }
                jobHandle = IntPtr.Zero;
            }

            try { if (process != null && !process.HasExited) process.Kill(); } catch { }
            try { if (process != null) process.WaitForExit(3000); } catch { }

            HostLog.Line("STOP-WRAPPER done wrapperPid=" + ownedWrapperPid.ToString() +
                " exited=" + (process == null || process.HasExited).ToString());
        }

        /// <summary>
        /// ④⑤ 端口仍被监听时的兜底：只有身份验证通过才结束真正 listener——
        /// PID 与启动时记录的 ownedListenerPid 一致，或命令行重新验证为
        /// 「DSH + 当前 profile + 当前 port」。绝不因为端口还开着就盲目杀 PID。
        /// </summary>
        public void TryStopListenerFallback(int port)
        {
            if (port <= 0 || !IsReady(port, 300)) return;

            int currentPid = FindListeningPid(port);
            if (currentPid <= 0) return;

            bool identityOk = false;
            if (ownedListenerPid > 0 && currentPid == ownedListenerPid)
            {
                identityOk = true;   // 与启动时记录的 listener 一致
            }
            else
            {
                string commandLine;
                if (IsLikelyDshProcess(currentPid, out commandLine, port))
                {
                    string lower = (commandLine ?? "").ToLowerInvariant();
                    string profile = (ownedProfile ?? "").ToLowerInvariant();
                    bool profileOk = String.IsNullOrEmpty(profile) ||
                        Regex.IsMatch(lower, @"--profile\s+" + Regex.Escape(profile) + @"(\s|$)");
                    identityOk = profileOk;
                }
            }

            if (!identityOk)
            {
                HostLog.Line("STOP-FALLBACK refused pid=" + currentPid.ToString() +
                    " ownedListenerPid=" + ownedListenerPid.ToString() + " identity not verified");
                return;
            }

            try
            {
                Process listener = Process.GetProcessById(currentPid);
                listener.Kill();
                listener.Dispose();
                HostLog.Line("STOP-FALLBACK killed listener pid=" + currentPid.ToString());
            }
            catch (Exception ex)
            {
                HostLog.Line("STOP-FALLBACK kill failed pid=" + currentPid.ToString() + " :: " + ex.Message);
            }
        }

        /// <summary>
        /// 停止自家后端完整序列：Job 关闭 → wrapper Kill → WaitForExit(3s) → 端口仍开时
        /// 身份验证后结束真正 listener → 端口连续两次确认关闭 → 最后才 OwnsBackend=false。
        /// 不抛异常（关闭/退出路径使用）；重启路径由 RestartBackendAsync 分阶段调用并加门禁。
        /// </summary>
        public void StopOwnedBackend()
        {
            if (!OwnsBackend) return;

            int port = ownedPort;
            HostLog.Line("STOP-OWNED begin port=" + port.ToString() +
                " oldWrapperPid=" + ownedWrapperPid.ToString() +
                " oldListenerPid=" + ownedListenerPid.ToString());

            StopOwnedWrapper();
            TryStopListenerFallback(port);
            WaitForPortClosedTwice(port, 5000);

            OwnsBackend = false;
            HostLog.Line("STOP-OWNED complete port=" + port.ToString() + " ownsBackend=false");
        }

        /// <summary>
        /// 停止外部（非桌面壳启动）的 DSH 监听进程：先身份验证（DSH + 当前端口），
        /// 身份不符拒绝结束；与 RestartBackendAsync 的 preflight 确认配套使用。
        /// </summary>
        public void StopExternalBackend(int port)
        {
            if (!IsReady(port, 300)) return;

            int pid = FindListeningPid(port);
            if (pid <= 0)
                throw new InvalidOperationException(
                    "端口仍在监听，但无法确定监听进程 PID。桌面壳不会盲目结束未知进程。");

            string commandLine;
            if (!IsLikelyDshProcess(pid, out commandLine, port))
                throw new InvalidOperationException(
                    "拒绝结束 PID " + pid.ToString() + "：该监听进程不像 DSH Web。\r\n\r\n命令行：\r\n" +
                    (String.IsNullOrWhiteSpace(commandLine) ? "（无法读取）" : commandLine));

            try
            {
                Process external = Process.GetProcessById(pid);
                external.Kill();
                external.Dispose();
            }
            catch (Exception ex)
            {
                throw new InvalidOperationException("无法结束端口 " + port.ToString() + " 的 DSH 监听进程 PID " +
                    pid.ToString() + "：" + ex.Message);
            }
        }

        /// <summary>
        /// 停止当前端口的 DSH 后端：自家托管的走完整停止链；外部进程只有在
        /// allowExternalStop=true 且命令行像 DSH 时才结束。与 RestartBackend 分离，
        /// 让调用方可以在「停止之后、启动之前」插入 PluginCompat.ApplyAll，
        /// 保证升级插件后点“重启 DSH 后端”也能吃到兼容修复。
        /// </summary>
        public void StopBackend(int port, bool allowExternalStop)
        {
            if (OwnsBackend)
            {
                StopOwnedBackend();
            }
            else if (IsReady(port, 300))
            {
                if (!allowExternalStop)
                    throw new InvalidOperationException("当前端口由桌面壳之外的进程提供，未获准结束该进程。");

                StopExternalBackend(port);
            }

            if (!WaitForPortClosed(port, 10000))
                throw new InvalidOperationException("旧的 DSH Web 在 10 秒内没有释放端口 " + port.ToString() + "。");
        }

        public void RestartBackend(int port, string workingDirectory, string logsDirectory,
            string requestedVersion, string profileName, string configuredDshPath, string runnerMode, bool allowExternalStop)
        {
            StopBackend(port, allowExternalStop);
            EnsureStarted(port, workingDirectory, logsDirectory, requestedVersion, profileName, configuredDshPath, runnerMode, false);
        }

        private static void CleanupOldLogs(string directory)
        {
            try
            {
                DirectoryInfo dir = new DirectoryInfo(directory);
                FileInfo[] logs = dir.GetFiles("dsh-*.log");
                Array.Sort(logs, delegate(FileInfo a, FileInfo b)
                {
                    return b.LastWriteTimeUtc.CompareTo(a.LastWriteTimeUtc);
                });

                for (int i = 0; i < logs.Length; i++)
                {
                    if (i >= 40 || logs[i].LastWriteTimeUtc < DateTime.UtcNow.AddDays(-30))
                    {
                        try { logs[i].Delete(); } catch { }
                    }
                }
            }
            catch { }
        }

        private void OnOutput(object sender, DataReceivedEventArgs e)
        {
            if (e.Data != null)
            {
                AppendLog(e.Data);
                // DSH 官方 ready banner（如 "dsh web: http://127.0.0.1:3080"）来自本次自己
                // 启动的进程树时是额外强信号；只记录标志作辅助，不取代 Job/PID 归属检查。
                if (!sawReadyBanner && ownedPort > 0 &&
                    e.Data.IndexOf("dsh web", StringComparison.OrdinalIgnoreCase) >= 0 &&
                    e.Data.IndexOf("127.0.0.1:" + ownedPort.ToString(), StringComparison.OrdinalIgnoreCase) >= 0)
                {
                    sawReadyBanner = true;
                    HostLog.Line("READY-BANNER seen port=" + ownedPort.ToString());
                }
            }
        }

        private void AppendLog(string text)
        {
            try
            {
                lock (logLock)
                {
                    if (String.IsNullOrEmpty(logPath)) return;
                    File.AppendAllText(logPath, "[" + DateTime.Now.ToString("HH:mm:ss.fff") + "] " +
                        text + "\r\n", Encoding.UTF8);
                }
            }
            catch { }
        }

        private static string QuoteArg(string value)
        {
            if (String.IsNullOrEmpty(value)) return "\"\"";
            if (value.IndexOfAny(new char[] { ' ', '\t', '\"' }) < 0) return value;
            return "\"" + value.Replace("\"", "\\\"") + "\"";
        }

        private static ProcessStartInfo BuildStartInfo(string command, string arguments, string cwd)
        {
            string ext = Path.GetExtension(command).ToLowerInvariant();
            ProcessStartInfo psi = new ProcessStartInfo();

            if (ext == ".cmd" || ext == ".bat")
            {
                psi.FileName = Environment.GetEnvironmentVariable("ComSpec") ?? "cmd.exe";
                psi.Arguments = "/d /s /c \"\"" + command + "\" " + arguments + "\"";
            }
            else
            {
                psi.FileName = command;
                psi.Arguments = arguments;
            }

            psi.WorkingDirectory = Directory.Exists(cwd)
                ? cwd
                : Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
            psi.UseShellExecute = false;
            psi.CreateNoWindow = true;
            psi.RedirectStandardOutput = true;
            psi.RedirectStandardError = true;
            psi.StandardOutputEncoding = Encoding.UTF8;
            psi.StandardErrorEncoding = Encoding.UTF8;
            return psi;
        }

        public static string FindCommand(string name)
        {
            string[] candidates = new string[] { name + ".exe", name + ".cmd", name + ".bat", name };
            string path = Environment.GetEnvironmentVariable("PATH") ?? "";
            string[] parts = path.Split(new char[] { ';' }, StringSplitOptions.RemoveEmptyEntries);

            foreach (string candidate in candidates)
            {
                foreach (string raw in parts)
                {
                    try
                    {
                        string dir = raw.Trim().Trim('"');
                        string full = Path.Combine(dir, candidate);
                        if (File.Exists(full)) return full;
                    }
                    catch { }
                }
            }
            return null;
        }

        private void TryAttachJob(Process p)
        {
            try
            {
                jobHandle = CreateJobObject(IntPtr.Zero, null);
                if (jobHandle == IntPtr.Zero) return;

                JOBOBJECT_EXTENDED_LIMIT_INFORMATION info = new JOBOBJECT_EXTENDED_LIMIT_INFORMATION();
                info.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;

                int length = Marshal.SizeOf(typeof(JOBOBJECT_EXTENDED_LIMIT_INFORMATION));
                IntPtr ptr = Marshal.AllocHGlobal(length);
                try
                {
                    Marshal.StructureToPtr(info, ptr, false);
                    if (!SetInformationJobObject(jobHandle, JobObjectExtendedLimitInformation, ptr, (uint)length))
                    {
                        CloseHandle(jobHandle);
                        jobHandle = IntPtr.Zero;
                        return;
                    }
                }
                finally { Marshal.FreeHGlobal(ptr); }

                if (!AssignProcessToJobObject(jobHandle, p.Handle))
                {
                    CloseHandle(jobHandle);
                    jobHandle = IntPtr.Zero;
                }
            }
            catch
            {
                if (jobHandle != IntPtr.Zero)
                {
                    try { CloseHandle(jobHandle); } catch { }
                    jobHandle = IntPtr.Zero;
                }
            }
        }

        public void Dispose()
        {
            StopOwnedBackend();
            try { if (process != null) process.Dispose(); } catch { }
        }
    }

    internal static class ThemedMessageBox
    {
        public static DialogResult Show(IWin32Window owner, string text, string caption,
            MessageBoxButtons buttons, MessageBoxIcon icon)
        {
            bool dark = ThemeHelper.IsDark();
            using (Form dialog = new Form())
            {
                dialog.Text = caption;
                dialog.FormBorderStyle = FormBorderStyle.FixedDialog;
                dialog.MaximizeBox = false;
                dialog.MinimizeBox = false;
                dialog.ShowInTaskbar = false;
                dialog.StartPosition = owner == null ? FormStartPosition.CenterScreen : FormStartPosition.CenterParent;
                dialog.Width = 590;
                dialog.AutoScaleMode = AutoScaleMode.Dpi;

                int left = 24;
                PictureBox picture = null;
                Icon systemIcon = null;
                if (icon != MessageBoxIcon.None)
                {
                    if (icon == MessageBoxIcon.Error) systemIcon = SystemIcons.Error;
                    else if (icon == MessageBoxIcon.Warning) systemIcon = SystemIcons.Warning;
                    else if (icon == MessageBoxIcon.Question) systemIcon = SystemIcons.Question;
                    else systemIcon = SystemIcons.Information;

                    picture = new PictureBox();
                    picture.SizeMode = PictureBoxSizeMode.CenterImage;
                    picture.Width = 40;
                    picture.Height = 40;
                    picture.Left = 24;
                    picture.Top = 24;
                    picture.Image = systemIcon.ToBitmap();
                    dialog.Controls.Add(picture);
                    left = 78;
                }

                Label message = new Label();
                message.Text = text;
                message.Left = left;
                message.Top = 24;
                message.Width = 540 - left;
                Size measured = TextRenderer.MeasureText(text, SystemFonts.MessageBoxFont,
                    new Size(message.Width, 1000), TextFormatFlags.WordBreak | TextFormatFlags.TextBoxControl);
                message.Height = Math.Max(44, measured.Height + 8);
                dialog.Controls.Add(message);

                int buttonTop = Math.Max(92, message.Bottom + 18);
                int buttonWidth = 90;
                int buttonHeight = 32;
                int right = 548;

                if (buttons == MessageBoxButtons.YesNo)
                {
                    Button no = new Button();
                    no.Text = "否";
                    no.DialogResult = DialogResult.No;
                    no.Width = buttonWidth;
                    no.Height = buttonHeight;
                    no.Left = right - buttonWidth;
                    no.Top = buttonTop;
                    dialog.Controls.Add(no);

                    Button yes = new Button();
                    yes.Text = "是";
                    yes.DialogResult = DialogResult.Yes;
                    yes.Width = buttonWidth;
                    yes.Height = buttonHeight;
                    yes.Left = no.Left - buttonWidth - 10;
                    yes.Top = buttonTop;
                    dialog.Controls.Add(yes);
                    dialog.AcceptButton = yes;
                    dialog.CancelButton = no;
                }
                else
                {
                    Button ok = new Button();
                    ok.Text = "确定";
                    ok.DialogResult = DialogResult.OK;
                    ok.Width = buttonWidth;
                    ok.Height = buttonHeight;
                    ok.Left = right - buttonWidth;
                    ok.Top = buttonTop;
                    dialog.Controls.Add(ok);
                    dialog.AcceptButton = ok;
                    dialog.CancelButton = ok;
                }

                dialog.ClientSize = new Size(570, buttonTop + buttonHeight + 22);
                dialog.HandleCreated += delegate { ThemeHelper.ApplyDialogTheme(dialog, dark); };
                ThemeHelper.ApplyDialogTheme(dialog, dark);
                return owner == null ? dialog.ShowDialog() : dialog.ShowDialog(owner);
            }
        }
    }

    internal sealed class CloseChoiceDialog : Form
    {
        public string ActionChoice { get; private set; }
        public bool RememberChoice { get { return remember.Checked; } }

        private CheckBox remember;

        public CloseChoiceDialog(bool dark)
        {
            Text = "关闭 DeepSeek Harness";
            Width = 520;
            Height = 245;
            FormBorderStyle = FormBorderStyle.FixedDialog;
            MaximizeBox = false;
            MinimizeBox = false;
            StartPosition = FormStartPosition.CenterParent;
            ShowInTaskbar = false;

            Label title = new Label();
            title.Text = "关闭窗口后，要继续在后台运行吗？";
            title.Font = new Font(SystemFonts.MessageBoxFont.FontFamily, 11F, FontStyle.Bold);
            title.AutoSize = true;
            title.Left = 24;
            title.Top = 24;

            Label desc = new Label();
            desc.Text = "关闭到托盘会隐藏主窗口并保留当前会话和后台服务；\r\n标题栏最小化按钮仍会正常最小化到任务栏。选择退出会结束桌面壳与其启动的 DSH 服务。";
            desc.AutoSize = true;
            desc.Left = 24;
            desc.Top = 62;

            remember = new CheckBox();
            remember.Text = "记住此选择";
            remember.AutoSize = true;
            remember.Left = 24;
            remember.Top = 112;

            Button tray = new Button();
            tray.Text = "关闭到托盘";
            tray.Width = 120;
            tray.Height = 32;
            tray.Left = 112;
            tray.Top = 150;
            tray.Click += delegate { ActionChoice = "tray"; DialogResult = DialogResult.OK; Close(); };

            Button exit = new Button();
            exit.Text = "退出";
            exit.Width = 90;
            exit.Height = 32;
            exit.Left = 242;
            exit.Top = 150;
            exit.Click += delegate { ActionChoice = "exit"; DialogResult = DialogResult.OK; Close(); };

            Button cancel = new Button();
            cancel.Text = "取消";
            cancel.Width = 90;
            cancel.Height = 32;
            cancel.Left = 342;
            cancel.Top = 150;
            cancel.Click += delegate { DialogResult = DialogResult.Cancel; Close(); };

            Controls.Add(title);
            Controls.Add(desc);
            Controls.Add(remember);
            Controls.Add(tray);
            Controls.Add(exit);
            Controls.Add(cancel);

            HandleCreated += delegate { ThemeHelper.ApplyDialogTheme(this, dark); };
            ThemeHelper.ApplyDialogTheme(this, dark);
        }
    }

    internal sealed class SettingsForm : Form
    {
        private ComboBox closeCombo;
        private TextBox workdirText;
        private TextBox versionText;
        private TextBox profileText;
        private ComboBox runnerCombo;
        private NumericUpDown portBox;
        private CheckBox restoreCheck;
        private CheckBox developerCheck;
        private readonly AppSettings draft;

        public AppSettings ResultSettings { get { return draft; } }

        public SettingsForm(AppSettings value, bool dark)
        {
            draft = value == null ? new AppSettings() : value.Clone();

            Text = "DeepSeek Harness 设置";
            Width = 620;
            Height = 615;
            FormBorderStyle = FormBorderStyle.FixedDialog;
            MaximizeBox = false;
            MinimizeBox = false;
            StartPosition = FormStartPosition.CenterParent;
            ShowInTaskbar = false;

            int leftLabel = 28;
            int leftControl = 190;

            Label generalTitle = Header("常规", 22);
            Controls.Add(generalTitle);

            Label closeLabel = new Label();
            closeLabel.Text = "关闭窗口";
            closeLabel.AutoSize = true;
            closeLabel.Left = leftLabel;
            closeLabel.Top = 72;
            Controls.Add(closeLabel);

            closeCombo = new ComboBox();
            closeCombo.DropDownStyle = ComboBoxStyle.DropDownList;
            closeCombo.Items.AddRange(new object[] { "每次询问", "关闭到托盘", "关闭并退出" });
            closeCombo.Left = leftControl;
            closeCombo.Top = 67;
            closeCombo.Width = 350;
            closeCombo.SelectedIndex =
                draft.closeAction == "tray" ? 1 :
                draft.closeAction == "exit" ? 2 : 0;
            Controls.Add(closeCombo);

            Label windowTitle = Header("窗口", 118);
            Controls.Add(windowTitle);

            restoreCheck = new CheckBox();
            restoreCheck.Text = "恢复上次窗口位置和大小";
            restoreCheck.AutoSize = true;
            restoreCheck.Left = leftControl;
            restoreCheck.Top = 158;
            restoreCheck.Checked = draft.restoreWindowBounds;
            Controls.Add(restoreCheck);

            Button reset = new Button();
            reset.Text = "重置窗口位置";
            reset.Left = leftControl;
            reset.Top = 188;
            reset.Width = 120;
            reset.Click += delegate
            {
                draft.hasSavedWindowBounds = false;
                draft.windowX = 0;
                draft.windowY = 0;
                draft.windowWidth = 1440;
                draft.windowHeight = 900;
                draft.windowMaximized = false;
                ThemedMessageBox.Show(this, "保存后，下次启动将使用默认窗口位置。", "DeepSeek Harness",
                    MessageBoxButtons.OK, MessageBoxIcon.Information);
            };
            Controls.Add(reset);

            Label dshTitle = Header("DeepSeek Harness", 232);
            Controls.Add(dshTitle);

            Label workLabel = new Label();
            workLabel.Text = "默认工作目录";
            workLabel.AutoSize = true;
            workLabel.Left = leftLabel;
            workLabel.Top = 277;
            Controls.Add(workLabel);

            workdirText = new TextBox();
            workdirText.Left = leftControl;
            workdirText.Top = 271;
            workdirText.Width = 280;
            workdirText.Text = draft.workingDirectory;
            Controls.Add(workdirText);

            Button browse = new Button();
            browse.Text = "浏览...";
            browse.Left = 480;
            browse.Top = 269;
            browse.Width = 62;
            browse.Click += delegate
            {
                using (FolderBrowserDialog dialog = new FolderBrowserDialog())
                {
                    dialog.SelectedPath = Directory.Exists(workdirText.Text)
                        ? workdirText.Text
                        : Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
                    if (dialog.ShowDialog(this) == DialogResult.OK) workdirText.Text = dialog.SelectedPath;
                }
            };
            Controls.Add(browse);

            Label portLabel = new Label();
            portLabel.Text = "Web 端口";
            portLabel.AutoSize = true;
            portLabel.Left = leftLabel;
            portLabel.Top = 315;
            Controls.Add(portLabel);

            portBox = new NumericUpDown();
            portBox.Minimum = 1;
            portBox.Maximum = 65535;
            portBox.Value = draft.port;
            portBox.Left = leftControl;
            portBox.Top = 309;
            portBox.Width = 110;
            Controls.Add(portBox);

            Label profileLabel = new Label();
            profileLabel.Text = "Profile";
            profileLabel.AutoSize = true;
            profileLabel.Left = leftLabel;
            profileLabel.Top = 353;
            Controls.Add(profileLabel);

            profileText = new TextBox();
            profileText.Left = leftControl;
            profileText.Top = 347;
            profileText.Width = 180;
            profileText.Text = AppSettings.NormalizeProfileName(draft.profileName);
            Controls.Add(profileText);

            Label profileHint = new Label();
            profileHint.Text = "默认 web；插件和兼容修复均跟随此 Profile。";
            profileHint.AutoSize = true;
            profileHint.Left = 382;
            profileHint.Top = 351;
            profileHint.Tag = "secondary";
            profileHint.ForeColor = dark ? Color.Silver : Color.DimGray;
            Controls.Add(profileHint);

            Label runnerLabel = new Label();
            runnerLabel.Text = "DSH 运行方式";
            runnerLabel.AutoSize = true;
            runnerLabel.Left = leftLabel;
            runnerLabel.Top = 391;
            Controls.Add(runnerLabel);

            runnerCombo = new ComboBox();
            runnerCombo.DropDownStyle = ComboBoxStyle.DropDownList;
            runnerCombo.Items.AddRange(new object[] { "自动（优先现有 dsh，否则 npx）", "现有 dsh", "仅 npx" });
            runnerCombo.Left = leftControl;
            runnerCombo.Top = 385;
            runnerCombo.Width = 280;
            runnerCombo.SelectedIndex =
                draft.dshRunnerMode == "command" ? 1 :
                draft.dshRunnerMode == "npx" ? 2 : 0;
            Controls.Add(runnerCombo);

            Label versionLabel = new Label();
            versionLabel.Text = "npx 版本";
            versionLabel.AutoSize = true;
            versionLabel.Left = leftLabel;
            versionLabel.Top = 429;
            Controls.Add(versionLabel);

            versionText = new TextBox();
            versionText.Left = leftControl;
            versionText.Top = 423;
            versionText.Width = 180;
            versionText.Text = AppSettings.NormalizeDshVersion(draft.dshVersion);
            versionText.ReadOnly = true;
            Controls.Add(versionText);

            Label versionHint = new Label();
            versionHint.Text = "仅 npx 方式使用此版本，不做全局安装；在管理器中调整。";
            versionHint.AutoSize = true;
            versionHint.Left = 382;
            versionHint.Top = 427;
            versionHint.Tag = "secondary";
            versionHint.ForeColor = dark ? Color.Silver : Color.DimGray;
            Controls.Add(versionHint);

            Label shellTitle = Header("桌面壳", 466);
            Controls.Add(shellTitle);

            developerCheck = new CheckBox();
            developerCheck.Text = "开发者模式（允许 WebView2 DevTools）";
            developerCheck.AutoSize = true;
            developerCheck.Left = leftControl;
            developerCheck.Top = 504;
            developerCheck.Checked = draft.developerMode;
            Controls.Add(developerCheck);

            Label hint = new Label();
            hint.Text = "工作目录、端口、Profile、运行方式和开发者模式在下次启动时生效；npx 版本在管理器中调整。";
            hint.AutoSize = true;
            hint.Left = leftControl;
            hint.Top = 530;
            hint.Tag = "secondary";
            hint.ForeColor = dark ? Color.Silver : Color.DimGray;
            Controls.Add(hint);

            Button save = new Button();
            save.Text = "保存";
            save.Width = 90;
            save.Height = 32;
            save.Left = 390;
            save.Top = 544;
            save.Click += delegate
            {
                draft.closeAction =
                    closeCombo.SelectedIndex == 1 ? "tray" :
                    closeCombo.SelectedIndex == 2 ? "exit" : "ask";
                draft.restoreWindowBounds = restoreCheck.Checked;
                draft.workingDirectory = String.IsNullOrWhiteSpace(workdirText.Text)
                    ? Environment.GetFolderPath(Environment.SpecialFolder.UserProfile)
                    : workdirText.Text.Trim();
                draft.port = Decimal.ToInt32(portBox.Value);
                draft.developerMode = developerCheck.Checked;
                draft.dshVersion = AppSettings.NormalizeDshVersion(versionText.Text);
                draft.dshRunnerMode =
                    runnerCombo.SelectedIndex == 1 ? "command" :
                    runnerCombo.SelectedIndex == 2 ? "npx" : "auto";
                draft.profileName = AppSettings.NormalizeProfileName(profileText.Text);
                DialogResult = DialogResult.OK;
                Close();
            };
            Controls.Add(save);

            Button cancel = new Button();
            cancel.Text = "取消";
            cancel.Width = 90;
            cancel.Height = 32;
            cancel.Left = 490;
            cancel.Top = 544;
            cancel.Click += delegate { DialogResult = DialogResult.Cancel; Close(); };
            Controls.Add(cancel);

            HandleCreated += delegate
            {
                ThemeHelper.ApplyDialogTheme(this, dark);
                hint.ForeColor = dark ? Color.Silver : Color.DimGray;
                versionHint.ForeColor = dark ? Color.Silver : Color.DimGray;
                profileHint.ForeColor = dark ? Color.Silver : Color.DimGray;
            };
            ThemeHelper.ApplyDialogTheme(this, dark);
            hint.ForeColor = dark ? Color.Silver : Color.DimGray;
            versionHint.ForeColor = dark ? Color.Silver : Color.DimGray;
            profileHint.ForeColor = dark ? Color.Silver : Color.DimGray;
        }

        private Label Header(string text, int top)
        {
            Label label = new Label();
            label.Text = text;
            label.AutoSize = true;
            label.Left = 22;
            label.Top = top;
            label.Font = new Font(SystemFonts.MessageBoxFont.FontFamily, 10.5F, FontStyle.Bold);
            return label;
        }
    }

    /// <summary>启动阶段（用于宿主日志与“按阶段重试”路由）。</summary>
    /// <summary>
    /// 端口监听者身份四态。关键约束：任何“暂时读不到”都必须归 Pending，
    /// 绝不能等价于 Foreign——端口刚打开时 PID/命令行可能滞后数百毫秒。
    /// </summary>
    internal enum ListenerIdentity
    {
        None,           // 端口未监听
        Pending,        // 端口已开，但 PID 查不到 / 命令行暂时读不到
        OwnedJob,       // PID 属于本 DesktopShell 创建的 Job → 自己的 DSH 进程树（最强证明）
        VerifiedDsh,    // 命令行明确是 DSH（package/path + profile + port）
        Foreign         // 命令行明确不是 DSH（需 PID 稳定 + 连续多次确认）
    }

    internal enum StartupPhase
    {
        CommandVerify,
        PluginCompat,
        BackendProbe,
        Backend,
        WebViewEnvironment,
        WebViewInitialize,
        WebViewConfigure,
        Permission,
        Navigate
    }

    internal sealed class MainForm : Form
    {
        private readonly string baseDirectory;
        private readonly string settingsPath;
        private readonly string logsDirectory;
        private readonly string webViewDataDirectory;
        private readonly AppSettings settings;
        private readonly DshProcessManager dsh;
        private WebView2 webView;
        private readonly Panel loadingPanel;
        private readonly Label loadingLabel;
        private readonly Label errorTitle;
        private readonly TextBox errorDetails;
        private readonly Button copyErrorButton;
        private readonly Button overlayPrimaryButton;
        private readonly Button overlaySecondaryButton;
        private readonly NotifyIcon trayIcon;
        private readonly ContextMenuStrip trayMenu;
        private readonly System.Windows.Forms.Timer themeTimer;
        private readonly System.Windows.Forms.Timer healthTimer;
        private readonly Guid mainFormInstanceId = Guid.NewGuid();

        private EventHandler overlayPrimaryHandler;
        private EventHandler overlaySecondaryHandler;
        private bool allowExit;
        private bool currentDark;
        private bool chromeApplied;
        private bool webViewReady;
        private bool healthCheckBusy;
        private bool restartBusy;
        private bool startBusy;
        private bool hiddenToTray;
        private bool trayTransition;
        // 后端“代”：每次重启/停止递增；已飞出的健康检查完成时对比代数，旧代结果直接丢弃，
        // 避免重启期间健康检查把“后端被主动停掉”误报成“后端中断”。
        private long backendGeneration;
        // 重启当前所处阶段（RestartPhase 进入每阶段即更新；失败时外层 catch 打印它，
        // 不再停留在 preflight 误导排查）
        private string activeRestartPhase = "";
        private int healthFailures;
        private int compatPendingAtStartup;
        private StartupPhase currentPhase = StartupPhase.CommandVerify;
        private string overlayReason;
        private Icon runtimeIcon;
        private ContextMenuStrip activeWebContextMenu;

        private const int VK_CONTROL = 0x11;
        private const int VK_SHIFT = 0x10;
        private const int VK_P = 0x50;
        private const int VK_C = 0x43;
        private const int VK_I = 0x49;
        private const int VK_J = 0x4A;
        private const int VK_F12 = 0x7B;

        [DllImport("user32.dll")]
        private static extern short GetKeyState(int nVirtKey);

        public MainForm()
        {
            baseDirectory = AppDomain.CurrentDomain.BaseDirectory.TrimEnd(Path.DirectorySeparatorChar);
            settingsPath = Path.Combine(baseDirectory, "settings.json");
            logsDirectory = Path.Combine(baseDirectory, "logs");
            webViewDataDirectory = Path.Combine(baseDirectory, "webview2-data");
            settings = AppSettings.Load(settingsPath);
            dsh = new DshProcessManager();

            HostLog.Initialize(logsDirectory, mainFormInstanceId.ToString("N"));
            HostLog.Line("FORM created instance=" + mainFormInstanceId.ToString("N"));
            HostLog.Line("ENV DesktopShellVersion=" + ReadVersionText() +
                " runnerMode=" + settings.dshRunnerMode +
                " profile=" + settings.profileName +
                " port=" + settings.port.ToString() +
                " workingDirectory=" + settings.workingDirectory +
                " dshPathExists=" + (!String.IsNullOrWhiteSpace(settings.dshPath) && File.Exists(settings.dshPath)).ToString() +
                " verifiedDsh=" + DshProcessManager.VerifiedDshVersion);

            Text = "DeepSeek Harness";
            MinimumSize = new Size(960, 640);
            Width = settings.windowWidth;
            Height = settings.windowHeight;
            StartPosition = FormStartPosition.CenterScreen;
            RestoreWindowPosition();

            webView = CreateWebViewControl();
            Controls.Add(webView);

            loadingPanel = new Panel();
            loadingPanel.Dock = DockStyle.Fill;
            loadingPanel.BackColor = Color.White;

            loadingLabel = new Label();
            loadingLabel.AutoSize = false;
            loadingLabel.TextAlign = ContentAlignment.MiddleCenter;
            loadingLabel.Text = "正在启动 DeepSeek Harness...";
            loadingLabel.Font = new Font(SystemFonts.MessageBoxFont.FontFamily, 12F, FontStyle.Regular);
            loadingLabel.Height = 44;

            errorTitle = new Label();
            errorTitle.AutoSize = false;
            errorTitle.TextAlign = ContentAlignment.MiddleCenter;
            errorTitle.Font = new Font(SystemFonts.MessageBoxFont.FontFamily, 15F, FontStyle.Bold);
            errorTitle.Height = 40;
            errorTitle.Visible = false;

            errorDetails = new TextBox();
            errorDetails.Multiline = true;
            errorDetails.ReadOnly = true;
            errorDetails.ScrollBars = ScrollBars.Vertical;
            errorDetails.BorderStyle = BorderStyle.FixedSingle;
            errorDetails.BackColor = Color.FromArgb(30, 30, 30);
            errorDetails.ForeColor = Color.Gainsboro;
            errorDetails.Font = new Font("Consolas", 9F);
            errorDetails.Visible = false;

            copyErrorButton = new Button();
            copyErrorButton.Text = "复制错误";
            copyErrorButton.Width = 110;
            copyErrorButton.Height = 34;
            copyErrorButton.Visible = false;
            copyErrorButton.Click += delegate
            {
                try { Clipboard.SetText(errorDetails.Text); } catch { }
            };

            overlayPrimaryButton = new Button();
            overlayPrimaryButton.Width = 142;
            overlayPrimaryButton.Height = 34;
            overlayPrimaryButton.Visible = false;

            overlaySecondaryButton = new Button();
            overlaySecondaryButton.Width = 142;
            overlaySecondaryButton.Height = 34;
            overlaySecondaryButton.Visible = false;

            loadingPanel.Controls.Add(errorTitle);
            loadingPanel.Controls.Add(loadingLabel);
            loadingPanel.Controls.Add(errorDetails);
            loadingPanel.Controls.Add(copyErrorButton);
            loadingPanel.Controls.Add(overlayPrimaryButton);
            loadingPanel.Controls.Add(overlaySecondaryButton);
            loadingPanel.Resize += delegate { LayoutOverlay(); };

            Controls.Add(loadingPanel);
            loadingPanel.BringToFront();

            trayMenu = BuildTrayMenu();
            trayIcon = new NotifyIcon();
            trayIcon.Text = "DeepSeek Harness";
            trayIcon.Visible = true;
            trayIcon.ContextMenuStrip = trayMenu;
            trayIcon.DoubleClick += delegate { RestoreFromTray(); };

            themeTimer = new System.Windows.Forms.Timer();
            themeTimer.Interval = 1000;
            themeTimer.Tick += delegate { ApplyThemeIfChanged(); };
            themeTimer.Start();

            healthTimer = new System.Windows.Forms.Timer();
            healthTimer.Interval = 5000;
            healthTimer.Tick += async delegate { await CheckBackendHealthAsync(); };
            healthTimer.Start();

            Shown += async delegate { await StartAsync(); };
            HandleCreated += delegate
            {
                HostLog.Line("HANDLE created");
                chromeApplied = false;
                ApplyThemeIfChanged(true);
            };
            FormClosing += OnFormClosing;

            ApplyThemeIfChanged(true);
        }

        private string ReadVersionText()
        {
            try
            {
                string v = Path.Combine(baseDirectory, "version.txt");
                if (File.Exists(v))
                {
                    string raw = File.ReadAllText(v, Encoding.UTF8).Trim();
                    if (raw.Length > 0) return raw;
                }
            }
            catch { }
            return "?";
        }

        private WebView2 CreateWebViewControl()
        {
            WebView2 control = new WebView2();
            control.Dock = DockStyle.Fill;
            return control;
        }

        private void LayoutOverlay()
        {
            int panelWidth = loadingPanel.ClientSize.Width;
            int panelHeight = loadingPanel.ClientSize.Height;
            int width = Math.Min(760, Math.Max(360, panelWidth - 80));
            int left = Math.Max(20, (panelWidth - width) / 2);
            int gap = 12;

            if (errorDetails.Visible)
            {
                // 错误模式：大标题 + 消息 + 可滚动详情 + 按钮行
                errorTitle.Width = width;
                errorTitle.Left = left;
                errorTitle.Top = Math.Max(18, (panelHeight - 360) / 2 - 60);

                loadingLabel.Width = width;
                loadingLabel.Left = left;
                loadingLabel.Top = errorTitle.Bottom + 4;
                loadingLabel.Height = 44;

                errorDetails.Width = width;
                errorDetails.Left = left;
                errorDetails.Top = loadingLabel.Bottom + 10;
                errorDetails.Height = Math.Max(120, panelHeight - errorDetails.Top - 96);

                int buttonRowTop = errorDetails.Bottom + 12;
                int buttonCount = (copyErrorButton.Visible ? 1 : 0) + (overlayPrimaryButton.Visible ? 1 : 0) + (overlaySecondaryButton.Visible ? 1 : 0);
                if (buttonCount == 0) return;
                int total = (copyErrorButton.Visible ? copyErrorButton.Width + gap : 0) +
                            (overlayPrimaryButton.Visible ? overlayPrimaryButton.Width + gap : 0) +
                            (overlaySecondaryButton.Visible ? overlaySecondaryButton.Width : 0) - (buttonCount > 1 ? gap : 0);
                int bx = Math.Max(20, (panelWidth - total) / 2);
                if (copyErrorButton.Visible) { copyErrorButton.Left = bx; copyErrorButton.Top = buttonRowTop; bx += copyErrorButton.Width + gap; }
                if (overlayPrimaryButton.Visible) { overlayPrimaryButton.Left = bx; overlayPrimaryButton.Top = buttonRowTop; bx += overlayPrimaryButton.Width + gap; }
                if (overlaySecondaryButton.Visible) { overlaySecondaryButton.Left = bx; overlaySecondaryButton.Top = buttonRowTop; }
                return;
            }

            loadingLabel.Width = width;
            loadingLabel.Left = left;

            int centerY = Math.Max(100, panelHeight / 2 - 50);
            loadingLabel.Top = centerY;

            int visibleButtons = (overlayPrimaryButton.Visible ? 1 : 0) + (overlaySecondaryButton.Visible ? 1 : 0);
            if (visibleButtons == 0) return;

            int totalWidth = visibleButtons == 2
                ? overlayPrimaryButton.Width + overlaySecondaryButton.Width + gap
                : overlayPrimaryButton.Width;
            int bleft = Math.Max(20, (panelWidth - totalWidth) / 2);
            int top = loadingLabel.Bottom + 18;

            if (overlayPrimaryButton.Visible)
            {
                overlayPrimaryButton.Left = bleft;
                overlayPrimaryButton.Top = top;
                bleft += overlayPrimaryButton.Width + gap;
            }

            if (overlaySecondaryButton.Visible)
            {
                overlaySecondaryButton.Left = bleft;
                overlaySecondaryButton.Top = top;
            }
        }

        private void ShowOverlay(string reason, string message,
            string primaryText, EventHandler primaryHandler,
            string secondaryText, EventHandler secondaryHandler)
        {
            ShowOverlayInternal(reason, null, message, null, primaryText, primaryHandler, secondaryText, secondaryHandler);
        }

        /// <summary>
        /// 错误型覆盖层：大标题 + 消息 + 可滚动异常详情 + 复制按钮 + 操作按钮。
        /// detailsText 为 null 时等同 ShowOverlay（无详情区）。
        /// </summary>
        private void ShowErrorOverlay(string reason, string title, string message, string detailsText,
            string primaryText, EventHandler primaryHandler,
            string secondaryText, EventHandler secondaryHandler)
        {
            ShowOverlayInternal(reason, title, message, detailsText, primaryText, primaryHandler, secondaryText, secondaryHandler);
        }

        private void ShowOverlayInternal(string reason, string title, string message, string detailsText,
            string primaryText, EventHandler primaryHandler,
            string secondaryText, EventHandler secondaryHandler)
        {
            overlayReason = reason;
            bool errorMode = detailsText != null;

            errorTitle.Text = title ?? "";
            errorTitle.Visible = errorMode;
            loadingLabel.Text = message;
            if (errorMode)
            {
                errorDetails.Text = detailsText;
                errorDetails.Visible = true;
                copyErrorButton.Visible = true;
            }
            else
            {
                errorDetails.Visible = false;
                copyErrorButton.Visible = false;
            }

            if (overlayPrimaryHandler != null) overlayPrimaryButton.Click -= overlayPrimaryHandler;
            if (overlaySecondaryHandler != null) overlaySecondaryButton.Click -= overlaySecondaryHandler;

            overlayPrimaryHandler = primaryHandler;
            overlaySecondaryHandler = secondaryHandler;

            overlayPrimaryButton.Visible = !String.IsNullOrEmpty(primaryText) && primaryHandler != null;
            overlayPrimaryButton.Text = primaryText ?? "";
            if (overlayPrimaryButton.Visible) overlayPrimaryButton.Click += overlayPrimaryHandler;

            overlaySecondaryButton.Visible = !String.IsNullOrEmpty(secondaryText) && secondaryHandler != null;
            overlaySecondaryButton.Text = secondaryText ?? "";
            if (overlaySecondaryButton.Visible) overlaySecondaryButton.Click += overlaySecondaryHandler;

            loadingPanel.Visible = true;
            loadingPanel.BringToFront();
            LayoutOverlay();
        }

        private void HideOverlay()
        {
            overlayReason = null;
            errorDetails.Visible = false;
            copyErrorButton.Visible = false;
            errorTitle.Visible = false;
            loadingPanel.Visible = false;
        }

        private ContextMenuStrip BuildTrayMenu()
        {
            ContextMenuStrip menu = new ContextMenuStrip();

            ToolStripMenuItem show = new ToolStripMenuItem("显示 DeepSeek Harness");
            show.Click += delegate { RestoreFromTray(); };
            menu.Items.Add(show);

            ToolStripMenuItem prefs = new ToolStripMenuItem("设置...");
            prefs.Click += delegate { ShowSettings(); };
            menu.Items.Add(prefs);

            menu.Items.Add(new ToolStripSeparator());

            ToolStripMenuItem reload = new ToolStripMenuItem("重新加载页面");
            reload.Click += delegate { ReloadDshPage(); };
            menu.Items.Add(reload);

            ToolStripMenuItem restartBackend = new ToolStripMenuItem("重启 DSH 后端");
            restartBackend.Click += async delegate { await RestartBackendAsync(); };
            menu.Items.Add(restartBackend);

            ToolStripMenuItem logs = new ToolStripMenuItem("打开日志目录");
            logs.Click += delegate
            {
                try
                {
                    Directory.CreateDirectory(logsDirectory);
                    Process.Start("explorer.exe", "\"" + logsDirectory + "\"");
                }
                catch { }
            };
            menu.Items.Add(logs);

            menu.Items.Add(new ToolStripSeparator());

            ToolStripMenuItem behavior = new ToolStripMenuItem("关闭行为");
            ToolStripMenuItem ask = new ToolStripMenuItem("每次询问");
            ToolStripMenuItem tray = new ToolStripMenuItem("关闭到托盘");
            ToolStripMenuItem exit = new ToolStripMenuItem("关闭并退出");

            EventHandler refreshChecks = delegate
            {
                ask.Checked = settings.closeAction == "ask";
                tray.Checked = settings.closeAction == "tray";
                exit.Checked = settings.closeAction == "exit";
            };

            ask.Click += delegate
            {
                settings.closeAction = "ask";
                settings.Save(settingsPath);
                refreshChecks(null, EventArgs.Empty);
            };
            tray.Click += delegate
            {
                settings.closeAction = "tray";
                settings.Save(settingsPath);
                refreshChecks(null, EventArgs.Empty);
            };
            exit.Click += delegate
            {
                settings.closeAction = "exit";
                settings.Save(settingsPath);
                refreshChecks(null, EventArgs.Empty);
            };

            behavior.DropDownOpening += refreshChecks;
            behavior.DropDownItems.Add(ask);
            behavior.DropDownItems.Add(tray);
            behavior.DropDownItems.Add(exit);
            menu.Items.Add(behavior);

            menu.Items.Add(new ToolStripSeparator());

            ToolStripMenuItem quit = new ToolStripMenuItem("退出 DeepSeek Harness");
            // 退出动作延迟到当前 ToolStrip 点击消息完成后执行，避免 Click handler 返回后
            // WinForms 自动收起菜单时访问已 Dispose 的 ContextMenuStrip。
            quit.Click += delegate { BeginInvoke((MethodInvoker)ShutdownAndClose); };
            menu.Items.Add(quit);

            return menu;
        }

        private async Task StartAsync()
        {
            if (startBusy) return;
            startBusy = true;
            currentPhase = StartupPhase.CommandVerify;
            ShowOverlay("startup", "正在启动 DeepSeek Harness...", null, null, null, null);

            try
            {
                // 阶段一：命令验证 —— 每次启动前重新验证现有 dsh 命令的版本
                //（command/auto 模式）：与上次 accepted 的版本比对，变化/无法读取时询问用户。
                HostLog.Enter("START phase=" + currentPhase.ToString());
                ConfirmCommandVersionBeforeStart();
                HostLog.Ok("START phase=CommandVerify");

                DshProcessManager.ExternalBackendInfo probe = null;
                bool restartExternal = false;
                bool attachUnverified = false;

                // 阶段二：后端探测 + 兼容补丁。
                // 规则：只要端口已经打开，启动前绝不写兼容补丁（不依赖第一次 PID/命令行
                // 识别一定成功）；只有端口原本为空时才“补丁 → 启动自己的 DSH”。
                currentPhase = StartupPhase.BackendProbe;
                HostLog.Enter("START phase=BackendProbe");
                await Task.Run(delegate
                {
                    probe = dsh.ProbeExternalDsh(settings.port);
                    compatPendingAtStartup = PluginCompat.ApplyAll(
                        baseDirectory, logsDirectory, settings.profileName, !probe.PortOpen);
                });
                HostLog.Ok("START phase=BackendProbe portOpen=" + (probe != null && probe.PortOpen).ToString());

                // 外部 backend 必须单独通过版本验证（runnerMode 只管启动方式）。
                if (probe != null && probe.PortOpen && probe.IsDsh && !probe.IsVerified)
                {
                    string shown = String.IsNullOrWhiteSpace(probe.CommandLine)
                        ? "（无法读取命令行）" : probe.CommandLine;
                    DialogResult confirm = ThemedMessageBox.Show(
                        this,
                        "端口 " + settings.port.ToString() + " 上已有一个 DSH 后端在运行，但它未通过版本验证：\r\n" +
                        (String.IsNullOrEmpty(probe.Version)
                            ? "无法从命令行读取其版本。"
                            : "其版本为 " + probe.Version + "。") +
                        "\r\nDesktopShell 验证基线：" + DshProcessManager.VerifiedDshVersion +
                        "。\r\n\r\n命令行：\r\n" + shown +
                        "\r\n\r\n选择“是”继续附着该后端；选择“否”结束它并由桌面壳按当前设置重新启动。",
                        "DeepSeek Harness",
                        MessageBoxButtons.YesNo,
                        MessageBoxIcon.Warning);
                    if (confirm == DialogResult.No)
                        restartExternal = true;
                    else
                        attachUnverified = true;   // 是 / 取消都按非破坏性处理：附着
                }

                // 阶段三：启动（或附着）后端 —— 仅当本窗体不拥有、或拥有的后端已不在运行时
                // 才真正执行；已在运行的 owned 后端绝不再启动第二次，避免“重试启动”误伤健康后端。
                currentPhase = StartupPhase.Backend;
                HostLog.Enter("START phase=Backend");
                await Task.Run(delegate
                {
                    if (restartExternal)
                    {
                        // 用户已确认结束外部后端：停止 → 补丁 → 启动自己的 DSH
                        dsh.StopBackend(settings.port, true);
                        PluginCompat.ApplyAll(baseDirectory, logsDirectory, settings.profileName, true);
                        compatPendingAtStartup = 0;
                    }
                    if (!dsh.BackendRunning)
                    {
                        dsh.EnsureStarted(
                            settings.port,
                            settings.workingDirectory,
                            logsDirectory,
                            settings.dshVersion,
                            settings.profileName,
                            settings.dshPath,
                            settings.dshRunnerMode,
                            attachUnverified);
                    }
                });
                HostLog.Ok("START phase=Backend");

                // 阶段四：WebView2 环境
                currentPhase = StartupPhase.WebViewEnvironment;
                HostLog.Enter("START phase=WebViewEnvironment");
                loadingLabel.Text = "正在初始化 WebView2...";
                Directory.CreateDirectory(webViewDataDirectory);
                CoreWebView2Environment env = await CoreWebView2Environment.CreateAsync(null, webViewDataDirectory);
                HostLog.Ok("START phase=WebViewEnvironment");

                // 阶段五：WebView2 初始化
                currentPhase = StartupPhase.WebViewInitialize;
                HostLog.Enter("START phase=WebViewInitialize");
                await webView.EnsureCoreWebView2Async(env);
                HostLog.Ok("START phase=WebViewInitialize");

                // 阶段六：WebView2 配置
                currentPhase = StartupPhase.WebViewConfigure;
                HostLog.Enter("START phase=WebViewConfigure");
                await ConfigureWebViewAsync();
                HostLog.Ok("START phase=WebViewConfigure");

                // 阶段七：通知权限
                currentPhase = StartupPhase.Permission;
                HostLog.Enter("START phase=Permission");
                await GrantDshNotificationPermissionAsync();
                HostLog.Ok("START phase=Permission");

                // 阶段八：导航
                currentPhase = StartupPhase.Navigate;
                HostLog.Enter("START phase=Navigate");
                webViewReady = true;
                healthFailures = 0;
                webView.CoreWebView2.Navigate(DshHomeUrl());
                HideOverlay();
                HostLog.Ok("START complete");

                if (compatPendingAtStartup > 0)
                {
                    ShowOverlay(
                        "compat",
                        "检测到外部 DSH 后端正在运行。为避免与运行中的后端冲突，本次未执行 " +
                        compatPendingAtStartup.ToString() + " 项兼容修复。\r\n\r\n" +
                        "点击“重启 DSH 后端”接管后端后会自动完成修复。",
                        "重启 DSH 后端",
                        OnOverlayRestartBackend,
                        "稍后",
                        OnOverlayDismiss);
                }
            }
            catch (Exception ex)
            {
                HostLog.Fail("START failed phase=" + currentPhase.ToString(), ex);
                webViewReady = false;
                HandleStartupError(ex);
            }
            finally
            {
                startBusy = false;
            }
        }

        /// <summary>
        /// 启动失败的错误型覆盖层：标题 + 消息 + 可滚动异常详情 + 复制错误按钮，并按失败
        /// 阶段给出对应重试路径。缺少 WebView2 Runtime 时单独给出官方下载入口。
        /// </summary>
        private void HandleStartupError(Exception ex)
        {
            webViewReady = false;

            // 缺少 WebView2 Runtime 是普通用户最常见的启动失败原因：
            // 单独给明确提示与官方下载入口，而不是笼统的“启动失败”。
            bool missingWebView2 = ex.Message.IndexOf("WebView2", StringComparison.OrdinalIgnoreCase) >= 0;

            string message;
            string primaryText;
            EventHandler primaryHandler;
            if (missingWebView2)
            {
                message = "缺少 WebView2 Runtime，无法启动界面。\r\n\r\n" + ex.Message +
                          "\r\n\r\n下载地址：https://go.microsoft.com/fwlink/p/?LinkId=2124703";
                primaryText = "下载 WebView2 Runtime";
                primaryHandler = OnOverlayOpenWebView2Download;
            }
            else
            {
                // 阶段感知的重试：
                //   后端类失败（CommandVerify/BackendProbe/Backend）→ 重启后端；
                //   WebView2 类失败（Environment/Initialize）→ 只重建 WebView2，不碰后端；
                //   配置/权限/导航类失败 → 整体重试（有 BackendRunning 保护，不误杀健康后端）。
                EventHandler retryHandler;
                string phaseName;
                switch (currentPhase)
                {
                    case StartupPhase.CommandVerify:
                    case StartupPhase.BackendProbe:
                    case StartupPhase.Backend:
                        phaseName = "DSH 后端";
                        retryHandler = OnOverlayRestartBackend;
                        break;
                    case StartupPhase.WebViewEnvironment:
                    case StartupPhase.WebViewInitialize:
                        phaseName = "WebView2 初始化";
                        retryHandler = OnOverlayRetryWebView;
                        break;
                    case StartupPhase.WebViewConfigure:
                        phaseName = "WebView2 配置";
                        retryHandler = OnOverlayRetryConfigure;
                        break;
                    case StartupPhase.Permission:
                        phaseName = "通知权限";
                        retryHandler = OnOverlayRetryStart;
                        break;
                    default:
                        phaseName = "页面加载";
                        retryHandler = OnOverlayRetryStart;
                        break;
                }
                message = "启动失败（" + phaseName + "阶段）。\r\n\r\n" + ex.Message;
                primaryText = "重试";
                primaryHandler = retryHandler;
            }

            ShowErrorOverlay(
                "startup-error",
                "启动失败",
                message,
                ex.ToString(),
                primaryText,
                primaryHandler,
                "打开日志目录",
                OnOverlayOpenLogs);
        }

        /// <summary>
        /// WebView2 环境/初始化阶段失败后的重试入口：真正重建 WebView2 控件，
        /// 绝不停止或重启后端（WebView 失败不该碰健康 DSH）。
        /// </summary>
        private async Task RetryWebViewAsync()
        {
            await ReplaceWebViewControlAsync();
        }

        /// <summary>
        /// 真·重建 WebView2 控件（不再是同一控件上重复 CreateAsync/EnsureCoreWebView2Async）：
        /// 摘除旧控件并 Dispose → 新建控件 → 重新初始化/配置/权限/导航。
        /// 失败时只影响 WebView，后端保持原样。
        /// </summary>
        private async Task ReplaceWebViewControlAsync()
        {
            try
            {
                currentPhase = StartupPhase.WebViewEnvironment;
                HostLog.Enter("RETRY-WEBVIEW phase=replace-control");
                ShowOverlay("startup", "正在重建 WebView2...", null, null, null, null);

                // 摘除旧控件：CoreWebView2 处理器由 ConfigureWebViewAsync 以「先摘除再挂接」
                // 模式注册，控件级无其它事件订阅；直接移除并释放控件即可，不会残留处理器。
                WebView2 old = webView;
                try { Controls.Remove(old); } catch { }
                try { old.Dispose(); } catch { }

                webView = CreateWebViewControl();
                Controls.Add(webView);
                webView.BringToFront();
                loadingPanel.BringToFront();
                webViewReady = false;

                Directory.CreateDirectory(webViewDataDirectory);
                CoreWebView2Environment env = await CoreWebView2Environment.CreateAsync(null, webViewDataDirectory);
                HostLog.Ok("RETRY-WEBVIEW phase=replace-control");

                currentPhase = StartupPhase.WebViewInitialize;
                HostLog.Enter("RETRY-WEBVIEW phase=initialize");
                await webView.EnsureCoreWebView2Async(env);
                HostLog.Ok("RETRY-WEBVIEW phase=initialize");

                currentPhase = StartupPhase.WebViewConfigure;
                await ConfigureWebViewAsync();

                currentPhase = StartupPhase.Permission;
                await GrantDshNotificationPermissionAsync();

                currentPhase = StartupPhase.Navigate;
                webViewReady = true;
                healthFailures = 0;
                webView.CoreWebView2.Navigate(DshHomeUrl());
                HideOverlay();
                HostLog.Ok("RETRY-WEBVIEW complete");
            }
            catch (Exception ex)
            {
                HostLog.Fail("RETRY-WEBVIEW failed phase=" + currentPhase.ToString(), ex);
                webViewReady = false;
                HandleStartupError(ex);
            }
        }

        /// <summary>
        /// WebView2 配置阶段失败后的重试：只重跑配置（处理器先摘除再挂接，不会叠加），
        /// 后端与已初始化的 WebView2 都不动。
        /// </summary>
        private async Task RetryConfigureAsync()
        {
            try
            {
                currentPhase = StartupPhase.WebViewConfigure;
                HostLog.Enter("RETRY-CONFIGURE");
                ShowOverlay("startup", "正在重新配置 WebView2...", null, null, null, null);

                await ConfigureWebViewAsync();
                HostLog.Ok("RETRY-CONFIGURE phase=WebViewConfigure");

                currentPhase = StartupPhase.Permission;
                await GrantDshNotificationPermissionAsync();

                currentPhase = StartupPhase.Navigate;
                webViewReady = true;
                healthFailures = 0;
                webView.CoreWebView2.Navigate(DshHomeUrl());
                HideOverlay();
                HostLog.Ok("RETRY-CONFIGURE complete");
            }
            catch (Exception ex)
            {
                HostLog.Fail("RETRY-CONFIGURE failed phase=" + currentPhase.ToString(), ex);
                webViewReady = false;
                HandleStartupError(ex);
            }
        }

        private async Task ConfigureWebViewAsync()
        {
            if (webView.CoreWebView2 == null) return;

            CoreWebView2 core = webView.CoreWebView2;

            // 先摘除再挂接：配置阶段失败后重试（RetryConfigureAsync）时不会叠加重复处理器。
            core.NewWindowRequested -= OnWebViewNewWindowRequested;
            core.NavigationStarting -= OnWebViewNavigationStarting;
            core.NavigationCompleted -= OnWebViewNavigationCompleted;
            core.PermissionRequested -= OnWebViewPermissionRequested;
            core.ContextMenuRequested -= OnWebContextMenuRequested;
            core.ProcessFailed -= OnWebViewProcessFailed;

            core.NewWindowRequested += OnWebViewNewWindowRequested;
            core.NavigationStarting += OnWebViewNavigationStarting;
            core.NavigationCompleted += OnWebViewNavigationCompleted;
            core.PermissionRequested += OnWebViewPermissionRequested;
            core.ContextMenuRequested += OnWebContextMenuRequested;
            core.ProcessFailed += OnWebViewProcessFailed;

            CoreWebView2Settings viewSettings = core.Settings;
            viewSettings.AreDevToolsEnabled = settings.developerMode;

            // Keep ContextMenuRequested alive, then always mark the event handled and
            // draw our own native menu.  Setting this false would suppress the event too.
            viewSettings.AreDefaultContextMenusEnabled = true;

            // Deliberately keep browser accelerators ON so Ctrl+F, Ctrl+/mouse-wheel zoom,
            // Ctrl++/Ctrl+- and F3 continue to work.  We selectively suppress only the
            // browser chrome shortcuts that do not belong in a standalone app.
            viewSettings.AreBrowserAcceleratorKeysEnabled = true;
            viewSettings.IsZoomControlEnabled = true;
            viewSettings.IsStatusBarEnabled = false;
            viewSettings.IsBuiltInErrorPageEnabled = false;

            // The WinForms WebView2 documentation still lists an AcceleratorKeyPressed
            // event, but the shipping .NET control does not expose it (MicrosoftEdge/
            // WebView2Feedback #2151). Keep browser accelerators enabled so Ctrl+F and
            // zoom continue to work, and suppress only desktop-inappropriate shortcuts
            // inside the document instead. AreDevToolsEnabled remains the host-side
            // authority for F12 / inspector availability.
            string shortcutGuard = @"(() => {
  if (window.__dshDesktopShortcutGuardInstalled) return;
  window.__dshDesktopShortcutGuardInstalled = true;
  const developerMode = " + (settings.developerMode ? "true" : "false") + @";
  window.addEventListener('keydown', (event) => {
    const key = String(event.key || '').toLowerCase();
    const ctrl = event.ctrlKey || event.metaKey;
    const shift = event.shiftKey;
    let block = false;

    // Keep Ctrl+F / F3 and Ctrl+plus/minus/0 zoom behavior untouched.
    if (ctrl && key === 'p') block = true;
    if (!developerMode && (
      key === 'f12' ||
      (ctrl && shift && (key === 'i' || key === 'j' || key === 'c'))
    )) block = true;

    if (block) {
      event.preventDefault();
      event.stopImmediatePropagation();
    }
  }, true);
})();";
            await core.AddScriptToExecuteOnDocumentCreatedAsync(shortcutGuard);
        }

        private void OnWebViewNewWindowRequested(object sender, CoreWebView2NewWindowRequestedEventArgs e)
        {
            e.Handled = true;
            OpenExternalUri(e.Uri);
        }

        private void OnWebViewNavigationStarting(object sender, CoreWebView2NavigationStartingEventArgs e)
        {
            if (!IsAllowedMainNavigation(e.Uri))
            {
                e.Cancel = true;
                OpenExternalUri(e.Uri);
            }
        }

        private void OnWebViewNavigationCompleted(object sender, CoreWebView2NavigationCompletedEventArgs e)
        {
            if (!e.IsSuccess)
            {
                ShowOverlay(
                    "navigation",
                    "DSH 页面加载失败。\r\n\r\n" + e.WebErrorStatus.ToString(),
                    "重新加载",
                    OnOverlayReloadPage,
                    "重启 DSH 后端",
                    OnOverlayRestartBackend);
            }
            else if (overlayReason == "navigation" || overlayReason == "backend")
            {
                HideOverlay();
            }
        }

        private void OnWebViewPermissionRequested(object sender, CoreWebView2PermissionRequestedEventArgs e)
        {
            try
            {
                if (e.PermissionKind == CoreWebView2PermissionKind.Notifications && IsDshLoopbackOrigin(e.Uri))
                {
                    e.State = CoreWebView2PermissionState.Allow;
                    e.SavesInProfile = true;
                    e.Handled = true;
                }
            }
            catch { }
        }

        private void OnWebContextMenuRequested(object sender, CoreWebView2ContextMenuRequestedEventArgs e)
        {
            e.Handled = true;
            CoreWebView2Deferral deferral = e.GetDeferral();

            try
            {
                if (activeWebContextMenu != null)
                {
                    ContextMenuStrip previous = activeWebContextMenu;
                    activeWebContextMenu = null;
                    // 只关闭旧菜单，Dispose 延迟到当前 WinForms 菜单消息处理完成之后，
                    // 避免在 ToolStripDropDown 的 Close/SetVisibleCore 调用栈中同步释放。
                    if (!previous.IsDisposed)
                        previous.Close();
                    DisposeWebContextMenuDeferred(previous);
                }

                ContextMenuStrip menu = new ContextMenuStrip();
                ApplyMenuTheme(menu, currentDark);
                activeWebContextMenu = menu;

                CoreWebView2ContextMenuTarget target = e.ContextMenuTarget;
                bool any = false;

                if (target != null && target.IsEditable)
                {
                    any |= AddBuiltInContextItem(menu, e, "undo", "撤销");
                    any |= AddBuiltInContextItem(menu, e, "redo", "重做");
                    AddContextSeparator(menu);
                    any |= AddBuiltInContextItem(menu, e, "cut", "剪切");
                    any |= AddBuiltInContextItem(menu, e, "copy", "复制");
                    any |= AddBuiltInContextItem(menu, e, "paste", "粘贴");
                    any |= AddBuiltInContextItem(menu, e, "pasteAndMatchStyle", "粘贴为纯文本");
                    AddContextSeparator(menu);
                    any |= AddBuiltInContextItem(menu, e, "selectAll", "全选");
                }
                else if (target != null && target.HasSelection && !String.IsNullOrEmpty(target.SelectionText))
                {
                    string selectedText = target.SelectionText;
                    ToolStripMenuItem copySelection = new ToolStripMenuItem("复制");
                    copySelection.Click += delegate
                    {
                        try { Clipboard.SetText(selectedText); } catch { }
                    };
                    menu.Items.Add(copySelection);
                    any = true;
                }

                if (target != null && target.HasLinkUri && !String.IsNullOrWhiteSpace(target.LinkUri))
                {
                    if (any) AddContextSeparator(menu);
                    string link = target.LinkUri;

                    ToolStripMenuItem openLink = new ToolStripMenuItem("在默认浏览器中打开链接");
                    openLink.Click += delegate { OpenExternalUri(link); };
                    menu.Items.Add(openLink);

                    ToolStripMenuItem copyLink = new ToolStripMenuItem("复制链接地址");
                    copyLink.Click += delegate
                    {
                        try { Clipboard.SetText(link); } catch { }
                    };
                    menu.Items.Add(copyLink);
                    any = true;
                }

                if (target != null && target.HasSourceUri && !String.IsNullOrWhiteSpace(target.SourceUri))
                {
                    if (any) AddContextSeparator(menu);
                    any |= AddBuiltInContextItem(menu, e, "copyImage", "复制图片");

                    string source = target.SourceUri;
                    ToolStripMenuItem copySource = new ToolStripMenuItem("复制资源地址");
                    copySource.Click += delegate
                    {
                        try { Clipboard.SetText(source); } catch { }
                    };
                    menu.Items.Add(copySource);
                    any = true;
                }

                if (settings.developerMode)
                {
                    if (any) AddContextSeparator(menu);
                    ToolStripMenuItem devTools = new ToolStripMenuItem("打开开发者工具");
                    devTools.Click += delegate
                    {
                        try
                        {
                            if (webView.CoreWebView2 != null)
                                webView.CoreWebView2.OpenDevToolsWindow();
                        }
                        catch { }
                    };
                    menu.Items.Add(devTools);
                    any = true;
                }

                TrimContextSeparators(menu);

                if (!any || menu.Items.Count == 0)
                {
                    menu.Dispose();
                    activeWebContextMenu = null;
                    deferral.Complete();
                    return;
                }

                bool deferralCompleted = false;

                menu.Closed += delegate
                {
                    if (!deferralCompleted)

                    {

                        try { deferral.Complete(); } catch { }

                        deferralCompleted = true;

                    }

                    DisposeWebContextMenuDeferred(menu);

                    if (Object.ReferenceEquals(activeWebContextMenu, menu))
                        activeWebContextMenu = null;
                };

                Point screenPoint = webView.PointToScreen(e.Location);
                menu.Show(screenPoint);
            }
            catch
            {
                try { deferral.Complete(); } catch { }
            }
        }

        /// <summary>
        /// 延迟释放 WebView 右键菜单。菜单的 Closed/替换路径可能正处在 WinForms
        /// ToolStripDropDown 的关闭消息处理中，此时同步 Dispose 会让框架继续访问已释放对象；
        /// 放到 UI 线程下一条消息再释放，避免 ObjectDisposedException。
        /// </summary>
        private void DisposeWebContextMenuDeferred(ContextMenuStrip menu)
        {
            if (menu == null) return;
            try
            {
                BeginInvoke((MethodInvoker)delegate
                {
                    if (!menu.IsDisposed)
                        menu.Dispose();
                });
            }
            catch (InvalidOperationException)
            {
                // 窗体已关闭/句柄不可用时不会有活动菜单消息，直接释放是安全的。
                if (!menu.IsDisposed)
                    menu.Dispose();
            }
        }


        private bool AddBuiltInContextItem(ContextMenuStrip menu,
            CoreWebView2ContextMenuRequestedEventArgs args, string name, string label)
        {
            CoreWebView2ContextMenuItem found = null;
            foreach (CoreWebView2ContextMenuItem item in args.MenuItems)
            {
                if (String.Equals(item.Name, name, StringComparison.OrdinalIgnoreCase))
                {
                    found = item;
                    break;
                }
            }

            if (found == null) return false;

            int commandId = found.CommandId;
            ToolStripMenuItem hostItem = new ToolStripMenuItem(label);
            hostItem.Enabled = found.IsEnabled;
            hostItem.Click += delegate { args.SelectedCommandId = commandId; };
            menu.Items.Add(hostItem);
            return true;
        }

        private static void AddContextSeparator(ContextMenuStrip menu)
        {
            if (menu.Items.Count == 0) return;
            if (menu.Items[menu.Items.Count - 1] is ToolStripSeparator) return;
            menu.Items.Add(new ToolStripSeparator());
        }

        private static void TrimContextSeparators(ContextMenuStrip menu)
        {
            while (menu.Items.Count > 0 && menu.Items[0] is ToolStripSeparator)
                menu.Items.RemoveAt(0);
            while (menu.Items.Count > 0 && menu.Items[menu.Items.Count - 1] is ToolStripSeparator)
                menu.Items.RemoveAt(menu.Items.Count - 1);
        }

        private void OnWebViewProcessFailed(object sender, CoreWebView2ProcessFailedEventArgs e)
        {
            string kind = e.ProcessFailedKind.ToString();
            if (kind.IndexOf("Unresponsive", StringComparison.OrdinalIgnoreCase) >= 0) return;

            ShowOverlay(
                "webview-failed",
                "WebView2 进程异常退出。\r\n\r\n" + kind,
                "重新加载页面",
                OnOverlayReloadPage,
                "重启桌面壳",
                OnOverlayRestartApp);
        }

        private async Task GrantDshNotificationPermissionAsync()
        {
            if (webView.CoreWebView2 == null) return;

            string port = settings.port.ToString();
            string[] origins = new string[]
            {
                "http://127.0.0.1:" + port,
                "http://localhost:" + port
            };

            foreach (string origin in origins)
            {
                try
                {
                    await webView.CoreWebView2.Profile.SetPermissionStateAsync(
                        CoreWebView2PermissionKind.Notifications,
                        origin,
                        CoreWebView2PermissionState.Allow);
                }
                catch { }
            }
        }

        private async Task CheckBackendHealthAsync()
        {
            if (!webViewReady || restartBusy || healthCheckBusy) return;
            healthCheckBusy = true;
            long generation = backendGeneration;   // 记录本次检查所属代
            try
            {
                bool ready = await Task.Run(delegate { return dsh.IsDshHealthy(settings.port, 350); });
                // 检查期间发生了重启/停止：旧代结果不可信，直接丢弃（不得改 healthFailures / 覆盖 Overlay）
                if (generation != backendGeneration) return;
                if (ready)
                {
                    healthFailures = 0;
                    if (overlayReason == "backend") HideOverlay();
                    return;
                }

                healthFailures++;
                if (healthFailures >= 2)
                {
                    ShowOverlay(
                        "backend",
                        "DSH 后端连接已中断。",
                        "重启 DSH 后端",
                        OnOverlayRestartBackend,
                        "重新检查",
                        OnOverlayRetryHealth);
                }
            }
            finally
            {
                healthCheckBusy = false;
            }
        }

        /// <summary>重启事务的阶段包装：进入即更新 activeRestartPhase，ENTER / OK / FAIL
        ///（失败记录后原样抛出，中止后续阶段；外层 catch 打印 activeRestartPhase 定位失败阶段）。</summary>
        private void RestartPhase(string phase, Action action)
        {
            activeRestartPhase = phase;
            HostLog.Enter("RESTART phase=" + phase);
            try
            {
                action();
                HostLog.Ok("RESTART phase=" + phase);
            }
            catch (Exception ex)
            {
                HostLog.Fail("RESTART phase=" + phase, ex);
                throw;
            }
        }

        /// <summary>
        /// 每次真正启动 command/auto 模式的现有 dsh 前，重新读取 dsh --version 并与上次
        /// accepted 的版本比对（保存的 dshPath 可能在安装后被升级成新版本）。变化或无法
        /// 读取时询问用户：确认后更新 acceptedDshCommandPath/Version 并继续；拒绝则抛错
        /// 取消本次启动。npx 模式或没有 dsh 时不做校验。
        /// </summary>
        /// <summary>
        /// 每次真正启动现有 dsh 前重新验证。统一规则（与 PowerShell 端完全一致）：
        /// 只要本次最终 runner 解析结果是「使用现有 dsh」：
        ///   acceptedPath 为空 / acceptedVersion 为空 / actualPath != acceptedPath /
        ///   actualVersion 为空 / actualVersion != acceptedVersion
        ///   → 必须重新验证
        /// 分情况：
        ///   actualVersion == COMPATIBILITY.verifiedDshVersion → 自动接受并写入 accepted
        ///   actualVersion != verified → 交互询问（确认后更新 accepted；拒绝则取消启动）
        ///   无法读取版本 → 交互询问
        /// </summary>
        private void ConfirmCommandVersionBeforeStart()
        {
            if (settings.dshRunnerMode == "npx") return;

            string command = settings.dshPath;
            if (String.IsNullOrWhiteSpace(command) || !File.Exists(command))
                command = DshProcessManager.FindCommand("dsh");
            if (String.IsNullOrWhiteSpace(command) || !File.Exists(command))
                return;   // 没有 dsh：交给 EnsureStarted 走 npx 或报错

            string acceptedPath = settings.acceptedDshCommandPath ?? "";
            string accepted = settings.acceptedDshCommandVersion ?? "";
            string actual = DshProcessManager.GetCommandVersion(command);

            bool pathChanged =
                !String.IsNullOrEmpty(acceptedPath) &&
                !String.Equals(acceptedPath, command, StringComparison.OrdinalIgnoreCase);
            bool needsVerify =
                String.IsNullOrEmpty(acceptedPath) ||
                String.IsNullOrEmpty(accepted) ||
                pathChanged ||
                String.IsNullOrEmpty(actual) ||
                actual != accepted;
            if (!needsVerify) return;

            // 与验证基线一致 → 自动接受并写入 accepted（无需打扰用户）
            if (!String.IsNullOrEmpty(actual) && DshProcessManager.IsVerifiedDshVersion(actual))
            {
                settings.acceptedDshCommandPath = command;
                settings.acceptedDshCommandVersion = actual;
                settings.Save(settingsPath);
                return;
            }

            string detail = String.IsNullOrEmpty(actual)
                ? "无法读取其版本（上次记录：" + (String.IsNullOrEmpty(accepted) ? "无" : accepted) + "）。"
                : "其版本为 " + actual + "（上次记录：" + (String.IsNullOrEmpty(accepted) ? "无" : accepted) + "）。";
            if (pathChanged)
                detail += "\r\n（命令路径也已变化，当前为：" + command + "）";
            DialogResult confirm = ThemedMessageBox.Show(
                this,
                "现有 dsh 命令：" + command + "\r\n\r\n" + detail +
                "\r\nDesktopShell 每次启动前都会重新验证现有 dsh。\r\n\r\n" +
                "选择“是”继续使用并记住新版本；选择“否”取消本次启动（可在设置中改用 npx）。",
                "DeepSeek Harness",
                MessageBoxButtons.YesNo,
                MessageBoxIcon.Warning);
            if (confirm != DialogResult.Yes)
                throw new InvalidOperationException(
                    "已取消启动：现有 dsh 版本未确认。请确认后重试，或在设置中把运行方式改为 npx。");

            settings.acceptedDshCommandPath = command;
            settings.acceptedDshCommandVersion = actual ?? "";
            settings.Save(settingsPath);
        }

        private async Task RestartBackendAsync()
        {
            if (restartBusy) return;
            restartBusy = true;
            activeRestartPhase = "restart.preflight";
            HostLog.Enter("RESTART phase=restart.preflight");

            // 重启期间停掉 5 秒健康检查并递增代数：已飞出的旧代检查结果全部作废，
            // 不允许重启期间出现“后端连接已中断”假警报。
            healthTimer.Stop();
            backendGeneration++;

            try
            {
                bool allowExternal = false;

                // 重启同样先重新验证现有 dsh 命令版本（command/auto 模式）
                ConfirmCommandVersionBeforeStart();

                if (!dsh.OwnsBackend && dsh.IsReady(settings.port, 300))
                {
                    int externalPid = dsh.FindListeningPid(settings.port);
                    if (externalPid <= 0)
                        throw new InvalidOperationException("端口正在监听，但无法读取监听进程 PID。");

                    string commandLine;
                    if (!dsh.IsLikelyDshProcess(externalPid, out commandLine, settings.port))
                        throw new InvalidOperationException(
                            "端口 " + settings.port.ToString() + " 的监听进程不像 DSH，桌面壳拒绝结束它。\r\n\r\n" +
                            (String.IsNullOrWhiteSpace(commandLine) ? "无法读取命令行。" : commandLine));

                    DialogResult confirm = ThemedMessageBox.Show(this,
                        "当前 DSH Web 不是由桌面壳启动的（PID " + externalPid.ToString() + "）。\r\n\r\n" +
                        "已确认它的命令行属于 DSH Web。是否结束该进程并由桌面壳重新启动？",
                        "重启 DSH 后端",
                        MessageBoxButtons.YesNo,
                        MessageBoxIcon.Warning);
                    if (confirm != DialogResult.Yes) return;
                    allowExternal = true;
                }
                HostLog.Ok("RESTART phase=restart.preflight");

                ShowOverlay("restart", "正在重启 DSH 后端...", null, null, null, null);

                await Task.Run(delegate
                {
                    // restart.snapshot：旧进程还活着、命令行还可读时冻结 listener 身份
                    //（写入 ownedListenerPid），记录旧 wrapper/listener PID、ownsBackend、port
                    RestartPhase("restart.snapshot", delegate
                    {
                        dsh.FreezeOwnedListener(settings.port);
                        int oldWrapperPid = dsh.WrapperPid;
                        int oldListenerPid = dsh.OwnedListenerPid > 0
                            ? dsh.OwnedListenerPid
                            : dsh.FindListeningPid(settings.port);
                        HostLog.Line("SNAPSHOT oldWrapperPid=" + oldWrapperPid.ToString() +
                            " oldListenerPid=" + oldListenerPid.ToString() +
                            " ownsBackend=" + dsh.OwnsBackend.ToString() +
                            " port=" + settings.port.ToString());
                    });

                    if (dsh.OwnsBackend)
                    {
                        // restart.stop-wrapper：Job 关闭 → Kill wrapper → WaitForExit(3s)
                        RestartPhase("restart.stop-wrapper", delegate { dsh.StopOwnedWrapper(); });
                        // restart.stop-listener-fallback：端口仍开时，身份验证后才结束真正 listener
                        RestartPhase("restart.stop-listener-fallback", delegate { dsh.TryStopListenerFallback(settings.port); });
                    }
                    else if (allowExternal)
                    {
                        RestartPhase("restart.stop-wrapper", delegate { dsh.StopExternalBackend(settings.port); });
                        RestartPhase("restart.stop-listener-fallback", delegate { });
                    }
                    else
                    {
                        HostLog.Ok("RESTART phase=restart.stop-wrapper (nothing to stop)");
                        HostLog.Ok("RESTART phase=restart.stop-listener-fallback (nothing to stop)");
                    }

                    // restart.wait-port-close：端口连续两次确认关闭，10 秒门禁
                    RestartPhase("restart.wait-port-close", delegate
                    {
                        if (!dsh.WaitForPortClosedTwice(settings.port, 10000))
                            throw new InvalidOperationException(
                                "旧的 DSH Web 在 10 秒内没有释放端口 " + settings.port.ToString() + "。");
                    });

                    // restart.compat：兼容修复在「停止旧后端之后、启动新后端之前」执行——
                    // 升级插件后点“重启 DSH 后端”也能吃到兼容补丁
                    //（账本清理也不会被旧后端关停写回覆盖）。
                    RestartPhase("restart.compat", delegate
                    {
                        PluginCompat.ApplyAll(baseDirectory, logsDirectory, settings.profileName, true);
                    });

                    // restart.start：启动（或附着）新后端——EnsureStarted 成功即已确认
                    // listener 归属并写入 ownedListenerPid，直接返回结果
                    DshProcessManager.BackendStartResult startResult = null;
                    RestartPhase("restart.start", delegate
                    {
                        startResult = dsh.EnsureStarted(
                            settings.port,
                            settings.workingDirectory,
                            logsDirectory,
                            settings.dshVersion,
                            settings.profileName,
                            settings.dshPath,
                            settings.dshRunnerMode,
                            false);
                    });

                    // restart.wait-ready：确认新后端就绪并记录新 wrapper/listener PID
                    RestartPhase("restart.wait-ready", delegate
                    {
                        if (startResult == null || startResult.ListenerPid <= 0)
                            throw new InvalidOperationException("重启后无法确认 DSH 监听进程。");
                        int waited = 0;
                        while (waited < 15000 && !dsh.IsDshReady(settings.port, 300))
                        {
                            Thread.Sleep(250);
                            waited += 250;
                        }
                        if (!dsh.IsDshReady(settings.port, 300))
                            throw new InvalidOperationException("重启后 DSH Web 未在预期时间内就绪。");
                        HostLog.Line("SNAPSHOT-NEW newWrapperPid=" + startResult.WrapperPid.ToString() +
                            " newListenerPid=" + startResult.ListenerPid.ToString());
                    });
                });

                // restart.navigate：页面恢复
                activeRestartPhase = "restart.navigate";
                HostLog.Enter("RESTART phase=restart.navigate");
                healthFailures = 0;
                compatPendingAtStartup = 0;
                webViewReady = true;
                ReloadDshPage();
                HideOverlay();
                HostLog.Ok("RESTART phase=restart.navigate");

                // restart.complete
                activeRestartPhase = "restart.complete";
                HostLog.Ok("RESTART phase=restart.complete");
            }
            catch (Exception ex)
            {
                HostLog.Fail("RESTART failed phase=" + activeRestartPhase, ex);
                HandleRestartError(ex);
            }
            finally
            {
                restartBusy = false;
                healthFailures = 0;
                healthTimer.Start();
            }
        }

        /// <summary>
        /// 重启失败按真实后端状态分流展示，不让健康检查的泛化提示盖掉真正异常：
        /// A. 重启失败，但原后端仍然健康；B. 重启失败，旧后端已经停止；
        /// C. 新后端已经监听，但页面恢复失败。webViewReady 按实际状态重算。
        /// </summary>
        private void HandleRestartError(Exception ex)
        {
            bool portOpen = dsh.IsReady(settings.port, 800);
            bool dshListening = false;
            if (portOpen)
            {
                int pid = dsh.FindListeningPid(settings.port);
                string cmd;
                dshListening = pid > 0 && dsh.IsLikelyDshProcess(pid, out cmd, settings.port);
            }
            bool backendStillHealthy = dsh.IsDshHealthy(settings.port, 800);
            webViewReady = backendStillHealthy;

            string title;
            string message;
            if (backendStillHealthy)
            {
                title = "重启未完成，原后端仍健康";
                message = "DSH 后端重启未完成，但原有后端仍然健康，可以继续使用。\r\n\r\n" + ex.Message;
            }
            else if (dshListening)
            {
                title = "新后端已就绪，页面恢复失败";
                message = "重启已成功启动新的 DSH 后端，但页面恢复失败。\r\n\r\n" + ex.Message;
            }
            else
            {
                title = "DSH 后端重启失败";
                message = "DSH 后端重启失败，且旧后端已经停止。\r\n\r\n" + ex.Message;
            }

            ShowErrorOverlay(
                "restart-error",
                title,
                message,
                ex.ToString(),
                "重试",
                OnOverlayRestartBackend,
                "打开日志目录",
                OnOverlayOpenLogs);
        }

        private void ReloadDshPage()
        {
            try
            {
                if (webView.CoreWebView2 != null)
                    webView.CoreWebView2.Navigate(DshHomeUrl());
            }
            catch { }
        }

        private string DshHomeUrl()
        {
            return "http://127.0.0.1:" + settings.port.ToString() + "/";
        }

        private bool IsAllowedMainNavigation(string uriText)
        {
            if (String.IsNullOrWhiteSpace(uriText)) return false;
            if (uriText.Equals("about:blank", StringComparison.OrdinalIgnoreCase)) return true;
            return IsDshLoopbackOrigin(uriText);
        }

        private bool IsDshLoopbackOrigin(string uriText)
        {
            try
            {
                Uri uri = new Uri(uriText);
                string host = uri.Host == null ? "" : uri.Host.ToLowerInvariant();
                bool loopback = host == "127.0.0.1" || host == "localhost" || host == "::1";
                return uri.Scheme == Uri.UriSchemeHttp && loopback && uri.Port == settings.port;
            }
            catch
            {
                return false;
            }
        }

        private void OpenExternalUri(string uriText)
        {
            try
            {
                if (String.IsNullOrWhiteSpace(uriText)) return;
                Uri uri;
                if (!Uri.TryCreate(uriText, UriKind.Absolute, out uri)) return;

                // 协议白名单（而非危险协议黑名单）：http/https/mailto 直接交给系统；
                // file:、ms-settings:、任意自定义 URI handler 等必须先经用户确认。
                string scheme = uri.Scheme.ToLowerInvariant();
                bool allowed = scheme == Uri.UriSchemeHttp || scheme == Uri.UriSchemeHttps ||
                               scheme == "mailto";

                if (!allowed)
                {
                    string shown = uriText.Length > 240 ? uriText.Substring(0, 240) + "…" : uriText;
                    DialogResult confirm = ThemedMessageBox.Show(
                        this,
                        "页面请求打开一个非 http/https 的外部链接：\r\n\r\n" + shown +
                        "\r\n\r\n是否交给 Windows 用系统程序打开？",
                        "DeepSeek Harness",
                        MessageBoxButtons.YesNo,
                        MessageBoxIcon.Warning);
                    if (confirm != DialogResult.Yes) return;
                }

                ProcessStartInfo psi = new ProcessStartInfo();
                psi.FileName = uriText;
                psi.UseShellExecute = true;
                Process.Start(psi);
            }
            catch { }
        }

        private void OnOverlayReloadPage(object sender, EventArgs e)
        {
            ReloadDshPage();
        }

        private async void OnOverlayRestartBackend(object sender, EventArgs e)
        {
            await RestartBackendAsync();
        }

        private async void OnOverlayRetryHealth(object sender, EventArgs e)
        {
            healthFailures = 1;
            await CheckBackendHealthAsync();
        }

        private async void OnOverlayRetryWebView(object sender, EventArgs e)
        {
            await RetryWebViewAsync();
        }

        private async void OnOverlayRetryConfigure(object sender, EventArgs e)
        {
            await RetryConfigureAsync();
        }

        private async void OnOverlayRetryStart(object sender, EventArgs e)
        {
            await StartAsync();
        }

        private void OnOverlayDismiss(object sender, EventArgs e)
        {
            HideOverlay();
        }

        private void OnOverlayOpenLogs(object sender, EventArgs e)
        {
            try
            {
                Directory.CreateDirectory(logsDirectory);
                Process.Start("explorer.exe", "\"" + logsDirectory + "\"");
            }
            catch { }
        }

        private void OnOverlayOpenWebView2Download(object sender, EventArgs e)
        {
            try
            {
                ProcessStartInfo psi = new ProcessStartInfo();
                psi.FileName = "https://go.microsoft.com/fwlink/p/?LinkId=2124703";
                psi.UseShellExecute = true;
                Process.Start(psi);
            }
            catch { }
        }

        private void OnOverlayRestartApp(object sender, EventArgs e)
        {
            try
            {
                allowExit = true;
                SaveWindowPosition();
                dsh.StopOwnedBackend();
                Application.Restart();
                Close();
            }
            catch
            {
                ShutdownAndClose();
            }
        }

        private void RestoreWindowPosition()
        {
            if (!settings.restoreWindowBounds || !settings.hasSavedWindowBounds)
            {
                StartPosition = FormStartPosition.CenterScreen;
                return;
            }

            Rectangle saved = new Rectangle(
                settings.windowX,
                settings.windowY,
                settings.windowWidth,
                settings.windowHeight);

            bool visible = false;
            foreach (Screen screen in Screen.AllScreens)
            {
                Rectangle intersection = Rectangle.Intersect(screen.WorkingArea, saved);
                if (intersection.Width >= 160 && intersection.Height >= 120)
                {
                    visible = true;
                    break;
                }
            }

            if (visible)
            {
                StartPosition = FormStartPosition.Manual;
                Bounds = saved;
                if (settings.windowMaximized) WindowState = FormWindowState.Maximized;
            }
            else
            {
                StartPosition = FormStartPosition.CenterScreen;
            }
        }

        private void SaveWindowPosition()
        {
            if (!settings.restoreWindowBounds) return;

            Rectangle bounds = WindowState == FormWindowState.Normal ? Bounds : RestoreBounds;
            settings.windowX = bounds.X;
            settings.windowY = bounds.Y;
            settings.windowWidth = bounds.Width;
            settings.windowHeight = bounds.Height;
            settings.windowMaximized = WindowState == FormWindowState.Maximized;
            settings.hasSavedWindowBounds = true;
            settings.Save(settingsPath);
        }

        private void ShowSettings()
        {
            using (SettingsForm dialog = new SettingsForm(settings, currentDark))
            {
                if (dialog.ShowDialog(this) == DialogResult.OK)
                {
                    settings.CopyFrom(dialog.ResultSettings);
                    settings.Save(settingsPath);
                }
            }
        }

        private void RestoreFromTray()
        {
            hiddenToTray = false;
            HostLog.Line("TRAY restore");
            Show();
            ShowInTaskbar = true;
            if (WindowState == FormWindowState.Minimized) WindowState = FormWindowState.Normal;
            Activate();
            BringToFront();
        }

        /// <summary>
        /// 关闭到托盘：延迟到 FormClosing 流程结束后再隐藏（由调用方 BeginInvoke），
        /// 避免在关闭事件处理中途 Hide() 造成窗口状态异常（残留不可见窗口或托盘恢复失败）。
        /// </summary>
        private void HideToTray()
        {
            hiddenToTray = true;
            HostLog.Line("TRAY hide");
            Hide();
            ShowInTaskbar = false;
        }

        protected override void WndProc(ref Message m)
        {
            if (m.Msg == Program.ActivateExistingMessage)
            {
                RestoreFromTray();
                m.Result = IntPtr.Zero;
                return;
            }

            base.WndProc(ref m);
        }

        private void OnFormClosing(object sender, FormClosingEventArgs e)
        {
            if (allowExit)
            {
                SaveWindowPosition();
                return;
            }

            if (e.CloseReason == CloseReason.WindowsShutDown)
            {
                allowExit = true;
                SaveWindowPosition();
                dsh.StopOwnedBackend();
                return;
            }

            if (settings.closeAction == "tray")
            {
                e.Cancel = true;
                if (!trayTransition)
                {
                    trayTransition = true;
                    BeginInvoke((MethodInvoker)delegate
                    {
                        trayTransition = false;
                        HideToTray();
                    });
                }
                return;
            }

            if (settings.closeAction == "exit")
            {
                allowExit = true;
                SaveWindowPosition();
                dsh.StopOwnedBackend();
                return;
            }

            using (CloseChoiceDialog dialog = new CloseChoiceDialog(currentDark))
            {
                DialogResult result = dialog.ShowDialog(this);
                if (result != DialogResult.OK)
                {
                    e.Cancel = true;
                    return;
                }

                if (dialog.RememberChoice)
                {
                    settings.closeAction = dialog.ActionChoice;
                    settings.Save(settingsPath);
                }

                if (dialog.ActionChoice == "tray")
                {
                    e.Cancel = true;
                    if (!trayTransition)
                    {
                        trayTransition = true;
                        BeginInvoke((MethodInvoker)delegate
                        {
                            trayTransition = false;
                            HideToTray();
                        });
                    }
                }
                else
                {
                    allowExit = true;
                    SaveWindowPosition();
                    dsh.StopOwnedBackend();
                }
            }
        }

        private void ShutdownAndClose()
        {
            allowExit = true;
            SaveWindowPosition();
            dsh.StopOwnedBackend();
            Close();
        }

        private static void ApplyMenuTheme(ToolStrip strip, bool dark)
        {
            if (strip == null) return;

            if (dark)
            {
                strip.BackColor = Color.FromArgb(32, 32, 32);
                strip.ForeColor = Color.WhiteSmoke;
                strip.Renderer = new ToolStripProfessionalRenderer(new DarkMenuColorTable());
            }
            else
            {
                strip.BackColor = SystemColors.Menu;
                strip.ForeColor = SystemColors.MenuText;
                strip.Renderer = new ToolStripSystemRenderer();
            }

            foreach (ToolStripItem item in strip.Items)
            {
                item.ForeColor = dark ? Color.WhiteSmoke : SystemColors.MenuText;
                ToolStripMenuItem menuItem = item as ToolStripMenuItem;
                if (menuItem != null && menuItem.HasDropDownItems)
                    ApplyMenuTheme(menuItem.DropDown, dark);
            }
        }

        private void ApplyThemeIfChanged()
        {
            ApplyThemeIfChanged(false);
        }

        private void ApplyThemeIfChanged(bool force)
        {
            bool dark = ThemeHelper.IsDark();
            bool themeChanged = dark != currentDark;

            if (!force && !themeChanged && chromeApplied) return;
            currentDark = dark;

            if (IsHandleCreated)
            {
                ThemeHelper.ApplyWindowChrome(this, dark);
                chromeApplied = true;
            }

            loadingPanel.BackColor = dark ? Color.FromArgb(24, 24, 24) : Color.White;
            loadingLabel.ForeColor = dark ? Color.WhiteSmoke : Color.FromArgb(30, 30, 30);
            errorTitle.ForeColor = dark ? Color.WhiteSmoke : Color.FromArgb(30, 30, 30);
            ThemeHelper.ApplyButtonTheme(overlayPrimaryButton, dark);
            ThemeHelper.ApplyButtonTheme(overlaySecondaryButton, dark);
            ThemeHelper.ApplyButtonTheme(copyErrorButton, dark);
            ApplyMenuTheme(trayMenu, dark);
            ApplyMenuTheme(activeWebContextMenu, dark);

            string iconFile = Path.Combine(
                baseDirectory,
                dark ? "DeepSeekHarness-Dark.ico" : "DeepSeekHarness-Light.ico");

            try
            {
                if (File.Exists(iconFile))
                {
                    Icon next = new Icon(iconFile);
                    Icon old = runtimeIcon;
                    runtimeIcon = next;
                    Icon = runtimeIcon;
                    trayIcon.Icon = runtimeIcon;
                    if (old != null) old.Dispose();
                }
            }
            catch { }
        }

        protected override void Dispose(bool disposing)
        {
            HostLog.Line("FORM dispose instance=" + mainFormInstanceId.ToString("N") +
                " hiddenToTray=" + hiddenToTray.ToString());
            if (disposing)
            {
                try { themeTimer.Stop(); themeTimer.Dispose(); } catch { }
                try { healthTimer.Stop(); healthTimer.Dispose(); } catch { }
                try { trayIcon.Visible = false; trayIcon.Dispose(); } catch { }
                try { trayMenu.Dispose(); } catch { }
                try { if (activeWebContextMenu != null) activeWebContextMenu.Dispose(); } catch { }
                try { dsh.Dispose(); } catch { }
                try { webView.Dispose(); } catch { }
                try { if (runtimeIcon != null) runtimeIcon.Dispose(); } catch { }
            }

            base.Dispose(disposing);
        }
    }

    internal static class Program
    {
        internal static readonly int ActivateExistingMessage =
            RegisterWindowMessage("DeepSeekHarnessDesktop.ActivateExisting.v1");

        private static readonly IntPtr HWND_BROADCAST = new IntPtr(0xffff);

        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        private static extern int RegisterWindowMessage(string lpString);

        [DllImport("user32.dll", SetLastError = true)]
        private static extern bool PostMessage(IntPtr hWnd, int msg, IntPtr wParam, IntPtr lParam);

        [STAThread]
        private static void Main()
        {
            ThemeHelper.EnablePerMonitorV2();
            Application.EnableVisualStyles();
            Application.SetCompatibleTextRenderingDefault(false);

            bool created;
            using (Mutex mutex = new Mutex(true, @"Local\DeepSeekHarnessDesktop", out created))
            {
                if (!created)
                {
                    try
                    {
                        PostMessage(HWND_BROADCAST, ActivateExistingMessage, IntPtr.Zero, IntPtr.Zero);
                    }
                    catch { }
                    return;
                }

                Application.Run(new MainForm());
            }
        }
    }

}