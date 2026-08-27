// Raw Input plumbing for the key tester.
//
// The point of the tester is to show what the *pad* sends. An ordinary WPF key
// handler cannot do that: by the time a keystroke reaches the window it carries
// no indication of which keyboard produced it, so typing on the main keyboard
// would be indistinguishable from pressing the pad.
//
// Raw Input does carry the source device handle, which resolves to a device
// name containing the VID/PID. That is what makes attribution possible.
//
// Targets C# 5 / .NET Framework 4.x -- compiled by Add-Type under PowerShell 5.1.

using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;

namespace MiniKeyboard
{
    public class RawInputEvent
    {
        public string DeviceName;
        public string Kind;        // "keyboard", "hid" or "mouse"
        public int VirtualKey;
        public int ScanCode;
        public bool KeyUp;
        public byte[] HidData;
    }

    public static class RawInput
    {
        public const int WM_INPUT = 0x00FF;

        private const int RID_INPUT = 0x10000003;
        private const int RIDI_DEVICENAME = 0x20000007;
        private const int RIDEV_INPUTSINK = 0x00000100;
        private const int RIM_TYPEMOUSE = 0;
        private const int RIM_TYPEKEYBOARD = 1;
        private const int RIM_TYPEHID = 2;

        [StructLayout(LayoutKind.Sequential)]
        private struct RAWINPUTDEVICE
        {
            public ushort UsagePage;
            public ushort Usage;
            public int Flags;
            public IntPtr Target;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct RAWINPUTHEADER
        {
            public int Type;
            public int Size;
            public IntPtr Device;
            public IntPtr WParam;
        }

        [DllImport("user32.dll", SetLastError = true)]
        private static extern bool RegisterRawInputDevices(RAWINPUTDEVICE[] devices, int count, int size);

        [DllImport("user32.dll", SetLastError = true)]
        private static extern int GetRawInputData(IntPtr rawInput, int command, IntPtr data, ref int size, int headerSize);

        [DllImport("user32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
        private static extern int GetRawInputDeviceInfoW(IntPtr device, int command, IntPtr data, ref int size);

        // Resolving a device handle to its name is a syscall; the handle is
        // stable for the life of the device, so cache it.
        private static readonly Dictionary<IntPtr, string> nameCache = new Dictionary<IntPtr, string>();

        /// <summary>
        /// Subscribe the given window to keyboard, consumer-control and mouse
        /// raw input. RIDEV_INPUTSINK means events arrive even when another
        /// application has focus, so the pad can be tested against a real app.
        /// </summary>
        public static bool Register(IntPtr hwnd)
        {
            RAWINPUTDEVICE[] devices = new RAWINPUTDEVICE[3];
            devices[0].UsagePage = 0x01; devices[0].Usage = 0x06;   // keyboard
            devices[1].UsagePage = 0x0C; devices[1].Usage = 0x01;   // consumer control
            devices[2].UsagePage = 0x01; devices[2].Usage = 0x02;   // mouse
            for (int i = 0; i < devices.Length; i++)
            {
                devices[i].Flags = RIDEV_INPUTSINK;
                devices[i].Target = hwnd;
            }
            return RegisterRawInputDevices(devices, devices.Length, Marshal.SizeOf(typeof(RAWINPUTDEVICE)));
        }

        /// <summary>Stop receiving raw input. RIDEV_REMOVE requires a null target.</summary>
        public static bool Unregister()
        {
            RAWINPUTDEVICE[] devices = new RAWINPUTDEVICE[3];
            devices[0].UsagePage = 0x01; devices[0].Usage = 0x06;
            devices[1].UsagePage = 0x0C; devices[1].Usage = 0x01;
            devices[2].UsagePage = 0x01; devices[2].Usage = 0x02;
            for (int i = 0; i < devices.Length; i++)
            {
                devices[i].Flags = 0x00000001;   // RIDEV_REMOVE
                devices[i].Target = IntPtr.Zero;
            }
            nameCache.Clear();
            return RegisterRawInputDevices(devices, devices.Length, Marshal.SizeOf(typeof(RAWINPUTDEVICE)));
        }

        public static string GetDeviceName(IntPtr device)
        {
            if (device == IntPtr.Zero) return "";
            lock (nameCache)
            {
                string cached;
                if (nameCache.TryGetValue(device, out cached)) return cached;
            }

            int size = 0;
            if (GetRawInputDeviceInfoW(device, RIDI_DEVICENAME, IntPtr.Zero, ref size) != 0 || size <= 0)
                return "";

            IntPtr buffer = Marshal.AllocHGlobal(size * 2);
            try
            {
                if (GetRawInputDeviceInfoW(device, RIDI_DEVICENAME, buffer, ref size) < 0)
                    return "";
                string name = Marshal.PtrToStringUni(buffer);
                if (name == null) name = "";
                lock (nameCache) { nameCache[device] = name; }
                return name;
            }
            finally
            {
                Marshal.FreeHGlobal(buffer);
            }
        }

        /// <summary>
        /// Decode one WM_INPUT message. Returns null when the message is not
        /// readable or the source device name does not contain the filter.
        /// </summary>
        public static RawInputEvent Process(IntPtr lParam, string deviceFilter)
        {
            int headerSize = Marshal.SizeOf(typeof(RAWINPUTHEADER));
            int size = 0;
            if (GetRawInputData(lParam, RID_INPUT, IntPtr.Zero, ref size, headerSize) != 0 || size <= 0)
                return null;

            IntPtr buffer = Marshal.AllocHGlobal(size);
            try
            {
                if (GetRawInputData(lParam, RID_INPUT, buffer, ref size, headerSize) != size)
                    return null;

                RAWINPUTHEADER header = (RAWINPUTHEADER)Marshal.PtrToStructure(buffer, typeof(RAWINPUTHEADER));
                string name = GetDeviceName(header.Device);

                if (!string.IsNullOrEmpty(deviceFilter) &&
                    name.IndexOf(deviceFilter, StringComparison.OrdinalIgnoreCase) < 0)
                    return null;

                RawInputEvent result = new RawInputEvent();
                result.DeviceName = name;
                IntPtr body = new IntPtr(buffer.ToInt64() + headerSize);

                if (header.Type == RIM_TYPEKEYBOARD)
                {
                    // RAWKEYBOARD: MakeCode, Flags, Reserved, VKey (ushort each),
                    // then Message (uint) and ExtraInformation (uint).
                    result.Kind = "keyboard";
                    result.ScanCode = Marshal.ReadInt16(body, 0) & 0xFFFF;
                    int flags = Marshal.ReadInt16(body, 2) & 0xFFFF;
                    result.KeyUp = (flags & 0x01) != 0;
                    result.VirtualKey = Marshal.ReadInt16(body, 6) & 0xFFFF;
                    return result;
                }

                if (header.Type == RIM_TYPEHID)
                {
                    // RAWHID: dwSizeHid, dwCount, then dwCount packets of that size.
                    result.Kind = "hid";
                    int sizeHid = Marshal.ReadInt32(body, 0);
                    int count = Marshal.ReadInt32(body, 4);
                    int total = sizeHid * count;
                    if (total <= 0 || total > 1024) return null;

                    byte[] data = new byte[total];
                    Marshal.Copy(new IntPtr(body.ToInt64() + 8), data, 0, total);
                    result.HidData = data;
                    return result;
                }

                if (header.Type == RIM_TYPEMOUSE)
                {
                    // RAWMOUSE: usFlags (ushort), then a union whose first
                    // members are usButtonFlags and usButtonData.
                    result.Kind = "mouse";
                    result.VirtualKey = Marshal.ReadInt16(body, 4) & 0xFFFF;   // usButtonFlags
                    return result;
                }

                return null;
            }
            finally
            {
                Marshal.FreeHGlobal(buffer);
            }
        }
    }
}
