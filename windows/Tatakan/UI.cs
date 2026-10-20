using System;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Shapes;

namespace Tatakan
{
    /// <summary>Small shared building blocks (Puteran components).</summary>
    internal static class UI
    {
        /// <summary>Small uppercase mono label (Puteran's Label9).</summary>
        public static TextBlock Label9(string text)
        {
            var t = new TextBlock
            {
                Text = text.ToUpperInvariant(), FontFamily = Theme.Mono, FontSize = 9,
                TextTrimming = TextTrimming.CharacterEllipsis,
            };
            t.SetResourceReference(TextBlock.ForegroundProperty, "Mute");
            return t;
        }

        public static Button RoundIcon(string glyph, string tip, Action action)
        {
            var b = new Button { Content = glyph, ToolTip = tip };
            b.SetResourceReference(FrameworkElement.StyleProperty, "RoundIcon");
            b.Click += (_, _) => action();
            ToolTipService.SetInitialShowDelay(b, 600);
            return b;
        }

        public static TextBlock Icon(string glyph, double size = 13) =>
            new() { Text = glyph, FontFamily = Theme.Icons, FontSize = size, VerticalAlignment = VerticalAlignment.Center };

        /// <summary>Async thumbnail: placeholder icon first, real thumbnail when ready.</summary>
        public static FrameworkElement Thumb(ShelfItem item, int size)
        {
            if (!item.IsFile)
            {
                var g = new Grid { Width = size, Height = size };
                var tile = new Border { CornerRadius = new CornerRadius(Math.Max(6, size / 6.0)) };
                tile.SetResourceReference(Border.BackgroundProperty, "Panel");
                tile.SetResourceReference(Border.BorderBrushProperty, "Line");
                tile.BorderThickness = new Thickness(1);
                g.Children.Add(tile);
                var glyph = Icon(item.Kind == ItemKind.Link ? Glyph.Link : Glyph.Text, size * 0.42);
                glyph.HorizontalAlignment = HorizontalAlignment.Center;
                glyph.SetResourceReference(TextBlock.ForegroundProperty, "Ink");
                g.Children.Add(glyph);
                return g;
            }
            var img = new Image { Width = size, Height = size, Stretch = Stretch.Uniform };
            RenderOptions.SetBitmapScalingMode(img, BitmapScalingMode.HighQuality);
            int px = (int)Math.Round(size * 2.0);
            var cached = Thumbnails.Cached(item, px);
            if (cached != null) img.Source = cached;
            else
            {
                img.Opacity = 0.4;
                Thumbnails.Load(item, px, src => { if (src != null) { img.Source = src; img.Opacity = 1; } });
            }
            return img;
        }

        /// <summary>4 px rounded scrollbar thumb, no arrows (template built in XAML, see App.xaml "ThinScrollBar").</summary>
        public static Style ThinScrollBar() => (Style)Application.Current.Resources["ThinScrollBar"];

        public static Ellipse Swatch(Color c) =>
            new() { Width = 10, Height = 10, Fill = new SolidColorBrush(c), VerticalAlignment = VerticalAlignment.Center };

        public static BitmapImage Logo()
        {
            var b = new BitmapImage(new Uri("pack://application:,,,/Assets/logo-256.png"));
            b.Freeze();
            return b;
        }
    }
}
