using System;
using System.Collections;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.Net.Sockets;
using System.Runtime.InteropServices;
using System.Text;
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
            dshVersion = "0.1.0-rc.7";
            dshPath = "";
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
                    value.dshVersion = "0.1.0-rc.7";
                value.dshVersion = NormalizeDshVersion(value.dshVersion);
                if (value.dshPath == null) value.dshPath = "";
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
            profileName = NormalizeProfileName(other.profileName);
        }

        public static string NormalizeDshVersion(string value)
        {
            string version = String.IsNullOrWhiteSpace(value) ? "0.1.0-rc.7" : value.Trim();
            foreach (char c in version)
            {
                if (!(Char.IsLetterOrDigit(c) || c == '.' || c == '-' || c == '_' || c == '+'))
                    return "0.1.0-rc.7";
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
            return profile;
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
                Button btn = (Button)control;
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

        public static void ApplyAll(string desktopDirectory, string logsDirectory, string profileName)
        {
            try
            {
                string dshHome = Environment.GetEnvironmentVariable("DSH_HOME");
                if (String.IsNullOrWhiteSpace(dshHome))
                {
                    dshHome = Path.Combine(
                        Environment.GetFolderPath(Environment.SpecialFolder.UserProfile),
                        ".dsh");
                }

                if (String.IsNullOrWhiteSpace(dshHome)) return;
                if (!Directory.Exists(logsDirectory)) Directory.CreateDirectory(logsDirectory);

                StringBuilder log = new StringBuilder();
                log.AppendLine("DeepSeek Harness DesktopShell plugin compatibility");
                log.AppendLine("Checked: " + DateTime.Now.ToString("O"));
                log.AppendLine("DSH_HOME: " + dshHome);

                string profile = AppSettings.NormalizeProfileName(profileName);
                log.AppendLine("Profile: " + profile);
                RepairSentinel(dshHome, profile, log);
                RepairCostMeterModLens(dshHome, profile, log);
                RepairCostMeterBackfill(dshHome, profile, log);
                RepairCostMeterLedger(dshHome, log);

                File.WriteAllText(
                    Path.Combine(logsDirectory, "plugin-compat.log"),
                    log.ToString(),
                    new UTF8Encoding(false));
            }
            catch
            {
                // Compatibility repair must never prevent the shell itself from starting.
            }
        }

        private static void RepairSentinel(string dshHome, string profileName, StringBuilder log)
        {
            string path = Path.Combine(dshHome, "profiles", profileName, "node_modules", "dsh-sentinel", "lib", "client.js");
            if (!File.Exists(path))
            {
                log.AppendLine("Sentinel: not installed; skipped.");
                return;
            }

            try
            {
                string source = File.ReadAllText(path, Encoding.UTF8);
                int wrongCount = CountOccurrences(source, SentinelWrongId);
                int rightCount = CountOccurrences(source, SentinelRightId);

                if (wrongCount == 1 && rightCount == 0)
                {
                    source = source.Replace(SentinelWrongId, SentinelRightId);
                    WriteAtomic(path, source);
                    log.AppendLine("Sentinel: repaired client bundle id.");
                }
                else if (wrongCount == 0 && rightCount >= 1)
                {
                    log.AppendLine("Sentinel: already healthy / upstream fixed; no action.");
                }
                else
                {
                    log.AppendLine("Sentinel: unrecognized bundle shape; left untouched.");
                }

                CleanupFiles(Path.GetDirectoryName(path), "client.js.before-client-id-fix-*.bak");
            }
            catch (Exception ex)
            {
                log.AppendLine("Sentinel: repair failed: " + ex.Message);
            }
        }

        private static void RepairCostMeterModLens(string dshHome, string profileName, StringBuilder log)
        {
            string path = Path.Combine(dshHome, "profiles", profileName, "node_modules", "dsh-cost-meter", "lib", "index.js");
            if (!File.Exists(path))
            {
                log.AppendLine("Cost meter: not installed; skipped.");
                return;
            }

            try
            {
                string source = File.ReadAllText(path, Encoding.UTF8);
                if (source.IndexOf(CostMarker, StringComparison.Ordinal) >= 0)
                {
                    log.AppendLine("Cost meter: ModLens de-dup already active.");
                    CleanupFiles(Path.GetDirectoryName(path), "index.js.before-modlens-dedup-*.bak");
                    return;
                }

                int handler = source.IndexOf("ctx.on('llm/stream'", StringComparison.Ordinal);
                if (handler < 0)
                    handler = source.IndexOf("ctx.on(\"llm/stream\"", StringComparison.Ordinal);

                if (handler < 0)
                {
                    log.AppendLine("Cost meter: llm/stream handler not found; left untouched.");
                    return;
                }

                int account = source.IndexOf("ledger.account(", handler, StringComparison.Ordinal);
                if (account < 0)
                {
                    log.AppendLine("Cost meter: ledger.account call not found; left untouched.");
                    return;
                }

                string region = source.Substring(handler, account - handler);
                if (region.IndexOf("deepseek-modlens", StringComparison.Ordinal) >= 0 ||
                    region.IndexOf("modlens-", StringComparison.Ordinal) >= 0)
                {
                    log.AppendLine("Cost meter: upstream already contains ModLens filtering; no action.");
                    CleanupFiles(Path.GetDirectoryName(path), "index.js.before-modlens-dedup-*.bak");
                    return;
                }

                string needle = "if (usage !== null) {";
                int condition = source.IndexOf(needle, handler, StringComparison.Ordinal);
                if (condition < 0 || condition > account)
                {
                    log.AppendLine("Cost meter: expected usage guard not found; left untouched.");
                    return;
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
            }
            catch (Exception ex)
            {
                log.AppendLine("Cost meter: repair failed: " + ex.Message);
            }
        }

        /// <summary>
        /// 给 cost-meter 的 backfill.js 打幂等补丁：历史回放（backfillLegacyLedger）
        /// 会从会话日志重建 byProviderModel，而会话日志里保留着 ModLens 合成包装的
        /// request/header + usage 事件。若不拦截，任何被清空/新建的账本都会在启动
        /// 回填时把合成条目重新计回（双倍计价“复发”的根因）。与 index.js 的守卫一致。
        /// </summary>
        private static void RepairCostMeterBackfill(string dshHome, string profileName, StringBuilder log)
        {
            string path = Path.Combine(dshHome, "profiles", profileName, "node_modules",
                "dsh-cost-meter", "lib", "backfill.js");
            if (!File.Exists(path))
            {
                log.AppendLine("Cost meter backfill: not installed; skipped.");
                return;
            }

            try
            {
                string source = File.ReadAllText(path, Encoding.UTF8);
                if (source.IndexOf(BackfillMarker, StringComparison.Ordinal) >= 0)
                {
                    log.AppendLine("Cost meter backfill: ModLens skip already active.");
                    CleanupFiles(Path.GetDirectoryName(path), "backfill.js.before-modlens-backfill-fix-*.bak");
                    return;
                }

                string anchor = "    const atMs = Number(event.time)";
                int at = source.IndexOf(anchor, StringComparison.Ordinal);
                if (at < 0)
                {
                    log.AppendLine("Cost meter backfill: anchor not found; left untouched.");
                    return;
                }

                string patch =
                    "    // " + BackfillMarker + "\r\n" +
                    "    if (provider === 'deepseek-modlens' || provider.startsWith('modlens-')) continue\r\n";
                source = source.Substring(0, at) + patch + source.Substring(at);

                WriteAtomic(path, source);
                log.AppendLine("Cost meter backfill: repaired ModLens replay skip.");
                CleanupFiles(Path.GetDirectoryName(path), "backfill.js.before-modlens-backfill-fix-*.bak");
            }
            catch (Exception ex)
            {
                log.AppendLine("Cost meter backfill: repair failed: " + ex.Message);
            }
        }

        /// <summary>
        /// 清理 cost-meter 账本中被 ModLens 合成包装误计的条目（双倍计价修复）。
        /// 删除 provider 键为 deepseek-modlens:* 或 modlens-*:* 的计费桶（日级 + 会话级），
        /// 并从日/会话合计中扣减对应 token 与金额；修改前自动备份。
        /// 与 scripts/Repair-CostMeterLedger.ps1 逻辑一致，桌面壳每次启动时执行。
        /// </summary>
        private static void RepairCostMeterLedger(string dshHome, StringBuilder log)
        {
            string path = Path.Combine(dshHome, "storages", "cost-meter", "ledger.json");
            if (!File.Exists(path))
            {
                log.AppendLine("Cost meter ledger: not found; skipped.");
                return;
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
                    return;
                }

                if (ledger == null || !ledger.ContainsKey("days"))
                {
                    log.AppendLine("Cost meter ledger: no days; skipped.");
                    return;
                }

                bool changed = false;
                int removedBuckets = 0;
                int removedCalls = 0;
                double removedCost = 0;

                Dictionary<string, object> days = ledger["days"] as Dictionary<string, object>;
                if (days != null)
                {
                    foreach (KeyValuePair<string, object> dayPair in new List<KeyValuePair<string, object>>(days))
                    {
                        Dictionary<string, object> day = dayPair.Value as Dictionary<string, object>;
                        if (day == null) continue;
                        removedBuckets += RemoveSyntheticLedgerBuckets(
                            day, dayPair.Key + " day", log,
                            ref changed, ref removedCalls, ref removedCost);

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
                                        ref changed, ref removedCalls, ref removedCost);
                                }
                            }
                        }
                    }
                }

                if (!changed)
                {
                    log.AppendLine("Cost meter ledger: no synthetic ModLens entries; clean.");
                    return;
                }

                string stamp = DateTime.Now.ToString("yyyyMMdd-HHmmss");
                string bak = path + ".before-modlens-clean-" + stamp + ".bak";
                File.Copy(path, bak, true);
                WriteAtomic(path, serializer.Serialize(ledger));
                log.AppendLine("Cost meter ledger: removed " + removedBuckets + " synthetic bucket(s) (" +
                    removedCalls + " calls, " + removedCost.ToString("0.######") + " CNY); backup " + bak);
            }
            catch (Exception ex)
            {
                log.AppendLine("Cost meter ledger: repair failed: " + ex.Message);
            }
        }

        private static int RemoveSyntheticLedgerBuckets(Dictionary<string, object> parent,
            string label, StringBuilder log, ref bool changed, ref int removedCalls, ref double removedCost)
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
                if (b != null) SubtractLedgerBucket(parent, b);
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
            return removed;
        }

        private static void SubtractLedgerBucket(Dictionary<string, object> total, Dictionary<string, object> b)
        {
            SubtractLedgerField(total, b, "input");
            SubtractLedgerField(total, b, "output");
            SubtractLedgerField(total, b, "cacheRead");
            SubtractLedgerField(total, b, "cacheWrite");
            SubtractLedgerField(total, b, "reasoning");
            SubtractLedgerField(total, b, "calls");
            SubtractLedgerField(total, b, "cost");
        }

        private static void SubtractLedgerField(Dictionary<string, object> total,
            Dictionary<string, object> b, string name)
        {
            if (!total.ContainsKey(name) || !b.ContainsKey(name)) return;
            try
            {
                if (name == "calls")
                    total[name] = Convert.ToInt32(total[name]) - Convert.ToInt32(b[name]);
                else
                    total[name] = Convert.ToDouble(total[name]) - Convert.ToDouble(b[name]);
            }
            catch { }
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
            return IsLikelyDshProcess(pid, out commandLine);
        }

        public void EnsureStarted(int port, string workingDirectory, string logsDirectory, string requestedVersion, string profileName, string configuredDshPath)
        {
            if (IsReady(port, 350))
            {
                int existingPid = FindListeningPid(port);
                if (existingPid <= 0)
                    throw new InvalidOperationException(
                        "端口 " + port.ToString() + " 已被占用，但无法确认监听进程身份。为避免误附着，桌面壳不会继续。");

                string commandLine;
                if (!IsLikelyDshProcess(existingPid, out commandLine))
                    throw new InvalidOperationException(
                        "端口 " + port.ToString() + " 已被非 DSH 进程占用（PID " + existingPid.ToString() + "）。\r\n\r\n" +
                        "命令行：\r\n" + (String.IsNullOrWhiteSpace(commandLine) ? "（无法读取）" : commandLine) +
                        "\r\n\r\n桌面壳拒绝把它当作 DSH。请更换端口或结束占用进程。");

                OwnsBackend = false;
                return;
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

            if (String.IsNullOrWhiteSpace(command) || !File.Exists(command))
                command = FindCommand("dsh");

            if (String.IsNullOrWhiteSpace(command) || !File.Exists(command))
            {
                command = FindCommand("npx");
                usingNpx = true;
            }

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
                arguments = "-y @deepseek-ai/dsh@" + QuoteArg(version) +
                    " --profile " + QuoteArg(profile) + " web --port " + port.ToString();
            }
            else
            {
                arguments = "--profile " + QuoteArg(profile) + " web --port " + port.ToString();
            }

            ProcessStartInfo psi = BuildStartInfo(command, arguments, workingDirectory);
            string oldPath = psi.EnvironmentVariables["PATH"] ?? Environment.GetEnvironmentVariable("PATH") ?? "";
            string commandDir = Path.GetDirectoryName(command) ?? "";
            if (!String.IsNullOrWhiteSpace(commandDir)) psi.EnvironmentVariables["PATH"] = commandDir + ";" + oldPath;
            psi.EnvironmentVariables["DSH_DESKTOP_DSH_VERSION"] = version;
            // Process-local GitHub transport fallback: old plugin specs may still use git+ssh,
            // but a desktop installation should not require the user to configure an SSH key.
            psi.EnvironmentVariables["GIT_CONFIG_COUNT"] = "3";
            psi.EnvironmentVariables["GIT_CONFIG_KEY_0"] = "url.https://github.com/.insteadOf";
            psi.EnvironmentVariables["GIT_CONFIG_VALUE_0"] = "git+ssh://git@github.com/";
            psi.EnvironmentVariables["GIT_CONFIG_KEY_1"] = "url.https://github.com/.insteadOf";
            psi.EnvironmentVariables["GIT_CONFIG_VALUE_1"] = "ssh://git@github.com/";
            psi.EnvironmentVariables["GIT_CONFIG_KEY_2"] = "url.https://github.com/.insteadOf";
            psi.EnvironmentVariables["GIT_CONFIG_VALUE_2"] = "git@github.com:";
            process = new Process();
            process.StartInfo = psi;
            process.EnableRaisingEvents = true;
            process.OutputDataReceived += OnOutput;
            process.ErrorDataReceived += OnOutput;

            AppendLog("Launching: " + psi.FileName + " " + psi.Arguments);
            if (!process.Start())
                throw new InvalidOperationException("无法启动 DeepSeek Harness。");

            OwnsBackend = true;
            TryAttachJob(process);
            process.BeginOutputReadLine();
            process.BeginErrorReadLine();

            int waited = 0;
            while (waited < 120000)
            {
                if (IsDshReady(port, 300)) return;
                if (IsReady(port, 300))
                    throw new InvalidOperationException(
                        "端口 " + port.ToString() + " 在 DSH 就绪前被非 DSH 进程占用。桌面壳拒绝把它当作 DSH。请查看日志：" + logPath);
                if (process.HasExited)
                    throw new InvalidOperationException("DSH 在 Web 服务就绪前退出，退出码 " +
                        process.ExitCode.ToString() + "。请查看日志：" + logPath);
                Thread.Sleep(250);
                waited += 250;
            }

            throw new TimeoutException("等待 DSH Web 启动超时（120 秒）。请查看日志：" + logPath);
        }

        public int FindListeningPid(int port)
        {
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

                        int pid;
                        if (Int32.TryParse(parts[4], out pid)) return pid;
                    }
                }
            }
            catch { }
            return -1;
        }

        public bool IsLikelyDshProcess(int pid, out string commandLine)
        {
            commandLine = GetProcessCommandLine(pid);
            if (String.IsNullOrWhiteSpace(commandLine)) return false;

            string lower = commandLine.ToLowerInvariant();
            bool hasDshPackage =
                lower.Contains("@deepseek-ai") && lower.Contains("dsh");
            bool hasDshPath =
                lower.Contains("\\dsh\\") || lower.Contains("/dsh/") ||
                lower.Contains("dsh.cmd") || lower.Contains("dsh.exe");
            bool hasWeb =
                lower.Contains(" web") || lower.Contains("\"web\"") ||
                lower.Contains("'web'");

            return hasWeb && (hasDshPackage || hasDshPath);
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

        /// <summary>
        /// 停止当前端口的 DSH 后端：自家托管的直接回收；外部进程只有在
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

                int pid = FindListeningPid(port);
                if (pid <= 0)
                    throw new InvalidOperationException(
                        "端口仍在监听，但无法确定监听进程 PID。桌面壳不会盲目结束未知进程。");

                string commandLine;
                if (!IsLikelyDshProcess(pid, out commandLine))
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

            if (!WaitForPortClosed(port, 10000))
                throw new InvalidOperationException("旧的 DSH Web 在 10 秒内没有释放端口 " + port.ToString() + "。");
        }

        public void RestartBackend(int port, string workingDirectory, string logsDirectory,
            string requestedVersion, string profileName, string configuredDshPath, bool allowExternalStop)
        {
            StopBackend(port, allowExternalStop);
            EnsureStarted(port, workingDirectory, logsDirectory, requestedVersion, profileName, configuredDshPath);
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
            if (e.Data != null) AppendLog(e.Data);
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

        private static string FindCommand(string name)
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

        public void StopOwnedBackend()
        {
            if (!OwnsBackend) return;

            if (jobHandle != IntPtr.Zero)
            {
                try { CloseHandle(jobHandle); } catch { }
                jobHandle = IntPtr.Zero;
            }

            try
            {
                if (process != null && !process.HasExited) process.Kill();
            }
            catch { }

            OwnsBackend = false;
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
            Height = 575;
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

            Label versionLabel = new Label();
            versionLabel.Text = "DSH / npx 版本";
            versionLabel.AutoSize = true;
            versionLabel.Left = leftLabel;
            versionLabel.Top = 391;
            Controls.Add(versionLabel);

            versionText = new TextBox();
            versionText.Left = leftControl;
            versionText.Top = 385;
            versionText.Width = 180;
            versionText.Text = AppSettings.NormalizeDshVersion(draft.dshVersion);
            versionText.ReadOnly = true;
            Controls.Add(versionText);

            Label versionHint = new Label();
            versionHint.Text = "优先使用现有 dsh；不存在时用 npx 运行此版本，不做全局安装。";
            versionHint.AutoSize = true;
            versionHint.Left = 382;
            versionHint.Top = 389;
            versionHint.Tag = "secondary";
            versionHint.ForeColor = dark ? Color.Silver : Color.DimGray;
            Controls.Add(versionHint);

            Label shellTitle = Header("桌面壳", 428);
            Controls.Add(shellTitle);

            developerCheck = new CheckBox();
            developerCheck.Text = "开发者模式（允许 WebView2 DevTools）";
            developerCheck.AutoSize = true;
            developerCheck.Left = leftControl;
            developerCheck.Top = 466;
            developerCheck.Checked = draft.developerMode;
            Controls.Add(developerCheck);

            Label hint = new Label();
            hint.Text = "工作目录、端口、Profile和开发者模式在下次启动时生效；npx版本在管理器中调整。";
            hint.AutoSize = true;
            hint.Left = leftControl;
            hint.Top = 492;
            hint.Tag = "secondary";
            hint.ForeColor = dark ? Color.Silver : Color.DimGray;
            Controls.Add(hint);

            Button save = new Button();
            save.Text = "保存";
            save.Width = 90;
            save.Height = 32;
            save.Left = 390;
            save.Top = 506;
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
            cancel.Top = 506;
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
        private readonly Button overlayPrimaryButton;
        private readonly Button overlaySecondaryButton;
        private readonly NotifyIcon trayIcon;
        private readonly ContextMenuStrip trayMenu;
        private readonly System.Windows.Forms.Timer themeTimer;
        private readonly System.Windows.Forms.Timer healthTimer;

        private EventHandler overlayPrimaryHandler;
        private EventHandler overlaySecondaryHandler;
        private bool allowExit;
        private bool currentDark;
        private bool chromeApplied;
        private bool webViewReady;
        private bool healthCheckBusy;
        private bool restartBusy;
        private int healthFailures;
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
            loadingLabel.Height = 70;

            overlayPrimaryButton = new Button();
            overlayPrimaryButton.Width = 142;
            overlayPrimaryButton.Height = 34;
            overlayPrimaryButton.Visible = false;

            overlaySecondaryButton = new Button();
            overlaySecondaryButton.Width = 142;
            overlaySecondaryButton.Height = 34;
            overlaySecondaryButton.Visible = false;

            loadingPanel.Controls.Add(loadingLabel);
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
                chromeApplied = false;
                ApplyThemeIfChanged(true);
            };
            FormClosing += OnFormClosing;

            ApplyThemeIfChanged(true);
        }

        private WebView2 CreateWebViewControl()
        {
            WebView2 control = new WebView2();
            control.Dock = DockStyle.Fill;
            return control;
        }

        private void LayoutOverlay()
        {
            int width = Math.Min(760, Math.Max(360, loadingPanel.ClientSize.Width - 80));
            loadingLabel.Width = width;
            loadingLabel.Left = Math.Max(20, (loadingPanel.ClientSize.Width - width) / 2);

            int centerY = Math.Max(100, loadingPanel.ClientSize.Height / 2 - 50);
            loadingLabel.Top = centerY;

            int visibleButtons = (overlayPrimaryButton.Visible ? 1 : 0) + (overlaySecondaryButton.Visible ? 1 : 0);
            if (visibleButtons == 0) return;

            int gap = 12;
            int totalWidth = visibleButtons == 2
                ? overlayPrimaryButton.Width + overlaySecondaryButton.Width + gap
                : overlayPrimaryButton.Width;
            int left = Math.Max(20, (loadingPanel.ClientSize.Width - totalWidth) / 2);
            int top = loadingLabel.Bottom + 18;

            if (overlayPrimaryButton.Visible)
            {
                overlayPrimaryButton.Left = left;
                overlayPrimaryButton.Top = top;
                left += overlayPrimaryButton.Width + gap;
            }

            if (overlaySecondaryButton.Visible)
            {
                overlaySecondaryButton.Left = left;
                overlaySecondaryButton.Top = top;
            }
        }

        private void ShowOverlay(string reason, string message,
            string primaryText, EventHandler primaryHandler,
            string secondaryText, EventHandler secondaryHandler)
        {
            overlayReason = reason;
            loadingLabel.Text = message;

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
            quit.Click += delegate { ShutdownAndClose(); };
            menu.Items.Add(quit);

            return menu;
        }

        private async Task StartAsync()
        {
            ShowOverlay("startup", "正在启动 DeepSeek Harness...", null, null, null, null);

            try
            {
                await Task.Run(delegate
                {
                    // 每次启动 DSH 前都执行兼容修复（幂等）
                    PluginCompat.ApplyAll(baseDirectory, logsDirectory, settings.profileName);
                    dsh.EnsureStarted(
                        settings.port,
                        settings.workingDirectory,
                        logsDirectory,
                        settings.dshVersion,
                        settings.profileName,
                        settings.dshPath);
                });

                loadingLabel.Text = "正在初始化 WebView2...";
                Directory.CreateDirectory(webViewDataDirectory);
                CoreWebView2Environment env = await CoreWebView2Environment.CreateAsync(null, webViewDataDirectory);
                await webView.EnsureCoreWebView2Async(env);

                await ConfigureWebViewAsync();
                await GrantDshNotificationPermissionAsync();

                webViewReady = true;
                healthFailures = 0;
                webView.CoreWebView2.Navigate(DshHomeUrl());
                HideOverlay();
            }
            catch (Exception ex)
            {
                webViewReady = false;
                ShowOverlay(
                    "startup-error",
                    "启动失败\r\n\r\n" + ex.Message,
                    "重试",
                    OnOverlayRestartBackend,
                    "打开日志目录",
                    OnOverlayOpenLogs);
            }
        }

        private async Task ConfigureWebViewAsync()
        {
            if (webView.CoreWebView2 == null) return;

            CoreWebView2 core = webView.CoreWebView2;

            core.NewWindowRequested += delegate(object sender, CoreWebView2NewWindowRequestedEventArgs e)
            {
                e.Handled = true;
                OpenExternalUri(e.Uri);
            };

            core.NavigationStarting += delegate(object sender, CoreWebView2NavigationStartingEventArgs e)
            {
                if (!IsAllowedMainNavigation(e.Uri))
                {
                    e.Cancel = true;
                    OpenExternalUri(e.Uri);
                }
            };

            core.NavigationCompleted += delegate(object sender, CoreWebView2NavigationCompletedEventArgs e)
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
            };

            core.PermissionRequested += delegate(object sender, CoreWebView2PermissionRequestedEventArgs e)
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
            };

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

        private void OnWebContextMenuRequested(object sender, CoreWebView2ContextMenuRequestedEventArgs e)
        {
            e.Handled = true;
            CoreWebView2Deferral deferral = e.GetDeferral();

            try
            {
                if (activeWebContextMenu != null)
                {
                    try { activeWebContextMenu.Close(); activeWebContextMenu.Dispose(); } catch { }
                    activeWebContextMenu = null;
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

                menu.Closed += delegate
                {
                    try { deferral.Complete(); } catch { }
                    try { menu.Dispose(); } catch { }
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

            try
            {
                bool ready = await Task.Run(delegate { return dsh.IsDshReady(settings.port, 350); });
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

        private async Task RestartBackendAsync()
        {
            if (restartBusy) return;
            restartBusy = true;

            try
            {
                bool allowExternal = false;

                if (!dsh.OwnsBackend && dsh.IsReady(settings.port, 300))
                {
                    int externalPid = dsh.FindListeningPid(settings.port);
                    if (externalPid <= 0)
                        throw new InvalidOperationException("端口正在监听，但无法读取监听进程 PID。");

                    string commandLine;
                    if (!dsh.IsLikelyDshProcess(externalPid, out commandLine))
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

                ShowOverlay("restart", "正在重启 DSH 后端...", null, null, null, null);

                await Task.Run(delegate
                {
                    // 兼容修复在「停止旧后端之后、启动新后端之前」执行：
                    // 升级插件后点“重启 DSH 后端”也能吃到兼容补丁（账本清理也不会被旧后端关停写回覆盖）。
                    dsh.StopBackend(settings.port, allowExternal);
                    PluginCompat.ApplyAll(baseDirectory, logsDirectory, settings.profileName);
                    dsh.EnsureStarted(
                        settings.port,
                        settings.workingDirectory,
                        logsDirectory,
                        settings.dshVersion,
                        settings.profileName,
                        settings.dshPath);
                });

                healthFailures = 0;
                webViewReady = true;
                ReloadDshPage();
                HideOverlay();
            }
            catch (Exception ex)
            {
                ShowOverlay(
                    "restart-error",
                    "DSH 后端重启失败\r\n\r\n" + ex.Message,
                    "重试",
                    OnOverlayRestartBackend,
                    "打开日志目录",
                    OnOverlayOpenLogs);
            }
            finally
            {
                restartBusy = false;
            }
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

        private void OnOverlayOpenLogs(object sender, EventArgs e)
        {
            try
            {
                Directory.CreateDirectory(logsDirectory);
                Process.Start("explorer.exe", "\"" + logsDirectory + "\"");
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
            Show();
            ShowInTaskbar = true;
            if (WindowState == FormWindowState.Minimized) WindowState = FormWindowState.Normal;
            Activate();
            BringToFront();
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
                Hide();
                ShowInTaskbar = false;
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
                    Hide();
                    ShowInTaskbar = false;
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