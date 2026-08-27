// HID transport for the CH57x/CH552 macro pad (VID 0x1189, PID 0x8840).
//
// The pad exposes its configuration channel as an ordinary vendor-defined HID
// interface (usage page 0xFF00, usage 0x0001) with 65-byte input and output
// reports. That means Windows' in-box HidUsb driver is enough -- no USBDK, no
// Zadig, no WinUSB replacement, no elevation.
//
// Targets C# 5 / .NET Framework 4.x: this is compiled by Add-Type under
// Windows PowerShell 5.1, so no interpolated strings, no expression-bodied
// members, no null-conditional operators.

using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Threading;

namespace MiniKeyboard
{
    public class HidDeviceInfo
    {
        public string Path;
        public ushort VendorId;
        public ushort ProductId;
        public ushort VersionNumber;
        public ushort UsagePage;
        public ushort Usage;
        public ushort InputReportByteLength;
        public ushort OutputReportByteLength;
        public ushort FeatureReportByteLength;
        public string Manufacturer;
        public string Product;
    }

    public class HidTransport : IDisposable
    {
        public const ushort VID = 0x1189;
        public const ushort PID = 0x8840;

        // The vendor-defined collection that accepts configuration reports.
        public const ushort CONFIG_USAGE_PAGE = 0xFF00;
        public const ushort CONFIG_USAGE = 0x0001;

        public const int REPORT_LENGTH = 65;

        #region P/Invoke

        [StructLayout(LayoutKind.Sequential)]
        private struct HIDD_ATTRIBUTES
        {
            public int Size;
            public ushort VendorID;
            public ushort ProductID;
            public ushort VersionNumber;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct HIDP_CAPS
        {
            public ushort Usage;
            public ushort UsagePage;
            public ushort InputReportByteLength;
            public ushort OutputReportByteLength;
            public ushort FeatureReportByteLength;
            [MarshalAs(UnmanagedType.ByValArray, SizeConst = 17)]
            public ushort[] Reserved;
            public ushort NumberLinkCollectionNodes;
            public ushort NumberInputButtonCaps;
            public ushort NumberInputValueCaps;
            public ushort NumberInputDataIndices;
            public ushort NumberOutputButtonCaps;
            public ushort NumberOutputValueCaps;
            public ushort NumberOutputDataIndices;
            public ushort NumberFeatureButtonCaps;
            public ushort NumberFeatureValueCaps;
            public ushort NumberFeatureDataIndices;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct SP_DEVICE_INTERFACE_DATA
        {
            public int cbSize;
            public Guid InterfaceClassGuid;
            public int Flags;
            public IntPtr Reserved;
        }

        [DllImport("hid.dll")]
        private static extern void HidD_GetHidGuid(out Guid guid);
        [DllImport("hid.dll")]
        private static extern bool HidD_GetPreparsedData(IntPtr handle, out IntPtr preparsed);
        [DllImport("hid.dll")]
        private static extern bool HidD_FreePreparsedData(IntPtr preparsed);
        [DllImport("hid.dll")]
        private static extern bool HidD_GetAttributes(IntPtr handle, ref HIDD_ATTRIBUTES attrs);
        [DllImport("hid.dll", CharSet = CharSet.Unicode)]
        private static extern bool HidD_GetProductString(IntPtr handle, byte[] buffer, int length);
        [DllImport("hid.dll", CharSet = CharSet.Unicode)]
        private static extern bool HidD_GetManufacturerString(IntPtr handle, byte[] buffer, int length);
        [DllImport("hid.dll")]
        private static extern bool HidD_SetOutputReport(IntPtr handle, byte[] buffer, int length);
        [DllImport("hid.dll")]
        private static extern bool HidD_FlushQueue(IntPtr handle);
        [DllImport("hid.dll")]
        private static extern bool HidD_SetNumInputBuffers(IntPtr handle, int number);
        [DllImport("hid.dll")]
        private static extern int HidP_GetCaps(IntPtr preparsed, ref HIDP_CAPS caps);

        [DllImport("setupapi.dll", CharSet = CharSet.Unicode)]
        private static extern IntPtr SetupDiGetClassDevs(ref Guid guid, IntPtr enumerator, IntPtr hwnd, uint flags);
        [DllImport("setupapi.dll")]
        private static extern bool SetupDiEnumDeviceInterfaces(IntPtr set, IntPtr devInfo, ref Guid guid, uint index, ref SP_DEVICE_INTERFACE_DATA data);
        [DllImport("setupapi.dll", CharSet = CharSet.Unicode)]
        private static extern bool SetupDiGetDeviceInterfaceDetail(IntPtr set, ref SP_DEVICE_INTERFACE_DATA data, IntPtr detail, uint size, ref uint required, IntPtr devInfo);
        [DllImport("setupapi.dll")]
        private static extern bool SetupDiDestroyDeviceInfoList(IntPtr set);

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern IntPtr CreateFile(string name, uint access, uint share, IntPtr security, uint disposition, uint flags, IntPtr template);
        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool CloseHandle(IntPtr handle);
        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool WriteFile(IntPtr handle, byte[] buffer, int toWrite, out int written, IntPtr overlapped);
        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool ReadFile(IntPtr handle, byte[] buffer, int toRead, out int read, IntPtr overlapped);
        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool CancelIoEx(IntPtr handle, IntPtr overlapped);

        private const uint GENERIC_READ = 0x80000000;
        private const uint GENERIC_WRITE = 0x40000000;
        private const uint FILE_SHARE_READ = 0x00000001;
        private const uint FILE_SHARE_WRITE = 0x00000002;
        private const uint OPEN_EXISTING = 3;
        private const uint DIGCF_PRESENT = 0x02;
        private const uint DIGCF_DEVICEINTERFACE = 0x10;
        private static readonly IntPtr INVALID_HANDLE = new IntPtr(-1);

        #endregion

        private IntPtr handle = INVALID_HANDLE;
        private HidDeviceInfo info;
        private bool readable;

        public HidDeviceInfo Info { get { return info; } }
        public bool CanRead { get { return readable; } }

        /// <summary>Enumerate every HID collection, optionally filtered to our VID/PID.</summary>
        public static List<HidDeviceInfo> Enumerate(bool onlyOurDevice)
        {
            List<HidDeviceInfo> found = new List<HidDeviceInfo>();
            Guid hidGuid;
            HidD_GetHidGuid(out hidGuid);

            IntPtr set = SetupDiGetClassDevs(ref hidGuid, IntPtr.Zero, IntPtr.Zero, DIGCF_PRESENT | DIGCF_DEVICEINTERFACE);
            if (set == INVALID_HANDLE)
                throw new InvalidOperationException("SetupDiGetClassDevs failed: " + Marshal.GetLastWin32Error());

            try
            {
                uint index = 0;
                while (true)
                {
                    SP_DEVICE_INTERFACE_DATA data = new SP_DEVICE_INTERFACE_DATA();
                    data.cbSize = Marshal.SizeOf(data);
                    if (!SetupDiEnumDeviceInterfaces(set, IntPtr.Zero, ref hidGuid, index, ref data))
                        break;
                    index++;

                    uint required = 0;
                    SetupDiGetDeviceInterfaceDetail(set, ref data, IntPtr.Zero, 0, ref required, IntPtr.Zero);
                    if (required == 0)
                        continue;

                    IntPtr detail = Marshal.AllocHGlobal((int)required);
                    try
                    {
                        // cbSize of SP_DEVICE_INTERFACE_DETAIL_DATA: 8 on x64, 6 on x86.
                        Marshal.WriteInt32(detail, IntPtr.Size == 8 ? 8 : 6);
                        if (!SetupDiGetDeviceInterfaceDetail(set, ref data, detail, required, ref required, IntPtr.Zero))
                            continue;
                        string path = Marshal.PtrToStringUni(new IntPtr(detail.ToInt64() + 4));
                        if (path == null)
                            continue;

                        HidDeviceInfo probed = Probe(path);
                        if (probed == null)
                            continue;
                        if (onlyOurDevice && (probed.VendorId != VID || probed.ProductId != PID))
                            continue;
                        found.Add(probed);
                    }
                    finally
                    {
                        Marshal.FreeHGlobal(detail);
                    }
                }
            }
            finally
            {
                SetupDiDestroyDeviceInfoList(set);
            }
            return found;
        }

        /// <summary>Open a collection with zero access rights purely to read its descriptors.</summary>
        private static HidDeviceInfo Probe(string path)
        {
            IntPtr h = CreateFile(path, 0, FILE_SHARE_READ | FILE_SHARE_WRITE, IntPtr.Zero, OPEN_EXISTING, 0, IntPtr.Zero);
            if (h == INVALID_HANDLE)
                return null;
            try
            {
                IntPtr preparsed;
                if (!HidD_GetPreparsedData(h, out preparsed))
                    return null;
                try
                {
                    HIDP_CAPS caps = new HIDP_CAPS();
                    HidP_GetCaps(preparsed, ref caps);

                    HIDD_ATTRIBUTES attrs = new HIDD_ATTRIBUTES();
                    attrs.Size = Marshal.SizeOf(attrs);
                    HidD_GetAttributes(h, ref attrs);

                    HidDeviceInfo d = new HidDeviceInfo();
                    d.Path = path;
                    d.VendorId = attrs.VendorID;
                    d.ProductId = attrs.ProductID;
                    d.VersionNumber = attrs.VersionNumber;
                    d.UsagePage = caps.UsagePage;
                    d.Usage = caps.Usage;
                    d.InputReportByteLength = caps.InputReportByteLength;
                    d.OutputReportByteLength = caps.OutputReportByteLength;
                    d.FeatureReportByteLength = caps.FeatureReportByteLength;
                    d.Manufacturer = ReadString(h, true);
                    d.Product = ReadString(h, false);
                    return d;
                }
                finally
                {
                    HidD_FreePreparsedData(preparsed);
                }
            }
            finally
            {
                CloseHandle(h);
            }
        }

        private static string ReadString(IntPtr h, bool manufacturer)
        {
            byte[] buffer = new byte[512];
            bool ok = manufacturer
                ? HidD_GetManufacturerString(h, buffer, buffer.Length)
                : HidD_GetProductString(h, buffer, buffer.Length);
            if (!ok)
                return "";
            string s = System.Text.Encoding.Unicode.GetString(buffer);
            int nul = s.IndexOf('\0');
            if (nul >= 0)
                s = s.Substring(0, nul);
            return s;
        }

        /// <summary>
        /// Locate the pad's configuration collection. Matched by usage page rather than by
        /// device-instance path, because the path's instance fragment changes between USB ports.
        /// </summary>
        public static HidDeviceInfo FindConfigInterface()
        {
            List<HidDeviceInfo> ours = Enumerate(true);
            if (ours.Count == 0)
                throw new InvalidOperationException(
                    "No macro pad found. Expected a HID device with VID 0x1189 / PID 0x8840. Is it plugged in?");

            List<HidDeviceInfo> config = new List<HidDeviceInfo>();
            foreach (HidDeviceInfo d in ours)
            {
                if (d.UsagePage == CONFIG_USAGE_PAGE && d.Usage == CONFIG_USAGE)
                    config.Add(d);
            }

            if (config.Count == 0)
                throw new InvalidOperationException(
                    "Found the pad, but not its vendor configuration collection (usage page 0xFF00, usage 0x0001). " +
                    "A driver may have claimed the interface exclusively.");
            if (config.Count > 1)
                throw new InvalidOperationException(string.Format(
                    "Found {0} configuration collections for VID 0x1189 / PID 0x8840. " +
                    "Unplug the other pads and retry.", config.Count));

            HidDeviceInfo chosen = config[0];
            if (chosen.OutputReportByteLength != REPORT_LENGTH)
                throw new InvalidOperationException(string.Format(
                    "Unexpected output report length {0}; this protocol requires {1}. Firmware may differ.",
                    chosen.OutputReportByteLength, REPORT_LENGTH));
            return chosen;
        }

        public static HidTransport OpenConfigInterface()
        {
            return new HidTransport(FindConfigInterface());
        }

        public HidTransport(HidDeviceInfo device)
        {
            info = device;

            // Read access is only needed for config read-back; a device that refuses it is
            // still perfectly writable, so degrade rather than fail.
            handle = CreateFile(device.Path, GENERIC_READ | GENERIC_WRITE,
                FILE_SHARE_READ | FILE_SHARE_WRITE, IntPtr.Zero, OPEN_EXISTING, 0, IntPtr.Zero);
            readable = true;

            if (handle == INVALID_HANDLE)
            {
                handle = CreateFile(device.Path, GENERIC_WRITE,
                    FILE_SHARE_READ | FILE_SHARE_WRITE, IntPtr.Zero, OPEN_EXISTING, 0, IntPtr.Zero);
                readable = false;
            }

            if (handle == INVALID_HANDLE)
                throw new InvalidOperationException(string.Format(
                    "Could not open {0} (Win32 error {1}).", device.Path, Marshal.GetLastWin32Error()));

            if (readable)
                HidD_SetNumInputBuffers(handle, 64);
        }

        /// <summary>
        /// Send one 65-byte report. Tries SET_REPORT over the control pipe first and falls back
        /// to a plain interrupt-OUT write, since firmware revisions differ in which they accept.
        /// </summary>
        public void Write(byte[] report)
        {
            if (report == null || report.Length != REPORT_LENGTH)
                throw new ArgumentException(string.Format(
                    "Report must be exactly {0} bytes, got {1}.", REPORT_LENGTH, report == null ? 0 : report.Length));
            if (report[0] != 0x03)
                throw new ArgumentException(string.Format(
                    "Report ID must be 0x03, got 0x{0:X2}.", report[0]));
            if (handle == INVALID_HANDLE)
                throw new InvalidOperationException("Device is not open.");

            if (HidD_SetOutputReport(handle, report, report.Length))
                return;
            int setReportError = Marshal.GetLastWin32Error();

            int written;
            if (WriteFile(handle, report, report.Length, out written, IntPtr.Zero) && written == report.Length)
                return;
            int writeFileError = Marshal.GetLastWin32Error();

            throw new InvalidOperationException(string.Format(
                "Failed to send report. HidD_SetOutputReport error {0}; WriteFile error {1}.",
                setReportError, writeFileError));
        }

        /// <summary>
        /// Read one input report, or null on timeout. ReadFile on a HID handle blocks
        /// indefinitely, so it runs on a worker thread and is cancelled via CancelIoEx.
        /// </summary>
        public byte[] Read(int timeoutMs)
        {
            if (!readable)
                throw new InvalidOperationException(
                    "Device was opened write-only; read-back is unavailable.");
            if (handle == INVALID_HANDLE)
                throw new InvalidOperationException("Device is not open.");

            byte[] buffer = new byte[info.InputReportByteLength];
            bool ok = false;
            int read = 0;
            IntPtr h = handle;

            using (ManualResetEvent done = new ManualResetEvent(false))
            {
                ThreadPool.QueueUserWorkItem(delegate
                {
                    try { ok = ReadFile(h, buffer, buffer.Length, out read, IntPtr.Zero); }
                    catch { ok = false; }
                    finally { try { done.Set(); } catch { } }
                });

                if (!done.WaitOne(timeoutMs))
                {
                    CancelIoEx(h, IntPtr.Zero);
                    done.WaitOne(500);
                    return null;
                }
            }

            if (!ok || read <= 0)
                return null;

            byte[] result = new byte[read];
            Array.Copy(buffer, result, read);
            return result;
        }

        /// <summary>Drop any stale input reports before issuing a request/response exchange.</summary>
        public void FlushInput()
        {
            if (handle != INVALID_HANDLE && readable)
                HidD_FlushQueue(handle);
        }

        public void Dispose()
        {
            if (handle != INVALID_HANDLE)
            {
                CloseHandle(handle);
                handle = INVALID_HANDLE;
            }
            GC.SuppressFinalize(this);
        }

        ~HidTransport()
        {
            if (handle != INVALID_HANDLE)
                CloseHandle(handle);
        }
    }
}
