using System;
using System.Runtime.InteropServices;

namespace DeepSeekHarnessDesktop
{
    /// <summary>
    /// 原生 TCP 表（GetExtendedTcpTable）端口 owner PID 查询。
    /// 独立成文件：桌面壳与回归测试（tests/test-port-owner.ps1 编译本文件 + Main 包装）
    /// 共用同一实现，避免“看起来写了原生代码”但解析错误没有被发现。
    ///
    /// 解析要点：
    /// - 返回缓冲区以 DWORD dwNumEntries 开头，行从 sizeof(uint) 偏移开始；
    /// - 按 entryCount 遍历，不用 size/rowSize 猜数量；
    /// - dwLocalPort 为网络字节序：低 16 位两字节需字节交换（ntohs 语义）才是端口号；
    /// - 只匹配 LISTEN 状态；失败返回 -1，由调用方退回 netstat。
    /// </summary>
    internal static class TcpTableHelper
    {
        [DllImport("iphlpapi.dll", SetLastError = true)]
        private static extern uint GetExtendedTcpTable(IntPtr pTcpTable, ref int dwOutBufLen, bool sort, int ipVersion, int tblClass, uint reserved);

        private const int AF_INET = 2;
        private const int TCP_TABLE_OWNER_PID_ALL = 5;
        private const uint MIB_TCP_STATE_LISTEN = 2;
        private const uint ERROR_INSUFFICIENT_BUFFER = 122;

        [StructLayout(LayoutKind.Sequential)]
        private struct MIB_TCPROW_OWNER_PID
        {
            public uint state;
            public uint localAddr;
            public uint localPort;
            public uint remoteAddr;
            public uint remotePort;
            public uint owningPid;
        }

        // dwLocalPort 为网络字节序：读出的低 16 位是 [msb, lsb] 排列，交换后才是主机序端口
        private static int NetworkToHost16(uint value)
        {
            int low = (int)(value & 0xFFFF);
            return ((low & 0xFF) << 8) | ((low >> 8) & 0xFF);
        }

        /// <summary>返回监听 port 的 owner PID；失败返回 -1。</summary>
        public static int FindListeningPidNative(int port)
        {
            try
            {
                int size = 0;
                uint rc = GetExtendedTcpTable(IntPtr.Zero, ref size, false, AF_INET, TCP_TABLE_OWNER_PID_ALL, 0);
                if (rc != 0 && rc != ERROR_INSUFFICIENT_BUFFER) return -1;
                if (size <= 0) return -1;

                IntPtr buffer = Marshal.AllocHGlobal(size);
                try
                {
                    rc = GetExtendedTcpTable(buffer, ref size, false, AF_INET, TCP_TABLE_OWNER_PID_ALL, 0);
                    if (rc != 0) return -1;

                    // 表头 DWORD dwNumEntries
                    int entryCount = Marshal.ReadInt32(buffer, 0);
                    if (entryCount <= 0) return -1;

                    int rowSize = Marshal.SizeOf(typeof(MIB_TCPROW_OWNER_PID));
                    IntPtr rowsStart = new IntPtr(buffer.ToInt64() + sizeof(uint));
                    for (int i = 0; i < entryCount; i++)
                    {
                        IntPtr rowPtr = new IntPtr(rowsStart.ToInt64() + (long)i * rowSize);
                        MIB_TCPROW_OWNER_PID row =
                            (MIB_TCPROW_OWNER_PID)Marshal.PtrToStructure(rowPtr, typeof(MIB_TCPROW_OWNER_PID));
                        if (row.state != MIB_TCP_STATE_LISTEN) continue;
                        int rowPort = NetworkToHost16(row.localPort);
                        if (rowPort == port) return (int)row.owningPid;
                    }
                }
                finally { Marshal.FreeHGlobal(buffer); }
            }
            catch { }
            return -1;
        }
    }
}
