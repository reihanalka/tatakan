using System;
using System.Diagnostics;
using System.Linq;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Interop;
using System.Windows.Media;

namespace Tatakan
{
    /// <summary>Settings: same options as the Mac app's Shelf section. No notch — that's Mac only.</summary>
    internal sealed class SettingsWindow : Window
    {
        readonly AppSettings s = AppSettings.Shared;
        readonly StackPanel excludedList = new();
        readonly ComboBox appPicker = new();
        Slider? sensitivity;

        public SettingsWindow()
        {
            Title = "Tatakan Settings";
            Width = 480;
            SizeToContent = SizeToContent.Height;
            ResizeMode = ResizeMode.NoResize;
            WindowStartupLocation = WindowStartupLocation.CenterScreen;
            Icon = UI.Logo();
            UseLayoutRounding = true;
            SetResourceReference(BackgroundProperty, "Panel");
            SourceInitialized += (_, _) => Native.UseDarkTitleBar(new WindowInteropHelper(this).Handle, Theme.IsDark);
            Theme.Changed += OnTheme;
            Closed += (_, _) => Theme.Changed -= OnTheme;

            var root = new StackPanel { Margin = new Thickness(22, 18, 22, 22) };
            var head = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(0, 0, 0, 14) };
            head.Children.Add(new Image { Source = UI.Logo(), Width = 34, Height = 34, Margin = new Thickness(0, 0, 10, 0) });
            var name = new StackPanel { VerticalAlignment = VerticalAlignment.Center };
            var word = new TextBlock { Text = "TATAKAN", FontFamily = Theme.Dot, FontSize = 20 };
            word.SetResourceReference(TextBlock.ForegroundProperty, "Ink");
            name.Children.Add(word);
            var ver = typeof(App).Assembly.GetName().Version;
            name.Children.Add(UI.Label9($"Version {ver?.Major}.{ver?.Minor}.{ver?.Build} · Windows"));
            head.Children.Add(name);
            root.Children.Add(head);

            // Shelf
            var shelf = Card("Shelf");
            shelf.Children.Add(Toggle("Open a shelf when I shake the pointer while dragging", s.ShakeEnabled, v =>
            {
                s.ShakeEnabled = v; s.Save();
                if (sensitivity != null) sensitivity.IsEnabled = v;
            }));
            sensitivity = new Slider { Minimum = 0, Maximum = 1, Value = s.ShakeSensitivity, Width = 170, VerticalAlignment = VerticalAlignment.Center, IsEnabled = s.ShakeEnabled };
            sensitivity.SetResourceReference(StyleProperty, "Thin");
            sensitivity.ValueChanged += (_, e) => { s.ShakeSensitivity = e.NewValue; s.Save(); };
            var sensRow = new StackPanel { Orientation = Orientation.Horizontal };
            sensRow.Children.Add(Small("Calm"));
            sensitivity.Margin = new Thickness(8, 0, 8, 0);
            sensRow.Children.Add(sensitivity);
            sensRow.Children.Add(Small("Eager"));
            shelf.Children.Add(Row("Shake sensitivity", sensRow));
            shelf.Children.Add(Toggle("Remove items after dragging them out", s.RemoveAfterDrag, v => { s.RemoveAfterDrag = v; s.Save(); }));
            shelf.Children.Add(Toggle("Close the shelf when it becomes empty", s.CloseWhenEmpty, v => { s.CloseWhenEmpty = v; s.Save(); }));
            root.Children.Add(Wrap(shelf));

            // Shortcuts
            var keys = Card("Shortcuts");
            keys.Children.Add(Row("New shelf", Mono("Ctrl+Alt+Space")));
            keys.Children.Add(Row("Tray icon", Mono("Click = new shelf")));
            keys.Children.Add(Row("On a shelf", Mono("Ctrl+C  Ctrl+V  Del  F2  Esc")));
            root.Children.Add(Wrap(keys));

            // Excluded apps
            var ex = Card("Don't shake in these apps");
            ex.Children.Add(excludedList);
            var pick = new Grid { Margin = new Thickness(0, 6, 0, 0) };
            pick.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            pick.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            appPicker.FontFamily = Theme.Ui;
            appPicker.FontSize = 12;
            appPicker.Margin = new Thickness(0, 0, 8, 0);
            appPicker.Padding = new Thickness(8, 4, 8, 4);
            appPicker.VerticalContentAlignment = VerticalAlignment.Center;
            appPicker.DropDownOpened += (_, _) => FillPicker();
            FillPicker();
            pick.Children.Add(appPicker);
            var add = new Button { Content = "Add" };
            add.SetResourceReference(StyleProperty, "PillButton");
            add.Click += (_, _) =>
            {
                if (appPicker.SelectedItem is ComboBoxItem { Tag: string p } && p.Length > 0 && !s.ExcludedApps.Contains(p))
                {
                    s.ExcludedApps.Add(p); s.Save(); RenderExcluded(); FillPicker();
                }
            };
            Grid.SetColumn(add, 1);
            pick.Children.Add(add);
            ex.Children.Add(pick);
            RenderExcluded();
            root.Children.Add(Wrap(ex));

            // General
            var gen = Card("General");
            gen.Children.Add(Toggle("Launch at login", AppSettings.LaunchAtLogin, v => AppSettings.LaunchAtLogin = v));
            var links = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(0, 6, 0, 0) };
            links.Children.Add(Link("Source code", "https://github.com/reihanalka/tatakan"));
            links.Children.Add(Link("Report a bug", "https://github.com/reihanalka/tatakan/issues/new/choose"));
            gen.Children.Add(links);
            root.Children.Add(Wrap(gen));

            var note = UI.Label9("The notch panel (Nook) is Mac only.");
            note.Margin = new Thickness(4, 4, 0, 0);
            root.Children.Add(note);
            Content = root;
        }

        void OnTheme() => Native.UseDarkTitleBar(new WindowInteropHelper(this).Handle, Theme.IsDark);

        static StackPanel Card(string title)
        {
            var p = new StackPanel();
            var l = UI.Label9(title);
            l.Margin = new Thickness(0, 0, 0, 8);
            p.Children.Add(l);
            return p;
        }

        static Border Wrap(UIElement child)
        {
            var b = new Border { CornerRadius = new CornerRadius(16), Padding = new Thickness(14, 12, 14, 12), Margin = new Thickness(0, 0, 0, 10), Child = child };
            b.SetResourceReference(Border.BackgroundProperty, "Card");
            return b;
        }

        static FrameworkElement Toggle(string label, bool value, Action<bool> changed)
        {
            var cb = new CheckBox { IsChecked = value, VerticalAlignment = VerticalAlignment.Center };
            cb.SetResourceReference(StyleProperty, "Pill");
            cb.Checked += (_, _) => changed(true);
            cb.Unchecked += (_, _) => changed(false);
            var row = Row(label, cb);
            row.MouseLeftButtonUp += (_, e) => { if (e.OriginalSource is not CheckBox) cb.IsChecked = !cb.IsChecked; };
            row.Cursor = System.Windows.Input.Cursors.Hand;
            return row;
        }

        static Grid Row(string label, UIElement right)
        {
            var g = new Grid { Margin = new Thickness(0, 4, 0, 4), Background = Brushes.Transparent };
            g.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            g.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            var t = new TextBlock { Text = label, FontFamily = Theme.Ui, FontSize = 12.5, TextWrapping = TextWrapping.Wrap, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(0, 0, 12, 0) };
            t.SetResourceReference(TextBlock.ForegroundProperty, "Ink");
            g.Children.Add(t);
            Grid.SetColumn(right, 1);
            g.Children.Add(right);
            return g;
        }

        static TextBlock Small(string s)
        {
            var t = new TextBlock { Text = s, FontFamily = Theme.Ui, FontSize = 11, VerticalAlignment = VerticalAlignment.Center };
            t.SetResourceReference(TextBlock.ForegroundProperty, "Mute");
            return t;
        }

        static TextBlock Mono(string s)
        {
            var t = new TextBlock { Text = s, FontFamily = Theme.Mono, FontSize = 11, VerticalAlignment = VerticalAlignment.Center };
            t.SetResourceReference(TextBlock.ForegroundProperty, "Mute");
            return t;
        }

        static Button Link(string text, string url)
        {
            var b = new Button { Content = text, Margin = new Thickness(0, 0, 8, 0) };
            b.SetResourceReference(StyleProperty, "PillButton");
            b.Click += (_, _) => { try { Process.Start(new ProcessStartInfo(url) { UseShellExecute = true }); } catch { } };
            return b;
        }

        void RenderExcluded()
        {
            excludedList.Children.Clear();
            if (s.ExcludedApps.Count == 0) { excludedList.Children.Add(Small("None yet. Shaking works everywhere.")); return; }
            foreach (var app in s.ExcludedApps.ToList())
            {
                var remove = UI.RoundIcon(Glyph.Remove, "Remove", () => { s.ExcludedApps.Remove(app); s.Save(); RenderExcluded(); FillPicker(); });
                excludedList.Children.Add(Row(app, remove));
            }
        }

        void FillPicker()
        {
            var keep = (appPicker.SelectedItem as ComboBoxItem)?.Tag as string;
            appPicker.Items.Clear();
            appPicker.Items.Add(new ComboBoxItem { Content = "Choose a running app…", Tag = "" });
            var names = Process.GetProcesses()
                .Where(p => { try { return p.MainWindowHandle != IntPtr.Zero && p.Id != Environment.ProcessId; } catch { return false; } })
                .Select(p => p.ProcessName).Distinct(StringComparer.OrdinalIgnoreCase)
                .Where(n => !s.ExcludedApps.Contains(n, StringComparer.OrdinalIgnoreCase))
                .OrderBy(n => n, StringComparer.OrdinalIgnoreCase);
            foreach (var n in names) appPicker.Items.Add(new ComboBoxItem { Content = n, Tag = n });
            appPicker.SelectedIndex = 0;
            if (keep != null)
                foreach (ComboBoxItem it in appPicker.Items)
                    if ((string)it.Tag == keep) { appPicker.SelectedItem = it; break; }
        }
    }
}
