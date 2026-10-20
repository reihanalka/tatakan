using System;
using System.Collections.Generic;
using System.Collections.Specialized;
using System.Diagnostics;
using System.IO;
using System.IO.Compression;
using System.Linq;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Media;
using System.Windows.Media.Imaging;

namespace Tatakan
{
    /// <summary>Everything you can do with items on a shelf.</summary>
    internal static class Actions
    {
        // Clipboard ------------------------------------------------------------
        public static DataObject ToDataObject(IReadOnlyCollection<ShelfItem> items)
        {
            var d = new DataObject();
            var files = new StringCollection();
            foreach (var i in items) if (i.IsFile && i.Path != null) files.Add(i.Path);
            if (files.Count > 0) d.SetFileDropList(files);
            var texts = items.Where(i => !i.IsFile).Select(i => i.Kind == ItemKind.Link ? i.Path : i.Text)
                .Where(t => !string.IsNullOrEmpty(t)).ToList();
            if (texts.Count > 0) d.SetText(string.Join(Environment.NewLine, texts));
            var links = items.Where(i => i.Kind == ItemKind.Link).ToList();
            if (files.Count == 0 && links.Count == 1)
            {
                var bytes = System.Text.Encoding.Unicode.GetBytes(links[0].Path + "\0");
                d.SetData("UniformResourceLocatorW", new MemoryStream(bytes));
            }
            return d;
        }

        public static void Copy(IReadOnlyCollection<ShelfItem> items, Shelf shelf)
        {
            if (items.Count == 0) return;
            try { Clipboard.SetDataObject(ToDataObject(items), true); }
            catch { shelf.Toast("Clipboard is busy"); return; }
            shelf.Toast(items.Count == 1 ? "Copied" : $"Copied {items.Count} items");
        }

        public static void Paste(Shelf shelf)
        {
            IDataObject? d = null;
            try { d = Clipboard.GetDataObject(); } catch { }
            var items = d == null ? new List<ShelfItem>() : Ingest.Items(d);
            shelf.Add(items);
            if (items.Count == 0) shelf.Toast("Clipboard is empty");
        }

        public static void CopyPaths(IReadOnlyCollection<ShelfItem> items, Shelf shelf)
        {
            var paths = items.Select(i => i.Kind == ItemKind.Text ? i.Text : i.Path).Where(p => p != null);
            try { Clipboard.SetText(string.Join(Environment.NewLine, paths)); } catch { }
            shelf.Toast("Paths copied");
        }

        // Files ---------------------------------------------------------------
        public static void Open(IEnumerable<ShelfItem> items)
        {
            foreach (var i in items)
            {
                try
                {
                    string target = i.Path ?? "";
                    if (i.Kind == ItemKind.Text)
                    {
                        target = Path.Combine(Ingest.NewTempFolder(), "Snippet.txt");
                        File.WriteAllText(target, i.Text ?? "");
                    }
                    if (target.Length > 0) Process.Start(new ProcessStartInfo(target) { UseShellExecute = true });
                }
                catch (Exception e) { Debug.WriteLine("Tatakan open: " + e.Message); }
            }
        }

        public static void Reveal(IEnumerable<ShelfItem> items)
        {
            foreach (var group in items.Where(i => i.IsFile && i.Path != null)
                         .GroupBy(i => Path.GetDirectoryName(i.Path!) ?? "").Take(4))
            {
                var first = group.First().Path!;
                try { Process.Start("explorer.exe", $"/select,\"{first}\""); } catch { }
            }
        }

        /// <summary>Copy or move files into a folder the user picks.</summary>
        public static void SaveTo(IReadOnlyCollection<ShelfItem> items, Shelf shelf, bool move, Window owner)
        {
            var files = items.Where(i => i.IsFile && i.Path != null).ToList();
            if (files.Count == 0) { shelf.Toast("No files to save"); return; }
            var dlg = new Microsoft.Win32.OpenFolderDialog
            {
                Title = move ? "Move to folder" : "Save to folder",
                InitialDirectory = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile) + "\\Downloads",
            };
            owner.Activate();
            if (dlg.ShowDialog(owner) != true) return;
            var dir = dlg.FolderName;
            int done = 0;
            var moved = new List<ShelfItem>();
            foreach (var f in files)
            {
                var src = f.Path!;
                var dst = UniquePath(Path.Combine(dir, Path.GetFileName(src.TrimEnd('\\'))));
                try
                {
                    bool isDir = Directory.Exists(src);
                    if (move)
                    {
                        if (isDir) Directory.Move(src, dst); else File.Move(src, dst);
                        moved.Add(ShelfItem.FromFile(dst));
                    }
                    else if (isDir) CopyDirectory(src, dst);
                    else File.Copy(src, dst);
                    done++;
                }
                catch (Exception e) { Debug.WriteLine("Tatakan save: " + e.Message); }
            }
            if (move) shelf.Replace(files, moved);
            shelf.Toast($"{(move ? "Moved" : "Saved")} {done} to {Path.GetFileName(dir.TrimEnd('\\'))}");
        }

        static void CopyDirectory(string src, string dst)
        {
            Directory.CreateDirectory(dst);
            foreach (var f in Directory.GetFiles(src)) File.Copy(f, Path.Combine(dst, Path.GetFileName(f)));
            foreach (var d in Directory.GetDirectories(src)) CopyDirectory(d, Path.Combine(dst, Path.GetFileName(d)));
        }

        public static string UniquePath(string path)
        {
            if (!File.Exists(path) && !Directory.Exists(path)) return path;
            var dir = Path.GetDirectoryName(path)!;
            var name = Path.GetFileNameWithoutExtension(path);
            var ext = Path.GetExtension(path);
            for (int n = 2; ; n++)
            {
                var c = Path.Combine(dir, $"{name} {n}{ext}");
                if (!File.Exists(c) && !Directory.Exists(c)) return c;
            }
        }

        /// <summary>Text snippets become .txt files (needed for sharing and drag-out to File Explorer).</summary>
        public static string? TextToFile(ShelfItem i)
        {
            if (i.Kind != ItemKind.Text) return null;
            var name = new string(i.Title.Where(c => !Path.GetInvalidFileNameChars().Contains(c)).Take(40).ToArray()).Trim();
            var f = Path.Combine(Ingest.NewTempFolder(), (name.Length == 0 ? "Snippet" : name) + ".txt");
            File.WriteAllText(f, i.Text ?? "");
            return f;
        }

        // ZIP ------------------------------------------------------------------
        public static void Zip(IReadOnlyCollection<ShelfItem> items, Shelf shelf)
        {
            var files = items.Where(i => i.IsFile && i.Path != null).ToList();
            if (files.Count == 0) { shelf.Toast("Nothing to zip"); return; }
            shelf.Status = "Zipping…";
            var name = files.Count == 1 ? Path.GetFileNameWithoutExtension(files[0].Path!.TrimEnd('\\'))
                                        : (shelf.Name.Length == 0 ? "Archive" : shelf.Name);
            var ui = Application.Current.Dispatcher;
            Task.Run(() =>
            {
                var output = Path.Combine(Ingest.NewTempFolder(), name + ".zip");
                try
                {
                    using (var zip = ZipFile.Open(output, ZipArchiveMode.Create))
                    {
                        var used = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
                        foreach (var f in files)
                        {
                            var p = f.Path!.TrimEnd('\\');
                            var entry = UniqueEntry(Path.GetFileName(p), used);
                            if (Directory.Exists(p)) AddFolder(zip, p, entry);
                            else zip.CreateEntryFromFile(p, entry, CompressionLevel.Optimal);
                        }
                    }
                    ui.Invoke(() => { shelf.Replace(files, new[] { ShelfItem.FromFile(output) }); shelf.Toast("ZIP ready"); });
                }
                catch (Exception e)
                {
                    Debug.WriteLine("Tatakan zip: " + e.Message);
                    ui.Invoke(() => shelf.Toast("ZIP failed"));
                }
            });
        }

        static string UniqueEntry(string name, HashSet<string> used)
        {
            var n = name; int k = 2;
            while (!used.Add(n)) n = $"{Path.GetFileNameWithoutExtension(name)} {k++}{Path.GetExtension(name)}";
            return n;
        }

        static void AddFolder(ZipArchive zip, string dir, string prefix)
        {
            var files = Directory.GetFiles(dir);
            var dirs = Directory.GetDirectories(dir);
            if (files.Length == 0 && dirs.Length == 0) zip.CreateEntry(prefix + "/");
            foreach (var f in files) zip.CreateEntryFromFile(f, prefix + "/" + Path.GetFileName(f), CompressionLevel.Optimal);
            foreach (var d in dirs) AddFolder(zip, d, prefix + "/" + Path.GetFileName(d));
        }

        // Images ---------------------------------------------------------------
        public enum ImageFormat { Keep, Png, Jpg }

        /// <param name="maxSide">longest edge in px (null = keep)</param>
        /// <param name="scale">0.5 etc (null = keep)</param>
        public static void ProcessImages(IReadOnlyCollection<ShelfItem> items, Shelf shelf,
            int? maxSide = null, double? scale = null, ImageFormat format = ImageFormat.Keep)
        {
            var images = items.Where(i => i.IsImage).ToList();
            if (images.Count == 0) { shelf.Toast("No images selected"); return; }
            shelf.Status = "Processing…";
            var ui = Application.Current.Dispatcher;
            Task.Run(() =>
            {
                var results = new List<ShelfItem>();
                var sources = new List<ShelfItem>();
                foreach (var img in images)
                {
                    try
                    {
                        var output = WriteImage(img.Path!, maxSide, scale, format);
                        if (output != null) { results.Add(ShelfItem.FromFile(output)); sources.Add(img); }
                    }
                    catch (Exception e) { Debug.WriteLine("Tatakan image: " + e.Message); }
                }
                ui.Invoke(() =>
                {
                    shelf.Replace(sources, results);
                    shelf.Toast(results.Count == 0 ? "Couldn't process" : $"Done · {results.Count} image{(results.Count == 1 ? "" : "s")}");
                });
            });
        }

        static string? WriteImage(string path, int? maxSide, double? scale, ImageFormat format)
        {
            BitmapSource src;
            using (var fs = File.OpenRead(path))
            {
                var dec = BitmapDecoder.Create(fs, BitmapCreateOptions.PreservePixelFormat, BitmapCacheOption.OnLoad);
                src = dec.Frames[0];
            }
            double longest = Math.Max(src.PixelWidth, src.PixelHeight);
            double target = longest;
            if (maxSide.HasValue) target = Math.Min(target, maxSide.Value);
            if (scale.HasValue) target = longest * scale.Value;
            BitmapSource output = src;
            if (Math.Abs(target - longest) > 0.5)
            {
                double s = target / longest;
                output = new TransformedBitmap(src, new ScaleTransform(s, s));
            }

            bool png = format == ImageFormat.Png
                       || (format == ImageFormat.Keep && Path.GetExtension(path).Equals(".png", StringComparison.OrdinalIgnoreCase));
            BitmapEncoder enc = png ? new PngBitmapEncoder() : new JpegBitmapEncoder { QualityLevel = 90 };
            if (!png && output.Format != PixelFormats.Bgr24 && output.Format != PixelFormats.Bgr32)
            {
                // JPG has no alpha: flatten onto white.
                output = Flatten(output);
            }
            enc.Frames.Add(BitmapFrame.Create(output));

            var name = Path.GetFileNameWithoutExtension(path);
            if (maxSide.HasValue || scale.HasValue) name += $"@{output.PixelWidth}px";
            var outPath = Path.Combine(Ingest.NewTempFolder(), name + (png ? ".png" : ".jpg"));
            using var outFs = File.Create(outPath);
            enc.Save(outFs);
            return outPath;
        }

        static BitmapSource Flatten(BitmapSource src)
        {
            var dv = new DrawingVisual();
            using (var dc = dv.RenderOpen())
            {
                var rect = new Rect(0, 0, src.PixelWidth, src.PixelHeight);
                dc.DrawRectangle(Brushes.White, null, rect);
                dc.DrawImage(src, rect);
            }
            var rtb = new RenderTargetBitmap(src.PixelWidth, src.PixelHeight, 96, 96, PixelFormats.Pbgra32);
            rtb.Render(dv);
            return new FormatConvertedBitmap(rtb, PixelFormats.Bgr24, null, 0);
        }

        // OCR (Windows built-in engine, offline) -------------------------------
        public static async void ExtractText(IReadOnlyCollection<ShelfItem> items, Shelf shelf)
        {
            var images = items.Where(i => i.IsImage).ToList();
            if (images.Count == 0) { shelf.Toast("No images selected"); return; }
            var engine = Windows.Media.Ocr.OcrEngine.TryCreateFromUserProfileLanguages();
            if (engine == null) { shelf.Toast("OCR not available"); return; }
            shelf.Status = "Reading text…";
            var chunks = new List<string>();
            foreach (var img in images)
            {
                try
                {
                    var file = await Windows.Storage.StorageFile.GetFileFromPathAsync(img.Path);
                    using var stream = await file.OpenAsync(Windows.Storage.FileAccessMode.Read);
                    var decoder = await Windows.Graphics.Imaging.BitmapDecoder.CreateAsync(stream);
                    uint max = Windows.Media.Ocr.OcrEngine.MaxImageDimension;
                    Windows.Graphics.Imaging.SoftwareBitmap bmp;
                    if (decoder.PixelWidth > max || decoder.PixelHeight > max)
                    {
                        double s = (double)max / Math.Max(decoder.PixelWidth, decoder.PixelHeight);
                        var t = new Windows.Graphics.Imaging.BitmapTransform
                        {
                            ScaledWidth = (uint)(decoder.PixelWidth * s), ScaledHeight = (uint)(decoder.PixelHeight * s),
                        };
                        bmp = await decoder.GetSoftwareBitmapAsync(Windows.Graphics.Imaging.BitmapPixelFormat.Bgra8,
                            Windows.Graphics.Imaging.BitmapAlphaMode.Premultiplied, t,
                            Windows.Graphics.Imaging.ExifOrientationMode.RespectExifOrientation,
                            Windows.Graphics.Imaging.ColorManagementMode.DoNotColorManage);
                    }
                    else
                    {
                        bmp = await decoder.GetSoftwareBitmapAsync(Windows.Graphics.Imaging.BitmapPixelFormat.Bgra8,
                            Windows.Graphics.Imaging.BitmapAlphaMode.Premultiplied);
                    }
                    using (bmp)
                    {
                        var result = await engine.RecognizeAsync(bmp);
                        var lines = result.Lines.Select(l => l.Text).ToList();
                        if (lines.Count > 0) chunks.Add(string.Join(Environment.NewLine, lines));
                    }
                }
                catch (Exception e) { Debug.WriteLine("Tatakan OCR: " + e.Message); }
            }
            var text = string.Join(Environment.NewLine + Environment.NewLine, chunks);
            if (text.Length == 0) { shelf.Toast("No text found"); return; }
            try { Clipboard.SetText(text); } catch { }
            shelf.Add(new[] { ShelfItem.FromText(text) });
            shelf.Toast("Text copied");
        }
    }
}
