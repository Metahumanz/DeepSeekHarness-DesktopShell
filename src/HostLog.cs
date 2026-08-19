using System;
using System.IO;
using System.Text;

namespace DeepSeekHarnessDesktop
{
    /// <summary>
    /// 宿主日志：logs\desktop-shell.log（与 dsh-YYYYMMDD-HHMMSS.log 分离）。
    /// 记录启动阶段 ENTER/OK/FAIL、异常完整信息（ex.ToString() 含类型/Message/StackTrace/InnerException）
    /// 与关键环境信息。绝不记录 API Key、Cookie、Authorization、DeepSeek 凭据等敏感内容。
    /// 超过上限（8MB）时清空重写，避免无限增长。
    /// </summary>
    internal static class HostLog
    {
        private static readonly object gate = new object();
        private static string logPath = "";
        private static bool enabled = true;

        public static void Initialize(string logsDirectory, string instanceId)
        {
            try
            {
                if (!Directory.Exists(logsDirectory)) Directory.CreateDirectory(logsDirectory);
                logPath = Path.Combine(logsDirectory, "desktop-shell.log");
                if (!File.Exists(logPath))
                    File.WriteAllText(logPath, "DeepSeek Harness DesktopShell host log\r\n", new UTF8Encoding(false));
                Line("INIT host log instance=" + instanceId);
            }
            catch { enabled = false; }
        }

        public static void Line(string text)
        {
            if (!enabled || String.IsNullOrEmpty(logPath)) return;
            try
            {
                lock (gate)
                {
                    FileInfo fi = new FileInfo(logPath);
                    if (fi.Exists && fi.Length > 8 * 1024 * 1024)
                        File.WriteAllText(logPath, "DeepSeek Harness DesktopShell host log (rotated)\r\n", new UTF8Encoding(false));
                    File.AppendAllText(logPath,
                        "[" + DateTime.Now.ToString("HH:mm:ss.fff") + "] " + text + "\r\n",
                        new UTF8Encoding(false));
                }
            }
            catch { }
        }

        public static void Enter(string phase) { Line("ENTER " + phase); }
        public static void Ok(string phase) { Line("OK " + phase); }

        public static void Fail(string phase, Exception ex)
        {
            Line("FAIL " + phase + " :: " + (ex == null ? "(null)" : ex.ToString()));
        }
    }
}
