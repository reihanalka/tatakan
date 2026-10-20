using System;
using System.Collections.Generic;
using System.Collections.ObjectModel;
using System.ComponentModel;
using System.IO;
using System.Linq;
using System.Runtime.CompilerServices;
using System.Text.Json.Serialization;
using System.Windows.Media;
using System.Windows.Threading;

namespace Tatakan
{
    public enum ItemKind { File, Link, Text }

    /// <summary>One thing on a shelf: a file/folder, a web link or a text snippet.</summary>
    public sealed class ShelfItem
    {
        public Guid Id { get; set; } = Guid.NewGuid();
        public ItemKind Kind { get; set; }
        /// <summary>File path for files, URL for links.</summary>
        public string? Path { get; set; }
        public string? Text { get; set; }
        public string Title { get; set; } = "";

        public static ShelfItem FromFile(string path)
        {
            var name = System.IO.Path.GetFileName(path.TrimEnd('\\', '/'));
            return new ShelfItem { Kind = ItemKind.File, Path = path, Title = name.Length > 0 ? name : path };
        }

        public static ShelfItem FromLink(string url, string? title)
        {
            string t = !string.IsNullOrWhiteSpace(title) ? title!
                : Uri.TryCreate(url, UriKind.Absolute, out var u) ? u.Host : url;
            return new ShelfItem { Kind = ItemKind.Link, Path = url, Title = t };
        }

        public static ShelfItem FromText(string s)
        {
            var first = s.Split('\n').Select(l => l.Trim()).FirstOrDefault(l => l.Length > 0) ?? s;
            return new ShelfItem { Kind = ItemKind.Text, Text = s, Title = first.Length > 60 ? first[..60] : first };
        }

        [JsonIgnore] public bool IsFile => Kind == ItemKind.File;
        [JsonIgnore] public bool IsDirectory => IsFile && Path != null && Directory.Exists(Path);

        /// <summary>Still points at something real? Files can be moved or deleted behind our back.</summary>
        [JsonIgnore]
        public bool IsAlive => !IsFile || (Path != null && (File.Exists(Path) || Directory.Exists(Path)));

        static readonly HashSet<string> ImageExt = new(StringComparer.OrdinalIgnoreCase)
            { ".png", ".jpg", ".jpeg", ".bmp", ".gif", ".tif", ".tiff", ".webp", ".heic", ".heif", ".ico", ".jxr" };

        [JsonIgnore]
        public bool IsImage => IsFile && Path != null && ImageExt.Contains(System.IO.Path.GetExtension(Path));

        [JsonIgnore]
        public string Subtitle
        {
            get
            {
                switch (Kind)
                {
                    case ItemKind.Link:
                        return "Link · " + (Uri.TryCreate(Path, UriKind.Absolute, out var u) ? u.Host : "");
                    case ItemKind.Text:
                        return $"Text · {Text?.Length ?? 0} chr";
                    default:
                        if (Path == null) return "";
                        if (Directory.Exists(Path)) return "Folder";
                        var ext = System.IO.Path.GetExtension(Path).TrimStart('.');
                        long size = 0;
                        try { size = new FileInfo(Path).Length; } catch { }
                        return $"{(ext.Length == 0 ? "File" : ext)} · {Bytes.Format(size)}";
                }
            }
        }
    }

    internal static class Bytes
    {
        public static string Format(long b)
        {
            string[] u = { "bytes", "KB", "MB", "GB", "TB" };
            double v = b; int i = 0;
            while (v >= 1000 && i < u.Length - 1) { v /= 1000; i++; }
            return i == 0 ? $"{b} {u[0]}" : $"{v:0.#} {u[i]}";
        }

        public static long SizeOf(ShelfItem item)
        {
            if (!item.IsFile || item.Path == null) return 0;
            try { return File.Exists(item.Path) ? new FileInfo(item.Path).Length : 0; } catch { return 0; }
        }
    }

    /// <summary>State of one shelf window.</summary>
    public sealed class Shelf : INotifyPropertyChanged
    {
        public event PropertyChangedEventHandler? PropertyChanged;
        public event Action? SelectionChanged;

        public ObservableCollection<ShelfItem> Items { get; } = new();
        readonly HashSet<Guid> selection = new();
        Guid? anchor;

        string name = "";
        int colorIndex;
        bool expanded, isTargeted, renaming;
        string? status;

        public string Name { get => name; set => Set(ref name, value); }
        public int ColorIndex { get => colorIndex; set => Set(ref colorIndex, value); }
        public bool Expanded { get => expanded; set => Set(ref expanded, value); }
        public bool IsTargeted { get => isTargeted; set => Set(ref isTargeted, value); }
        public bool Renaming { get => renaming; set => Set(ref renaming, value); }
        /// <summary>Small toast at the bottom ("Copied", "Zipping…").</summary>
        public string? Status { get => status; set => Set(ref status, value); }

        public static readonly Color[] Colors =
        {
            Color.FromRgb(0x8E, 0x8E, 0x93), Color.FromRgb(0xFF, 0x3B, 0x30), Color.FromRgb(0xFF, 0x95, 0x00),
            Color.FromRgb(0xFF, 0xCC, 0x00), Color.FromRgb(0x34, 0xC7, 0x59), Color.FromRgb(0x00, 0x7A, 0xFF),
            Color.FromRgb(0xAF, 0x52, 0xDE), Color.FromRgb(0xFF, 0x2D, 0x55),
        };
        public static readonly string[] ColorNames = { "None", "Red", "Orange", "Yellow", "Green", "Blue", "Purple", "Pink" };
        public Color? Tint => colorIndex == 0 ? null : Colors[colorIndex];

        public string DisplayTitle
        {
            get
            {
                if (name.Length > 0) return name;
                if (Items.Count == 0) return "Shelf";
                int files = Items.Count(i => i.IsFile);
                if (files == Items.Count) return files == 1 ? "1 File" : $"{files} Files";
                return Items.Count == 1 ? "1 Item" : $"{Items.Count} Items";
            }
        }

        // Selection ---------------------------------------------------------
        public bool IsSelected(Guid id) => selection.Contains(id);
        public int SelectionCount => selection.Count;
        public IEnumerable<ShelfItem> SelectedItems => Items.Where(i => selection.Contains(i.Id));

        public void Select(Guid id) { selection.Clear(); selection.Add(id); anchor = id; SelectionChanged?.Invoke(); }
        public void Toggle(Guid id)
        {
            if (!selection.Remove(id)) { selection.Add(id); anchor = id; }
            SelectionChanged?.Invoke();
        }
        public void SelectRange(Guid id)
        {
            int a = anchor.HasValue ? IndexOf(anchor.Value) : -1, b = IndexOf(id);
            if (a < 0 || b < 0) { Select(id); return; }
            selection.Clear();
            for (int i = Math.Min(a, b); i <= Math.Max(a, b); i++) selection.Add(Items[i].Id);
            SelectionChanged?.Invoke();
        }
        public void SelectAll() { selection.Clear(); foreach (var i in Items) selection.Add(i.Id); SelectionChanged?.Invoke(); }
        public void ClearSelection() { if (selection.Count == 0) return; selection.Clear(); SelectionChanged?.Invoke(); }
        int IndexOf(Guid id) { for (int i = 0; i < Items.Count; i++) if (Items[i].Id == id) return i; return -1; }

        /// <summary>Items an action works on: the selection in list mode, otherwise everything.</summary>
        public List<ShelfItem> Targets => expanded && selection.Count > 0 ? SelectedItems.ToList() : Items.ToList();

        // Items --------------------------------------------------------------
        public void Add(IEnumerable<ShelfItem> added)
        {
            var existing = new HashSet<string>(Items.Where(i => i.IsFile && i.Path != null)
                .Select(i => Norm(i.Path!)), StringComparer.OrdinalIgnoreCase);
            foreach (var item in added)
            {
                if (item.IsFile && item.Path != null && !existing.Add(Norm(item.Path))) continue;
                Items.Add(item);
            }
            OnChanged(nameof(DisplayTitle));
        }

        static string Norm(string p) { try { return System.IO.Path.GetFullPath(p).TrimEnd('\\'); } catch { return p; } }

        public void Remove(IEnumerable<Guid> ids)
        {
            var set = ids.ToHashSet();
            foreach (var i in Items.Where(i => set.Contains(i.Id)).ToList()) Items.Remove(i);
            selection.ExceptWith(set);
            SelectionChanged?.Invoke();
        }

        /// <summary>Swap processed items for their results, keeping their place on the shelf.</summary>
        public void Replace(IReadOnlyCollection<ShelfItem> old, IReadOnlyCollection<ShelfItem> results)
        {
            if (results.Count == 0) return;
            var oldIds = old.Select(o => o.Id).ToHashSet();
            int first = -1;
            for (int i = 0; i < Items.Count; i++) if (oldIds.Contains(Items[i].Id)) { first = i; break; }
            foreach (var i in Items.Where(i => oldIds.Contains(i.Id)).ToList()) Items.Remove(i);
            int at = first < 0 ? Items.Count : Math.Min(first, Items.Count);
            foreach (var r in results) Items.Insert(at++, r);
            selection.Clear();
            foreach (var r in results) selection.Add(r.Id);
            SelectionChanged?.Invoke();
        }

        public void PruneDeadFiles()
        {
            var dead = Items.Where(i => !i.IsAlive).Select(i => i.Id).ToList();
            if (dead.Count > 0) Remove(dead);
        }

        DispatcherTimer? toastTimer;
        public void Toast(string text, double seconds = 1.6)
        {
            Status = text;
            toastTimer?.Stop();
            toastTimer = new DispatcherTimer { Interval = TimeSpan.FromSeconds(seconds) };
            toastTimer.Tick += (_, _) => { toastTimer?.Stop(); Status = null; };
            toastTimer.Start();
        }

        // Recent shelves ------------------------------------------------------
        public ShelfSnapshot Snapshot() => new()
        {
            Name = name, ColorIndex = colorIndex, Items = Items.ToList(), ClosedAt = DateTime.Now, Title = DisplayTitle,
        };

        void Set<T>(ref T field, T value, [CallerMemberName] string? prop = null)
        {
            if (EqualityComparer<T>.Default.Equals(field, value)) return;
            field = value;
            OnChanged(prop);
        }
        void OnChanged(string? prop) => PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(prop));
    }

    public sealed class ShelfSnapshot
    {
        public Guid Id { get; set; } = Guid.NewGuid();
        public string Name { get; set; } = "";
        public int ColorIndex { get; set; }
        public List<ShelfItem> Items { get; set; } = new();
        public DateTime ClosedAt { get; set; }
        public string Title { get; set; } = "";
    }
}
