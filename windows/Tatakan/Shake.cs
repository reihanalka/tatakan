using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Windows.Interop;

namespace Tatakan
{
    /// <summary>
    /// Detects "shake the pointer while dragging something" anywhere on screen,
    /// through a low-level mouse hook (no admin rights needed).
    /// </summary>
    internal sealed class ShakeDetector : IDisposable
    {
        public event Action<Native.POINT>? Shake;

        readonly Native.LowLevelMouseProc proc;   // keep a reference so the GC doesn't collect the callback
        IntPtr hook;
        bool down, dragging, fired;
        Native.POINT downAt;
        long downTicks;
        readonly List<(long t, int x)> samples = new();
        static readonly int ownPid = Environment.ProcessId;

        public ShakeDetector() { proc = Hook; }

        public void Start()
        {
            if (hook != IntPtr.Zero) return;
            hook = Native.SetWindowsHookEx(Native.WH_MOUSE_LL, proc, Native.GetModuleHandle(null), 0);
        }

        public void Dispose()
        {
            if (hook != IntPtr.Zero) Native.UnhookWindowsHookEx(hook);
            hook = IntPtr.Zero;
        }

        IntPtr Hook(int code, IntPtr wParam, IntPtr lParam)
        {
            if (code >= 0)
            {
                var info = Marshal.PtrToStructure<Native.MSLLHOOKSTRUCT>(lParam);
                switch ((int)wParam)
                {
                    case Native.WM_LBUTTONDOWN:
                        down = true; dragging = false; fired = false;
                        downAt = info.pt; downTicks = Stopwatch.GetTimestamp();
                        samples.Clear();
                        break;
                    case Native.WM_LBUTTONUP:
                        down = false; samples.Clear();
                        break;
                    case Native.WM_MOUSEMOVE:
                        if (down && !fired) Track(info.pt);
                        break;
                }
            }
            return Native.CallNextHookEx(hook, code, wParam, lParam);
        }

        void Track(Native.POINT p)
        {
            var s = AppSettings.Shared;
            if (!s.ShakeEnabled) return;
            double now = Stopwatch.GetTimestamp() / (double)Stopwatch.Frequency;

            // Only once the button has been held and the pointer has left the drag threshold:
            // that's when Windows starts a real drag-and-drop.
            if (!dragging)
            {
                double held = (Stopwatch.GetTimestamp() - downTicks) / (double)Stopwatch.Frequency;
                int dx = Math.Abs(p.X - downAt.X), dy = Math.Abs(p.Y - downAt.Y);
                if (held < 0.12 || (dx < 8 && dy < 8)) return;
                dragging = true;
            }

            samples.Add(((long)(now * 1000), p.X));
            samples.RemoveAll(x => now * 1000 - x.t > 600);

            double scale = Native.DpiScaleAt(p);
            double minTravel = (70 - 45 * s.ShakeSensitivity) * scale;   // px between turns
            int needed = s.ShakeSensitivity > 0.66 ? 3 : 4;
            int reversals = 0, dir = 0;
            int anchor = samples.Count > 0 ? samples[0].x : p.X;
            for (int i = 1; i < samples.Count; i++)
            {
                int d = samples[i].x - anchor;
                if (Math.Abs(d) < minTravel) continue;
                int nd = d > 0 ? 1 : -1;
                if (dir != 0 && nd != dir) reversals++;
                dir = nd; anchor = samples[i].x;
            }
            if (reversals < needed) return;

            fired = true;
            samples.Clear();
            if (IsExcludedForeground()) return;
            var at = p;
            System.Windows.Application.Current?.Dispatcher.BeginInvoke(() => Shake?.Invoke(at));
        }

        static bool IsExcludedForeground()
        {
            try
            {
                Native.GetWindowThreadProcessId(Native.GetForegroundWindow(), out var pid);
                if (pid == ownPid) return true;   // dragging out of our own shelf
                var name = Process.GetProcessById((int)pid).ProcessName;
                return AppSettings.Shared.ExcludedApps.Exists(a => a.Equals(name, StringComparison.OrdinalIgnoreCase));
            }
            catch { return false; }
        }
    }

    /// <summary>System-wide keyboard shortcut (RegisterHotKey on a message-only window).</summary>
    internal sealed class HotKey : IDisposable
    {
        readonly HwndSource source;
        readonly int id;
        readonly Action handler;
        public bool Registered { get; }

        public HotKey(int id, uint modifiers, uint key, Action handler)
        {
            this.id = id;
            this.handler = handler;
            var p = new HwndSourceParameters("TatakanHotKey") { Width = 0, Height = 0, WindowStyle = 0, ParentWindow = new IntPtr(-3) };
            source = new HwndSource(p);
            source.AddHook(WndProc);
            Registered = Native.RegisterHotKey(source.Handle, id, modifiers | Native.MOD_NOREPEAT, key);
        }

        IntPtr WndProc(IntPtr hwnd, int msg, IntPtr wParam, IntPtr lParam, ref bool handled)
        {
            if (msg == Native.WM_HOTKEY && wParam.ToInt32() == id) { handler(); handled = true; }
            return IntPtr.Zero;
        }

        public void Dispose()
        {
            Native.UnregisterHotKey(source.Handle, id);
            source.Dispose();
        }
    }
}
