using System;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Interop;
using Forms = System.Windows.Forms;

namespace Tatakan
{
    /// <summary>
    /// The notification-area icon: Windows' equivalent of the Mac menu-bar item.
    /// Left click → new shelf, right click → menu (styled WPF menu, not the grey WinForms one).
    /// </summary>
    internal sealed class TrayIcon : IDisposable
    {
        readonly Forms.NotifyIcon icon;
        readonly Func<ContextMenu> menuFactory;
        readonly Window anchor;

        public TrayIcon(Func<ContextMenu> menuFactory, Action onClick)
        {
            this.menuFactory = menuFactory;
            icon = new Forms.NotifyIcon { Text = "Tatakan", Visible = true };
            UpdateIcon();
            Microsoft.Win32.SystemEvents.UserPreferenceChanged += (_, _) =>
                Application.Current?.Dispatcher.BeginInvoke(UpdateIcon);

            // Invisible owner so the WPF menu gets focus and closes when you click elsewhere.
            anchor = new Window
            {
                WindowStyle = WindowStyle.None, AllowsTransparency = true, Width = 1, Height = 1,
                ShowInTaskbar = false, Background = System.Windows.Media.Brushes.Transparent, Topmost = true,
                Left = -10000, Top = -10000, ShowActivated = false,
            };
            anchor.SourceInitialized += (_, _) => Native.MakeToolWindow(new WindowInteropHelper(anchor).Handle);
            anchor.Show();

            icon.MouseUp += (_, e) =>
            {
                if (e.Button == Forms.MouseButtons.Left) onClick();
                else if (e.Button == Forms.MouseButtons.Right) ShowMenu();
            };
        }

        void UpdateIcon()
        {
            // White glyph on dark taskbars, black on light ones.
            var name = Theme.TaskbarIsLight() ? "tray-light.ico" : "tray-dark.ico";
            var res = Application.GetResourceStream(new Uri($"pack://application:,,,/Assets/{name}"));
            if (res == null) return;
            var old = icon.Icon;
            using (var s = res.Stream)
                icon.Icon = new System.Drawing.Icon(s, Forms.SystemInformation.SmallIconSize);
            old?.Dispose();
        }

        void ShowMenu()
        {
            var menu = menuFactory();
            var p = Native.Cursor();
            double s = Native.DpiScaleAt(p);
            anchor.Left = p.X / s; anchor.Top = p.Y / s;
            anchor.Activate();
            Native.SetForegroundWindow(new WindowInteropHelper(anchor).Handle);
            menu.PlacementTarget = anchor;
            menu.Placement = PlacementMode.AbsolutePoint;
            menu.HorizontalOffset = p.X / s;
            menu.VerticalOffset = p.Y / s;
            menu.Opened += (_, _) =>
            {
                // Open upwards from the taskbar if it would run off the bottom.
                var work = Native.WorkAreaAt(p);
                if (p.Y / s + menu.ActualHeight > work.Bottom / s) menu.VerticalOffset = p.Y / s - menu.ActualHeight;
            };
            menu.IsOpen = true;
        }

        public void Balloon(string title, string text) =>
            icon.ShowBalloonTip(4000, title, text, Forms.ToolTipIcon.None);

        public void Dispose()
        {
            icon.Visible = false;
            icon.Dispose();
            anchor.Close();
        }
    }
}
