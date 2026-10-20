using System;
using System.Windows;
using System.Windows.Media;
using Microsoft.Win32;

namespace Tatakan
{
    /// <summary>
    /// Tatakan design tokens — same family as the Mac app (Puteran / Nothing-style).
    /// Light by default, dark follows Windows. Accent #F07A42 only for active states.
    /// </summary>
    internal static class Theme
    {
        public static bool IsDark { get; private set; }
        public static event Action? Changed;
        public static readonly Color Accent = Color.FromRgb(0xF0, 0x7A, 0x42);

        public static FontFamily Dot = null!, Ui = null!, UiSemi = null!, UiBold = null!, Mono = null!;
        public static readonly FontFamily Icons = new("Segoe Fluent Icons, Segoe MDL2 Assets");

        static bool? forced;

        public static void Init(bool? forceDark)
        {
            forced = forceDark;
            var baseUri = new Uri("pack://application:,,,/");
            Dot = new FontFamily(baseUri, "./Assets/Fonts/#Doto");
            Ui = new FontFamily(baseUri, "./Assets/Fonts/#Space Grotesk Medium");
            UiSemi = new FontFamily(baseUri, "./Assets/Fonts/#Space Grotesk SemiBold");
            UiBold = new FontFamily(baseUri, "./Assets/Fonts/#Space Grotesk Bold");
            Mono = new FontFamily(baseUri, "./Assets/Fonts/#Space Mono");
            var r = Application.Current.Resources;
            r["UiFont"] = Ui;
            r["MonoFont"] = Mono;
            Apply(forced ?? !AppsUseLightTheme());
            if (forced == null)
            {
                SystemEvents.UserPreferenceChanged += (_, e) =>
                {
                    if (e.Category != UserPreferenceCategory.General) return;
                    Application.Current?.Dispatcher.BeginInvoke(() => Apply(!AppsUseLightTheme()));
                };
            }
        }

        static bool ReadFlag(string name, bool fallback)
        {
            try
            {
                using var k = Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Themes\Personalize");
                return k?.GetValue(name) is int v ? v != 0 : fallback;
            }
            catch { return fallback; }
        }

        public static bool AppsUseLightTheme() => ReadFlag("AppsUseLightTheme", true);
        public static bool TaskbarIsLight() => ReadFlag("SystemUsesLightTheme", false);

        static void Apply(bool dark)
        {
            IsDark = dark;
            var r = Application.Current.Resources;
            Set(r, "Panel", dark ? 0x161616u : 0xF4F4F2u);
            Set(r, "Card", dark ? 0x1F1F1Fu : 0xECECEAu);
            Set(r, "Ink", dark ? 0xF2F2F0u : 0x111111u);
            Set(r, "OnInk", dark ? 0x111111u : 0xFFFFFFu);
            Set(r, "Mute", dark ? 0x8A8A88u : 0x6E6E6Cu);
            Set(r, "Line", dark ? 0x2C2C2Cu : 0xD9D9D6u);
            Set(r, "AccentSoft", dark ? 0x4A2A1Cu : 0xF9D9C8u);
            // Smoke: the Mac shelf sits on a live blur; here it's a near-opaque tint of the same colour.
            Set(r, "Smoke", dark ? 0x161616u : 0xF4F4F2u, dark ? 0.94 : 0.95);
            Set(r, "SmokeCard", dark ? 0x2A2A2Au : 0xFFFFFFu, 0.55);
            Set(r, "SmokeLine", dark ? 0xFFFFFFu : 0x000000u, 0.10);
            Set(r, "Dot", dark ? 0xFFFFFFu : 0x000000u, dark ? 0.14 : 0.16);
            var accent = new SolidColorBrush(Accent); accent.Freeze();
            r["Accent"] = accent;
            Changed?.Invoke();
        }

        static void Set(ResourceDictionary r, string key, uint rgb, double alpha = 1)
        {
            var b = new SolidColorBrush(C(rgb, alpha));
            b.Freeze();
            r[key] = b;
        }

        public static Color C(uint rgb, double alpha = 1) =>
            Color.FromArgb((byte)Math.Round(alpha * 255), (byte)(rgb >> 16), (byte)(rgb >> 8), (byte)rgb);

        public static Brush B(string key) => (Brush)Application.Current.Resources[key];

        public static string N2(int n) => Math.Min(n, 99).ToString("00");
    }

    /// <summary>Segoe Fluent / MDL2 glyphs used in the UI.</summary>
    internal static class Glyph
    {
        public const string Close = "\uE711", More = "\uE712", Share = "\uE72D", Paste = "\uE77F", List = "\uE8FD",
            Stack = "\uE8A9", Open = "\uE8A7", Folder = "\uE838", Copy = "\uE8C8", Link = "\uE71B", Save = "\uE74E",
            Move = "\uE8DE", Zip = "\uE7B8", Photo = "\uE91B", Remove = "\uE738", Rename = "\uE8AC", Color = "\uE790",
            Delete = "\uE74D", Add = "\uE710", History = "\uE81C", Settings = "\uE713", Power = "\uE7E8",
            Text = "\uE8A5", Tray = "\uE8B7";
    }
}
