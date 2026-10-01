// GPU-PV Fix - user session probe.
// Compiled inside the guest by Install-Guest.ps1 (Windows PowerShell 5.1 Add-Type => C# 5 only).
//
//   GpuPvProbe.exe [--state-dir DIR] [--interval-min N]   resident watcher (one per session)
//   GpuPvProbe.exe --once --out FILE [--reason TEXT]      run a single OpenGL/Vulkan/display probe
//
// The resident watcher never loads OpenGL/Vulkan itself; every probe runs in a short-lived child
// process so GPU driver DLLs are not kept in memory between probes.

using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Security.Principal;
using System.Text;
using System.Threading;
using System.Windows.Forms;

namespace EasyGpuP.GpuPvFix
{
    public static class Program
    {
        [STAThread]
        public static int Main(string[] args)
        {
            string stateDir = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData), @"Easy-GPU-P\GpuPvFix\state");
            string outPath = null;
            string reason = "manual";
            bool once = false;
            int intervalMin = 15;

            for (int i = 0; i < args.Length; i++)
            {
                string a = args[i].ToLowerInvariant();
                string next = (i + 1 < args.Length) ? args[i + 1] : null;
                if (a == "--once") { once = true; }
                else if (a == "--out" && next != null) { outPath = next; i++; }
                else if (a == "--reason" && next != null) { reason = next; i++; }
                else if (a == "--state-dir" && next != null) { stateDir = next; i++; }
                else if (a == "--interval-min" && next != null) { int.TryParse(next, out intervalMin); i++; }
            }

            if (once)
            {
                if (outPath == null) { outPath = Path.Combine(stateDir, "probe-" + Process.GetCurrentProcess().SessionId + ".json"); }
                ProbeResult r = Probe.Run(reason);
                Json.WriteAtomic(outPath, r.ToJson());
                return r.Ok ? 0 : 1;
            }

            bool created;
            using (Mutex m = new Mutex(true, @"Local\GpuPvFixProbe", out created))
            {
                if (!created) { return 0; }
                Directory.CreateDirectory(stateDir);
                Watcher w = new Watcher(stateDir, intervalMin);
                w.Start();
                Application.Run();
                GC.KeepAlive(m);
            }
            return 0;
        }
    }

    // ---------------------------------------------------------------- resident watcher

    internal sealed class Watcher : NativeWindow
    {
        const int WM_DISPLAYCHANGE = 0x007E;
        const int WM_DEVICECHANGE = 0x0219;
        const int WM_WTSSESSION_CHANGE = 0x02B1;
        const int DBT_DEVNODES_CHANGED = 0x0007;

        [DllImport("wtsapi32.dll")] static extern bool WTSRegisterSessionNotification(IntPtr hWnd, int dwFlags);

        readonly string stateDir;
        readonly string outPath;
        readonly string logPath;
        readonly int intervalMin;
        readonly object gate = new object();
        System.Threading.Timer debounce;
        System.Threading.Timer periodic;
        FileSystemWatcher requestWatcher;
        string pendingReason;
        int running;

        public Watcher(string stateDir, int intervalMin)
        {
            this.stateDir = stateDir;
            this.intervalMin = intervalMin;
            int sid = Process.GetCurrentProcess().SessionId;
            outPath = Path.Combine(stateDir, "probe-" + sid + ".json");
            logPath = Path.Combine(stateDir, "probe-" + sid + ".log");
        }

        public void Start()
        {
            CreateHandle(new CreateParams());   // hidden top-level window: receives broadcast WM_DISPLAYCHANGE / WM_DEVICECHANGE
            WTSRegisterSessionNotification(Handle, 0);
            debounce = new System.Threading.Timer(OnDebounce, null, Timeout.Infinite, Timeout.Infinite);
            if (intervalMin > 0)
            {
                long ms = (long)intervalMin * 60000L;
                periodic = new System.Threading.Timer(delegate { Trigger("periodic", 0); }, null, ms, ms);
            }
            try
            {
                requestWatcher = new FileSystemWatcher(stateDir, "request.txt");
                requestWatcher.NotifyFilter = NotifyFilters.LastWrite | NotifyFilters.FileName | NotifyFilters.Size;
                requestWatcher.Changed += delegate { Trigger("request", 500); };
                requestWatcher.Created += delegate { Trigger("request", 500); };
                requestWatcher.EnableRaisingEvents = true;
            }
            catch (Exception ex) { Log("request watcher unavailable: " + ex.Message); }
            Log("watcher started (session " + Process.GetCurrentProcess().SessionId + ", interval " + intervalMin + " min)");
            Trigger("start", 2000);
        }

        protected override void WndProc(ref Message m)
        {
            if (m.Msg == WM_DISPLAYCHANGE) { Trigger("displaychange", 3000); }
            else if (m.Msg == WM_DEVICECHANGE && m.WParam.ToInt64() == DBT_DEVNODES_CHANGED) { Trigger("devicechange", 3000); }
            else if (m.Msg == WM_WTSSESSION_CHANGE) { Trigger("session:" + m.WParam.ToInt64(), 3000); }
            base.WndProc(ref m);
        }

        void Trigger(string reason, int delayMs)
        {
            lock (gate)
            {
                pendingReason = (pendingReason == null) ? reason : pendingReason;
                debounce.Change(delayMs, Timeout.Infinite);
            }
        }

        void OnDebounce(object _)
        {
            if (Interlocked.Exchange(ref running, 1) == 1)
            {
                lock (gate) { debounce.Change(2000, Timeout.Infinite); }   // a probe is already running: retry afterwards
                return;
            }
            try
            {
                string reason;
                lock (gate) { reason = pendingReason ?? "unknown"; pendingReason = null; }
                RunChild(reason);
            }
            finally { Interlocked.Exchange(ref running, 0); }
        }

        void RunChild(string reason)
        {
            string exe = Process.GetCurrentProcess().MainModule.FileName;
            ProcessStartInfo psi = new ProcessStartInfo(exe, "--once --reason \"" + reason + "\" --out \"" + outPath + "\"");
            psi.UseShellExecute = false;
            psi.CreateNoWindow = true;
            try
            {
                using (Process p = Process.Start(psi))
                {
                    if (!p.WaitForExit(30000))
                    {
                        try { p.Kill(); } catch { }
                        ProbeResult r = new ProbeResult(reason);
                        r.Error = "probe timed out after 30s (GPU driver hang?)";
                        Json.WriteAtomic(outPath, r.ToJson());
                        Log("probe (" + reason + ") TIMEOUT");
                        return;
                    }
                    Log("probe (" + reason + ") exit " + p.ExitCode);
                }
            }
            catch (Exception ex) { Log("probe (" + reason + ") failed to start: " + ex.Message); }
        }

        void Log(string msg)
        {
            try
            {
                FileInfo fi = new FileInfo(logPath);
                if (fi.Exists && fi.Length > 512 * 1024) { File.Copy(logPath, logPath + ".1", true); File.Delete(logPath); }
                File.AppendAllText(logPath, DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss") + " " + msg + Environment.NewLine);
            }
            catch { }
        }
    }

    // ---------------------------------------------------------------- probe

    internal sealed class DisplayInfo
    {
        public string Adapter;
        public string DeviceName;
        public bool Attached;
        public bool Primary;
    }

    internal sealed class VkDevice
    {
        public string Name;
        public string Type;
        public uint VendorId;
    }

    internal sealed class ProbeResult
    {
        public string Reason;
        public DateTime TimestampUtc = DateTime.UtcNow;
        public List<DisplayInfo> Displays = new List<DisplayInfo>();
        public bool GlOk;
        public string GlVendor, GlRenderer, GlVersion, GlError;
        public bool VkOk;
        public bool VkLoader;
        public List<VkDevice> VkDevices = new List<VkDevice>();
        public string VkError;
        public string Error;

        public ProbeResult(string reason) { Reason = reason; }

        public bool Ok { get { return Error == null && GlOk && VkOk; } }

        public string ToJson()
        {
            Json j = new Json();
            j.Begin();
            j.Num("schema", 1);
            j.Str("timestampUtc", TimestampUtc.ToString("o"));
            j.Str("reason", Reason);
            j.Str("user", SafeUser());
            j.Num("sessionId", Process.GetCurrentProcess().SessionId);
            j.Bool("is64BitProcess", Environment.Is64BitProcess);
            j.Bool("ok", Ok);
            j.Str("error", Error);
            j.BeginArray("displays");
            foreach (DisplayInfo d in Displays)
            {
                j.BeginObj();
                j.Str("adapter", d.Adapter); j.Str("deviceName", d.DeviceName);
                j.Bool("attached", d.Attached); j.Bool("primary", d.Primary);
                j.EndObj();
            }
            j.EndArray();
            j.BeginObj("opengl");
            j.Bool("ok", GlOk); j.Str("vendor", GlVendor); j.Str("renderer", GlRenderer); j.Str("version", GlVersion); j.Str("error", GlError);
            j.EndObj();
            j.BeginObj("vulkan");
            j.Bool("ok", VkOk); j.Bool("loader", VkLoader); j.Str("error", VkError);
            j.BeginArray("devices");
            foreach (VkDevice d in VkDevices)
            {
                j.BeginObj();
                j.Str("name", d.Name); j.Str("type", d.Type); j.Num("vendorId", d.VendorId);
                j.EndObj();
            }
            j.EndArray();
            j.EndObj();
            j.End();
            return j.ToString();
        }

        static string SafeUser()
        {
            try { return WindowsIdentity.GetCurrent().Name; } catch { return Environment.UserName; }
        }
    }

    internal static class Probe
    {
        public static ProbeResult Run(string reason)
        {
            ProbeResult r = new ProbeResult(reason);
            try { Displays(r); } catch (Exception ex) { r.Error = "display enumeration: " + ex.Message; }
            try { OpenGl(r); } catch (Exception ex) { r.GlError = ex.GetType().Name + ": " + ex.Message; }
            try { Vulkan(r); } catch (Exception ex) { r.VkError = ex.GetType().Name + ": " + ex.Message; }
            return r;
        }

        // ---- displays

        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        struct DISPLAY_DEVICE
        {
            public int cb;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string DeviceName;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string DeviceString;
            public int StateFlags;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string DeviceID;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string DeviceKey;
        }

        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        static extern bool EnumDisplayDevices(string lpDevice, uint iDevNum, ref DISPLAY_DEVICE lpDisplayDevice, uint dwFlags);

        static void Displays(ProbeResult r)
        {
            for (uint i = 0; i < 64; i++)
            {
                DISPLAY_DEVICE dd = new DISPLAY_DEVICE();
                dd.cb = Marshal.SizeOf(typeof(DISPLAY_DEVICE));
                if (!EnumDisplayDevices(null, i, ref dd, 0)) { break; }
                DisplayInfo d = new DisplayInfo();
                d.Adapter = dd.DeviceString;
                d.DeviceName = dd.DeviceName;
                d.Attached = (dd.StateFlags & 0x1) != 0;
                d.Primary = (dd.StateFlags & 0x4) != 0;
                r.Displays.Add(d);
            }
        }

        // ---- OpenGL (legacy WGL context on a hidden window, same path most GL apps take)

        [StructLayout(LayoutKind.Sequential)]
        struct PIXELFORMATDESCRIPTOR
        {
            public ushort nSize, nVersion;
            public uint dwFlags;
            public byte iPixelType, cColorBits, cRedBits, cRedShift, cGreenBits, cGreenShift, cBlueBits, cBlueShift,
                        cAlphaBits, cAlphaShift, cAccumBits, cAccumRedBits, cAccumGreenBits, cAccumBlueBits, cAccumAlphaBits,
                        cDepthBits, cStencilBits, cAuxBuffers, iLayerType, bReserved;
            public uint dwLayerMask, dwVisibleMask, dwDamageMask;
        }

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)] static extern IntPtr LoadLibrary(string name);
        [DllImport("kernel32.dll", CharSet = CharSet.Ansi)] static extern IntPtr GetProcAddress(IntPtr module, string name);
        [DllImport("kernel32.dll")] static extern bool FreeLibrary(IntPtr module);
        [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        static extern IntPtr CreateWindowEx(int exStyle, string cls, string name, int style, int x, int y, int w, int h, IntPtr parent, IntPtr menu, IntPtr inst, IntPtr param);
        [DllImport("user32.dll")] static extern bool DestroyWindow(IntPtr hwnd);
        [DllImport("user32.dll")] static extern IntPtr GetDC(IntPtr hwnd);
        [DllImport("user32.dll")] static extern int ReleaseDC(IntPtr hwnd, IntPtr hdc);
        [DllImport("gdi32.dll", SetLastError = true)] static extern int ChoosePixelFormat(IntPtr hdc, ref PIXELFORMATDESCRIPTOR pfd);
        [DllImport("gdi32.dll", SetLastError = true)] static extern bool SetPixelFormat(IntPtr hdc, int format, ref PIXELFORMATDESCRIPTOR pfd);
        [DllImport("opengl32.dll", SetLastError = true)] static extern IntPtr wglCreateContext(IntPtr hdc);
        [DllImport("opengl32.dll")] static extern bool wglMakeCurrent(IntPtr hdc, IntPtr hglrc);
        [DllImport("opengl32.dll")] static extern bool wglDeleteContext(IntPtr hglrc);
        [DllImport("opengl32.dll")] static extern IntPtr glGetString(uint name);

        static void OpenGl(ProbeResult r)
        {
            LoadLibrary("opengl32.dll");
            const int WS_OVERLAPPEDWINDOW = 0x00CF0000, WS_CLIPSIBLINGS = 0x04000000, WS_CLIPCHILDREN = 0x02000000;
            IntPtr hwnd = CreateWindowEx(0, "STATIC", "GpuPvProbeGL", WS_OVERLAPPEDWINDOW | WS_CLIPSIBLINGS | WS_CLIPCHILDREN, 0, 0, 64, 64, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero);
            if (hwnd == IntPtr.Zero) { r.GlError = "CreateWindowEx failed: " + Marshal.GetLastWin32Error(); return; }
            IntPtr hdc = GetDC(hwnd);
            IntPtr ctx = IntPtr.Zero;
            try
            {
                PIXELFORMATDESCRIPTOR pfd = new PIXELFORMATDESCRIPTOR();
                pfd.nSize = (ushort)Marshal.SizeOf(typeof(PIXELFORMATDESCRIPTOR));
                pfd.nVersion = 1;
                pfd.dwFlags = 0x4 | 0x20 | 0x1;   // DRAW_TO_WINDOW | SUPPORT_OPENGL | DOUBLEBUFFER
                pfd.iPixelType = 0;               // RGBA
                pfd.cColorBits = 32;
                pfd.cDepthBits = 24;
                pfd.cStencilBits = 8;
                int fmt = ChoosePixelFormat(hdc, ref pfd);
                if (fmt == 0) { r.GlError = "ChoosePixelFormat failed: " + Marshal.GetLastWin32Error(); return; }
                if (!SetPixelFormat(hdc, fmt, ref pfd)) { r.GlError = "SetPixelFormat failed: " + Marshal.GetLastWin32Error(); return; }
                ctx = wglCreateContext(hdc);
                if (ctx == IntPtr.Zero) { r.GlError = "wglCreateContext failed: " + Marshal.GetLastWin32Error(); return; }
                if (!wglMakeCurrent(hdc, ctx)) { r.GlError = "wglMakeCurrent failed"; return; }
                r.GlVendor = Marshal.PtrToStringAnsi(glGetString(0x1F00));
                r.GlRenderer = Marshal.PtrToStringAnsi(glGetString(0x1F01));
                r.GlVersion = Marshal.PtrToStringAnsi(glGetString(0x1F02));
                string ren = (r.GlRenderer ?? "").ToLowerInvariant();
                bool software = ren.Length == 0 || ren.Contains("gdi generic") || ren.Contains("llvmpipe") || ren.Contains("softpipe") || ren.Contains("basic render");
                r.GlOk = !software;
                if (software) { r.GlError = "software OpenGL renderer"; }
            }
            finally
            {
                if (ctx != IntPtr.Zero) { wglMakeCurrent(IntPtr.Zero, IntPtr.Zero); wglDeleteContext(ctx); }
                ReleaseDC(hwnd, hdc);
                DestroyWindow(hwnd);
            }
        }

        // ---- Vulkan (instance + physical device enumeration only)

        [StructLayout(LayoutKind.Sequential)]
        struct VkInstanceCreateInfo
        {
            public int sType;
            public IntPtr pNext;
            public uint flags;
            public IntPtr pApplicationInfo;
            public uint enabledLayerCount;
            public IntPtr ppEnabledLayerNames;
            public uint enabledExtensionCount;
            public IntPtr ppEnabledExtensionNames;
        }

        [UnmanagedFunctionPointer(CallingConvention.Winapi)]
        delegate IntPtr VkGetInstanceProcAddr(IntPtr instance, [MarshalAs(UnmanagedType.LPStr)] string name);
        [UnmanagedFunctionPointer(CallingConvention.Winapi)]
        delegate int VkCreateInstance(ref VkInstanceCreateInfo info, IntPtr allocator, out IntPtr instance);
        [UnmanagedFunctionPointer(CallingConvention.Winapi)]
        delegate int VkEnumeratePhysicalDevices(IntPtr instance, ref uint count, [In, Out] IntPtr[] devices);
        [UnmanagedFunctionPointer(CallingConvention.Winapi)]
        delegate void VkGetPhysicalDeviceProperties(IntPtr device, IntPtr properties);
        [UnmanagedFunctionPointer(CallingConvention.Winapi)]
        delegate void VkDestroyInstance(IntPtr instance, IntPtr allocator);

        static T Fn<T>(IntPtr p) where T : class
        {
            if (p == IntPtr.Zero) { return null; }
            return (T)(object)Marshal.GetDelegateForFunctionPointer(p, typeof(T));
        }

        static void Vulkan(ProbeResult r)
        {
            IntPtr lib = LoadLibrary("vulkan-1.dll");
            if (lib == IntPtr.Zero) { r.VkError = "vulkan-1.dll not found"; return; }
            r.VkLoader = true;
            VkGetInstanceProcAddr gipa = Fn<VkGetInstanceProcAddr>(GetProcAddress(lib, "vkGetInstanceProcAddr"));
            if (gipa == null) { r.VkError = "vkGetInstanceProcAddr missing"; return; }
            VkCreateInstance create = Fn<VkCreateInstance>(gipa(IntPtr.Zero, "vkCreateInstance"));
            VkInstanceCreateInfo ci = new VkInstanceCreateInfo();
            ci.sType = 1;   // VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO
            IntPtr inst;
            int res = create(ref ci, IntPtr.Zero, out inst);
            if (res != 0) { r.VkError = "vkCreateInstance returned " + res; return; }
            IntPtr props = Marshal.AllocHGlobal(4096);   // VkPhysicalDeviceProperties is ~824 bytes
            try
            {
                VkEnumeratePhysicalDevices enumerate = Fn<VkEnumeratePhysicalDevices>(gipa(inst, "vkEnumeratePhysicalDevices"));
                VkGetPhysicalDeviceProperties getProps = Fn<VkGetPhysicalDeviceProperties>(gipa(inst, "vkGetPhysicalDeviceProperties"));
                uint count = 0;
                res = enumerate(inst, ref count, null);
                if (res != 0) { r.VkError = "vkEnumeratePhysicalDevices returned " + res; return; }
                IntPtr[] devs = new IntPtr[count];
                if (count > 0) { res = enumerate(inst, ref count, devs); }
                if (res != 0 && res != 5) { r.VkError = "vkEnumeratePhysicalDevices returned " + res; return; }   // 5 = VK_INCOMPLETE
                string[] types = { "other", "integrated", "discrete", "virtual", "cpu" };
                for (int i = 0; i < count; i++)
                {
                    getProps(devs[i], props);
                    VkDevice d = new VkDevice();
                    d.VendorId = (uint)Marshal.ReadInt32(props, 8);
                    int t = Marshal.ReadInt32(props, 16);
                    d.Type = (t >= 0 && t < types.Length) ? types[t] : t.ToString();
                    d.Name = Marshal.PtrToStringAnsi(new IntPtr(props.ToInt64() + 20));
                    r.VkDevices.Add(d);
                    if (d.Type != "cpu") { r.VkOk = true; }
                }
                if (!r.VkOk) { r.VkError = (count == 0) ? "no Vulkan physical devices" : "only CPU Vulkan devices"; }
            }
            finally
            {
                Marshal.FreeHGlobal(props);
                VkDestroyInstance destroy = Fn<VkDestroyInstance>(gipa(inst, "vkDestroyInstance"));
                if (destroy != null) { destroy(inst, IntPtr.Zero); }
            }
        }
    }

    // ---------------------------------------------------------------- tiny JSON writer

    internal sealed class Json
    {
        readonly StringBuilder sb = new StringBuilder();
        bool first = true;

        void Key(string k)
        {
            if (!first) { sb.Append(','); }
            first = false;
            if (k != null) { Esc(k); sb.Append(':'); }
        }
        void Esc(string s)
        {
            sb.Append('"');
            foreach (char c in s)
            {
                if (c == '"' || c == '\\') { sb.Append('\\').Append(c); }
                else if (c < 0x20) { sb.Append("\\u").Append(((int)c).ToString("x4")); }
                else { sb.Append(c); }
            }
            sb.Append('"');
        }
        public void Begin() { sb.Append('{'); first = true; }
        public void End() { sb.Append('}'); }
        public void BeginObj() { BeginObj(null); }
        public void BeginObj(string k) { Key(k); sb.Append('{'); first = true; }
        public void EndObj() { sb.Append('}'); first = false; }
        public void BeginArray(string k) { Key(k); sb.Append('['); first = true; }
        public void EndArray() { sb.Append(']'); first = false; }
        public void Str(string k, string v) { Key(k); if (v == null) { sb.Append("null"); } else { Esc(v); } }
        public void Num(string k, long v) { Key(k); sb.Append(v); }
        public void Bool(string k, bool v) { Key(k); sb.Append(v ? "true" : "false"); }
        public override string ToString() { return sb.ToString(); }

        public static void WriteAtomic(string path, string content)
        {
            string dir = Path.GetDirectoryName(path);
            if (!string.IsNullOrEmpty(dir)) { Directory.CreateDirectory(dir); }
            string tmp = path + ".tmp";
            File.WriteAllText(tmp, content, new UTF8Encoding(false));
            if (File.Exists(path)) { File.Replace(tmp, path, null); } else { File.Move(tmp, path); }
        }
    }
}
