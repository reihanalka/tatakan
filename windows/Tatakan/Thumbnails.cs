using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Threading;
using System.Windows;
using System.Windows.Media;
using System.Windows.Media.Imaging;

namespace Tatakan
{
    /// <summary>
    /// File Explorer thumbnails (or the file's icon) via IShellItemImageFactory,
    /// generated on one background STA thread and cached per item.
    /// </summary>
    internal static class Thumbnails
    {
        static readonly Dictionary<(Guid, int), ImageSource> cache = new();
        static readonly BlockingCollection<(ShelfItem item, int px, Action<ImageSource?> done)> queue = new();

        static Thumbnails()
        {
            var t = new Thread(Worker) { IsBackground = true, Name = "Tatakan thumbnails" };
            t.SetApartmentState(ApartmentState.STA);
            t.Start();
        }

        public static ImageSource? Cached(ShelfItem item, int px) =>
            cache.TryGetValue((item.Id, px), out var s) ? s : null;

        public static void Load(ShelfItem item, int px, Action<ImageSource?> done)
        {
            if (!item.IsFile || item.Path == null) { done(null); return; }
            if (cache.TryGetValue((item.Id, px), out var hit)) { done(hit); return; }
            var ui = Application.Current.Dispatcher;
            queue.Add((item, px, img => ui.BeginInvoke(() =>
            {
                if (img != null) cache[(item.Id, px)] = img;
                done(img);
            })));
        }

        static void Worker()
        {
            foreach (var (item, px, done) in queue.GetConsumingEnumerable())
            {
                ImageSource? img = null;
                try { img = Shell(item.Path!, px); } catch { }
                done(img);
            }
        }

        [ComImport, Guid("bcc18b79-ba16-442f-80c4-8a59c30c463b"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
        interface IShellItemImageFactory
        {
            [PreserveSig] int GetImage(Native.SIZE size, int flags, out IntPtr phbm);
        }

        [DllImport("shell32.dll", CharSet = CharSet.Unicode, PreserveSig = false)]
        static extern void SHCreateItemFromParsingName(string path, IntPtr pbc,
            [MarshalAs(UnmanagedType.LPStruct)] Guid riid, [MarshalAs(UnmanagedType.Interface)] out IShellItemImageFactory item);

        static ImageSource? Shell(string path, int px)
        {
            SHCreateItemFromParsingName(path, IntPtr.Zero, typeof(IShellItemImageFactory).GUID, out var factory);
            try
            {
                // flags 0 = SIIGBF_RESIZETOFIT: thumbnail when there is one, otherwise the icon.
                if (factory.GetImage(new Native.SIZE { cx = px, cy = px }, 0, out var hbm) != 0 || hbm == IntPtr.Zero) return null;
                try { return FromHBitmap(hbm); }
                finally { Native.DeleteObject(hbm); }
            }
            finally { Marshal.ReleaseComObject(factory); }
        }

        /// <summary>HBITMAP → frozen BitmapSource, keeping the alpha channel.</summary>
        static BitmapSource? FromHBitmap(IntPtr hbm)
        {
            if (Native.GetObject(hbm, Marshal.SizeOf<Native.BITMAP>(), out var bm) == 0) return null;
            int w = bm.bmWidth, h = Math.Abs(bm.bmHeight);
            var bi = new Native.BITMAPINFOHEADER
            {
                biSize = (uint)Marshal.SizeOf<Native.BITMAPINFOHEADER>(), biWidth = w, biHeight = -h,
                biPlanes = 1, biBitCount = 32, biCompression = 0,
            };
            var pixels = new byte[w * h * 4];
            var dc = Native.GetDC(IntPtr.Zero);
            try { if (Native.GetDIBits(dc, hbm, 0, (uint)h, pixels, ref bi, 0) == 0) return null; }
            finally { Native.ReleaseDC(IntPtr.Zero, dc); }

            bool anyAlpha = false;
            for (int i = 3; i < pixels.Length; i += 4) if (pixels[i] != 0) { anyAlpha = true; break; }
            if (!anyAlpha) for (int i = 3; i < pixels.Length; i += 4) pixels[i] = 255;

            var src = BitmapSource.Create(w, h, 96, 96, PixelFormats.Pbgra32, null, pixels, w * 4);
            src.Freeze();
            return src;
        }
    }
}
