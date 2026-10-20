using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Windows;
using System.Windows.Media.Imaging;
using ComTypes = System.Runtime.InteropServices.ComTypes;

namespace Tatakan
{
    /// <summary>Turns anything dropped or pasted into shelf items.</summary>
    internal static class Ingest
    {
        public static string CacheDir { get; } = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Tatakan", "Cache");

        /// <summary>Fresh unique folder so names never collide.</summary>
        public static string NewTempFolder()
        {
            var d = Path.Combine(CacheDir, Guid.NewGuid().ToString("N"));
            Directory.CreateDirectory(d);
            return d;
        }

        public static List<ShelfItem> Items(IDataObject data)
        {
            try { return Read(data); }
            catch (Exception e) { Debug.WriteLine("Tatakan ingest: " + e); return new(); }
        }

        static List<ShelfItem> Read(IDataObject data)
        {
            var list = new List<ShelfItem>();

            // 1. Real files and folders (File Explorer, desktop, most apps)
            if (data.GetDataPresent(DataFormats.FileDrop) && data.GetData(DataFormats.FileDrop) is string[] paths && paths.Length > 0)
            {
                foreach (var p in paths) list.Add(ShelfItem.FromFile(p));
                return list;
            }

            // 2. Virtual files (Outlook attachments, browser images, zip contents…)
            var descriptors = ReadFileGroup(data);
            bool onlyUrlShortcuts = descriptors.Count > 0 && descriptors.TrueForAll(d =>
                d.Name.EndsWith(".url", StringComparison.OrdinalIgnoreCase));
            if (descriptors.Count > 0 && !onlyUrlShortcuts)
            {
                list.AddRange(SaveVirtualFiles(data, descriptors));
                if (list.Count > 0) return list;
            }

            // 3. Raw image data (screenshots, images copied from apps)
            var image = SaveImage(data);
            if (image != null) { list.Add(ShelfItem.FromFile(image)); return list; }

            // 4. Web links
            var url = ReadUrl(data);
            if (url != null)
            {
                string? title = onlyUrlShortcuts ? Path.GetFileNameWithoutExtension(descriptors[0].Name) : null;
                list.Add(ShelfItem.FromLink(url, title));
                return list;
            }

            // 5. Plain text (a URL typed as text becomes a link)
            if (data.GetDataPresent(DataFormats.UnicodeText) && data.GetData(DataFormats.UnicodeText) is string s
                && s.Trim().Length > 0)
            {
                var t = s.Trim();
                if (IsWebUrl(t)) list.Add(ShelfItem.FromLink(t, null));
                else list.Add(ShelfItem.FromText(s));
            }
            return list;
        }

        static bool IsWebUrl(string t) =>
            !t.Contains(' ') && !t.Contains('\n') && Uri.TryCreate(t, UriKind.Absolute, out var u)
            && (u.Scheme == Uri.UriSchemeHttp || u.Scheme == Uri.UriSchemeHttps);

        static string? ReadUrl(IDataObject data)
        {
            foreach (var fmt in new[] { "UniformResourceLocatorW", "UniformResourceLocator" })
            {
                if (!data.GetDataPresent(fmt)) continue;
                if (data.GetData(fmt) is MemoryStream ms)
                {
                    var bytes = ms.ToArray();
                    var s = fmt.EndsWith("W") ? Encoding.Unicode.GetString(bytes) : Encoding.Default.GetString(bytes);
                    s = s.TrimEnd('\0').Trim();
                    if (IsWebUrl(s)) return s;
                }
            }
            if (data.GetDataPresent(DataFormats.UnicodeText) && data.GetData(DataFormats.UnicodeText) is string t && IsWebUrl(t.Trim()))
                return t.Trim();
            return null;
        }

        // Images ---------------------------------------------------------------
        static string? SaveImage(IDataObject data)
        {
            try
            {
                if (data.GetDataPresent("PNG") && data.GetData("PNG") is MemoryStream png)
                {
                    var f = Path.Combine(NewTempFolder(), "Image.png");
                    File.WriteAllBytes(f, png.ToArray());
                    return f;
                }
                if (data.GetDataPresent(DataFormats.Bitmap) && data.GetData(DataFormats.Bitmap) is BitmapSource bmp)
                {
                    var f = Path.Combine(NewTempFolder(), "Image.png");
                    var enc = new PngBitmapEncoder();
                    enc.Frames.Add(BitmapFrame.Create(bmp));
                    using var fs = File.Create(f);
                    enc.Save(fs);
                    return f;
                }
            }
            catch (Exception e) { Debug.WriteLine("Tatakan image: " + e); }
            return null;
        }

        // Virtual files (FileGroupDescriptorW + FileContents) ------------------
        internal readonly record struct Descriptor(string Name, bool IsFolder);

        static List<Descriptor> ReadFileGroup(IDataObject data)
        {
            var result = new List<Descriptor>();
            if (!data.GetDataPresent("FileGroupDescriptorW")) return result;
            if (data.GetData("FileGroupDescriptorW") is not MemoryStream ms) return result;
            var b = ms.ToArray();
            if (b.Length < 4) return result;
            int count = BitConverter.ToInt32(b, 0);
            const int size = 592, nameOffset = 72;
            for (int i = 0; i < count; i++)
            {
                int start = 4 + i * size;
                if (start + size > b.Length) break;
                uint flags = BitConverter.ToUInt32(b, start);
                uint attrs = BitConverter.ToUInt32(b, start + 56);
                var name = Encoding.Unicode.GetString(b, start + nameOffset, 520);
                int z = name.IndexOf('\0');
                if (z >= 0) name = name[..z];
                bool folder = (flags & 0x4) != 0 && (attrs & 0x10) != 0;
                result.Add(new Descriptor(name, folder));
            }
            return result;
        }

        static List<ShelfItem> SaveVirtualFiles(IDataObject data, List<Descriptor> files)
        {
            var items = new List<ShelfItem>();
            if (data is not ComTypes.IDataObject com) return items;
            var dir = NewTempFolder();
            var top = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            short cf = (short)DataFormats.GetDataFormat("FileContents").Id;

            for (int i = 0; i < files.Count; i++)
            {
                var rel = string.Join(Path.DirectorySeparatorChar,
                    files[i].Name.Split('\\', '/'));
                foreach (var c in Path.GetInvalidFileNameChars())
                    if (c != Path.DirectorySeparatorChar) rel = rel.Replace(c, '_');
                if (rel.Length == 0) rel = "File";
                var target = Path.Combine(dir, rel);
                var root = rel.Split(Path.DirectorySeparatorChar)[0];

                if (files[i].IsFolder) { Directory.CreateDirectory(target); top.Add(root); continue; }
                var bytes = ReadContents(com, cf, i);
                if (bytes == null) continue;
                Directory.CreateDirectory(Path.GetDirectoryName(target)!);
                File.WriteAllBytes(target, bytes);
                top.Add(root);
            }
            foreach (var t in top) items.Add(ShelfItem.FromFile(Path.Combine(dir, t)));
            return items;
        }

        static byte[]? ReadContents(ComTypes.IDataObject com, short cf, int index)
        {
            var fmt = new ComTypes.FORMATETC
            {
                cfFormat = cf, dwAspect = ComTypes.DVASPECT.DVASPECT_CONTENT, lindex = index,
                tymed = ComTypes.TYMED.TYMED_ISTREAM | ComTypes.TYMED.TYMED_HGLOBAL,
            };
            ComTypes.STGMEDIUM med;
            try { com.GetData(ref fmt, out med); } catch { return null; }
            try
            {
                if (med.tymed == ComTypes.TYMED.TYMED_ISTREAM)
                {
                    var stream = (ComTypes.IStream)Marshal.GetObjectForIUnknown(med.unionmember);
                    using var outMs = new MemoryStream();
                    var buf = new byte[81920];
                    IntPtr readPtr = Marshal.AllocCoTaskMem(sizeof(int));
                    try
                    {
                        while (true)
                        {
                            stream.Read(buf, buf.Length, readPtr);
                            int n = Marshal.ReadInt32(readPtr);
                            if (n <= 0) break;
                            outMs.Write(buf, 0, n);
                        }
                    }
                    finally { Marshal.FreeCoTaskMem(readPtr); }
                    return outMs.ToArray();
                }
                if (med.tymed == ComTypes.TYMED.TYMED_HGLOBAL)
                {
                    var p = Native.GlobalLock(med.unionmember);
                    try
                    {
                        int len = (int)Native.GlobalSize(med.unionmember).ToUInt64();
                        var bytes = new byte[len];
                        Marshal.Copy(p, bytes, 0, len);
                        return bytes;
                    }
                    finally { Native.GlobalUnlock(med.unionmember); }
                }
                return null;
            }
            finally { Native.ReleaseStgMedium(ref med); }
        }

        /// <summary>Temp files (zips, resized images, dropped images) older than 3 days.</summary>
        public static void CleanOldCache()
        {
            try
            {
                if (!Directory.Exists(CacheDir)) return;
                var limit = DateTime.Now.AddDays(-3);
                foreach (var d in Directory.GetDirectories(CacheDir))
                    if (Directory.GetLastWriteTime(d) < limit) Directory.Delete(d, true);
            }
            catch { }
        }
    }
}
