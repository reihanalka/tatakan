using System;
using System.Collections.Generic;
using System.IO;
using System.IO.Pipes;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;

namespace Tatakan
{
    public partial class App : Application
    {
        const string InstanceName = "Tatakan.SingleInstance.v1";
        Mutex? mutex;
        readonly List<ShelfWindow> shelves = new();
        ShakeDetector? shake;
        HotKey? hotKey;
        TrayIcon? tray;
        SettingsWindow? settingsWindow;
        CancellationTokenSource? pipeCts;

        protected override void OnStartup(StartupEventArgs e)
        {
            base.OnStartup(e);
            var args = e.Args;

            // One Tatakan per user: a second launch just asks the first to open a shelf.
            mutex = new Mutex(true, InstanceName + Environment.UserName, out bool first);
            if (!first)
            {
                Signal(args.Contains("--background") ? "noop" : "new");
                Shutdown();
                return;
            }

            DispatcherUnhandledException += (_, ex) =>
            {
                System.Diagnostics.Debug.WriteLine("Tatakan: " + ex.Exception);
                ex.Handled = true;
            };

            bool? forceDark = args.Contains("--dark") ? true : args.Contains("--light") ? false : null;
            Theme.Init(forceDark);
            Ingest.CleanOldCache();

            tray = new TrayIcon(BuildTrayMenu, () => NewShelf(null)?.BringUp());
            shake = new ShakeDetector();
            shake.Shake += p => NewShelf(new Point(p.X, p.Y));
            shake.Start();
            hotKey = new HotKey(1, Native.MOD_CONTROL | Native.MOD_ALT, Native.VK_SPACE, () => NewShelf(null)?.BringUp());
            ListenForSignals();

            if (args.Contains("--demo")) Demo(args);
            else if (!args.Contains("--background") && AppSettings.Shared.Recent.Count == 0 && !AppSettings.LaunchAtLogin)
                tray.Balloon("Tatakan is running", "Shake the pointer while dragging a file, or press Ctrl+Alt+Space.");
        }

        protected override void OnExit(ExitEventArgs e)
        {
            pipeCts?.Cancel();
            shake?.Dispose();
            hotKey?.Dispose();
            tray?.Dispose();
            mutex?.Dispose();
            base.OnExit(e);
        }

        // Shelves ----------------------------------------------------------------
        public ShelfWindow? NewShelf(Point? screenPx)
        {
            // Reuse an empty shelf instead of stacking empties.
            var empty = shelves.FirstOrDefault(s => s.Shelf.Items.Count == 0);
            if (empty != null) { empty.Topmost = false; empty.Topmost = true; return empty; }
            var w = new ShelfWindow(screenPx);
            Track(w);
            w.ShowShelf();
            return w;
        }

        void Track(ShelfWindow w)
        {
            w.ClosedShelf += closed =>
            {
                if (closed.Shelf.Items.Count > 0) AppSettings.Shared.PushRecent(closed.Shelf.Snapshot());
                shelves.Remove(closed);
            };
            shelves.Add(w);
        }

        void Restore(ShelfSnapshot snap)
        {
            var w = new ShelfWindow(null);
            w.Shelf.Name = snap.Name;
            w.Shelf.ColorIndex = snap.ColorIndex;
            w.Shelf.Add(snap.Items.Where(i => i.IsAlive));
            AppSettings.Shared.Recent.RemoveAll(r => r.Id == snap.Id);
            AppSettings.Shared.Save();
            Track(w);
            w.ShowShelf();
            w.BringUp();
        }

        public void OpenSettings()
        {
            if (settingsWindow == null)
            {
                settingsWindow = new SettingsWindow();
                settingsWindow.Closed += (_, _) => settingsWindow = null;
            }
            settingsWindow.Show();
            settingsWindow.Activate();
        }

        // Tray menu ------------------------------------------------------------
        ContextMenu BuildTrayMenu()
        {
            var m = new ContextMenu();
            m.Items.Add(ItemMenu.Item("New Shelf", Glyph.Add, () => NewShelf(null)?.BringUp(), true, "Ctrl+Alt+Space"));
            m.Items.Add(ItemMenu.Item("New Shelf from Clipboard", Glyph.Paste, () =>
            {
                var w = NewShelf(null);
                if (w != null) { Actions.Paste(w.Shelf); w.BringUp(); }
            }));

            if (shelves.Count > 0)
            {
                m.Items.Add(new Separator());
                m.Items.Add(ItemMenu.Header("Open Shelves"));
                foreach (var w in shelves.ToList())
                    m.Items.Add(ItemMenu.Item(w.Shelf.DisplayTitle, Glyph.Tray, w.BringUp));
                m.Items.Add(ItemMenu.Item("Close All Shelves", Glyph.Close, () => shelves.ToList().ForEach(s => s.CloseShelf())));
            }

            var recent = AppSettings.Shared.Recent;
            var recentItem = new MenuItem { Header = "Recent Shelves", Icon = UI.Icon(Glyph.History, 12), IsEnabled = recent.Count > 0 };
            foreach (var snap in recent.ToList())
            {
                var it = ItemMenu.Item($"{snap.Title} — {Ago(snap.ClosedAt)}", null, () => Restore(snap));
                if (snap.ColorIndex > 0) it.Icon = UI.Swatch(Shelf.Colors[snap.ColorIndex]);
                recentItem.Items.Add(it);
            }
            if (recent.Count > 0)
            {
                recentItem.Items.Add(new Separator());
                recentItem.Items.Add(ItemMenu.Item("Clear Recent", null, () => { AppSettings.Shared.Recent.Clear(); AppSettings.Shared.Save(); }));
            }
            m.Items.Add(new Separator());
            m.Items.Add(recentItem);

            m.Items.Add(new Separator());
            var shakeItem = new MenuItem { Header = "Shake to Open", IsChecked = AppSettings.Shared.ShakeEnabled };
            shakeItem.Click += (_, _) => { AppSettings.Shared.ShakeEnabled = !AppSettings.Shared.ShakeEnabled; AppSettings.Shared.Save(); };
            m.Items.Add(shakeItem);
            m.Items.Add(ItemMenu.Item("Settings…", Glyph.Settings, OpenSettings));
            m.Items.Add(ItemMenu.Item("Quit Tatakan", Glyph.Power, Shutdown));
            return m;
        }

        static string Ago(DateTime t)
        {
            var d = DateTime.Now - t;
            if (d.TotalMinutes < 1) return "now";
            if (d.TotalHours < 1) return $"{(int)d.TotalMinutes} min ago";
            if (d.TotalDays < 1) return $"{(int)d.TotalHours} hr ago";
            return $"{(int)d.TotalDays} d ago";
        }

        // Single instance pipe -------------------------------------------------
        static void Signal(string msg)
        {
            try
            {
                using var c = new NamedPipeClientStream(".", InstanceName + Environment.UserName, PipeDirection.Out);
                c.Connect(800);
                using var w = new StreamWriter(c);
                w.WriteLine(msg);
            }
            catch { }
        }

        void ListenForSignals()
        {
            pipeCts = new CancellationTokenSource();
            var token = pipeCts.Token;
            Task.Run(async () =>
            {
                while (!token.IsCancellationRequested)
                {
                    try
                    {
                        using var s = new NamedPipeServerStream(InstanceName + Environment.UserName, PipeDirection.In, 1,
                            PipeTransmissionMode.Byte, PipeOptions.Asynchronous);
                        await s.WaitForConnectionAsync(token);
                        using var r = new StreamReader(s);
                        var msg = await r.ReadLineAsync();
                        if (msg == "new") _ = Dispatcher.BeginInvoke(() => NewShelf(null)?.BringUp());
                    }
                    catch (OperationCanceledException) { break; }
                    catch { await Task.Delay(500, token).ContinueWith(_ => { }); }
                }
            }, token);
        }

        // Screenshots / testing: Tatakan.exe --demo <file> <file> … [--expand] [--pair] [--settings] [--dark|--light]
        void Demo(string[] args)
        {
            int i = Array.IndexOf(args, "--demo");
            var files = args.Skip(i + 1).Where(a => !a.StartsWith("--")).ToList();
            var w = NewShelf(new Point(420, 520));
            if (w == null) return;
            w.Shelf.Add(files.Select(ShelfItem.FromFile));
            if (args.Contains("--expand")) w.SetExpanded(true);
            if (args.Contains("--pair"))
            {
                var e = new ShelfWindow(new Point(760, 520)); Track(e); e.ShowShelf();
                var l = new ShelfWindow(new Point(1100, 520)); Track(l); l.ShowShelf();
                l.Shelf.Add(files.Select(ShelfItem.FromFile));
                l.Shelf.Add(new[] { ShelfItem.FromText("Client brief v2 — colour revision"), ShelfItem.FromLink("https://github.com/reihanalka/tatakan", "Tatakan on GitHub") });
                l.Shelf.Name = "KV Revision"; l.Shelf.ColorIndex = 2;
                l.SetExpanded(true);
                l.Shelf.Select(l.Shelf.Items[Math.Min(1, l.Shelf.Items.Count - 1)].Id);
            }
            if (args.Contains("--settings")) OpenSettings();
        }
    }
}
