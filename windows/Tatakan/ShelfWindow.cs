using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Linq;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Animation;
using System.Windows.Shapes;

namespace Tatakan
{
    /// <summary>
    /// One floating shelf. Borderless, always on top, doesn't steal focus when it appears.
    /// Visual language: Puteran (Space Grotesk / Space Mono / Doto, ink controls, one accent).
    /// </summary>
    public sealed class ShelfWindow : Window
    {
        public Shelf Shelf { get; } = new();
        public event Action<ShelfWindow>? ClosedShelf;

        public static readonly Size CollapsedSize = new(196, 236);
        public static readonly Size ExpandedSize = new(300, 420);

        readonly Border frame = new();
        readonly Grid body = new();
        readonly ContentControl content = new();
        readonly StackPanel header = new();
        readonly Grid headerRow = new();
        readonly Grid footer = new();
        bool closing, draggingOut;

        public ShelfWindow(Point? screenPx = null)
        {
            WindowStyle = WindowStyle.None;
            AllowsTransparency = true;
            Background = Brushes.Transparent;
            ResizeMode = ResizeMode.NoResize;
            ShowInTaskbar = false;
            Topmost = true;
            ShowActivated = false;
            Width = CollapsedSize.Width + 24;
            Height = CollapsedSize.Height + 24;
            AllowDrop = true;
            Title = "Tatakan Shelf";
            UseLayoutRounding = true;
            SnapsToDevicePixels = true;
            TextOptions.SetTextFormattingMode(this, TextFormattingMode.Display);

            // 12 px transparent margin so the shadow has room.
            frame.Margin = new Thickness(12);
            frame.CornerRadius = new CornerRadius(22);
            frame.SetResourceReference(Border.BackgroundProperty, "Smoke");
            frame.BorderThickness = new Thickness(1);
            frame.Effect = new System.Windows.Media.Effects.DropShadowEffect { BlurRadius = 18, ShadowDepth = 4, Direction = 270, Opacity = 0.28 };
            frame.Child = body;
            Content = frame;

            body.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
            body.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
            body.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
            Grid.SetRow(content, 1);
            Grid.SetRow(footer, 2);
            BuildHeader();
            body.Children.Add(headerRow);
            body.Children.Add(content);
            body.Children.Add(footer);

            Shelf.Items.CollectionChanged += (_, _) => Render();
            Shelf.SelectionChanged += Render;
            Shelf.PropertyChanged += OnShelfChanged;
            Theme.Changed += Render;

            SourceInitialized += (_, _) =>
            {
                var h = new WindowInteropHelper(this).Handle;
                Native.MakeToolWindow(h);
                PlaceNear(screenPx);
            };
            Activated += (_, _) => Shelf.PruneDeadFiles();
            KeyDown += OnKey;
            MouseLeftButtonDown += (_, e) => { if (e.ButtonState == MouseButtonState.Pressed && e.OriginalSource is not ButtonBase) TryDragMove(); };

            DragEnter += OnDragOver;
            DragOver += OnDragOver;
            DragLeave += (_, _) => Shelf.IsTargeted = false;
            Drop += OnDrop;

            Render();
        }

        void TryDragMove() { try { DragMove(); } catch { } }

        // Placement ------------------------------------------------------------
        void PlaceNear(Point? px)
        {
            var p = px.HasValue ? new Native.POINT((int)px.Value.X, (int)px.Value.Y) : Native.Cursor();
            var work = Native.WorkAreaAt(p);
            double s = Native.DpiScaleAt(p);
            int w = (int)(Width * s), h = (int)(Height * s);
            int x = p.X + (int)(12 * s), y = p.Y - h / 2;
            if (x + w > work.Right) x = p.X - w - (int)(12 * s);
            x = Math.Clamp(x, work.Left, Math.Max(work.Left, work.Right - w));
            y = Math.Clamp(y, work.Top, Math.Max(work.Top, work.Bottom - h));
            var hwnd = new WindowInteropHelper(this).Handle;
            Native.SetWindowPos(hwnd, Native.HWND_TOPMOST, x, y, 0, 0, Native.SWP_NOSIZE | Native.SWP_NOACTIVATE);
        }

        public void ShowShelf()
        {
            Opacity = 0;
            Show();
            BeginAnimation(OpacityProperty, new DoubleAnimation(0, 1, TimeSpan.FromMilliseconds(160)));
        }

        public void BringUp()
        {
            if (!IsVisible) Show();
            Topmost = false; Topmost = true;
            Activate();
        }

        public void CloseShelf()
        {
            if (closing) return;
            closing = true;
            var a = new DoubleAnimation(Opacity, 0, TimeSpan.FromMilliseconds(120));
            a.Completed += (_, _) => { Close(); ClosedShelf?.Invoke(this); };
            BeginAnimation(OpacityProperty, a);
        }

        public void SetExpanded(bool on)
        {
            if (Shelf.Expanded == on) return;
            var target = on ? ExpandedSize : CollapsedSize;
            double top = Top;
            Width = target.Width + 24;
            Height = target.Height + 24;
            Top = top;
            // keep on screen
            var hwnd = new WindowInteropHelper(this).Handle;
            if (Native.GetWindowRect(hwnd, out var r))
            {
                var work = Native.WorkAreaAt(new Native.POINT(r.Left, r.Top));
                double s = Native.DpiScaleAt(new Native.POINT(r.Left, r.Top));
                if (r.Bottom > work.Bottom) Top -= (r.Bottom - work.Bottom) / s;
                if (r.Right > work.Right) Left -= (r.Right - work.Right) / s;
            }
            Shelf.Expanded = on;
            if (!on) Shelf.ClearSelection();
        }

        void OnShelfChanged(object? s, PropertyChangedEventArgs e)
        {
            switch (e.PropertyName)
            {
                case nameof(Shelf.IsTargeted):
                    UpdateFrameStroke();
                    if (Shelf.Items.Count == 0 || !Shelf.Expanded) Render();
                    break;
                case nameof(Shelf.Status):
                    RenderFooter();
                    break;
                case nameof(Shelf.Name):
                case nameof(Shelf.ColorIndex):
                case nameof(Shelf.Renaming):
                    RenderHeader();
                    break;
                case nameof(Shelf.Expanded):
                    Render();
                    break;
            }
        }

        void UpdateFrameStroke()
        {
            frame.SetResourceReference(Border.BorderBrushProperty, Shelf.IsTargeted ? "Accent" : "SmokeLine");
            frame.BorderThickness = new Thickness(Shelf.IsTargeted ? 1.5 : 1);
        }

        // Rendering ------------------------------------------------------------
        void Render()
        {
            UpdateFrameStroke();
            RenderHeader();
            if (Shelf.Items.Count == 0) content.Content = EmptyState();
            else if (Shelf.Expanded) content.Content = ListView();
            else content.Content = PileView();
            RenderFooter();
        }

        void BuildHeader()
        {
            headerRow.Margin = new Thickness(10, 10, 10, 6);
            headerRow.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            headerRow.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            headerRow.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            var close = UI.RoundIcon(Glyph.Close, "Close Shelf (Ctrl+W)", CloseShelf);
            var menu = UI.RoundIcon(Glyph.More, "Actions", () => { });
            menu.Click += (_, _) => OpenMenu(menu, Shelf.Targets, includeShelf: true);
            Grid.SetColumn(header, 1);
            Grid.SetColumn(menu, 2);
            header.HorizontalAlignment = HorizontalAlignment.Center;
            header.VerticalAlignment = VerticalAlignment.Center;
            headerRow.Children.Add(close);
            headerRow.Children.Add(header);
            headerRow.Children.Add(menu);
        }

        void RenderHeader()
        {
            header.Children.Clear();
            var titleRow = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Center };
            if (Shelf.Tint is Color tint)
                titleRow.Children.Add(new Ellipse { Width = 6, Height = 6, Fill = new SolidColorBrush(tint), Margin = new Thickness(0, 0, 5, 0), VerticalAlignment = VerticalAlignment.Center });

            if (Shelf.Renaming)
            {
                var box = new TextBox
                {
                    Text = Shelf.Name, Width = 130, FontFamily = Theme.UiBold, FontSize = 12, TextAlignment = TextAlignment.Center,
                    BorderThickness = new Thickness(0, 0, 0, 1), Background = Brushes.Transparent, Padding = new Thickness(0),
                };
                box.SetResourceReference(ForegroundProperty, "Ink");
                box.SetResourceReference(BorderBrushProperty, "Accent");
                box.SetResourceReference(TextBox.CaretBrushProperty, "Ink");
                void Commit() { if (!Shelf.Renaming) return; Shelf.Name = box.Text.Trim(); Shelf.Renaming = false; }
                box.KeyDown += (_, e) =>
                {
                    if (e.Key == Key.Enter) { Commit(); e.Handled = true; }
                    if (e.Key == Key.Escape) { Shelf.Renaming = false; e.Handled = true; }
                };
                box.LostKeyboardFocus += (_, _) => Commit();
                titleRow.Children.Add(box);
                Dispatcher.BeginInvoke(() => { Activate(); box.Focus(); box.SelectAll(); });
            }
            else
            {
                bool named = Shelf.Name.Length > 0;
                var t = new TextBlock
                {
                    Text = named ? Shelf.Name.ToUpperInvariant() : "TATAKAN",
                    FontFamily = named ? Theme.UiBold : Theme.Dot, FontSize = named ? 12 : 15,
                    TextTrimming = TextTrimming.CharacterEllipsis, MaxWidth = 130,
                };
                if (!named) t.Margin = new Thickness(0, -1, 0, -1);
                t.SetResourceReference(TextBlock.ForegroundProperty, "Ink");
                t.ToolTip = "Double-click to rename";
                t.MouseLeftButtonDown += (_, e) => { if (e.ClickCount == 2) { Shelf.Renaming = true; e.Handled = true; } };
                titleRow.Children.Add(t);
            }
            header.Children.Add(titleRow);
            var meta = UI.Label9(Meta());
            meta.HorizontalAlignment = HorizontalAlignment.Center;
            meta.Margin = new Thickness(0, 1, 0, 0);
            header.Children.Add(meta);
        }

        string Meta()
        {
            if (Shelf.Items.Count == 0) return "Empty";
            var n = $"{Theme.N2(Shelf.Items.Count)} item{(Shelf.Items.Count == 1 ? "" : "s")}";
            if (!Shelf.Expanded) return n;
            long bytes = Shelf.Items.Sum(Bytes.SizeOf);
            return bytes > 0 ? n + " · " + Bytes.Format(bytes) : n;
        }

        UIElement EmptyState()
        {
            var g = new Grid { Margin = new Thickness(10, 0, 10, 2), ClipToBounds = true };
            var card = new Border { CornerRadius = new CornerRadius(14) };
            card.SetResourceReference(Border.BackgroundProperty, "SmokeCard");
            g.Children.Add(card);
            g.Children.Add(new DotGrid { Active = Shelf.IsTargeted });
            var label = new Border { CornerRadius = new CornerRadius(12), Padding = new Thickness(12, 8, 12, 8), HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center };
            label.SetResourceReference(Border.BackgroundProperty, "Smoke");
            var stack = new StackPanel();
            var drop = new TextBlock { Text = "DROP", FontFamily = Theme.Dot, FontSize = 30, HorizontalAlignment = HorizontalAlignment.Center };
            drop.SetResourceReference(TextBlock.ForegroundProperty, Shelf.IsTargeted ? "Accent" : "Ink");
            stack.Children.Add(drop);
            var hint = UI.Label9(Shelf.IsTargeted ? "Release to keep" : "Files · links · text");
            hint.HorizontalAlignment = HorizontalAlignment.Center;
            hint.Margin = new Thickness(0, 4, 0, 0);
            stack.Children.Add(hint);
            label.Child = stack;
            g.Children.Add(label);
            return g;
        }

        /// <summary>Collapsed: a pile of thumbnails on a card; drag it to drag everything.</summary>
        UIElement PileView()
        {
            var outer = new Grid { Margin = new Thickness(10, 0, 10, 2) };
            var card = new Border { CornerRadius = new CornerRadius(14), ClipToBounds = true };
            card.SetResourceReference(Border.BackgroundProperty, "SmokeCard");
            var g = new Grid();
            g.Children.Add(new DotGrid { Active = Shelf.IsTargeted, Opacity = 0.7 });
            var top = Shelf.Items.Skip(Math.Max(0, Shelf.Items.Count - 3)).ToList();
            for (int i = 0; i < top.Count; i++)
            {
                int depth = top.Count - 1 - i;
                var th = UI.Thumb(top[i], 84);
                th.Effect = new System.Windows.Media.Effects.DropShadowEffect { BlurRadius = 8, ShadowDepth = 2, Direction = 270, Opacity = 0.22 };
                th.RenderTransformOrigin = new Point(0.5, 0.5);
                th.RenderTransform = new TransformGroup
                {
                    Children = { new RotateTransform(depth * (i % 2 == 0 ? -6 : 6)), new TranslateTransform(0, -depth * 4) },
                };
                g.Children.Add(th);
            }
            card.Child = g;
            outer.Children.Add(card);
            if (Shelf.Items.Count > 1)
            {
                var badge = new Border { CornerRadius = new CornerRadius(10), Padding = new Thickness(7, 2, 7, 3), Margin = new Thickness(8), HorizontalAlignment = HorizontalAlignment.Right, VerticalAlignment = VerticalAlignment.Top };
                badge.SetResourceReference(Border.BackgroundProperty, "Ink");
                var n = new TextBlock { Text = Theme.N2(Shelf.Items.Count), FontFamily = Theme.Dot, FontSize = 14 };
                n.SetResourceReference(TextBlock.ForegroundProperty, "OnInk");
                badge.Child = n;
                outer.Children.Add(badge);
            }
            outer.Background = Brushes.Transparent;
            outer.ToolTip = "Drag to drop everything · Click to see items";
            ToolTipService.SetInitialShowDelay(outer, 900);
            AttachDrag(outer, () => Shelf.Items.ToList(),
                click: _ => SetExpanded(true),
                doubleClick: () => Actions.Open(Shelf.Items.ToList()),
                menu: () => Shelf.Items.ToList());
            return outer;
        }

        /// <summary>Expanded: list with selection.</summary>
        UIElement ListView()
        {
            var stack = new StackPanel { Margin = new Thickness(10, 2, 10, 2) };
            foreach (var item in Shelf.Items)
            {
                var row = ItemRow(item, Shelf.IsSelected(item.Id));
                AttachDrag(row, () => DragSet(item),
                    click: mods => Click(item, mods),
                    doubleClick: () => Actions.Open(new[] { item }),
                    menu: () =>
                    {
                        if (!Shelf.IsSelected(item.Id)) Shelf.Select(item.Id);
                        return Shelf.Targets;
                    });
                stack.Children.Add(row);
            }
            var scroll = new ScrollViewer
            {
                Content = stack, VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
                HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled, Focusable = false,
            };
            scroll.Resources.Add(typeof(ScrollBar), UI.ThinScrollBar());
            return scroll;
        }

        static Border ItemRow(ShelfItem item, bool selected)
        {
            var row = new Border { CornerRadius = new CornerRadius(12), Padding = new Thickness(6, 5, 6, 5), Margin = new Thickness(0, 0, 0, 4) };
            row.SetResourceReference(Border.BackgroundProperty, selected ? "Ink" : "SmokeCard");
            var g = new Grid();
            g.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(34) });
            g.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            var thumbBox = new Border { Width = 34, Height = 34, CornerRadius = new CornerRadius(8) };
            if (!selected) thumbBox.SetResourceReference(Border.BackgroundProperty, "Smoke");
            thumbBox.Child = UI.Thumb(item, 30);
            g.Children.Add(thumbBox);
            var text = new StackPanel { Margin = new Thickness(9, 0, 0, 0), VerticalAlignment = VerticalAlignment.Center };
            Grid.SetColumn(text, 1);
            var title = new TextBlock { Text = item.Title, FontFamily = Theme.UiSemi, FontSize = 12, TextTrimming = TextTrimming.CharacterEllipsis };
            title.SetResourceReference(TextBlock.ForegroundProperty, selected ? "OnInk" : "Ink");
            text.Children.Add(title);
            var sub = UI.Label9(item.Subtitle);
            if (selected) { sub.SetResourceReference(TextBlock.ForegroundProperty, "OnInk"); sub.Opacity = 0.7; }
            sub.Margin = new Thickness(0, 2, 0, 0);
            text.Children.Add(sub);
            g.Children.Add(text);
            row.Child = g;
            row.ToolTip = item.Kind == ItemKind.Text ? Excerpt(item.Text) : item.Path;
            ToolTipService.SetInitialShowDelay(row, 900);
            return row;
        }

        static string? Excerpt(string? s) => s == null ? null : s.Length > 300 ? s[..300] + "…" : s;

        void RenderFooter()
        {
            footer.Children.Clear();
            footer.ColumnDefinitions.Clear();
            footer.Margin = new Thickness(10, 8, 10, 10);
            footer.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            footer.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            footer.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });

            var toggle = Shelf.Expanded
                ? UI.RoundIcon(Glyph.Stack, "Collapse", () => SetExpanded(false))
                : UI.RoundIcon(Glyph.List, "Show items", () => SetExpanded(true));
            toggle.IsEnabled = Shelf.Expanded || Shelf.Items.Count > 0;
            footer.Children.Add(toggle);

            if (Shelf.Status is string s)
            {
                var pill = new Border { CornerRadius = new CornerRadius(10), Padding = new Thickness(8, 4, 8, 4), HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(4, 0, 4, 0) };
                pill.SetResourceReference(Border.BackgroundProperty, "SmokeCard");
                var sp = new StackPanel { Orientation = Orientation.Horizontal };
                var dot = new Ellipse { Width = 5, Height = 5, Margin = new Thickness(0, 0, 5, 0), VerticalAlignment = VerticalAlignment.Center };
                dot.SetResourceReference(Shape.FillProperty, "Accent");
                sp.Children.Add(dot);
                var l = UI.Label9(s);
                l.SetResourceReference(TextBlock.ForegroundProperty, "Ink");
                sp.Children.Add(l);
                pill.Child = sp;
                Grid.SetColumn(pill, 1);
                footer.Children.Add(pill);
            }

            var right = new StackPanel { Orientation = Orientation.Horizontal };
            Grid.SetColumn(right, 2);
            var share = UI.RoundIcon(Glyph.Share, "Share (Nearby Share, Mail, apps…)", () => ShareUI.Show(this, Shelf.Targets, Shelf));
            share.IsEnabled = Shelf.Items.Count > 0;
            right.Children.Add(share);
            var paste = UI.RoundIcon(Glyph.Paste, "Paste (Ctrl+V)", () => Actions.Paste(Shelf));
            paste.Margin = new Thickness(6, 0, 0, 0);
            right.Children.Add(paste);
            footer.Children.Add(right);
        }

        List<ShelfItem> DragSet(ShelfItem item) =>
            Shelf.IsSelected(item.Id) ? Shelf.SelectedItems.ToList() : new List<ShelfItem> { item };

        void Click(ShelfItem item, ModifierKeys mods)
        {
            if (mods.HasFlag(ModifierKeys.Control)) Shelf.Toggle(item.Id);
            else if (mods.HasFlag(ModifierKeys.Shift)) Shelf.SelectRange(item.Id);
            else Shelf.Select(item.Id);
            Activate();
        }

        // Drag out ---------------------------------------------------------------
        void AttachDrag(FrameworkElement el, Func<List<ShelfItem>> items, Action<ModifierKeys> click,
                        Action doubleClick, Func<List<ShelfItem>> menu)
        {
            Point? down = null;
            bool moved = false;
            el.MouseLeftButtonDown += (_, e) =>
            {
                if (e.ClickCount == 2) { doubleClick(); down = null; e.Handled = true; return; }
                down = e.GetPosition(this); moved = false;
                el.CaptureMouse();
                e.Handled = true;   // don't DragMove the window from items
            };
            el.MouseMove += (_, e) =>
            {
                if (down == null || e.LeftButton != MouseButtonState.Pressed) return;
                var p = e.GetPosition(this);
                if (Math.Abs(p.X - down.Value.X) < SystemParameters.MinimumHorizontalDragDistance &&
                    Math.Abs(p.Y - down.Value.Y) < SystemParameters.MinimumVerticalDragDistance) return;
                moved = true; down = null;
                el.ReleaseMouseCapture();
                StartDrag(items());
            };
            el.MouseLeftButtonUp += (_, e) =>
            {
                el.ReleaseMouseCapture();
                if (down != null && !moved) click(Keyboard.Modifiers);
                down = null;
            };
            el.MouseRightButtonUp += (_, e) => { OpenMenu(el, menu(), includeShelf: false); e.Handled = true; };
        }

        void StartDrag(List<ShelfItem> items)
        {
            if (items.Count == 0) return;
            // File Explorer can't take raw text in a drop; when text is mixed with files, send it as .txt.
            bool mixed = items.Any(i => i.IsFile) && items.Any(i => i.Kind == ItemKind.Text);
            var dragItems = mixed
                ? items.Select(i => i.Kind == ItemKind.Text && Actions.TextToFile(i) is string f ? ShelfItem.FromFile(f) : i).ToList()
                : items;
            var data = Actions.ToDataObject(dragItems);
            draggingOut = true;
            DragDropEffects result;
            try { result = DragDrop.DoDragDrop(this, data, DragDropEffects.Copy | DragDropEffects.Move | DragDropEffects.Link); }
            catch { result = DragDropEffects.None; }
            finally { draggingOut = false; }
            AfterDrag(items, result);
        }

        /// <summary>After a successful drop elsewhere: optionally clear what was dragged out.</summary>
        void AfterDrag(List<ShelfItem> items, DragDropEffects effect)
        {
            var timer = new System.Windows.Threading.DispatcherTimer { Interval = TimeSpan.FromMilliseconds(250) };
            timer.Tick += (_, _) =>
            {
                timer.Stop();
                Shelf.PruneDeadFiles();   // an Explorer "move" leaves nothing behind
                if (effect == DragDropEffects.None) return;
                if (AppSettings.Shared.RemoveAfterDrag) Shelf.Remove(items.Select(i => i.Id));
                if (AppSettings.Shared.CloseWhenEmpty && Shelf.Items.Count == 0) CloseShelf();
            };
            timer.Start();
        }

        // Drop in ----------------------------------------------------------------
        void OnDragOver(object sender, DragEventArgs e)
        {
            e.Handled = true;
            if (draggingOut) { e.Effects = DragDropEffects.None; return; }
            e.Effects = DragDropEffects.Copy;
            Shelf.IsTargeted = true;
        }

        void OnDrop(object sender, DragEventArgs e)
        {
            Shelf.IsTargeted = false;
            if (draggingOut) return;
            Accept(e.Data);
            e.Handled = true;
        }

        public bool Accept(IDataObject data)
        {
            var items = Ingest.Items(data);
            Shelf.Add(items);
            return items.Count > 0;
        }

        // Menu -------------------------------------------------------------------
        void OpenMenu(FrameworkElement anchor, List<ShelfItem> items, bool includeShelf)
        {
            var menu = ItemMenu.Build(items, this, includeShelf);
            menu.PlacementTarget = anchor;
            menu.Placement = includeShelf ? PlacementMode.Bottom : PlacementMode.MousePoint;
            Activate();
            menu.IsOpen = true;
        }

        // Keyboard (when the shelf is focused) ---------------------------------
        void OnKey(object sender, KeyEventArgs e)
        {
            if (Shelf.Renaming) return;
            bool ctrl = Keyboard.Modifiers.HasFlag(ModifierKeys.Control);
            switch (e.Key)
            {
                case Key.Delete:
                case Key.Back:
                    Shelf.Remove(Shelf.SelectionCount == 0 ? Shelf.Items.Select(i => i.Id).ToList() : Shelf.SelectedItems.Select(i => i.Id).ToList());
                    break;
                case Key.Escape: CloseShelf(); break;
                case Key.Enter: Actions.Open(Shelf.Targets); break;
                case Key.C when ctrl: Actions.Copy(Shelf.Targets, Shelf); break;
                case Key.V when ctrl: Actions.Paste(Shelf); break;
                case Key.A when ctrl: SetExpanded(true); Shelf.SelectAll(); break;
                case Key.W when ctrl: CloseShelf(); break;
                case Key.O when ctrl: Actions.Open(Shelf.Targets); break;
                case Key.F2: Shelf.Renaming = true; break;
                default: return;
            }
            e.Handled = true;
        }

        protected override void OnClosed(EventArgs e)
        {
            Theme.Changed -= Render;
            base.OnClosed(e);
        }
    }

    /// <summary>Dot-matrix field. Dots light up in the accent when Active.</summary>
    internal sealed class DotGrid : FrameworkElement
    {
        public bool Active { get; set; }
        public double Spacing { get; set; } = 9;

        protected override void OnRender(DrawingContext dc)
        {
            var brush = Active ? new SolidColorBrush(Theme.Accent) { Opacity = 0.75 } : Theme.B("Dot");
            int cols = (int)(ActualWidth / Spacing), rows = (int)(ActualHeight / Spacing);
            if (cols < 1 || rows < 1) return;
            double ox = (ActualWidth - (cols - 1) * Spacing) / 2, oy = (ActualHeight - (rows - 1) * Spacing) / 2;
            for (int r = 0; r < rows; r++)
                for (int c = 0; c < cols; c++)
                    dc.DrawEllipse(brush, null, new Point(ox + c * Spacing, oy + r * Spacing), 1.1, 1.1);
        }
    }
}
